import Foundation
import UIKit
import Combine
import CoreImage
import Vision
import MWDATCore
import MWDATCamera
import AVFoundation

/// De qué cámara tiene que salir la imagen donde se busca el QR.
enum QRScanSource {
    /// Gafas si están vinculadas; el teléfono si no. El teléfono entra además de
    /// relevo si las gafas llevan un rato sin leer nada.
    case automatic
    /// Solo las gafas. Sin relevo: quien elige las gafas no quiere ver el visor
    /// del teléfono adelantarse.
    case glasses
    /// Solo el teléfono.
    case phone
}

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
    /// Techo de seguridad, no el ritmo real: quien marca el ritmo es el candado
    /// `isDetectingQR`, que deja una sola detección en vuelo.
    ///
    /// Estaba en 0.25 s (4 por segundo) y eso tiraba 26 de cada 30 frames. Con la
    /// cámara en la cabeza casi todos salen movidos y solo unos pocos son nítidos:
    /// descartando el 87% se descartaban justo los buenos. GlassesAgentApp mira
    /// todos los frames que le llegan, y ahí el código sí se lee.
    private static let qrInspectionInterval: TimeInterval = 0.05
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

    /// Cámara que está buscando el QR ahora mismo, para que la UI no lo adivine.
    @Published private(set) var activeQRSource: QRScanSource = .automatic

    /// Cuenta atrás para que el teléfono entre de relevo en `.automatic`.
    private var phoneFallbackTask: Task<Void, Never>?

    /// Cuánto aguantan las gafas solas antes de que entre el teléfono.
    ///
    /// Suficiente para que el stream arranque (el watchdog de frames espera 6 s) y
    /// para reencuadrar un par de veces.
    private static let phoneFallbackDelay: TimeInterval = 12
    
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
                } else if self.qrFramesInspected % 40 == 0 {
                    // Sin esto, "N frames y no lee" no dice si falta resolución o
                    // falta encuadre. El tamaño del frame distingue los dos casos.
                    let w = image.cgImage?.width ?? 0
                    let h = image.cgImage?.height ?? 0
                    DiagnosticLogger.shared.log(.warning, tag: "QR",
                        message: "\(self.qrFramesInspected) inspecciones sin leer el código. Frame \(w)x\(h). Acerca el código o céntralo: la cámara de las gafas es gran angular.")
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
            
            // Dejar respirar el canal antes de pedir video.
            //
            // Portado de GlassesAgentApp, donde el escaneo si funciona: el enlace es
            // uno solo y el HUD acaba de enviar su render. Arrancar el stream encima
            // lo satura y el SDK lo mata con videoStreamingError, que es exactamente
            // el starting -> stopping que veniamos viendo.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.camera != nil else { return }

            // No marcamos `isStreaming` aquí: `start()` es asíncrono y puede fallar
            // por térmica, bisagras o red. La bandera la pone `handleStreamState`
            // cuando el SDK confirma `.streaming`.
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

        // El disparo exige el canal de video vivo: sin el, capturePhoto devuelve
        // false y las gafas "rechazan la captura". Se enciende solo para la foto y
        // se apaga enseguida, que es una rafaga corta y no calienta como el stream
        // sostenido. En platanus-ios-working la foto tambien sale con stream activo.
        let hadStream = isStreaming
        if !hadStream {
            camera.stream.start()
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        defer {
            if !hadStream { camera.stream.stop() }
        }
        
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
    
    /// Arranca la búsqueda de QR en la cámara que se pida.
    ///
    /// **Por qué hay una fuente explícita.** Antes las dos cámaras arrancaban a la
    /// vez y ganaba la primera que detectara. En la práctica ganaba siempre el
    /// teléfono: `AVCaptureMetadataOutput` detecta en cuanto la sesión abre,
    /// mientras el stream de las gafas tarda segundos en entregar el primer frame.
    /// Resultado: elegías "Gafas" en el selector y el escaneo lo acababa haciendo
    /// el teléfono. El respaldo del teléfono existe para que una demostración no se
    /// quede sin nada que mostrar, no para adelantarse a las gafas.
    func startQRScanning(source: QRScanSource = .automatic) async {
        let resolved: QRScanSource
        switch source {
        case .phone:
            resolved = .phone
        case .glasses where camera == nil:
            DiagnosticLogger.shared.log(.warning, tag: "QR",
                message: "Se pidió escanear con las gafas, pero no hay cámara vinculada. Escanea el teléfono.")
            resolved = .phone
        case .glasses:
            resolved = .glasses
        case .automatic:
            resolved = camera != nil ? .glasses : .phone
        }

        activeQRSource = resolved
        qrFramesInspected = 0
        bindPhoneScannerFallback()

        guard resolved == .glasses else {
            DiagnosticLogger.shared.log(.info, tag: "QR",
                message: "Buscando QR con la cámara del teléfono.")
            await startPhoneScanner()
            return
        }

        isScanningQR = true
        DiagnosticLogger.shared.log(.info, tag: "QR", message: "Buscando QR con las gafas...")
        // Quien lleva puestas las gafas no ve el teléfono: si el HUD no dice
        // nada, encender la cámara (que tarda) parece que el botón no hizo nada.
        ProjectAuditAgent.shared.statusLine = "Iniciando cámara..."
        await HUDGridManager.shared.renderCurrentState(force: true, duringScan: true)
        let framesBefore = totalFramesReceived
        await startStream()
        startFrameWatchdog(from: framesBefore)

        // Solo en automático. Si la fuente es `.glasses`, es una elección del
        // usuario y nadie la pisa por su cuenta.
        if resolved == .glasses, source == .automatic {
            startPhoneFallbackTimer()
        }
    }

    /// Enciende la cámara del teléfono, si iOS lo permite en este momento.
    ///
    /// iOS no abre `AVCaptureSession` en segundo plano, y el intento no falla en
    /// silencio: escupe el assert de CoreMedia `FigCaptureSourceRemote ... err=-17281`,
    /// que parece un fallo de las gafas y no lo es.
    private func startPhoneScanner() async {
        guard UIApplication.shared.applicationState == .active else {
            DiagnosticLogger.shared.log(.info, tag: "QR",
                message: "App en segundo plano: iOS no abre la cámara del teléfono fuera de primer plano.")
            return
        }
        await PhoneQRSession.shared.start()
    }

    /// El teléfono entra de relevo solo si las gafas llevan `phoneFallbackDelay`
    /// sin leer nada, para que el fallo de una cámara no deje al usuario a pie.
    private func startPhoneFallbackTimer() {
        phoneFallbackTask?.cancel()
        phoneFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.phoneFallbackDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isScanningQR else { return }
            DiagnosticLogger.shared.log(.info, tag: "QR",
                message: "\(Int(Self.phoneFallbackDelay))s sin leer con las gafas: entra la cámara del teléfono como relevo.")
            await self.startPhoneScanner()
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
    
    /// Escanea un QR con **una sola foto**, sin encender el stream.
    ///
    /// Es la via que se puede disparar desde un boton del HUD: el usuario mira el
    /// codigo, activa el boton en las gafas y se toma una foto. No depende del canal
    /// de video continuo, que es justo el que viene fallando, y ademas no calienta.
    /// La foto sale a resolucion completa, que para un QR importa mas que los fps.
    @discardableResult
    func scanQRFromPhoto() async -> String? {
        // Todo el recorrido se cuenta en el HUD. Antes fallaba en silencio: el toque
        // se sentia, la accion se disparaba y moria sin que las gafas dijeran nada,
        // asi que parecia que el boton no hacia nada.
        func report(_ text: String) async {
            ProjectAuditAgent.shared.statusLine = text
            await HUDGridManager.shared.renderCurrentState(force: true, duringScan: true)
        }

        guard camera != nil else {
            DiagnosticLogger.shared.log(.error, tag: "QR", message: "Escaneo por foto sin cámara asignada.")
            await report("Sin cámara. ¿Están conectadas?")
            return nil
        }

        DiagnosticLogger.shared.log(.info, tag: "QR", message: "Escaneo por foto: capturando...")
        await report("Tomando foto...")

        let jpeg: Data
        do {
            jpeg = try await capturePhotoOnce()
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "QR", message: "No se pudo tomar la foto: \(error.localizedDescription)")
            await report("No se pudo tomar la foto")
            return nil
        }

        guard let image = UIImage(data: jpeg) else {
            DiagnosticLogger.shared.log(.error, tag: "QR", message: "La foto no se pudo decodificar.")
            await report("Foto ilegible")
            return nil
        }

        await report("Buscando el código...")

        let payload = await Task.detached(priority: .userInitiated) {
            Self.detectQRCode(in: image)
        }.value

        guard let payload else {
            DiagnosticLogger.shared.log(.warning, tag: "QR", message: "No habia ningun QR legible en la foto.")
            await report("No vi ningún código. Acércate.")
            return nil
        }

        DiagnosticLogger.shared.log(.success, tag: "QR", message: "QR leido de la foto: \(payload)")
        await report("¡Código leído!")
        onQRDetected?(payload)
        return payload
    }

    /// Detiene el escaneo y apaga el canal de video.
    ///
    /// Antes dejaba el stream vivo, y eso costaba dos veces: las gafas seguían
    /// calentando hasta el corte térmico con nadie mirando los frames, y al volver a
    /// escanear se llamaba `stream.start()` sobre un stream ya activo, que es la
    /// forma más rápida de que el segundo intento no arranque.
    func stopQRScanning() {
        phoneFallbackTask?.cancel()
        phoneFallbackTask = nil
        // El teléfono puede estar escaneando solo, con `isScanningQR` en false:
        // con el guard antiguo, parar dejaba su cámara encendida.
        guard isScanningQR || PhoneQRSession.shared.isRunning else { return }
        isScanningQR = false
        frameWatchdog?.cancel()
        frameWatchdog = nil
        PhoneQRSession.shared.stop()
        stopStream()
        DiagnosticLogger.shared.log(.info, tag: "QR", message: "Escaneo de QR detenido.")
    }
    
    private func handleDetectedQR(_ payload: String) {
        guard isScanningQR || PhoneQRSession.shared.isRunning else { return }
        isScanningQR = false
        phoneFallbackTask?.cancel()
        phoneFallbackTask = nil
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

        // 1. El frame entero.
        if let payload = visionPayload(in: cgImage) { return payload }

        // 2. El centro, ampliado.
        //
        // La cámara de las gafas es gran angular: el usuario cree que está
        // "apuntando" al código, pero el QR acaba ocupando una porción diminuta del
        // encuadre. Vision reescala internamente la imagen antes de buscar, y ahí un
        // QR pequeño se queda sin módulos que resolver — se inspeccionan cientos de
        // frames y no se lee ninguno. Recortar el centro y ampliarlo no inventa
        // píxeles, pero sube la proporción que ocupa el código y con eso sí entra.
        if let zoomed = centerCrop(cgImage, fraction: 0.5, scale: 2.0),
           let payload = visionPayload(in: zoomed) { return payload }

        // 3. Respaldo: en algunos frames muy contrastados CIDetector todavía acierta
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

    nonisolated private static func visionPayload(in cgImage: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .first(where: { !$0.isEmpty })
    }

    /// Recorta la porción central del frame y la reescala.
    nonisolated private static func centerCrop(_ cgImage: CGImage,
                                               fraction: CGFloat,
                                               scale: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropWidth = (width * fraction).rounded()
        let cropHeight = (height * fraction).rounded()
        guard cropWidth >= 1, cropHeight >= 1 else { return nil }

        let rect = CGRect(x: ((width - cropWidth) / 2).rounded(),
                          y: ((height - cropHeight) / 2).rounded(),
                          width: cropWidth, height: cropHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }

        let targetWidth = Int(cropWidth * scale)
        let targetHeight = Int(cropHeight * scale)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return cropped }

        // Escala de grises + interpolación alta: es lo que come el binarizador de
        // Vision, y de paso quita el ruido de color del sensor.
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? cropped
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
