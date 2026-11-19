import SwiftUI
import SwiftData

struct UsageView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Provider.createdAt) private var providers: [Provider]

    private struct Stat {
        var requests = 0
        var promptTokens = 0
        var completionTokens = 0
        var retried = 0
        var totalLatency = 0
        var total: Int { promptTokens + completionTokens }
        var avgLatency: Int { requests == 0 ? 0 : totalLatency / requests }
    }

    private var allMessages: [ChatMessage] { conversations.flatMap(\.messages) }

    private var overall: Stat {
        var s = Stat()
        for m in allMessages where m.role == .assistant {
            s.requests += 1
            s.promptTokens += m.promptTokens
            s.completionTokens += m.completionTokens
            if m.retried { s.retried += 1 }
            s.totalLatency += m.latencyMs
        }
        return s
    }

    private var perProvider: [(Provider, Stat)] {
        providers.compactMap { p in
            let ids = Set(conversations.filter { $0.providerUID == p.uid }.map(\.uid))
            var s = Stat()
            for m in allMessages where m.role == .assistant {
                guard let c = m.conversation, ids.contains(c.uid) else { continue }
                s.requests += 1
                s.promptTokens += m.promptTokens
                s.completionTokens += m.completionTokens
                if m.retried { s.retried += 1 }
                s.totalLatency += m.latencyMs
            }
            return s.requests > 0 ? (p, s) : nil
        }
        .sorted { $0.1.total > $1.1.total }
    }

    private var retryRate: Double {
        overall.requests == 0 ? 0 : Double(overall.retried) / Double(overall.requests) * 100
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    Section("总览") {
                        LabeledContent("请求数", value: "\(overall.requests)")
                        LabeledContent("总 tokens", value: formatNumber(overall.total))
                        LabeledContent("输入", value: formatNumber(overall.promptTokens))
                        LabeledContent("输出", value: formatNumber(overall.completionTokens))
                        LabeledContent("破甲重试率", value: String(format: "%.1f%%", retryRate))
                        LabeledContent("平均延迟", value: "\(overall.avgLatency) ms")
                    }

                    if !perProvider.isEmpty {
                        Section("按供应商") {
                            ForEach(perProvider, id: \.0.uid) { p, s in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(p.name).font(.body)
                                        Spacer()
                                        Text(formatNumber(s.total))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(
                                        value: Double(s.total),
                                        total: Double(max(overall.total, 1))
                                    )
                                    .tint(.accentColor)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Section {
                        Text("token 数来自接口返回的 usage 字段。中转站不透传 usage 时显示 0，不代表没消耗。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
