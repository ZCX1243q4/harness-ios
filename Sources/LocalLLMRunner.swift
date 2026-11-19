import Foundation
import SwiftUI

#if canImport(llama)

/// 管理 llama.cpp 引擎的生命周期。App 内同一时刻只加载一个本地模型。
@MainActor
final class LocalLLMRunner: ObservableObject {

    static let shared = LocalLLMRunner()

    @Published private(set) var loadedFile: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let engine = LlamaEngine()

    private init() {}

    /// 引擎是否编译进这个包
    static let engineAvailable = true

    var isReady: Bool { loadError == nil && engine.isLoaded }

    /// 诊断信息
    var debugInfo: (loaded: Bool, file: String, params: UInt64, ctx: Int, trained: Int, template: String) {
        (
            loaded: engine.isLoaded,
            file: loadedFile ?? "",
            params: engine.parameterCount,
            ctx: engine.contextSize,
            trained: engine.trainedContext,
            template: engine.templatePreview
        )
    }

    var architectureDebug: String { engine.architecture }
    var modelNameDebug: String { engine.modelName }

    var lastPromptDebug: String { engine.lastPrompt }

    func ensureLoaded(fileName: String, contextLength: Int = 4096, threads: Int = 4) async throws {
        if loadedFile == fileName, engine.isLoaded { return }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let url = LocalModelStore.modelsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadedFile = nil
            let msg = "找不到文件：\(fileName)"
            loadError = msg
            throw LlamaError.loadFailed
        }

        engine.unload()

        var cfg = LlamaEngine.Config(contextLength: contextLength, threads: threads)
        // 小模型容易复读，惩罚调重一点
        cfg.repeatPenalty = 1.3
        cfg.penaltyLastN = 64
        cfg.temperature = 0.6
        cfg.maxTokens = min(768, contextLength / 2)
        let path = url.path

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                do {
                    try engine.load(path: path, config: cfg)
                    Task { @MainActor in
                        self.loadedFile = fileName
                        cont.resume()
                    }
                } catch {
                    Task { @MainActor in
                        self.loadedFile = nil
                        self.loadError = error.localizedDescription
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func unload() {
        engine.unload()
        loadedFile = nil
    }

    func cancel() { engine.cancel() }

    func run(
        config: EndpointConfig,
        turns: [ChatTurn],
        prefill: String = "",
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> StreamResult {
        let started = Date()

        // 手机上内存有限：上下文别开太大
        let ctxLen = min(4096, max(1024, config.maxTokens))
        try await ensureLoaded(
            fileName: config.localModelFile,
            contextLength: ctxLen,
            threads: max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
        )

        engine.disableThinking = config.disableThinking
        engine.setPrefill(prefill)

        // 用模型自带的对话模板拼 prompt（engine 内部处理）
        let tupleTurns = turns.map { (role: $0.role, content: $0.content) }
        let prompt = engine.buildPrompt(
            system: config.effectiveSystemPrompt,
            turns: tupleTurns
        )

        let text: String = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                do {
                    let out = try engine.generate(prompt: prompt) { piece in
                        Task { @MainActor in onDelta(piece) }
                    }
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        if text.isEmpty { throw LLMError.empty }

        return StreamResult(
            text: text, retried: false, matchedRule: -1,
            promptTokens: 0, completionTokens: 0,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            truncated: false
        )
    }

}

#else

/// llama.cpp 没编进来时的降级实现：界面照常，点本地模型会给出明确提示。
@MainActor
final class LocalLLMRunner: ObservableObject {

    static let shared = LocalLLMRunner()
    static let engineAvailable = false

    @Published private(set) var loadedFile: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private init() {}

    var isReady: Bool { false }

    var debugInfo: (loaded: Bool, file: String, params: UInt64, ctx: Int, trained: Int, template: String) {
        (false, "", 0, 0, 0, "引擎未编入")
    }

    var lastPromptDebug: String { "" }
    var architectureDebug: String { "—" }
    var modelNameDebug: String { "—" }

    func ensureLoaded(fileName: String, contextLength: Int = 4096, threads: Int = 4) async throws {
        throw LLMError.http(0, "这个包没有编入 llama.cpp 引擎")
    }

    func unload() {}
    func cancel() {}

    func run(
        config: EndpointConfig,
        turns: [ChatTurn],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> StreamResult {
        throw LLMError.http(0, "这个包没有编入 llama.cpp 引擎，本地推理不可用。\n模型文件可以用，引擎需要重新打包。")
    }
}

#endif
