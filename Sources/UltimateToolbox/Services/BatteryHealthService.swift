import Foundation

/// 电池健康：IOKit 实时探测优先，逃逸解析 Analytics 诊断日志做后备。
/// 两条路都读不到就返回 nil，绝不伪造；诊断日志有 24 小时左右延迟，须标清数据日期。

struct BatteryHealthInfo {
    let healthPercent: Double?
    let cycleCount: Int?
    let designCapacityMah: Int?
    let currentCapacityMah: Int?
    let temperatureC: Double?
    /// "IOKit 实时" 或 "诊断日志 2026-11-18"
    let source: String
    let dataDate: Date?
}

final class BatteryHealthService: Sendable {
    static let shared = BatteryHealthService()

    func fetch(modelIdentifier: String) async -> BatteryHealthInfo? {
        if let live = await iokitProbe() { return live }
        return await analyticsProbe(modelIdentifier: modelIdentifier)
    }

    // MARK: - IOKit 实时探测（无专用 entitlement 时大概率被拦住，失败即返回 nil）

    private func iokitProbe() async -> BatteryHealthInfo? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: Self.readIOKitBattery())
            }
        }
    }

    private static func readIOKitBattery() -> BatteryHealthInfo? {
        for serviceName in ["AppleSmartBattery", "IOPMPowerSource"] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == 0,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            let design = (dict["DesignCapacity"] as? NSNumber)?.intValue
            let rawMax = (dict["AppleRawMaxCapacity"] as? NSNumber)?.intValue
            let nominal = (dict["NominalChargeCapacity"] as? NSNumber)?.intValue
            let cycles = (dict["CycleCount"] as? NSNumber)?.intValue
            let tempRaw = (dict["Temperature"] as? NSNumber)?.doubleValue
            guard design != nil || rawMax != nil || cycles != nil else { continue }
            let current = rawMax ?? nominal
            var health: Double?
            if let d = design, d > 0, let cur = current { health = Double(cur) / Double(d) * 100 }
            UTLog.info("电池健康 IOKit 探测成功：健康 \(health.map { String(format: "%.1f%%", $0) } ?? "-")，循环 \(cycles.map(String.init) ?? "-")", category: "系统信息")
            return BatteryHealthInfo(
                healthPercent: health, cycleCount: cycles,
                designCapacityMah: design, currentCapacityMah: current,
                temperatureC: tempRaw.map { $0 / 100 },
                source: "IOKit 实时", dataDate: Date()
            )
        }
        return nil
    }

    // MARK: - Analytics 诊断日志（逃逸读文件，零 entitlement）

    private func analyticsProbe(modelIdentifier: String) async -> BatteryHealthInfo? {
        let dir = "/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs"
        guard let names = await EscapeService.shared.listDirectory(dir) else {
            UTLog.warning("电池健康：诊断日志目录不可读", category: "系统信息")
            return nil
        }
        let candidates = names
            .filter { ($0.hasPrefix("Analytics-") || $0.hasPrefix("log-aggregated-")) && ($0.hasSuffix(".ips") || $0.hasSuffix(".ips.ca.gz")) }
            .sorted().reversed()
        for name in candidates.prefix(3) {
            let path = (dir as NSString).appendingPathComponent(name)
            guard var data = await EscapeService.shared.readFile(path) else { continue }
            if path.hasSuffix(".gz") {
                guard let decompressed = Self.gunzip(data) else { continue }
                data = decompressed
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
            let cycles = (plist["com.apple.ioreport.BatteryCycleCount"] as? NSNumber)?.intValue
            let design = (plist["com.apple.power.battery.design_capacity"] as? NSNumber)?.intValue
            let nominal = (plist["com.apple.power.battery.nominal_charge_capacity"] as? NSNumber)?.intValue
            let rawMax = (plist["com.apple.power.battery.raw_max_capacity"] as? NSNumber)?.intValue
            let maxPercent = (plist["battery.MaximumCapacityPercent"] as? NSNumber)?.doubleValue
            guard cycles != nil || design != nil || nominal != nil || rawMax != nil || maxPercent != nil else { continue }
            let designMah = design ?? Self.designCapacityFallback(modelIdentifier: modelIdentifier)
            let current = rawMax ?? nominal
            var health = maxPercent
            if health == nil, let d = designMah, d > 0, let cur = current { health = Double(cur) / Double(d) * 100 }
            let date = Self.dateFromAnalyticsFilename(name)
            let dateText = date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? name
            UTLog.info("电池健康诊断日志解析成功：健康 \(health.map { String(format: "%.1f%%", $0) } ?? "-")，循环 \(cycles.map(String.init) ?? "-")，数据日期 \(dateText)", category: "系统信息")
            return BatteryHealthInfo(
                healthPercent: health, cycleCount: cycles,
                designCapacityMah: designMah, currentCapacityMah: current,
                temperatureC: nil, source: "诊断日志", dataDate: date
            )
        }
        UTLog.warning("电池健康：近 3 份诊断日志均无电池数据", category: "系统信息")
        return nil
    }

    /// .ips.ca.gz 解压（libz，windowBits 47 自动识别 zlib/gzip）。
    private static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let ok = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: src.baseAddress!.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(data.count)
            return inflateInit2_(&stream, 47, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        }
        guard ok == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        repeat {
            status = buffer.withUnsafeMutableBufferPointer { ptr in
                stream.next_out = ptr.baseAddress
                stream.avail_out = uInt(chunk)
                return inflate(&stream, Z_NO_FLUSH)
            }
            if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR { return nil }
            let have = chunk - Int(stream.avail_out)
            if have > 0 { out.append(buffer, count: have) }
        } while status != Z_STREAM_END
        return out
    }

    /// 文件名里的日期：Analytics-YYYY-MM-DD-… 或 log-aggregated-YYYY-MM-DD-…。
    private static func dateFromAnalyticsFilename(_ name: String) -> Date? {
        let parts = name.split(separator: "-").map(String.init)
        // 找连续 3 个数字段（年-月-日）
        for i in 0..<(parts.count - 2) {
            guard parts[i].count == 4, let y = Int(parts[i]), let m = Int(parts[i + 1]), let d = Int(parts[i + 2]) else { continue }
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            return Calendar.current.date(from: comps)
        }
        return nil
    }

    /// 新版诊断日志可能没有 design_capacity，按机型查表补（只列有把握的 iPhone 15 系列）。
    private static func designCapacityFallback(modelIdentifier: String) -> Int? {
        switch modelIdentifier {
        case "iPhone15,4": return 3349 // iPhone 15
        case "iPhone15,5": return 4383 // iPhone 15 Plus
        case "iPhone15,2": return 3274 // iPhone 15 Pro
        case "iPhone15,3": return 4422 // iPhone 15 Pro Max
        default: return nil
        }
    }
}
