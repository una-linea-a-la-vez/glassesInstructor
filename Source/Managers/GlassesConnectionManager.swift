import Foundation
import Combine
import UIKit
import Network
import AVFoundation
import MWDATCore
import MWDATDisplay
import MWDATCamera

/// Coordinador central del ciclo de vida y la conexión resiliente con las gafas Meta Ray-Ban Display
@MainActor
class GlassesConnectionManager: NSObject, ObservableObject {
    static let shared = GlassesConnectionManager()
    
    // Estado y Telemetría reactiva
    @Published var connectionState: ConnectionState = .disconnected
    @Published var telemetry: DeviceTelemetry = DeviceTelemetry()
    @Published var isSDKConfigured: Bool = false
    @Published var isConnecting: Bool = false

    /// Cuando es `true`, la UI debe cerrar cualquier vista activa y mostrar
    /// el aviso de gafas sin conexión. Todo depende del hardware, así que no
    /// tiene sentido dejar pantallas vivas sin enlace.
    @Published var isGlassesOffline: Bool = false
    @Published var offlineReason: String?
    
    // Managers subsidiarios
    let hudManager = HUDGridManager.shared
    let cameraManager = CameraStreamManager.shared
    let speechManager = SpeechAudioManager.shared
    let logger = DiagnosticLogger.shared
    
    private var session: DeviceSession?
    private var connectionTokens: [any AnyListenerToken] = []
    private var serviceBrowser: NetServiceBrowser?

    // Control de la ceremonia de registro con Meta AI
    private var awaitingRegistrationCallback = false
    private var registrationWatchdog: Timer?
    private var linkWatchTask: Task<Void, Never>?
    /// Distingue "el usuario desconectó" de "las gafas se cayeron".
    private var isIntentionalDisconnect = false

    /// Ticks de 500 ms que esperamos a que el SDK salga de `.unavailable`
    private static let registrationReadyTicks = 20
    /// Margen para que el usuario autorice en Meta AI y vuelva a la app
    private static let registrationCallbackTimeout: TimeInterval = 90
    
    private override init() {
        super.init()
        triggerLocalNetworkPermission()
        setupInterManagerWiring()
    }
    
    /// Conecta la actualización de texto de dictado con la pantalla HUD
    private func setupInterManagerWiring() {
        speechManager.onTranscriptUpdated = { [weak self] transcript in
            guard let self = self else { return }
            if self.hudManager.currentMode == .dictationMic {
                Task {
                    await self.hudManager.renderCurrentState()
                }
            }
        }
        
        hudManager.onModeSelected = { [weak self] newMode in
            guard let self = self else { return }
            Task {
                await self.handleModeSwitch(newMode)
            }
        }
    }
    
    /// Maneja las acciones secundarias al cambiar de modo (iniciar/detener streaming de cámara o audio)
    private func handleModeSwitch(_ mode: HUDMode) async {
        logger.log(.info, tag: "Mode", message: "Cambiando a modo: \(mode.rawValue)")
        
        switch mode {
        case .gridMenu:
            cameraManager.stopStream()
            speechManager.stopListening()
            
        case .cameraStream:
            speechManager.stopListening()
            // Sin sesión activa no hay hardware de cámara asignado todavía
            guard connectionState == .connected else {
                logger.log(.warning, tag: "Mode", message: "Modo cámara solicitado sin sesión activa. Conecta las gafas primero.")
                return
            }
            await cameraManager.startStream()
            
        case .dictationMic:
            cameraManager.stopStream()
            speechManager.startListening()
            
        case .deviceDiagnostics, .interactiveGuide:
            cameraManager.stopStream()
            speechManager.stopListening()
        }
    }
    
