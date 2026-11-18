import Foundation

/// GitHub API（最小权限：Device Flow scope 为 repo / workflow / read:user）。
/// 个人信息、仓库、Issues、PR、Releases、Actions、提交记录。

struct GHUser: Decodable, Identifiable {
    let login: String
    let id: Int
    let avatar_url: String?
    let name: String?
    let bio: String?
    let blog: String?
    let html_url: String?
    let created_at: String?
    let email: String?
    let public_repos: Int?
    let followers: Int?
    let following: Int?
    let public_gists: Int?
}

struct GHRepo: Decodable, Identifiable {
    let id: Int
    let name: String
    let full_name: String
    let description: String?
    let stargazers_count: Int?
    let forks_count: Int?
    let language: String?
    let updated_at: String?
    let default_branch: String?
    let html_url: String?
    let `private`: Bool?
}

struct GHIssue: Decodable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let state: String?
    let html_url: String?
    let created_at: String?
    let pull_request: GHPRRef?
    struct GHPRRef: Decodable {}
}

struct GHRelease: Decodable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let html_url: String?
    let published_at: String?
    let draft: Bool?
    let prerelease: Bool?
}

struct GHActionRun: Decodable, Identifiable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let html_url: String?
    let created_at: String?
    let head_branch: String?
}

struct GHActionRunsResponse: Decodable {
    let workflow_runs: [GHActionRun]
}

struct GHSearchIssuesResponse: Decodable {
    let total_count: Int
    let items: [GHIssue]
}

@MainActor
final class GitHubAPIService: ObservableObject {
    static let shared = GitHubAPIService()

    @Published private(set) var user: GHUser?
    @Published private(set) var repos: [GHRepo] = []
    @Published private(set) var issues: [GHIssue] = []
    @Published private(set) var pullRequests: [GHIssue] = []
    @Published private(set) var releases: [GHRelease] = []
    @Published private(set) var actionRuns: [GHActionRun] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private func request(_ path: String) async throws -> Data {
        guard let token = GitHubAuthService.shared.token else {
            throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        var req = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("UltimateToolbox-iOS", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "网络请求失败"])
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NSError(domain: "GitHub", code: 401, userInfo: [NSLocalizedDescriptionKey: "Token 无效或已过期，请重新登录"]) }
            if http.statusCode == 403 { throw NSError(domain: "GitHub", code: 403, userInfo: [NSLocalizedDescriptionKey: "API 限流或权限不足（HTTP 403）"]) }
            throw NSError(domain: "GitHub", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub API 错误（HTTP \(http.statusCode)）"])
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await request(path)
        return try JSONDecoder().decode(type, from: data)
    }

    func loadProfile() async {
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await decode(GHUser.self, path: "/user")
            UTLog.info("GitHub 个人信息已加载：@\(user?.login ?? "")", category: "GitHub")
        } catch {
            errorMessage = error.localizedDescription
            UTLog.error("GitHub 个人信息加载失败：\(error.localizedDescription)", category: "GitHub")
        }
    }

    func loadRepos() async {
        isLoading = true
        defer { isLoading = false }
        do {
            repos = try await decode([GHRepo].self, path: "/user/repos?per_page=100&sort=updated")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadIssues() async {
        isLoading = true
        defer { isLoading = false }
        do {
            issues = try await decode([GHIssue].self, path: "/user/issues?state=open&per_page=50")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPullRequests() async {
        guard let login = user?.login else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await decode(GHSearchIssuesResponse.self, path: "/search/issues?q=author:\(login)+type:pr&per_page=30")
            pullRequests = resp.items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadReleases(repoFullName: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            releases = try await decode([GHRelease].self, path: "/repos/\(repoFullName)/releases?per_page=20")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadActionRuns(repoFullName: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await decode(GHActionRunsResponse.self, path: "/repos/\(repoFullName)/actions/runs?per_page=20")
            actionRuns = resp.workflow_runs
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        user = nil
        repos = []
        issues = []
        pullRequests = []
        releases = []
        actionRuns = []
        errorMessage = nil
    }
}
