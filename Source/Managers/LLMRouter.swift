import Foundation
import Combine

/// Proveedores disponibles. El orden de `LLMRouter.order` decide a quién se pregunta
/// primero; si uno falla (sin clave, sin crédito, error de red), se pasa al siguiente.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case gemini
    case openRouter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    var model: String {
        switch self {
        case .gemini: return "gemini-2.5-flash"
        // Modelo de otra casa a proposito: si el respaldo apuntara tambien a Gemini,
        // un fallo del propio modelo tumbaria las dos patas a la vez. Tiene vision,
        // que hace falta para leer el ambiente por foto.
        case .openRouter: return "openai/gpt-4o-mini"
        }
    }

    var defaultsKey: String {
        switch self {
        case .gemini: return "GeminiAPIKey"
        case .openRouter: return "OpenRouterAPIKey"
        }
    }

    /// Donde se recuerda si el proveedor esta encendido.
    var enabledKey: String { defaultsKey + "_enabled" }

    /// Pista para el campo de texto del panel.
    var keyHint: String {
        switch self {
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
/// Existe porque en una feria no puedes quedarte sin respuestas: si a Gemini se le acaba
/// la cuota a media demo, OpenRouter contesta sin que nadie toque nada.
@MainActor
class LLMRouter: ObservableObject {
    static let shared = LLMRouter()

    @Published var geminiKey: String { didSet { persist(geminiKey, for: .gemini) } }
    @Published var openRouterKey: String { didSet { persist(openRouterKey, for: .openRouter) } }

    /// Orden de preferencia. OpenRouter primero porque es la clave que hay hoy;
    /// preguntar antes a uno sin clave o desactivado solo gasta un intento.
    @Published var order: [LLMProvider] = [.openRouter, .gemini]

    /// Proveedores apagados a mano. Sirve para dejar fuera a uno aunque tenga
    /// clave guardada: una clave caducada haria perder un intento en cada consulta.
    @Published private var disabled: Set<LLMProvider> = [] {
        didSet {
            for provider in LLMProvider.allCases {
                UserDefaults.standard.set(!disabled.contains(provider), forKey: provider.enabledKey)
            }
        }
    }

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
        self.geminiKey = defaults.string(forKey: LLMProvider.gemini.defaultsKey) ?? ""
        self.openRouterKey = defaults.string(forKey: LLMProvider.openRouter.defaultsKey) ?? ""

        // Encendidos por defecto: solo se apagan si alguien lo pidio antes.
        self.disabled = Set(LLMProvider.allCases.filter { provider in
            defaults.object(forKey: provider.enabledKey) != nil
                && !defaults.bool(forKey: provider.enabledKey)
        })
    }

    private func persist(_ value: String, for provider: LLMProvider) {
        UserDefaults.standard.set(value, forKey: provider.defaultsKey)
    }

    func key(for provider: LLMProvider) -> String {
        switch provider {
        case .gemini: return geminiKey
        case .openRouter: return openRouterKey
        }
    }

    func hasKey(_ provider: LLMProvider) -> Bool {
        !key(for: provider).trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isEnabled(_ provider: LLMProvider) -> Bool { !disabled.contains(provider) }

    func setEnabled(_ enabled: Bool, for provider: LLMProvider) {
        if enabled { disabled.remove(provider) } else { disabled.insert(provider) }
        DiagnosticLogger.shared.log(.info, tag: "LLM",
            message: "\(provider.label) \(enabled ? "activado" : "desactivado").")
    }

    /// Proveedores que realmente pueden responder ahora mismo.
    var availableProviders: [LLMProvider] {
        order.filter { isEnabled($0) && hasKey($0) }
    }

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
            guard isEnabled(provider) else { continue }   // apagado a mano: ni se menciona
            guard hasKey(provider) else {
                failures.append("\(provider.label): sin clave")
                continue
            }

            let result: Result<String, LLMError>
            switch provider {
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
