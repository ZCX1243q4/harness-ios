#if canImport(llama)
import Foundation
import llama

/// llama.cpp 的 Swift 封装。
///
/// 两个关键点（输出乱码/训练数据的根因）：
///  1. token 字节要用缓冲区的实际长度构造字符串，不能靠 null 终止符。
///     llama_token_to_piece 不写 \0，一个中文/emoji 常被拆成多个 token。
///  2. 对话模板必须问模型本身。硬编码 ChatML 会让模型当裸文本续写，
///     输出训练数据片段或标点堆。
final class LlamaEngine {

    struct Config {
        var contextLength: Int = 2048
        var threads: Int = 4
        var temperature: Float = 0.6
        var topP: Float = 0.9
        var topK: Int32 = 40
        var repeatPenalty: Float = 1.3
        var penaltyLastN: Int = 64
        var maxTokens: Int = 1024
        var seed: UInt32 = 1234
    }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var config = Config()
    private var cancelled = false
    private var backendReady = false
    /// 预填充文本：拼在 assistant 标记后，强制模型从合规开场续写
    private var prefill = ""
    private var chatTemplate: String?

    var isLoaded: Bool { model != nil && ctx != nil }
    var contextSize: Int { ctx.map { Int(llama_n_ctx($0)) } ?? 0 }
    var hasChatTemplate: Bool { (chatTemplate?.isEmpty == false) }

    /// 诊断用：模型有多少参数
    var parameterCount: UInt64 { model.map { llama_model_n_params($0) } ?? 0 }

    /// 诊断用：训练上下文长度
    var trainedContext: Int { model.map { Int(llama_model_n_ctx_train($0)) } ?? 0 }

    /// 诊断用：模型架构名（qwen2 / qwen3 / llama ...）
    var architecture: String {
        guard let m = model else { return "—" }
        return Self.metaString(m, "general.architecture") ?? "—"
    }

    /// 诊断用：模型名
    var modelName: String {
        guard let m = model else { return "—" }
        return Self.metaString(m, "general.name") ?? "—"
    }

