import Foundation
import SwiftUI
import Combine

/// 外观 / 强调色 / 语言 / 备份设置。全部真实生效（.preferredColorScheme、.accentColor、语言切换）。

enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0, light, dark
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var label: String { self == .zh ? "简体中文" : "English" }
}

/// 字体大小（App 内独立设置，不跟随系统；标准对应 iOS 默认的 .large）。
enum TextSizeOption: Int, CaseIterable, Identifiable {
    case small = 0, standard, large, extraLarge, huge
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .extraLarge: return "特大"
        case .huge: return "超大"
        }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .large
        case .large: return .xLarge
        case .extraLarge: return .xxLarge
        case .huge: return .xxxLarge
        }
    }
}

/// 界面密度：控制列表行最小高度（紧凑 36 / 标准 44 / 宽松 56）。
enum UIDensity: Int, CaseIterable, Identifiable {
    case compact = 0, standard, comfortable
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .comfortable: return "宽松"
        }
    }
    var minRowHeight: CGFloat {
        switch self {
        case .compact: return 36
        case .standard: return 44
        case .comfortable: return 56
        }
    }
}

struct AccentPreset: Identifiable {
    let id: String
    let name: String
    let color: Color
    static let presets: [AccentPreset] = [
        .init(id: "red", name: "红色", color: .red),
        .init(id: "orange", name: "橙色", color: .orange),
        .init(id: "yellow", name: "黄色", color: .yellow),
        .init(id: "green", name: "绿色", color: .green),
        .init(id: "blue", name: "蓝色", color: .blue),
        .init(id: "purple", name: "紫色", color: .purple),
        .init(id: "pink", name: "粉色", color: .pink),
    ]
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("ut.appearance") private var appearanceRaw: Int = AppearanceMode.system.rawValue
    @AppStorage("ut.accentPreset") private var accentPresetID: String = "blue"
    @AppStorage("ut.accentCustomHex") private var accentCustomHex: String = ""
    @AppStorage("ut.language") private var languageRaw: String = AppLanguage.zh.rawValue
    @AppStorage("ut.autoBackup") var autoBackup: Bool = true
    @AppStorage("ut.logRetentionDays") var logRetentionDays: Int = 7
    @AppStorage("ut.textSize") private var textSizeRaw: Int = TextSizeOption.standard.rawValue
    @AppStorage("ut.uiDensity") private var uiDensityRaw: Int = UIDensity.standard.rawValue

    var textSize: TextSizeOption {
        get { TextSizeOption(rawValue: textSizeRaw) ?? .standard }
        set { textSizeRaw = newValue.rawValue }
    }
    var uiDensity: UIDensity {
        get { UIDensity(rawValue: uiDensityRaw) ?? .standard }
        set { uiDensityRaw = newValue.rawValue }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .zh }
        set {
            languageRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var accentColor: Color {
        if !accentCustomHex.isEmpty, let c = Color(hex: accentCustomHex) { return c }
        return AccentPreset.presets.first { $0.id == accentPresetID }?.color ?? .blue
    }
    var accentName: String {
        if !accentCustomHex.isEmpty { return "自定义" }
        return AccentPreset.presets.first { $0.id == accentPresetID }?.name ?? "蓝色"
    }
    func setAccentPreset(_ id: String) {
        accentPresetID = id
        accentCustomHex = ""
        objectWillChange.send()
    }
    func setAccentCustom(_ hex: String) {
        accentCustomHex = hex
        objectWillChange.send()
    }

    var colorScheme: ColorScheme? { appearance.colorScheme }

    func resetAll() {
        appearanceRaw = AppearanceMode.system.rawValue
        accentPresetID = "blue"
        accentCustomHex = ""
        languageRaw = AppLanguage.zh.rawValue
        autoBackup = true
        logRetentionDays = 7
        textSizeRaw = TextSizeOption.standard.rawValue
        uiDensityRaw = UIDensity.standard.rawValue
        objectWillChange.send()
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
    func toHex() -> String? {
        #if os(iOS)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return nil
        #endif
    }
}

/// 主界面字符串（中 / 英双语，语言设置真实切换）。
/// 注意：直接读 UserDefaults，不经过 @MainActor 的 AppSettings（L10n 用于非隔离上下文）。
enum L10n {
    static var isEnglish: Bool {
        UserDefaults.standard.string(forKey: "ut.language") == "en"
    }
    static func s(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
    static var home: String { s("主页", "Home") }
    static var tools: String { s("工具", "Tools") }
    static var github: String { s("GitHub", "GitHub") }
    static var settings: String { s("设置", "Settings") }
    static var runLog: String { s("运行日志", "Run Log") }
    static var cacheCleaner: String { s("缓存清理", "Cache Cleaner") }
    static var fileManager: String { s("文件管理器", "File Manager") }
    static var systemInfo: String { s("系统信息", "System Info") }
    static var plistEditor: String { s("Plist 编辑器", "Plist Editor") }
    static var gestalt: String { s("MobileGestalt", "MobileGestalt") }
    static var backup: String { s("备份与恢复", "Backup & Restore") }
    static var wallpaper: String { s("交互壁纸", "Live Wallpaper") }
    static var unavailable: String { s("不可用", "Unavailable") }
}
