import Foundation
import UIKit

/// GitHub 登录：官方 OAuth Device Flow（无需在 App 内嵌 Client Secret，不让用户填密码）。
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

    private let tokenAccount = "github.token"
    private var deviceFlowTask: Task<Void, Never>?

    init() {
        clientID = UserDefaults.standard.string(forKey: "ut.github.clientID") ?? ""
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
        guard !clientID.isEmpty else {
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
            req.httpBody = "client_id=\(clientID)&scope=repo%20workflow%20read%3Auser".data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "请求 device_code 失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）"])
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
                req.httpBody = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)
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
