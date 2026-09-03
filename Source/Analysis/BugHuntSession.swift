import SwiftUI
import Combine

/// Tipo de fallo que se predice.
enum BugKind: String, CaseIterable, Identifiable {
    case visual
    case logic
    case functional
    case vibecoded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visual:     return "Vista"
        case .logic:      return "Lógica"
        case .functional: return "Función"
        case .vibecoded:  return "Vibecodeado"
        }
    }

    var icon: String {
        switch self {
        case .visual:     return "eye.trianglebadge.exclamationmark"
        case .logic:      return "arrow.triangle.branch"
        case .functional: return "bolt.trianglebadge.exclamationmark"
        case .vibecoded:  return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .visual:     return .purple
        case .logic:      return .orange
        case .functional: return .red
        case .vibecoded:  return .pink
        }
    }

    /// Comprobacion de reserva cuando el modelo no devuelve la suya.
    ///
    /// Antes todas caian en la misma frase generica y la pantalla se llenaba de
    /// "pidele que lo demuestre en vivo" repetido, que no dice como comprobar nada.
    /// Al menos que cada tipo sugiera algo propio del tipo.
    var defaultCheck: String {
        switch self {
        case .visual:
            return "Gíralo a horizontal y mira si algo se sale o se solapa."
        case .logic:
            return "Pulsa enviar dos veces seguidas y mira qué pasa."
        case .functional:
            return "Pon el teléfono en modo avión y recarga delante de él."
        case .vibecoded:
            return "Pídele que te explique por qué eligió eso y no la alternativa."
        }
    }

    static func parse(_ raw: String) -> BugKind {
        let value = raw.lowercased()
        if value.contains("vista") || value.contains("visual") { return .visual }
        if value.contains("logic") || value.contains("lógic") { return .logic }
        if value.contains("vibe") { return .vibecoded }
        return .functional
    }
}

/// Un fallo probable, con su porqué y su forma de comprobarlo.
/// Lo que se comprobo en el sitio.
enum BugVerdict: String {
    case pending
    case confirmed   // se reprodujo
    case refuted     // no ocurre

    var label: String {
        switch self {
        case .pending:   return "Sin comprobar"
        case .confirmed: return "Falla"
        case .refuted:   return "Correcto"
        }
    }
}

struct PredictedBug: Identifiable {
    let id = UUID()
    /// Resultado de la comprobacion delante del stand.
    var verdict: BugVerdict = .pending
    let kind: BugKind
    /// Qué se rompería, en cristiano.
    let symptom: String
    /// El dato medido que lo hace probable.
    let evidence: String
    /// Cómo verlo en diez segundos, delante del stand.
    let howToCheck: String
}

/// Predice dónde se rompe el proyecto antes de tocarlo.
///
/// Los otros módulos miran lo que ya se midió; éste extrapola. Por eso cada
/// prediccion viene con su forma de comprobarla en el sitio: una prediccion que no
/// puedes verificar delante del alumno no es un hallazgo, es una acusacion, y si
/// falla te deja a ti en evidencia y no a su proyecto.
@MainActor
class BugHuntSession: ObservableObject {
    static let shared = BugHuntSession()

    @Published var bugs: [PredictedBug] = []
    @Published var isRunning: Bool = false
    @Published var statusLine: String = "Sin analizar"

    private var cache: [String: [PredictedBug]] = [:]

    private init() {}

    private var cacheKey: String? {
        ProjectAuditAgent.shared.analysis?.url.absoluteString
    }

    func run(force: Bool = false) async {
        guard ProjectAuditAgent.shared.analysis != nil else {
            statusLine = "Escanea un proyecto primero"
            return
        }

        if !force, let key = cacheKey, let cached = cache[key], !cached.isEmpty {
            bugs = cached
            statusLine = "\(cached.count) fallos probables"
            DiagnosticLogger.shared.log(.info, tag: "Bugs",
                message: "\(cached.count) predicciones de caché, sin gastar API.")
            return
        }

        isRunning = true
        bugs = []
        statusLine = "Buscando por dónde se rompe..."

        let response = await LLMRouter.shared.complete(
            prompt: ProjectAuditAgent.shared.evidenceSummary,
            system: Self.systemPrompt,
            maxTokens: 600
        )

        bugs = Self.parse(response)
        if let key = cacheKey, !bugs.isEmpty { cache[key] = bugs }

        isRunning = false
        statusLine = bugs.isEmpty ? "Sin fallos claros" : "\(bugs.count) fallos probables"
        DiagnosticLogger.shared.log(.success, tag: "Bugs",
            message: "\(bugs.count) predicciones en \(LLMRouter.shared.lastLatencyMs) ms.")

        await showOnGlasses()
    }

