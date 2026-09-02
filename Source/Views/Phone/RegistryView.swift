import SwiftUI

/// Historial de proyectos de la feria.
///
/// Volver a uno no cuesta red: `LinkAnalyzer` guarda su análisis, así que
/// reactivarlo sale de memoria. Eso es lo que permite ir de mesa en mesa sin
/// perder lo anterior ni pagar por revisitarlo.
struct RegistryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = ProjectRegistry.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.05).ignoresSafeArea()

                if registry.projects.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundColor(.gray)
                        Text("Todavía no has escaneado ningún proyecto")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(registry.projects) { project in
                                row(project)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Proyectos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func row(_ project: RegisteredProject) -> some View {
        let isActive = registry.activeID == project.id

        return Button {
            guard !isActive else { return }
            Task {
                await registry.activate(project)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isActive ? Color.brand : Color.gray.opacity(0.35))
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.domain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Text("SEC \(project.securityScore)")
                            .foregroundColor(project.securityScore < 40 ? .orange : .brand)
                        Text("CRAFT \(project.craftScore)")
                            .foregroundColor(.gray)
                        if project.answeredCount > 0 {
                            Text("\(project.answeredCount) resp.")
                                .foregroundColor(.gray)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }

                Spacer()

                Text(isActive ? "Activo" : "Volver")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isActive ? .brand : .white.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isActive ? 0.10 : 0.05))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
}
