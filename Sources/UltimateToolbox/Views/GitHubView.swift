import SwiftUI

/// GitHub 页：官方 OAuth Device Flow 登录 + 网页登录（ASWebAuthenticationSession）+ PAT 备用 → 个人信息、仓库、Issues、PR、Releases、Actions。

struct GitHubView: View {
    @StateObject private var auth = GitHubAuthService.shared
    @StateObject private var api = GitHubAPIService.shared
    @State private var patText = ""
    @State private var showPAT = false
    @State private var selectedTab = 0
    @State private var selectedRepo: GHRepo?
    @State private var showLogoutConfirm = false

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                loginView
            } else {
                loggedInView
            }
        }
        .navigationTitle(L10n.github)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 登录

    private var loginView: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("GitHub 登录", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.headline)
                        Text("使用官方 OAuth Device Flow 登录，不让 App 接触你的密码。Token 只存本机 Keychain，不上传任何第三方服务器。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("第一步：填入 OAuth App Client ID").font(.headline)
                        Text("在 github.com/settings/developers 新建一个 OAuth App（免费），回调地址填 com.hmk849.ultimatetoolbox://oauth/github，把 Client ID 复制到这里。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Client ID（如 Ov23li…）", text: $auth.clientID)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if auth.isAuthenticating, let code = auth.userCode, let url = auth.verificationURL {
                            VStack(spacing: 8) {
                                Text("验证码")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(code)
                                    .font(.title2).fontWeight(.bold)
                                    .textSelection(.enabled)
                                Button("在浏览器打开验证页") { auth.openVerificationPage() }
                                    .buttonStyle(.borderedProminent)
                                Text("正在等待你在浏览器完成授权…（\(url.host ?? "")）")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("取消登录", role: .destructive) { auth.cancelDeviceFlow() }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                        } else {
                            Button("开始 OAuth 登录") {
                                Task { await auth.startDeviceFlow() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(auth.clientID.isEmpty)
                        }
                        if let err = auth.authError {
                            Text(err).foregroundStyle(.red).font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("网页登录（跳转 GitHub 网页）").font(.headline)
                        Text("点一下跳到 GitHub 登录页输账号密码，授权后自动跳回 App 内。OAuth App 的回调地址须为 com.hmk849.ultimatetoolbox://oauth/github；Client Secret 从 OAuth App 设置页复制（只存本机 Keychain，GitHub 换 token 时强制要求）。")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Client Secret", text: $auth.clientSecret)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button("用网页登录 GitHub") {
                            auth.startWebFlow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(auth.clientID.isEmpty || auth.clientSecret.isEmpty || auth.isAuthenticating)
                        if auth.isAuthenticating {
                            Text("正在等待网页授权…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("备用：Personal Access Token").font(.headline)
                        Text("在 github.com/settings/tokens 生成 Token（classic 或 fine-grained，需 repo / workflow / read:user 权限），粘贴登录。")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("粘贴 Token（ghp_… / github_pat_…）", text: $patText)
                            .textFieldStyle(.roundedBorder)
                        Button("用 Token 登录") {
                            Task {
                                if await auth.loginWithPAT(patText) { patText = "" }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(patText.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("权限说明：登录只请求 repo / workflow / read:user。私有仓库信息只有在你授权该 scope 后才能访问；退出登录会删除本地 Token，撤销授权请到 github.com/settings/applications 操作。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding()
        }
    }

    // MARK: - 已登录

    private var loggedInView: some View {
        List {
            if let user = api.user {
                Section("个人信息") {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: user.avatar_url ?? "")) { image in
                            image.resizable()
                        } placeholder: {
                            Image(systemName: "person.circle.fill").font(.largeTitle)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name ?? user.login).font(.headline)
                            Text("@\(user.login)").font(.subheadline).foregroundStyle(.secondary)
                            if let bio = user.bio { Text(bio).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let blog = user.blog, !blog.isEmpty {
                        Link("个人主页：\(blog)", destination: URL(string: blog.hasPrefix("http") ? blog : "https://\(blog)")!)
                    }
                    if let email = user.email { Text("公开邮箱：\(email)") }
                    if let created = user.created_at { Text("注册时间：\(created)") }
                    HStack(spacing: 20) {
                        statItem("\(user.public_repos ?? 0)", label: "公开仓库")
                        statItem("\(user.followers ?? 0)", label: "Followers")
                        statItem("\(user.following ?? 0)", label: "Following")
                        statItem("\(user.public_gists ?? 0)", label: "Gist")
                    }
                }
            }
            Picker("内容", selection: $selectedTab) {
                Text("仓库").tag(0)
                Text("Issues").tag(1)
                Text("PR").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if selectedTab == 0 {
                Section("仓库（\(api.repos.count)）") {
                    ForEach(api.repos) { repo in
                        Button {
                            selectedRepo = repo
                            Task {
                                await api.loadReleases(repoFullName: repo.full_name)
                                await api.loadActionRuns(repoFullName: repo.full_name)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(repo.name).font(.subheadline).fontWeight(.medium)
                                    if repo.private == true {
                                        Text("私有").font(.caption)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.orange.opacity(0.2), in: Capsule())
                                    }
                                    Spacer()
                                    Text("★ \(repo.stargazers_count ?? 0)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let desc = repo.description { Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                HStack(spacing: 12) {
                                    if let lang = repo.language { Text(lang).font(.caption).foregroundStyle(.secondary) }
                                    Text("Fork \(repo.forks_count ?? 0)").font(.caption).foregroundStyle(.secondary)
                                    if let updated = repo.updated_at { Text(updated).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                if let repo = selectedRepo {
                    Section("Releases · \(repo.name)") {
                        if api.releases.isEmpty {
                            Text("该仓库暂无 Release").foregroundStyle(.secondary)
                        }
                        ForEach(api.releases) { rel in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rel.tag_name).font(.subheadline).fontWeight(.medium)
                                if let name = rel.name { Text(name).font(.caption).foregroundStyle(.secondary) }
                                if let published = rel.published_at { Text(published).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Actions · \(repo.name)") {
                        if api.actionRuns.isEmpty {
                            Text("暂无工作流运行记录").foregroundStyle(.secondary)
                        }
                        ForEach(api.actionRuns) { run in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.name ?? "workflow").font(.subheadline)
                                    Text("\(run.head_branch ?? "") · \(run.created_at ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(run.conclusion ?? run.status ?? "")
                                    .font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(run.conclusion == "success" ? .green : run.conclusion == "failure" ? .red : .secondary)
                            }
                        }
                    }
                }
            } else if selectedTab == 1 {
                Section("Issues（\(api.issues.count)）") {
                    if api.issues.isEmpty {
                        Text("暂无待处理 Issue").foregroundStyle(.secondary)
                    }
                    ForEach(api.issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(issue.number) \(issue.title)").font(.subheadline)
                            Text(issue.state ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section("Pull Requests（\(api.pullRequests.count)）") {
                    if api.pullRequests.isEmpty {
                        Text("暂无 Pull Request").foregroundStyle(.secondary)
                    }
                    ForEach(api.pullRequests) { pr in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(pr.number) \(pr.title)").font(.subheadline)
                            Text(pr.state ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("退出登录", role: .destructive) { showLogoutConfirm = true }
            }
        }
        .alert("退出登录？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                auth.logout()
                api.clear()
            }
        } message: {
            Text("将删除本机 Keychain 中的 Token。撤销授权请到 github.com/settings/applications 操作。")
        }
        .refreshable {
            await api.loadProfile()
            await api.loadRepos()
            await api.loadIssues()
            await api.loadPullRequests()
        }
        .task {
            if api.user == nil { await api.loadProfile() }
            if api.repos.isEmpty { await api.loadRepos() }
            if api.issues.isEmpty { await api.loadIssues() }
            if api.pullRequests.isEmpty { await api.loadPullRequests() }
        }
        .alert("GitHub", isPresented: Binding(
            get: { api.errorMessage != nil },
            set: { if !$0 { api.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(api.errorMessage ?? "")
        }
    }

    private func statItem(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
