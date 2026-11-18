import Foundation
import CryptoKit

/// 备份与恢复：真实生成文件（带 manifest + SHA-256 校验），恢复前先备份当前数据。

struct BackupManifestItem: Codable {
    let relativePath: String
    let size: Int64
    let sha256: String
}

struct BackupManifest: Codable {
    let label: String
    let createdAt: Date
    let items: [BackupManifestItem]
}

struct BackupEntry: Identifiable {
    let id = UUID()
    let folderName: String
    let url: URL
    let manifest: BackupManifest
    var totalSize: Int64 { manifest.items.reduce(0) { $0 + $1.size } }
}

@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published private(set) var backups: [BackupEntry] = []

    var backupsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Backups", isDirectory: true)
    }

    func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        var out: [BackupEntry] = []
        if let dirs = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) {
            for dir in dirs where dir.hasDirectoryPath {
                let manifestURL = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else { continue }
                out.append(BackupEntry(folderName: dir.lastPathComponent, url: dir, manifest: manifest))
            }
        }
        backups = out.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 创建备份：items 为（源文件 URL，备份内相对路径）。
    func createBackup(label: String, items: [(URL, String)]) -> BackupEntry? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        let folder = backupsDir.appendingPathComponent("\(stamp)-\(safeLabel)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var manifestItems: [BackupManifestItem] = []
            for (src, rel) in items {
                let dst = folder.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                let data = try Data(contentsOf: dst)
                manifestItems.append(BackupManifestItem(relativePath: rel, size: Int64(data.count), sha256: Self.sha256(of: data)))
            }
            let manifest = BackupManifest(label: label, createdAt: Date(), items: manifestItems)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: folder.appendingPathComponent("manifest.json"))
            // 完整性验证：重读每个文件校验哈希
            guard verifyBackup(at: folder, manifest: manifest) else {
                try? fm.removeItem(at: folder)
                UTLog.error("备份完整性验证失败，已删除不完整备份：\(label)", category: "备份")
                return nil
            }
            let entry = BackupEntry(folderName: folder.lastPathComponent, url: folder, manifest: manifest)
            UTLog.success("备份已创建：\(label)，\(manifestItems.count) 个文件", category: "备份")
            refresh()
            return entry
        } catch {
            UTLog.error("创建备份失败：\(error.localizedDescription)", category: "备份")
            try? fm.removeItem(at: folder)
            return nil
        }
    }

    /// 备份本 App 的全部用户数据（Documents 下除 Backups 外的所有内容，含引擎自动备份的 OriginalGestalt.plist）。
    func backupAppData() -> BackupEntry? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        var items: [(URL, String)] = []
        if let names = try? fm.contentsOfDirectory(atPath: docs.path) {
            for name in names where name != "Backups" {
                items.append((docs.appendingPathComponent(name), name))
            }
        }
        return createBackup(label: "应用数据", items: items)
    }

    /// 单独备份 MobileGestalt 原始文件（引擎首次读取时自动生成的 Documents/OriginalGestalt.plist）。
    /// 未读取过 MobileGestalt 时引擎备份不存在，返回 nil。
    func backupGestaltOriginal() async -> BackupEntry? {
        guard await EscapeService.shared.gestaltBackupExists() else { return nil }
        let path = await EscapeService.shared.gestaltBackupPath()
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return createBackup(label: "MobileGestalt 原始文件", items: [(url, "OriginalGestalt.plist")])
    }

    func verifyBackup(at folder: URL, manifest: BackupManifest) -> Bool {
        for item in manifest.items {
            let url = folder.appendingPathComponent(item.relativePath)
            guard let data = try? Data(contentsOf: url),
                  Int64(data.count) == item.size,
                  Self.sha256(of: data) == item.sha256 else { return false }
        }
        return true
    }

    /// 恢复：先自动备份当前数据，再把备份文件写回原位置（相对路径对应 Documents 下）。
    func restore(_ entry: BackupEntry) -> Bool {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 恢复前先备份当前数据
        if AppSettings.shared.autoBackup {
            var current: [(URL, String)] = []
            for item in entry.manifest.items {
                let target = docs.appendingPathComponent(item.relativePath)
                if fm.fileExists(atPath: target.path) {
                    current.append((target, item.relativePath))
                }
            }
            if !current.isEmpty {
                _ = createBackup(label: "恢复前自动备份", items: current)
            }
        }
        var ok = true
        for item in entry.manifest.items {
            let src = entry.url.appendingPathComponent(item.relativePath)
            let dst = docs.appendingPathComponent(item.relativePath)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            } catch {
                UTLog.error("恢复 \(item.relativePath) 失败：\(error.localizedDescription)", category: "备份")
                ok = false
            }
        }
        if ok {
            UTLog.success("已恢复备份：\(entry.manifest.label)", category: "备份")
        }
        return ok
    }

    func delete(_ entry: BackupEntry) -> Bool {
        do {
            try FileManager.default.removeItem(at: entry.url)
            UTLog.success("已删除备份：\(entry.manifest.label)", category: "备份")
            refresh()
            return true
        } catch {
            UTLog.error("删除备份失败：\(error.localizedDescription)", category: "备份")
            return false
        }
    }
}
