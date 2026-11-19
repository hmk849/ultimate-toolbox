import SwiftUI

@main
struct UltimateToolboxApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var logStore = LogStore.shared
    @StateObject private var compat = CompatibilityService.shared
    @StateObject private var systemInfo = SystemInfoService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(logStore)
                .environmentObject(compat)
                .environmentObject(systemInfo)
                .preferredColorScheme(settings.colorScheme)
                .accentColor(settings.accentColor)
                .dynamicTypeSize(settings.textSize.dynamicTypeSize)
                .environment(\.defaultMinListRowHeight, settings.uiDensity.minRowHeight)
                .task {
                    await startup()
                }
        }
    }

    private func startup() async {
        let device = UIDevice.current
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        UTLog.info("Ultimate Toolbox 启动：v\(appVersion) (build \(appBuild))", category: "启动")
        UTLog.info("设备：\(SystemInfoService.marketingName(for: SystemInfoService.deviceModelIdentifier()))（\(SystemInfoService.deviceModelIdentifier())）", category: "启动")
        UTLog.info("系统：iOS \(device.systemVersion)，Build \(CompatibilityService.shared.build)", category: "启动")
        SystemInfoService.shared.startNetworkMonitor()
        UTLog.info("API 初始化：网络监听已启动", category: "启动")
        await CompatibilityService.shared.probe()
        SystemInfoService.shared.refresh()
        UTLog.info("系统检测完成", category: "启动")
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label(L10n.home, systemImage: "house.fill") }
            NavigationStack { ToolsView() }
                .tabItem { Label(L10n.tools, systemImage: "wrench.and.screwdriver.fill") }
            NavigationStack { GitHubView() }
                .tabItem { Label(L10n.github, systemImage: "chevron.left.forwardslash.chevron.right") }
            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.settings, systemImage: "gearshape.fill") }
        }
    }
}
