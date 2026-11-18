import SwiftUI

/// MobileGestalt：预设（多选 + 统一 Apply + 互斥）+ CacheExtra 字段编辑器 + 备份/恢复 + Respring。
/// 首次读取时引擎自动备份原始 plist；写入后重读验证。

struct GestaltView: View {
    @StateObject private var service = GestaltService.shared
    @EnvironmentObject var compat: CompatibilityService
    @State private var selectedPresets: Set<String> = []
    @State private var islandSubtype: Int = 2868
    @State private var searchText = ""
    @State private var editingField: (key: String, value: PlistValue)?
    @State private var showAddField = false
    @State private var newFieldName = ""
    @State private var newFieldKind: PlistValueKind = .integer
    @State private var showApplyConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showRespringConfirm = false
    @State private var showSiriPhase2Confirm = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        Group {
            if let report = compat.report, report.gestalt != .available {
                ScrollView {
                    UnavailableCard(title: "MobileGestalt 编辑不可用", reason: {
                        switch report.gestalt {
                        case .unavailable(let r): return r
                        case .limited(let n): return n
                        case .available: return ""
                        }
                    }())
                    .padding()
                }
            } else if !service.loaded {
                VStack(spacing: 16) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("读取 MobileGestalt 缓存")
                        .font(.headline)
                    Text("首次读取会自动备份原始 plist 到引擎备份位置。读取需要沙盒逃逸（iOS 27.0.1 可用）。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    if service.isLoading {
                        ProgressView()
                    } else {
                        Button("读取") { Task { await service.load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if let error = service.errorMessage {
                        Text(error).foregroundStyle(.red).font(.subheadline).padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedView
            }
        }
        .navigationTitle(L10n.gestalt)
        .navigationBarTitleDisplayMode(.inline)
        .alert("应用预设", isPresented: $showApplyConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认应用", role: .destructive) {
                Task {
                    let presets = MGPresets.all.filter { selectedPresets.contains($0.id) }
                    let ok = await service.applyPresets(presets, islandSubtype: selectedPresets.contains("dynamic-island") ? islandSubtype : nil)
                    resultMessage = ok ? "预设已写入并验证通过。部分改动需要 Respring 或重启后生效。" : "写入失败：\(service.errorMessage ?? "未知错误")"
                    showResult = true
                }
            }
        } message: {
            Text("将把选中的 \(selectedPresets.count) 个预设写入 MobileGestalt 缓存。写入前原始文件已有备份，写入后会重读验证。")
        }
        .alert("恢复原始备份", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认恢复", role: .destructive) {
                Task {
                    let ok = await service.restoreBackup()
                    resultMessage = ok ? "已恢复到原始备份。" : "恢复失败：\(service.errorMessage ?? "未知错误")"
                    showResult = true
                }
            }
        } message: {
            Text("将用首次读取时自动创建的原始备份覆盖当前 MobileGestalt 缓存。")
        }
        .alert("Respring", isPresented: $showRespringConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认 Respring", role: .destructive) {
                Task { await service.respring() }
            }
        } message: {
            Text("Respring 会重启 SpringBoard 以使改动生效。")
        }
        .alert("Siri AI 第二步", isPresented: $showSiriPhase2Confirm) {
            Button("取消", role: .cancel) {}
            Button("确认还原身份", role: .destructive) {
                Task {
                    let ok = await service.restoreSiriIdentity()
                    resultMessage = ok ? "身份键已还原，SiriMode 已保留。" : "还原失败：\(service.errorMessage ?? "未知错误")"
                    showResult = true
                }
            }
        } message: {
            Text("仅当模型已下载完成后再执行：删除身份伪装键，保留 SiriMode。")
        }
        .alert("结果", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var loadedView: some View {
        List {
            Section("预设（多选，统一应用）") {
                ForEach(MGPresets.all) { preset in
                    let selected = selectedPresets.contains(preset.id)
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            togglePreset(preset)
                        } label: {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(preset.displayName).font(.subheadline).fontWeight(.medium)
                                if case .high = preset.risk {
                                    Text("高危").font(.caption).fontWeight(.bold)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.red.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(preset.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { togglePreset(preset) }
                }
                if selectedPresets.contains("dynamic-island") {
                    Picker("灵动岛子类型", selection: $islandSubtype) {
                        ForEach(MGPresets.dynamicIslandSubtypes, id: \.subtype) { item in
                            Text(item.label).tag(item.subtype)
                        }
                    }
                }
                Button("统一应用所选预设") { showApplyConfirm = true }
                    .disabled(selectedPresets.isEmpty)
                if selectedPresets.contains("siri-ai") {
                    Button("Siri AI 第二步：还原身份键") { showSiriPhase2Confirm = true }
                }
            }
            Section("CacheExtra 字段编辑器（\(service.cacheExtra.count) 个键）") {
                ForEach(filteredFields, id: \.key) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.key).font(.caption).fontWeight(.medium)
                            Text(item.value.displayString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(item.value.kind.rawValue).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingField = item }
                    .swipeActions {
                        Button(role: .destructive) {
                            service.deleteField(key: item.key)
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
                Button("新增字段") { showAddField = true }
                Button("保存字段修改") {
                    Task {
                        let ok = await service.saveFields()
                        resultMessage = ok ? "字段已保存并验证通过。" : "保存失败：\(service.errorMessage ?? "未知错误")"
                        showResult = true
                    }
                }
            }
            Section("备份与生效") {
                Button("恢复原始备份") { showRestoreConfirm = true }
                Button("Respring 使改动生效") { showRespringConfirm = true }
                Text("首次读取时已自动备份原始 plist。恢复前当前内容不会被额外备份，请谨慎操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("说明") {
                Text("这些键只是向系统宣称具备某能力，不代表硬件或服务端一定生效。改了键不等于功能可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $searchText, prompt: "搜索 CacheExtra 字段")
        .sheet(item: Binding(
            get: { editingField.map { EditableKey(key: $0.key, value: $0.value) } },
            set: { _ in editingField = nil }
        )) { editable in
            PlistValueEditorSheet(key: editable.key, value: editable.value) { newValue in
                service.setField(key: editable.key, value: newValue)
            }
        }
        .alert("新增字段", isPresented: $showAddField) {
            TextField("字段名（哈希键）", text: $newFieldName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                guard !newFieldName.isEmpty else { return }
                service.setField(key: newFieldName, value: PlistValue.empty(kind: newFieldKind))
                newFieldName = ""
            }
        }
    }

    private var filteredFields: [(key: String, value: PlistValue)] {
        guard !searchText.isEmpty else { return service.cacheExtra }
        return service.cacheExtra.filter {
            $0.key.localizedCaseInsensitiveContains(searchText)
            || $0.value.displayString.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func togglePreset(_ preset: MGPreset) {
        if selectedPresets.contains(preset.id) {
            selectedPresets.remove(preset.id)
        } else {
            // 互斥组：同组内只能选一个
            if let group = preset.conflictGroup {
                for other in MGPresets.all where other.conflictGroup == group {
                    selectedPresets.remove(other.id)
                }
            }
            selectedPresets.insert(preset.id)
        }
    }
}
