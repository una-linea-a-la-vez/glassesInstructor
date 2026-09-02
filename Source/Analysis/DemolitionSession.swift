import Foundation
import Combine

/// Una grieta entre lo que el alumno sostiene y lo que el sitio demuestra.
///
/// Siempre lleva las tres piezas juntas a propósito. Una acusación sin el dato que
/// la sostiene es una opinión, y el alumno la puede rebatir; con el dato delante,
/// la conversación deja de ser sobre quién tiene razón.
struct Challenge: Identifiable {
    let id = UUID()
    /// Lo que dijo, o lo que el proyecto aparenta.
    let claim: String
    /// El dato medido que no encaja con esa afirmación.
    let evidence: String
    /// La repregunta que no se puede contestar de memoria.
    let followUp: String
}

/// Módulo "tronar el proyecto": busca dónde se cae la historia.
///
/// No busca humillar a nadie ni sirve para eso: busca separar a quien entendió lo
/// que hizo de quien no. La diferencia práctica es que aquí toda objeción va atada
/// a una medición del sitio, y la salida es una repregunta, no un veredicto. Si el
/// alumno la contesta bien, el proyecto queda mejor parado que antes.
@MainActor
class DemolitionSession: ObservableObject {
    static let shared = DemolitionSession()

    @Published var challenges: [Challenge] = []
    @Published var isRunning: Bool = false
    @Published var cursor: Int = 0
    @Published var statusLine: String = "Sin analizar"

    private init() {}

    var current: Challenge? {
        guard challenges.indices.contains(cursor) else { return nil }
        return challenges[cursor]
    }

    func advance() {
        guard !challenges.isEmpty else { return }
        cursor = (cursor + 1) % challenges.count
        statusLine = "Grieta \(cursor + 1)/\(challenges.count)"
        Task { await speakCurrent() }
    }

    /// Cruza la evidencia medida con lo que el alumno ya respondió.
    func run() async {
        guard ProjectAuditAgent.shared.analysis != nil else {
            statusLine = "Escanea un proyecto primero"
            return
        }

        isRunning = true
        challenges = []
        cursor = 0
        statusLine = "Buscando grietas..."
        await HUDGridManager.shared.renderCurrentState(force: true)

        let answered = QuestionSession.shared.questions.filter(\.wasAnswered)
        let transcript = answered.isEmpty
            ? "(Todavía no ha respondido nada.)"
            : answered.map { "P: \($0.question)\nR: \($0.answer)" }.joined(separator: "\n\n")

        let focus = QuestionSession.shared.focus
        let response = await LLMRouter.shared.complete(
            prompt: [
                "EVIDENCIA MEDIDA DEL PROYECTO:",
                ProjectAuditAgent.shared.evidenceSummary,
                "",
                "LO QUE HA RESPONDIDO HASTA AHORA:",
                transcript,
                "",
                // Mismo enfoque que las preguntas: si estas apretando por seguridad,
                // las grietas tienen que salir de ahi y no de otro terreno.
                "ENFOQUE: \(focus.label).",
                focus.guidance
            ].joined(separator: "\n"),
            system: Self.systemPrompt,
            maxTokens: 900
        )

        challenges = Self.parse(response)
        isRunning = false
        statusLine = challenges.isEmpty
            ? "Sin grietas claras"
            : "Grieta 1/\(challenges.count)"

        DiagnosticLogger.shared.log(.success, tag: "Tronar",
            message: "\(challenges.count) grietas en \(LLMRouter.shared.lastLatencyMs) ms.")

        await HUDGridManager.shared.renderCurrentState(force: true)
        await speakCurrent()
    }

    /// Dice la repregunta por las gafas: es lo que hay que soltar en voz alta.
    private func speakCurrent() async {
        guard let current else { return }

        ProjectAuditAgent.shared.statusLine = statusLine
        ProjectAuditAgent.shared.findings = [current.claim, current.evidence, current.followUp]
        ProjectAuditAgent.shared.cursor = 0

        await HUDGridManager.shared.switchMode(.projectAudit)
        AvatarHUDManager.shared.startSpeakingAnimation(textToSpeak: current.followUp)
    }

    // MARK: - Formato

    private static let systemPrompt = [
        "Eres el jurado tecnico de una feria de proyectos estudiantiles.",
        "Tu trabajo es encontrar donde NO cuadra la historia del alumno con lo que su",
        "sitio demuestra de verdad, para distinguir a quien entendio lo que hizo de",
        "quien genero codigo sin entenderlo.",
        "",
        "Reglas que no puedes saltarte:",
        "- Cada objecion se apoya en un dato concreto de la evidencia. Sin dato, no hay objecion.",
        "- Si la evidencia respalda al alumno, no inventes una grieta. Es valido devolver menos.",
        "- No juzgas a la persona, juzgas si la explicacion se sostiene.",
        "",
        "Devuelve entre 2 y 4 bloques con este formato EXACTO, sin markdown:",
        "AFIRMA: <lo que sostiene o aparenta el proyecto, una linea>",
        "DATO: <la medicion que no encaja, una linea>",
        "PREGUNTA: <repregunta que no se puede contestar de memoria, una linea>",
        "---",
        "",
        "Maximo 90 caracteres por linea."
    ].joined(separator: "\n")

    /// Trocea la respuesta. Si el modelo ignora el formato, cae a un modo degradado
    /// en vez de devolver nada: media grieta sirve mas que una pantalla vacia.
    static func parse(_ text: String) -> [Challenge] {
        var result: [Challenge] = []

        for block in text.components(separatedBy: "---") {
            var claim = "", evidence = "", followUp = ""
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let value = trimmed.dropPrefixIfPresent("AFIRMA:") { claim = value }
                else if let value = trimmed.dropPrefixIfPresent("DATO:") { evidence = value }
                else if let value = trimmed.dropPrefixIfPresent("PREGUNTA:") { followUp = value }
            }
            if !followUp.isEmpty {
                result.append(Challenge(claim: claim, evidence: evidence, followUp: followUp))
            }
        }

        guard result.isEmpty else { return result }

        // Degradado: cada linea util se toma como repregunta suelta.
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 }
            .prefix(4)
            .map { Challenge(claim: "", evidence: "", followUp: $0) }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