    /// 诊断用：模板前 120 字符
    var templatePreview: String {
        guard let t = chatTemplate else { return "（模型没带对话模板）" }
        let flat = t.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(120))
    }

    /// 诊断用：最近一次实际发送的 prompt
    private(set) var lastPrompt: String = ""

    /// 只有 Qwen3 有 thinking 模式，Qwen2.5 没有。
    /// 用模型元数据里的 arch / name 判断，不能靠模板片段（Qwen2.5 也用 ChatML）。
    private var isQwen3Family: Bool {
        guard let m = model else { return false }
        guard let arch = Self.metaString(m, "general.architecture") else { return false }
        // Qwen3 的 arch 是 "qwen3"，Qwen2.5 是 "qwen2"
        return arch.lowercased() == "qwen3"
    }

    private static func metaString(_ model: OpaquePointer, _ key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = key.withCString { k in
            llama_model_meta_val_str(model, k, &buf, buf.count)
        }
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 是否关闭 thinking。Qwen3 的 thinking 会把推理过程当正文输出。
    var disableThinking = true

    // MARK: - 加载

    func load(path: String, config: Config = Config()) throws {
        unload()
        self.config = config

        if !backendReady {
            llama_backend_init()
            backendReady = true
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0

        var loaded: OpaquePointer?
        path.withCString { cPath in
            loaded = llama_model_load_from_file(cPath, mparams)
        }
        guard let m = loaded else { throw LlamaError.loadFailed }
        model = m

        guard let v = llama_model_get_vocab(m) else {
            llama_model_free(m); model = nil
            throw LlamaError.loadFailed
        }
        vocab = v

        if let raw = llama_model_chat_template(m, nil) {
            let s = String(cString: raw)
            chatTemplate = s.isEmpty ? nil : s
        }

        let trained = Int(llama_model_n_ctx_train(m))
        let want = min(config.contextLength, trained > 0 ? trained : config.contextLength)
        let ctxLen = max(512, want)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(ctxLen)
        cparams.n_batch = UInt32(min(ctxLen, 512))
        cparams.n_threads = Int32(config.threads)
        cparams.n_threads_batch = Int32(config.threads)

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m); model = nil; vocab = nil
            throw LlamaError.contextFailed
        }
        ctx = c
        llama_set_n_threads(c, Int32(config.threads), Int32(config.threads))

        guard let chain = makeSampler() else {
            llama_free(c); llama_model_free(m)
            ctx = nil; model = nil; vocab = nil
            throw LlamaError.samplerFailed
        }
        sampler = chain
    }

    func unload() {
        if let s = sampler { llama_sampler_free(s) }
        sampler = nil
        if let c = ctx { llama_free(c) }
        ctx = nil
        if let m = model { llama_model_free(m) }
        model = nil
        vocab = nil
        chatTemplate = nil
        if backendReady {
            llama_backend_free()
            backendReady = false
        }
    }

    func cancel() { cancelled = true }

    /// 设置预填充文本。空字符串表示不预填。
    func setPrefill(_ text: String) { prefill = text }

    /// 每次都造一条新的采样器链，seed 随机 —— 否则相同 prompt 会得到相同输出。
    /// 重复惩罚必须放在最前面：小模型没有它就会陷入复读循环。
    private func makeSampler() -> UnsafeMutablePointer<llama_sampler>? {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return nil }

        let nVocab = Int32(llama_vocab_n_tokens(vocab))
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            nVocab,
            Int32(config.penaltyLastN),   // 惩罚最近 N 个 token
            config.repeatPenalty,          // 1.1 = 轻度，1.3 = 强力
            0.0,
            0.0
        ))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(config.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(config.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        return chain
    }

    // MARK: - 组装 prompt

    func buildPrompt(system: String, turns: [(role: String, content: String)]) -> String {
        var messages: [(String, String)] = []
        if !system.isEmpty { messages.append(("system", system)) }
        for t in turns {
            let role = (t.role == "assistant") ? "assistant" : "user"
            messages.append((role, t.content))
        }
        guard !messages.isEmpty else { return "" }

        // Qwen3 系列默认开 thinking，会把推理过程当正文吐出来。
        // 官方给的软开关：在最后一条 user 消息末尾加 /no_think。
        var finalMessages = messages
        if isQwen3Family, !disableThinking {
            if let last = finalMessages.last, last.0 == "user" {
                finalMessages[finalMessages.count - 1] = (last.0, last.1 + " /no_think")
            }
        }

        var base: String

        // Qwen2.5 / Qwen3 一律手写 ChatML。
        // llama_chat_apply_template 没有 Jinja 解析器，Qwen 的模板（以 {%- if tools %} 开头）
        // 匹配不上内置列表，返回的可能是空或残缺格式 —— 系统提示词会丢。
        if useChatML {
            base = Self.chatML(messages: finalMessages, addAssistant: true)
        } else if let tmpl = chatTemplate,
                  let applied = Self.applyTemplate(tmpl, messages: finalMessages) {
            base = applied
        } else {
            base = Self.chatML(messages: finalMessages, addAssistant: true)
        }

        // 预填充：接在 assistant 标记后面，让模型顺着这段往下写
        if !prefill.isEmpty {
            base += prefill
        }
        return base
    }

    /// Qwen 系（ChatML 格式）。判定依据是模型架构，不是模板片段。
    private var useChatML: Bool {
        guard let m = model else { return false }
        guard let arch = Self.metaString(m, "general.architecture") else { return false }
        let a = arch.lowercased()
        return a.hasPrefix("qwen")
    }

    /// 手写 ChatML。Qwen2.5 / Qwen3 的官方格式就是这一套。
    static func chatML(messages: [(String, String)], addAssistant: Bool) -> String {
        var out = ""
        for (role, content) in messages {
            out += "<|im_start|>" + role + "\n" + content + "<|im_end|>\n"
        }
        if addAssistant {
            out += "<|im_start|>assistant\n"
        }
        return out
    }

    private static func applyTemplate(_ template: String, messages: [(String, String)]) -> String? {
        var cMessages: [llama_chat_message] = []
        var keepAlive: [UnsafeMutablePointer<CChar>] = []

        for (role, content) in messages {
            guard let rp = strdup(role), let cp = strdup(content) else {
                keepAlive.forEach { free($0) }
                return nil
            }
            keepAlive.append(rp)
            keepAlive.append(cp)
            cMessages.append(llama_chat_message(role: UnsafePointer(rp), content: UnsafePointer(cp)))
        }
        defer { keepAlive.forEach { free($0) } }

        var result: String?
        template.withCString { tmplPtr in
            let needed = llama_chat_apply_template(tmplPtr, cMessages, cMessages.count, true, nil, 0)
            guard needed > 0 else { return }
            var buf = [CChar](repeating: 0, count: Int(needed) + 64)
            let written = llama_chat_apply_template(tmplPtr, cMessages, cMessages.count, true, &buf, Int32(buf.count))
            guard written > 0, Int(written) <= buf.count else { return }
            buf.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                let raw = UnsafeRawBufferPointer(start: base, count: Int(written))
                result = String(decoding: raw.bindMemory(to: UInt8.self), as: UTF8.self)
            }
        }
        return result
    }

    // MARK: - 生成

    func generate(prompt: String, onToken: @escaping (String) -> Void) throws -> String {
        guard let ctx, let vocab else { throw LlamaError.notLoaded }
        cancelled = false

        lastPrompt = prompt

        // 每轮重建采样器：固定 seed 的 RNG 会让每次输出完全一样
        if let old = sampler { llama_sampler_free(old) }
        sampler = makeSampler()

        if let mem = llama_get_memory(ctx) { llama_memory_clear(mem, true) }

        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { throw LlamaError.emptyPrompt }

        let nCtx = Int(llama_n_ctx(ctx))
        let reserve = max(64, config.maxTokens)
        if tokens.count > nCtx - reserve {
            let keep = max(1, nCtx - reserve)
            tokens = Array(tokens.suffix(keep))
        }

        var decodeTokens = tokens
        let rc = decodeTokens.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            let batch = llama_batch_get_one(base, Int32(buf.count))
            return llama_decode(ctx, batch)
        }
        if rc != 0 { throw LlamaError.decodeFailed(rc) }

        var output = ""
        var generated = 0
        var pending = Data()

        while generated < config.maxTokens && !cancelled {
            guard let smp = sampler else { break }
            let id = llama_sampler_sample(smp, ctx, -1)
            llama_sampler_accept(smp, id)
            if llama_vocab_is_eog(vocab, id) { break }

            if let bytes = tokenBytes(id) {
                pending.append(contentsOf: bytes)
                if let text = Self.takeCompleteUTF8(&pending) {
                    output += text
                    onToken(text)
                }
            }

            var one = [id]
            let r = one.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                let batch = llama_batch_get_one(base, 1)
                return llama_decode(ctx, batch)
            }
            if r != 0 { break }
            generated += 1
        }

        if !pending.isEmpty {
            if let tail = String(data: pending, encoding: .utf8) {
                output += tail
                onToken(tail)
            }
            pending.removeAll()
        }

        return Self.stripThinking(output)
    }

    /// 兜底剥离 thinking 块。Qwen3 用  thinking...<｜end▁of▁thinking｜>，
    /// 若开了 /no_think 但模型仍输出，这里保证界面上看不到。
    static func stripThinking(_ text: String) -> String {
        var s = text
        // 成对的 thinking 块
        while let start = s.range(of: " thinking"),
              let end = s.range(of: "<｜end▁of▁thinking｜>", range: start.upperBound..<s.endIndex) {
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // 未闭合的：从  thinking 起全砍掉
        if let start = s.range(of: " thinking") {
            s = String(s[s.startIndex..<start.lowerBound])
        }
        // Qwen3 的特殊 token 形式
        s = s.replacingOccurrences(of: "<|endoftext|>", with: "")
        s = s.replacingOccurrences(of: "<|im_end|>", with: "")
        s = s.replacingOccurrences(of: "<|im_start|>", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func takeCompleteUTF8(_ buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }
        let bytes = [UInt8](buffer)
        var cut = bytes.count
        var attempt = 0
        while cut > 0 && attempt < 4 {
            let prefix = Array(bytes.prefix(cut))
            if let s = String(bytes: prefix, encoding: .utf8) {
                buffer = Data(bytes.suffix(bytes.count - cut))
                return s
            }
            cut -= 1
            attempt += 1
        }
        return nil
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        return text.withCString { cstr in
            let byteCount = Int32(strlen(cstr))
            let probe = llama_tokenize(vocab, cstr, byteCount, nil, 0, addSpecial, true)
            guard probe < 0 else { return [] }
            let capacity = Int(-probe)
            guard capacity > 0 else { return [] }
            var buffer = [llama_token](repeating: 0, count: capacity)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                llama_tokenize(vocab, cstr, byteCount, ptr.baseAddress, Int32(capacity), addSpecial, true)
            }
            guard n > 0 else { return [] }
            return Array(buffer.prefix(Int(n)))
        }
    }

    private func tokenBytes(_ token: llama_token) -> [UInt8]? {
        guard let vocab else { return nil }
        var buffer = [CChar](repeating: 0, count: 512)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, false)
        }
        guard n > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { ptr -> [UInt8]? in
            guard let base = ptr.baseAddress else { return nil }
            let raw = UnsafeRawBufferPointer(start: base, count: Int(n))
            return Array(raw.bindMemory(to: UInt8.self))
        }
    }
}

enum LlamaError: LocalizedError {
    case loadFailed
    case contextFailed
    case samplerFailed
    case batchFailed
    case decodeFailed(Int32)
    case notLoaded
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "模型加载失败：文件可能损坏、不是 GGUF，或量化格式不支持"
        case .contextFailed: return "上下文创建失败：内存不足"
        case .samplerFailed: return "采样器初始化失败"
        case .batchFailed: return "批处理创建失败"
        case .decodeFailed(let c): return "推理失败（码 " + String(c) + "）"
        case .notLoaded: return "还没有加载模型"
        case .emptyPrompt: return "输入为空"
        }
    }
}
#endif