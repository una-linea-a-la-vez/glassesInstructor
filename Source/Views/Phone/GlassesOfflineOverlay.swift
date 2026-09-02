import SwiftUI

/// Aviso a pantalla completa cuando se pierde el enlace con las gafas.
///
/// Toda la app depende del hardware: si el enlace cae, cualquier vista abierta
/// (cámara, dictado, avatar) queda mostrando datos muertos. Este overlay se
/// impone sobre todo, y el `ViewModifier` de abajo cierra las vistas activas.
struct GlassesOfflineOverlay: View {
    let reason: String?
    let isReconnecting: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.25), lineWidth: 2)
                        .frame(width: 108, height: 108)
                        .scaleEffect(appeared ? 1.08 : 0.9)
                    Image(systemName: "eyeglasses.slash")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundColor(.red)
                }

                VStack(spacing: 8) {
                    Text("GAFAS SIN CONEXIÓN")
                        .font(.system(size: 19, weight: .black, design: .monospaced))
                        .foregroundColor(.white)

                    Text(reason ?? "Se perdió el enlace con las gafas.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.68))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }

                // Lo que en la práctica resuelve el 90% de las caídas
                VStack(alignment: .leading, spacing: 9) {
                    checklistRow("eyeglasses", "Ábrelas y póntelas (o tapa el sensor nasal)")
                    checklistRow("battery.25", "Revisa que tengan batería")
                    checklistRow("wifi", "Mismo Wi-Fi que el iPhone, sin VPN")
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .background(Color(white: 0.10))
                .cornerRadius(14)
                .padding(.horizontal, 28)

                VStack(spacing: 10) {
                    Button(action: onRetry) {
                        HStack(spacing: 8) {
                            if isReconnecting {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isReconnecting ? "Reconectando…" : "Reconectar")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isReconnecting ? Color.gray : Color.green)
                        .cornerRadius(12)
                    }
                    .disabled(isReconnecting)

                    Button(action: onDismiss) {
                        Text("Continuar sin gafas")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 28)
            }
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private func checklistRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.yellow)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.75))
            Spacer(minLength: 0)
        }
    }
}

/// Aplica el guard a cualquier vista: cierra lo que esté abierto y muestra el aviso.
///
/// Se pone en la raíz para que ninguna pantalla quede viva sin enlace.
struct GlassesOfflineGuard: ViewModifier {
    @ObservedObject private var connection = GlassesConnectionManager.shared

    /// Vistas presentadas que hay que cerrar cuando cae el enlace.
    @Binding var openSheets: [Bool]

    func body(content: Content) -> some View {
        content
            .onChange(of: connection.isGlassesOffline) { _, isOffline in
                guard isOffline else { return }
                // Cerrar todo lo abierto: sin gafas esas vistas muestran datos muertos.
                for index in openSheets.indices {
                    openSheets[index] = false
                }
            }
            .overlay {
                if connection.isGlassesOffline {
                    GlassesOfflineOverlay(
                        reason: connection.offlineReason,
                        isReconnecting: connection.isConnecting,
                        onRetry: {
                            Task { await connection.connectGlasses() }
                        },
                        onDismiss: {
                            connection.dismissOfflineBanner()
                        }
                    )
                    .transition(.opacity)
                    .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: connection.isGlassesOffline)
    }
}

extension View {
    /// Cierra las vistas indicadas y muestra el aviso al perder las gafas.
    func glassesOfflineGuard(closing sheets: Binding<[Bool]>) -> some View {
        modifier(GlassesOfflineGuard(openSheets: sheets))
    }
}
