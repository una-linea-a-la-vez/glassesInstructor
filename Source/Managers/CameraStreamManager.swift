import Foundation
import UIKit
import Combine
import CoreImage
import Vision
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
    
    /// Cuando está activo, cada frame decodificado se inspecciona en busca de códigos QR.
    @Published var isScanningQR: Bool = false
    
    /// Se invoca una sola vez por detección, con el contenido del QR. El escaneo se detiene solo.
    var onQRDetected: ((String) -> Void)?

    /// Candado propio del detector: sin él, cada frame lanzaba una detección
    /// nueva aunque la anterior siguiera corriendo.
    private var isDetectingQR = false
    private var lastQRInspection = Date.distantPast
    /// 4 inspecciones por segundo bastan para que el escaneo se sienta inmediato
    /// sin poner la CPU (y la térmica de las gafas) al límite.
    private static let qrInspectionInterval: TimeInterval = 0.25
    /// Visible en la UI para saber si el detector está recibiendo algo.
    @Published private(set) var qrFramesInspected: Int = 0
    
    /// Configuración del stream. `nil` significa usar la del SDK.
    ///
    /// La del SDK es la que el repo traía al principio (`addCamera()` sin argumentos)
    /// y es la única que se ha visto abrir el canal de verdad. Las configuraciones
    /// explícitas que se probaron después (`.medium`/24 fps buscando latencia, y luego
    /// `.high`/15 fps buscando píxeles para el QR) mueren igual: el stream pasa de
    /// `starting` a `stopping` con `videoStreamingError` y no llega ni un frame.
    /// Un stream que no entrega nada no decodifica ningún QR, por buena que sea su
    /// resolución sobre el papel.
    ///
    /// Si hace falta tunear, la escalera de `platanus-ios-working` (en el monoRepo)
    /// va de menos a más exigente y está probada en este mismo hardware:
    /// `(.hvc1, .medium, 7)` → `(.hvc1, .low, 8)` → `(.raw, .medium, 7)` → `(.raw, .low, 8)`.
    /// Fíjate en los fps: 7-8, no 15 ni 24.
    static let streamConfiguration: StreamConfiguration? = nil
    
    private var camera: Camera?
    private var streamTokens: [any AnyListenerToken] = []
    
    /// Descarta frames mientras haya una decodificación en vuelo, para no acumular retraso.
    private var isDecodingFrame: Bool = false
    
    /// Evita disparar dos capturas de foto solapadas.
    private var isCapturingPhoto: Bool = false
    
    /// Vigila que lleguen frames tras arrancar el escaneo.
    private var frameWatchdog: Task<Void, Never>?
    
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
        // `Camera` es dueña del recurso de hardware: sin `stop()` el firmware lo
        // mantiene tomado y el siguiente `addCamera()` falla. Ésta era la causa
        // de que la cámara fallara más en el segundo intento que en el primero.
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

                // Detección de QR con freno propio.
                //
                // Antes el candado `isDecodingFrame` se soltaba justo arriba, así que
                // a 30 fps se lanzaban decenas de detecciones Vision en paralelo: se
                // saturaban entre sí, ninguna terminaba a tiempo y de paso calentaban
                // el equipo. Ahora hay un candado propio para la detección y un techo
                // de frecuencia: basta con mirar unos pocos frames por segundo.
                guard self.isScanningQR, !self.isDetectingQR else { return }

                let now = Date()
                guard now.timeIntervalSince(self.lastQRInspection) >= Self.qrInspectionInterval else { return }
                self.lastQRInspection = now
                self.isDetectingQR = true

                let payload = await Task.detached(priority: .userInitiated) {
                    Self.detectQRCode(in: image)
                }.value

                self.isDetectingQR = false
                self.qrFramesInspected += 1

                if let payload {
                    self.handleDetectedQR(payload)
                }
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

    /// Sincroniza la bandera con lo que reporta el SDK. Antes `isStreaming` se
    /// ponía en `true` nada más llamar a `start()`, así que la UI decía
    /// "Transmitiendo" aunque el stream nunca hubiera arrancado.
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

    /// Traduce los errores del SDK a algo accionable. `hingesClosed` y los
    /// térmicos son los que más aparecen en pruebas de escritorio.
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
    
    /// Captura **una** foto sin encender el stream continuo.
    ///
    /// Es la forma correcta de analizar el ambiente: el streaming sostenido lleva las gafas
    /// al corte térmico (`thermalCritical`) y se apagan solas a media demo. Una foto puntual
    /// no calienta.
    func capturePhotoOnce(timeoutSeconds: Double = 15) async throws -> Data {
        guard let camera else {
            throw NSError(domain: "GlassesInstructor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Conecta las gafas antes de tomar una foto."])
        }
        
        while isCapturingPhoto {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        isCapturingPhoto = true
        defer { isCapturingPhoto = false }
        
        DiagnosticLogger.shared.log(.info, tag: "Photo", message: "Capturando foto del ambiente...")
        
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            var token: (any AnyListenerToken)?
            
            token = camera.stream.photoDataPublisher.listen { photo in
                Task { @MainActor in
                    _ = token          // mantiene vivo el token hasta que llega la foto
                    box.finish(.success(photo.data))
                }
            }
            
            guard camera.stream.capturePhoto(format: .jpeg) else {
                box.finish(.failure(NSError(domain: "GlassesInstructor", code: 11,
                                            userInfo: [NSLocalizedDescriptionKey: "Las gafas rechazaron la captura."])))
                return
            }
            
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                box.finish(.failure(NSError(domain: "GlassesInstructor", code: 12,
                                            userInfo: [NSLocalizedDescriptionKey: "La foto no llegó en \(Int(timeoutSeconds))s."])))
            }
        }
    }
    
    /// Arranca el stream en modo escaneo de QR (reutiliza los permisos de `startStream`).
    /// Arranca la búsqueda de QR en **las dos cámaras a la vez**.
    ///
    /// Antes solo usaba las gafas cuando estaban conectadas, así que si su cámara
    /// no lograba leer el código (poca luz, ángulo, stream a medias) no había
    /// forma de que el teléfono ayudara. Ahora gana la primera que detecte.
    func startQRScanning() async {
        isScanningQR = true
        bindPhoneScannerFallback()

        // El teléfono siempre participa: es la cámara que el usuario puede apuntar
        // con precisión y la que sigue viva si el enlace se cae.
        await PhoneQRSession.shared.start()

        if camera != nil {
            DiagnosticLogger.shared.log(.info, tag: "QR",
                message: "Buscando QR con las gafas y con el teléfono...")
            let framesBefore = totalFramesReceived
            await startStream()
            startFrameWatchdog(from: framesBefore)
        } else {
            DiagnosticLogger.shared.log(.info, tag: "QR",
                message: "Sin gafas: buscando QR con la cámara del teléfono.")
        }
    }

    /// Avisa si el stream dice estar activo pero no llega ni un frame.
    ///
    /// Es el fallo mas confuso del sistema: las gafas encienden el LED, el SDK reporta
    /// `streaming` y aun asi el telefono no recibe nada, porque el video viaja por
    /// Wi-Fi y muchas redes institucionales aislan a los clientes entre si.
    private func startFrameWatchdog(from baseline: Int) {
        frameWatchdog?.cancel()
        frameWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.isScanningQR else { return }
            
            let received = self.totalFramesReceived - baseline
            if received == 0 {
                DiagnosticLogger.shared.log(.error, tag: "Camera",
                    message: "6 s en 'streaming' y 0 frames recibidos. El video no esta llegando: prueba con un hotspot propio en vez de la red del recinto.")
            } else {
                DiagnosticLogger.shared.log(.info, tag: "Camera",
                    message: "\(received) frames en 6 s. \(self.qrFramesInspected) inspecciones de QR.")
            }
        }
    }
    
    /// Detiene el escaneo sin necesariamente cortar el stream.
    func stopQRScanning() {
        guard isScanningQR else { return }
        isScanningQR = false
        frameWatchdog?.cancel()
        frameWatchdog = nil
        PhoneQRSession.shared.stop()
        DiagnosticLogger.shared.log(.info, tag: "QR", message: "Escaneo de QR detenido.")
    }
    
    private func handleDetectedQR(_ payload: String) {
        guard isScanningQR else { return }
        isScanningQR = false
        stopStream()
        PhoneQRSession.shared.stop()
        DiagnosticLogger.shared.log(.success, tag: "QR", message: "Código QR detectado: \(payload)")
        onQRDetected?(payload)
    }

    /// Enlaza el escáner del teléfono con el mismo manejador que usan las gafas,
    /// para que el resto de la app no tenga que saber de dónde vino el código.
    func bindPhoneScannerFallback() {
        PhoneQRSession.shared.onDetect = { [weak self] url in
            self?.handleDetectedQR(url.absoluteString)
        }
    }
    
    /// Busca un QR en el frame de las gafas.
    ///
    /// Usa Vision en vez de `CIDetector`: aguanta mucho mejor los frames movidos,
    /// con poca luz o en ángulo, que es exactamente lo que produce una cámara
    /// montada en la cabeza. `CIDetector` fallaba salvo con el código muy quieto
    /// y de frente.
    nonisolated private static func detectQRCode(in image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        if let payload = (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .first(where: { !$0.isEmpty }) {
            return payload
        }

        // Respaldo: en algunos frames muy contrastados CIDetector todavía acierta
        // donde Vision no, así que se prueban los dos antes de descartar.
        let ciImage = CIImage(cgImage: cgImage)
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else { return nil }

        for feature in detector.features(in: ciImage) {
            if let qr = feature as? CIQRCodeFeature, let message = qr.messageString {
                return message
            }
        }
        return nil
    }
    
    /// Detiene la transmisión de video
    func stopStream() {
        // Sin `guard isStreaming`: si la bandera quedó desincronizada (el stream
        // murió por térmica o por bisagras y nadie la bajó), el guard impedía
        // detenerlo de verdad y seguía vivo consumiendo batería.
        camera?.stream.stop()
        isStreaming = false
        currentFPS = 0.0
        streamStatusMessage = "Cámara detenida"
        DiagnosticLogger.shared.log(.info, tag: "Camera", message: "Stream de cámara detenido.")
    }
    
    /// Publica el frame ya decodificado y calcula el rendimiento FPS
    private func publishFrame(_ uiImage: UIImage) {
        // El primer frame es el dato que faltaba para diagnosticar: el estado
        // "streaming" del SDK solo dice que las gafas capturan, no que los frames
        // lleguen al telefono por Wi-Fi.
        if totalFramesReceived == 0 {
            let size = uiImage.size
            DiagnosticLogger.shared.log(.success, tag: "Camera",
                message: "Primer frame recibido (\(Int(size.width))x\(Int(size.height))). El canal de video SI llega.")
        }
        
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


/// Garantiza que una `CheckedContinuation` se reanude exactamente una vez, aunque compitan
/// la llegada de la foto y el temporizador de timeout.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()
    
    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }
    
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        
        guard let pending else { return }
        switch result {
        case .success(let data): pending.resume(returning: data)
        case .failure(let error): pending.resume(throwing: error)
        }
    }
}
