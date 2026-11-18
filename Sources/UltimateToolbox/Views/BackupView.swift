import SwiftUI

/// 备份与恢复：真实生成备份文件（manifest + SHA-256），恢复前先备份当前数据。

struct BackupView: View {
    @StateObject private var service = BackupService.shared
    @State private var isBackingUp = false
    @State private var showDeleteConfirm: BackupEntry?
    @State private var restoringEntry: BackupEntry?
    @State private var showRestoreConfirm = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        List {
            Section("创建备份") {
                Button {
                    isBackingUp = true
                    Task {
                        let entry = await service.backupAppData()
                        isBackingUp = false
                        resultMessage = entry != nil ? "应用数据备份已创建并通过完整性校验。" : "备份失败，请查看运行日志。"
                        showResult = true
                    }
                } label: {
                    Label("备份应用数据", systemImage: "externaldrive.badge.plus")
                }
                .disabled(isBackingUp)
                Text("备份 Documents 下除 Backups 外的全部内容，生成 manifest.json 并对每个文件做 SHA-256 校验。MobileGestalt 原始文件在首次读取时已由引擎自动备份。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("备份列表（\(service.backups.count) 个）") {
                if service.backups.isEmpty {
                    Text("暂无备份").foregroundStyle(.secondary)
                }
                ForEach(service.backups) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.manifest.label).font(.subheadline).fontWeight(.medium)
                        Text("\(entry.manifest.items.count) 个文件 · \(SystemInfoService.formatBytes(entry.totalSize))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.manifest.createdAt, style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Button("恢复") {
                                restoringEntry = entry
                                showRestoreConfirm = true
                            }
                            Button("导出") {
                                shareURL = entry.url
                                showShare = true
                            }
                            Button("删除", role: .destructive) {
                                showDeleteConfirm = entry
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L10n.backup)
        .navigationBarTitleDisplayMode(.inline)
        .alert("恢复备份？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认恢复", role: .destructive) {
                if let entry = restoringEntry {
                    Task {
                        let ok = await service.restore(entry)
                        resultMessage = ok ? "备份已恢复（恢复前当前数据已自动备份）。" : "恢复部分失败，请查看运行日志。"
                        showResult = true
                    }
                }
            }
        } message: {
            Text("恢复前会自动备份当前数据。备份文件将写回原位置。")
        }
        .alert("删除备份？", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let entry = showDeleteConfirm { _ = service.delete(entry) }
            }
        } message: {
            Text("将永久删除备份「\(showDeleteConfirm?.manifest.label ?? "")」。")
        }
        .alert("结果", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareLink(item: shareURL) { Text("分享备份文件夹") }
                    .presentationDetents([.medium])
            }
        }
        .onAppear { service.refresh() }
    }
}
