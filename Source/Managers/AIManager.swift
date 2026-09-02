import Foundation

@MainActor
class AIManager: ObservableObject {
    static let shared = AIManager()
    
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "GeminiAPIKey")
        }
    }
    
    @Published var systemPrompt: String = "Eres un asistente virtual encarnado en un tierno avatar de lobo chibi llamado Shiki. Eres amigable, inteligente y respondes de forma concisa (máximo 2 oraciones) para que tus respuestas quepan bien en las gafas HUD."
    
    // Conversation history
    struct Message: Codable {
        let role: String // "user" or "model"
        let parts: [Part]
        
        struct Part: Codable {
            let text: String
        }
    }
    
    @Published var history: [Message] = []
    @Published var isGenerating = false
    @Published var lastResponse: String = ""
    
    // Contexto descargado del stand a través del QR
    @Published var standContext: String? = nil
    
    private init() {
        // Lee la API Key desde el archivo Config.swift (ignorado en Git)
        let key = Config.geminiAPIKey
        
        if !key.isEmpty && key != "TU_API_KEY_AQUI" {
            self.apiKey = key
        } else {
            self.apiKey = UserDefaults.standard.string(forKey: "GeminiAPIKey") ?? ""
        }
    }
    
    func getActiveSystemPrompt() -> String {
        var basePrompt = systemPrompt
        
        // Si hay un contexto de repositorio cargado de la feria de ciencias, lo agregamos de manera estructurada al prompt
        if let standContext = standContext {
            basePrompt += "\n\n[CONTEXTO DEL REPOSITORIO DEL STAND ACTIVO]\n\(standContext)\n\n[INSTRUCCIÓN IMPORTANTE]: Eres el guía científico de este stand. Utiliza la información anterior para responder de forma precisa, entusiasta y muy concisa (máximo 60 palabras, 4 líneas en total, sin markdown complejo como negritas o títulos). Si la pregunta del visitante no se relaciona con este stand, explícale de forma amigable y concéntrate en el proyecto del stand."
        }
        return basePrompt
    }
    
    /// Descarga el README.md de un repositorio público de GitHub usando su API raw
    func fetchRepositoryContext(url: String) async throws -> String {
        guard let githubURL = URL(string: url),
              githubURL.host?.contains("github.com") == true else {
            throw NSError(domain: "AIManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "URL no es un repositorio de GitHub válido."])
        }
        
        let pathComponents = githubURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            throw NSError(domain: "AIManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Formato de repositorio GitHub incompleto."])
        }
        
        let owner = pathComponents[0]
        let repo = pathComponents[1]
        
        let apiURLString = "https://api.github.com/repos/\(owner)/\(repo)/readme"
        guard let apiURL = URL(string: apiURLString) else {
            throw NSError(domain: "AIManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "No se pudo generar la dirección de la API."])
        }
        
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept") // Pide el contenido raw directamente
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AIManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Error en la respuesta del servidor."])
        }
        
        if httpResponse.statusCode == 404 {
            throw NSError(domain: "AIManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "El repositorio es privado o no existe."])
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "AIManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Error de servidor (\(httpResponse.statusCode))."])
        }
        
        guard let readmeContent = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AIManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "No se pudo leer el archivo README."])
        }
        
        let trimmed = readmeContent.prefix(2500)
        return """
        [Proyecto]: \(repo) (por \(owner))
        [Detalles/Readme]:
        \(trimmed)
        """
    }
    
    /// Consulta puntual con su propio system prompt. No toca `history`, para que una
    /// auditoría no contamine la conversación del avatar (ni al revés).
    func generateOneShot(prompt: String, systemPrompt: String) async -> String {
        guard !apiKey.isEmpty else {
            return "Falta la API Key de Gemini."
        }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return "URL de API inválida." }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        struct OneShotPayload: Codable {
            let contents: [Message]
            let systemInstruction: SystemInstruction
            struct SystemInstruction: Codable { let parts: [Message.Part] }
        }
        
        let payload = OneShotPayload(
            contents: [Message(role: "user", parts: [Message.Part(text: prompt)])],
            systemInstruction: .init(parts: [Message.Part(text: systemPrompt)])
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "sin cuerpo"
                DiagnosticLogger.shared.log(.error, tag: "AI", message: "Gemini respondió \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body)")
                return "Error al comunicarse con la IA."
            }
            
            struct GeminiResponse: Codable {
                let candidates: [Candidate]?
                struct Candidate: Codable {
                    let content: Content?
                    struct Content: Codable {
                        let parts: [Part]?
                        struct Part: Codable { let text: String? }
                    }
                }
            }
            
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
                return "No recibí respuesta de la IA."
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "AI", message: "Fallo en generateOneShot: \(error.localizedDescription)")
            return "Error de red: \(error.localizedDescription)"
        }
    }
    
    func clearHistory() {
        self.history.removeAll()
        self.lastResponse = ""
    }
    
    func generateResponse(userPrompt: String) async -> String {
        guard !apiKey.isEmpty else {
            return "Por favor, ingresa tu API Key de Gemini en la app."
        }
        
        isGenerating = true
        defer { isGenerating = false }
        
        // Append user message to history
        let userMsg = Message(role: "user", parts: [Message.Part(text: userPrompt)])
        history.append(userMsg)
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return "URL de API inválida."
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Build payload
        struct Payload: Codable {
            let contents: [Message]
            let systemInstruction: SystemInstruction?
            
            struct SystemInstruction: Codable {
                let parts: [Message.Part]
            }
        }
        
        let activeSystemPrompt = getActiveSystemPrompt()
        
        let payload = Payload(
            contents: history,
            systemInstruction: Payload.SystemInstruction(parts: [Message.Part(text: activeSystemPrompt)])
        )
        
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorStr = String(data: data, encoding: .utf8) ?? "Error desconocido"
                DiagnosticLogger.shared.log(.error, tag: "AI", message: "Error de API Gemini: \(errorStr)")
                return "Error al comunicarse con la IA."
            }
            
            // Parse response
            struct GeminiResponse: Codable {
                let candidates: [Candidate]?
                
                struct Candidate: Codable {
                    let content: Content?
                    
                    struct Content: Codable {
                        let parts: [Part]?
                        
                        struct Part: Codable {
                            let text: String?
                        }
                    }
                }
            }
            
            let decoder = JSONDecoder()
            let decodedResponse = try decoder.decode(GeminiResponse.self, from: data)
            
            if let text = decodedResponse.candidates?.first?.content?.parts?.first?.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Add model message to history
                let modelMsg = Message(role: "model", parts: [Message.Part(text: trimmed)])
                history.append(modelMsg)
                
                self.lastResponse = trimmed
                return trimmed
            } else {
                return "No recibí respuesta de la IA."
            }
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "AI", message: "Fallo en generateResponse: \(error.localizedDescription)")
            return "Error de red: \(error.localizedDescription)"
        }
    }
}
