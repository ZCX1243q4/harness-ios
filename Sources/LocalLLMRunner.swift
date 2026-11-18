import Foundation
import SwiftUI

/// 管理 llama.cpp 引擎的生命周期。App 内同一时刻只加载一个本地模型。
@MainActor
final class LocalLLMRunner: ObservableObject {

    static let shared = LocalLLMRunner()

    @Published private(set) var loadedFile: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let engine = LlamaEngine()

    private init() {}

    var isReady: Bool { !loadedFile.isEmpty && !isLoading }

    /// 确保指定模型已加载；已加载同一个就直接用
    func ensureLoaded(fileName: String, contextLength: Int = 4096, threads: Int = 4) async throws {
        if loadedFile == fileName, !isLoading { return }

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

        let cfg = LlamaEngine.Config(
            contextLength: contextLength,
            threads: threads
        )

        // 加载是阻塞的，扔到后台
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                do {
                    try engine.load(path: url.path, config: cfg)
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

    func cancel() {
        engine.cancel()
    }

    /// 跑一次完整生成
    func run(
        config: EndpointConfig,
        turns: [ChatTurn],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> StreamResult {
        let started = Date()

        try await ensureLoaded(
            fileName: config.localModelFile,
            contextLength: min(8192, max(2048, config.maxTokens * 2)),
            threads: ProcessInfo.processInfo.activeProcessorCount
        )

        let prompt = Self.buildPrompt(
            system: config.effectiveSystemPrompt,
            turns: turns
        )

        // 生成跑后台，token 回主线程
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
            text: text,
            retried: false,
            matchedRule: -1,
            promptTokens: 0,
            completionTokens: 0,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            truncated: false
        )
    }

    /// 拼成 ChatML 风格，大多数 instruct 模型都认
    static func buildPrompt(system: String, turns: [ChatTurn]) -> String {
        var s = ""
        if !system.isEmpty {
            s += "<|im_start|>system\n\(system)<|im_end|>\n"
        }
        for t in turns {
            let role = t.role == "assistant" ? "assistant" : "user"
            s += "<|im_start|>\(role)\n\(t.content)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        return s
    }
}
