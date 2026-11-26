#if canImport(llama)
import Foundation
import llama

enum LocalSubtitleEngine {
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private static let grammar = #"""
    root ::= "{" ws "\"changes\"" ws ":" ws "[" ws change (ws "," ws change)* ws "]" ws "}"
    change ::= "{" ws "\"number\"" ws ":" ws [1-9] [0-9]? ws "," ws "\"replacement\"" ws ":" ws string ws "}"
    string ::= "\"" char* "\""
    char ::= [^"\\\x00-\x1f] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n\r]?
    """#

    static func corrections(in cues: [SubtitleCue], modelURL: URL,
                            progress: @MainActor @Sendable (Int) -> Void) async throws -> [SubtitleCorrection] {
        _ = backend
        var modelOptions = llama_model_default_params()
        modelOptions.n_gpu_layers = 0
        var noOffloadDevice: ggml_backend_dev_t? = nil
        let loaded = withUnsafeMutablePointer(to: &noOffloadDevice) { devices in
            modelOptions.devices = devices
            return modelURL.path.withCString { llama_model_load_from_file($0, modelOptions) }
        }
        guard let model = loaded else {
            throw RecorderError.message("无法打开简录的本地校对模型。")
        }
        defer { llama_model_free(model) }
        guard let vocabulary = llama_model_get_vocab(model) else {
            throw RecorderError.message("无法打开简录的本地校对模型。")
        }
        var result: [SubtitleCorrection] = []
        var completed = 0
        for batch in SubtitleProofreading.batches(cues) {
            try Task.checkCancellation()
            let lines = try SubtitleProofreading.prompt(for: batch).replacingOccurrences(of: "<", with: "\\u003c")
            let prompt = """
            <|im_start|>system
            \(SubtitleProofreading.instructions)<|im_end|>
            <|im_start|>user
            \(lines)<|im_end|>
            <|im_start|>assistant

            """
            let changes = try SubtitleProofreading.decode(generate(prompt, using: model, vocabulary: vocabulary))
            result += SubtitleProofreading.validated(changes, for: batch)
            completed += batch.count
            await progress(completed)
        }
        try Task.checkCancellation()
        return result
    }

    private static func generate(_ prompt: String, using model: OpaquePointer, vocabulary: OpaquePointer) throws -> String {
        var tokens = try tokenize(prompt, vocabulary: vocabulary)
        var options = llama_context_default_params()
        options.n_ctx = 4_096
        options.n_batch = 4_096
        options.n_threads = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        options.n_threads_batch = options.n_threads
        options.offload_kqv = false
        guard let context = llama_init_from_model(model, options) else {
            throw RecorderError.message("无法启动本地字幕校对。")
        }
        defer { llama_free(context) }
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw RecorderError.message("无法启动本地字幕校对。")
        }
        defer { llama_sampler_free(sampler) }
        guard let constrained = llama_sampler_init_grammar(vocabulary, grammar, "root") else {
            throw RecorderError.message("无法准备校对结果的格式。")
        }
        llama_sampler_chain_add(sampler, constrained)
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        guard tokens.count <= 3_072, decodeTokens(&tokens, context: context) else {
            throw RecorderError.message("有一条字幕太长。请分成较短的字幕后重试。")
        }

        var bytes: [UInt8] = []
        var piece = [Int8](repeating: 0, count: 512)
        for _ in 0..<1_024 {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            let length = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
            guard length > 0 else { throw RecorderError.message("本地模型未能生成完整的校对结果。") }
            bytes.append(contentsOf: piece.prefix(Int(length)).map(UInt8.init(bitPattern:)))
            var next = [token]
            guard decodeTokens(&next, context: context) else {
                throw RecorderError.message("本地模型未能生成完整的校对结果。")
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func tokenize(_ text: String, vocabulary: OpaquePointer) throws -> [llama_token] {
        try text.withCString { characters in
            let length = Int32(text.utf8.count)
            let count = -llama_tokenize(vocabulary, characters, length, nil, 0, false, true)
            guard count > 0 else { throw RecorderError.message("无法读取这些字幕。") }
            var tokens = [llama_token](repeating: 0, count: Int(count))
            guard llama_tokenize(vocabulary, characters, length, &tokens, count, false, true) == count else {
                throw RecorderError.message("无法读取这些字幕。")
            }
            return tokens
        }
    }

    private static func decodeTokens(_ tokens: inout [llama_token], context: OpaquePointer) -> Bool {
        tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))) == 0
        }
    }
}
#endif
