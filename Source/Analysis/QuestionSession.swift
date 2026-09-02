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

    private init() {}

    var activeQuestion: AskedQuestion? {
        guard let activeQuestionID else { return nil }
        return questions.first { $0.id == activeQuestionID }
    }

    /// Carga las preguntas recién generadas, descartando las de un proyecto anterior.
    func load(_ generated: [String]) {
        questions = generated.map { AskedQuestion(question: $0) }
        activeQuestionID = nil
        DiagnosticLogger.shared.log(.info, tag: "Preguntas", message: "\(generated.count) preguntas cargadas.")
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
