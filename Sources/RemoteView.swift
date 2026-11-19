import SwiftUI
import AVFoundation

// MARK: - 电脑模式（对话互通，可自由选会话）

struct RemoteView: View {
    @EnvironmentObject private var remote: RemoteControl
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var messages: [(role: String, text: String)] = []
    @State private var showScanner = false
    @State private var showSessions = false
    @State private var streaming = ""
    @State private var loadingHistory = false
    @State private var loadingMore = false
    @State private var historyHasMore = false
    @State private var historyNextBefore: Int? = nil
    @State private var currentSessionForHistory = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    statusBar
                    if remote.status == .connected {
                        sessionBar
                        conversation
                        inputBar
                    } else {
                        pairingGuide
                    }
                }
            }
            .navigationTitle("电脑模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showScanner = true } label: {
                            Label("重新配对", systemImage: "qrcode.viewfinder")
                        }
                        if remote.status == .connected {
                            Button {
                                Task {
                                    await remote.refreshSessions()
                                    showSessions = true
                                }
                            } label: {
                                Label("切换会话", systemImage: "list.bullet")
                            }
                            Button {
                                remote.select(sessionId: nil)
                                messages.removeAll()
                            } label: {
                                Label("开新对话", systemImage: "plus.bubble")
                            }
                        }
                        Button(role: .destructive) {
                            remote.disconnect()
                        } label: {
                            Label("断开", systemImage: "wifi.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                PairScannerSheet { payload in
                    remote.connect(pair: payload)
                    showScanner = false
                }
            }
            .sheet(isPresented: $showSessions) {
                SessionPickerSheet(
                    sessions: remote.sessions,
                    activeId: remote.activeSessionId
                ) { session in
                    remote.select(sessionId: session?.id)
                    messages.removeAll()
                    loadingHistory = false
                    if let s = session {
                        messages.append(("system", "已切到电脑会话：\(s.title)"))
                        currentSessionForHistory = s.id
                        loadingHistory = true
                        historyHasMore = false
                        historyNextBefore = nil
                        Task {
                            let page = await remote.fetchHistory(sessionId: s.id, before: nil, rounds: 5)
                            loadingHistory = false
                            historyHasMore = page.hasMore
                            historyNextBefore = page.nextBefore
                            if page.messages.isEmpty {
                                messages.append(("system", "（这段对话在电脑上没有历史记录）"))
                            } else {
                                messages.append(("system", "电脑上最近 \(page.messages.count) 条消息"))
                                for h in page.messages {
                                    messages.append((h.role, h.text))
                                }
                                messages.append(("system", page.hasMore ? "— 上滑加载更早 —" : "—— 历史结束 ——"))
                            }
                        }
                    } else {
                        messages.append(("system", "下一条消息会在电脑上新开一个对话"))
                    }
                    showSessions = false
                }
            }
        }
        .onAppear {
            // 有保存过的连接就直接自动重连，不用再扫码
            if !remote.isPaired {
                if !remote.autoReconnect() {
                    showScanner = true
                }
            } else if remote.status == .connected {
                Task { await remote.refreshSessions() }
            }
        }
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.subheadline)
            Spacer()
            if remote.isPaired, !remote.hostName.isEmpty {
                Text(remote.hostName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var statusColor: Color {
        switch remote.status {
        case .connected: return .green
        case .connecting, .hostOffline: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch remote.status {
        case .idle: return "未配对"
        case .connecting: return "连接中…"
        case .connected: return "已连接电脑"
        case .hostOffline: return "电脑离线"
        case .failed(let m): return m
        }
    }

    // MARK: 会话条

    private var sessionBar: some View {
        Button {
            Task {
                await remote.refreshSessions()
                showSessions = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: remote.activeSessionId == nil ? "plus.bubble" : "bubble.left.and.text.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(remote.activeSessionTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(remote.sessions.count) 个会话")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
    }

    // MARK: 对话

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if loadingHistory {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在拉电脑上的历史…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    if historyHasMore && !loadingMore {
                        Button {
                            loadMoreHistory()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.circle")
                                Text("加载更早的消息")
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }

                    if loadingMore {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("加载中…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }

                    if messages.isEmpty && streaming.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.tint)
                            Text(remote.activeSessionId == nil ? "和电脑开新对话" : "接着电脑上的对话")
                                .font(.subheadline)
                            Text("这里的每句话都会发给电脑，\n由电脑上的 DSH 处理。")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 50)
                    }

                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        bubble(role: m.role, text: m.text)
                    }

                    if !streaming.isEmpty {
                        bubble(role: "assistant", text: streaming)
                    } else if remote.running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("电脑处理中…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: streaming) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func bubble(role: String, text: String) -> some View {
        let isUser = role == "user"
        let isSystem = role == "system"
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            if !isSystem {
                Text(isUser ? "我" : "电脑")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isUser ? Color.secondary : Color.accentColor)
            }
            Text(text)
                .font(isSystem ? .caption : .body)
                .italic(isSystem)
                .foregroundStyle(isSystem ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, isSystem ? 4 : 13)
                .padding(.vertical, isSystem ? 2 : 9)
                .background {
                    if isSystem {
                        Color.clear
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isUser
                                  ? Color.accentColor.opacity(0.16)
                                  : Color(uiColor: .secondarySystemBackground))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: 输入

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("跟电脑说点什么", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
                .onSubmit(sendNow)

            Button(action: sendNow) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !remote.running
    }

    private func loadMoreHistory() {
        guard historyHasMore, !loadingMore,
              !currentSessionForHistory.isEmpty
        else { return }
        loadingMore = true
        let before = historyNextBefore

        Task {
            let page = await remote.fetchHistory(
                sessionId: currentSessionForHistory,
                before: before,
                rounds: 5
            )
            loadingMore = false
            historyHasMore = page.hasMore
            historyNextBefore = page.nextBefore

            if page.messages.isEmpty {
                messages.insert(("system", "没有更早的消息了"), at: 0)
                historyHasMore = false
            } else {
                // 插到最前面
                var newRows: [(role: String, text: String)] = page.messages.map { item in (role: item.role, text: item.text) }
                newRows.append(("system", page.hasMore ? "— 还能继续上滑 —" : "—— 历史最早处 ——"))
                messages.insert(contentsOf: newRows, at: 0)
            }
        }
    }

    private func sendNow() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !remote.running else { return }
        draft = ""
        messages.append(("user", text))
        streaming = ""

        Task {
            let reply = await remote.chat(text) { piece in
                streaming += piece
            }
            if reply.isEmpty {
                streaming = ""
                messages.append(("system", "（电脑没有返回内容）"))
            } else {
                messages.append(("assistant", reply))
                streaming = ""
            }
            // 回复完刷新会话列表，标题可能变了
            await remote.refreshSessions()
        }
    }

    // MARK: 未连接引导

    private var pairingGuide: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)

                Text("还没连接电脑").font(.headline)

                if remote.savedPairs.isEmpty {
                    Text("在电脑的 DSH 设置里打开 Harness Link，\n把配对信息复制过来，或直接扫码。")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showScanner = true
                } label: {
                    Label("扫码配对", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // 记住的连接
                if !remote.savedPairs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("上次连接")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("全部清除") {
                                remote.forgetAll()
                            }
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                        ForEach(Array(remote.savedPairs.enumerated()), id: \.offset) { idx, p in
                            Button {
                                remote.connect(pair: p)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortHost(p.relay))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("房间 " + p.room)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if idx == 0 {
                                        Text("最近")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.12), in: Capsule())
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    remote.forget(p)
                                } label: {
                                    Label("删除这条", systemImage: "trash")
                                }
                            }

                            if idx < remote.savedPairs.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 4)
        }
    }

    private func shortHost(_ relay: String) -> String {
        if let u = URL(string: relay) {
            let host = u.host ?? relay
            let port = u.port.map { ":\($0)" } ?? ""
            return host + port
        }
        return relay
    }
}

