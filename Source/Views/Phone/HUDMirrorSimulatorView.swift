import SwiftUI

/// Componente visual que simula píxel a píxel la pantalla Waveguide (600x600 px) de las gafas
struct HUDMirrorSimulatorView: View {
    @ObservedObject var hudManager = HUDGridManager.shared
    @ObservedObject var cameraManager = CameraStreamManager.shared
    @ObservedObject var speechManager = SpeechAudioManager.shared
    
    var body: some View {
        VStack(spacing: 12) {
            // Marco óptico del HUD
            ZStack {
                // Fondo óptico con efecto de tinte verde/oscuro
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.brand.opacity(0.4), lineWidth: 1.5)
                    )
                
                // Efecto de cuadrícula de guía óptica sutil
                HUDGridLinesOverlay()
                
                // Contenido según el modo activo
                VStack(spacing: 14) {
                    // Header de la lente
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hudManager.isDisplayActive ? Color.brand : Color.gray)
                                .frame(width: 8, height: 8)
                            Text("OPTIC WAVEGUIDE (600x600)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.brand.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Text(hudManager.mirrorState.activeMode.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.brand.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    
                    Spacer()
                    
                    // Renderizado del contenido interno del HUD
                    switch hudManager.currentMode {
                    case .welcome:
                        // El espejo reutiliza la vista de Shiki: la bienvenida es
                        // la misma mascota, saludando.
                        HUDShikiModeView(hudManager: hudManager, avatarManager: AvatarHUDManager.shared)
                    case .gridMenu:
                        HUDGridMenuView(hudManager: hudManager)
                    case .cameraStream:
                        HUDCameraModeView(cameraManager: cameraManager, hudManager: hudManager)
                    case .dictationMic:
                        HUDDictationModeView(speechManager: speechManager, hudManager: hudManager)
                    case .deviceDiagnostics:
                        HUDDiagnosticsModeView(hudManager: hudManager)
                    case .interactiveGuide:
                        HUDGuideModeView(hudManager: hudManager)
                    case .shikiAgent:
                        HUDShikiModeView(hudManager: hudManager, avatarManager: AvatarHUDManager.shared)
                    case .reviewFocus:
                        // El espejo del telefono no necesita su propia pantalla de
                        // enfoque: la eleccion se hace desde las gafas o desde
                        // Preguntas, y aqui basta con reflejar cual esta activo.
                        HUDAuditModeView(hudManager: hudManager, agent: ProjectAuditAgent.shared)
                    case .projectAudit:
                        HUDAuditModeView(hudManager: hudManager, agent: ProjectAuditAgent.shared)
                    }
                    
                    Spacer()
                    
                    // Barra inferior de telemetría del HUD
                    HStack {
                        Text("FPS: \(Int(cameraManager.currentFPS))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.brand.opacity(0.6))
                        Spacer()
                        Text("LATENCIA: <12ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.brand.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .frame(height: 280)
            .shadow(color: Color.brand.opacity(0.15), radius: 10, x: 0, y: 4)
        }
    }
}

// MARK: - Subvistas del Simulador de HUD

/// Cuadrícula 2x2 en el HUD
private struct HUDGridMenuView: View {
    @ObservedObject var hudManager: HUDGridManager
    
    var body: some View {
        VStack(spacing: 12) {
            Text("GLASSHUD INSTRUCTOR")
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundColor(.brand)
            
            Text("Selecciona una herramienta en las gafas:")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.brand.opacity(0.8))
            
            // Fila 1 de la cuadrícula
            HStack(spacing: 12) {
                HUDGridButton(icon: "camera.fill", title: "Cámara", isPrimary: true) {
                    Task { await hudManager.switchMode(.cameraStream) }
                }
                
                HUDGridButton(icon: "mic.fill", title: "Dictado", isPrimary: true) {
                    Task { await hudManager.switchMode(.dictationMic) }
                }
            }
            
            // Fila 2 de la cuadrícula
            HStack(spacing: 12) {
                HUDGridButton(icon: "gauge.with.dots.needle.bottom.50percent", title: "Estado", isPrimary: false) {
                    Task { await hudManager.switchMode(.deviceDiagnostics) }
                }
                
                HUDGridButton(icon: "book.fill", title: "Guía", isPrimary: false) {
                    Task { await hudManager.switchMode(.interactiveGuide) }
                }
            }
            
            HUDGridButton(icon: "sparkles", title: "Shiki (Agente IA)", isPrimary: true) {
                Task { await hudManager.switchMode(.shikiAgent) }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Espejo de la auditoría: veredicto progresivo y los tres agentes
private struct HUDAuditModeView: View {
    @ObservedObject var hudManager: HUDGridManager
    @ObservedObject var agent: ProjectAuditAgent
    
    var body: some View {
        VStack(spacing: 8) {
            Text("🛡 AUDITORÍA DE PROYECTO")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundColor(.brand)
            
            Text(agent.statusLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.brand.opacity(0.7))
            
            ForEach(agent.hudLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.brand)
                    .multilineTextAlignment(.center)
            }
            
            if agent.analysis != nil && agent.findings.isEmpty {
                HStack(spacing: 8) {
                    ForEach(AuditRole.allCases) { role in
                        HUDGridButton(icon: "bolt.fill", title: role.label, isPrimary: true) {
                            Task { await agent.run(role: role) }
                        }
                    }
                }
            }
            
            HUDGridButton(icon: "arrow.left", title: "Volver", isPrimary: false) {
                Task { await hudManager.switchMode(.gridMenu) }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Espejo del agente Shiki: avatar animado y estado de la conversación
private struct HUDShikiModeView: View {
    @ObservedObject var hudManager: HUDGridManager
    @ObservedObject var avatarManager: AvatarHUDManager
    
    var body: some View {
        VStack(spacing: 8) {
            Image(uiImage: avatarManager.currentAvatarImage)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(height: 110)
            
            Text(avatarManager.avatarState.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.brand.opacity(0.7))
            
            Text(avatarManager.hudText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.brand)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
            
            HUDGridButton(icon: "arrow.left", title: "Volver", isPrimary: false) {
                Task { await hudManager.switchMode(.gridMenu) }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Botón estilizado para el HUD Waveguide
private struct HUDGridButton: View {
    let icon: String
    let title: String
    let isPrimary: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(isPrimary ? .black : .brand)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPrimary ? Color.brand : Color.brand.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.brand, lineWidth: isPrimary ? 0 : 1)
                    )
            )
        }
    }
}

/// Vista de Cámara en el HUD
private struct HUDCameraModeView: View {
    @ObservedObject var cameraManager: CameraStreamManager
    @ObservedObject var hudManager: HUDGridManager
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 16))
                Text("CÁMARA FRONTAL EN VIVO")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.brand)
            
            if let frame = cameraManager.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 85)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.brand.opacity(0.8), lineWidth: 1)
                    )
            } else {
                VStack(spacing: 4) {
                    ProgressView()
                        .tint(.brand)
                    Text(cameraManager.streamStatusMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.brand.opacity(0.8))
                }
                .frame(height: 85)
            }
            
            Button(action: {
                Task { await hudManager.switchMode(.gridMenu) }
            }) {
                Text("⬅ VOLVER AL MENÚ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brand.opacity(0.15))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Vista de Dictado en el HUD
private struct HUDDictationModeView: View {
    @ObservedObject var speechManager: SpeechAudioManager
    @ObservedObject var hudManager: HUDGridManager
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                Text("SUBTÍTULOS & DICTADO")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.brand)
            
            Text(speechManager.transcriptText.isEmpty ? "(Habla para ver el texto proyectado en las gafas...)" : speechManager.transcriptText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.brand)
                .multilineTextAlignment(.center)
                .frame(minHeight: 50)
                .padding(8)
                .background(Color.brand.opacity(0.08))
                .cornerRadius(6)
            
            Button(action: {
                Task { await hudManager.switchMode(.gridMenu) }
            }) {
                Text("⬅ VOLVER AL MENÚ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brand.opacity(0.15))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Vista de Diagnóstico en el HUD
private struct HUDDiagnosticsModeView: View {
    @ObservedObject var hudManager: HUDGridManager
    
    var body: some View {
        VStack(spacing: 8) {
            Text("DIAGNÓSTICO HARDWARE")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.brand)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("• BT Channel: com.meta.ar.wearable")
                Text("• App ID: 0 (Developer Mode)")
                Text("• Display: 600x600 px Waveguide")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.brand.opacity(0.85))
            
            Button(action: {
                Task { await hudManager.switchMode(.gridMenu) }
            }) {
                Text("⬅ VOLVER AL MENÚ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brand.opacity(0.15))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Vista de Guía en el HUD
private struct HUDGuideModeView: View {
    @ObservedObject var hudManager: HUDGridManager
    
    var body: some View {
        VStack(spacing: 8) {
            Text("GUÍA RÁPIDA DE CONEXIÓN")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.brand)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Gafas puestas en el rostro")
                Text("2. Mismo Wi-Fi sin VPN activa")
                Text("3. Toca la patilla para confirmar")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.brand.opacity(0.85))
            
            Button(action: {
                Task { await hudManager.switchMode(.gridMenu) }
            }) {
                Text("⬅ VOLVER AL MENÚ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brand.opacity(0.15))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Líneas de calibración óptica de fondo
private struct HUDGridLinesOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let w = proxy.size.width
                let h = proxy.size.height
                
                // Líneas de cuadrícula sutiles
                for i in 1..<4 {
                    let y = h * CGFloat(i) / 4.0
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                for j in 1..<6 {
                    let x = w * CGFloat(j) / 6.0
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
            }
            .stroke(Color.brand.opacity(0.04), lineWidth: 1)
        }
    }
}
