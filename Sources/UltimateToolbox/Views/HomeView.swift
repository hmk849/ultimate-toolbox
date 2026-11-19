import SwiftUI
import UniformTypeIdentifiers

/// 主页：iOS 设置风格的分组列表（设备 / 系统检测 / 云编译 / 操作记录 / 实时日志）。
/// 原卡片式布局已改为 insetGrouped 分组列表，功能不变；版本号改为动态读取，不再硬编码。

struct HomeView: View {
    @EnvironmentObject var logStore: LogStore
    @EnvironmentObject var compat: CompatibilityService
    @EnvironmentObject var systemInfo: SystemInfoService
    @EnvironmentObject var settings: AppSettings
    @StateObject private var auth = GitHubAuthService.shared
    @StateObject private var build = GitHubBuildService.shared

    @State private var searchText = ""
    @State private var selectedLevel: LogLevel?
    @State private var selectedCategory: String?
    @State private var showClearConfirm = false
    @State private var showRespringConfirm = false
    @State private var shareURL: URL?
    @State private var showShare = false

    var filtered: [LogEntry] {
        logStore.filtered(level: selectedLevel, category: selectedCategory, query: searchText).reversed()
    }

    private var appVersion: String {
        let d = Bundle.main.infoDictionary
        let v = d?["CFBundleShortVersionString"] as? String ?? "?"
        let b = d?["CFBundleVersion"] as? String ?? "?"
        return "v\(v)（build \(b)）"
    }

    private var buildPhaseColor: Color {
        switch build.phase {
        case .succeeded: return .green
        case .failed: return .red
        case .dispatching, .queued, .running: return .orange
        case .idle: return .secondary
        }
    }

    /// 软重启依赖逃逸引擎：27.0.1 可用，27.3 beta 2 起被修补后不可用。
    private var respringAvailable: Bool {
        compat.report?.escapeAvailable == true
    }

    private var respringSubtitle: String {
        if let report = compat.report {
            return report.escapeAvailable ? "重启 SpringBoard（桌面）" : report.escapeDetail
        }
        return "正在检测逃逸状态…"
    }