// MARK: - 会话选择

struct SessionPickerSheet: View {
    let sessions: [RemoteControl.RemoteSession]
    let activeId: String?
    let onPick: (RemoteControl.RemoteSession?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [RemoteControl.RemoteSession] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.preview.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.bubble.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开新对话").font(.body)
                                Text("下一条消息在电脑上新建一个会话")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if activeId == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("电脑上的会话（\(sessions.count)）") {
                    if filtered.isEmpty {
                        Text(sessions.isEmpty ? "电脑上没有会话" : "没有匹配的")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { s in
                            Button {
                                onPick(s)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.title)
                                            .font(.body)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            if s.messages > 0 {
                                                Text("\(s.messages) 条")
                                            }
                                            if !s.workspace.isEmpty {
                                                Text(s.workspace)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                        if !s.preview.isEmpty {
                                            Text(s.preview)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if s.id == activeId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜标题或内容")
            .navigationTitle("选择会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 扫码

struct PairScannerSheet: View {
    let onScanned: (PairPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manual = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 14) {
                    QRScannerView { code in
                        if let p = PairPayload.parse(code) { onScanned(p) }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)

                    VStack(spacing: 8) {
                        Text("或者粘贴配对信息")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("{\"v\":1,\"relay\":...,\"room\":...,\"token\":...}", text: $manual, axis: .vertical)
                            .font(.caption.monospaced())
                            .lineLimit(3...6)
                            .padding(10)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            }
                            .padding(.horizontal, 16)
                        Button("配对") {
                            if let p = PairPayload.parse(manual) { onScanned(p) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(PairPayload.parse(manual) == nil)
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
            .navigationTitle("配对电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 二维码扫描

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !handled,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue
        else { return }
        handled = true
        session.stopRunning()
        onCode?(code)
    }
}
