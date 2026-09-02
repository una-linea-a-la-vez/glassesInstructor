import Foundation
import Combine

/// Proveedores disponibles. El orden de `LLMRouter.order` decide a quién se pregunta
/// primero; si uno falla (sin clave, sin crédito, error de red), se pasa al siguiente.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case claude
    case gemini
    case openRouter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    var model: String {
        switch self {
        case .claude: return "claude-opus-5"
        case .gemini: return "gemini-2.5-flash"
        case .openRouter: return "google/gemini-2.5-flash"
        }
    }

    var defaultsKey: String {
        switch self {
        case .claude: return "AnthropicAPIKey"
        case .gemini: return "GeminiAPIKey"
        case .openRouter: return "OpenRouterAPIKey"
        }
    }

    /// Pista para el campo de texto del panel.
    var keyHint: String {
        switch self {
        case .claude: return "sk-ant-..."
        case .gemini: return "AIza..."
        case .openRouter: return "sk-or-..."
        }
    }
}

enum LLMError: Error {
    case missingKey
    case http(Int, String)
    case transport(String)
    case emptyResponse
    case refused

    var readable: String {
        switch self {
        case .missingKey: return "sin clave"
        case .http(let code, _): return "HTTP \(code)"
        case .transport(let detail): return "red: \(detail)"
        case .emptyResponse: return "respuesta vacía"
        case .refused: return "rechazado"
        }
    }
}

/// Pregunta al primer proveedor con clave y, si falla, cae al siguiente.
///
/// Existe porque en una feria no puedes quedarte sin respuestas: si a Claude se le acaba
/// el crédito a media demo, Gemini u OpenRouter contestan sin que nadie toque nada.
@MainActor
class LLMRouter: ObservableObject {
    static let shared = LLMRouter()

    @Published var claudeKey: String { didSet { persist(claudeKey, for: .claude) } }
    @Published var geminiKey: String { didSet { persist(geminiKey, for: .gemini) } }
    @Published var openRouterKey: String { didSet { persist(openRouterKey, for: .openRouter) } }

    /// Orden de preferencia. Claude primero por calidad; los otros son la red de seguridad.
    @Published var order: [LLMProvider] = [.claude, .gemini, .openRouter]

    @Published var isGenerating: Bool = false
    @Published var lastProviderUsed: LLMProvider? = nil
    @Published var lastLatencyMs: Int = 0
    @Published var lastResponse: String = ""

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private init() {
        let defaults = UserDefaults.standard
        self.claudeKey = defaults.string(forKey: LLMProvider.claude.defaultsKey) ?? ""
        self.geminiKey = defaults.string(forKey: LLMProvider.gemini.defaultsKey) ?? ""
        self.openRouterKey = defaults.string(forKey: LLMProvider.openRouter.defaultsKey) ?? ""
    }

    private func persist(_ value: String, for provider: LLMProvider) {
        UserDefaults.standard.set(value, forKey: provider.defaultsKey)
    }

    func key(for provider: LLMProvider) -> String {
        switch provider {
        case .claude: return claudeKey
        case .gemini: return geminiKey
        case .openRouter: return openRouterKey
        }
    }

