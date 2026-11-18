import Foundation
import FoundationModels

/// iOS 26 自带的设备端模型（Apple Intelligence）。
/// 不需要地址、不需要 key、完全离线，模型由系统管理，不占 App 存储。
@available(iOS 26.0, *)
enum OnDeviceClient {

    enum Availability {
        case ready
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case unknown(String)

        var text: String {
            switch self {
            case .ready: return "可用"
            case .deviceNotEligible: return "这台设备不支持"
            case .notEnabled: return "需要在系统设置里开启 Apple Intelligence"
            case .modelNotReady: return "模型下载中，请稍后"
            case .unknown(let s): return s
            }
        }

        var available: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    static func availability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable(let other):
            return .unknown(String(describing: other))
        }
    }

    /// 流式生成。返回完整文本，每段增量回调给 onDelta。
    @MainActor
    static func stream(
        systemPrompt: String,
        turns: [ChatTurn],
        onDelta: @MainActor (String) -> Void
    ) async throws -> String {
        guard availability().available else {
            throw LLMError.http(0, availability().text)
        }

        let session = systemPrompt.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: systemPrompt)

        // 把历史压成一段上下文，最后一条作为本轮输入
        guard let last = turns.last else { throw LLMError.empty }
        let history = turns.dropLast()
        var context = ""
        for turn in history {
            let who = turn.role == "assistant" ? "助手" : "用户"
            context += "\(who)：\(turn.content)\n"
        }
        let prompt = context.isEmpty
            ? last.content
            : "以下是之前的对话：\n\(context)\n用户：\(last.content)"

        var full = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            let current = snapshot.content
            if current.count > full.count {
                let piece = String(current.dropFirst(full.count))
                full = current
                if !piece.isEmpty { onDelta(piece) }
            }
        }

        if full.isEmpty { throw LLMError.empty }
        return full
    }
}