    /// Fuerza el prompt de permisos de Red Local en iOS 16+
    private func triggerLocalNetworkPermission() {
        logger.log(.info, tag: "Network", message: "Disparando paquete UDP multicast para activar diálogo de Red Local...")
        let connection = NWConnection(host: "224.0.0.251", port: 5353, using: .udp)
        connection.start(queue: .main)
        connection.send(content: "glasses_ping".data(using: .utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
        
        let browser = NetServiceBrowser()
        self.serviceBrowser = browser
        browser.searchForServices(ofType: "_mwdathud._tcp.", inDomain: "local.")
    }
    
    /// Flujo maestro de conexión paso a paso siguiendo las 7 Reglas de Oro
    func connectGlasses() async {
        guard !isConnecting else {
            logger.log(.warning, tag: "Connection", message: "Conexión ya en curso. Ignorando solicitud duplicada.")
            return
        }
        
        isConnecting = true
        defer { isConnecting = false }
        
        connectionState = .configuring
        logger.log(.info, tag: "Connection", message: "Iniciando secuencia de enlace con gafas...")
        
        do {
            // PASO 1: Configuración Lazy del SDK
            if !isSDKConfigured {
                logger.log(.info, tag: "SDK", message: "Paso 1: Configurando Wearables SDK bajo demanda...")
                try Wearables.configure()
                
                let regToken = Wearables.shared.addRegistrationStateListener { [weak self] state in
                    Task { @MainActor in
                        self?.handleRegistrationChange(state)
                    }
                }
                connectionTokens.append(regToken)
                isSDKConfigured = true
                logger.log(.success, tag: "SDK", message: "Wearables SDK configurado exitosamente.")
                
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            
            let wearables = Wearables.shared
            
            // PASO 2: Verificación de Registro Meta AI
            // El SDK arranca en .unavailable y tarda en poblar su estado real. Llamar a
            // startRegistration() mientras sigue en .unavailable deja el registro atorado
            // en .registering y el callback de Meta AI nunca regresa.
            var registration = wearables.registrationState
            logger.log(.info, tag: "Registration", message: "Paso 2: Estado de registro: \(registration.readableName)")

            if registration == .unavailable {
                logger.log(.info, tag: "Registration", message: "SDK aún no disponible. Esperando a que el registro se poble...")
                var ticks = 0
                while registration == .unavailable && ticks < Self.registrationReadyTicks {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    registration = wearables.registrationState
                    ticks += 1
                }
                logger.log(.info, tag: "Registration", message: "Estado tras esperar \(Double(ticks) * 0.5)s: \(registration.readableName)")
            }

            guard registration != .unavailable else {
                connectionState = .error
                telemetry.lastErrorDescription = "El SDK de Meta nunca estuvo disponible. Verifica que Meta AI esté instalada, que Bluetooth esté encendido y que Wearables DAT Developer Mode esté activo en Meta View."
                logger.log(.error, tag: "Registration", message: "Timeout: el registro no salió de .unavailable en \(Double(Self.registrationReadyTicks) * 0.5)s.")
                return
            }

            if registration != .registered {
                connectionState = .registeringMetaAI
                awaitingRegistrationCallback = true
                logger.log(.warning, tag: "Registration", message: "Abriendo Meta AI para autorizar esquema (estado actual: \(registration.readableName))...")
                try await wearables.startRegistration()
                // La secuencia continúa fuera de esta función: se reanuda desde
                // handleRegistrationChange o desde resumeAfterRegistrationCallback (.onOpenURL).
                scheduleRegistrationWatchdog()
                return
            }
            
            // PASO 3: Despertar Scanner Bluetooth
            connectionState = .scanning
            logger.log(.info, tag: "Discovery", message: "Paso 3: Suscribiendo listener para despertar Bluetooth Scanner...")
            
            let devToken = wearables.addDevicesListener { [weak self] devices in
                guard let self = self else { return }
                self.logger.log(.info, tag: "Discovery", message: "Dispositivos actualizados: \(devices.count) encontrados.")
            }
            connectionTokens.append(devToken)
            
            // PASO 4: Esperar a que el dispositivo esté en .connected
            connectionState = .linkConnecting
            logger.log(.info, tag: "Link", message: "Paso 4: Esperando linkState == .connected...")
            
            var attempts = 0
            var connectedDeviceId: DeviceIdentifier? = nil
            
            while attempts < 15 {
                if let firstId = wearables.devices.first,
                   let device = wearables.deviceForIdentifier(firstId) {
                    telemetry.deviceName = device.name
                    telemetry.linkState = "\(device.linkState)"
                    logger.log(.info, tag: "Link", message: "Dispositivo: \(device.name), LinkState: \(device.linkState)")
                    
                    if device.linkState == .connected {
                        connectedDeviceId = firstId
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 seg
                attempts += 1
            }
            
            guard let validDeviceId = connectedDeviceId,
                  wearables.deviceForIdentifier(validDeviceId) != nil else {
                connectionState = .error
                telemetry.lastErrorDescription = "No se detectaron gafas enlazadas por Bluetooth. Revisa que estén abiertas y puestas."
                logger.log(.error, tag: "Link", message: "Timeout buscando gafas o linkState != .connected.")
                return
            }
            
            // PASO 5: Crear e Iniciar DeviceSession
            connectionState = .sessionStarting
            logger.log(.info, tag: "Session", message: "Paso 5: Creando e iniciando DeviceSession...")
            
            let deviceSession: DeviceSession
            if let existing = self.session {
                deviceSession = existing
            } else {
                deviceSession = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: validDeviceId))
                self.session = deviceSession
                
                let sessionToken = deviceSession.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.handleSessionState(state)
                    }
                }
                connectionTokens.append(sessionToken)
                
                let errorToken = deviceSession.errorPublisher.listen { [weak self] err in
                    Task { @MainActor in
                        self?.logger.log(.error, tag: "Session", message: "Error de sesión: \(err)")
                    }
                }
                connectionTokens.append(errorToken)
            }
            
            if deviceSession.state != .started && deviceSession.state != .starting {
                try deviceSession.start()
            }
            
            // Esperar a que la sesión complete el handshake criptográfico
            var sessionAttempts = 0
            while deviceSession.state == .starting && sessionAttempts < 12 {
                logger.log(.info, tag: "Session", message: "Esperando handshake... (Intento \(sessionAttempts + 1))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                sessionAttempts += 1
            }
            
            guard deviceSession.state == .started else {
                throw DeviceSessionError.unexpectedError(description: "La sesión no pudo entrar en estado .started")
            }
            
            logger.log(.success, tag: "Session", message: "Sesión establecida con éxito.")
            
            // PASO 6: Adjuntar Display Capability
            logger.log(.info, tag: "Display", message: "Paso 6: Adjuntando canal de pantalla (Display)...")
            let displayCapability = try deviceSession.addDisplay()
            hudManager.attachDisplayCapability(displayCapability)
            telemetry.isDisplayReady = true
            
            // PASO 7: Adjuntar Camera Capability
            logger.log(.info, tag: "Camera", message: "Paso 7: Adjuntando canal de cámara...")
            if let cameraCapability = try deviceSession.addCamera() {
                cameraManager.attachCameraCapability(cameraCapability)
            }
            
            // Vigilancia del enlace: térmica y caídas inesperadas
            startLinkWatch(for: validDeviceId)

            // PASO 8: Renderizar Menú Cuadrícula en el HUD
            isGlassesOffline = false
            offlineReason = nil
            connectionState = .connected
            logger.log(.success, tag: "HUD", message: "Paso 8: Renderizando Menú Cuadrícula 2x2 en las gafas.")
            await hudManager.switchMode(.gridMenu)
            
        } catch {
            connectionState = .error
            telemetry.lastErrorDescription = error.localizedDescription
            logger.log(.error, tag: "Connection", message: "Fallo durante la secuencia: \(error.localizedDescription)")
        }
    }
    
    /// Desconecta limpiamente la sesión y libera los canales
    func disconnectGlasses() {
        logger.log(.warning, tag: "Connection", message: "Desconectando gafas y liberando recursos...")

        // El estado baja ANTES del teardown: `session.stop()` hace que el SDK emita
        // `.stopped` de forma asíncrona, y si en ese momento el estado siguiera en
        // `.connected` se interpretaría como una caída y saldría el aviso de "sin
        // conexión" justo cuando el usuario pidió desconectar.
        isIntentionalDisconnect = true
        connectionState = .disconnected
        isGlassesOffline = false
        offlineReason = nil

        teardownEverything()

        // La bandera se limpia tras dar tiempo al callback asíncrono del SDK.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.isIntentionalDisconnect = false
        }

        logger.log(.info, tag: "Connection", message: "Desconexión completada.")
    }

    /// Corte de emergencia: las gafas se fueron sin avisar (se plegaron, se
    /// guardaron, salieron de rango o murió la sesión).
    ///
    /// Todo en esta app depende del hardware, así que dejar corriendo la cámara,
    /// el escáner o el micrófono tras perder el enlace solo produce errores en
    /// cascada y consume batería. Se apaga todo y la UI muestra un único mensaje.
    func handleUnexpectedDisconnection(reason: String) {
        // Ignorar si la desconexión la pidió el usuario, y no degradar un estado
        // que ya estaba caído.
        guard !isIntentionalDisconnect else { return }
        guard connectionState != .disconnected, !isGlassesOffline else { return }

        logger.log(.error, tag: "Connection", message: "Enlace perdido: \(reason)")
        teardownEverything()

        connectionState = .error
        telemetry.lastErrorDescription = reason
        offlineReason = reason
        isGlassesOffline = true
    }

    /// Cierra el aviso y deja la app lista para reconectar.
    func dismissOfflineBanner() {
        isGlassesOffline = false
        offlineReason = nil
        connectionState = .disconnected
    }

    /// Apaga en orden todo lo que consume el enlace con las gafas.
    private func teardownEverything() {
        clearRegistrationWatchdog()
        linkWatchTask?.cancel()
        linkWatchTask = nil

        // El escáner primero: deja de pedir frames que ya no van a llegar.
        QRScanner.shared.stop()
        PhoneQRSession.shared.stop()

        // El narrador, para que no siga hablando sobre una pantalla muerta.
        AvatarNarrator.shared.stop()

        cameraManager.detachCamera()
        hudManager.detachDisplay()
        speechManager.stopListening()

        connectionTokens.removeAll()
        session?.stop()
        session = nil

        telemetry.isDisplayReady = false
        telemetry.isCameraStreaming = false
    }
    
    private func handleRegistrationChange(_ state: RegistrationState) {
        logger.log(.info, tag: "Registration", message: "Estado de registro actualizado: \(state.readableName)")

        guard state == .registered else { return }
        guard awaitingRegistrationCallback || connectionState == .registeringMetaAI else { return }

        clearRegistrationWatchdog()
        logger.log(.success, tag: "Registration", message: "Registro completado. Reanudando secuencia de conexión...")
        Task {
            await connectGlasses()
        }
    }

    /// Reanuda la conexión cuando Meta AI devuelve el control por URL scheme.
    /// El listener de estado no siempre dispara al volver a foreground, así que el
    /// callback también reanuda: sin esto la secuencia muere tras el registro.
    func resumeAfterRegistrationCallback() async {
        let state = Wearables.shared.registrationState
        logger.log(.info, tag: "Registration", message: "Callback de Meta AI recibido. Estado: \(state.readableName)")

        guard awaitingRegistrationCallback else { return }
        clearRegistrationWatchdog()

        guard state == .registered else {
            connectionState = .error
            telemetry.lastErrorDescription = "Meta AI devolvió el control pero el registro quedó en \(state.readableName). Vuelve a pulsar Conectar."
            logger.log(.error, tag: "Registration", message: "Callback sin registro completo: \(state.readableName)")
            return
        }

        await connectGlasses()
    }

    /// Aborta la espera si Meta AI nunca devuelve la autorización
    private func scheduleRegistrationWatchdog() {
        registrationWatchdog?.invalidate()
        registrationWatchdog = Timer.scheduledTimer(withTimeInterval: Self.registrationCallbackTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.awaitingRegistrationCallback else { return }
                self.awaitingRegistrationCallback = false
                self.registrationWatchdog = nil
                self.connectionState = .error
                self.telemetry.lastErrorDescription = "Meta AI no devolvió la autorización en \(Int(Self.registrationCallbackTimeout))s. Abre Meta View > Ajustes > Acerca de, toca 7 veces la versión y activa Wearables DAT Developer Mode."
                self.logger.log(.error, tag: "Registration", message: "Watchdog: sin callback de Meta AI tras \(Int(Self.registrationCallbackTimeout))s. Secuencia abortada.")
            }
        }
    }

