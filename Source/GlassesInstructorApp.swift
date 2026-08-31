import SwiftUI
import MWDATCore

@main
struct GlassesInstructorApp: App {
    var body: some Scene {
        WindowGroup {
            FullScreenMainView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    Task {
                        do {
                            // Reenvía la URL recibida desde Meta AI/Meta View al SDK para completar el registro
                            _ = try await Wearables.shared.handleUrl(url)
                            DiagnosticLogger.shared.log(.success, tag: "URLHandler", message: "Callback URL de Meta AI procesada exitosamente: \(url.scheme ?? "")")
                        } catch {
                            DiagnosticLogger.shared.log(.error, tag: "URLHandler", message: "Error procesando callback URL de Meta SDK: \(error.localizedDescription)")
                        }
                    }
                }
        }
    }
}
