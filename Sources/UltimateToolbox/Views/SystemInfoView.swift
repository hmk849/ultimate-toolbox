import SwiftUI

/// 系统信息：公开 API 可读取的设备与系统信息；读不到的项明确标"不可读取"。

struct SystemInfoView: View {
    @StateObject private var service = SystemInfoService.shared

    var body: some View {
        List {
            ForEach(service.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        InfoRowView(row: row)
                    }
                }
            }
            Section("说明") {
                Text("电池健康、Wi-Fi 名称等无公开 API 的信息已标记为不可读取，不会伪造数据。内核版本通过公开 sysctl 读取，若系统限制则显示不可读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.systemInfo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { service.refresh() }
            }
        }
        .onAppear { service.refresh() }
    }
}
