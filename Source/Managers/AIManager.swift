import Foundation

/// Estado del stand escaneado y descarga de su README.
///
/// Ya NO habla con ningun modelo: todas las consultas pasan por `LLMRouter`, que es
/// quien gestiona el respaldo entre Gemini y OpenRouter. Dejar aqui una ruta
/// HTTP propia invitaria a saltarse ese respaldo.
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
    func clearHistory() {
        self.history.removeAll()
        self.lastResponse = ""
    }
}
