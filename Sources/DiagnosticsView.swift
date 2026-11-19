import SwiftUI

// MARK: - 破甲诊断

struct DiagnosticsSheet: View {
    let result: StreamResult?
    let provider: Provider?
    let systemPromptLength: Int
    let boostEnabled: Bool

    @Environment(\.dismiss) private var dismiss

    private var totalPrompt: Int {
        systemPromptLength + (boostEnabled ? PromptBoost.tail.count : 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("上一次请求") {
                    if let r = result {
                        LabeledContent("延迟", value: "\(r.latencyMs) ms")
                        LabeledContent("输入 token", value: "\(r.promptTokens)")
                        LabeledContent("输出 token", value: "\(r.completionTokens)")
                        LabeledContent("命中规则", value: r.retried ? "第 \(r.matchedRule + 1) 条" : "无")
                        LabeledContent("被截断", value: r.truncated ? "是" : "否")
                    } else {
                        Text("还没有发过请求")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("实际发出的系统提示") {
                    LabeledContent("你的提示词", value: "\(systemPromptLength) 字符")
                    LabeledContent("破甲尾段", value: boostEnabled ? "\(PromptBoost.tail.count) 字符" : "关")
                    LabeledContent("合计", value: "\(totalPrompt) 字符")
                }

                Section {
                    Text(PromptBoost.tail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("破甲尾段全文")
                }

                Section {
                    Text("共 \(PromptBoost.ruleCount) 条，判定窗口 400 字符。命中即丢弃本次输出、加加固语重跑一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("拒绝识别")
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 编辑重发

struct EditMessageSheet: View {
    let message: ChatMessage
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("消息", text: $text, axis: .vertical)
                        .lineLimit(6...20)
                }
            }
            .navigationTitle("编辑并重发")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重发") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = message.text }
        }
    }
}
