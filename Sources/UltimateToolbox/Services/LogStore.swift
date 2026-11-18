import Foundation
import Combine

/// 真实运行日志系统：内存环形缓冲 + 文件持久化，支持搜索 / 分类筛选 / 清空 / 复制 / 导出 TXT / 分享。
/// 不是预先写好的静态内容，所有条目都由 App 运行时真实产生。

enum LogLevel: String, CaseIterable, Identifiable {
    case info, success, warning, error, debug
    var id: String { rawValue }
    var label: String {
        switch self {
        case .info: return "INFO"
        case .success: return "SUCCESS"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .debug: return "DEBUG"
        }
    }
    /// SwiftUI 颜色名（视图层映射，避免服务层依赖 SwiftUI）。
    var colorName: String {
        switch self {
        case .info: return "secondary"
        case .success: return "green"
        case .warning: return "orange"
        case .error: return "red"
        case .debug: return "purple"
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let category: String
    let message: String
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    static let logDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Logs", isDirectory: true)
    }()
    static let logFile: URL = logDirectory.appendingPathComponent("ultimate-toolbox.log")

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        try? FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
    }

    func log(_ level: LogLevel, category: String, message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        appendToFile(entry)
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.logFile)
    }

    func filtered(level: LogLevel?, category: String?, query: String) -> [LogEntry] {
        entries.filter { e in
            (level == nil || e.level == level)
            && (category == nil || category == "全部" || e.category == category)
            && (query.isEmpty || e.message.localizedCaseInsensitiveContains(query)
                || e.category.localizedCaseInsensitiveContains(query))
        }
    }

    var categories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries where seen.insert(e.category).inserted { out.append(e.category) }
        return out.sorted()
    }

    func exportText() -> String {
        entries.map { e in
            "[\(dateFormatter.string(from: e.date))] [\(e.level.label)] [\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }

    func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }

    private func appendToFile(_ entry: LogEntry) {
        let line = "[\(dateFormatter.string(from: entry.date))] [\(entry.level.label)] [\(entry.category)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: Self.logFile.path) {
            if let handle = try? FileHandle(forWritingTo: Self.logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: Self.logFile)
        }
    }
}

/// 全局日志入口（任意线程可调，内部切回主线程写 store）。
enum UTLog {
    static func log(_ level: LogLevel, category: String, message: String) {
        Task { @MainActor in LogStore.shared.log(level, category: category, message: message) }
    }
    static func info(_ message: String, category: String = "App") { log(.info, category: category, message: message) }
    static func success(_ message: String, category: String = "App") { log(.success, category: category, message: message) }
    static func warning(_ message: String, category: String = "App") { log(.warning, category: category, message: message) }
    static func error(_ message: String, category: String = "App") { log(.error, category: category, message: message) }
    static func debug(_ message: String, category: String = "App") { log(.debug, category: category, message: message) }
}
