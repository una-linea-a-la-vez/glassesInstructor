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
    @State private var showingQuestions = false

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

                HStack(spacing: 20) {
                    CircleAction(
                        icon: "qrcode.viewfinder",
                        title: "Escanear",
                        caption: "Lee el QR del stand",
                        isPrimary: true
                    ) {
                        showingScanStand = true
                    }

                    CircleAction(
                        icon: "questionmark.bubble.fill",
                        title: "Preguntas",
                        caption: auditAgent.analysis == nil
                            ? "Escanea un proyecto primero"
                            : "Para los participantes",
                        isPrimary: false
                    ) {
                        // Se abre ya, para que se vea el "generando" en vez de un
                        // botón muerto mientras el modelo trabaja.
                        showingQuestions = true
                        Task {
                            await hudManager.switchMode(.projectAudit)
                            await auditAgent.run(role: .interrogate)
                            QuestionSession.shared.load(auditAgent.findings)
                        }
                    }
                    .disabled(auditAgent.analysis == nil)
                    .opacity(auditAgent.analysis == nil ? 0.45 : 1)
                }
                .padding(.horizontal, 28)

                if auditAgent.isAnalyzing || auditAgent.isGenerating {
                    Text(auditAgent.statusLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.brand)
                        .padding(.top, 20)
                }

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: $showingQuestions) {
            QuestionsView()
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
                .fill(isConnected ? Color.brand : Color.gray)
                .frame(width: 9, height: 9)

            Text(isConnected ? "Gafas conectadas" : connectionManager.connectionState.rawValue)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isConnected ? .brand : .gray)

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

/// Acción de la home, como círculo.
///
/// El círculo se consigue con `aspectRatio(1)` sobre un ancho flexible: los dos
/// quedan iguales y se adaptan al ancho del teléfono en vez de llevar un tamaño
/// fijo que se saldría en pantallas estrechas.
private struct CircleAction: View {
    let icon: String
    let title: String
    let caption: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                VStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .semibold))
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(isPrimary ? .black : .white)
                .padding(18)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(isPrimary ? Color.brand : Color.white.opacity(0.08))
                .clipShape(Circle())
            }

            Text(caption)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
                                .fill(router.hasKey(provider) ? Color.brand : Color.gray.opacity(0.4))
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