    func setVerdict(_ verdict: BugVerdict, at index: Int) {
        guard bugs.indices.contains(index) else { return }
        bugs[index].verdict = verdict
        DiagnosticLogger.shared.log(.info, tag: "Bugs",
            message: "\(bugs[index].kind.label): \(verdict.label).")
    }

    /// Cuantos se confirmaron, para el resumen.
    var confirmedCount: Int { bugs.filter { $0.verdict == .confirmed }.count }

    /// Lleva al teleprompter la forma de comprobar cada fallo: es lo que se dice
    /// en voz alta delante del stand.
    func showOnGlasses() async {
        guard !bugs.isEmpty else { return }

        // El teleprompter devuelve el veredicto de la linea que se esta leyendo,
        // para poder marcar bien o mal desde las gafas sin sacar el telefono.
        Teleprompter.shared.onVerdict = { [weak self] index, passed in
            self?.setVerdict(passed ? .refuted : .confirmed, at: index)
        }

        await Teleprompter.shared.present(bugs.map(\.howToCheck),
                                          title: "COMPROBAR",
                                          kind: .challenges,
                                          support: bugs.map(\.symptom),
                                          autoAdvance: true)
    }

    private static let systemPrompt = [
        "Predices donde se rompe un proyecto web estudiantil, a partir de evidencia",
        "medida de su sitio y, si la hay, de su repositorio.",
        "",
        "Cuatro tipos: VISTA (lo que se ve mal o se rompe al redimensionar),",
        "LOGICA (casos borde, doble envio, estados vacios), FUNCION (que deja de",
        "funcionar si algo falla) y VIBECODEADO (señales de codigo generado sin",
        "entenderlo: andamiaje sin tocar, textos por defecto, historial volcado).",
        "",
        "Reglas:",
        "- Cada prediccion se apoya en un dato concreto de la evidencia.",
        "- COMPROBAR es OBLIGATORIO y distinto en cada bloque. Nunca lo dejes vacio",
        "  ni repitas la misma comprobacion dos veces.",
        "- Cada una se hace en diez segundos",
        "  delante del stand, no una auditoria.",
        "- Si la evidencia no da para predecir algo, devuelve menos. No inventes.",
        "",
        "Devuelve entre 3 y 5 bloques con este formato EXACTO, sin markdown:",
        "TIPO: <VISTA|LOGICA|FUNCION|VIBECODEADO>",
        "FALLO: <que se rompería, una linea>",
        "DATO: <la medicion que lo hace probable, una linea>",
        "COMPROBAR: <como verlo en diez segundos, una linea>",
        "---",
        "",
        "Maximo 90 caracteres por linea."
    ].joined(separator: "\n")

    /// Trocea la respuesta; si el modelo ignora el formato, cae a un modo degradado
    /// en vez de devolver nada.
    static func parse(_ text: String) -> [PredictedBug] {
        var result: [PredictedBug] = []

        for block in text.components(separatedBy: "---") {
            var kind = "", symptom = "", evidence = "", check = ""
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("TIPO:") { kind = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                else if trimmed.hasPrefix("FALLO:") { symptom = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if trimmed.hasPrefix("DATO:") { evidence = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                else if trimmed.hasPrefix("COMPROBAR:") { check = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
            }
            if !symptom.isEmpty {
                result.append(PredictedBug(kind: BugKind.parse(kind),
                                           symptom: symptom,
                                           evidence: evidence,
                                           howToCheck: check.isEmpty
                                               ? BugKind.parse(kind).defaultCheck
                                               : check))
            }
        }

        guard result.isEmpty else { return result }

        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 }
            .prefix(4)
            .map { PredictedBug(kind: .functional, symptom: $0, evidence: "",
                                howToCheck: BugKind.functional.defaultCheck) }
    }
}
