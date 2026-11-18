import SwiftUI

/// 缓存清理：真实扫描、真实删除、清理后重新计算容量。

struct CacheCleanerView: View {
    @StateObject private var service = CacheCleanerService.shared
    @EnvironmentObject var compat: CompatibilityService
    @State private var showCleanConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if let report = compat.report, report.crossAppCache != .available {
                        UnavailableCard(title: "跨 App 缓存清理不可用", reason: unavailableReason(report.crossAppCache))
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("缓存总容量")
                                    .font(.headline)
                                Spacer()
                                Text(SystemInfoService.formatBytes(service.totalSize))
                                    .font(.title3).fontWeight(.bold)
                            }
                            Text("已选 \(service.items.filter { $0.selected }.count) 项，共 \(SystemInfoService.formatBytes(service.selectedSize))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(service.status)
                                .font(.caption).foregroundStyle(.secondary)
                            if service.isScanning || service.isCleaning {
                                ProgressView(value: service.progress)
                            }
                            HStack(spacing: 12) {
                                Button("扫描") { service.scan() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(service.isScanning || service.isCleaning)
                                Button("选择大型缓存") { service.selectLarge() }
                                    .buttonStyle(.bordered)
                                    .disabled(service.items.isEmpty)
                                Button("全选") {
                                    service.selectAll(true)
                                }
                                .buttonStyle(.bordered)
                                .disabled(service.items.isEmpty)
                                Spacer()
                                Button("清理已选") { showCleanConfirm = true }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                    .disabled(service.selectedSize == 0 || service.isCleaning || service.isScanning)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if service.items.isEmpty && !service.isScanning {
                        Text("点击「扫描」开始检测可访问的缓存。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(service.items) { item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { item.selected },
                                set: { v in service.setSelected(id: item.id, value: v) }
                            ))
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline).fontWeight(.medium)
                                Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(SystemInfoService.formatBytes(item.size))
                                .font(.subheadline).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 4)
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.s("会清理", "Will clean"))
                                .font(.subheadline).fontWeight(.semibold)
                            Text(L10n.s("本 App 的 Library/Caches 与 tmp；App Group 的 Library/Caches；其他 App（含插件容器）的 Library/Caches 与 tmp；崩溃日志。只删目录里的内容，保留 Caches / tmp 目录本身。", "This app's Library/Caches and tmp; the App Group's Library/Caches; other apps' (including plugin containers') Library/Caches and tmp; crash logs. Only the contents are deleted; the Caches / tmp folders themselves are kept."))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(L10n.s("不会清理", "Will NOT clean"))
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.top, 4)
                            Text(L10n.s("各 App 的 Documents（聊天记录、下载、离线文件）、照片与视频、通讯录、钥匙串、系统文件。清理前不备份，删除不可恢复；有些 App 把离线内容（音乐、地图）放在 Caches 里，清了要重新下载。", "Apps' Documents (chats, downloads, offline files), photos and videos, contacts, Keychain, system files. No backup is made before cleaning and deletion cannot be undone; some apps keep offline content (music, maps) in Caches and will need to download it again."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(L10n.cacheCleaner)
        .navigationBarTitleDisplayMode(.inline)
        .alert("清理前确认", isPresented: $showCleanConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) {
                Task { await service.cleanSelected() }
            }
        } message: {
            Text("将删除已选 \(service.items.filter { $0.selected }.count) 项缓存，共 \(SystemInfoService.formatBytes(service.selectedSize))。此操作不可恢复（跨 App 缓存清理无备份）。")
        }
        .onAppear { if service.items.isEmpty { service.scan() } }
    }

    private func unavailableReason(_ status: ModuleStatus) -> String {
        switch status {
        case .unavailable(let r): return r + "仍可清理本 App 自身缓存。"
        case .limited(let n): return n + "仍可清理本 App 自身缓存。"
        case .available: return ""
        }
    }
}
