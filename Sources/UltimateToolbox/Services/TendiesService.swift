import Foundation

/// .tendies 动态壁纸：导入安装 + GitHub 壁纸库。
/// 引擎已实现 BQApplyTendies（解包、写 PosterBoard 描述符、刷新偏好、失败回滚），这里只做 Swift 封装与界面状态。
/// 壁纸库首选仓库根目录 wallpapers.json（名字 + previews/gif/*.gif 预览图，raw 直链不走 API 限流），
/// 大小从 Contents API 补；任一失败都退回只用 Contents API 列表（无预览图）。

struct TendiesPack: Identifiable, Equatable {
    let id = UUID()
    /// 展示名：优先用 wallpapers.json 里的 name（带空格，如 "11037 Case 1"），没有则用文件名。
    let name: String
    /// 大小（Contents API 给；只用 wallpapers.json 时可能没有）。
    let size: Int64?
    let downloadURL: URL
    /// 预览图（wallpapers.json 的 preview，仓库 previews/gif/*.gif，raw 直链；没有为 nil）。
    let previewURL: URL?
    var displayName: String { (name as NSString).deletingPathExtension }
}

/// 壁纸操作失败的原因（Result 的 Failure 必须是 Error，不能直接用 String）。
enum TendiesError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
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
    /// 壁纸库元数据（仓库根目录 wallpapers.json，raw 直链，不走 API 限流）。
    static let libraryJSON = URL(string: "https://raw.githubusercontent.com/CAPlayground/wallpapers/refs/heads/main/wallpapers.json")!

    /// wallpapers.json 的结构：base_url + 每条的名字、文件路径、预览图路径。
    private struct WallpaperJSON: Decodable {
        let base_url: String
        let wallpapers: [WallpaperJSONEntry]
    }
    private struct WallpaperJSONEntry: Decodable {
        let name: String
        let file: String
        let preview: String?
    }
    private struct ContentsEntry: Decodable {
        let name: String
        let size: Int64
        let download_url: URL?
        let type: String
    }

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
        // 名字 + 预览图走 wallpapers.json，大小 + 下载地址走 Contents API，两边按文件名合并；
        // JSON 失败退回只用 Contents 列表（无预览图），Contents 失败则只有 JSON 的数据（无大小）。
        let json = try? await fetchLibraryJSON()
        let contents = try? await fetchContentsList()
        if let json {
            let base = json.base_url
            let sizeByFile = Dictionary(uniqueKeysWithValues: (contents ?? []).map { ($0.name, $0.size) })
            var list: [TendiesPack] = json.wallpapers.compactMap { e in
                let fileName = (e.file as NSString).lastPathComponent
                guard let downloadURL = URL(string: base + e.file) else { return nil }
                let previewURL = e.preview.flatMap { URL(string: base + $0) }
                return TendiesPack(name: e.name, size: sizeByFile[fileName], downloadURL: downloadURL, previewURL: previewURL)
            }
            // JSON 里没有的新文件也补上（只有 Contents 列表里有、无预览图）。
            if let contents {
                let known = Set(json.wallpapers.map { ($0.file as NSString).lastPathComponent })
                for c in contents where c.type == "file" && c.name.hasSuffix(".tendies") && !known.contains(c.name) {
                    guard let url = c.download_url else { continue }
                    list.append(TendiesPack(name: c.name, size: c.size, downloadURL: url, previewURL: nil))
                }
            }
            packs = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            status = "壁纸库已加载（\(packs.count) 个）"
            UTLog.info("壁纸库已加载：\(packs.count) 个", category: "交互壁纸")
        } else if let contents {
            packs = contents
                .filter { $0.type == "file" && $0.name.hasSuffix(".tendies") }
                .compactMap { e -> TendiesPack? in
                    guard let url = e.download_url else { return nil }
                    return TendiesPack(name: e.name, size: e.size, downloadURL: url, previewURL: nil)
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            status = "壁纸库已加载（\(packs.count) 个，预览图暂不可用）"
            UTLog.info("壁纸库已加载（仅 Contents 列表）：\(packs.count) 个", category: "交互壁纸")
        } else {
            status = "壁纸库加载失败，请检查网络后点刷新"
            UTLog.error("壁纸库加载失败：JSON 与 Contents API 都不可用", category: "交互壁纸")
        }
    }

    private func fetchLibraryJSON() async throws -> WallpaperJSON {
        let (data, resp) = try await URLSession.shared.data(from: Self.libraryJSON)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(WallpaperJSON.self, from: data)
    }

    private func fetchContentsList() async throws -> [ContentsEntry] {
        var req = URLRequest(url: Self.libraryAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([ContentsEntry].self, from: data)
    }

    // MARK: - 下载并安装

    func downloadAndApply(_ pack: TendiesPack) async {
        guard !isDownloading, !isApplying else { return }
        isDownloading = true
        downloadProgress = 0
        status = "正在下载 \(pack.displayName)…"
        do {
            // 临时文件名用下载地址里的真实文件名（含 .tendies 后缀），pack.name 现在是展示名（可能没后缀）。
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(pack.downloadURL.lastPathComponent)
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

    /// 流式下载到临时文件并上报进度（URLSessionDownloadDelegate）。
    /// 注意：URLSession.shared.bytes 是逐字节（UInt8）的 AsyncBytes，不适合直接写文件，改用下载任务。
    private func downloadWithProgress(from url: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let delegate = TendiesDownloadDelegate(destination: dest) { [weak self] p in
                Task { @MainActor in self?.downloadProgress = p }
            } onComplete: { result in
                switch result {
                case .success: c.resume()
                case .failure(let error): c.resume(throwing: error)
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
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
        case .failure(let error):
            status = "安装失败：\(error.localizedDescription)"
            UTLog.error("壁纸安装失败：\(error.localizedDescription)", category: "交互壁纸")
        }
    }

    /// BQApplyTendies 是阻塞调用（解包最大 128MB），放后台线程跑。
    private func runApply(url: URL) async -> Result<Int, TendiesError> {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var count: CInt = 0
                var err: NSString?
                let ok = BQApplyTendies(url, &count, &err)
                if ok {
                    c.resume(returning: .success(Int(count)))
                } else {
                    c.resume(returning: .failure(.message(err as String? ?? "安装失败")))
                }
            }
        }
    }

    /// 重置 PosterBoard：删除已导入的壁纸描述符（系统自带壁纸不受影响）。
    /// 引擎安装失败且回滚不完整时，错误信息会提示先重置再重试。
    func resetPosterBoard() async {
        let result: Result<Void, TendiesError> = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSString?
                let ok = BQResetPosterBoard(&err)
                if ok {
                    c.resume(returning: .success(()))
                } else {
                    c.resume(returning: .failure(.message(err as String? ?? "重置失败")))
                }
            }
        }
        switch result {
        case .success:
            status = "PosterBoard 已重置（已删导入的描述符）"
            UTLog.success("PosterBoard 已重置", category: "交互壁纸")
        case .failure(let error):
            status = "重置失败：\(error.localizedDescription)"
            UTLog.error("PosterBoard 重置失败：\(error.localizedDescription)", category: "交互壁纸")
        }
    }

    /// 打开系统墙纸设置（PosterBoard），安装后去那里挑选壁纸。
    func openPosterBoard() {
        if !BQOpenPosterBoard() {
            status = "无法打开墙纸设置，请手动去设置 → 墙纸挑选"
        }
    }
}

/// 带进度的下载任务代理：下完把系统临时文件移到目标位置，失败只回调一次。
/// 回调都在 session 的串行代理队列上跑，finished 标志只在该队列上读写。
private final class TendiesDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress: (Double) -> Void
    let onComplete: (Result<Void, Error>) -> Void
    var session: URLSession?
    private var finished = false

    init(destination: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        onComplete(result)
    }
}
