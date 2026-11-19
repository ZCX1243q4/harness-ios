import SwiftUI
import SwiftData

/// 本地模型的诊断信息。回答"为什么输出奇怪"必须看这里。
struct ModelDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var models: [LocalModel]

    @State private var promptText = ""
    @State private var refreshCount = 0

    private var engineInfo: (loaded: Bool, file: String, params: UInt64, ctx: Int, trained: Int, template: String) {
        // 触发刷新
        _ = refreshCount
        return LocalLLMRunner.shared.debugInfo
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    Section {
                        LabeledContent("引擎状态", value: LocalLLMRunner.engineAvailable ? "已编入" : "未编入")
                        LabeledContent("已加载模型", value: engineInfo.loaded ? engineInfo.file : "没有")
                        if engineInfo.loaded {
                            LabeledContent("模型名", value: LocalLLMRunner.shared.modelNameDebug)
                            LabeledContent("架构", value: LocalLLMRunner.shared.architectureDebug)
                            LabeledContent("参数量", value: formatParams(engineInfo.params))
                            LabeledContent("上下文", value: "\(engineInfo.ctx)")
                            LabeledContent("训练上下文", value: "\(engineInfo.trained)")
                        }
                    } header: {
                        Text("模型")
                    }

                    Section {
                        Text(engineInfo.template)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("对话模板")
                    } footer: {
                        Text(engineInfo.template.contains("没带")
                             ? "⚠️ 模型没有内置对话模板，这通常意味着它是 base 模型——base 模型不会对话，只会续写文本。这就是输出代码片段或复读提示词的原因。请换 instruct / chat 版本的模型。"
                             : "模板来自模型文件本身，正常。")
                    }

                    Section {
                        Button("刷新") { refreshCount += 1 }
                        Button("重新加载模型") {
                            LocalLLMRunner.shared.unload()
                            refreshCount += 1
                        }
                    } header: {
                        Text("操作")
                    }

                    Section {
                        let p = LocalLLMRunner.shared.lastPromptDebug
                        if p.isEmpty {
                            Text("还没发过消息").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("长度：\(p.count) 字符")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(p)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    } header: {
                        Text("上次实际发送的 prompt")
                    } footer: {
                        Text("必须能在开头看到 <|im_start|>system 和你的提示词。看不到说明系统提示词没传进去。")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("模型诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func formatParams(_ n: UInt64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return "\(n)"
    }
}
