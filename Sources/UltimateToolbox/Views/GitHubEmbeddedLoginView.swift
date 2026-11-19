import SwiftUI
import WebKit

/// App 内嵌 GitHub 登录页：WKWebView 打开 GitHub 自己的登录页输账号密码，不跳出 App。
/// 密码只在 GitHub 页面输入，App 代码不接触密码；授权后拦截回调地址取 code 换 token。
/// 注意：GitHub 自 2020 年起不再支持账号密码直接调 API，原生账号密码框换不到 Token，
/// 所以账号密码只能在 GitHub 自己的登录页输入——内嵌页与系统浏览器登录是同一套 OAuth 流程。

struct GitHubEmbeddedLoginView: View {
    @StateObject private var auth = GitHubAuthService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var authorizeURL: URL?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if let url = authorizeURL {
                    GitHubLoginWebView(url: url) { callbackURL in
                        Task { @MainActor in
                            await auth.completeWebLogin(callbackURL: callbackURL)
                            if auth.isLoggedIn {
                                dismiss()
                            } else {
                                showError = true
                            }
                        }
                    }
                } else {
                    ProgressView("正在打开登录页…")
                }
            }
            .navigationTitle("GitHub 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        auth.cancelWebLogin()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if authorizeURL == nil {
                    authorizeURL = auth.beginWebLogin()
                    if authorizeURL == nil { showError = true }
                }
            }
            .alert("登录失败", isPresented: $showError) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text(auth.authError ?? "无法打开登录页")
            }
        }
    }
}

/// WKWebView 包装：加载 GitHub 授权页，拦截回调 scheme（com.hmk849.ultimatetoolbox://oauth/github）。
private struct GitHubLoginWebView: UIViewRepresentable {
    let url: URL
    let onCallback: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCallback: (URL) -> Void

        init(onCallback: @escaping (URL) -> Void) {
            self.onCallback = onCallback
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.scheme == GitHubAuthService.webCallbackScheme {
                onCallback(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
