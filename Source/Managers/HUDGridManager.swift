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
        await renderCurrentState()
        onModeSelected?(newMode)
    }
    
    /// Renderiza la pantalla adecuada según el modo actual
    func renderCurrentState() async {
        guard let display = display, isDisplayActive else {
            // Actualizar simulador local aún si las gafas físicas no están conectadas
            updateSimulatorState()
            return
        }
        
        do {
            switch currentMode {
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
            }
            updateSimulatorState()
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "HUD", message: "Error al enviar vista al HUD: \(error.localizedDescription)")
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
            Text("App ID: 0 (Developer Mode)", style: .body, color: .secondary)
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
    
    /// Actualiza el estado visual para el componente espejo/simulador de la app del teléfono
    private func updateSimulatorState() {
        var state = HUDMirrorState()
        state.activeMode = currentMode
        state.lastRenderTimestamp = Date()
        
        switch currentMode {
        case .gridMenu:
            state.title = "GLASSHUD INSTRUCTOR"
            state.subtitle = "Cuadrícula Principal de Herramientas"
            state.gridButtons = ["📷 Cámara", "🎙️ Micrófono", "⚡ Diagnóstico", "📖 Guía"]
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
        }
        
        self.mirrorState = state
    }
}
