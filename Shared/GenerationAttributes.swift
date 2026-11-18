import Foundation
import ActivityKit

/// 生成过程的活动属性。主 App 与 Widget extension 共用同一份定义。
struct GenerationAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case connecting
            case streaming
            case retrying
            case finished
            case failed
        }

        var phase: Phase
        var model: String
        var receivedChars: Int
        var elapsedSeconds: Int
        var note: String

        static func connecting(model: String) -> ContentState {
            ContentState(phase: .connecting, model: model, receivedChars: 0, elapsedSeconds: 0, note: "正在连接")
        }
    }

    /// 对话标题，开始后不再变
    var conversationTitle: String
    /// 供应商名字
    var providerName: String
}
