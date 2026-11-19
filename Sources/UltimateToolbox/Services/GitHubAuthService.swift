import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Security

/// GitHub 登录：官方 OAuth Device Flow（无需 Secret）+ 网页登录（ASWebAuthenticationSession，PKCE + state）。
/// 网页登录换 token 时 GitHub 强制要求 client_secret（PKCE 也省不掉，2026-10 实测不带 secret 返回 incorrect_client_credentials），
/// Secret 由用户从自己的 OAuth App 设置页粘贴，只存本机 Keychain，绝不进仓库、不上传。
/// Client ID 由用户在设置里填入自己的 OAuth App Client ID（github.com/settings/developers 创建，免费 2 分钟），
/// 或直接用 Personal Access Token 登录（备用路径）。Token 只存 Keychain。

struct DeviceCodeResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
}

struct DeviceTokenResponse: Decodable {
    let access_token: String?
    let error: String?
    let error_description: String?
}

@MainActor
final class GitHubAuthService: ObservableObject {
    static let shared = GitHubAuthService()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isAuthenticating = false
    @Published var userCode: String?
    @Published var verificationURL: URL?
    @Published var authError: String?

    /// 用户自己的 OAuth App Client ID（公开值，存 UserDefaults 即可）。
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "ut.github.clientID") }
    }

    /// 用户自己的 OAuth App Client Secret（敏感值，只存 Keychain；网页登录换 token 时 GitHub 强制要求）。
    @Published var clientSecret: String {
        didSet {
            if clientSecret.isEmpty { KeychainHelper.delete(account: secretAccount) }
            else { KeychainHelper.save(clientSecret, account: secretAccount) }
        }
    }

    private let tokenAccount = "github.token"
    /// 粘贴 Client ID / Secret 时常带上首尾空格或换行，GitHub 会认不出，直接 404；请求前统一去掉。
    private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedClientSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    private let secretAccount = "github.clientSecret"
    private var deviceFlowTask: Task<Void, Never>?
    private var webAuthSession: ASWebAuthenticationSession?
    private let webAuthPresentation = WebAuthPresentationProvider()
    private var webState: String?
    private var codeVerifier: String?

    /// 网页登录回调地址（须与 OAuth App 设置里的 Authorization callback URL 完全一致）。
    static let webCallbackURL = "com.hmk849.ultimatetoolbox://oauth/github"
    static let webCallbackScheme = "com.hmk849.ultimatetoolbox"

    /// 本 App 的 OAuth App Client ID（hmk849 账号下“Ultimate Toolbox”，2026-11-19 创建；
    /// Client ID 是公开标识、不是密钥，Device Flow 换 token 也不需要 Secret，所以可作默认值预填）。
    static let defaultClientID = "Ov23lifD8ZpzlGAyn3jy"

    init() {
        let stored = UserDefaults.standard.string(forKey: "ut.github.clientID") ?? ""
        clientID = stored.isEmpty ? Self.defaultClientID : stored
        clientSecret = KeychainHelper.read(account: secretAccount) ?? ""
        isLoggedIn = KeychainHelper.read(account: tokenAccount) != nil
    }

    var token: String? { KeychainHelper.read(account: tokenAccount) }

    func saveToken(_ token: String) {
        KeychainHelper.save(token, account: tokenAccount)
        isLoggedIn = true
        UTLog.success("GitHub 登录成功（Token 已存入 Keychain）", category: "GitHub")
    }

    /// Device Flow：第一步，取 device_code + user_code。
    func startDeviceFlow() async {
        guard !trimmedClientID.isEmpty else {
            authError = "请先在设置里填入你的 GitHub OAuth App Client ID（github.com/settings/developers 创建）"
            return
        }
        isAuthenticating = true
        authError = nil
        do {
            var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "client_id=\(trimmedClientID)&scope=repo%20workflow%20read%3Auser".data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                // 404 = GitHub 不认这个 Client ID：OAuth App 没建好、填成了 GitHub App 的 ID（Iv1. 开头）、或抄错了。
                if statusCode == 404 {
                    throw NSError(domain: "GitHub", code: 404, userInfo: [NSLocalizedDescriptionKey: "Client ID 无效（HTTP 404）：GitHub 不认这个 ID。可能原因：① OAuth App 还没建好；② 填成了 GitHub App 的 Client ID（Iv1. 开头），要 OAuth App 的（Ov23 开头）；③ 抄错了。去 github.com/settings/developers 的 OAuth Apps 里核对。"])
                }
                // device_flow_disabled = OAuth App 建好了但没开 Device Flow，去设置页点 Enable Device Flow。
                if let oauthErr = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data),
                   oauthErr.error == "device_flow_disabled" {
                    throw NSError(domain: "GitHub", code: 400, userInfo: [NSLocalizedDescriptionKey: "Device Flow 未开启：去 OAuth App 设置页（github.com/settings/developers → Ultimate Toolbox）点 Enable Device Flow，再回来登录。"])
                }
                throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "请求 device_code 失败（HTTP \(statusCode)）"])
            }
            let code = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
            userCode = code.user_code
            verificationURL = URL(string: code.verification_uri)
            UTLog.info("GitHub Device Flow 已发起，请在浏览器输入验证码", category: "GitHub")
            // 第二步：轮询换 token
            deviceFlowTask = Task { await self.pollForToken(deviceCode: code.device_code, interval: code.interval, expiresIn: code.expires_in) }
        } catch {
            authError = error.localizedDescription
            isAuthenticating = false
            UTLog.error("GitHub Device Flow 发起失败：\(error.localizedDescription)", category: "GitHub")
        }
    }

    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var wait = max(interval, 5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            if Task.isCancelled { break }
            do {
                var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = "client_id=\(trimmedClientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)
                let (data, _) = try await URLSession.shared.data(for: req)
                let tokenResp = try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
                if let token = tokenResp.access_token {
                    saveToken(token)
                    isAuthenticating = false
                    userCode = nil
                    verificationURL = nil
                    return
                }
                switch tokenResp.error {
                case "authorization_pending":
                    break
                case "slow_down":
                    wait += 5
                case "expired_token":
                    authError = "验证码已过期，请重新发起登录"
                    isAuthenticating = false
                    return
                case "access_denied":
                    authError = "你已拒绝授权"
                    isAuthenticating = false
                    return
                default:
                    break
                }
            } catch {
                // 网络抖动：继续轮询
                continue
            }
        }
        authError = "登录超时，请重新发起"
        isAuthenticating = false
    }

    func cancelDeviceFlow() {
        deviceFlowTask?.cancel()
        deviceFlowTask = nil
        isAuthenticating = false
        userCode = nil
        verificationURL = nil
    }

    // MARK: - 网页登录（ASWebAuthenticationSession + PKCE + state）

    /// 生成授权地址（PKCE + state），供系统浏览器登录与 App 内嵌登录页共用。
    /// 返回 nil 时 authError 已设置。
    func beginWebLogin() -> URL? {
        guard !trimmedClientID.isEmpty, !trimmedClientSecret.isEmpty else {
            authError = "请先填入 Client ID 和 Client Secret（OAuth App 设置页可见，Secret 只存本机 Keychain）"
            return nil
        }
        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomState()
        codeVerifier = verifier
        webState = state
        var comps = URLComponents(string: "https://github.com/login/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "redirect_uri", value: Self.webCallbackURL),
            URLQueryItem(name: "scope", value: "repo workflow read:user"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else {
            authError = "构造授权地址失败"
            return nil
        }
        isAuthenticating = true
        authError = nil
        return url
    }

    /// 取消一次网页登录（关闭内嵌登录页 / 取消系统浏览器登录时调用）。
    func cancelWebLogin() {
        codeVerifier = nil
        webState = nil
        isAuthenticating = false
    }

    /// 处理授权回调：校验 state 与错误，提取 code 换 token。
    /// 系统浏览器登录与 App 内嵌登录页共用。
    func completeWebLogin(callbackURL: URL) async {
        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            authError = "未收到 GitHub 回调"
            isAuthenticating = false
            return
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            authError = err == "access_denied" ? "你已拒绝授权" : "GitHub 返回错误：\(err)"
            isAuthenticating = false
            UTLog.error("GitHub 网页登录失败：\(err)", category: "GitHub")
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == webState else {
            authError = "回调校验失败（state 不一致），已中止登录"
            isAuthenticating = false
            return
        }
        await exchangeCodeForToken(code: code)
    }

    /// 网页登录：跳 GitHub 网页输账号密码授权，授权后自动跳回 App 内换 token。
    /// 需要 Client ID + Client Secret（GitHub 换 token 强制要求 Secret，PKCE 也省不掉）。
    func startWebFlow() {
        guard let url = beginWebLogin() else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.webCallbackScheme) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.webAuthSession = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.cancelWebLogin()
                    return
                }
                if let error {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                    UTLog.error("GitHub 网页登录失败：\(error.localizedDescription)", category: "GitHub")
                    return
                }
                guard let callbackURL else {
                    self.authError = "未收到 GitHub 回调"
                    self.isAuthenticating = false
                    return
                }
                await self.completeWebLogin(callbackURL: callbackURL)
            }
        }
        session.presentationContextProvider = webAuthPresentation
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        if !session.start() {
            cancelWebLogin()
            authError = "无法打开登录页"
            webAuthSession = nil
        }
    }

    /// 授权码换 token（带 client_secret + code_verifier），成功后调 /user 核对身份再存 Keychain。
    private func exchangeCodeForToken(code: String) async {
        guard let verifier = codeVerifier else {
            authError = "登录状态丢失，请重试"
            isAuthenticating = false
            return
        }
        do {
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = [
                "client_id": trimmedClientID,
                "client_secret": trimmedClientSecret,
                "code": code,
                "redirect_uri": Self.webCallbackURL,
                "code_verifier": verifier,
            ].map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "换 token 失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）"])
            }
            let tokenResp = try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
            guard let token = tokenResp.access_token else {
                throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: tokenResp.error_description ?? tokenResp.error ?? "换 token 失败"])
            }
            // 核对身份，防止账号混淆
            var userReq = URLRequest(url: URL(string: "https://api.github.com/user")!)
            userReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            userReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (_, userResp) = try await URLSession.shared.data(for: userReq)
            guard (userResp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "Token 校验失败"])
            }
            codeVerifier = nil
            webState = nil
            saveToken(token)
            isAuthenticating = false
            UTLog.success("GitHub 网页登录成功（Token 已存入 Keychain）", category: "GitHub")
        } catch {
            authError = error.localizedDescription
            isAuthenticating = false
            UTLog.error("GitHub 网页登录失败：\(error.localizedDescription)", category: "GitHub")
        }
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// PKCE code_verifier：32 字节随机 → 43 字符 base64url（无 padding）。
    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PKCE code_challenge：base64url(SHA-256(verifier))，无 padding。
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 防 CSRF 的随机 state。
    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 备用路径：Personal Access Token 登录（先用 token 调 /user 验证有效性）。
    func loginWithPAT(_ pat: String) async -> Bool {
        let token = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                authError = "Token 无效（请检查 Token 是否正确、是否过期）"
                return false
            }
            saveToken(token)
            return true
        } catch {
            authError = error.localizedDescription
            return false
        }
    }

    /// 退出登录：只删本地 Token；撤销授权请到 github.com/settings/applications 操作（Device Flow 公开客户端无 Secret，无法程序内撤销）。
    func logout() {
        KeychainHelper.delete(account: tokenAccount)
        isLoggedIn = false
        UTLog.info("已退出 GitHub 登录（本地 Token 已删除）", category: "GitHub")
    }

    func openVerificationPage() {
        if let url = verificationURL {
            UIApplication.shared.open(url)
        }
    }
}

/// ASWebAuthenticationSession 的展示锚点（单独类：@MainActor 类不能直接遵循该协议）。
private final class WebAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
