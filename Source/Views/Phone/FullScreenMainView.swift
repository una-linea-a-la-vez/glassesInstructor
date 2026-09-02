import SwiftUI

/// Home del MVP: dos acciones y nada más.
///
/// Antes esto era un panel de control con consola de logs, espejo del HUD y seis
/// tiles. Para enseñarlo en una feria eso es ruido: quien mira la pantalla del
/// teléfono no necesita ver telemetría, necesita saber qué botón tocar.
/// Los ajustes siguen accesibles tras el engrane, porque sin la clave de IA no
/// responde nada.
struct FullScreenMainView: View {
    @StateObject private var connectionManager = GlassesConnectionManager.shared
    @ObservedObject private var hudManager = HUDGridManager.shared
    @ObservedObject private var llmRouter = LLMRouter.shared
    @ObservedObject private var auditAgent = ProjectAuditAgent.shared

    @State private var showingGuideSheet = false
    @State private var showingCameraDetail = false
    @State private var showingDictationDetail = false
    @State private var showingShiki = false
    @State private var showingScanStand = false
    @State private var showingWelcome = true
    @State private var showingQRGafas = false
    @State private var showingSettings = false

    /// Enlaza cada campo de clave con el proveedor que le toca.
    private func binding(for provider: LLMProvider) -> Binding<String> {
        switch provider {
        case .gemini: return $llmRouter.geminiKey
        case .openRouter: return $llmRouter.openRouterKey
        }
    }

    private var isConnected: Bool { connectionManager.connectionState == .connected }

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                VStack(spacing: 16) {
                    HomeAction(
                        icon: "qrcode.viewfinder",
                        title: "Escanear proyecto",
                        subtitle: "Lee el QR del stand y lo analiza",
                        isPrimary: true
                    ) {
                        showingScanStand = true
                    }

                    HomeAction(
                        icon: "questionmark.bubble.fill",
                        title: "Preguntas",
                        subtitle: auditAgent.analysis == nil
                            ? "Escanea un proyecto primero"
                            : "Genera preguntas para los participantes",
                        isPrimary: false
                    ) {
                        Task {
                            await hudManager.switchMode(.projectAudit)
                            await auditAgent.run(role: .interrogate)
                            showingShiki = true
                        }
                    }
                    .disabled(auditAgent.analysis == nil)
                    .opacity(auditAgent.analysis == nil ? 0.45 : 1)
                }
                .padding(.horizontal, 24)

                if auditAgent.isAnalyzing || auditAgent.isGenerating {
                    Text(auditAgent.statusLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(.top, 20)
                }

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(router: llmRouter, binding: binding, onOpenQRModule: {
                showingSettings = false
                showingQRGafas = true
            })
        }
        .sheet(isPresented: $showingGuideSheet) {
            ConnectionGuideSheetView()
        }
        .sheet(isPresented: $showingCameraDetail) {
            CameraStreamDetailView()
        }
        .sheet(isPresented: $showingDictationDetail) {
            DictationDetailView()
        }
        .fullScreenCover(isPresented: $showingShiki) {
            AvatarAIView()
        }
        .task {
            // Enlace automático al abrir: el caso normal no debería pedir nada.
            await connectionManager.autoConnectOnLaunch()
        }
        // La app abre con la mascota saludando, no con el panel de control.
        .fullScreenCover(isPresented: $showingWelcome) {
            WelcomeView(
                onStart: {
                    showingWelcome = false
                    // Pequeña pausa para que no se solapen las dos transiciones.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingScanStand = true
                    }
                },
                onSkip: { showingWelcome = false }
            )
        }
        .fullScreenCover(isPresented: $showingScanStand) {
            ScanStandView { urlString in
                guard let url = URL(string: urlString) else { return }
                Task {
                    await hudManager.switchMode(.projectAudit)
                    await auditAgent.audit(url: url)
                }
            }
        }
        // El HUD cambia el modo al tocar Shiki en las gafas, pero nadie lo
        // escuchaba en el teléfono: por eso el botón no abría nada.
        .onReceive(hudManager.$currentMode) { mode in
            if mode == .shikiAgent {
                showingShiki = true
            }
        }
        // Guard global: al perder las gafas cierra las vistas que dependen del
        // hardware y muestra el aviso.
        //
        // Shiki queda FUERA a propósito: analiza enlaces y escanea con la cámara
        // del teléfono, así que sigue siendo útil sin gafas. Cerrarlo
        // interrumpiría justo lo único que todavía funciona.
        .glassesOfflineGuard(closing: Binding(
            get: { [showingCameraDetail, showingDictationDetail] },
            set: { values in
                showingCameraDetail    = values[0]
                showingDictationDetail = values[1]
            }
        ), onUsePhone: {
            showingShiki = true
        })
        .sheet(isPresented: $showingQRGafas) {
            QRGafasView()
        }
    }

    /// Cabecera mínima: nombre, punto de estado y acceso a ajustes.
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 9, height: 9)

            Text(isConnected ? "Gafas conectadas" : connectionManager.connectionState.rawValue)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isConnected ? .green : .gray)

            Spacer()

            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}

/// Botón grande de la home. Área táctil generosa: se usa de pie y con prisa.
private struct HomeAction: View {
    let icon: String
    let title: String
    let subtitle: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .opacity(0.75)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
            .foregroundColor(isPrimary ? .black : .white)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(isPrimary ? Color.green : Color.white.opacity(0.08))
            .cornerRadius(18)
        }
    }
}

/// Ajustes: claves de IA y el módulo aislado de QR. Fuera de la home a propósito.
private struct SettingsSheet: View {
    @ObservedObject var router: LLMRouter
    let binding: (LLMProvider) -> Binding<String>
    let onOpenQRModule: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedores de IA") {
                    ForEach(router.order) { provider in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(router.hasKey(provider) ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(provider.label)
                                .frame(width: 90, alignment: .leading)
                            SecureField(provider.keyHint, text: binding(provider))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    if let used = router.lastProviderUsed {
                        Text("Última respuesta: \(used.label) · \(router.lastLatencyMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Diagnóstico") {
                    Button("Módulo QR · Gafas", action: onOpenQRModule)
                }
            }
            .navigationTitle("Ajustes")
        }
    }
}

/// Tarjeta para la cuadrícula de acciones rápidas
private struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let badgeColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(badgeColor)
                    Spacer()
                    Circle()
                        .fill(badgeColor.opacity(0.2))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(badgeColor)
                        )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}
