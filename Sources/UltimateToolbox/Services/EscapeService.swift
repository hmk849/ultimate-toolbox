import Foundation

/// KAMUI BQCore（MIT）引擎的 Swift 封装。所有阻塞调用都在后台队列执行，绝不在主线程跑逃逸。

enum EscapeError: LocalizedError {
    case notInitialized
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notInitialized: return "逃逸引擎未初始化"
        case .failed(let m): return m
        }
    }
}

struct ContainerEntry: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let bundleID: String
    let displayName: String
}

struct PathEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let isDir: Bool
    let size: Int64
}

/// KAMUI BQCore（MIT）引擎的 Swift 封装。所有阻塞调用都在后台队列执行，绝不在主线程跑逃逸。
/// 用 actor 隔离共享可变状态（Swift 6 严格并发要求）。

actor EscapeService {
    static let shared = EscapeService()
    private let queue = DispatchQueue(label: "com.hmk849.ultimatetoolbox.escape", qos: .userInitiated)
    private(set) var initialized = false

    static let mobileGestaltCaches = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: work()) }
        }
    }

    /// 初始化引擎（建目录、加载 MCM、读 App Group）。返回引擎是否就绪。
    func initialize() async -> Bool {
        let ok = await run { BQCoreInit() }
        initialized = ok
        UTLog.info("逃逸引擎初始化：\(ok ? "就绪" : "失败")", category: "逃逸")
        return ok
    }

    /// 真实探测：尝试对 MobileGestalt 缓存目录做只读访问。
    func probeEscape() async -> (Bool, String) {
        if !initialized { _ = await initialize() }
        guard initialized else { return (false, "引擎初始化失败") }
        return await run {
            var err: NSString?
            let ok = BQCheckAccess(Self.mobileGestaltCaches, false, &err)
            return (ok, ok ? "逃逸探测成功" : (err as String? ?? "访问被拒绝"))
        }
    }

    // MARK: - MobileGestalt

    func loadGestalt() async throws -> [String: Any] {
        try await runThrowing {
            var err: NSString?
            guard let dict = BQLoadGestalt(&err) as? [String: Any] else {
                throw EscapeError.failed(err as String? ?? "读取 MobileGestalt 失败")
            }
            return dict
        }
    }

    func saveGestalt(_ dict: [String: Any]) async throws {
        try await runThrowing {
            var err: NSString?
            let ok = BQSaveGestalt(dict, &err)
            if !ok { throw EscapeError.failed(err as String? ?? "写入 MobileGestalt 失败") }
        }
    }

    func restoreGestalt() async throws {
        try await runThrowing {
            var err: NSString?
            let ok = BQRestoreGestalt(&err)
            if !ok { throw EscapeError.failed(err as String? ?? "恢复 MobileGestalt 备份失败") }
        }
    }

    func gestaltBackupExists() async -> Bool {
        await run { BQBackupExists() }
    }

    func respring() async {
        await run { BQRespring() }
    }

    // MARK: - 容器浏览

    func containerRoots() async -> [String] {
        await run { (BQContainerRoots() as? [String]) ?? [] }
    }

    func listContainers(root: String) async -> [String] {
        await run { (BQListContainers(root) as? [String]) ?? [] }
    }

    /// 容器元数据（.com.apple.mobile_container_manager.metadata.plist），含 MCMMetadataIdentifier（Bundle ID）。
    func containerInfo(_ container: String) async -> [String: Any] {
        await run { (BQContainerInfo(container) as? [String: Any]) ?? [:] }
    }

    func listPath(container: String, rel: String) async throws -> [PathEntry] {
        try await runThrowing {
            var err: NSString?
            let names = (BQListPath(container, rel, &err) as? [String]) ?? []
            if let e = err as String?, !e.isEmpty, names.isEmpty {
                // 空目录也可能返回空且无错；只有带错误信息时才抛错
                if e != "list failed" { throw EscapeError.failed(e) }
            }
            return names.map { name in
                var statErr: NSString?
                let stat = BQStatPath(container, (rel as NSString).appendingPathComponent(name), &statErr) as? [String: Any]
                let isDir = (stat?["isDir"] as? NSNumber)?.boolValue ?? false
                let size = (stat?["size"] as? NSNumber)?.int64Value ?? 0
                return PathEntry(name: name, isDir: isDir, size: size)
            }
        }
    }

    func readPath(container: String, rel: String) async throws -> Data {
        try await runThrowing {
            var err: NSString?
            guard let data = BQReadPath(container, rel, &err) else {
                throw EscapeError.failed(err as String? ?? "读取失败")
            }
            return data
        }
    }

    func writePath(container: String, rel: String, data: Data) async throws {
        try await runThrowing {
            var err: NSString?
            let ok = BQWritePath(container, rel, data, &err)
            if !ok { throw EscapeError.failed(err as String? ?? "写入失败") }
        }
    }

    func deletePath(container: String, rel: String) async throws {
        try await runThrowing {
            var err: NSString?
            let ok = BQDeletePath(container, rel, &err)
            if !ok { throw EscapeError.failed(err as String? ?? "删除失败") }
        }
    }

    private func runThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                do { c.resume(returning: try work()) }
                catch { c.resume(throwing: error) }
            }
        }
    }
}
