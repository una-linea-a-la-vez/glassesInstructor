import Foundation
import UIKit
import Combine
import FoundationModels

/// Proveedores disponibles. El orden de `LLMRouter.order` decide a quién se pregunta
/// primero; si uno falla (sin clave, sin crédito, error de red), se pasa al siguiente.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    /// El modelo que Apple trae en el propio telefono. Sin red, sin clave y sin
    /// coste. Va primero: en la feria la red es el eslabon que falla.
    case appleOnDevice
    case gemini
    case openRouter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleOnDevice: return "Apple (en el teléfono)"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    var model: String {
        switch self {
        case .appleOnDevice: return "system"
        case .gemini: return "gemini-2.5-flash"
        // Modelo de otra casa a proposito: si el respaldo apuntara tambien a Gemini,
        // un fallo del propio modelo tumbaria las dos patas a la vez. Tiene vision,
        // que hace falta para leer el ambiente por foto.
        case .openRouter: return "openai/gpt-4o-mini"
        }
    }

    var defaultsKey: String {
        switch self {
        case .appleOnDevice: return "AppleOnDeviceUnused"
        case .gemini: return "GeminiAPIKey"
        case .openRouter: return "OpenRouterAPIKey"
        }
    }

    /// El modelo local no lleva clave: la pide el sistema, no nosotros.
    var requiresKey: Bool { self != .appleOnDevice }

    /// Solo los remotos aceptan imagen. El modelo de Apple es de texto, asi que
    /// para leer el ambiente por foto hay que saltarselo en vez de fallar.
    var supportsImages: Bool { self != .appleOnDevice }

    /// Donde se recuerda si el proveedor esta encendido.
    var enabledKey: String { defaultsKey + "_enabled" }

    /// Pista para el campo de texto del panel.
    var keyHint: String {
        switch self {
        case .appleOnDevice: return ""
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
    @Published var order: [LLMProvider] = [.appleOnDevice, .openRouter, .gemini]

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
        let raw: String
        switch provider {
        case .appleOnDevice: raw = "local"   // no hay clave que guardar
        case .gemini: raw = geminiKey
        case .openRouter: raw = openRouterKey
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Reduce la foto antes de mandarla.
    ///
    /// Una captura de las gafas viene a resolucion completa; en base64 son varios
    /// megas que subir antes de que el modelo empiece siquiera a mirar. Eso explica
    /// los 20 s de la lectura del entorno, y probablemente tambien el error TLS: una
    /// subida larga sobre un enlace inestable se corta a media conexion. Para
    /// describir una escena o leer un cartel, 1024 px de lado largo sobran.
    nonisolated private static func shrink(_ data: Data, maxSide: CGFloat = 1024, quality: CGFloat = 0.6) -> Data {
        guard let image = UIImage(data: data) else { return data }

        let side = max(image.size.width, image.size.height)
        guard side > maxSide else {
            return image.jpegData(compressionQuality: quality) ?? data
        }

        let scale = maxSide / side
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.jpegData(compressionQuality: quality) ?? data
    }

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

        // Una sola vez, no por proveedor: si hay que caer al siguiente no tiene
        // sentido volver a redimensionar la misma foto.
        let payloadImage: Data? = await Task.detached(priority: .userInitiated) { [imageJPEG] in
            imageJPEG.map { Self.shrink($0) }
        }.value

        if let original = imageJPEG, let reduced = payloadImage {
            DiagnosticLogger.shared.log(.info, tag: "LLM",
                message: "Imagen: \(original.count / 1024) KB -> \(reduced.count / 1024) KB.")
        }

        var failures: [String] = []

        for provider in order {
            guard isEnabled(provider) else { continue }   // apagado a mano: ni se menciona
            guard hasKey(provider) else {
                failures.append("\(provider.label): sin clave")
                continue
            }

            warnIfKeyLooksWrong(provider)

            let result: Result<String, LLMError>
            // De texto: si hay foto, este no puede y cede el turno.
            if !provider.supportsImages, payloadImage != nil {
                failures.append("\(provider.label): no lee imágenes")
                continue
            }

            switch provider {
            case .appleOnDevice:
                result = await callAppleOnDevice(prompt: prompt, system: system, maxTokens: maxTokens)
            case .gemini:
                result = await callGemini(prompt: prompt, system: system, imageJPEG: payloadImage, maxTokens: maxTokens)
            case .openRouter:
                result = await callOpenRouter(prompt: prompt, system: system, imageJPEG: payloadImage, maxTokens: maxTokens)
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

    /// Un 401 de OpenRouter dice "Missing Authentication header" tanto si falta la
    /// cabecera como si la clave esta mal, asi que conviene avisar por adelantado.
    private func warnIfKeyLooksWrong(_ provider: LLMProvider) {
        guard provider.requiresKey else { return }
        let value = key(for: provider)
        let expected: String
        switch provider {
        case .openRouter: expected = "sk-or-"
        case .gemini: expected = "AIza"
        case .appleOnDevice: return
        }
        guard !value.hasPrefix(expected) else { return }
        DiagnosticLogger.shared.log(.warning, tag: "LLM",
            message: "La clave de \(provider.label) no empieza por \(expected). Comprueba que sea la correcta y que se pego completa.")
    }

    // MARK: - Diagnostico

    /// Lanza una peticion minima contra un proveedor y devuelve el resultado en
    /// crudo: codigo HTTP y cuerpo recortado.
    ///
    /// Existe porque "no jala" no es diagnosticable. Un 401 de OpenRouter dice
    /// "Missing Authentication header" tanto si la clave esta mal como si llega
    /// malformada, y un 402 (sin credito) se parece a un fallo de red desde fuera.
    /// Esto lo pone en pantalla sin tener que leer logs.
    func testProvider(_ provider: LLMProvider) async -> String {
        let value = key(for: provider)
        guard !value.isEmpty else { return "Sin clave." }

        let result: Result<String, LLMError>
        switch provider {
        case .appleOnDevice:
            result = await callAppleOnDevice(prompt: "Responde solo: ok",
                                             system: "Responde en una palabra.", maxTokens: 10)
        case .gemini:
            result = await callGemini(prompt: "Responde solo: ok", system: "Responde en una palabra.",
                                      imageJPEG: nil, maxTokens: 10)
        case .openRouter:
            result = await callOpenRouter(prompt: "Responde solo: ok", system: "Responde en una palabra.",
                                          imageJPEG: nil, maxTokens: 10)
        }

        switch result {
        case .success(let text):
            return "OK · respondio \"\(text.prefix(40))\" en \(lastLatencyMs) ms"
        case .failure(let error):
            switch error {
            case .http(let code, let body):
                let hint: String
                switch code {
                case 401: hint = "Clave rechazada. Comprueba que este completa y sin espacios."
                case 402: hint = "Sin credito en la cuenta."
                case 404: hint = "El modelo no existe para esta cuenta."
                case 429: hint = "Demasiadas peticiones. Espera un momento."
                default:  hint = "Revisa la cuenta del proveedor."
                }
                return "HTTP \(code) · \(hint)\n\(body.prefix(160))"
            default:
                return "Fallo: \(error.readable)"
            }
        }
    }

    // MARK: - Apple, en el propio telefono

    /// Responde con el modelo que Apple trae en el sistema.
    ///
    /// No pasa por la red, asi que es el unico que sigue funcionando cuando el
    /// recinto no da internet. A cambio es de texto y mas pequeño que los remotos:
    /// sirve de sobra para redactar preguntas sobre evidencia ya medida, que es
    /// justo lo que aqui se le pide.
    private func callAppleOnDevice(prompt: String, system: String, maxTokens: Int) async -> Result<String, LLMError> {
        guard #available(iOS 26.0, *) else {
            return .failure(.transport("requiere iOS 26"))
        }

        // El motivo importa: no es lo mismo un telefono que no puede que uno al que
        // solo le falta activar Apple Intelligence o terminar de bajar el modelo.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            let detail: String
            switch reason {
            case .deviceNotEligible:          detail = "el dispositivo no lo soporta"
            case .appleIntelligenceNotEnabled: detail = "Apple Intelligence está desactivado en Ajustes"
            case .modelNotReady:              detail = "el modelo aún se está descargando"
            @unknown default:                 detail = "no disponible"
            }
            return .failure(.transport(detail))
        }

        do {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.emptyResponse) : .success(text)
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { return .failure(.refused) }
            return .failure(.transport(error.localizedDescription))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Gemini

    private func callGemini(prompt: String, system: String, imageJPEG: Data?, maxTokens: Int) async -> Result<String, LLMError> {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMProvider.gemini.model):generateContent?key=\(key(for: .gemini))"
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
        request.setValue("Bearer \(key(for: .openRouter))", forHTTPHeaderField: "Authorization")
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