    func hasKey(_ provider: LLMProvider) -> Bool {
        !key(for: provider).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Proveedores que realmente pueden responder ahora mismo.
    var availableProviders: [LLMProvider] { order.filter(hasKey) }

    // MARK: - Punto de entrada

    /// Recorre `order` hasta que uno responda. Devuelve texto siempre: si todos fallan,
    /// el mensaje explica cuál falló y por qué, para no dejar el HUD mudo.
    func complete(
        prompt: String,
        system: String,
        imageJPEG: Data? = nil,
        maxTokens: Int = 400
    ) async -> String {
        isGenerating = true
        let started = Date()
        defer {
            isGenerating = false
            lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
        }

        var failures: [String] = []

        for provider in order {
            guard hasKey(provider) else {
                failures.append("\(provider.label): sin clave")
                continue
            }

            let result: Result<String, LLMError>
            switch provider {
            case .claude:
                result = await callClaude(prompt: prompt, system: system, imageJPEG: imageJPEG, maxTokens: maxTokens)
            case .gemini:
                result = await callGemini(prompt: prompt, system: system, imageJPEG: imageJPEG, maxTokens: maxTokens)
            case .openRouter:
                result = await callOpenRouter(prompt: prompt, system: system, imageJPEG: imageJPEG, maxTokens: maxTokens)
            }

            switch result {
            case .success(let text):
                lastProviderUsed = provider
                lastResponse = text
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                DiagnosticLogger.shared.log(.success, tag: "LLM", message: "\(provider.label) respondió en \(ms) ms.")
                return text

            case .failure(let error):
                failures.append("\(provider.label): \(error.readable)")
                DiagnosticLogger.shared.log(.warning, tag: "LLM", message: "\(provider.label) falló (\(error.readable)). Probando el siguiente...")
            }
        }

        lastProviderUsed = nil
        let detail = failures.joined(separator: " · ")
        DiagnosticLogger.shared.log(.error, tag: "LLM", message: "Ningún proveedor respondió. \(detail)")
        return "Sin respuesta. \(detail)"
    }

    // MARK: - Claude (Messages API)

    private func callClaude(prompt: String, system: String, imageJPEG: Data?, maxTokens: Int) async -> Result<String, LLMError> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .failure(.transport("URL inválida"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(claudeKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Fast mode baja mucho la latencia; el fallback evita pantalla vacía si un
        // clasificador rechaza la petición.
        request.setValue("fast-mode-2026-02-01,server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": LLMProvider.claude.model,
            "max_tokens": maxTokens,
            "speed": "fast",
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]

        return await send(request: request, body: body) { root in
            if let stop = root["stop_reason"] as? String, stop == "refusal" { throw LLMError.refused }
            guard let blocks = root["content"] as? [[String: Any]] else { return nil }
            return blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
    }

    // MARK: - Gemini

    private func callGemini(prompt: String, system: String, imageJPEG: Data?, maxTokens: Int) async -> Result<String, LLMError> {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMProvider.gemini.model):generateContent?key=\(geminiKey)"
        guard let url = URL(string: endpoint) else {
            return .failure(.transport("URL inválida"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = []
        if let imageJPEG {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]])
        }
        parts.append(["text": prompt])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": maxTokens]
        ]

        return await send(request: request, body: body) { root in
            guard let candidates = root["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
    }

    // MARK: - OpenRouter (formato compatible con OpenAI)

    private func callOpenRouter(prompt: String, system: String, imageJPEG: Data?, maxTokens: Int) async -> Result<String, LLMError> {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return .failure(.transport("URL inválida"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
        request.setValue("glassesinstructor", forHTTPHeaderField: "X-Title")

        var userContent: [[String: Any]] = [["type": "text", "text": prompt]]
        if let imageJPEG {
            let dataURI = "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
            userContent.append(["type": "image_url", "image_url": ["url": dataURI]])
        }

        let body: [String: Any] = [
            "model": LLMProvider.openRouter.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ]
        ]

        return await send(request: request, body: body) { root in
            guard let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    // MARK: - Transporte común

    /// Envía y deja que cada proveedor extraiga su texto. `extract` devuelve `nil` si el
    /// JSON no tiene la forma esperada; lanzar desde ahí marca un rechazo explícito.
    private func send(
        request: URLRequest,
        body: [String: Any],
        extract: @escaping ([String: Any]) throws -> String?
    ) async -> Result<String, LLMError> {
        var request = request
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.transport("no se pudo serializar"))
        }

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("respuesta inválida"))
            }
            guard http.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                return .failure(.http(http.statusCode, String(detail)))
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.emptyResponse)
            }

            let text = try extract(root)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return .failure(.emptyResponse) }
            return .success(text)
        } catch let error as LLMError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
