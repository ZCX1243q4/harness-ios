import Foundation
import SwiftData

// MARK: - 供应商类型

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    /// 苹果设备端模型，走 FoundationModels，不需要地址和 key
    case onDevice = "ondevice"
    /// 本地 GGUF 模型，走 llama.cpp
    case localGGUF = "localgguf"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .onDevice: return "设备端模型"
        case .localGGUF: return "本地 GGUF"
        }
    }

    /// 不需要 baseURL / apiKey 的类型
    var isOnDevice: Bool { self == .onDevice || self == .localGGUF }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .onDevice: return ""
        case .localGGUF: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-5"
        case .gemini: return "gemini-2.0-flash"
        case .onDevice: return "Apple Intelligence"
        case .localGGUF: return "本地模型"
        }
    }

    var symbol: String {
        switch self {
        case .openAI: return "bolt.horizontal.circle"
        case .anthropic: return "a.circle"
        case .gemini: return "sparkles"
        case .onDevice: return "cpu"
        case .localGGUF: return "internaldrive"
        }
    }

    var keyHint: String {
        switch self {
        case .openAI: return "sk-..."
        case .anthropic: return "sk-ant-..."
        case .gemini: return "AIza..."
        case .onDevice: return "不需要"
        case .localGGUF: return "不需要"
        }
    }
}

// MARK: - 供应商

@Model
final class Provider {
    @Attribute(.unique) var uid: UUID
    var name: String
    var kindRaw: String
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var extraHeaders: String
    var systemPrompt: String
    var boostEnabled: Bool = true
    var refusalRetry: Bool = true
    /// 单次请求上限，0 = 不限制
    var timeoutSeconds: Int = 120
    /// localGGUF 时指向 Documents/Models 下的文件名
    var localModelFile: String = ""
    var createdAt: Date

    init(
        name: String,
        kind: ProviderKind,
        baseURL: String,
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        extraHeaders: String = "",
        systemPrompt: String = PromptPresets.unrestricted,
        boostEnabled: Bool = true,
        refusalRetry: Bool = true
    ) {
        self.uid = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraHeaders = extraHeaders
        self.systemPrompt = systemPrompt
        self.boostEnabled = boostEnabled
        self.refusalRetry = refusalRetry
        self.timeoutSeconds = 120
        self.createdAt = .now
    }

    var kind: ProviderKind {
        get { ProviderKind(rawValue: kindRaw) ?? .openAI }
        set { kindRaw = newValue.rawValue }
    }

    var keychainAccount: String { "provider.\(uid.uuidString)" }
}

// MARK: - 会话

@Model
final class Conversation {
    @Attribute(.unique) var uid: UUID
    var title: String
    var providerUID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool = false
    /// 归档，不计入列表
    var archived: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(title: String = "新对话", providerUID: UUID? = nil) {
        self.uid = UUID()
        self.title = title
        self.providerUID = providerUID
        self.createdAt = .now
        self.updatedAt = .now
        self.pinned = false
        self.archived = false
    }

    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var preview: String {
        orderedMessages.last(where: { $0.role != .system })?.text ?? ""
    }
}

// MARK: - 消息

enum MessageRole: String, Codable {
    case system, user, assistant

    var label: String {
        switch self {
        case .system: return "系统"
        case .user: return "我"
        case .assistant: return "AI"
        }
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var uid: UUID
    var roleRaw: String
    var text: String
    var createdAt: Date
    var conversation: Conversation?
    /// 输入 token（接口给了才有）
    var promptTokens: Int = 0
    /// 输出 token
    var completionTokens: Int = 0
    /// 这次请求触发过拒绝重试
    var retried: Bool = false
    /// 命中的拒绝规则下标，-1 = 无
    var matchedRule: Int = -1
    var latencyMs: Int = 0

    init(role: MessageRole, text: String, conversation: Conversation? = nil) {
        self.uid = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = .now
        self.conversation = conversation
        self.promptTokens = 0
        self.completionTokens = 0
        self.retried = false
        self.matchedRule = -1
        self.latencyMs = 0
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var totalTokens: Int { promptTokens + completionTokens }
}

// MARK: - 提示词芯片

@Model
final class PromptChip {
    @Attribute(.unique) var uid: UUID
    var title: String
    var text: String
    var createdAt: Date

    init(title: String, text: String) {
        self.uid = UUID()
        self.title = title
        self.text = text
        self.createdAt = .now
    }
}
