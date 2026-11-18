import Foundation

/// Plist 编辑器：读取 / 搜索 / 编辑全部类型 / 新增 / 删除 / 保存 + 保存后重读验证 / 修改前自动备份。
/// 操作对象是本 App 可访问范围内的 plist（自身容器、导入的文件、逃逸可达的容器）。

enum PlistValueKind: String, CaseIterable {
    case string = "String"
    case integer = "Integer"
    case float = "Float"
    case boolean = "Boolean"
    case data = "Data"
    case array = "Array"
    case dictionary = "Dictionary"
}

enum PlistValue: Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case data(Data)
    case array([PlistValue])
    case dictionary([(key: String, value: PlistValue)])

    static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    var kind: PlistValueKind {
        switch self {
        case .string: return .string
        case .integer: return .integer
        case .float: return .float
        case .boolean: return .boolean
        case .data: return .data
        case .array: return .array
        case .dictionary: return .dictionary
        }
    }

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .integer(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .boolean(let b): return b ? "true" : "false"
        case .data(let d): return "\(d.count) 字节（Base64：\(d.base64EncodedString().prefix(32))…）"
        case .array(let a): return "\(a.count) 项"
        case .dictionary(let d): return "\(d.count) 个键"
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return i
        case .float(let f): return f
        case .boolean(let b): return b
        case .data(let d): return d
        case .array(let a): return a.map { $0.anyValue }
        case .dictionary(let d):
            var dict: [String: Any] = [:]
            for (k, v) in d { dict[k] = v.anyValue }
            return dict
        }
    }

    static func from(_ any: Any) -> PlistValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // NSNumber 可能是 Bool / Int / Double：用 objCType 区分
            let t = String(cString: n.objCType)
            if t == "c" || t == "B" { return .boolean(n.boolValue) }
            if t == "d" || t == "f" { return .float(n.doubleValue) }
            return .integer(n.intValue)
        case let d as Data: return .data(d)
        case let a as [Any]: return .array(a.map { from($0) })
        case let d as [String: Any]:
            return .dictionary(d.keys.sorted().map { ($0, from(d[$0]!)) })
        case let d as NSDictionary:
            let dict = d as! [String: Any]
            return .dictionary(dict.keys.sorted().map { ($0, from(dict[$0]!)) })
        default: return .string("\(any)")
        }
    }

    static func empty(kind: PlistValueKind) -> PlistValue {
        switch kind {
        case .string: return .string("")
        case .integer: return .integer(0)
        case .float: return .float(0)
        case .boolean: return .boolean(false)
        case .data: return .data(Data())
        case .array: return .array([])
        case .dictionary: return .dictionary([])
        }
    }
}

@MainActor
final class PlistEditorService: ObservableObject {
    @Published private(set) var root: [(key: String, value: PlistValue)] = []
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceName: String = ""
    @Published private(set) var isLoaded = false
    @Published var errorMessage: String?

    private var originalData: Data?

    func load(url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            return load(data: data, name: url.lastPathComponent, url: url)
        } catch {
            errorMessage = "读取失败：\(error.localizedDescription)"
            UTLog.error("Plist 读取失败：\(error.localizedDescription)", category: "Plist 编辑")
            return false
        }
    }

    func load(data: Data, name: String, url: URL? = nil) -> Bool {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dict = plist as? [String: Any] else {
                errorMessage = "仅支持字典为根的 Plist（当前根为 \(type(of: plist))）"
                return false
            }
            originalData = data
            sourceURL = url
            sourceName = name
            root = dict.keys.sorted().map { ($0, PlistValue.from(dict[$0]!)) }
            isLoaded = true
            errorMessage = nil
            UTLog.info("已载入 Plist：\(name)，\(root.count) 个顶层键", category: "Plist 编辑")
            return true
        } catch {
            errorMessage = "解析失败：\(error.localizedDescription)"
            UTLog.error("Plist 解析失败：\(error.localizedDescription)", category: "Plist 编辑")
            return false
        }
    }

    func search(_ query: String) -> [(key: String, value: PlistValue)] {
        guard !query.isEmpty else { return root }
        return root.filter {
            $0.key.localizedCaseInsensitiveContains(query)
            || $0.value.displayString.localizedCaseInsensitiveContains(query)
        }
    }

    func setValue(key: String, value: PlistValue) {
        if let i = root.firstIndex(where: { $0.key == key }) {
            root[i] = (key, value)
        } else {
            root.append((key, value))
            root.sort { $0.key < $1.key }
        }
    }

    func deleteKey(_ key: String) {
        root.removeAll { $0.key == key }
    }

    func renameKey(_ old: String, to new: String) {
        guard let i = root.firstIndex(where: { $0.key == old }) else { return }
        root[i] = (new, root[i].value)
        root.sort { $0.key < $1.key }
    }

    /// 保存：修改前自动备份原文件，写盘后重读验证。
    func save() -> Bool {
        guard let url = sourceURL else {
            errorMessage = "没有可保存的目标文件（从数据载入的 Plist 请先导出）"
            return false
        }
        var dict: [String: Any] = [:]
        for (k, v) in root { dict[k] = v.anyValue }
        do {
            // 自动备份
            if AppSettings.shared.autoBackup, let orig = originalData {
                let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Backups/Plist", isDirectory: true)
                try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backupURL = backupDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(stamp).plist")
                try? orig.write(to: backupURL)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            // 保存后重读验证
            let reloaded = try Data(contentsOf: url)
            let check = try PropertyListSerialization.propertyList(from: reloaded, options: [], format: nil) as? [String: Any]
            guard let check, check.count == dict.count else {
                errorMessage = "保存后重读验证失败，文件可能未正确写入"
                UTLog.error("Plist 保存后验证失败：\(sourceName)", category: "Plist 编辑")
                return false
            }
            originalData = reloaded
            UTLog.success("已保存并验证 Plist：\(sourceName)（\(dict.count) 个键）", category: "Plist 编辑")
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            UTLog.error("Plist 保存失败：\(error.localizedDescription)", category: "Plist 编辑")
            return false
        }
    }

    func exportData() -> Data? {
        var dict: [String: Any] = [:]
        for (k, v) in root { dict[k] = v.anyValue }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}
