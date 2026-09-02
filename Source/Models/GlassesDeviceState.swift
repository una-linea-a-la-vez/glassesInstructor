import Foundation
import SwiftUI

/// Modos de pantalla disponibles tanto en el HUD de las gafas como en la interfaz del iPhone
enum HUDMode: String, CaseIterable, Identifiable {
    /// Pantalla de entrada: la mascota saluda y ofrece una sola acción. Aparece al
    /// enlazar, antes que el menú, para que lo primero no sea una rejilla de seis
    /// botones sin contexto.
    case welcome = "Bienvenida"
    case gridMenu = "Menú Principal (2x2)"
    case cameraStream = "Cámara en Vivo"
    case dictationMic = "Micrófono & Dictado"
    case deviceDiagnostics = "Diagnóstico & Hardware"
    case interactiveGuide = "Guía de Conexión"
    case shikiAgent = "Shiki (Agente IA)"
    case projectAudit = "Auditoría de Proyecto"
    case reviewFocus = "Elegir Enfoque"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .gridMenu: return "square.grid.2x2.fill"
        case .cameraStream: return "camera.fill"
        case .dictationMic: return "mic.fill"
        case .deviceDiagnostics: return "gauge.with.dots.needle.bottom.50percent"
        case .interactiveGuide: return "book.fill"
        case .shikiAgent: return "sparkles"
        case .projectAudit: return "checkmark.shield.fill"
        case .reviewFocus: return "slider.horizontal.3"
        }
    }
    
    var color: Color {
        switch self {
        case .welcome: return .cyan
        case .gridMenu: return .blue
        case .cameraStream: return .green
        case .dictationMic: return .orange
        case .deviceDiagnostics: return .purple
        case .interactiveGuide: return .cyan
        case .shikiAgent: return .pink
        case .projectAudit: return .mint
        case .reviewFocus: return .indigo
        }
    }
}

/// Estados de la máquina de conexión con las gafas inteligentes
enum ConnectionState: String {
    case disconnected = "Desconectado"
    case configuring = "Iniciando SDK..."
    case registeringMetaAI = "Autorizando en Meta AI..."
    case scanning = "Buscando Gafas (Bluetooth)..."
    case linkConnecting = "Enlazando Canal Físico..."
    case sessionStarting = "Negociando Sesión Criptográfica..."
    case connected = "Gafas Conectadas & HUD Listo"
    case error = "Error de Conexión"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .configuring, .registeringMetaAI, .scanning, .linkConnecting, .sessionStarting: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
}

/// Telemetría y estado en tiempo real del hardware
struct DeviceTelemetry {
    var deviceName: String = "No detectado"
    var deviceType: String = "Desconocido"
    var supportsDisplay: Bool = false
    var linkState: String = "Desconectado"
    var isDisplayReady: Bool = false
    var isCameraStreaming: Bool = false
    var currentFPS: Double = 0.0
    var receivedFramesCount: Int = 0
    var lastErrorDescription: String? = nil
    var isProximitySensorActive: Bool = true
    /// Único dato de salud que el SDK expone (`DeviceState.thermalLevel`).
    var thermalLevel: String = "desconocido"
}