    private func clearRegistrationWatchdog() {
        awaitingRegistrationCallback = false
        registrationWatchdog?.invalidate()
        registrationWatchdog = nil
    }
    
    private func handleSessionState(_ state: DeviceSessionState) {
        logger.log(.info, tag: "Session", message: "Estado de sesión cambió a: \(state)")

        switch state {
        case .stopped:
            // Solo es una caída si veníamos conectados y nadie pidió desconectar.
            // Si el estado ya bajó, la desconexión fue intencional: no hay nada
            // que hacer aquí (llamar a `disconnectGlasses()` sería recursivo).
            if connectionState == .connected && !isIntentionalDisconnect {
                handleUnexpectedDisconnection(
                    reason: "Se perdió el enlace con las gafas. Revisa que estén abiertas, puestas y con batería.")
            }

        case .paused:
            // Ocurre al plegarlas o guardarlas en el estuche.
            handleUnexpectedDisconnection(
                reason: "Las gafas pausaron la sesión. Ábrelas y póntelas para continuar.")

        default:
            break
        }
    }

    /// Vigila el enlace físico mientras la sesión está viva. `deviceStateStream`
    /// también entrega el nivel térmico, que es la otra causa de corte.
    private func startLinkWatch(for deviceId: DeviceIdentifier) {
        linkWatchTask?.cancel()
        linkWatchTask = Task { [weak self] in
            guard let self else { return }
            for await deviceState in Wearables.shared.deviceStateStream(for: deviceId) {
                if Task.isCancelled { return }
                await self.handleThermal(deviceState.thermalLevel)
            }
        }
    }

    /// El firmware corta el video solo al llegar a crítico. Avisar antes evita
    /// que la app parezca rota cuando en realidad son las gafas protegiéndose.
    private func handleThermal(_ level: ThermalLevel) {
        telemetry.thermalLevel = "\(level)"

        switch level {
        case .severe:
            logger.log(.warning, tag: "Thermal",
                       message: "Las gafas se están calentando. Reduciendo actividad.")
            QRScanner.shared.stop()

        case .critical, .emergency, .shutdown:
            handleUnexpectedDisconnection(
                reason: "Las gafas se sobrecalentaron y cortaron la sesión. Déjalas enfriar un minuto.")

        default:
            break
        }
    }
}

/// El SDK imprime `RegistrationState(rawValue: 2)`, que no dice nada al depurar en campo.
/// Estos nombres hacen que el log del teléfono sea legible sin consultar el binario.
extension RegistrationState {
    var readableName: String {
        switch self {
        case .unavailable: return "unavailable(0) · SDK aún no listo"
        case .available: return "available(1) · listo para registrar"
        case .registering: return "registering(2) · esperando callback de Meta AI"
        case .registered: return "registered(3) · autorizado"
        @unknown default: return "desconocido(\(rawValue))"
        }
    }
}
