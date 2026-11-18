import Foundation
import ActivityKit

/// 灵动岛 / 锁屏的生成状态。失败静默降级——没授权或系统不支持时功能只是不显示。
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<GenerationAttributes>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var lastChars = 0
    private var lastPhase: GenerationAttributes.ContentState.Phase = .connecting
    private var lastNote = ""
    private var lastModel = ""

    private init() {}

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(conversationTitle: String, providerName: String, model: String) {
        guard isEnabled else { return }
        end()

        startedAt = Date()
        lastChars = 0
        lastPhase = .connecting
        lastNote = "正在连接"
        lastModel = model

        let attributes = GenerationAttributes(
            conversationTitle: String(conversationTitle.prefix(40)),
            providerName: providerName
        )
        let state = GenerationAttributes.ContentState(
            phase: .connecting,
            model: model,
            receivedChars: 0,
            elapsedSeconds: 0,
            note: "正在连接"
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(300))
            )
            startTicker()
        } catch {
            activity = nil
        }
    }

    func updateProgress(chars: Int) {
        guard activity != nil else { return }
        lastChars = chars
        lastPhase = .streaming
        lastNote = "生成中"
        push()
    }

    func markRetrying() {
        guard activity != nil else { return }
        lastPhase = .retrying
        lastNote = "检测到推脱，正在重试"
        push()
    }

    func finish(note: String = "完成") {
        guard let activity else { return }
        lastPhase = .finished
        lastNote = note
        push()

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        stopTicker()
        self.activity = nil
    }

    func fail(note: String) {
        guard let activity else { return }
        lastPhase = .failed
        lastNote = String(note.prefix(60))
        push()

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        stopTicker()
        self.activity = nil
    }

    func end() {
        stopTicker()
        if let activity {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    private func push() {
        guard let activity else { return }
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let state = GenerationAttributes.ContentState(
            phase: lastPhase,
            model: lastModel,
            receivedChars: lastChars,
            elapsedSeconds: elapsed,
            note: lastNote
        )
        let target = activity
        Task { await target.update(.init(state: state, staleDate: nil)) }
    }

    /// 每秒刷新计时，让灵动岛上的秒数真的在走
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard self.activity != nil else { return }
                self.push()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
