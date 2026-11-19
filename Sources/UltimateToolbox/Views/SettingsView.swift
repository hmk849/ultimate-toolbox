import SwiftUI

/// 设置：外观（浅色/深色/跟随系统）、强调色（预设 + 系统调色盘）、语言、日志、自动备份、数据管理、隐私、开源许可、版本、检查更新、重置、开发者。

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logStore: LogStore
    @StateObject private var auth = GitHubAuthService.shared
    @StateObject private var api = GitHubAPIService.shared
    @State private var customColor: Color = .blue
    @State private var showResetConfirm = false
    @State private var showClearLogsConfirm = false
    @State private var showLogoutConfirm = false
    @State private var updateMessage: String?
    @State private var showUpdateAlert = false
    @State private var isCheckingUpdate = false

    var body: some View {
        List {
            Section("账号与设备") {
                HStack {
                    Text("本机设备")
                    Spacer()
                    Text("\(SystemInfoService.marketingName(for: SystemInfoService.deviceModelIdentifier())) · iOS \(UIDevice.current.systemVersion)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("GitHub 账号")
                    Spacer()
                    if auth.isLoggedIn {
                        Text("@\(api.user?.login ?? "已登录")").foregroundStyle(.secondary)
                    } else {
                        Text("未登录").foregroundStyle(.secondary)
                    }
                }
                if auth.isLoggedIn {
                    Button("注销设备", role: .destructive) { showLogoutConfirm = true }
                } else {
                    Text("去 GitHub 页登录后，这里会显示账号并可一键注销。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("外观") {
                Picker("外观", selection: Binding(
                    get: { settings.appearance },
                    set: { settings.appearance = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("强调色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(AccentPreset.presets) { preset in
                        Button {
                            settings.setAccentPreset(preset.id)
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if settings.accentName == preset.name {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                                .font(.caption).fontWeight(.bold)
                                        }
                                    }
                                Text(preset.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("自定义颜色（系统调色盘）", selection: Binding(
                    get: { customColor },
                    set: { newValue in
                        customColor = newValue
                        if let hex = newValue.toHex() {
                            settings.setAccentCustom(hex)
                        }
                    }
                ))
                Text("当前强调色：\(settings.accentName)，将同步应用到按钮、图标、选中状态、开关、导航栏与卡片细节。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("界面显示") {
                Picker("字体大小", selection: Binding(
                    get: { settings.textSize },
                    set: { settings.textSize = $0 }
                )) {
                    ForEach(TextSizeOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                Picker("界面密度", selection: Binding(
                    get: { settings.uiDensity },
                    set: { settings.uiDensity = $0 }
                )) {
                    ForEach(UIDensity.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("预览")
                    Spacer()
                    Text("示例文字 Aa").foregroundStyle(.secondary)
                }
                Text("立即生效，作用于全部页面。字体大小为 App 内独立设置，不影响系统其他 App。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("语言") {
                Picker("语言", selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("日志与备份") {
                Toggle("自动备份（修改 Plist / 恢复前）", isOn: $settings.autoBackup)
                Picker("日志保留", selection: $settings.logRetentionDays) {
                    Text("3 天").tag(3)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                Button("清空运行日志", role: .destructive) { showClearLogsConfirm = true }
            }
            Section("数据管理") {
                Text("日志文件：Documents/Logs/ultimate-toolbox.log")
                    .font(.caption).foregroundStyle(.secondary)
                Text("备份目录：Documents/Backups/")
                    .font(.caption).foregroundStyle(.secondary)
                Text("导入的文件：Documents/Imported/")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私说明") {
                Text("本 App 不收集、不上传任何个人数据。GitHub Token 只存本机 Keychain；日志、备份只存本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("开源许可") {
                Text("本 App 采用 MIT 开源。逃逸引擎源自 KAMUI（MIT）；预设键表为自写；另受 GestaltEdit、WQ Files、Erosion 启发（其代码未直接使用）。完整说明见仓库 LICENSES.md。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("版本信息") {
                HStack { Text("版本"); Spacer(); Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")（build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）").foregroundStyle(.secondary) }
                HStack { Text("最低 iOS"); Spacer(); Text("26.0").foregroundStyle(.secondary) }
                Button(isCheckingUpdate ? "正在检查…" : "检查更新") {
                    Task { await checkUpdate() }
                }
                .disabled(isCheckingUpdate)
            }
            Section("开发者") {
                Link("hmk849", destination: URL(string: "https://github.com/hmk849")!)
                Link("hmk11131", destination: URL(string: "https://github.com/hmk11131")!)
                Link("chjc0r（X）", destination: URL(string: "https://x.com/chjc0r?s=11")!)
            }
            Section {
                Button("重置应用设置", role: .destructive) { showResetConfirm = true }
            }
        }
        .navigationTitle(L10n.settings)
        .alert("注销设备？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("注销", role: .destructive) {
                auth.logout()
                api.clear()
            }
        } message: {
            Text("将删除本机 Keychain 中的 GitHub Token，并清除已加载的 GitHub 个人信息。撤销授权请到 github.com/settings/applications 操作。")
        }
        .alert("重置应用设置？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                settings.resetAll()
                UTLog.info("应用设置已重置", category: "设置")
            }
        } message: {
            Text("将恢复外观、强调色、语言、自动备份等设置为默认值，不会删除日志与备份文件。")
        }
        .alert("清空日志？", isPresented: $showClearLogsConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                logStore.clear()
                UTLog.info("日志已清空", category: "日志")
            }
        } message: {
            Text("将清空当前日志列表并删除日志文件。")
        }
        .alert("检查更新", isPresented: $showUpdateAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(updateMessage ?? "")
        }
    }

    private func checkUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/hmk849/ultimate-toolbox/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("UltimateToolbox-iOS", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                updateMessage = "检查失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）"
                showUpdateAlert = true
                return
            }
            struct Latest: Decodable { let tag_name: String }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            let current = "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
            if latest.tag_name == current {
                updateMessage = "当前已是最新版本（\(current)）。"
            } else {
                updateMessage = "发现新版本 \(latest.tag_name)，请到 GitHub Releases 下载。"
            }
            showUpdateAlert = true
            UTLog.info("检查更新：最新 \(latest.tag_name)", category: "设置")
        } catch {
            updateMessage = "检查失败：\(error.localizedDescription)"
            showUpdateAlert = true
        }
    }
}
