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

    /// Presentaciones a pantalla completa y hojas, cada grupo con UNA sola fuente.
    ///
    /// Antes habia tres `.fullScreenCover` y cinco `.sheet` encadenados sobre la misma
    /// vista. SwiftUI no lo maneja bien: al pedir uno mientras otro sigue registrado,
    /// la primera presentacion no cuaja y hace falta una segunda pasada. Eso es el
    /// desfase que se veia al tocar Escanear, donde asomaba la home antes de abrirse
    /// la vista de escaneo. Con `item:` solo hay un presentador por grupo.
    private enum Cover: Int, Identifiable {
        case welcome, scanStand, shiki
        var id: Int { rawValue }
    }

    private enum Sheet: Int, Identifiable {
        case questions, settings, guide, cameraDetail, dictationDetail, qrGafas, demolition
        var id: Int { rawValue }
    }

    @State private var activeCover: Cover? = .welcome
    @State private var activeSheet: Sheet? = nil

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
                // Sin esto, una transcripcion arrancada desde el HUD o desde las
                // preguntas no tenia ningun sitio donde pausarse.
                ActiveChannelsBar()

                Spacer()

                HStack(spacing: 20) {
                    CircleAction(
                        icon: "qrcode.viewfinder",
                        title: "Escanear",
                        caption: "Lee el QR del stand",
                        isPrimary: true
                    ) {
                        activeCover = .scanStand
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
                        activeSheet = .questions
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
        // Un solo presentador por grupo: encadenar varios sobre la misma vista es
        // lo que provocaba el desfase al abrir la vista de escaneo.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .questions:       QuestionsView()
            case .settings:        SettingsSheet(router: llmRouter, binding: binding,
                                                 onOpenQRModule: { activeSheet = .qrGafas })
            case .guide:           ConnectionGuideSheetView()
            case .cameraDetail:    CameraStreamDetailView()
            case .dictationDetail: DictationDetailView()
            case .qrGafas:         QRGafasView()
            case .demolition:      DemolitionView()
            }
        }
        .fullScreenCover(item: $activeCover) { cover in
            switch cover {
            case .shiki:
                AvatarAIView()

            // La app abre con la mascota saludando, no con el panel de control.
            case .welcome:
                // El guard vive en la vista que presenta, y un cover no lo hereda:
                // por eso la bienvenida era la unica pantalla sin aviso de desconexion.
                WelcomeView(
                    onStart: {
                        // Ir directo al escaneo. Antes se cerraba la bienvenida y se
                        // reabria el cover 0,35 s despues; con un solo presentador
                        // basta con cambiar el caso y la transicion es unica.
                        activeCover = .scanStand
                    },
                    onSkip: { activeCover = nil }
                )
                .glassesOfflineGuard(closing: .constant([]))

            case .scanStand:
                ScanStandView { urlString in
                    guard let url = URL(string: urlString) else { return }
                    Task {
                        await hudManager.switchMode(.projectAudit)
                        await auditAgent.audit(url: url)
                    }
                }
            }
        }
        .task {
            // Enlace automático al abrir: el caso normal no debería pedir nada.
            await connectionManager.autoConnectOnLaunch()
        }
        // El HUD cambia el modo al tocar Shiki en las gafas, pero nadie lo
        // escuchaba en el teléfono: por eso el botón no abría nada.
        // El HUD puede traer al telefono la pantalla que toque. Se limpia al
        // consumirlo, o volveria a abrirse sola al cerrarla.
        .onReceive(GlassesActionSettings.shared.$phoneScreenRequest.compactMap { $0 }) { screen in
            switch screen {
            case .questions: activeSheet = .questions
            case .scan:      activeCover = .scanStand
            case .demolition: activeSheet = .demolition
            }
            GlassesActionSettings.shared.phoneScreenRequest = nil
        }
        .onReceive(hudManager.$currentMode) { mode in
            if mode == .shikiAgent {
                activeCover = .shiki
            }
        }
        // Guard global: al perder las gafas cierra las vistas que dependen del
        // hardware y muestra el aviso.
        //
        // Shiki queda FUERA a propósito: analiza enlaces y escanea con la cámara
        // del teléfono, así que sigue siendo útil sin gafas. Cerrarlo
        // interrumpiría justo lo único que todavía funciona.
        .glassesOfflineGuard(closing: Binding(
            get: { [activeSheet == .cameraDetail, activeSheet == .dictationDetail] },
            set: { values in
                if !values[0] && activeSheet == .cameraDetail { activeSheet = nil }
                if !values[1] && activeSheet == .dictationDetail { activeSheet = nil }
            }
        ), onUsePhone: {
            activeCover = .shiki
        })
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

            Button(action: { activeSheet = .settings }) {
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
    @ObservedObject private var actions = GlassesActionSettings.shared
    /// Resultado del ultimo test por proveedor, para no tener que leer logs.
    @State private var testResults: [LLMProvider: String] = [:]
    @State private var testing: LLMProvider? = nil
    let binding: (LLMProvider) -> Binding<String>
    let onOpenQRModule: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedores de IA") {
                    ForEach(router.order) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            // El interruptor deja fuera a un proveedor aunque tenga
                            // clave guardada: una clave caducada haria perder un
                            // intento fallido en cada consulta antes de pasar al otro.
                            Toggle(isOn: Binding(
                                get: { router.isEnabled(provider) },
                                set: { router.setEnabled($0, for: provider) }
                            )) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(router.isEnabled(provider) && router.hasKey(provider)
                                              ? Color.brand : Color.gray.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(provider.label)
                                }
                            }

                            SecureField(provider.keyHint, text: binding(provider))
                                .font(.system(size: 12, design: .monospaced))
                                .disabled(!router.isEnabled(provider))
                                .opacity(router.isEnabled(provider) ? 1 : 0.4)

                            HStack(spacing: 10) {
                                Button {
                                    testing = provider
                                    Task {
                                        let result = await router.testProvider(provider)
                                        testResults[provider] = result
                                        testing = nil
                                    }
                                } label: {
                                    if testing == provider {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Probar conexión")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(testing != nil || !router.hasKey(provider))

                                Spacer()
                            }

                            if let result = testResults[provider] {
                                Text(result)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(result.hasPrefix("OK") ? .green : .orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Que quede claro con cuantos se esta trabajando.
                    if router.availableProviders.isEmpty {
                        Text("Ningun proveedor activo: no habra respuestas.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    } else {
                        Text("Se preguntara en este orden: "
                             + router.availableProviders.map(\.label).joined(separator: " → "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if let used = router.lastProviderUsed {
                        Text("Última respuesta: \(used.label) · \(router.lastLatencyMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Picker("Botón principal", selection: $actions.primary) {
                        ForEach(GlassesAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    Text(actions.primary.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Toggle("Un solo destino", isOn: $actions.singleActionMode)
                    Text("La bienvenida muestra solo la acción principal y toda la tarjeta queda tocable. Cualquier toque de la pulsera escanea, sin navegar.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if !actions.singleActionMode {
                        Picker("Botón secundario", selection: $actions.secondary) {
                            ForEach(GlassesAction.allCases) { action in
                                Text(action.label).tag(action)
                            }
                        }
                        Text(actions.secondary.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Botones del HUD (pulsera)")
                } footer: {
                    // Decirlo aqui evita que alguien busque una pantalla de gestos
                    // que no puede existir.
                    Text("La Neural Band no entrega sus gestos al SDK: no hay eventos de pellizco ni deslizamiento. Lo que sí llega es la pulsación de estos botones del HUD, que la pulsera activa. Aquí eliges qué hace cada uno.")
                        .font(.system(size: 11))
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
