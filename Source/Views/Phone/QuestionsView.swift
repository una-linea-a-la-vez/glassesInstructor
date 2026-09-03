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

                VStack(spacing: 0) {
                    focusPicker

                    if session.questions.isEmpty {
                        empty
                        Spacer()
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
                                    onCancel: { session.cancelAnswering() },
                                    onDiscard: { Task { await session.discard(question) } }
                                )
                            }
                            Button {
                                Teleprompter.shared.load(session.questions.map(\.question),
                                                         title: session.focus.label.uppercased())
                                Task { await HUDGridManager.shared.switchMode(.teleprompter) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "eyeglasses")
                                    Text("Leer en las gafas")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Color.brand)
                                .cornerRadius(12)
                            }
                            .padding(.top, 4)

                            Button {
                                Task { await session.newRound() }
                            } label: {
                                HStack(spacing: 8) {
                                    if session.isGenerating {
                                        ProgressView().controlSize(.small).tint(.black)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(session.isGenerating ? "Generando..." : "Otra tanda")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Color.white.opacity(0.10))
                                .cornerRadius(12)
                            }
                            .disabled(session.isGenerating)
                        }
                        .padding(16)
                    }
                    }
                }
            }
            .withActiveChannelsBar()
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

    /// Selector de area. En fila desplazable y no en un Picker porque son siete y
    /// se cambian a menudo: se ven todas y se tocan de una.
    private var focusPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReviewFocus.allCases) { option in
                    let isActive = session.focus == option
                    Button {
                        Task { await session.setFocus(option) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                                .font(.system(size: 11, weight: .bold))
                            Text(option.label)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(isActive ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(isActive ? option.tint : Color.white.opacity(0.08))
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isGenerating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            if auditAgent.isGenerating {
                ProgressView().tint(.brand)
                Text("Generando preguntas del proyecto...")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.brand)
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
    let onDiscard: () -> Void

    private var isListeningHere: Bool { isActive && isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(question.question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                // Cambiar UNA pregunta cuesta una peticion minima, en vez de
                // regenerar la tanda entera por una que no encajaba.
                if !isListeningHere && !question.isEvaluating {
                    Button(action: onDiscard) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }

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
                        .buttonStyle(FilledButton(color: .brand, textColor: .black))
                    Button("Cancelar", action: onCancel)
                        .buttonStyle(FilledButton(color: .white.opacity(0.1), textColor: .white))
                }
            } else if question.isEvaluating {
                HStack(spacing: 8) {
                    ProgressView().tint(.brand)
                    Text("Evaluando la respuesta...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.brand)
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
                            .foregroundColor(.brand)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button("Volver a preguntar", action: onAsk)
                    .buttonStyle(FilledButton(color: .white.opacity(0.1), textColor: .white))
            } else {
                Button("Haré esta pregunta", action: onAsk)
                    .buttonStyle(FilledButton(color: .brand, textColor: .black))
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
