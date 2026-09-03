import SwiftUI

/// Pantalla para dejar los stands listos antes de la feria.
struct PreloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preloader = ProjectPreloader.shared

    @State private var newURL: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://...", text: $newURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, design: .monospaced))

                        Button {
                            preloader.add(newURL)
                            newURL = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button("Restaurar los stands de la feria") {
                        for target in ProjectPreloader.fairTargets { preloader.add(target) }
                    }

                    Button("Añadir los ya escaneados") {
                        preloader.addFromRegistry()
                    }
                    .disabled(ProjectRegistry.shared.projects.isEmpty)
                } header: {
                    Text("Stands")
                } footer: {
                    Text("Precargar analiza el sitio y deja una tanda de preguntas hecha. En la feria eso sale de memoria: ni red ni espera.")
                }

                if !preloader.entries.isEmpty {
                    Section("En la lista") {
                        ForEach(preloader.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(string: entry.url)?.host ?? entry.url)
                                    .font(.system(size: 14, weight: .medium))
                                Text(entry.note)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(entry.isReady ? .brand : .secondary)
                            }
                        }
                        .onDelete(perform: preloader.remove)
                    }
                }

                Section {
                    Button {
                        Task { await preloader.preloadAll() }
                    } label: {
                        HStack(spacing: 10) {
                            if preloader.isWorking {
                                ProgressView().controlSize(.small)
                                Text(preloader.progress)
                                    .font(.system(size: 12, design: .monospaced))
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Precargar todo")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                    }
                    .disabled(preloader.isWorking || preloader.entries.isEmpty)
                } footer: {
                    // Que quede claro por que hay que repetirlo: las cachés viven en
                    // memoria, no en disco, y se van al cerrar la app.
                    Text("Hazlo con buena conexión y sin cerrar la app: lo precargado vive en memoria y se pierde al reiniciarla.")
                }
            }
            .navigationTitle("Precargar stands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