    var body: some View {
        List {
            Section("设备") {
                settingsRow(icon: "iphone", color: .gray, title: "设备", value: SystemInfoService.marketingName(for: SystemInfoService.deviceModelIdentifier()))
                settingsRow(icon: "applelogo", color: .gray, title: "系统", value: "iOS \(UIDevice.current.systemVersion)（Build \(compat.build)）")
                settingsRow(icon: "app.badge", color: .blue, title: "App 版本", value: appVersion)
            }

            Section("设备操作") {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "arrow.triangle.2.circlepath", color: .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("软重启（Respring）")
                        Text(respringSubtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if respringAvailable {
                        Button("执行") { showRespringConfirm = true }
                            .buttonStyle(.bordered)
                    } else {
                        Text("不可用").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!respringAvailable)
            } footer: {
                Text("软重启只重启 SpringBoard（桌面），正在运行的 App 会被关闭；不是整机重启。整机重启仍需用电源键或设置 → 通用 → 关机。")
            }

            Section {
                if let report = compat.report {
                    statusRow("逃逸引擎", status: report.escapeAvailable ? .available : .unavailable(reason: report.escapeDetail))
                    statusRow("MobileGestalt 编辑", status: report.gestalt)
                    statusRow("跨 App 文件访问", status: report.crossAppFiles)
                    statusRow("跨 App 缓存清理", status: report.crossAppCache)
                    statusRow("崩溃日志", status: report.crashLogs)
                } else if compat.probing {
                    HStack {
                        ProgressView()
                        Text("正在检测…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("尚未检测").foregroundStyle(.secondary)
                }
            } header: {
                Text("系统检测")
            } footer: {
                if let report = compat.report, case .unavailable(let reason) = report.gestalt {
                    Text(reason)
                }
            }

            Section {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "hammer.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub 云编译")
                        Text("hmk849/ultimate-toolbox · main")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(build.statusText)
                        .font(.subheadline)
                        .foregroundStyle(buildPhaseColor)
                }
                if let err = build.errorMessage {
                    Text(err).font(.subheadline).foregroundStyle(.red)
                }
                Button {
                    Task { await build.triggerBuild() }
                } label: {
                    HStack {
                        Spacer()
                        Text(build.isBusy ? "编译中…" : "一键编译")
                        Spacer()
                    }
                }
                .disabled(build.isBusy || !auth.isLoggedIn)
                if build.isBusy {
                    Button("取消", role: .destructive) { build.cancel() }
                }
                if let url = build.runURL {
                    Link("在 GitHub 查看构建", destination: url)
                }
                if !auth.isLoggedIn {
                    Text("请先到 GitHub 页登录（需要 repo / workflow 权限）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("云编译")
            } footer: {
                Text("编译产物在构建页 Artifacts 里下载（需登录 GitHub）；Release 仍需在 GitHub Releases 页发布。")
            }

            Section("操作记录") {
                recordRow("缓存清理", category: "缓存清理")
                recordRow("文件操作", category: "文件管理")
                recordRow("备份与恢复", category: "备份")
                recordRow("MobileGestalt", category: "MobileGestalt")
                recordRow("GitHub", category: "GitHub")
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        levelChip(nil, label: "全部")
                        ForEach(LogLevel.allCases) { level in
                            levelChip(level, label: level.label)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                if !logStore.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip(nil)
                            ForEach(logStore.categories, id: \.self) { cat in
                                categoryChip(cat)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
                ForEach(filtered.prefix(100)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(logStore.timeString(entry.date))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                        Text(entry.level.label)
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(logColor(entry.level))
                            .frame(width: 58, alignment: .leading)
                        Text(entry.message)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if filtered.isEmpty {
                    Text("暂无符合条件的日志").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("实时日志")
                    Spacer()
                    Text("\(filtered.count) 条")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.runLog)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { copyLogs() } label: { Image(systemName: "doc.on.doc") }
                Button { exportLogs() } label: { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { showClearConfirm = true } label: { Image(systemName: "trash") }
            }
        }
        .alert("软重启？", isPresented: $showRespringConfirm) {
            Button("取消", role: .cancel) {}
            Button("软重启", role: .destructive) {
                Task { await GestaltService.shared.respring() }
            }
        } message: {
            Text("将重启 SpringBoard（桌面），正在运行的 App 会被关闭。")
        }
        .alert("清空日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                logStore.clear()
                UTLog.info("日志已清空", category: "日志")
            }
        } message: {
            Text("将清空当前日志列表并删除日志文件，此操作不可恢复。")
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareLink(item: shareURL) { Text("分享日志文件") }
                    .presentationDetents([.medium])
            }
        }
        .searchable(text: $searchText, prompt: "搜索日志")
    }

    private func settingsRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: icon, color: color)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ title: String, status: ModuleStatus) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(statusLabel(status))
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(statusColor(status).opacity(0.18), in: Capsule())
                .foregroundStyle(statusColor(status))
        }
        .font(.subheadline)
    }

    private func recordRow(_ title: String, category: String) -> some View {
        let count = logStore.entries.filter { $0.category == category }.count
        let last = logStore.entries.filter { $0.category == category }.last
        return HStack {
            Text(title)
            Spacer()
            if let last {
                Text(last.message).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(count) 条").font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func levelChip(_ level: LogLevel?, label: String) -> some View {
        Button {
            selectedLevel = level
        } label: {
            Text(label)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selectedLevel == level ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(selectedLevel == level ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func categoryChip(_ category: String?) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Text(category ?? "全部")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selectedCategory == category ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(selectedCategory == category ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func copyLogs() {
        UIPasteboard.general.string = logStore.exportText()
        UTLog.info("日志已复制到剪贴板", category: "日志")
    }

    private func exportLogs() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ultimate-toolbox-log.txt")
        try? logStore.exportText().write(to: url, atomically: true, encoding: .utf8)
        shareURL = url
        showShare = true
    }
}
