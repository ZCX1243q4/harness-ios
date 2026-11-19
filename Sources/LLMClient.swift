import Foundation

struct ChatTurn: Sendable {
    let role: String
    let content: String
}

struct EndpointConfig: Sendable {
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var systemPrompt: String
    var temperature: Double
    var maxTokens: Int
    var extraHeaders: String
    var boostEnabled: Bool
    var refusalRetry: Bool
    var timeoutSeconds: Int
    var localModelFile: String
    var disableThinking: Bool

    init(
        kind: ProviderKind,
        baseURL: String,
        model: String,
        systemPrompt: String,
        temperature: Double,
        maxTokens: Int,
        extraHeaders: String,
        boostEnabled: Bool = true,
        refusalRetry: Bool = true,
        timeoutSeconds: Int = 120,
        localModelFile: String = "",
        disableThinking: Bool = true
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraHeaders = extraHeaders
        self.boostEnabled = boostEnabled
        self.refusalRetry = refusalRetry
        self.timeoutSeconds = timeoutSeconds
        self.localModelFile = localModelFile
        self.disableThinking = disableThinking
    }

    init(provider: Provider) {
        self.kind = provider.kind
        self.baseURL = provider.baseURL
        self.model = provider.model
        self.systemPrompt = provider.systemPrompt
        self.temperature = provider.temperature
        self.maxTokens = provider.maxTokens
        self.extraHeaders = provider.extraHeaders
        self.boostEnabled = provider.boostOn
        self.refusalRetry = provider.retryOn
        self.timeoutSeconds = provider.timeoutSeconds
        self.localModelFile = provider.localModelFile
        self.disableThinking = provider.disableThinking
    }

    var effectiveSystemPrompt: String {
        PromptBoost.assemble(systemPrompt: systemPrompt, boostEnabled: boostEnabled)
    }
}

enum LLMError: LocalizedError {
    case missingKey
    case badURL(String)
    case http(Int, String)
    case empty
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingKey: return "这个供应商还没有填 API Key"
        case .badURL(let s): return "接口地址无效：\(s)"
        case .http(let code, let body): return "HTTP \(code)\n\(body.prefix(600))"
        case .empty: return "模型没有返回内容"
        case .cancelled: return "已取消"
        case .timeout: return "请求超时"
        }
    }
}

struct StreamResult: Sendable {
    let text: String
    let retried: Bool
    let matchedRule: Int
    let promptTokens: Int
    let completionTokens: Int
    let latencyMs: Int
    /// 因为 max_tokens 被截断
    let truncated: Bool
}

enum LLMClient {

    private static let refusalBufferChars = 400

    static func stream(
        config: EndpointConfig,
        apiKey: String,
        turns: [ChatTurn],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> StreamResult {
        // 本地 GGUF 走 llama.cpp。也要走破甲重试 —— 本地 instruct 模型同样会对齐拒答。
        if config.kind == .localGGUF {
            let started = Date()

            let first = try await LocalLLMRunner.shared.run(
                config: config, turns: turns, onDelta: onDelta
            )

            guard config.refusalRetry else {
                return StreamResult(
                    text: first.text, retried: false, matchedRule: -1,
                    promptTokens: 0, completionTokens: 0,
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    truncated: false
                )
            }

            let head = String(first.text.prefix(refusalBufferChars))
            let rule = PromptBoost.matchIndex(head)
            guard rule >= 0 else {
                return StreamResult(
                    text: first.text, retried: false, matchedRule: -1,
                    promptTokens: 0, completionTokens: 0,
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    truncated: false
                )
            }

            // 命中拒绝：换一套更强的打法重跑
            // 1) 系统提示换成超强版（不只是原尾段 + nudge）
            // 2) 用 prefill 把模型按进"直接开始写"的轨道，绕开拒绝开场
            var nudged = config
            nudged.systemPrompt = PromptBoost.assemble(
                systemPrompt: PromptBoost.strongMode,
                boostEnabled: true
            ) + PromptBoost.retryNudge
            nudged.boostEnabled = false     // 已手动拼好

            let prefill = PromptBoost.prefillFor(turns: turns)

            let second = try await LocalLLMRunner.shared.run(
                config: nudged, turns: turns, prefill: prefill, onDelta: onDelta
            )
            return StreamResult(
                text: second.text, retried: true, matchedRule: rule,
                promptTokens: 0, completionTokens: 0,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                truncated: false
            )
        }

        // 设备端模型不走网络
        if config.kind == .onDevice {
            let started = Date()
            let text = try await OnDeviceClient.stream(
                systemPrompt: config.effectiveSystemPrompt,
                turns: turns,
                onDelta: onDelta
            )
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

        if !config.kind.isOnDevice && apiKey.isEmpty { throw LLMError.missingKey }

        let started = Date()
        var usage = (prompt: 0, completion: 0, truncated: false)

        let first = try await runOnce(
            config: config,
            apiKey: apiKey,
            turns: turns,
            systemSuffix: "",
            usage: &usage,
            onDelta: onDelta
        )

        guard config.refusalRetry else {
            return StreamResult(
                text: first,
                retried: false,
                matchedRule: -1,
                promptTokens: usage.prompt,
                completionTokens: usage.completion,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                truncated: usage.truncated
            )
        }

        let head = String(first.prefix(refusalBufferChars))
        let rule = PromptBoost.matchIndex(head)
        guard rule >= 0 else {
            return StreamResult(
                text: first,
                retried: false,
                matchedRule: -1,
                promptTokens: usage.prompt,
                completionTokens: usage.completion,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                truncated: usage.truncated
            )
        }

        var retryUsage = (prompt: 0, completion: 0, truncated: false)
        // 命中拒绝：换成强化模式重跑，不只是加一句叮嘱
        var strongConfig = config
        strongConfig.systemPrompt = PromptBoost.strongMode
        strongConfig.boostEnabled = true

        let second = try await runOnce(
            config: strongConfig,
            apiKey: apiKey,
            turns: turns,
            systemSuffix: PromptBoost.retryNudge,
            usage: &retryUsage,
            onDelta: onDelta
        )
        return StreamResult(
            text: second,
            retried: true,
            matchedRule: rule,
            promptTokens: retryUsage.prompt,
            completionTokens: retryUsage.completion,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            truncated: retryUsage.truncated
        )
    }

    // MARK: - 单次

    private static func runOnce(
        config: EndpointConfig,
        apiKey: String,
        turns: [ChatTurn],
        systemSuffix: String,
        usage: inout (prompt: Int, completion: Int, truncated: Bool),
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let system = config.effectiveSystemPrompt + systemSuffix
        let request = try makeRequest(config: config, apiKey: apiKey, turns: turns, system: system)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 3000 { break }
            }
            throw LLMError.http(http.statusCode, body)
        }

        var full = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

            // 顺带把 usage / finish_reason 捞出来
            harvestUsage(data, kind: config.kind, usage: &usage)

            if let piece = parseDelta(data, kind: config.kind), !piece.isEmpty {
                full += piece
                await onDelta(piece)
            }
        }

