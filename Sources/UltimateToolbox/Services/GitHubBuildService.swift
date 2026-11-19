import Foundation

/// 一键 GitHub 云编译：workflow_dispatch 触发 hmk849/ultimate-toolbox 的 Build UltimateToolbox IPA，
/// 随后轮询运行状态，直到完成。需要 GitHub 登录，Token 须有 repo / workflow 权限（登录时已申请）。
/// 产物在构建页 Artifacts 里下载（需登录 GitHub）；Release 仍由人工在 Release 页发布。

enum BuildPhase: Equatable {
    case idle
    case dispatching
    case queued
    case running
    case succeeded
    case failed
}

@MainActor
final class GitHubBuildService: ObservableObject {
    static let shared = GitHubBuildService()

    static let repo = "hmk849/ultimate-toolbox"
    static let workflowFile = "build-ipa.yml"

    @Published private(set) var phase: BuildPhase = .idle
    @Published private(set) var statusText: String = "未开始"
    @Published private(set) var runURL: URL?
    @Published private(set) var errorMessage: String?

    private var pollTask: Task<Void, Never>?

    var isBusy: Bool {
        phase == .dispatching || phase == .queued || phase == .running
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func triggerBuild() async {
        guard let token = GitHubAuthService.shared.token else {
            errorMessage = "请先到 GitHub 页登录"
            statusText = "未登录"
            return
        }
        guard !isBusy else { return }
        pollTask?.cancel()
        phase = .dispatching
        statusText = "正在触发编译…"
        errorMessage = nil
        runURL = nil
        let dispatchTime = Date()
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/actions/workflows/\(Self.workflowFile)/dispatches")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("UltimateToolbox-iOS", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["ref": "main"])
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 204 else {
                if code == 401 { throw NSError(domain: "GitHub", code: 401, userInfo: [NSLocalizedDescriptionKey: "Token 无效或已过期，请重新登录"]) }
                if code == 403 { throw NSError(domain: "GitHub", code: 403, userInfo: [NSLocalizedDescriptionKey: "Token 权限不足（需要 repo / workflow 权限），请重新登录授权"]) }
                if code == 404 { throw NSError(domain: "GitHub", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到编译工作流（仓库或 workflow 文件名已变）"]) }
                throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: "触发编译失败（HTTP \(code)）"])
            }
            UTLog.info("一键编译已触发（workflow_dispatch，main 分支）", category: "GitHub")
            phase = .queued
            statusText = "已触发，等待 Runner 接单…"
            pollTask = Task { await self.pollRuns(since: dispatchTime) }
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
            statusText = "触发失败"
            UTLog.error("一键编译触发失败：\(error.localizedDescription)", category: "GitHub")
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if isBusy {
            phase = .idle
            statusText = "已取消"
        }
    }

    private func pollRuns(since dispatchTime: Date) async {
        // 最长轮询约 20 分钟（云编译通常 3–8 分钟，含排队）。
        let deadline = Date().addingTimeInterval(20 * 60)
        let earliest = dispatchTime.addingTimeInterval(-10)
        while Date() < deadline {
            if Task.isCancelled { return }
            do {
                guard let token = GitHubAuthService.shared.token else {
                    phase = .failed
                    errorMessage = "登录已失效，请重新登录"
                    statusText = "登录失效"
                    return
                }
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/actions/workflows/\(Self.workflowFile)/runs?per_page=5")!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("UltimateToolbox-iOS", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "查询构建状态失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）"])
                }
                let runs = try JSONDecoder().decode(GHActionRunsResponse.self, from: data).workflow_runs
                if let run = runs.first(where: { run in
                    guard run.head_branch == "main",
                          let created = run.created_at,
                          let date = Self.isoFormatter.date(from: created) else { return false }
                    return date >= earliest
                }) {
                    if let urlString = run.html_url, let url = URL(string: urlString) {
                        runURL = url
                    }
                    switch run.status {
                    case "completed":
                        if run.conclusion == "success" {
                            phase = .succeeded
                            statusText = "编译成功"
                            UTLog.success("一键编译完成：构建成功", category: "GitHub")
                        } else {
                            phase = .failed
                            statusText = "编译失败"
                            errorMessage = "构建结论：\(run.conclusion ?? "未知")，请在构建页查看日志"
                            UTLog.error("一键编译完成：构建失败（\(run.conclusion ?? "未知")）", category: "GitHub")
                        }
                        return
                    case "in_progress":
                        phase = .running
                        statusText = "正在编译…"
                    case "waiting":
                        phase = .queued
                        statusText = "等待 Runner…"
                    default:
                        phase = .queued
                        statusText = "排队中…"
                    }
                } else {
                    statusText = "已触发，正在查找运行记录…"
                }
            } catch {
                // 网络抖动：继续轮询，不直接判失败
                statusText = "网络波动，重试查询中…"
            }
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
        phase = .failed
        errorMessage = "轮询超时（20 分钟），请到 GitHub Actions 页查看构建状态"
        statusText = "查询超时"
    }
}
