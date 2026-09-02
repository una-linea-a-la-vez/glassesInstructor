import SwiftUI

/// Pantalla del módulo "tronar el proyecto".
///
/// Cada grieta se muestra con sus tres piezas separadas —lo que afirma, el dato que
/// no encaja y la repregunta— porque es lo que la hace defendible. Si el alumno
/// discute, ahí está la medición; y si contesta bien la repregunta, su proyecto
/// queda mejor parado que antes.
struct DemolitionView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var session = DemolitionSession.shared
    @ObservedObject private var auditAgent = ProjectAuditAgent.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.05).ignoresSafeArea()

                if session.isRunning {
                    VStack(spacing: 12) {
                        ProgressView().tint(.brand)
                        Text(session.statusLine)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.brand)
                    }
                } else if session.challenges.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(session.challenges.enumerated()), id: \.element.id) { index, challenge in
                                ChallengeCard(challenge: challenge, number: index + 1)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .withActiveChannelsBar()
            .navigationTitle("Tronar proyecto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Analizar") {
                        Task { await session.run() }
                    }
                    .disabled(session.isRunning || auditAgent.analysis == nil)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text(auditAgent.analysis == nil
                 ? "Escanea un proyecto primero"
                 : "Pulsa Analizar para buscar grietas")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            if !QuestionSession.shared.questions.contains(where: \.wasAnswered) {
                // Las respuestas del alumno son la mitad del material: sin ellas
                // solo se puede objetar sobre el sitio, no sobre lo que sostiene.
                Text("Funciona mejor si antes le hiciste alguna pregunta: sus respuestas son la otra mitad del material.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .padding(30)
    }
}

private struct ChallengeCard: View {
    let challenge: Challenge
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GRIETA \(number)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.gray)

            if !challenge.claim.isEmpty {
                field(title: "AFIRMA", text: challenge.claim, color: .white.opacity(0.85))
            }
            if !challenge.evidence.isEmpty {
                field(title: "PERO EL DATO DICE", text: challenge.evidence, color: .orange)
            }

            Divider().background(Color.white.opacity(0.15))

            Text(challenge.followUp)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.brand)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
    }

    private func field(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