        if full.isEmpty { throw LLMError.empty }
        return full
    }

    // MARK: - 用量

    private static func harvestUsage(
        _ data: Data,
        kind: ProviderKind,
        usage: inout (prompt: Int, completion: Int, truncated: Bool)
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        switch kind {
        case .openAI:
            if let u = obj["usage"] as? [String: Any] {
                if let p = u["prompt_tokens"] as? Int { usage.prompt = p }
                if let c = u["completion_tokens"] as? Int { usage.completion = c }
            }
            if let choices = obj["choices"] as? [[String: Any]],
               let reason = choices.first?["finish_reason"] as? String,
               reason == "length" {
                usage.truncated = true
            }

        case .anthropic:
            if (obj["type"] as? String) == "message_start",
               let msg = obj["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any] {
                if let p = u["input_tokens"] as? Int { usage.prompt = p }
                if let c = u["output_tokens"] as? Int { usage.completion = c }
            }
            if (obj["type"] as? String) == "message_delta" {
                if let u = obj["usage"] as? [String: Any],
                   let c = u["output_tokens"] as? Int {
                    usage.completion = c
                }
                if let delta = obj["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String,
                   reason == "max_tokens" {
                    usage.truncated = true
                }
            }

        case .gemini:
            if let meta = obj["usageMetadata"] as? [String: Any] {
                if let p = meta["promptTokenCount"] as? Int { usage.prompt = p }
                if let c = meta["candidatesTokenCount"] as? Int { usage.completion = c }
            }
            if let candidates = obj["candidates"] as? [[String: Any]],
               let reason = candidates.first?["finishReason"] as? String,
               reason == "MAX_TOKENS" {
                usage.truncated = true
            }

        case .onDevice:
            break

        case .localGGUF:
            break
        }
    }

    // MARK: - 请求

    private static func makeRequest(
        config: EndpointConfig,
        apiKey: String,
        turns: [ChatTurn],
        system: String
    ) throws -> URLRequest {
        let url: URL?
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "temperature": config.temperature,
        ]
        var headers: [String: String] = ["Content-Type": "application/json"]

        switch config.kind {
        case .openAI:
            url = endpoint(config.baseURL, "/chat/completions")
            var messages: [[String: Any]] = []
            if !system.isEmpty {
                messages.append(["role": "system", "content": system])
            }
            messages += turns.map { ["role": $0.role, "content": $0.content] }
            body["messages"] = messages
            body["max_tokens"] = config.maxTokens
            headers["Authorization"] = "Bearer \(apiKey)"

        case .anthropic:
            url = endpoint(config.baseURL, "/messages")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = turns.map { ["role": $0.role, "content": $0.content] }
            body["max_tokens"] = config.maxTokens
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"

        case .gemini:
            let root = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var comps = URLComponents(string: root + "/models/\(config.model):streamGenerateContent")
            comps?.queryItems = [
                URLQueryItem(name: "alt", value: "sse"),
                URLQueryItem(name: "key", value: apiKey),
            ]
            url = comps?.url
            body.removeValue(forKey: "model")
            body.removeValue(forKey: "stream")
            body["contents"] = turns.map {
                ["role": $0.role == "assistant" ? "model" : "user",
                 "parts": [["text": $0.content]]]
            }
            body["generationConfig"] = [
                "temperature": config.temperature,
                "maxOutputTokens": config.maxTokens,
            ]
            if !system.isEmpty {
                body["systemInstruction"] = ["parts": [["text": system]]]
            }

        case .onDevice:
            throw LLMError.badURL("device")

        case .localGGUF:
            throw LLMError.badURL("local")
        }

        guard let finalURL = url else { throw LLMError.badURL(config.baseURL) }

        for line in config.extraHeaders.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds > 0 ? TimeInterval(config.timeoutSeconds) : 600
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix(path) { return URL(string: b) }
        if b.contains(":streamGenerateContent") { return URL(string: b) }
        return URL(string: b + path)
    }

    // MARK: - SSE

    private static func parseDelta(_ data: Data, kind: ProviderKind) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch kind {
        case .openAI:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { return nil }
            return delta["content"] as? String

        case .anthropic:
            guard (obj["type"] as? String) == "content_block_delta",
                  let delta = obj["delta"] as? [String: Any]
            else { return nil }
            return delta["text"] as? String

        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else { return nil }
            return parts.first?["text"] as? String

        case .onDevice, .localGGUF:
            return nil
        }
    }
}