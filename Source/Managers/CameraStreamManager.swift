import Foundation
import UIKit
import Combine
import MWDATCore
import MWDATCamera
import AVFoundation

/// Gestor del canal de transmisión de video desde la cámara frontal de las gafas inteligentes
@MainActor
class CameraStreamManager: ObservableObject {
    static let shared = CameraStreamManager()
    
    @Published var isStreaming: Bool = false
    @Published var latestFrame: UIImage? = nil
    @Published var currentFPS: Double = 0.0
    @Published var totalFramesReceived: Int = 0
    @Published var streamStatusMessage: String = "Cámara inactiva"
    @Published var lastStreamError: String? = nil
    
    private var camera: Camera?
    private var streamTokens: [any AnyListenerToken] = []
    
    private var frameCountSinceLastCheck: Int = 0
    private var lastFPSCalculationTime: Date = Date()
    
    private init() {}
    
    /// Asigna la capacidad de cámara proveniente de la sesión de MWDAT
    func attachCameraCapability(_ cameraCapability: Camera) {
        self.camera = cameraCapability
        setupStreamListeners(cameraCapability)
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Capacidad de cámara vinculada a la sesión.")
    }
    
    /// Desvincula y limpia la cámara.
    ///
    /// `Camera` es dueña del recurso de hardware según el SDK: sin `camera.stop()`
    /// el firmware lo mantiene tomado y el siguiente `addCamera()` falla. Esa era la
    /// causa de que la cámara fallara más en el segundo intento que en el primero.
    func detachCamera() {
        stopStream()
        camera?.stop()
        streamTokens.removeAll()
        camera = nil
        latestFrame = nil
        currentFPS = 0.0
        isStreaming = false
        streamStatusMessage = "Cámara inactiva"
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Capacidad de cámara desvinculada y hardware liberado.")
    }
    
    /// Configura los listeners del flujo de video y errores del stream
    private func setupStreamListeners(_ cameraCapability: Camera) {
        streamTokens.removeAll()
        
        // 1. Frame Listener
        let frameToken = cameraCapability.stream.videoFramePublisher.listen { [weak self] frame in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleIncomingFrame(frame)
            }
        }
        streamTokens.append(frameToken)
        
