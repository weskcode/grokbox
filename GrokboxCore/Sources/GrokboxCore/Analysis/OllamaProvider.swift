import Foundation

/// A local Ollama server. The open-source path.
///
/// Talks only to loopback. The model name is configurable; the default is a
/// small Apache-2.0-licensed model that handles JSON output reliably.
public struct OllamaProvider: TextModel {
    public let name: String
    public var baseURL: URL
    public var model: String

    public static let defaultModel = "qwen2.5:3b"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    public init(baseURL: URL = defaultBaseURL, model: String = defaultModel) {
        self.baseURL = baseURL
        self.model = model
        self.name = "Ollama (\(model))"
    }

    public func availability() async -> ModelAvailability {
        guard baseURL.host == "127.0.0.1" || baseURL.host == "localhost" else {
            return .unavailable(reason: "Grokbox only talks to Ollama on this machine.")
        }
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let installed = tags.models.map(\.name)
            guard installed.contains(where: { $0 == model || $0.hasPrefix(model + ":") || model.hasPrefix($0) }) else {
                return .unavailable(reason: "Ollama is running but `\(model)` is not pulled. Run: ollama pull \(model)")
            }
            return .available
        } catch {
            return .unavailable(reason: "Ollama is not running on 127.0.0.1:11434.")
        }
    }

    public func read(_ request: ReadRequest) async throws -> ReadResult {
        let prompt = """
        \(ReaderPrompt.instructions)

        Respond with JSON only, matching exactly:
        {"summary": string, "importance": "needsYou" | "worthKnowing" | "noise", "reason": string,
         "action": "reply" | "pay" | "attend" | "review" | "decide" | "none", "due": string, "quick": boolean}

        Email:
        \(request.rendered)
        """

        let body = GenerateRequest(model: model, prompt: prompt, stream: false, format: "json")
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/generate"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        let envelope = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let parsed = try JSONDecoder().decode(ModelOutput.self, from: Data(envelope.response.utf8))

        let due = (parsed.due ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadResult(
            summary: parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            importance: Importance(rawValue: parsed.importance) ?? .worthKnowing,
            reason: parsed.reason,
            actionType: parsed.action.flatMap(ActionType.init(rawValue:)) ?? .none,
            dueHint: due.isEmpty || due.lowercased() == "none" || due.lowercased() == "null" ? nil : due,
            isQuick: parsed.quick ?? false
        )
    }

    public func categorize(_ request: CategorizeRequest) async throws -> CategorizeResult {
        let prompt = """
        \(ReaderPrompt.categorizeInstructions)

        Respond with JSON only: {"kind": "person" | "transactional" | "notification" | "newsletter" | "promotion", "reason": string}

        \(request.rendered)
        """
        let body = GenerateRequest(model: model, prompt: prompt, stream: false, format: "json")
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/generate"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        let envelope = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let parsed = try JSONDecoder().decode(CategoryOutput.self, from: Data(envelope.response.utf8))
        return CategorizeResult(category: SenderCategory(rawValue: parsed.kind) ?? .unknown, reason: parsed.reason ?? "")
    }

    private struct CategoryOutput: Decodable {
        var kind: String
        var reason: String?
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { var name: String }
        var models: [Model]
    }

    private struct GenerateRequest: Encodable {
        var model: String
        var prompt: String
        var stream: Bool
        var format: String
    }

    private struct GenerateResponse: Decodable {
        var response: String
    }

    private struct ModelOutput: Decodable {
        var summary: String
        var importance: String
        var reason: String
        var action: String?
        var due: String?
        var quick: Bool?
    }
}
