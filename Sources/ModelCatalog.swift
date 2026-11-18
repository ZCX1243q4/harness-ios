import Foundation

/// 从各家接口自动拉取可用模型列表
enum ModelCatalog {

    struct Entry: Identifiable, Hashable {
        let id: String          // 请求时要填的模型名
        let display: String     // 列表里显示的名字
        let detail: String      // 副标题：上下文长度等
    }

    enum FetchError: Error {
        case message(String)

        var text: String {
            switch self {
            case .message(let m): return m
            }
        }
    }

    /// 拉取失败时也要能手动输入，所以返回 Result 而不是抛
    static func fetch(
        kind: ProviderKind,
        baseURL: String,
        apiKey: String,
        extraHeaders: String
    ) async -> Result<[Entry], FetchError> {
        guard !apiKey.isEmpty else { return .failure(.message("先填 API Key")) }

        var headers = ["Content-Type": "application/json"]
        for line in extraHeaders.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }

        switch kind {
        case .openAI:
            headers["Authorization"] = "Bearer \(apiKey)"
        case .anthropic:
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case .gemini:
            break
        case .onDevice, .localGGUF:
            return .failure(.message("本地模型不需要拉取列表"))
        }

        guard let url = buildListURL(kind: kind, baseURL: baseURL, apiKey: apiKey) else {
            return .failure(.message("Base URL 无效"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(.message("HTTP \(http.statusCode)\n\(body.prefix(300))"))
            }
            let entries = parse(data, kind: kind)
            if entries.isEmpty { return .failure(.message("接口没返回任何模型")) }
            return .success(entries)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    private static func buildListURL(kind: ProviderKind, baseURL: String, apiKey: String) -> URL? {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }

        switch kind {
        case .openAI:
            // 兼容 /v1 结尾、也兼容直接给到根
            if b.hasSuffix("/models") { return URL(string: b) }
            return URL(string: b + "/models")
        case .anthropic:
            if b.hasSuffix("/models") { return URL(string: b) }
            return URL(string: b + "/models")
        case .gemini:
            var comps = URLComponents(string: b + "/models")
            comps?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            return comps?.url

        case .onDevice, .localGGUF:
            return nil
        }
    }

    private static func parse(_ data: Data, kind: ProviderKind) -> [Entry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        switch kind {
        case .openAI:
            guard let list = obj["data"] as? [[String: Any]] else { return [] }
            return list.compactMap { item -> Entry? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                var detail = ""
                if let ctx = item["context_length"] as? Int { detail = "上下文 \(ctx)" }
                else if let owned = item["owned_by"] as? String { detail = owned }
                return Entry(id: id, display: id, detail: detail)
            }
            .sorted { $0.id < $1.id }

        case .anthropic:
            guard let list = obj["data"] as? [[String: Any]] else { return [] }
            return list.compactMap { item -> Entry? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let name = (item["display_name"] as? String) ?? id
                return Entry(id: id, display: name, detail: id)
            }

        case .gemini:
            guard let list = obj["models"] as? [[String: Any]] else { return [] }
            return list.compactMap { item -> Entry? in
                guard let raw = item["name"] as? String else { return nil }
                // "models/gemini-2.0-flash" -> "gemini-2.0-flash"
                let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
                let supported = (item["supportedGenerationMethods"] as? [String]) ?? []
                guard supported.isEmpty || supported.contains("generateContent") else { return nil }
                let name = (item["displayName"] as? String) ?? id
                var detail = ""
                if let limit = item["inputTokenLimit"] as? Int { detail = "输入 \(limit)" }
                return Entry(id: id, display: name, detail: detail)
            }
            .sorted { $0.id < $1.id }

        case .onDevice, .localGGUF:
            return []
        }
    }
}
