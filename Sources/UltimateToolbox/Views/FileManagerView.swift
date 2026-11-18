import SwiftUI
import UniformTypeIdentifiers

/// 文件管理器：本 App / App Group / 导入的文件 +（逃逸可用时）其他 App 容器。
/// 浏览、搜索、预览、文本编辑、Plist 编辑、Hex 查看、导入导出、重命名、删除、分享。

struct FileManagerView: View {
    @StateObject private var service = FileService.shared
    @EnvironmentObject var compat: CompatibilityService
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var selectedFile: FileItem?
    @State private var showTextEditor = false
    @State private var showHex = false
    @State private var showPlist = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var shareURL: URL?
    @State private var showShare = false

    var filtered: [FileItem] {
        guard !searchText.isEmpty else { return service.items }
        return service.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("根目录", selection: Binding(
                get: { service.currentRoot },
                set: { service.navigate(to: $0) }
            )) {
                ForEach(FileRoot.allCases) { root in
                    Text(root.rawValue).tag(root)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Button(action: { service.navigateUp() }) {
                    Label("上级", systemImage: "arrow.up")
                }
                .disabled(service.currentPath == service.rootPath(for: service.currentRoot))
                Text(service.currentPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            if let report = compat.report, report.crossAppFiles == .available {
                NavigationLink(destination: EscapeBrowserView()) {
                    Label("浏览其他 App 容器（逃逸）", systemImage: "app.badge")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            } else if let report = compat.report {
                UnavailableCard(title: "其他 App 容器不可访问", reason: {
                    switch report.crossAppFiles {
                    case .unavailable(let r): return r
                    case .limited(let n): return n
                    case .available: return ""
                    }
                }())
                .padding(.horizontal)
            }

            List(filtered) { item in
                HStack {
                    Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                        .foregroundStyle(item.isDir ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline)
                        Text(SystemInfoService.formatBytes(item.size))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.isDir {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if item.isDir {
                        service.navigateInto(item.name)
                    } else {
                        selectedFile = item
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "搜索文件")
        }
        .navigationTitle(L10n.fileManager)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = service.importFile(from: url)
            }
        }
        .actionSheet(item: $selectedFile) { file in
            ActionSheet(title: Text(file.name), buttons: [
                .default(Text("预览")) { openPreview(file) },
                .default(Text("文本编辑")) { showTextEditor = true },
                .default(Text("Plist 编辑")) { showPlist = true },
                .default(Text("Hex 查看")) { showHex = true },
                .default(Text("分享")) { shareURL = service.url(for: file.name); showShare = true },
                .default(Text("重命名")) { renameText = file.name; showRename = true },
                .destructive(Text("删除")) { showDeleteConfirm = true },
                .cancel(),
            ])
        }
        .sheet(isPresented: $showTextEditor) {
            if let file = selectedFile {
                TextEditorView(fileName: file.name)
            }
        }
        .sheet(isPresented: $showHex) {
            if let file = selectedFile {
                HexViewerView(fileName: file.name)
            }
        }
        .sheet(isPresented: $showPlist) {
            if let file = selectedFile {
                PlistEditorHostView(url: service.url(for: file.name))
            }
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("新名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let file = selectedFile { _ = service.rename(file.name, to: renameText) }
            }
        }
        .alert("删除文件？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let file = selectedFile { _ = service.delete(file.name) }
            }
        } message: {
            Text("将永久删除 \(selectedFile?.name ?? "")，此操作不可恢复。")
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareLink(item: shareURL) { Text("分享文件") }
                    .presentationDetents([.medium])
            }
        }
        .onAppear { service.refresh() }
    }

    private func openPreview(_ file: FileItem) {
        if file.name.hasSuffix(".plist") { showPlist = true }
        else if file.name.hasSuffix(".txt") || file.name.hasSuffix(".log") || file.name.hasSuffix(".json") || file.name.hasSuffix(".md") { showTextEditor = true }
        else { showHex = true }
    }
}

/// 文本编辑器（真实读写文件）。
struct TextEditorView: View {
    let fileName: String
    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding()
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if FileService.shared.writeText(text, to: fileName) { saved = true; dismiss() }
                        }
                    }
                }
                .onAppear { text = FileService.shared.readText(at: fileName) ?? "" }
        }
    }
}

/// Hex 查看器（真实读取文件字节）。
struct HexViewerView: View {
    let fileName: String
    @State private var dump: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(dump)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("\(fileName) · Hex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if let data = FileService.shared.readData(at: fileName) {
                    dump = FileService.hexDump(data)
                } else {
                    dump = "无法读取文件"
                }
            }
        }
    }
}

/// 逃逸容器浏览器：枚举全部 MCM 容器并浏览（需要逃逸可用）。
struct EscapeBrowserView: View {
    @State private var roots: [String] = []
    @State private var containers: [String] = []
    @State private var selectedRoot: String = ""
    @State private var currentContainer: String?
    @State private var currentRel: String = ""
    @State private var entries: [PathEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEntry: PathEntry?
    @State private var showHex = false
    @State private var hexDump = ""

    var body: some View {
        VStack {
            if currentContainer == nil {
                List {
                    Section("容器根目录") {
                        ForEach(roots, id: \.self) { root in
                            Button(root) {
                                selectedRoot = root
                                Task { await loadContainers(root) }
                            }
                        }
                    }
                    if !containers.isEmpty {
                        Section("容器（\(containers.count) 个）") {
                            ForEach(containers, id: \.self) { container in
                                Button {
                                    currentContainer = container
                                    currentRel = ""
                                    Task { await loadEntries() }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text((container as NSString).lastPathComponent)
                                            .font(.subheadline)
                                        Text(container).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                            .foregroundStyle(entry.isDir ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(entry.name).font(.subheadline)
                            Text(SystemInfoService.formatBytes(entry.size))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.isDir { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if entry.isDir {
                            currentRel = (currentRel as NSString).appendingPathComponent(entry.name)
                            Task { await loadEntries() }
                        } else {
                            selectedEntry = entry
                            Task { await loadHex(entry) }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回容器列表") { currentContainer = nil; entries = [] }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("上级") {
                            currentRel = (currentRel as NSString).deletingLastPathComponent
                            Task { await loadEntries() }
                        }
                        .disabled(currentRel.isEmpty)
                    }
                }
            }
            if isLoading { ProgressView() }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.subheadline).padding()
            }
        }
        .navigationTitle("其他 App 容器")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showHex) {
            NavigationStack {
                ScrollView {
                    Text(hexDump)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(selectedEntry?.name ?? "Hex")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showHex = false }
                    }
                }
            }
        }
        .task { await loadRoots() }
    }

    private func loadRoots() async {
        roots = await EscapeService.shared.containerRoots()
        UTLog.info("容器根目录已枚举：\(roots.count) 个", category: "文件管理")
    }

    private func loadContainers(_ root: String) async {
        isLoading = true
        defer { isLoading = false }
        containers = await EscapeService.shared.listContainers(root: root)
        UTLog.info("容器已枚举：\(containers.count) 个（\(root)）", category: "文件管理")
    }

    private func loadEntries() async {
        guard let container = currentContainer else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await EscapeService.shared.listPath(container: container, rel: currentRel)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
    }

    private func loadHex(_ entry: PathEntry) async {
        guard let container = currentContainer else { return }
        do {
            let data = try await EscapeService.shared.readPath(container: container, rel: (currentRel as NSString).appendingPathComponent(entry.name))
            hexDump = FileService.hexDump(data)
            showHex = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
