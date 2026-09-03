import Foundation
import Combine

/// Una pregunta hecha a un participante, con lo que respondió y el juicio del modelo.
struct AskedQuestion: Identifiable {
    let id = UUID()
    let question: String
    var answer: String = ""
    var verdict: String = ""
    var isEvaluating: Bool = false

    var wasAnswered: Bool { !answer.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Lleva el interrogatorio: qué se preguntó, qué contestaron y qué tan bien.
///
/// La respuesta se captura por dictado en vez de escribirla: quien pregunta está
/// de pie frente al stand y no puede teclear mientras escucha.
@MainActor
class QuestionSession: ObservableObject {
    static let shared = QuestionSession()

    /// Preguntas generadas a partir del proyecto escaneado.
    @Published var questions: [AskedQuestion] = []
    /// Pregunta que se está haciendo ahora mismo.
    @Published var activeQuestionID: AskedQuestion.ID? = nil
    @Published var isRecording: Bool = false

    private let speech = SpeechAudioManager.shared

    /// Preguntas ya generadas por proyecto. Abrir la pantalla no debe costar una
    /// peticion: sin esto, cada vez que se entraba a Preguntas se llamaba a la API
    /// aunque fuera el mismo stand y las mismas preguntas.
    private var cache: [String: [String]] = [:]

    /// Todo lo que ya se pregunto de cada proyecto, incluidas las descartadas.
    /// Se manda como exclusion para que una tanda nueva no repita lo anterior.
    private var seen: [String: Set<String>] = [:]

    @Published var isGenerating: Bool = false

    /// Area sobre la que apretar. Cambiarla pide una tanda nueva de ese terreno.
    @Published var focus: ReviewFocus = .general

    private init() {}

    /// Proyecto cuyas preguntas estan cargadas en `questions` ahora mismo.
    /// Sin esto, escanear otro stand dejaba en pantalla las preguntas del anterior:
    /// `questions` seguia lleno y la comprobacion de cache lo daba por bueno.
    private var loadedKey: String?

    /// Clave de cache: proyecto + enfoque. El enfoque forma parte de la clave
    /// porque las preguntas de Diseño no valen como preguntas de Seguridad.
    private var projectKey: String? {
        guard let url = ProjectAuditAgent.shared.analysis?.url else { return nil }
        return "\(url.absoluteString)|\(focus.rawValue)"
    }

    /// Para no repetir entre enfoques distintos del mismo proyecto.
    private var seenKey: String? {
        ProjectAuditAgent.shared.analysis?.url.absoluteString
    }

    var activeQuestion: AskedQuestion? {
        guard let activeQuestionID else { return nil }
        return questions.first { $0.id == activeQuestionID }
    }

    /// Carga las preguntas recién generadas, descartando las de un proyecto anterior.
    func load(_ generated: [String]) {
        questions = generated.map { AskedQuestion(question: $0) }
        activeQuestionID = nil
        if let key = projectKey {
            cache[key] = generated
            seen[seenKey ?? key, default: []].formUnion(generated)
            loadedKey = key
        }
        DiagnosticLogger.shared.log(.info, tag: "Preguntas", message: "\(generated.count) preguntas cargadas.")
    }

    // MARK: - Generación con caché

    /// Devuelve las preguntas del proyecto activo, pidiéndolas solo si no las hay.
    func ensureQuestions() async {
        guard let key = projectKey else { return }

        // Cambio de proyecto: lo que hubiera en pantalla es de otro stand.
        if loadedKey != key {
            questions = []
            activeQuestionID = nil
            loadedKey = key
        }

        // Ya en memoria: ni se toca la red. Es el caso normal al volver a abrir.
        if let cached = cache[key], !cached.isEmpty, questions.isEmpty {
            questions = cached.map { AskedQuestion(question: $0) }
            DiagnosticLogger.shared.log(.info, tag: "Preguntas",
                message: "\(cached.count) preguntas servidas de caché, sin gastar API.")
            return
        }
        guard questions.isEmpty else { return }   // ya están en pantalla

        let generated = await generate(count: 4, excluding: Array(seen[seenKey ?? key] ?? []))
        load(generated)
    }

    /// Cambia el area y trae las preguntas de esa area, de cache si ya existen.
    func setFocus(_ newFocus: ReviewFocus) async {
        guard newFocus != focus else { return }
        focus = newFocus
        questions = []
        activeQuestionID = nil
        loadedKey = nil
        DiagnosticLogger.shared.log(.info, tag: "Preguntas", message: "Enfoque: \(newFocus.label).")
        await ensureQuestions()
    }

    /// Descarta una pregunta y pide **una** sustituta, sin repetir lo ya visto.
    func discard(_ question: AskedQuestion) async {
        guard let key = projectKey else { return }
        questions.removeAll { $0.id == question.id }
        seen[seenKey ?? key, default: []].insert(question.question)

        let replacement = await generate(count: 1, excluding: Array(seen[seenKey ?? key] ?? []))
        guard let text = replacement.first else { return }

        questions.append(AskedQuestion(question: text))
        cache[key] = questions.map(\.question)
        seen[seenKey ?? key, default: []].insert(text)
    }

    /// Otra tanda entera, excluyendo todo lo preguntado antes.
    func newRound() async {
        guard let key = projectKey else { return }
        seen[seenKey ?? key, default: []].formUnion(questions.map(\.question))

        let generated = await generate(count: 4, excluding: Array(seen[seenKey ?? key] ?? []))
        guard !generated.isEmpty else { return }
        load(generated)
    }

    /// Una sola llamada, con las exclusiones dentro del prompt.
    private func generate(count: Int, excluding: [String]) async -> [String] {
        guard ProjectAuditAgent.shared.analysis != nil else { return [] }

        isGenerating = true
        defer { isGenerating = false }

        var prompt = [
            "EVIDENCIA MEDIDA DEL PROYECTO:",
            ProjectAuditAgent.shared.evidenceSummary,
            "",
            "ENFOQUE: \(focus.label).",
            focus.guidance,
            "",
            "Devuelve exactamente \(count) pregunta\(count == 1 ? "" : "s")."
        ]
        if !excluding.isEmpty {
            prompt.append("")
            prompt.append("NO repitas ni reformules ninguna de estas, ya se usaron:")
            prompt.append(excluding.map { "- \($0)" }.joined(separator: "\n"))
        }

        let response = await LLMRouter.shared.complete(
            prompt: prompt.joined(separator: "\n"),
            system: AuditRole.interrogate.systemPrompt,
            // Cuatro preguntas de una linea no necesitan 500 tokens, y cada token
            // de salida es tiempo de espera.
            maxTokens: 320
        )

        let lines = ProjectAuditAgent.splitIntoHUDLines(response)
        DiagnosticLogger.shared.log(.success, tag: "Preguntas",
            message: "\(lines.count) preguntas nuevas en \(LLMRouter.shared.lastLatencyMs) ms.")
        return Array(lines.prefix(count))
    }

    // MARK: - Dictado

    /// Abre el micrófono para recoger la respuesta del participante.
    func startAnswering(_ question: AskedQuestion) {
        activeQuestionID = question.id
        isRecording = true
        speech.transcriptText = ""
        // Sin modo continuo: aquí no queremos que el corte por silencio dispare
        // el ciclo del avatar, la respuesta la cierra quien pregunta.
        speech.startListening()
        DiagnosticLogger.shared.log(.info, tag: "Preguntas", message: "Grabando respuesta...")
    }

    /// Cierra el micrófono, guarda lo dicho y lo manda a evaluar.
    func finishAnswering() async {
        guard let id = activeQuestionID,
              let index = questions.firstIndex(where: { $0.id == id }) else { return }

        speech.stopListening()
        isRecording = false

        let spoken = speech.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        questions[index].answer = spoken

        guard !spoken.isEmpty else {
            DiagnosticLogger.shared.log(.warning, tag: "Preguntas", message: "No se escuchó nada.")
            return
        }
        DiagnosticLogger.shared.log(.success, tag: "Preguntas", message: "Respuesta guardada (\(spoken.count) caracteres).")

        // Que el registro sepa cuanto se avanzo con este stand: al volver de mesa
        // en mesa, saber cual quedo a medias es la mitad de la utilidad.
        if let url = ProjectAuditAgent.shared.analysis?.url {
            ProjectRegistry.shared.noteAnswers(for: url, count: questions.filter(\.wasAnswered).count)
        }

        await evaluate(at: index)
    }

    func cancelAnswering() {
        speech.stopListening()
        isRecording = false
        activeQuestionID = nil
    }

    // MARK: - Evaluación

    /// Manda pregunta, respuesta y evidencia medida al modelo para que juzgue.
    private func evaluate(at index: Int) async {
        questions[index].isEvaluating = true

        let asked = questions[index].question
        let answer = questions[index].answer
        let evidence = ProjectAuditAgent.shared.evidenceSummary

        let verdict = await LLMRouter.shared.complete(
            prompt: [
                "PREGUNTA: \(asked)",
                "RESPUESTA DEL ESTUDIANTE: \(answer)",
                "",
                "EVIDENCIA MEDIDA DEL PROYECTO:",
                evidence
            ].joined(separator: "\n"),
            system: Self.judgeSystemPrompt,
            maxTokens: 300
        )

        guard questions.indices.contains(index) else { return }
        questions[index].verdict = verdict
        questions[index].isEvaluating = false

        await speakVerdict(verdict)
    }

    /// Dice el veredicto por las gafas y lo deja escrito en el HUD.
    ///
    /// Leerlo en el telefono obliga a bajar la vista delante del alumno, que es
    /// justo el momento en que no quieres dejar de mirarle. Por el auricular de las
    /// gafas llega sin romper la conversacion.
    private func speakVerdict(_ verdict: String) async {
        let avatar = AvatarHUDManager.shared
        let hud = HUDGridManager.shared

        // La primera linea es el veredicto de una palabra; es lo que interesa oir
        // primero, el resto se lee en el HUD sin prisa.
        let spoken = verdict
            .split(separator: "\n")
            .prefix(2)
            .joined(separator: ". ")

        ProjectAuditAgent.shared.statusLine = "Veredicto"
        ProjectAuditAgent.shared.findings = verdict
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ProjectAuditAgent.shared.cursor = 0

        await hud.switchMode(.projectAudit)
        avatar.startSpeakingAnimation(textToSpeak: spoken)
    }

    private static let judgeSystemPrompt = [
        "Juzgas si un estudiante entiende el proyecto que presenta, comparando lo que",
        "respondio con la evidencia medida de su sitio.",
        "Distingue entender de repetir: quien genero codigo sin entenderlo describe QUE",
        "hace, pero no POR QUE se eligio eso ni QUE pasa cuando falla.",
        "Formato estricto:",
        "- Primera linea: un veredicto de una palabra (Solido, Dudoso o Flojo).",
        "- Despues, 2 o 3 lineas explicando en que te basas.",
        "- Maximo 70 caracteres por linea, sin markdown ni emojis.",
        "- Si la respuesta contradice la evidencia medida, dilo citando el dato."
    ].joined(separator: "\n")
}
