import Foundation

/// Credenciales locales. Deja el placeholder tal cual si prefieres introducir la API Key
/// desde la propia app (se guarda en UserDefaults); `AIManager` usa este valor sólo cuando
/// deja de ser el placeholder. Si escribes aquí tu clave real, **no la subas al repositorio**.
struct Config {
    static let geminiAPIKey = "TU_API_KEY_AQUI"
}
