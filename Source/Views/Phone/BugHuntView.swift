import SwiftUI

/// Fallos probables del proyecto, con cómo comprobarlos en el sitio.
struct BugHuntView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = BugHuntSession.shared
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
                } else if session.bugs.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(session.bugs.enumerated()), id: \.element.id) { index, bug in
                                card(bug, index: index)
                            }

                            Button {
                                Task { await session.showOnGlasses() }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "eyeglasses")
                                    Text("Comprobar en las gafas")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Color.brand)
                                .cornerRadius(12)
                            }
                            .padding(.top, 4)
                        }
                        .padding(16)
                    }
                }
            }
            .withActiveChannelsBar()
            .navigationTitle("Fallos probables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(session.bugs.isEmpty ? "Analizar" : "Rehacer") {
                        Task { await session.run(force: !session.bugs.isEmpty) }
                    }
                    .disabled(session.isRunning || auditAgent.analysis == nil)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text(auditAgent.analysis == nil
                 ? "Escanea un proyecto primero"
                 : "Pulsa Analizar para ver por dónde se rompe")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    private func card(_ bug: PredictedBug, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: bug.kind.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(bug.kind.label.uppercased())
                    .font(.system(size: 10, weight: .black, design: .monospaced))
            }
            .foregroundColor(bug.kind.tint)

            Text(bug.symptom)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !bug.evidence.isEmpty {
                Text(bug.evidence)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Color.white.opacity(0.15))

            // Lo que se hace delante del stand. Sin esto la predicción no se puede
            // defender, y una predicción indefendible se vuelve en tu contra.
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12))
                Text(bug.howToCheck)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.brand)

            // Marcarlo aqui o desde las gafas es lo mismo: el estado vive en la
            // sesion, no en la pantalla.
            HStack(spacing: 8) {
                verdictButton("Correcto", "checkmark", .refuted, bug: bug, index: index)
                verdictButton("Falla", "xmark", .confirmed, bug: bug, index: index)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
    }

    private func verdictButton(_ title: String,
                               _ icon: String,
                               _ verdict: BugVerdict,
                               bug: PredictedBug,
                               index: Int) -> some View {
        let isActive = bug.verdict == verdict
        let tint: Color = verdict == .confirmed ? .orange : .brand

        return Button {
            // Volver a tocar lo activo lo deja sin marcar: corregirse no deberia
            // obligar a reiniciar el analisis.
            session.setVerdict(isActive ? .pending : verdict, at: index)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(isActive ? .black : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(isActive ? tint : tint.opacity(0.14))
            .cornerRadius(9)
        }
        .buttonStyle(.plain)
    }
}
