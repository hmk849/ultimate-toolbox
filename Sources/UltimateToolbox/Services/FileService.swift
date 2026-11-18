import Foundation

/// 文件服务：本 App 容器 + App Group 容器的真实文件操作（浏览/复制/移动/重命名/删除/导入导出）。
/// 跨 App 容器走 EscapeService（逃逸可用时）。

struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date?
}

enum FileRoot: String, CaseIterable, Identifiable {
    case home = "本 App"
    case group = "App Group"
    case imported = "导入的文件"
    var id: String { rawValue }
}

@MainActor
final class FileService: ObservableObject {
    static let shared = FileService()

    @Published private(set) var items: [FileItem] = []
    @Published var currentPath: String = NSHomeDirectory()
    @Published var currentRoot: FileRoot = .home

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    var importedURL: URL {
        documentsURL.appendingPathComponent("Imported", isDirectory: true)
    }

    func rootPath(for root: FileRoot) -> String {
        switch root {
        case .home: return NSHomeDirectory()
        case .group:
            return FileManager.default.containerURLForSecurityApplicationGroupIdentifier("group.com.hmk849.ultimatetoolbox")?.path ?? NSHomeDirectory()
        case .imported:
            try? FileManager.default.createDirectory(at: importedURL, withIntermediateDirectories: true)
            return importedURL.path
        }
    }

    func navigate(to root: FileRoot) {
        currentRoot = root
        currentPath = rootPath(for: root)
        refresh()
    }

    func navigateInto(_ name: String) {
        currentPath = (currentPath as NSString).appendingPathComponent(name)
        refresh()
    }

    func navigateUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        let root = rootPath(for: currentRoot)
        if currentPath != root, currentPath.hasPrefix(root) {
            currentPath = parent
            refresh()
        }
    }

    func refresh() {
        let fm = FileManager.default
        var out: [FileItem] = []
        if let names = try? fm.contentsOfDirectory(atPath: currentPath) {
            for name in names.sorted(localizedCaseInsensitiveCompare: { $0 < $1 }) {
                let p = (currentPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                let attrs = try? fm.attributesOfItem(atPath: p)
                let size: Int64
                if isDir.boolValue {
                    size = CacheCleanerService.directorySize(p)
                } else {
                    size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                }
                out.append(FileItem(name: name, isDir: isDir.boolValue, size: size, modified: attrs?[.modificationDate] as? Date))
            }
        }
        items = out
    }

    func readText(at name: String) -> String? {
        let p = (currentPath as NSString).appendingPathComponent(name)
        return try? String(contentsOfFile: p, encoding: .utf8)
    }

    func writeText(_ text: String, to name: String) -> Bool {
        let p = (currentPath as NSString).appendingPathComponent(name)
        do {
            try text.write(toFile: p, atomically: true, encoding: .utf8)
            UTLog.success("已保存 \(name)", category: "文件管理")
            refresh()
            return true
        } catch {
            UTLog.error("保存 \(name) 失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func readData(at name: String) -> Data? {
        let p = (currentPath as NSString).appendingPathComponent(name)
        return try? Data(contentsOf: URL(fileURLWithPath: p))
    }

    func writeData(_ data: Data, to name: String) -> Bool {
        let p = (currentPath as NSString).appendingPathComponent(name)
        do {
            try data.write(to: URL(fileURLWithPath: p), options: .atomic)
            refresh()
            return true
        } catch {
            UTLog.error("写入 \(name) 失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func rename(_ name: String, to newName: String) -> Bool {
        let fm = FileManager.default
        let src = (currentPath as NSString).appendingPathComponent(name)
        let dst = (currentPath as NSString).appendingPathComponent(newName)
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            UTLog.success("已重命名 \(name) → \(newName)", category: "文件管理")
            refresh()
            return true
        } catch {
            UTLog.error("重命名失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func delete(_ name: String) -> Bool {
        let p = (currentPath as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(atPath: p)
            UTLog.success("已删除 \(name)", category: "文件管理")
            refresh()
            return true
        } catch {
            UTLog.error("删除 \(name) 失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func move(_ name: String, to destinationDir: String) -> Bool {
        let src = (currentPath as NSString).appendingPathComponent(name)
        let dst = (destinationDir as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
            UTLog.success("已移动 \(name)", category: "文件管理")
            refresh()
            return true
        } catch {
            UTLog.error("移动失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func copy(_ name: String, to destinationDir: String) -> Bool {
        let src = (currentPath as NSString).appendingPathComponent(name)
        let dst = (destinationDir as NSString).appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.removeItem(atPath: dst)
            }
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            UTLog.success("已复制 \(name)", category: "文件管理")
            refresh()
            return true
        } catch {
            UTLog.error("复制失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    /// 从系统文件选择器导入到 Documents/Imported。
    func importFile(from url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: importedURL, withIntermediateDirectories: true)
        let dst = importedURL.appendingPathComponent(url.lastPathComponent)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            // 安全域资源需要先访问
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: url, to: dst)
            UTLog.success("已导入 \(url.lastPathComponent)", category: "文件管理")
            if currentRoot == .imported { refresh() }
            return true
        } catch {
            UTLog.error("导入失败：\(error.localizedDescription)", category: "文件管理")
            return false
        }
    }

    func url(for name: String) -> URL {
        URL(fileURLWithPath: (currentPath as NSString).appendingPathComponent(name))
    }

    static func hexDump(_ data: Data, maxBytes: Int = 4096) -> String {
        let bytes = data.prefix(maxBytes)
        var lines: [String] = []
        var offset = 0
        for chunk in bytes.chunked(into: 16) {
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains(Int($0)) ? Character(UnicodeScalar($0)) : "." }.map(String.init).joined()
            lines.append(String(format: "%08x  %-48@  %@", offset, hex, ascii))
            offset += chunk.count
        }
        if data.count > maxBytes { lines.append("… 共 \(data.count) 字节，仅显示前 \(maxBytes) 字节") }
        return lines.joined(separator: "\n")
    }
}

extension Data {
    func chunked(into size: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        let bytes = [UInt8](self)
        while i < bytes.count {
            out.append(Array(bytes[i..<min(i + size, bytes.count)]))
            i += size
        }
        return out
    }
}
