import Foundation
import SwiftUI

// MARK: - 配对信息
// 全部由用户扫码或粘贴获得，代码里不写任何服务器地址。

struct PairPayload: Codable, Equatable {
    var v: Int = 1
    var relay: String
    var room: String
    var token: String

    static func parse(_ text: String) -> PairPayload? {
        guard let data = text.data(using: .utf8),
              let p = try? JSONDecoder().decode(PairPayload.self, from: data),
              !p.relay.isEmpty, !p.token.isEmpty
        else { return nil }
        return p
    }
}

// MARK: - 远程会话

@MainActor
final class RemoteControl: ObservableObject {

    static let shared = RemoteControl()

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case hostOffline
        case failed(String)
    }

    struct RemoteSession: Identifiable, Equatable {
        let id: String
        let title: String
        let preview: String
        let messages: Int
        let workspace: String
        let updatedAt: Double
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var hostName = ""
    @Published private(set) var running = false
    @Published private(set) var sessions: [RemoteSession] = []
    /// 当前绑定的电脑端会话 id；nil = 每句话都让电脑新开一个
    @Published var activeSessionId: String?

    private var task: URLSessionWebSocketTask?
    private var pair: PairPayload?
    private var waiters: [String: (String) -> Void] = [:]
    private var streamHandlers: [String: (String) -> Void] = [:]
    private var seq = 0
    /// 保存的连接历史（最近用的排前面）
    @Published private(set) var savedPairs: [PairPayload] = []

    private static let storeKey = "harness.remote.savedPairs"
    private static let lastKey = "harness.remote.lastPair"

    private init() {
        loadSaved()
    }

    var isPaired: Bool { pair != nil }
    var relayAddress: String { pair?.relay ?? "" }
    var currentPair: PairPayload? { pair }

    // MARK: 连接信息持久化

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let list = try? JSONDecoder().decode([PairPayload].self, from: data)
        else { return }
        savedPairs = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedPairs) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// 把这次配对信息记下来，下次直接连
    private func rememberPair(_ p: PairPayload) {
        var list = savedPairs.filter { !($0.relay == p.relay && $0.room == p.room && $0.token == p.token) }
        list.insert(p, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        savedPairs = list
        persist()
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.lastKey)
        }
    }

    func forget(_ p: PairPayload) {
        savedPairs.removeAll { $0.relay == p.relay && $0.room == p.room && $0.token == p.token }
        persist()
    }

    func forgetAll() {
        savedPairs = []
        persist()
        UserDefaults.standard.removeObject(forKey: Self.lastKey)
    }

    /// 上次用过的连接信息
    var lastPair: PairPayload? {
        if let p = savedPairs.first { return p }
        guard let data = UserDefaults.standard.data(forKey: Self.lastKey),
              let p = try? JSONDecoder().decode(PairPayload.self, from: data)
        else { return nil }
        return p
    }

    /// 自动重连上次的电脑。启动时调用。
    @discardableResult
    func autoReconnect() -> Bool {
        guard let p = lastPair else { return false }
        connect(pair: p)
        return true
    }

    // MARK: 连接

    func connect(pair: PairPayload) {
        disconnect()
        self.pair = pair
        rememberPair(pair)

        guard var comps = URLComponents(string: pair.relay) else {
            status = .failed("中继地址无效")
            return
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "role", value: "client"))
        items.append(URLQueryItem(name: "room", value: pair.room))
        items.append(URLQueryItem(name: "token", value: pair.token))
        comps.queryItems = items

        guard let url = comps.url else {
            status = .failed("URL 拼接失败")
            return
        }

        status = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()

        listen()
        send(["t": "hello"])
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .idle
        sessions = []
        activeSessionId = nil
        waiters.values.forEach { $0("") }
        waiters.removeAll()
        streamHandlers.removeAll()
    }

    // MARK: 收发

    private func listen() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(s)
                    case .data(let d): self.handle(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    self.listen()
                case .failure:
                    if self.status == .connected { self.status = .hostOffline }
                }
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let t = obj["t"] as? String
        else { return }

        switch t {
        case "host-state":
            status = (obj["online"] as? Bool ?? false) ? .connected : .hostOffline
        case "host-online":
            status = .connected
        case "host-offline":
            status = .hostOffline
        case "hello-ack":
            hostName = obj["name"] as? String ?? "电脑"
            status = .connected
        case "sessions":
            if let list = obj["list"] as? [[String: Any]] {
                sessions = list.map { item in
                    RemoteSession(
                        id: item["id"] as? String ?? "",
                        title: item["title"] as? String ?? "(未命名)",
                        preview: item["preview"] as? String ?? "",
                        messages: item["messages"] as? Int ?? 0,
                        workspace: item["workspace"] as? String ?? "",
                        updatedAt: (item["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                    )
                }
            }
            resolve(obj["id"] as? String, "")
        case "chat-delta":
            let id = obj["id"] as? String ?? ""
            let piece = obj["text"] as? String ?? ""
            if let h = streamHandlers[id] { h(piece) }
        case "chat-accepted":
            break
        case "history":
            if let list = obj["list"] as? [[String: Any]] {
                fetchedHistory = list.compactMap { item in
                    guard let role = item["role"] as? String,
                          let text = item["text"] as? String,
                          !text.isEmpty
                    else { return nil }
                    return (role: role, text: text)
                }
            }
            fetchedHasMore = obj["hasMore"] as? Bool ?? false
            if let nb = obj["nextBefore"] as? NSNumber {
                fetchedNextBefore = nb.intValue
            } else {
                fetchedNextBefore = nil
            }
            resolve(obj["id"] as? String, "")
        case "chat-reply":
            let id = obj["id"] as? String ?? ""
            let full = obj["text"] as? String ?? ""
            resolve(id, full)
            streamHandlers.removeValue(forKey: id)
        case "exec-result":
            let out = (obj["stdout"] as? String) ?? (obj["stderr"] as? String) ?? ""
            resolve(obj["id"] as? String, out)
        case "error":
            let id = obj["id"] as? String
            let message = obj["message"] as? String ?? "中继错误"
            if let id { resolve(id, "错误：" + message) } else { status = .failed(message) }
        default:
            break
        }
    }

    private func resolve(_ id: String?, _ value: String) {
        guard let id, let waiter = waiters.removeValue(forKey: id) else { return }
        running = false
        waiter(value)
    }

    // MARK: 会话管理

    /// 拉电脑上的会话列表
    func refreshSessions() async {
        guard status == .connected else { return }
        seq += 1
        let id = "s\(seq)"
        _ = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var finished = false
            waiters[id] = { _ in
                guard !finished else { return }
                finished = true
                cont.resume(returning: "")
            }
            send(["t": "list-sessions", "id": id])
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let w = self.waiters.removeValue(forKey: id), !finished {
                    finished = true
                    w("")
                }
            }
        }
    }

    /// 绑定到某个电脑端会话；传 nil 表示每句话新开一个
    func select(sessionId: String?) {
        activeSessionId = sessionId
    }

    /// 电脑端返回的历史消息
    private var fetchedHistory: [(role: String, text: String)] = []
    private var fetchedHasMore = false
    private var fetchedNextBefore: Int?

    struct HistoryPage {
        let messages: [(role: String, text: String)]
        let hasMore: Bool
        let nextBefore: Int?
    }

    /// 拉某个电脑会话的历史，分页：从最新往回拉 rounds 轮
    func fetchHistory(
        sessionId: String,
        before: Int? = nil,
        rounds: Int = 5,
        timeoutMs: Int = 20000
    ) async -> HistoryPage {
        guard status == .connected, !sessionId.isEmpty else {
            return HistoryPage(messages: [], hasMore: false, nextBefore: nil)
        }
        fetchedHistory = []
        fetchedHasMore = false
        fetchedNextBefore = nil

        seq += 1
        let id = "h\(seq)"

        _ = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var finished = false
            waiters[id] = { _ in
                guard !finished else { return }
                finished = true
                cont.resume(returning: "")
            }
            var payload: [String: Any] = ["t": "history", "id": id, "sessionId": sessionId, "rounds": rounds]
            if let before { payload["before"] = before }
            send(payload)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                if let w = self.waiters.removeValue(forKey: id), !finished {
                    finished = true
                    w("")
                }
            }
        }

        let page = HistoryPage(
            messages: fetchedHistory,
            hasMore: fetchedHasMore,
            nextBefore: fetchedNextBefore
        )
        fetchedHistory = []
        return page
    }

    var activeSessionTitle: String {
        guard let id = activeSessionId,
              let s = sessions.first(where: { $0.id == id })
        else { return "新对话" }
        return s.title
    }

    // MARK: 对话

    /// 发一句话给电脑。activeSessionId 为 nil 时电脑端会新开一个会话。
    func chat(
        _ text: String,
        onDelta: ((String) -> Void)? = nil,
        timeoutMs: Int = 180000
    ) async -> String {
        guard status == .connected else { return "电脑离线" }
        running = true
        seq += 1
        let id = "m\(seq)"

        if let onDelta { streamHandlers[id] = onDelta }

        return await withCheckedContinuation { cont in
            var finished = false
            waiters[id] = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            var payload: [String: Any] = ["t": "chat", "id": id, "text": text]
            if let sid = activeSessionId, !sid.isEmpty {
                payload["sessionId"] = sid
            }
            send(payload)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(min(timeoutMs, 300000)) * 1_000_000)
                if let w = self.waiters.removeValue(forKey: id), !finished {
                    finished = true
                    self.running = false
                    self.streamHandlers.removeValue(forKey: id)
                    w("等待电脑回复超时")
                }
            }
        }
    }

    // MARK: 命令

    func run(_ command: String, timeoutMs: Int = 30000) async -> String {
        guard status == .connected else { return "电脑离线" }
        running = true
        seq += 1
        let id = "c\(seq)"

        return await withCheckedContinuation { cont in
            var finished = false
            waiters[id] = { v in
                guard !finished else { return }
                finished = true
                cont.resume(returning: v)
            }
            send(["t": "exec", "id": id, "cmd": command, "timeout": timeoutMs])
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs + 5000) * 1_000_000)
                if let w = self.waiters.removeValue(forKey: id), !finished {
                    finished = true
                    self.running = false
                    w("超时")
                }
            }
        }
    }
}
