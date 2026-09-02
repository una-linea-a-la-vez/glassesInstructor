import Foundation
import UIKit
import Combine
import MWDATCore
import MWDATDisplay

/// Modelo que describe el contenido visible actual del HUD para el simulador del iPhone
struct HUDMirrorState {
    var title: String = "Menú Principal"
    var subtitle: String = "Selecciona una opción en la cuadrícula"
    var activeMode: HUDMode = .gridMenu
    var gridButtons: [String] = ["📷 Cámara", "🎙️ Micrófono", "⚡ Diagnóstico", "📖 Guía"]
    var liveText: String = ""
    var indicatorStatus: String = "En línea"
    var lastRenderTimestamp: Date = Date()
}

/// Gestor de renderizado de la interfaz en cuadrícula y vistas secundarias en la pantalla HUD (600x600 px)
@MainActor
class HUDGridManager: ObservableObject {
    static let shared = HUDGridManager()
    
    @Published var currentMode: HUDMode = .gridMenu
    @Published var mirrorState: HUDMirrorState = HUDMirrorState()
    @Published var isDisplayActive: Bool = false
    
    private var display: Display?
    private var displayTokens: [any AnyListenerToken] = []
    
    /// Mutex y cooldown de transmisión. El canal del HUD no admite más de ~10 envíos por
    /// segundo; por encima el SDK responde "Superseded by new display request".
    private var isSendingFrame: Bool = false
    private var lastFrameSentAt: Date = .distantPast
    private let minimumSendInterval: TimeInterval = 0.10
    
    // Callbacks para cambiar de modo desde los botones físicos/táctiles del HUD
    var onModeSelected: ((HUDMode) -> Void)?
    
    private init() {}
    
    /// Vincula la capacidad de pantalla (Display) de la sesión de MWDAT
    func attachDisplayCapability(_ displayCapability: Display) {
        self.display = displayCapability
        setupDisplayListeners(displayCapability)
        displayCapability.start()
        isDisplayActive = true
        DiagnosticLogger.shared.log(.success, tag: "HUD", message: "Canal de pantalla (HUD) iniciado.")
    }
    
    /// Desvincula la pantalla
    func detachDisplay() {
        displayTokens.removeAll()
        display = nil
        isDisplayActive = false
        currentMode = .gridMenu
        DiagnosticLogger.shared.log(.info, tag: "HUD", message: "Canal de pantalla desvinculado.")
    }
    
