import SwiftUI

/// Plist 编辑器：打开可访问的 Plist → 搜索 / 编辑全部类型 / 新增 / 删除 / 保存（重读验证）/ 修改前自动备份。

struct PlistEditorView: View {
    @StateObject private var editor = PlistEditorService()
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var editingKey: (key: String, value: PlistValue)?
    @State private var showAddKey = false
    @State private var newKeyName = ""
    @State private var newKeyKind: PlistValueKind = .string
    @State private var showSaved = false
    @State private var saveFailed = false

    var body: some View {
        VStack {
            if !editor.isLoaded {
                VStack(spacing: 16) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("选择一个 Plist 文件开始编辑")
                        .font(.headline)
                    Text("支持本 App 容器、导入的文件；跨 App 的 Plist 请先用文件管理器（逃逸）查看。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("选择 Plist 文件") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section(header: Text(editor.sourceName)) {
                        ForEach(editor.search(searchText), id: \.key) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.key).font(.subheadline).fontWeight(.medium)
                                    Text(item.value.displayString)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(item.value.kind.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingKey = item }
                            .swipeActions {
                                Button(role: .destructive) {
                                    editor.deleteKey(item.key)
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "搜索 Key 或 Value")
            }
        }
        .navigationTitle(L10n.plistEditor)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editor.isLoaded {
                    Button { showAddKey = true } label: { Image(systemName: "plus") }
                    Button("保存") {
                        if editor.save() { showSaved = true } else { saveFailed = true }
                    }
                    .fontWeight(.semibold)
                }
                Button { showImporter = true } label: { Image(systemName: "folder") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.propertyList], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                _ = editor.load(url: url)
            }
        }
        .sheet(item: Binding(
            get: { editingKey.map { EditableKey(key: $0.key, value: $0.value) } },
            set: { _ in editingKey = nil }
        )) { editable in
            PlistValueEditorSheet(key: editable.key, value: editable.value) { newValue in
                editor.setValue(key: editable.key, value: newValue)
            }
        }
        .alert("新增字段", isPresented: $showAddKey) {
            TextField("字段名", text: $newKeyName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                guard !newKeyName.isEmpty else { return }
                editor.setValue(key: newKeyName, value: PlistValue.empty(kind: newKeyKind))
                newKeyName = ""
            }
        } message: {
            Text("新字段默认值为所选类型的空值，添加后点字段可编辑。")
        }
        .alert("已保存并验证", isPresented: $showSaved) {
            Button("好", role: .cancel) {}
        } message: {
            Text("Plist 已写入磁盘并重读验证通过。修改前原文件已自动备份到 Documents/Backups/Plist。")
        }
        .alert("保存失败", isPresented: $saveFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text(editor.errorMessage ?? "未知错误")
        }
        .alert("提示", isPresented: Binding(
            get: { editor.errorMessage != nil && !editor.isLoaded },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }
}

struct EditableKey: Identifiable {
    let id = UUID()
    let key: String
    let value: PlistValue
}

/// 从文件管理器打开 Plist 的宿主（复用同一编辑器）。
struct PlistEditorHostView: View {
    let url: URL
    @StateObject private var editor = PlistEditorService()
    @State private var searchText = ""
    @State private var editingKey: (key: String, value: PlistValue)?
    @State private var showSaved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if editor.isLoaded {
                    List {
                        ForEach(editor.search(searchText), id: \.key) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.key).font(.subheadline).fontWeight(.medium)
                                    Text(item.value.displayString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Text(item.value.kind.rawValue).font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingKey = item }
                            .swipeActions {
                                Button(role: .destructive) {
                                    editor.deleteKey(item.key)
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "搜索 Key 或 Value")
                } else {
                    Text(editor.errorMessage ?? "载入中…")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if editor.save() { showSaved = true }
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("已保存并验证", isPresented: $showSaved) {
                Button("好", role: .cancel) {}
            }
            .sheet(item: Binding(
                get: { editingKey.map { EditableKey(key: $0.key, value: $0.value) } },
                set: { _ in editingKey = nil }
            )) { editable in
                PlistValueEditorSheet(key: editable.key, value: editable.value) { newValue in
                    editor.setValue(key: editable.key, value: newValue)
                }
            }
            .onAppear { _ = editor.load(url: url) }
        }
    }
}