        // 2. Error Listener — un error deja el stream muerto: hay que reflejarlo
        let errorToken = cameraCapability.stream.errorPublisher.listen { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleStreamError(error)
            }
        }
        streamTokens.append(errorToken)

        // 3. State Listener — ésta es la fuente de verdad del stream, no `isStreaming`
        let stateToken = cameraCapability.stream.statePublisher.listen { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleStreamState(state)
            }
        }
        streamTokens.append(stateToken)
    }

    /// Sincroniza la bandera con lo que reporta el SDK. Antes `isStreaming` se ponía
    /// en `true` nada más llamar a `start()`, así que la UI decía "Transmitiendo"
    /// aunque el stream nunca hubiera arrancado.
    private func handleStreamState(_ state: StreamState) {
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Estado de stream: \(state)")

        switch state {
        case .streaming:
            isStreaming = true
            lastStreamError = nil
            streamStatusMessage = "Transmitiendo en vivo"
            frameCountSinceLastCheck = 0
            lastFPSCalculationTime = Date()

        case .waitingForDevice:
            isStreaming = false
            streamStatusMessage = "Esperando a las gafas…"

        case .starting:
            streamStatusMessage = "Iniciando cámara…"

        case .paused:
            isStreaming = false
            currentFPS = 0
            streamStatusMessage = "Pausado por el dispositivo"

        case .stopping, .stopped:
            isStreaming = false
            currentFPS = 0
            streamStatusMessage = "Cámara detenida"
        }
    }

    /// Traduce los errores del SDK a algo accionable. `hingesClosed` y los térmicos
    /// son los que más aparecen en pruebas de escritorio.
    private func handleStreamError(_ error: StreamError) {
        isStreaming = false
        currentFPS = 0

        let message: String
        switch error {
        case .hingesClosed:
            message = "Las gafas están plegadas. Ábrelas y póntelas (o tapa el sensor nasal)."
        case .thermalCritical, .thermalEmergency:
            message = "Las gafas se calentaron y cortaron el video. Déjalas enfriar un minuto."
        case .peakPowerShutdown:
            message = "Las gafas cortaron el video por pico de consumo. Déjalas reposar."
        case .batteryCritical:
            message = "Batería crítica en las gafas. Ponlas en el estuche a cargar."
        case .permissionDenied:
            message = "Permiso de cámara denegado. Habilítalo en la app Meta AI."
        case .deviceNotConnected:
            message = "Las gafas se desconectaron."
        case .deviceNotFound:
            message = "No encuentro las gafas."
        case .photoCaptureFailed:
            message = "No se pudo capturar la foto. Reintenta."
        case .internalError:
            message = "Error interno del SDK de cámara."
        case .timeout:
            message = "El video no respondió a tiempo. Revisa que el iPhone y las gafas estén en el mismo Wi-Fi, sin VPN."
        case .videoStreamingError:
            message = "Falló el canal de video. Suele ser la red: prueba con un hotspot propio."
        default:
            message = "Error de cámara: \(error)"
        }

        lastStreamError = message
        streamStatusMessage = "Error de cámara"
        DiagnosticLogger.shared.log(.error, tag: "Camera", message: message)
    }
    
    /// Inicia físicamente la transmisión de video tras validar permisos
    func startStream() async {
        guard let camera = camera else {
            lastStreamError = "No hay hardware de cámara disponible. Conecta las gafas primero."
            DiagnosticLogger.shared.log(.error, tag: "Camera", message: "Intento de iniciar cámara sin hardware asignado.")
            return
        }
        
        lastStreamError = nil
        streamStatusMessage = "Verificando permisos de cámara..."
        
        // 1. Verificar permisos locales de iOS
        let localCameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if localCameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        
        // 2. Verificar permisos de Wearables SDK
        do {
            let wearablesStatus = try await Wearables.shared.checkPermissionStatus(.camera)
            DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Estado de permiso de cámara Wearables: \(wearablesStatus)")
            
            if wearablesStatus != .granted {
                let requestResult = try await Wearables.shared.requestPermission(.camera)
                DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Resultado solicitud permiso: \(requestResult)")
                
                if requestResult != .granted {
                    lastStreamError = "Permiso de cámara rechazado. Habilítalo en la app Meta View."
                    DiagnosticLogger.shared.log(.warning, tag: "Camera", message: "Permiso de cámara en gafas rechazado por el usuario.")
                    streamStatusMessage = "Permiso denegado"
                    return
                }
            }
            
            // Iniciar stream físico. No marcamos `isStreaming` aquí: `start()` es
            // asíncrono y puede fallar por térmica, bisagras o red. La bandera la
            // pone `handleStreamState` cuando el SDK confirma `.streaming`.
            camera.stream.start()
            streamStatusMessage = "Iniciando cámara…"
            DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Solicitud de inicio de stream enviada. Esperando confirmación del dispositivo…")
            
        } catch {
            lastStreamError = "Error al solicitar permisos de cámara: \(error.localizedDescription)"
            DiagnosticLogger.shared.log(.error, tag: "Camera", message: "Excepción al iniciar cámara: \(error.localizedDescription)")
            streamStatusMessage = "Error al iniciar"
        }
    }
    
    /// Detiene la transmisión de video.
    ///
    /// Sin `guard isStreaming`: si la bandera quedó desincronizada (el stream murió
    /// por térmica o por bisagras y nadie la bajó), el guard impedía detenerlo de
    /// verdad y el stream seguía vivo consumiendo batería.
    func stopStream() {
        camera?.stream.stop()
        isStreaming = false
        currentFPS = 0.0
        streamStatusMessage = "Cámara detenida"
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Stream de cámara detenido.")
    }
    
    /// Procesa cada frame entrante y calcula el rendimiento FPS
    private func handleIncomingFrame(_ frame: VideoFrame) {
        // El escáner decide solo si le toca inspeccionar: descarta la mayoría
        // de los frames antes de tocar Vision, para no calentar las gafas.
        QRScanner.shared.inspect(frame.sampleBuffer)

        guard let uiImage = frame.makeUIImage() else { return }

        self.latestFrame = uiImage
        self.totalFramesReceived += 1
        self.frameCountSinceLastCheck += 1
        
        let now = Date()
        let interval = now.timeIntervalSince(lastFPSCalculationTime)
        
        if interval >= 1.0 {
            self.currentFPS = Double(frameCountSinceLastCheck) / interval
            self.frameCountSinceLastCheck = 0
            self.lastFPSCalculationTime = now
        }
    }
}
