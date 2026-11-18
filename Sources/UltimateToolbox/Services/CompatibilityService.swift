import Foundation
import UIKit
import Darwin

/// 兼容性检测：系统版本 / Build / 逃逸可用性 / 各模块真实可用状态。
/// 检测系统 Build（不只是版本号），27.3 beta 2（24C5049d）起 worse_query 已被修补。

enum ModuleStatus: Equatable {
    case available
    case unavailable(reason: String)
    case limited(note: String)
}

struct CompatibilityReport: Equatable {
    let iosVersion: String
    let iosMajor: Int
    let build: String
    let deviceModel: String
    let escapeAvailable: Bool
    let escapeDetail: String
    let gestalt: ModuleStatus
    let crossAppFiles: ModuleStatus
    let crossAppCache: ModuleStatus
    let crashLogs: ModuleStatus
}

@MainActor
final class CompatibilityService: ObservableObject {
    static let shared = CompatibilityService()

    @Published private(set) var report: CompatibilityReport?
    @Published private(set) var probing = false

    /// 27.3 beta 2 的 Build：worse_query 在此被修补。
    static let patchedBuild = "24C5049d"

    var iosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    var iosMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// kern.osversion，如 24C5083a（27.0.1）。公开 sysctl，可读。
    var build: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "未知" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 else { return "未知" }
        return String(cString: buf)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Build 是否 >= 27.3 beta 2（24C5049d）：比较 24C + 数字部分。
    static func isPatchedBuild(_ build: String) -> Bool {
        // 形如 24C5049d / 24D1234a
        guard build.count >= 4 else { return false }
        let major = String(build.prefix(2))
        let letter = build[build.index(build.startIndex, offsetBy: 2)]
        let digits = build.dropFirst(3).prefix(while: { $0.isNumber })
        guard let majorNum = Int(major), let num = Int(digits) else { return false }
        if majorNum > 24 { return true }
        if majorNum < 24 { return false }
        if letter > "C" { return true }
        if letter < "C" { return false }
        return num >= 5049
    }

    /// 启动时做一次真实逃逸探测（后台线程），结果缓存。
    func probe() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        let (ok, detail) = await EscapeService.shared.probeEscape()
        let b = build
        let major = iosMajor
        let patched = Self.isPatchedBuild(b)
        let model = SystemInfoService.deviceModelIdentifier()

        let gestalt: ModuleStatus
        let files: ModuleStatus
        let cache: ModuleStatus
        let crash: ModuleStatus
        if major < 27 {
            let r = "MobileGestalt 写入需要 iOS 27+，当前为 iOS \(iosVersion)，该模块不可用。"
            gestalt = .unavailable(reason: r)
            files = .limited(note: "iOS 26 上逃逸只能访问单个 App / 插件 / Daemon / App Group 容器，无法访问全部应用数据。")
            cache = .limited(note: "iOS 26 上可清理单个 App 缓存，但无崩溃日志区，扫描较慢。")
            crash = .unavailable(reason: "iOS 26 没有可访问的崩溃日志区。")
        } else if patched {
            let r = "当前系统 Build \(b) 已修补 worse_query 沙盒逃逸（27.3 beta 2 起），该模块不可用。"
            gestalt = .unavailable(reason: r)
            files = .unavailable(reason: r)
            cache = .unavailable(reason: r)
            crash = .unavailable(reason: r)
        } else if ok {
            gestalt = .available
            files = .available
            cache = .available
            crash = .available
        } else {
            let r = "逃逸探测失败：\(detail)。对应模块已禁用。"
            gestalt = .unavailable(reason: r)
            files = .unavailable(reason: r)
            cache = .unavailable(reason: r)
            crash = .unavailable(reason: r)
        }
        report = CompatibilityReport(
            iosVersion: iosVersion, iosMajor: major, build: b, deviceModel: model,
            escapeAvailable: ok, escapeDetail: detail,
            gestalt: gestalt, crossAppFiles: files, crossAppCache: cache, crashLogs: crash
        )
        if ok {
            UTLog.success("兼容性检测通过：iOS \(iosVersion) (\(b))，逃逸可用", category: "兼容性")
        } else {
            UTLog.warning("兼容性检测：iOS \(iosVersion) (\(b))，逃逸不可用：\(detail)", category: "兼容性")
        }
    }
}
