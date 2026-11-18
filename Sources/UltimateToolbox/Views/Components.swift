import SwiftUI

/// 共享 UI 组件：原生 Liquid Glass 卡片、不可用提示、日志颜色等。

/// 玻璃卡片（iOS 26 原生 Liquid Glass，克制使用）。
struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

func logColor(_ level: LogLevel) -> Color {
    switch level {
    case .info: return .secondary
    case .success: return .green
    case .warning: return .orange
    case .error: return .red
    case .debug: return .purple
    }
}

func statusColor(_ status: ModuleStatus) -> Color {
    switch status {
    case .available: return .green
    case .unavailable: return .red
    case .limited: return .orange
    }
}

func statusLabel(_ status: ModuleStatus) -> String {
    switch status {
    case .available: return "可用"
    case .unavailable: return "不可用"
    case .limited: return "受限"
    }
}

/// 模块不可用时的诚实说明卡片（不留假开关）。
struct UnavailableCard: View {
    let title: String
    let reason: String
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InfoRowView: View {
    let row: InfoRow
    var body: some View {
        HStack {
            Text(row.title)
            Spacer()
            Text(row.value)
                .foregroundStyle(row.available ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
            if !row.available {
                Text("不可读取")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }
}

/// Plist 值编辑器（String / Integer / Float / Boolean / Data / Array / Dictionary）。
/// Array / Dictionary 用 JSON 文本编辑，保存时解析回 PlistValue。
struct PlistValueEditorSheet: View {
    let key: String
    @State var value: PlistValue
    var onSave: (PlistValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var boolValue: Bool = false
    @State private var jsonText: String = ""
    @State private var errorMessage: String?

    init(key: String, value: PlistValue, onSave: @escaping (PlistValue) -> Void) {
        self.key = key
        self._value = State(initialValue: value)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("字段") {
                    Text(key).font(.headline)
                    Text("类型：\(value.kind.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                }
                Section("值") {
                    switch value.kind {
                    case .string:
                        TextField("字符串", text: Binding(
                            get: { if case .string(let s) = value { return s } else { return "" } },
                            set: { value = .string($0) }
                        ))
                    case .integer:
                        TextField("整数", text: Binding(
                            get: { if case .integer(let i) = value { return "\(i)" } else { return "" } },
                            set: { value = .integer(Int($0) ?? 0) }
                        ))
                        .keyboardType(.numberPad)
                    case .float:
                        TextField("浮点数", text: Binding(
                            get: { if case .float(let f) = value { return "\(f)" } else { return "" } },
                            set: { value = .float(Double($0) ?? 0) }
                        ))
                        .keyboardType(.decimalPad)
                    case .boolean:
                        Toggle("布尔值", isOn: Binding(
                            get: { if case .boolean(let b) = value { return b } else { return false } },
                            set: { value = .boolean($0) }
                        ))
                    case .data:
                        TextField("Base64", text: Binding(
                            get: { if case .data(let d) = value { return d.base64EncodedString() } else { return "" } },
                            set: { value = .data(Data(base64Encoded: $0) ?? Data()) }
                        ))
                        .autocapitalization(.none)
                    case .array, .dictionary:
                        Text("以 JSON 编辑（保存时解析）")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $jsonText)
                            .frame(minHeight: 200)
                            .font(.system(.body, design: .monospaced))
                            .onAppear {
                                if let data = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys]),
                                   let s = String(data: data, encoding: .utf8) {
                                    jsonText = s
                                }
                            }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.subheadline) }
                }
            }
            .navigationTitle("编辑字段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        switch value.kind {
        case .array, .dictionary:
            guard let data = jsonText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let parsed = try? parseJSONValue(obj, expected: value.kind) else {
                errorMessage = "JSON 解析失败，请检查格式"
                return
            }
            onSave(parsed)
        default:
            onSave(value)
        }
        dismiss()
    }

    private func parseJSONValue(_ obj: Any, expected: PlistValueKind) throws -> PlistValue {
        if expected == .array, let arr = obj as? [Any] {
            return .array(arr.map { PlistValue.from($0) })
        }
        if expected == .dictionary, let dict = obj as? [String: Any] {
            return .dictionary(dict.keys.sorted().map { ($0, PlistValue.from(dict[$0]!)) })
        }
        throw NSError(domain: "Plist", code: 0, userInfo: [NSLocalizedDescriptionKey: "类型不匹配"])
    }
}
