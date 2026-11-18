import SwiftUI
import SwiftData
import UIKit

struct ChatView: View {
    let conversation: Conversation

    @Environment(\.modelContext) private var ctx
    @Query(sort: \Provider.createdAt) private var providers: [Provider]

    @AppStorage(Theme.bubbleKey) private var bubbleRaw = BubbleStyle.filled.rawValue
    @AppStorage(Theme.cornerKey) private var corner = 18.0

    @State private var draft = ""
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var retryNotice: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var editingMessage: ChatMessage?
    @State private var showDiagnostics = false
    @State private var lastResult: StreamResult?
    @FocusState private var inputFocused: Bool

    private var bubbleStyle: BubbleStyle { BubbleStyle(rawValue: bubbleRaw) ?? .filled }

    private var provider: Provider? {
        if let pid = conversation.providerUID,
           let p = providers.first(where: { $0.uid == pid }) {
            return p
        }
        return providers.first
    }

    private var messages: [ChatMessage] { conversation.orderedMessages }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty && streamingText.isEmpty {
                                header
                            }
                            ForEach(messages) { message in
                                MessageRow(
                                    role: message.role,
                                    text: message.text,
                                    streaming: false,
                                    retried: message.retried,
                                    corner: corner,
                                    style: bubbleStyle,
                                    onCopy: { UIPasteboard.general.string = message.text },
                                    onRegenerate: message.role == .assistant && !isStreaming
                                        ? { regenerate(from: message) } : nil,
                                    onEdit: message.role == .user && !isStreaming
                                        ? { editingMessage = message } : nil
                                )
                                .id(message.uid)
                            }
                            if isStreaming {
                                MessageRow(
                                    role: .assistant,
                                    text: streamingText,
                                    streaming: true,
                                    retried: false,
                                    corner: corner,
                                    style: bubbleStyle,
                                    onCopy: {},
                                    onRegenerate: nil,
                                    onEdit: nil
                                )
                                .id("streaming")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: streamingText) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                if let retryNotice {
                    banner(retryNotice, icon: "arrow.clockwise", tint: .green) { self.retryNotice = nil }
                }
                if let errorText {
                    banner(errorText, icon: "exclamationmark.triangle", tint: .orange) { self.errorText = nil }
                }

