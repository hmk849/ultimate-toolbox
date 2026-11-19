import SwiftUI

/// 工具页：App 核心，六大工具入口 + 各模块真实可用状态。

struct ToolsView: View {
    @EnvironmentObject var compat: CompatibilityService

    var body: some View {
        List {
            Section("工具") {
                toolRow(
                    icon: "trash.fill", color: .orange,
                    title: L10n.cacheCleaner, subtitle: "扫描并清理可访问的缓存",
                    status: compat.report?.crossAppCache,
                    destination: AnyView(CacheCleanerView())
                )
                toolRow(
                    icon: "folder.fill", color: .blue,
                    title: L10n.fileManager, subtitle: "浏览、搜索、编辑可访问的文件",
                    status: compat.report?.crossAppFiles,
                    destination: AnyView(FileManagerView())
                )
                toolRow(
                    icon: "info.circle", color: .green,
                    title: L10n.systemInfo, subtitle: "公开 API 可读取的设备与系统信息",
                    status: .available,
                    destination: AnyView(SystemInfoView())
                )
                toolRow(
                    icon: "list.bullet.rectangle", color: .purple,
                    title: L10n.plistEditor, subtitle: "编辑可访问的 Plist 文件",
                    status: .available,
                    destination: AnyView(PlistEditorView())
                )
                toolRow(
                    icon: "gearshape.fill", color: .red,
                    title: L10n.gestalt, subtitle: "MobileGestalt 预设与字段编辑",
                    status: compat.report?.gestalt,
                    destination: AnyView(GestaltView())
                )
                toolRow(
                    icon: "externaldrive.fill", color: .teal,
                    title: L10n.backup, subtitle: "真实备份文件，含完整性校验",
                    status: .available,
                    destination: AnyView(BackupView())
                )
            }
            Section("说明") {
                Text("跨 App 功能依赖 worse_query 沙盒逃逸：iOS 27.0.1 可用，27.3 beta 2 起已被 Apple 修补，届时对应模块会自动禁用并说明原因。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("改了能力键不等于功能生效：多数 MobileGestalt 预设只是向系统宣称具备某能力，硬件或服务端不配合就没有实际效果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.tools)
    }

    private func toolRow(icon: String, color: Color, title: String, subtitle: String, status: ModuleStatus?, destination: AnyView) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                SettingsIconTile(systemName: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status {
                    Text(statusLabel(status))
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(statusColor(status).opacity(0.18), in: Capsule())
                        .foregroundStyle(statusColor(status))
                }
            }
        }
    }
}
