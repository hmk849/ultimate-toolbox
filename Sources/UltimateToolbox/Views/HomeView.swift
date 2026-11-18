import SwiftUI
import UniformTypeIdentifiers

/// 主页：实时运行日志（Erosion 日志页风格）+ 设备信息 + API 初始化状态 + 系统检测结果 + 各类操作记录。

struct HomeView: View {
    @EnvironmentObject var logStore: LogStore
    @EnvironmentObject var compat: CompatibilityService
    @EnvironmentObject var systemInfo: SystemInfoService
    @EnvironmentObject var settings: AppSettings

    @State private var searchText = ""
    @State private var selectedLevel: LogLevel?
    @State private var selectedCategory: String?
    @State private var showClearConfirm = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var copiedToast = false

    var filtered: [LogEntry] {
        logStore.filtered(level: selectedLevel, category: selectedCategory, query: searchText).reversed()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                deviceCard
                statusCard
                recordsCard
                logCard
            }
            .padding()
        }
        .navigationTitle(L10n.runLog)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { copyLogs() } label: { Image(systemName: "doc.on.doc") }
                Button { exportLogs() } label: { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { showClearConfirm = true } label: { Image(systemName: "trash") }
            }
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

    private var deviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("设备", systemImage: "iphone").font(.headline)
                Text(SystemInfoService.marketingName(for: SystemInfoService.deviceModelIdentifier()))
                    .font(.title3).fontWeight(.semibold)
                Text("iOS \(UIDevice.current.systemVersion)（Build \(compat.build)）")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Ultimate Toolbox v1.0.0（build 1）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("API 初始化与系统检测", systemImage: "checkmark.seal.fill").font(.headline)
                if let report = compat.report {
                    statusRow("逃逸引擎", status: report.escapeAvailable ? .available : .unavailable(reason: report.escapeDetail))
                    statusRow("MobileGestalt 编辑", status: report.gestalt)
                    statusRow("跨 App 文件访问", status: report.crossAppFiles)
                    statusRow("跨 App 缓存清理", status: report.crossAppCache)
                    statusRow("崩溃日志", status: report.crashLogs)
                    if case .unavailable(let reason) = report.gestalt {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                } else if compat.probing {
                    ProgressView("正在检测…")
                } else {
                    Text("尚未检测").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var recordsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("操作记录", systemImage: "clock.arrow.circlepath").font(.headline)
                recordRow("缓存清理", category: "缓存清理")
                recordRow("文件操作", category: "文件管理")
                recordRow("备份与恢复", category: "备份")
                recordRow("MobileGestalt", category: "MobileGestalt")
                recordRow("GitHub", category: "GitHub")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private var logCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("实时日志", systemImage: "terminal.fill").font(.headline)
                    Spacer()
                    Text("\(filtered.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                // 级别筛选
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        levelChip(nil, label: "全部")
                        ForEach(LogLevel.allCases) { level in
                            levelChip(level, label: level.label)
                        }
                    }
                }
                // 分类筛选
                if !logStore.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip(nil)
                            ForEach(logStore.categories, id: \.self) { cat in
                                categoryChip(cat)
                            }
                        }
                    }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