                inputBar
            }
        }
        .navigationTitle(provider?.name ?? conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("切换模型") {
                        ForEach(providers) { p in
                            Button {
                                conversation.providerUID = p.uid
                                try? ctx.save()
                            } label: {
                                if p.uid == provider?.uid {
                                    Label("\(p.name) · \(p.model)", systemImage: "checkmark")
                                } else {
                                    Text("\(p.name) · \(p.model)")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("破甲诊断", systemImage: "waveform.path.ecg")
                    }
                    Button(role: .destructive) {
                        clearMessages()
                    } label: {
                        Label("清空对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(
                result: lastResult,
                provider: provider,
                systemPromptLength: provider?.systemPrompt.count ?? 0,
                boostEnabled: provider?.boostEnabled ?? false
            )
        }
        .sheet(item: $editingMessage) { message in
            EditMessageSheet(message: message) { newText in
                resend(message: message, newText: newText)
            }
        }
        .onDisappear { streamTask?.cancel() }
    }

    // MARK: 头部信息

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: provider?.kind.symbol ?? "bolt.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(provider?.kind.title ?? "API")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if provider?.boostEnabled == true {
                    Text("破甲")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
            }

            Text(provider?.model ?? "—")
                .font(.headline)

            Text(provider?.baseURL ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            if let p = provider, !p.systemPrompt.isEmpty {
                Divider()
                Text(p.systemPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func banner(_ text: String, icon: String, tint: Color, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
    }

    // MARK: 输入

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("发消息", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)

                if !draft.isEmpty {
                    Button {
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                if isStreaming {
                    streamTask?.cancel()
                } else {
                    send()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.glassProminent)
            .tint(isStreaming ? .red : .accentColor)
            .disabled(!isStreaming && !canSend)
            .opacity(isStreaming || canSend ? 1 : 0.4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider != nil && !isStreaming
    }

    // MARK: 发送

    @MainActor
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorText = nil
        retryNotice = nil

        let userMessage = ChatMessage(role: .user, text: text)
        ctx.insert(userMessage)
        conversation.messages.append(userMessage)
        if conversation.title == "新对话" {
            conversation.title = String(text.prefix(24))
        }
        conversation.updatedAt = .now
        try? ctx.save()
        fire()
    }

    @MainActor
    private func regenerate(from message: ChatMessage) {
        let ordered = messages
        guard let idx = ordered.firstIndex(where: { $0.uid == message.uid }) else { return }
        let tail = ordered[idx...]
        for m in tail { ctx.delete(m) }
        conversation.messages.removeAll { m in tail.contains { $0.uid == m.uid } }
        try? ctx.save()

        if messages.last?.role != .user {
            let nudge = ChatMessage(role: .user, text: "重新回答")
            ctx.insert(nudge)
            conversation.messages.append(nudge)
            try? ctx.save()
        }
        fire()
    }

    @MainActor
    private func resend(message: ChatMessage, newText: String) {
        message.text = newText
        let ordered = messages
        if let idx = ordered.firstIndex(where: { $0.uid == message.uid }) {
            let tail = ordered[(idx + 1)...]
            for m in tail { ctx.delete(m) }
            conversation.messages.removeAll { m in tail.contains { $0.uid == m.uid } }
        }
        conversation.updatedAt = .now
        try? ctx.save()
        fire()
    }

    @MainActor
    private func fire() {
        guard let provider else { return }
        let apiKey = provider.kind.isOnDevice ? "" : KeychainStore.read(provider.keychainAccount)
        if provider.kind == .localGGUF {
            guard !provider.localModelFile.isEmpty else {
                errorText = "还没选本地模型文件，去编辑供应商里选一个"
                return
            }
        }
        let config = EndpointConfig(provider: provider)
        let history = conversation.orderedMessages
            .filter { $0.role != .system }
            .map { ChatTurn(role: $0.role.rawValue, content: $0.text) }

        streamingText = ""
        isStreaming = true

        if provider.kind == .localGGUF {
            streamingText = ""
            retryNotice = "本地推理中，首次加载模型可能等几秒"
        }

        LiveActivityController.shared.start(
            conversationTitle: conversation.title,
            providerName: provider.name,
            model: provider.model
        )

        streamTask = Task { @MainActor in
            do {
                let result = try await LLMClient.stream(
                    config: config, apiKey: apiKey, turns: history
                ) { piece in
                    streamingText += piece
                    LiveActivityController.shared.updateProgress(chars: streamingText.count)
                }
                lastResult = result
                if result.retried {
                    LiveActivityController.shared.markRetrying()
                    retryNotice = "命中第 \(result.matchedRule + 1) 条规则，已重试"
                } else if provider.kind == .localGGUF {
                    retryNotice = nil
                }

                let reply = ChatMessage(role: .assistant, text: result.text)
                reply.retried = result.retried
                reply.matchedRule = result.matchedRule
                reply.promptTokens = result.promptTokens
                reply.completionTokens = result.completionTokens
                reply.latencyMs = result.latencyMs
                ctx.insert(reply)
                conversation.messages.append(reply)
                conversation.updatedAt = .now
                try? ctx.save()
                streamingText = ""
                isStreaming = false
                LiveActivityController.shared.finish()

                if result.truncated {
                    errorText = "回答被 max tokens 截断了"
                }
            } catch {
                if !streamingText.isEmpty {
                    let partial = ChatMessage(role: .assistant, text: streamingText + "\n\n[中断]")
                    ctx.insert(partial)
                    conversation.messages.append(partial)
                    try? ctx.save()
                }
                streamingText = ""
                isStreaming = false
                LiveActivityController.shared.fail(note: (error as? LocalizedError)?.errorDescription ?? "失败")
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func clearMessages() {
        streamTask?.cancel()
        for m in conversation.messages { ctx.delete(m) }
        conversation.messages.removeAll()
        conversation.title = "新对话"
        try? ctx.save()
        streamingText = ""
        isStreaming = false
        lastResult = nil
    }
}

// MARK: - 消息行

struct MessageRow: View {
    let role: MessageRole
    let text: String
    let streaming: Bool
    let retried: Bool
    let corner: CGFloat
    let style: BubbleStyle
    let onCopy: () -> Void
    let onRegenerate: (() -> Void)?
    let onEdit: (() -> Void)?

    private var isUser: Bool { role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 4) {
                if !isUser {
                    Text("AI")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("我")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if retried {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
                if isUser { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 4)

            bubble
                .frame(maxWidth: isUser ? 300 : .infinity, alignment: isUser ? .trailing : .leading)
                .contextMenu {
                    Button(action: onCopy) {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    if let onRegenerate {
                        Button(action: onRegenerate) {
                            Label("重新生成", systemImage: "arrow.clockwise")
                        }
                    }
                    if let onEdit {
                        Button(action: onEdit) {
                            Label("编辑重发", systemImage: "pencil")
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        if text.isEmpty && streaming {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .phaseAnimator([0, 1, 2]) { v, phase in
                            v.opacity(phase == i ? 1 : 0.3)
                        } animation: { _ in .easeInOut(duration: 0.5) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(bubbleBackground)
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(bubbleBackground)
        }
    }

    private var bubbleBackground: some View {
        Group {
            if style == .filled {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(isUser
                          ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                          : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isUser ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3), lineWidth: 1)
            }
        }
    }
}
