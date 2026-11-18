import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Provider.createdAt) private var providers: [Provider]

    @State private var selected: Conversation?
    @State private var showSettings = false
    @State private var showUsage = false
    @State private var searchText = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let live = conversations.filter { !$0.archived }
        let pinned = live.filter { $0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        let rest = live.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        guard !searchText.isEmpty else { return pinned + rest }
        let q = searchText.lowercased()
        return (pinned + rest).filter { c in
            c.title.lowercased().contains(q) ||
            c.messages.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var pinnedList: [Conversation] { filtered.filter { $0.pinned } }
    private var normalList: [Conversation] { filtered.filter { !$0.pinned } }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                Group {
                    if providers.isEmpty {
                        onboarding
                    } else if filtered.isEmpty && searchText.isEmpty {
                        ContentUnavailableView {
                            Label("还没有对话", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("点右上角新建一个")
                        } actions: {
                            Button("新建对话") { newConversation() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("对话")
            .searchable(text: $searchText, prompt: "搜索标题与内容")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showUsage = true
                        } label: {
                            Label("用量统计", systemImage: "chart.bar")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("供应商与设置", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(providers.isEmpty)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            )) {
                if let conversation = selected {
                    ChatView(conversation: conversation)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showUsage) { UsageView() }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("保存") {
                    renameTarget?.title = renameText.isEmpty ? "未命名" : renameText
                    try? ctx.save()
                    renameTarget = nil
                }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
        }
    }

    // MARK: 列表

    private var list: some View {
        List {
            if !pinnedList.isEmpty {
                Section {
                    ForEach(pinnedList) { row(for: $0) }
                } header: {
                    Label("置顶", systemImage: "pin.fill")
                        .font(.caption2)
                }
            }

            Section {
                ForEach(normalList) { row(for: $0) }
            } header: {
                if !pinnedList.isEmpty { Text("全部对话") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(for conversation: Conversation) -> some View {
        Button {
            selected = conversation
        } label: {
            ConversationCell(
                conversation: conversation,
                provider: providers.first { $0.uid == conversation.providerUID }
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                ctx.delete(conversation)
                try? ctx.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                conversation.pinned.toggle()
                try? ctx.save()
            } label: {
                Label(conversation.pinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                renameText = conversation.title
                renameTarget = conversation
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                conversation.pinned.toggle()
                try? ctx.save()
            } label: {
                Label(conversation.pinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            Button {
                conversation.archived = true
                try? ctx.save()
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            Divider()
            Button(role: .destructive) {
                ctx.delete(conversation)
                try? ctx.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: 首启

    private var onboarding: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 60)

                VStack(spacing: 8) {
                    Text("直连你的模型")
                        .font(.title2.weight(.semibold))
                    Text("填地址和 key，请求从这台手机直接发到模型。\n没有中间服务器，没有账号。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    featureRow("bolt.fill", "三种协议", "OpenAI 兼容 / Anthropic / Gemini")
                    Divider().padding(.leading, 46)
                    featureRow("lock.fill", "Key 在 Keychain", "不写数据库，不进备份")
                    Divider().padding(.leading, 46)
                    featureRow("shield.lefthalf.filled", "破甲三层", "强化尾段 + 拒绝正则 + 单次重试")
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20)

                Button {
                    showSettings = true
                } label: {
                    Text("添加第一个 API")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func newConversation() {
        let conversation = Conversation(providerUID: providers.first?.uid)
        ctx.insert(conversation)
        try? ctx.save()
        selected = conversation
    }
}

// MARK: - 单元格

struct ConversationCell: View {
    let conversation: Conversation
    let provider: Provider?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider?.kind.symbol ?? "bubble.left")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let model = provider?.model {
                        Text(model).lineLimit(1)
                    } else {
                        Text("默认")
                    }
                    Text("·")
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
