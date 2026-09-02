import SwiftUI

/// Vista principal a pantalla completa (Edge-to-Edge) de la aplicación GlassesInstructor
struct FullScreenMainView: View {
    @StateObject private var connectionManager = GlassesConnectionManager.shared
    @ObservedObject private var hudManager = HUDGridManager.shared
    @ObservedObject private var cameraManager = CameraStreamManager.shared
    @ObservedObject private var speechManager = SpeechAudioManager.shared
    @ObservedObject private var avatarManager = AvatarHUDManager.shared
    @ObservedObject private var aiManager = AIManager.shared
    @ObservedObject private var llmRouter = LLMRouter.shared
    @ObservedObject private var auditAgent = ProjectAuditAgent.shared
    @ObservedObject private var logger = DiagnosticLogger.shared
    
    @State private var showingGuideSheet = false
    @State private var showingCameraDetail = false
    @State private var showingDictationDetail = false
    @State private var showingCopiedToast = false
    @State private var showingQRGafas = false
    /// Evita relanzar la conexion si la vista se recompone.
    @State private var didAutoConnect = false
    /// Modo demo: oculta enlace y consola para dejar solo lo que se enseña.
    @State private var demoMode = true
    
    /// Enlaza cada campo con la clave que corresponde.
    private func binding(for provider: LLMProvider) -> Binding<String> {
        switch provider {
        case .claude: return $llmRouter.claudeKey
        case .gemini: return $llmRouter.geminiKey
        case .openRouter: return $llmRouter.openRouterKey
        }
    }
    
