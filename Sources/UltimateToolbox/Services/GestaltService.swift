import Foundation

/// MobileGestalt 服务：读 CacheExtra → 改预设/字段 → 写回 → 重读验证。
/// 首次读取时引擎自动备份原始 plist（BQLoadGestalt）；恢复用引擎备份。

@MainActor
final class GestaltService: ObservableObject {
    static let shared = GestaltService()

    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var cacheExtra: [(key: String, value: PlistValue)] = []
    @Published var topLevelKeys: [String] = []

    private var fullDict: [String: Any] = [:]

    var isAvailable: Bool {
        CompatibilityService.shared.report?.gestalt == .available
    }

    func load() async {
        guard isAvailable else {
            errorMessage = "MobileGestalt 编辑在当前系统上不可用"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await EscapeService.shared.loadGestalt()
            guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw NSError(domain: "MobileGestalt", code: 0, userInfo: [NSLocalizedDescriptionKey: "解析 MobileGestalt 数据失败"])
            }
            fullDict = dict
            if let extra = dict["CacheExtra"] as? [String: Any] {
                cacheExtra = extra.keys.sorted().map { ($0, PlistValue.from(extra[$0]!)) }
            } else {
                cacheExtra = []
            }
            topLevelKeys = dict.keys.sorted()
            loaded = true
            errorMessage = nil
            UTLog.success("MobileGestalt 已载入：CacheExtra \(cacheExtra.count) 个键", category: "MobileGestalt")
        } catch {
            errorMessage = error.localizedDescription
            UTLog.error("MobileGestalt 载入失败：\(error.localizedDescription)", category: "MobileGestalt")
        }
    }

    /// 应用选中的预设（统一 Apply）：写 CacheExtra → 保存 → 重读验证。
    func applyPresets(_ presets: [MGPreset], islandSubtype: Int?) async -> Bool {
        guard loaded else { return false }
        var extra = (fullDict["CacheExtra"] as? [String: Any]) ?? [:]
        for preset in presets {
            for k in preset.keys {
                extra[k.key] = k.value.anyValue
            }
        }
        // 灵动岛子类型：写 ArtworkDevice 字典
        if let subtype = islandSubtype,
           presets.contains(where: { $0.id == "dynamic-island" }) {
            var artwork = (extra["oPeik/9e8lQWMszEjbPzng"] as? [String: Any]) ?? [:]
            artwork["ArtworkDeviceSubType"] = subtype
            extra["oPeik/9e8lQWMszEjbPzng"] = artwork
        }
        fullDict["CacheExtra"] = extra
        return await saveAndVerify()
    }

    /// Siri AI 第二步：删除身份伪装键，保留 SiriMode。
    func restoreSiriIdentity() async -> Bool {
        guard loaded else { return false }
        var extra = (fullDict["CacheExtra"] as? [String: Any]) ?? [:]
        for key in MGPresets.siriIdentityKeys {
            extra.removeValue(forKey: key)
        }
        fullDict["CacheExtra"] = extra
        let ok = await saveAndVerify()
        if ok {
            UTLog.success("Siri AI 第二步完成：身份键已还原，SiriMode 已保留", category: "MobileGestalt")
        }
        return ok
    }

    /// 字段编辑：设置 / 新增 / 删除 CacheExtra 键。
    func setField(key: String, value: PlistValue) {
        if let i = cacheExtra.firstIndex(where: { $0.key == key }) {
            cacheExtra[i] = (key, value)
        } else {
            cacheExtra.append((key, value))
            cacheExtra.sort { $0.key < $1.key }
        }
    }

    func deleteField(key: String) {
        cacheExtra.removeAll { $0.key == key }
    }

    func saveFields() async -> Bool {
        guard loaded else { return false }
        var extra: [String: Any] = [:]
        for (k, v) in cacheExtra { extra[k] = v.anyValue }
        fullDict["CacheExtra"] = extra
        return await saveAndVerify()
    }

    func restoreBackup() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            try await EscapeService.shared.restoreGestalt()
            UTLog.success("MobileGestalt 已恢复到原始备份", category: "MobileGestalt")
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            UTLog.error("恢复备份失败：\(error.localizedDescription)", category: "MobileGestalt")
            return false
        }
    }

    func respring() async {
        await EscapeService.shared.respring()
        UTLog.info("已触发 Respring", category: "MobileGestalt")
    }

    private func saveAndVerify() async -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: fullDict, format: .xml, options: 0)
            try await EscapeService.shared.saveGestalt(data)
            // 重读验证
            let reloadedData = try await EscapeService.shared.loadGestalt()
            guard let reloaded = try? PropertyListSerialization.propertyList(from: reloadedData, options: [], format: nil) as? [String: Any] else {
                errorMessage = "写入后重读验证失败，无法解析"
                UTLog.error("MobileGestalt 写入后验证失败", category: "MobileGestalt")
                return false
            }
            let reExtra = (reloaded["CacheExtra"] as? [String: Any]) ?? [:]
            let myExtra = (fullDict["CacheExtra"] as? [String: Any]) ?? [:]
            guard reExtra.count == myExtra.count else {
                errorMessage = "写入后重读验证失败（键数量不一致），请检查"
                UTLog.error("MobileGestalt 写入后验证失败", category: "MobileGestalt")
                return false
            }
            fullDict = reloaded
            cacheExtra = reExtra.keys.sorted().map { ($0, PlistValue.from(reExtra[$0]!)) }
            UTLog.success("MobileGestalt 已写入并验证通过（CacheExtra \(myExtra.count) 个键）", category: "MobileGestalt")
            return true
        } catch {
            errorMessage = error.localizedDescription
            UTLog.error("MobileGestalt 写入失败：\(error.localizedDescription)", category: "MobileGestalt")
            return false
        }
    }
}
