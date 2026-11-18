import Foundation
import llama

/// llama.cpp 的 Swift 封装。跑本地 GGUF 模型。
final class LlamaEngine {

    struct Config {
        var contextLength: Int = 4096
        var threads: Int = 4
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int32 = 40
        var maxTokens: Int = 2048
    }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: OpaquePointer?
    private var config = Config()
    private var cancelled = false

    var isLoaded: Bool { model != nil && ctx != nil }

    // MARK: - 加载

    func load(path: String, config: Config = Config()) throws {
        unload()
        self.config = config

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0

        // llama_model_load_from_file 返回 optional
        guard let m = path.withCString({ cPath in
            llama_model_load_from_file(cPath, mparams)
        }) else {
            llama_backend_free()
            throw LlamaError.loadFailed
        }
        model = m
        vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(config.contextLength)
        cparams.n_batch = UInt32(max(512, config.contextLength))
        cparams.n_threads = Int32(config.threads)
        cparams.n_threads_batch = Int32(config.threads)

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            model = nil
            llama_backend_free()
            throw LlamaError.contextFailed
        }
        ctx = c
        llama_set_n_threads(c, Int32(config.threads), Int32(config.threads))

        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            throw LlamaError.samplerFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(config.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(config.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
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
        llama_backend_free()
    }

    func cancel() { cancelled = true }

    // MARK: - 生成

    func generate(prompt: String, onToken: @escaping (String) -> Void) throws -> String {
        guard let ctx, let vocab, let sampler else { throw LlamaError.notLoaded }
        cancelled = false

        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { throw LlamaError.emptyPrompt }

        let nCtx = Int(llama_n_ctx(ctx))
        let budget = max(256, Int(config.maxTokens))
        if tokens.count >= nCtx - budget {
            let keep = max(1, nCtx - budget - 16)
            tokens = Array(tokens.suffix(keep))
        }

        // 预填 prompt
        guard let batch = llama_batch_ext_init(ctx) else { throw LlamaError.batchFailed }
        for t in tokens {
            _ = llama_batch_ext_add_token(batch, 0, t)
        }
        let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
        llama_batch_ext_free(batch)
        if rc != 0 { throw LlamaError.decodeFailed(rc) }

        // 逐 token
        var output = ""
        var generated = 0

        while generated < config.maxTokens && !cancelled {
            let id = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, id)

            if llama_vocab_is_eog(vocab, id) { break }

            if let piece = tokenToPiece(id), !piece.isEmpty {
                output += piece
                onToken(piece)
            }

            guard let nb = llama_batch_ext_init(ctx) else { break }
            _ = llama_batch_ext_add_token(nb, 0, id)
            let r = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, nb)
            llama_batch_ext_free(nb)
            if r != 0 { break }

            generated += 1
        }

        return output
    }

    // MARK: - 工具

    /// 用 Swift String 的 utf8 C 字符串指针，避免 [CChar] 桥接歧义
    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        return text.withCString { cstr in
            let byteCount = Int32(strlen(cstr))

            // 先探测需要多少 token
            let probe = llama_tokenize(vocab, cstr, byteCount, nil, 0, addSpecial, true)
            guard probe < 0 else { return [] }
            let capacity = Int(-probe)

            var buffer = [llama_token](repeating: 0, count: capacity)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                llama_tokenize(vocab, cstr, byteCount, ptr.baseAddress, Int32(capacity), addSpecial, true)
            }
            guard n > 0 else { return [] }
            return Array(buffer.prefix(Int(n)))
        }
    }

    private func tokenToPiece(_ token: llama_token) -> String? {
        guard let vocab else { return nil }
        var buffer = [CChar](repeating: 0, count: 512)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, false)
        }
        guard n > 0 else { return nil }
        return String(cString: buffer)
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
        case .loadFailed: return "模型加载失败，文件可能损坏或格式不支持"
        case .contextFailed: return "上下文创建失败，模型可能太大"
        case .samplerFailed: return "采样器初始化失败"
        case .batchFailed: return "批处理创建失败"
        case .decodeFailed(let c): return "推理失败（码 \(c)）"
        case .notLoaded: return "还没有加载模型"
        case .emptyPrompt: return "输入为空"
        }
    }
}
