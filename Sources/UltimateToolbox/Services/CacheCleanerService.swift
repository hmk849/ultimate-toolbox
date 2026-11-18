import Foundation

/// 缓存清理：真实扫描 + 真实删除 + 清后重算。
/// 范围：本 App 容器（Library/Caches、tmp）+ App Group 容器 +（逃逸可用时）其他 App 的 Caches/tmp/崩溃日志。
/// 逃逸不可用时跨 App 部分明确显示不可用，不伪造扫描结果。

enum CacheKind: String {
    case own = "本 App"
    case group = "App Group"
    case app = "其他 App"
    case crash = "崩溃日志"
}

struct CacheItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    /// 跨 App 时为容器路径；本 App/Group 时为空。
    let container: String?
    let kind: CacheKind
    let size: Int64
    var selected: Bool = true
}

@MainActor
final class CacheCleanerService: ObservableObject {
    static let shared = CacheCleanerService()

    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var progress: Double = 0
    @Published var status: String = "未扫描"

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter { $0.selected }.reduce(0) { $0 + $1.size } }

    func setSelected(id: UUID, value: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].selected = value
        }
    }

    func selectAll(_ value: Bool) {
        for i in items.indices { items[i].selected = value }
    }

    func selectLarge(threshold: Int64 = 100 * 1024 * 1024) {
        for i in items.indices {
            items[i].selected = items[i].size >= threshold
        }
    }

    private var scanTask: Task<Void, Never>?

    func cancelScan() { scanTask?.cancel() }

    func scan() {
        scanTask?.cancel()
        scanTask = Task { await performScan() }
    }

    private func performScan() async {
        isScanning = true
        progress = 0
        status = "正在扫描…"
        items = []
        var found: [CacheItem] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // 1. 本 App
        for sub in ["Library/Caches", "tmp"] {
            let p = (home as NSString).appendingPathComponent(sub)
            let size = Self.directorySize(p)
            if size > 0 {
                found.append(CacheItem(name: "本 App · \(sub)", path: p, container: nil, kind: .own, size: size))
            }
        }
        progress = 0.15
        status = "已扫描本 App 缓存"

        // 2. App Group
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.hmk849.ultimatetoolbox") {
            let caches = groupURL.appendingPathComponent("Library/Caches").path
            let size = Self.directorySize(caches)
            if size > 0 {
                found.append(CacheItem(name: "App Group · Library/Caches", path: caches, container: nil, kind: .group, size: size))
            }
        }
        progress = 0.25

        // 3. 跨 App（需要逃逸）
        let report = CompatibilityService.shared.report
        if report?.crossAppCache == .available {
            status = "正在扫描其他 App 缓存…"
            let cross = await scanCrossApp()
            found.append(contentsOf: cross)
            progress = 0.85
            let crash = await scanCrashLogs()
            found.append(contentsOf: crash)
        } else {
            UTLog.warning("跨 App 缓存扫描不可用：\(statusText(for: report?.crossAppCache))", category: "缓存清理")
        }

        items = found.sorted { $0.size > $1.size }
        progress = 1
        isScanning = false
        status = "扫描完成：\(items.count) 项，共 \(SystemInfoService.formatBytes(totalSize))"
        UTLog.info("缓存扫描完成：\(items.count) 项，共 \(SystemInfoService.formatBytes(totalSize))", category: "缓存清理")
    }

    private func statusText(for status: ModuleStatus?) -> String {
        switch status {
        case .available: return "可用"
        case .unavailable(let r): return r
        case .limited(let n): return n
        case .none: return "尚未检测"
        }
    }

    /// 跨 App：枚举应用数据容器，逐个计量 Library/Caches 与 tmp。
    private func scanCrossApp() async -> [CacheItem] {
        var out: [CacheItem] = []
        let roots = await EscapeService.shared.containerRoots()
        let appRoot = roots.first { $0.contains("Containers/Data/Application") } ?? roots.first ?? ""
        guard !appRoot.isEmpty else { return out }
        let containers = await EscapeService.shared.listContainers(root: appRoot)
        let total = max(containers.count, 1)
        for (i, container) in containers.enumerated() {
            if Task.isCancelled { break }
            let info = await EscapeService.shared.containerInfo(container)
            let bundleID = (info["MCMMetadataIdentifier"] as? String) ?? (container as NSString).lastPathComponent
            for sub in ["Library/Caches", "tmp"] {
                if let stat = await statInContainer(container, sub), stat.size > 0 {
                    out.append(CacheItem(name: "\(bundleID) · \(sub)", path: (container as NSString).appendingPathComponent(sub), container: container, kind: .app, size: stat.size))
                }
            }
            await MainActor.run { self.progress = 0.25 + 0.6 * Double(i + 1) / Double(total) }
        }
        return out
    }

    private func statInContainer(_ container: String, _ rel: String) async -> (isDir: Bool, size: Int64)? {
        // BQStatPath 只给单项大小；目录需要递归。先取根 stat，再对目录做逐层累加（用 BQListPath + BQStatPath）。
        await directorySizeInContainer(container, rel)
    }

    private func directorySizeInContainer(_ container: String, _ rel: String) async -> (isDir: Bool, size: Int64)? {
        guard let entries = try? await EscapeService.shared.listPath(container: container, rel: rel) else { return nil }
        var total: Int64 = 0
        for e in entries {
            if e.isDir {
                if let sub = await directorySizeInContainer(container, (rel as NSString).appendingPathComponent(e.name)) {
                    total += sub.size
                }
            } else {
                total += e.size
            }
            if Task.isCancelled { break }
        }
        return (true, total)
    }

    /// 崩溃日志（仅 iOS 27 + 逃逸可用）：/var/mobile/Library/Logs/CrashReporter。
    private func scanCrashLogs() async -> [CacheItem] {
        guard CompatibilityService.shared.iosMajor >= 27 else { return [] }
        let target = "/var/mobile/Library/Logs/CrashReporter"
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var link: NSString?
                let h = BQEscape(target, &link)
                guard h >= 0, let linkPath = link as String? else {
                    c.resume(returning: [])
                    return
                }
                let size = Self.directorySize(linkPath)
                BQEndEscape(h)
                if size > 0 {
                    c.resume(returning: [CacheItem(name: "崩溃日志", path: target, container: target, kind: .crash, size: size)])
                } else {
                    c.resume(returning: [])
                }
            }
        }
    }

    /// 真实清理：逐项删除，带进度；完成后重新扫描。
    func cleanSelected() async {
        let targets = items.filter { $0.selected }
        guard !targets.isEmpty else { return }
        isCleaning = true
        progress = 0
        var freed: Int64 = 0
        var failed = 0
        for (i, item) in targets.enumerated() {
            status = "正在清理 \(item.name)…"
            let ok = await deleteItem(item)
            if ok { freed += item.size } else { failed += 1 }
            progress = Double(i + 1) / Double(targets.count)
        }
        isCleaning = false
        UTLog.success("缓存清理完成：释放 \(SystemInfoService.formatBytes(freed))，失败 \(failed) 项", category: "缓存清理")
        status = "已释放 \(SystemInfoService.formatBytes(freed))，正在重新扫描…"
        await performScan()
    }

    private func deleteItem(_ item: CacheItem) async -> Bool {
        switch item.kind {
        case .own, .group:
            do {
                // 只清内容，保留目录本身
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(atPath: item.path)
                for name in contents {
                    try fm.removeItem(atPath: (item.path as NSString).appendingPathComponent(name))
                }
                return true
            } catch {
                UTLog.error("清理 \(item.name) 失败：\(error.localizedDescription)", category: "缓存清理")
                return false
            }
        case .app:
            guard let container = item.container else { return false }
            let rel = (item.path as NSString).lastPathComponent == "Caches" || (item.path as NSString).lastPathComponent == "tmp"
                ? String(item.path.dropFirst(container.count + 1)) : ""
            guard !rel.isEmpty else { return false }
            do {
                // 逐项删子内容（保留 Caches/tmp 目录本身）
                let entries = try await EscapeService.shared.listPath(container: container, rel: rel)
                var ok = true
                for e in entries {
                    do { try await EscapeService.shared.deletePath(container: container, rel: (rel as NSString).appendingPathComponent(e.name)) }
                    catch { ok = false }
                }
                return ok
            } catch {
                UTLog.error("清理 \(item.name) 失败：\(error.localizedDescription)", category: "缓存清理")
                return false
            }
        case .crash:
            return await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    var link: NSString?
                    let h = BQEscape(item.path, &link)
                    guard h >= 0, let linkPath = link as String? else { c.resume(returning: false); return }
                    var ok = true
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: linkPath) {
                        for name in contents {
                            do { try FileManager.default.removeItem(atPath: (linkPath as NSString).appendingPathComponent(name)) }
                            catch { ok = false }
                        }
                    }
                    BQEndEscape(h)
                    c.resume(returning: ok)
                }
            }
        }
    }

    /// 本地目录递归大小（符号链接不跟进，防止循环）。
    static func directorySize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(atPath: path) {
            for case let name as String in enumerator {
                let p = (path as NSString).appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   (attrs[.type] as? FileAttributeType) == .typeRegular {
                    total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
                }
            }
        }
        return total
    }
}
