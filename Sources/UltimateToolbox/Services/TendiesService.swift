import Foundation

/// .tendies 动态壁纸：导入安装 + GitHub 壁纸库。
/// 引擎已实现 BQApplyTendies（解包、写 PosterBoard 描述符、刷新偏好、失败回滚），这里只做 Swift 封装与界面状态。
/// 壁纸库用 GitHub Contents API 列 CAPlayground/wallpapers（288 个 .tendies，公开仓库，无需登录 GitHub）。

struct TendiesPack: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: Int64
    let downloadURL: URL
    var displayName: String { (name as NSString).deletingPathExtension }
}

@MainActor
final class TendiesService: ObservableObject {
    static let shared = TendiesService()

    @Published private(set) var packs: [TendiesPack] = []
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var isApplying = false
    @Published private(set) var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published private(set) var status: String = "未安装"
    @Published var searchText = ""

    /// GitHub Contents API（公开仓库，无需登录；未登录每小时限 60 次）。
    static let libraryAPI = URL(string: "https://api.github.com/repos/CAPlayground/wallpapers/contents/wallpapers")!

    var filteredPacks: [TendiesPack] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return packs }
        return packs.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - 壁纸库

    func fetchLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        status = "正在加载壁纸库…"
        defer { isLoadingLibrary = false }
        do {
            var req = URLRequest(url: Self.libraryAPI)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 403 {
                status = "GitHub API 限流（未登录每小时 60 次），稍后再试"
                UTLog.warning("壁纸库加载失败：GitHub API 403 限流", category: "交互壁纸")
                return
            }
            guard http.statusCode == 200 else {
                status = "壁纸库加载失败（HTTP \(http.statusCode)）"
                return
            }
            struct Entry: Decodable { let name: String; let size: Int64; let download_url: URL?; let type: String }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            let list = entries
                .filter { $0.type == "file" && $0.name.hasSuffix(".tendies") }
                .compactMap { e -> TendiesPack? in
                    guard let url = e.download_url else { return nil }
                    return TendiesPack(name: e.name, size: e.size, downloadURL: url)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            packs = list
            status = "壁纸库：\(list.count) 个壁纸（CAPlayground/wallpapers）"
            UTLog.info("壁纸库加载完成：\(list.count) 个", category: "交互壁纸")
        } catch {
            status = "壁纸库加载失败：\(error.localizedDescription)"
            UTLog.error("壁纸库加载失败：\(error.localizedDescription)", category: "交互壁纸")
        }
    }

    // MARK: - 下载并安装

    func downloadAndApply(_ pack: TendiesPack) async {
        guard !isDownloading, !isApplying else { return }
        isDownloading = true
        downloadProgress = 0
        status = "正在下载 \(pack.displayName)…"
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(pack.name)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            try await downloadWithProgress(from: pack.downloadURL, to: tmp)
            isDownloading = false
            await applyTendies(at: tmp, label: pack.displayName)
        } catch {
            isDownloading = false
            status = "下载失败：\(error.localizedDescription)"
            UTLog.error("壁纸下载失败：\(error.localizedDescription)", category: "交互壁纸")
        }
    }

    /// 流式下载到临时文件并上报进度。
    private func downloadWithProgress(from url: URL, to dest: URL) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        let total = resp.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else { throw URLError(.cannotCreateFile) }
        defer { try? handle.close() }
        var written: Int64 = 0
        for try await chunk in bytes {
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            if total > 0 { downloadProgress = Double(written) / Double(total) }
        }
    }

    // MARK: - 安装

    /// 导入用户挑选的文件（Files 里的安全作用域 URL）：先拷到临时目录再安装。
    func importPickedFile(_ url: URL) async {
        guard !isApplying else { return }
        guard url.startAccessingSecurityScopedResource() else {
            status = "无法读取该文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            status = "复制文件失败：\(error.localizedDescription)"
            return
        }
        await applyTendies(at: tmp, label: url.deletingPathExtension().lastPathComponent)
    }

    func applyTendies(at fileURL: URL, label: String) async {
        guard !isApplying else { return }
        isApplying = true
        status = "正在安装 \(label)…"
        let result = await runApply(url: fileURL)
        isApplying = false
        switch result {
        case .success(let count):
            status = "已安装 \(label)（\(count) 个描述符），去墙纸设置里挑选"
            UTLog.success("壁纸已安装：\(label)，\(count) 个描述符", category: "交互壁纸")
        case .failure(let message):
            status = "安装失败：\(message)"
            UTLog.error("壁纸安装失败：\(message)", category: "交互壁纸")
        }
    }

    /// BQApplyTendies 是阻塞调用（解包最大 128MB），放后台线程跑。
    private func runApply(url: URL) async -> Result<Int, String> {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var count: CInt = 0
                var err: NSString?
                let ok = BQApplyTendies(url as NSURL, &count, &err)
                if ok {
                    c.resume(returning: .success(Int(count)))
                } else {
                    c.resume(returning: .failure(err as String? ?? "安装失败"))
                }
            }
        }
    }

    /// 重置 PosterBoard：删除已导入的壁纸描述符（系统自带壁纸不受影响）。
    /// 引擎安装失败且回滚不完整时，错误信息会提示先重置再重试。
    func resetPosterBoard() async {
        let result: Result<Void, String> = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSString?
                let ok = BQResetPosterBoard(&err)
                if ok {
                    c.resume(returning: .success(()))
                } else {
                    c.resume(returning: .failure(err as String? ?? "重置失败"))
                }
            }
        }
        switch result {
        case .success:
            status = "PosterBoard 已重置（已删导入的描述符）"
            UTLog.success("PosterBoard 已重置", category: "交互壁纸")
        case .failure(let message):
            status = "重置失败：\(message)"
            UTLog.error("PosterBoard 重置失败：\(message)", category: "交互壁纸")
        }
    }

    /// 打开系统墙纸设置（PosterBoard），安装后去那里挑选壁纸。
    func openPosterBoard() {
        if !BQOpenPosterBoard() {
            status = "无法打开墙纸设置，请手动去设置 → 墙纸挑选"
        }
    }
}
