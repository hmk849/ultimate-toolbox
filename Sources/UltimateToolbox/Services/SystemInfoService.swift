import Foundation
import UIKit
import Network
import Darwin
import CoreBluetooth

/// 系统信息：公开 API + IOKit 探测 + 逃逸读系统文件。读不到的项明确标"不可读取"，绝不伪造。
/// 电池健康与 Wi-Fi 名称是异步探测（IOKit / 诊断日志 / fetchCurrent / 系统配置文件），
/// 刷新时先显示"检测中…"，探测完成后再更新。

struct InfoRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    /// false = 该项无公开 API，不可读取（UI 上灰显并标注）。
    let available: Bool
}

struct SystemInfoSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [InfoRow]
}

@MainActor
final class SystemInfoService: ObservableObject {
    static let shared = SystemInfoService()

    @Published private(set) var sections: [SystemInfoSection] = []
    @Published var networkStatus: String = "检测中…"

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.hmk849.ultimatetoolbox.network")

    /// 蓝牙开关状态（CoreBluetooth 公开 API，只读状态，不扫描不连接）。
    /// 委托类必须单独继承 NSObject（@MainActor 类不能直接遵循 CBCentralManagerDelegate）。
    private var bluetoothProbe: BluetoothProbe?
    private var bluetoothStatus: String = "检测中…"

    /// 异步探测结果（电池健康 / Wi-Fi 名称），初始为检测中，探测完成或失败后更新。
    private var batteryValue: String = "检测中…"
    private var batteryAvailable = false
    private var wifiValue: String = "检测中…"
    private var wifiAvailable = false
    private var probesStarted = false

    static func deviceModelIdentifier() -> String {
        CompatibilityService.sysctlString("hw.machine") ?? UIDevice.current.model
    }

    /// 机型营销名映射（未知机型直接显示标识符，不猜）。
    static func marketingName(for identifier: String) -> String {
        let table: [String: String] = [
            "iPhone15,2": "iPhone 15 Pro", "iPhone15,3": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
            "iPad13,1": "iPad Air (第 4 代)", "iPad13,2": "iPad Air (第 4 代)",
            "iPad13,16": "iPad Air (第 5 代)", "iPad13,17": "iPad Air (第 5 代)",
            "iPad14,1": "iPad mini (第 6 代)", "iPad14,2": "iPad mini (第 6 代)",
            "iPad14,3": "iPad Pro 11 英寸 (第 4 代)", "iPad14,4": "iPad Pro 11 英寸 (第 4 代)",
            "iPad14,5": "iPad Pro 12.9 英寸 (第 6 代)", "iPad14,6": "iPad Pro 12.9 英寸 (第 6 代)",
            "iPad16,3": "iPad Pro 11 英寸 (M4)", "iPad16,4": "iPad Pro 11 英寸 (M4)",
            "iPad16,5": "iPad Pro 13 英寸 (M4)", "iPad16,6": "iPad Pro 13 英寸 (M4)",
        ]
        return table[identifier] ?? identifier
    }

    static func chipName() -> String? {
        if let brand = CompatibilityService.sysctlString("machdep.cpu.brand_string"), !brand.isEmpty {
            return brand
        }
        return nil
    }

