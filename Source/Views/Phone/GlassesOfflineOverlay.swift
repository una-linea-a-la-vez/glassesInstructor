import SwiftUI

/// Aviso cuando se pierde el enlace con las gafas.
///
/// Es una hoja inferior, no una pantalla completa: perder las gafas no es un
/// fallo fatal, la app sigue sirviendo con el teléfono. Taparlo todo con un
/// panel rojo hacía parecer catástrofe lo que es un contratiempo, y chocaba con
/// el tono del resto de la app.
struct GlassesOfflineOverlay: View {
    let reason: String?
    let isReconnecting: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void
    /// Abre el flujo que sigue funcionando con la cámara del teléfono.
    var onUsePhone: (() -> Void)?

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Ocupa la pantalla para que el corte se note y se resuelva ahora:
            // media app depende del enlace y seguir tocando cosas muertas
            // confunde más que detenerse un momento.
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                ShikiMascot(mood: .error, pixelSize: 9)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 9) {
                    Text("Se perdió el enlace")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(shortReason)
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                }

                hints

                Spacer()

                actions
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    private var shortReason: String {
        guard let reason, !reason.isEmpty else {
            return "Revisa que estén abiertas y puestas."
        }
        return reason
    }

    /// Las tres causas habituales, en una línea. La lista con iconos ocupaba un
    /// tercio de la pantalla para decir lo mismo.
    private var hints: some View {
        Text("Abiertas y puestas · con batería · mismo Wi-Fi sin VPN")
            .font(.system(size: 12))
            .foregroundColor(Color(white: 0.42))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private var actions: some View {
        VStack(spacing: 9) {
            Button(action: onRetry) {
                HStack(spacing: 8) {
                    if isReconnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(isReconnecting ? "Reconectando…" : "Reconectar")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(isReconnecting ? 0.55 : 0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isReconnecting)

            // El escaneo y las preguntas funcionan sin gafas, así que esta salida
            // no es un descarte: es la otra mitad del producto. Va con contorno
            // en vez de relleno para no competir con "Reconectar".
            if let onUsePhone {
                Button(action: onUsePhone) {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Seguir con el teléfono")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(Color(red: 0.5, green: 0.76, blue: 1.0))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(red: 0.5, green: 0.76, blue: 1.0).opacity(0.4), lineWidth: 1)
                    )
                }
            }

            Button(action: onDismiss) {
                Text("Cerrar aviso")
                    .font(.system(size: 13.5))
                    .foregroundColor(Color(white: 0.45))
            }
            .padding(.top, 4)
        }
    }
}

/// Aplica el guard a cualquier vista: cierra lo que dependa del hardware y
/// muestra el aviso.
struct GlassesOfflineGuard: ViewModifier {
    @ObservedObject private var connection = GlassesConnectionManager.shared

    /// Vistas presentadas que hay que cerrar cuando cae el enlace.
    @Binding var openSheets: [Bool]
    /// Acción para seguir trabajando sin gafas.
    var onUsePhone: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onChange(of: connection.isGlassesOffline) { _, isOffline in
                guard isOffline else { return }
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
                        },
                        onUsePhone: onUsePhone.map { action in
                            {
                                connection.dismissOfflineBanner()
                                action()
                            }
                        }
                    )
                    .transition(.opacity)
                    .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: connection.isGlassesOffline)
    }
}

extension View {
    /// Cierra las vistas indicadas y muestra el aviso al perder las gafas.
    func glassesOfflineGuard(closing sheets: Binding<[Bool]>,
                             onUsePhone: (() -> Void)? = nil) -> some View {
        modifier(GlassesOfflineGuard(openSheets: sheets, onUsePhone: onUsePhone))
    }
}
