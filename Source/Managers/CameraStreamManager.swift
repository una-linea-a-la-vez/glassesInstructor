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
    
    /// Configuración del stream. Es la palanca directa de latencia sobre el enlace inalámbrico:
    /// `hvc1` va comprimido por hardware (`raw` satura el canal) y bajar resolución/FPS reduce
    /// el bitrate. Súbelo a `.high` / 30 si prefieres calidad sobre respuesta.
    static let streamConfiguration = StreamConfiguration(
        videoCodec: .hvc1,
        resolution: .medium,
        frameRate: 24
    )
    
    private var camera: Camera?
    private var streamTokens: [any AnyListenerToken] = []
    
    /// Descarta frames mientras haya una decodificación en vuelo, para no acumular retraso.
    private var isDecodingFrame: Bool = false
    
    private var frameCountSinceLastCheck: Int = 0
    private var lastFPSCalculationTime: Date = Date()
    
    private init() {}
    
    /// Asigna la capacidad de cámara proveniente de la sesión de MWDAT
    func attachCameraCapability(_ cameraCapability: Camera) {
        self.camera = cameraCapability
        setupStreamListeners(cameraCapability)
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Capacidad de cámara vinculada a la sesión.")
    }
    
    /// Desvincula y limpia la cámara
    func detachCamera() {
        stopStream()
        streamTokens.removeAll()
        camera = nil
        latestFrame = nil
        currentFPS = 0.0
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Capacidad de cámara desvinculada.")
    }
    
    /// Configura los listeners del flujo de video y errores del stream
    private func setupStreamListeners(_ cameraCapability: Camera) {
        streamTokens.removeAll()
        
        // 1. Frame Listener
        let frameToken = cameraCapability.stream.videoFramePublisher.listen { [weak self] frame in
            guard let self = self else { return }
            Task { @MainActor in
                // Si la decodificación anterior sigue en curso vamos por detrás del stream:
                // descartar es preferible a encolar y acumular latencia.
                guard !self.isDecodingFrame else { return }
                self.isDecodingFrame = true
                
                // `VideoFrame` es Sendable y `makeUIImage()` devuelve `sending`, así que la
                // decodificación (lo caro) sale del main actor y sólo volvemos para publicar.
                let image = await Task.detached(priority: .userInitiated) {
                    frame.makeUIImage()
                }.value
                
                self.isDecodingFrame = false
                guard let image else { return }
                self.publishFrame(image)
            }
        }
        streamTokens.append(frameToken)
        
        // 2. Error Listener
        let errorToken = cameraCapability.stream.errorPublisher.listen { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor in
                self.lastStreamError = "\(error)"
                DiagnosticLogger.shared.log(.error, tag: "Camera", message: "Error en stream de video: \(error)")
            }
        }
        streamTokens.append(errorToken)
        
        // 3. State Listener
        let stateToken = cameraCapability.stream.statePublisher.listen { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor in
                DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Estado de stream de cámara: \(state)")
            }
        }
        streamTokens.append(stateToken)
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
            
            // Iniciar stream físico
            camera.stream.start()
            isStreaming = true
            streamStatusMessage = "Transmitiendo en vivo"
            frameCountSinceLastCheck = 0
            lastFPSCalculationTime = Date()
            DiagnosticLogger.shared.log(.success, tag: "Camera", message: "Stream de cámara frontal iniciado correctamente.")
            
        } catch {
            lastStreamError = "Error al solicitar permisos de cámara: \(error.localizedDescription)"
            DiagnosticLogger.shared.log(.error, tag: "Camera", message: "Excepción al iniciar cámara: \(error.localizedDescription)")
            streamStatusMessage = "Error al iniciar"
        }
    }
    
    /// Detiene la transmisión de video
    func stopStream() {
        guard isStreaming else { return }
        camera?.stream.stop()
        isStreaming = false
        currentFPS = 0.0
        streamStatusMessage = "Cámara detenida"
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Stream de cámara detenido.")
    }
    
    /// Publica el frame ya decodificado y calcula el rendimiento FPS
    private func publishFrame(_ uiImage: UIImage) {
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