    var body: some View {
        ZStack {
            // Fondo oscuro inmersivo a pantalla completa
            Color(white: 0.05).ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                // MARK: - 1. Top Header Bar
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.green)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GLASSES INSTRUCTOR")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                            Text(connectionManager.connectionState.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(connectionManager.connectionState.color)
                        }
                    }
                    
                    Spacer()
                    
                    // Modo demo: un toque esconde/enseña enlace y consola
                    Button(action: { demoMode.toggle() }) {
                        Image(systemName: demoMode ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                            .padding(8)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(white: 0.09).ignoresSafeArea(edges: .top))
                
                // MARK: - 2. Scrollable Body
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        
                        if !demoMode {
                        // Tarjeta Principal de Control de Conexión
                        VStack(spacing: 12) {
                            HStack {
                                Circle()
                                    .fill(connectionManager.connectionState.color)
                                    .frame(width: 10, height: 10)
                                Text("ESTADO DEL ENLACE")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                Spacer()
                                if !connectionManager.telemetry.deviceName.isEmpty {
                                    Text(connectionManager.telemetry.deviceName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                            
                            // Botón de Conexión / Desconexión
                            Button(action: {
                                if connectionManager.connectionState == .connected {
                                    connectionManager.disconnectGlasses()
                                } else {
                                    Task { await connectionManager.connectGlasses() }
                                }
                            }) {
                                HStack(spacing: 10) {
                                    if connectionManager.isConnecting {
                                        ProgressView()
                                            .tint(.black)
                                    } else {
                                        Image(systemName: connectionManager.connectionState == .connected ? "bolt.slash.fill" : "bolt.fill")
                                    }
                                    
                                    Text(connectionManager.connectionState == .connected ? "Desconectar Gafas" : (connectionManager.isConnecting ? "Conectando..." : "Conectar Meta Ray-Ban"))
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .foregroundColor(connectionManager.connectionState == .connected ? .white : .black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(connectionManager.connectionState == .connected ? Color.red : Color.green)
                                .cornerRadius(12)
                            }
                            .disabled(connectionManager.isConnecting)
                            
                            if let error = connectionManager.telemetry.lastErrorDescription {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(16)
                        .background(Color(white: 0.10))
                        .cornerRadius(16)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        }
                        
                        // MARK: - 3. HUD Live Mirror Simulator
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "sparkles.tv")
                                    .foregroundColor(.green)
                                Text("HUD LIVE MIRROR (LO QUE SE VE EN LAS GAFAS)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            
                            HUDMirrorSimulatorView()
                                .padding(.horizontal, 16)
                        }
                        
                        // MARK: - 4. Panel de Control Rápido (Acciones de la Cuadrícula)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ACCIONES RÁPIDAS (CONTROL REMOTO)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 16)
                            
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                
                                // Tile 1: Cámara de las Gafas
                                QuickActionCard(
                                    icon: "camera.fill",
                                    title: "Cámara Gafas",
                                    subtitle: cameraManager.isStreaming ? "\(Int(cameraManager.currentFPS)) FPS Activo" : "Abrir Stream",
                                    badgeColor: cameraManager.isStreaming ? .green : .blue
                                ) {
                                    showingCameraDetail = true
                                    Task { await hudManager.switchMode(.cameraStream) }
                                }
                                
                                // Tile 2: Micrófono & Dictado
                                QuickActionCard(
                                    icon: "mic.fill",
                                    title: "Micrófono",
                                    subtitle: speechManager.isListening ? "Grabando..." : "Iniciar Dictado",
                                    badgeColor: speechManager.isListening ? .green : .orange
                                ) {
                                    showingDictationDetail = true
                                    Task { await hudManager.switchMode(.dictationMic) }
                                }
                                
                                // Tile 3: Diagnóstico Hardware
                                QuickActionCard(
                                    icon: "gauge.with.dots.needle.bottom.50percent",
                                    title: "Diagnóstico",
                                    subtitle: "Link & Sensores",
                                    badgeColor: .purple
                                ) {
                                    Task { await hudManager.switchMode(.deviceDiagnostics) }
                                }
                                
                                // Tile 4: Manual Instructivo
                                QuickActionCard(
                                    icon: "book.fill",
                                    title: "Manual",
                                    subtitle: "Paso a paso",
                                    badgeColor: .cyan
                                ) {
                                    showingGuideSheet = true
                                }
                                
                                // Tile 5: Agente conversacional Shiki
                                QuickActionCard(
                                    icon: "sparkles",
                                    title: "Shiki (IA)",
                                    subtitle: avatarManager.avatarState,
                                    badgeColor: .pink
                                ) {
                                    Task { await hudManager.switchMode(.shikiAgent) }
                                }
                                
                                // Tile: modulo aislado de escaneo con gafas
                                QuickActionCard(
                                    icon: "qrcode.viewfinder",
                                    title: "QR · Gafas",
                                    subtitle: "Módulo de prueba",
                                    badgeColor: .teal
                                ) {
                                    showingQRGafas = true
                                }

                                // Tile 6b: Objetivo de prueba, sin QR ni gafas
                                QuickActionCard(
                                    icon: "testtube.2",
                                    title: "Probar Auditoría",
                                    subtitle: auditAgent.isAnalyzing ? auditAgent.statusLine : "VERDANA Loop",
                                    badgeColor: auditAgent.isAnalyzing ? .green : .mint
                                ) {
                                    Task {
                                        await hudManager.switchMode(.projectAudit)
                                        await auditAgent.auditDemoTarget()
                                    }
                                }
                                
                                // Tile 6: Escaneo de stand por QR
                                QuickActionCard(
                                    icon: "qrcode.viewfinder",
                                    title: "Escanear Stand",
                                    subtitle: cameraManager.isScanningQR ? "Buscando QR..." : (aiManager.standContext == nil ? "Sin stand" : "Stand cargado"),
                                    badgeColor: cameraManager.isScanningQR ? .green : .indigo
                                ) {
                                    Task {
                                        await hudManager.switchMode(.shikiAgent)
                                        await cameraManager.startQRScanning()
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            
                            // Credencial de Gemini: si Config.swift conserva el placeholder,
                            // la clave se guarda aquí (UserDefaults) sin tocar el repositorio.
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("PROVEEDORES DE IA")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Spacer()
                                    if let used = llmRouter.lastProviderUsed {
                                        Text("\(used.label) · \(llmRouter.lastLatencyMs) ms")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.green)
                                    }
                                }
                                
                                // Se pregunta en este orden; el primero con clave que
                                // responda gana, y si falla se cae al siguiente solo.
                                ForEach(llmRouter.order) { provider in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(llmRouter.hasKey(provider) ? Color.green : Color.gray.opacity(0.4))
                                            .frame(width: 7, height: 7)
                                        
                                        Text(provider.label)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .frame(width: 78, alignment: .leading)
                                        
                                        SecureField(provider.keyHint, text: binding(for: provider))
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(8)
                                            .background(Color.white.opacity(0.06))
                                            .cornerRadius(8)
                                    }
                                }
                                
                                Text(llmRouter.availableProviders.isEmpty
                                     ? "Sin ninguna clave: el análisis y Shiki no responderán."
                                     : "Respaldo activo: \(llmRouter.availableProviders.map(\.label).joined(separator: " → "))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(llmRouter.availableProviders.isEmpty ? .orange : .green.opacity(0.7))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }
                        
                        if !demoMode {
                        // MARK: - 5. Consola de Diagnóstico en Tiempo Real
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "terminal.fill")
                                    .foregroundColor(.green)
                                Text("CONSOLA DE EVENTOS & DIAGNÓSTICO")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Spacer()
                                
                                Button(action: {
                                    UIPasteboard.general.string = logger.fullExportText
                                    showingCopiedToast = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        showingCopiedToast = false
                                    }
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12))
                                        .foregroundColor(.green)
                                }
                                
                                Button(action: { logger.clearLogs() }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.horizontal, 16)
                            
                            // Lista de Logs Terminal
                            VStack(alignment: .leading, spacing: 6) {
                                if logger.logs.isEmpty {
                                    Text("Esperando eventos...")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.gray)
                                } else {
                                    ForEach(logger.logs.prefix(12)) { entry in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("[\(entry.formattedTime)]")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.gray)
                                            
                                            Text("[\(entry.tag)]")
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(entry.level.color)
                                            
                                            Text(entry.message)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.9))
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                        }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            
            // Toast de copiado
            if showingCopiedToast {
                VStack {
                    Spacer()
                    Text("✓ Logs copiados al portapapeles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .cornerRadius(20)
                        .shadow(radius: 10)
                        .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showingCopiedToast)
            }
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
        .sheet(isPresented: $showingQRGafas) {
            QRGafasView()
        }
        .task {
            // Enlaza solo al abrir la app, para que al ponerte las gafas ya salga la
            // bienvenida sin tocar nada. Si ya hay sesión, no hace nada.
            guard !didAutoConnect, connectionManager.connectionState == .disconnected else { return }
            didAutoConnect = true
            await connectionManager.connectGlasses()
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