    private func setupDisplayListeners(_ displayCapability: Display) {
        displayTokens.removeAll()
        
        let token = displayCapability.statePublisher.listen { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor in
                DiagnosticLogger.shared.log(.info, tag: "HUD", message: "Estado del canal Display: \(state)")
                self.isDisplayActive = (state == .started)
            }
        }
        displayTokens.append(token)
    }
    
    /// Cambia el modo activo y actualiza la pantalla de las gafas
    func switchMode(_ newMode: HUDMode) async {
        self.currentMode = newMode
        await renderCurrentState(force: true)
        onModeSelected?(newMode)
    }
    
    /// Renderiza en el HUD sólo si el modo activo es el agente (lo usa AvatarHUDManager).
    /// Modos cuyo HUD incluye a la mascota. Cada cuadro de su cara (boca al
    /// hablar, parpadeo) tiene que llegar a las gafas en cualquiera de ellos.
    private static let mascotModes: Set<HUDMode> = [.shikiAgent, .welcome, .projectAudit]

    /// Reenvía el HUD cuando la mascota cambia de cuadro.
    ///
    /// Antes exigía `currentMode == .shikiAgent`, así que en bienvenida y en
    /// auditoría la mascota quedaba congelada en su primer cuadro: el audio
    /// sonaba pero la boca no se movía, y parecía que no hablaba.
    func renderIfAgentMode() async {
        guard Self.mascotModes.contains(currentMode) else { return }
        await renderCurrentState()
    }
    
    /// Renderiza la pantalla adecuada según el modo actual.
    /// - Parameter force: omite el cooldown de transmisión (para cambios de modo, que deben ser inmediatos).
    func renderCurrentState(force: Bool = false) async {
        guard let display = display, isDisplayActive else {
            // Actualizar simulador local aún si las gafas físicas no están conectadas
            updateSimulatorState()
            return
        }
        
        if !force {
            // Si ya hay un envío en vuelo, descartar es mejor que encolar y acumular retraso.
            guard !isSendingFrame else { return }
            guard Date().timeIntervalSince(lastFrameSentAt) >= minimumSendInterval else { return }
        }
        
        isSendingFrame = true
        lastFrameSentAt = Date()
        defer { isSendingFrame = false }
        
        do {
            switch currentMode {
            case .welcome:
                try await renderWelcomeHUD(on: display)
            case .gridMenu:
                try await renderGridMenu(on: display)
            case .cameraStream:
                try await renderCameraHUD(on: display)
            case .dictationMic:
                try await renderDictationHUD(on: display, transcript: SpeechAudioManager.shared.transcriptText)
            case .deviceDiagnostics:
                try await renderDiagnosticsHUD(on: display)
            case .interactiveGuide:
                try await renderGuideHUD(on: display)
            case .shikiAgent:
                try await renderShikiHUD(on: display)
            case .projectAudit:
                try await renderAuditHUD(on: display)
            }
            updateSimulatorState()
        } catch {
            // "Superseded by new display request" sólo indica que un envío más reciente reemplazó
            // a éste; es esperado al actualizar rápido y no merece nivel de error.
            let description = error.localizedDescription
            let isSuperseded = description.localizedCaseInsensitiveContains("superseded")
            DiagnosticLogger.shared.log(
                isSuperseded ? .warning : .error,
                tag: "HUD",
                message: isSuperseded
                    ? "Render descartado: reemplazado por uno más reciente."
                    : "Error al enviar vista al HUD: \(description)"
            )
        }
    }
    
    // MARK: - 1. Renderizado de Menú en Cuadrícula 2x2
    private func renderGridMenu(on display: Display) async throws {
        let view = FlexBox(direction: .column, spacing: 14, alignment: .center) {
            Text("GLASSHUD INSTRUCTOR", style: .heading, color: .primary)
            Text("Selecciona una herramienta:", style: .body, color: .secondary)
            
            // Fila 1 de la cuadrícula
            FlexBox(direction: .row, spacing: 12, alignment: .center) {
                MWDATDisplay.Button(label: "📷 Cámara", style: .primary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.cameraStream)
                    }
                })
                
                MWDATDisplay.Button(label: "🎙️ Dictado", style: .primary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.dictationMic)
                    }
                })
            }
            
            // Fila 2 de la cuadrícula
            FlexBox(direction: .row, spacing: 12, alignment: .center) {
                MWDATDisplay.Button(label: "⚡ Estado", style: .secondary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.deviceDiagnostics)
                    }
                })
                
                MWDATDisplay.Button(label: "📖 Guía", style: .secondary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.interactiveGuide)
                    }
                })
            }
            
            FlexBox(direction: .row, spacing: 12, alignment: .center) {
                MWDATDisplay.Button(label: "🤖 Shiki", style: .primary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.shikiAgent)
                    }
                })
                
                MWDATDisplay.Button(label: "🛡 Auditar", style: .primary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.projectAudit)
                    }
                })
            }
        }
        
        try await display.send(view)
    }
    
    // MARK: - 2. Renderizado de Pantalla de Cámara
    private func renderCameraHUD(on display: Display) async throws {
        let fps = Int(CameraStreamManager.shared.currentFPS)
        let frames = CameraStreamManager.shared.totalFramesReceived
        let status = CameraStreamManager.shared.isStreaming ? "TRANSMITIENDO [\(fps) FPS]" : "CÁMARA PAUSADA"
        
        let view = FlexBox(direction: .column, spacing: 14, alignment: .center) {
            Text("📷 CÁMARA FRONTAL", style: .heading, color: .primary)
            Text(status, style: .body, color: .secondary)
            Text("Frames Recibidos: \(frames)", style: .body, color: .secondary)
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .secondary, onClick: {
                Task { @MainActor in
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    // MARK: - 3. Renderizado de Pantalla de Dictado / Micrófono
    func renderDictationHUD(on display: Display, transcript: String) async throws {
        let text = transcript.isEmpty ? "(Habla para ver el dictado en tiempo real...)" : transcript
        let micStatus = SpeechAudioManager.shared.isListening ? "🎙️ MICRÓFONO GRABANDO" : "🎙️ MICRÓFONO EN ESPERA"
        
        let view = FlexBox(direction: .column, spacing: 12, alignment: .center) {
            Text("DICTADO EN VIVO", style: .heading, color: .primary)
            Text(micStatus, style: .body, color: .secondary)
            Text(text, style: .body, color: .primary)
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .secondary, onClick: {
                Task { @MainActor in
                    SpeechAudioManager.shared.stopListening()
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    // MARK: - 4. Renderizado de Diagnóstico
    private func renderDiagnosticsHUD(on display: Display) async throws {
        let view = FlexBox(direction: .column, spacing: 10, alignment: .center) {
            Text("DIAGNÓSTICO HARDWARE", style: .heading, color: .primary)
            Text("BT Protocol: com.meta.ar.wearable", style: .body, color: .secondary)
            Text("App ID: \(HUDGridManager.configuredMetaAppID)", style: .body, color: .secondary)
            Text("Display: 600x600 px Waveguide", style: .body, color: .secondary)
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .primary, onClick: {
                Task { @MainActor in
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    // MARK: - 5. Renderizado de Guía
    private func renderGuideHUD(on display: Display) async throws {
        let view = FlexBox(direction: .column, spacing: 10, alignment: .center) {
            Text("GUÍA RÁPIDA", style: .heading, color: .primary)
            Text("1. Gafas puestas en el rostro", style: .body, color: .secondary)
            Text("2. Misma red Wi-Fi sin VPN", style: .body, color: .secondary)
            Text("3. Toca la patilla para interactuar", style: .body, color: .secondary)
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .primary, onClick: {
                Task { @MainActor in
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    // MARK: - 6. Renderizado del Agente Shiki
    private func renderShikiHUD(on display: Display) async throws {
        let avatar = AvatarHUDManager.shared
        let isListening = SpeechAudioManager.shared.isListening
        
        let view = FlexBox(direction: .column, spacing: 12, alignment: .center) {
            if let frame = avatar.hudFrame {
                Image(image: frame, sizePreset: .fill)
                    .flexGrow(1)
            }
            
            Text(avatar.hudText, style: .body, color: .primary)
            
            FlexBox(direction: .row, spacing: 10, alignment: .center) {
                MWDATDisplay.Button(label: "🔍 QR Stand", style: .secondary, onClick: {
                    Task { @MainActor in
                        await CameraStreamManager.shared.startQRScanning()
                    }
                })
                
                MWDATDisplay.Button(
                    label: isListening ? "🛑 Detener" : "🎙️ Hablar",
                    style: isListening ? .secondary : .primary,
                    onClick: {
                        Task { @MainActor in
                            if SpeechAudioManager.shared.isListening {
                                SpeechAudioManager.shared.stopListening()
                            } else {
                                SpeechAudioManager.shared.startListening(continuous: true)
                            }
                        }
                    }
                )
            }
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .secondary, onClick: {
                Task { @MainActor in
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    // MARK: - Bienvenida

    /// La mascota saluda en el HUD y ofrece una sola acción.
    ///
    /// Es lo primero que se ve al enlazar: seis botones de golpe no dicen por
    /// dónde empezar, y el saludo sí.
    private func renderWelcomeHUD(on display: Display) async throws {
        let avatar = AvatarHUDManager.shared
        let actions = GlassesActionSettings.shared

        let view = FlexBox(direction: .column, spacing: 12, alignment: .center) {
            if let frame = avatar.hudFrame {
                Image(image: frame, sizePreset: .fill)
            }

            Text("¡Hola!", style: .heading, color: .primary)
            Text("¿Entendemos un proyecto?", style: .body, color: .primary)

            // Los dos botones salen de Ajustes. Son los que la pulsera activa, que es
            // la unica entrada suya que el SDK entrega (como onClick, no como gesto).
            MWDATDisplay.Button(label: actions.primary.hudLabel, style: .primary, onClick: {
                Task { @MainActor in
                    await GlassesActionSettings.shared.perform(GlassesActionSettings.shared.primary)
                }
            })

            // En modo de un solo destino no se dibuja nada mas: si no hay otro
            // elemento que enfocar, cualquier toque cae en la accion principal.
            if !actions.singleActionMode {
                MWDATDisplay.Button(label: actions.secondary.hudLabel, style: .secondary, onClick: {
                    Task { @MainActor in
                        await GlassesActionSettings.shared.perform(GlassesActionSettings.shared.secondary)
                    }
                })

                MWDATDisplay.Button(label: "☰ Ver todo el menú", style: .secondary, onClick: {
                    Task { @MainActor in
                        await self.switchMode(.gridMenu)
                    }
                })
            }
        }

        if actions.singleActionMode {
            // La tarjeta entera queda tocable, no solo el boton: asi no hace falta
            // apuntar ni navegar, que es lo mas cerca del "toco y escanea" que
            // permite el SDK.
            try await display.send(view.onTap {
                Task { @MainActor in
                    await GlassesActionSettings.shared.perform(GlassesActionSettings.shared.primary)
                }
            })
        } else {
            try await display.send(view)
        }
    }

    // MARK: - 7. Renderizado de Auditoría de Proyecto
    private func renderAuditHUD(on display: Display) async throws {
        let agent = ProjectAuditAgent.shared
        let lines = agent.hudLines
        let hasAnalysis = agent.analysis != nil
        let hasFindings = !agent.findings.isEmpty
        
        let avatar = AvatarHUDManager.shared

        let view = FlexBox(direction: .column, spacing: 10, alignment: .center) {
            // La mascota también acompaña la auditoría: antes este modo era solo
            // texto y se sentía como un volcado de datos, no como que alguien te
            // está explicando el proyecto.
            if let frame = avatar.hudFrame {
                Image(image: frame, sizePreset: .fill)
            }

            Text(agent.isReadingEnvironment ? "DONDE ESTAS" : "ENTIENDE EL PROYECTO", style: .heading, color: .primary)

            // Las líneas ya vienen recortadas a lo que cabe legible en el waveguide.
            for line in lines {
                Text(line, style: .body, color: .primary)
            }
            
            if hasFindings {
                MWDATDisplay.Button(label: "▶ Siguiente", style: .primary, onClick: {
                    Task { @MainActor in
                        ProjectAuditAgent.shared.advanceCursor()
                        await self.renderCurrentState(force: true)
                    }
                })
            } else if hasAnalysis {
                // Tras el veredicto se puede repreguntar: la mascota lee la
                // pregunta y el micrófono queda abierto para responderle.
                MWDATDisplay.Button(label: "❓ Preguntar", style: .primary, onClick: {
                    Task { @MainActor in
                        await ProjectAuditAgent.shared.startQuestionRound()
                    }
                })

                FlexBox(direction: .row, spacing: 8, alignment: .center) {
                    for role in AuditRole.allCases {
                        MWDATDisplay.Button(label: role.hudLabel, style: .secondary, onClick: {
                            Task { @MainActor in
                                await ProjectAuditAgent.shared.run(role: role)
                            }
                        })
                    }
                }
            } else {
                MWDATDisplay.Button(label: "📷 Foto del código", style: .primary, onClick: {
                    Task { @MainActor in
                        await CameraStreamManager.shared.scanQRFromPhoto()
                    }
                })
            }
            
            MWDATDisplay.Button(label: "⬅ Volver al Menú", style: .secondary, onClick: {
                Task { @MainActor in
                    await self.switchMode(.gridMenu)
                }
            })
        }
        
        try await display.send(view)
    }
    
    /// MetaAppID declarado en Info.plist, para mostrarlo en el panel de diagnóstico.
    static var configuredMetaAppID: String {
        let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
        let value = (mwdat?["MetaAppID"] as? String) ?? ""
        if value.isEmpty || value == "0" {
            return "\(value.isEmpty ? "ausente" : value) (Developer Mode)"
        }
        return value
    }
    
    /// Actualiza el estado visual para el componente espejo/simulador de la app del teléfono
    private func updateSimulatorState() {
        var state = HUDMirrorState()
        state.activeMode = currentMode
        state.lastRenderTimestamp = Date()
        
        switch currentMode {
        case .welcome:
            state.title = "¡HOLA!"
            state.subtitle = "¿Entendemos un proyecto?"
            state.gridButtons = ["🔍 Escanear su código", "☰ Ver todo el menú"]
        case .gridMenu:
            state.title = "GLASSHUD INSTRUCTOR"
            state.subtitle = "Cuadrícula Principal de Herramientas"
            state.gridButtons = ["📷 Cámara", "🎙️ Micrófono", "⚡ Diagnóstico", "📖 Guía", "🤖 Shiki"]
        case .cameraStream:
            state.title = "📷 CÁMARA FRONTAL"
            state.subtitle = CameraStreamManager.shared.isStreaming ? "Transmitiendo en vivo" : "Stream pausado"
            state.liveText = "FPS: \(Int(CameraStreamManager.shared.currentFPS)) | Frames: \(CameraStreamManager.shared.totalFramesReceived)"
        case .dictationMic:
            state.title = "🎙️ DICTADO EN VIVO"
            state.subtitle = SpeechAudioManager.shared.isListening ? "Escuchando voz..." : "Micrófono en pausa"
            state.liveText = SpeechAudioManager.shared.transcriptText.isEmpty ? "(Habla para ver subtítulos aquí...)" : SpeechAudioManager.shared.transcriptText
        case .deviceDiagnostics:
            state.title = "DIAGNÓSTICO DE HARDWARE"
            state.subtitle = "Protocolos y Sesión OK"
            state.liveText = "Link: Conectado | Display: 600x600 | AppID: 0"
        case .interactiveGuide:
            state.title = "GUÍA DE INICIO RÁPIDO"
            state.subtitle = "Checklist de conexión"
            state.liveText = "1. Gafas en rostro\n2. Mismo Wi-Fi\n3. Sin VPN"
        case .projectAudit:
            let agent = ProjectAuditAgent.shared
            state.title = agent.isReadingEnvironment ? "DÓNDE ESTÁS" : "AUDITORÍA DE PROYECTO"
            state.subtitle = agent.statusLine
            state.liveText = agent.hudLines.joined(separator: "\n")
        case .shikiAgent:
            let avatar = AvatarHUDManager.shared
            state.title = "🤖 SHIKI (AGENTE IA)"
            state.subtitle = CameraStreamManager.shared.isScanningQR
                ? "Escaneando código QR..."
                : "Estado: \(avatar.avatarState)"
            state.liveText = avatar.hudText
        }
        
        self.mirrorState = state
    }
}