    static func kernelVersion() -> String? {
        CompatibilityService.sysctlString("kern.version")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let s: String
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) { s = "Wi-Fi 已连接" }
                else if path.usesInterfaceType(.cellular) { s = "蜂窝数据已连接" }
                else if path.usesInterfaceType(.wiredEthernet) { s = "有线网络已连接" }
                else { s = "已连接" }
            } else if path.status == .unsatisfied {
                s = "无网络连接"
            } else {
                s = "网络状态未知"
            }
            Task { @MainActor in self?.networkStatus = s }
        }
        monitor.start(queue: monitorQueue)
    }

    func refresh() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // 懒创建蓝牙探测器（只读开关状态；首次创建时系统可能弹一次蓝牙权限提示）。
        if bluetoothProbe == nil {
            bluetoothProbe = BluetoothProbe { [weak self] status in
                Task { @MainActor in
                    self?.bluetoothStatus = status
                    self?.refresh()
                }
            }
        }
        // 电池健康与 Wi-Fi 名称只探测一次（异步，完成后自动刷新本页）。
        if !probesStarted {
            probesStarted = true
            Task { await startProbes() }
        }
        let device = UIDevice.current
        let proc = ProcessInfo.processInfo
        let screen = UIScreen.main
        let identifier = Self.deviceModelIdentifier()

        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0

        var uts = utsname()
        uname(&uts)
        let arch = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        let batteryLevel = device.batteryLevel
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "充电中"
        case .full: batteryState = "已充满"
        case .unplugged: batteryState = "未充电"
        default: batteryState = "未知"
        }

        let uptime = proc.systemUptime
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60

        let deviceRows: [InfoRow] = [
            .init(title: "设备型号", value: Self.marketingName(for: identifier), available: true),
            .init(title: "设备标识符", value: identifier, available: true),
            .init(title: "设备名称", value: device.name, available: true),
            .init(title: "芯片", value: Self.chipName() ?? "不可读取", available: Self.chipName() != nil),
            .init(title: "CPU 核心", value: "\(proc.processorCount) 核", available: true),
            .init(title: "内存", value: Self.formatBytes(Int64(proc.physicalMemory)), available: true),
            .init(title: "存储总容量", value: total > 0 ? Self.formatBytes(total) : "不可读取", available: total > 0),
            .init(title: "剩余空间", value: free > 0 ? Self.formatBytes(free) : "不可读取", available: free > 0),
            .init(title: "屏幕分辨率", value: "\(Int(screen.nativeBounds.width)) × \(Int(screen.nativeBounds.height)) @\(screen.scale)x", available: true),
            .init(title: "屏幕刷新率", value: "\(screen.maximumFramesPerSecond) Hz", available: true),
            .init(title: "电池电量", value: batteryLevel >= 0 ? "\(Int(batteryLevel * 100))%（\(batteryState)）" : "不可读取", available: batteryLevel >= 0),
            .init(title: "电池健康", value: batteryValue, available: batteryAvailable),
        ]
        let systemRows: [InfoRow] = [
            .init(title: "iOS 版本", value: "\(device.systemVersion)", available: true),
            .init(title: "Build 版本", value: CompatibilityService.shared.build, available: true),
            .init(title: "内核版本", value: Self.kernelVersion() ?? "不可读取", available: Self.kernelVersion() != nil),
            .init(title: "系统运行时间", value: "\(hours) 小时 \(minutes) 分钟", available: true),
            .init(title: "时区", value: TimeZone.current.identifier, available: true),
            .init(title: "语言", value: Locale.current.identifier, available: true),
            .init(title: "网络状态", value: networkStatus, available: true),
            .init(title: "Wi-Fi 名称", value: wifiValue, available: wifiAvailable),
            .init(title: "蓝牙状态", value: bluetoothStatus, available: bluetoothStatus != "检测中…" && bluetoothStatus != "未知"),
            .init(title: "系统架构", value: arch, available: true),
        ]
        sections = [
            SystemInfoSection(title: "设备", rows: deviceRows),
            SystemInfoSection(title: "系统", rows: systemRows),
        ]
        UTLog.info("系统信息已刷新：\(Self.marketingName(for: identifier))，iOS \(device.systemVersion)", category: "系统信息")
    }

    /// 异步探测电池健康与 Wi-Fi 名称，任一完成即更新本页。
    private func startProbes() async {
        async let battery = BatteryHealthService.shared.fetch(modelIdentifier: Self.deviceModelIdentifier())
        async let wifi = WiFiService.shared.fetch()
        let b = await battery
        let w = await wifi
        if let b {
            var parts: [String] = []
            if let h = b.healthPercent { parts.append(String(format: "%.0f%%", h)) }
            if let c = b.cycleCount { parts.append("\(c) 次循环") }
            if let d = b.designCapacityMah, let cur = b.currentCapacityMah {
                parts.append("设计 \(d) mAh / 当前 \(cur) mAh")
            } else if let d = b.designCapacityMah {
                parts.append("设计 \(d) mAh")
            }
            if let t = b.temperatureC { parts.append(String(format: "%.1f°C", t)) }
            var value = parts.isEmpty ? "已读取" : parts.joined(separator: " · ")
            if b.source == "诊断日志" {
                let dateText = b.dataDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "未知日期"
                value += "（诊断日志 \(dateText)，非实时）"
            }
            batteryValue = value
            batteryAvailable = true
        } else {
            batteryValue = "不可读取（IOKit 被拦且诊断日志无电池数据）"
            batteryAvailable = false
        }
        if let w {
            wifiValue = w.source == "系统 Wi-Fi 信息" ? w.ssid : "\(w.ssid)（\(w.source)）"
            wifiAvailable = true
        } else {
            wifiValue = "不可读取（未获定位授权且系统配置中无匹配网络）"
            wifiAvailable = false
        }
        refresh()
    }
}

/// 蓝牙开关状态探测（CoreBluetooth，只读状态，不扫描不连接）。
/// 单独的 NSObject 子类：@MainActor 类不能直接遵循 CBCentralManagerDelegate。
private final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onState: (String) -> Void

    init(onState: @escaping (String) -> Void) {
        self.onState = onState
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: onState("已开启")
        case .poweredOff: onState("已关闭")
        case .unauthorized: onState("未授权（请在设置中允许蓝牙）")
        case .unsupported: onState("设备不支持蓝牙")
        case .resetting: onState("正在重置…")
        case .unknown: onState("检测中…")
        @unknown default: onState("未知")
        }
    }
}
