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
                                Button("选择大型缓存") { selectLarge() }
                                    .buttonStyle(.bordered)
                                    .disabled(service.items.isEmpty)
                                Button("全选") {
                                    for i in service.items.indices { service.items[i].selected = true }
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
                                set: { v in
                                    if let i = service.items.firstIndex(of: item) {
                                        service.items[i].selected = v
                                    }
                                }
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

    private func selectLarge() {
        for i in service.items.indices {
            service.items[i].selected = service.items[i].size >= 100 * 1024 * 1024
        }
    }

    private func unavailableReason(_ status: ModuleStatus) -> String {
        switch status {
        case .unavailable(let r): return r + "仍可清理本 App 自身缓存。"
        case .limited(let n): return n + "仍可清理本 App 自身缓存。"
        case .available: return ""
        }
    }
}
