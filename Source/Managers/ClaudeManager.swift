import Foundation
import UIKit
import Combine

/// Cliente de la Messages API de Claude. Swift no tiene SDK oficial de Anthropic,
/// así que va por HTTP directo contra `/v1/messages`.
///
/// Configuración elegida para latencia, que es el requisito de este proyecto:
/// `speed: "fast"` (hasta 2.5x más tokens/s), `effort: "low"` (menos razonamiento
/// para respuestas cortas) y `max_tokens` pequeño porque la salida son 3-5 líneas
/// que tienen que caber en el waveguide.
///
/// - Important: la API key viaja dentro de la app. Cualquiera que descargue el
///   binario puede extraerla. Para la feria es aceptable; para publicar habría que
///   poner un backend intermedio que guarde la clave.
@MainActor
class ClaudeManager: ObservableObject {
    static let shared = ClaudeManager()

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "AnthropicAPIKey") }
    }
    @Published var isGenerating: Bool = false
    @Published var lastResponse: String = ""
    /// Milisegundos de la última llamada, para poder enseñar la latencia real en la demo.
    @Published var lastLatencyMs: Int = 0

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"
    private static let apiVersion = "2023-06-01"
    /// Fast mode + fallback automático si un clasificador rechaza la petición.
    private static let betaHeader = "fast-mode-2026-02-01,server-side-fallback-2026-07-01"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: "AnthropicAPIKey") ?? ""
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Petición

    /// Una consulta puntual. Sin historial: cada análisis es independiente.
    /// - Parameter imageJPEG: si viene, se envía como bloque de imagen (análisis del ambiente).
    func complete(
        prompt: String,
        system: String,
        imageJPEG: Data? = nil,
        maxTokens: Int = 400
    ) async -> String {
        guard hasKey else {
            return "Falta la API Key de Anthropic."
        }

        isGenerating = true
        let started = Date()
        defer {
            isGenerating = false
            lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imageJPEG.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "speed": "fast",
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await Self.session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return "Respuesta inválida del servidor."
            }
            guard http.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? "sin cuerpo"
                DiagnosticLogger.shared.log(.error, tag: "Claude", message: "HTTP \(http.statusCode): \(detail)")
                return "Error de la API (\(http.statusCode))."
            }

            let text = Self.extractText(from: data)
            lastResponse = text
            DiagnosticLogger.shared.log(
                .success,
                tag: "Claude",
                message: "Respuesta en \(Int(Date().timeIntervalSince(started) * 1000)) ms."
            )
            return text
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "Claude", message: "Fallo de red: \(error.localizedDescription)")
            return "Error de red: \(error.localizedDescription)"
        }
    }

    /// Extrae el texto de `content[]`. Comprueba antes `stop_reason`, porque un rechazo
    /// llega como HTTP 200 con `stop_reason: "refusal"` y contenido vacío.
    private static func extractText(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No pude leer la respuesta."
        }

        if let stop = root["stop_reason"] as? String, stop == "refusal" {
            DiagnosticLogger.shared.log(.warning, tag: "Claude", message: "La petición fue rechazada por un clasificador.")
            return "La consulta fue rechazada."
        }

        guard let blocks = root["content"] as? [[String: Any]] else {
            return "Respuesta sin contenido."
        }

        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? "Respuesta vacía." : text
    }
}
