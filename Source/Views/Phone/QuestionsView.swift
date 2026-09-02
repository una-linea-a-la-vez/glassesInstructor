import SwiftUI

/// Interrogatorio del proyecto escaneado.
///
/// Antes este botón abría el avatar, que es una conversación libre y no servía para
/// esto. Aquí el flujo es concreto: las preguntas salen del proyecto que acabas de
/// escanear, eliges una, la haces en voz alta, y el micrófono recoge la respuesta
/// del participante para guardarla y contrastarla con la evidencia medida.
struct QuestionsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var session = QuestionSession.shared
    @ObservedObject private var speech = SpeechAudioManager.shared
    @ObservedObject private var auditAgent = ProjectAuditAgent.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.05).ignoresSafeArea()

                if session.questions.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(session.questions) { question in
                                QuestionCard(
                                    question: question,
                                    isActive: session.activeQuestionID == question.id,
                                    isRecording: session.isRecording,
                                    liveTranscript: speech.transcriptText,
                                    onAsk: { session.startAnswering(question) },
                                    onFinish: { Task { await session.finishAnswering() } },
                                    onCancel: { session.cancelAnswering() }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Preguntas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        session.cancelAnswering()
                        dismiss()
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            if auditAgent.isGenerating {
                ProgressView().tint(.green)
                Text("Generando preguntas del proyecto...")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 40))
                    .foregroundColor(.gray)
                Text("Escanea un proyecto primero")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
        }
        .padding(30)
    }
}

/// Una pregunta con su estado: por hacer, grabando o ya respondida.
private struct QuestionCard: View {
    let question: AskedQuestion
    let isActive: Bool
    let isRecording: Bool
    let liveTranscript: String
    let onAsk: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    private var isListeningHere: Bool { isActive && isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.question)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            if isListeningHere {
                // Lo que se va escuchando, en vivo: da confianza de que sí está grabando.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Escuchando la respuesta")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    Text(liveTranscript.isEmpty ? "..." : liveTranscript)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Terminar", action: onFinish)
                        .buttonStyle(FilledButton(color: .green, textColor: .black))
                    Button("Cancelar", action: onCancel)
                        .buttonStyle(FilledButton(color: .white.opacity(0.1), textColor: .white))
                }
            } else if question.isEvaluating {
                HStack(spacing: 8) {
                    ProgressView().tint(.green)
                    Text("Evaluando la respuesta...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green)
                }
            } else if question.wasAnswered {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Respondió", systemImage: "quote.opening")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text(question.answer)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.verdict.isEmpty {
                        Divider().background(Color.white.opacity(0.15))
                        Text(question.verdict)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button("Volver a preguntar", action: onAsk)
                    .buttonStyle(FilledButton(color: .white.opacity(0.1), textColor: .white))
            } else {
                Button("Haré esta pregunta", action: onAsk)
                    .buttonStyle(FilledButton(color: .green, textColor: .black))
                    .disabled(isRecording)
                    .opacity(isRecording ? 0.4 : 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
    }
}

private struct FilledButton: ButtonStyle {
    let color: Color
    let textColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(textColor)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(color)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
