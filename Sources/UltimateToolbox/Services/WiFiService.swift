import Foundation
import NetworkExtension
import CoreLocation
import SystemConfiguration

/// 当前 Wi-Fi 名称：NEHotspotNetwork.fetchCurrent（需 wifi-info entitlement + 精确定位）优先，
/// SCDynamicStore 便宜探测次之，逃逸读系统 Wi-Fi 配置文件做后备；都读不到返回 nil，不伪造。

struct WiFiInfo {
    let ssid: String
    /// "系统 Wi-Fi 信息" / "系统动态库" / "系统 Wi-Fi 配置（按 BSSID 匹配）" / "系统 Wi-Fi 配置（最近加入）"
    let source: String
}

final class WiFiService {
    static let shared = WiFiService()
    private let locationManager = CLLocationManager()

    func fetch() async -> WiFiInfo? {
        // 1. SCDynamicStore 便宜探测（无 entitlement 也能试一次，大概率 nil）
        if let ssid = dynamicStoreSSID() {
            return WiFiInfo(ssid: ssid, source: "系统动态库")
        }
        // 2. 官方接口（需 wifi-info entitlement + 精确定位授权）
        if let ssid = await fetchCurrentSSID() {
            return WiFiInfo(ssid: ssid, source: "系统 Wi-Fi 信息")
        }
        // 3. 逃逸读配置文件（启发式：BSSID 匹配，退而求其次取最近加入）
        return await escapeSSID()
    }

    // MARK: - SCDynamicStore

    private func dynamicStoreSSID() -> String? {
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "com.hmk849.ultimatetoolbox" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Interface/en0/AirPort" as CFString) as? [String: Any] else {
            return nil
        }
        if let ssid = value["SSID"] as? String, !ssid.isEmpty { return ssid }
        if let ssid = value["SSID_STR"] as? String, !ssid.isEmpty { return ssid }
        if let data = value["SSID"] as? Data, let ssid = String(data: data, encoding: .utf8), !ssid.isEmpty { return ssid }
        return nil
    }

    // MARK: - NEHotspotNetwork.fetchCurrent

    private func fetchCurrentSSID() async -> String? {
        let status = await MainActor.run { CLLocationManager.authorizationStatus() }
        switch status {
        case .notDetermined:
            guard await requestLocation() else { return nil }
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        let precise = await MainActor.run { locationManager.accuracyAuthorization == .fullAccuracy }
        guard precise else {
            UTLog.warning("Wi-Fi 名称：定位为大致位置，需精确位置才能读 SSID", category: "系统信息")
            return nil
        }
        let ssid = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in
                c.resume(returning: network?.ssid)
            }
        }
        if ssid == nil {
            UTLog.warning("Wi-Fi 名称：fetchCurrent 返回空（可能缺 wifi-info entitlement）", category: "系统信息")
        }
        return ssid
    }

    /// 请求使用时定位授权，轮询最多 20 秒等用户作答（不回答视为拒绝，走后备路线）。
    private func requestLocation() async -> Bool {
        await MainActor.run { locationManager.requestWhenInUseAuthorization() }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let status = await MainActor.run { CLLocationManager.authorizationStatus() }
            if status != .notDetermined {
                return status == .authorizedWhenInUse || status == .authorizedAlways
            }
            if Task.isCancelled { break }
        }
        return false
    }

    // MARK: - 逃逸读配置文件（后备）

    private func escapeSSID() async -> WiFiInfo? {
        // 当前网络的 BSSID（network.identification.plist 记录最后连接的网络）
        var currentBSSID: String?
        if let data = await EscapeService.shared.readFile("/private/var/preferences/SystemConfiguration/com.apple.network.identification.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            currentBSSID = Self.bssidString(plist["BSSID"])
        }

        var networks: [(ssid: String, bssid: String?, lastJoin: Date?)] = []
        // airport.preferences.plist：KnownNetworks
        if let data = await EscapeService.shared.readFile("/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let known = plist["KnownNetworks"] as? [String: Any] {
            for (_, v) in known {
                guard let entry = v as? [String: Any] else { continue }
                let ssid = (entry["SSIDString"] as? String) ?? Self.stringFromBytes(entry["SSID"])
                let bssid = Self.bssidString(entry["BSSID"])
                let last = Self.latestDate([entry["JoinedBySystemAt"], entry["JoinedByUserAt"], entry["LastAutoJoinAt"]])
                if let ssid { networks.append((ssid, bssid, last)) }
            }
        }
        // com.apple.wifi.plist：List of known networks
        if let data = await EscapeService.shared.readFile("/private/var/preferences/SystemConfiguration/com.apple.wifi.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let list = plist["List of known networks"] as? [[String: Any]] {
            for entry in list {
                let ssid = (entry["SSID_STR"] as? String) ?? Self.stringFromBytes(entry["SSID_STR"])
                let bssid = Self.bssidString(entry["BSSID"])
                let last = Self.latestDate([entry["lastJoined"], entry["lastAutoJoined"], entry["lastUpdated"]])
                if let ssid { networks.append((ssid, bssid, last)) }
            }
        }
        // com.apple.wifi.known-networks.plist
        if let data = await EscapeService.shared.readFile("/private/var/preferences/com.apple.wifi.known-networks.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            for (_, v) in plist {
                guard let entry = v as? [String: Any] else { continue }
                let ssid = Self.stringFromBytes(entry["SSID"])
                var bssid: String?
                if let spec = entry["__OSSpecific__"] as? [String: Any] { bssid = Self.bssidString(spec["BSSID"]) }
                bssid = bssid ?? Self.bssidString(entry["BSSID"])
                let last = Self.latestDate([entry["JoinedBySystemAt"], entry["JoinedByUserAt"], entry["UpdatedAt"]])
                if let ssid { networks.append((ssid, bssid, last)) }
            }
        }

        guard !networks.isEmpty else {
            UTLog.warning("Wi-Fi 名称：逃逸读系统 Wi-Fi 配置无数据（/private/var/preferences 可能不可达）", category: "系统信息")
            return nil
        }
        // 优先按 BSSID 匹配当前网络
        if let current = currentBSSID,
           let match = networks.first(where: { $0.bssid.map(Self.normalizeBSSID) == Self.normalizeBSSID(current) }) {
            return WiFiInfo(ssid: match.ssid, source: "系统 Wi-Fi 配置（按 BSSID 匹配）")
        }
        // 否则取最近加入的（启发式，可能不准）
        if let latest = networks.compactMap({ n -> (String, Date)? in n.lastJoin.map { (n.ssid, $0) } }).max(by: { $0.1 < $1.1 }) {
            return WiFiInfo(ssid: latest.0, source: "系统 Wi-Fi 配置（最近加入）")
        }
        return nil
    }

    private static func bssidString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let d = value as? Data, !d.isEmpty {
            return d.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }

    private static func normalizeBSSID(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
    }

    private static func stringFromBytes(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let d = value as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        return nil
    }

    private static func latestDate(_ values: [Any?]) -> Date? {
        values.compactMap { $0 as? Date }.max()
    }
}
