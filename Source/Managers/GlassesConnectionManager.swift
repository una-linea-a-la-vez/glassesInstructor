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

    /// Cuando es `true`, la UI debe cerrar las vistas que dependen del hardware
    /// y mostrar el aviso de gafas sin conexión.
    @Published var isGlassesOffline: Bool = false
    @Published var offlineReason: String?

    /// La app intenta enlazar sola al abrirse. Mientras dure ese intento el botón
    /// de conectar se oculta; si no lo consigue a tiempo, aparece para hacerlo a
    /// mano. Así el caso normal no pide nada al usuario y el caso raro no lo deja
    /// atrapado esperando.
    @Published var isAutoConnecting: Bool = false
    @Published var showsManualConnectButton: Bool = false

    /// Margen antes de rendirse y ofrecer el botón manual.
    private static let autoConnectTimeout: TimeInterval = 10
    
    // Managers subsidiarios
    let hudManager = HUDGridManager.shared
    let cameraManager = CameraStreamManager.shared
    let speechManager = SpeechAudioManager.shared
    let avatarManager = AvatarHUDManager.shared
    let aiManager = AIManager.shared
    let logger = DiagnosticLogger.shared
    
    private var session: DeviceSession?
    private var linkWatchTask: Task<Void, Never>?
    /// Distingue "el usuario desconectó" de "las gafas se cayeron".
    private var isIntentionalDisconnect = false
    private var connectionTokens: [any AnyListenerToken] = []
    
    /// Coalescencia de renders del HUD durante el dictado. SFSpeechRecognizer emite resultados
    /// parciales varias veces por segundo; enviar cada uno al Display satura el canal y el SDK
    /// responde "Superseded by new display request". Renderizamos como mucho cada 400 ms.
    private var pendingDictationRender: Task<Void, Never>?
    private var lastDictationRenderAt: Date = .distantPast
    private var lastRenderedTranscript: String = ""
    private let dictationRenderInterval: TimeInterval = 0.4
    private var serviceBrowser: NetServiceBrowser?

    // Control de la ceremonia de registro con Meta AI
    private var awaitingRegistrationCallback = false
    private var registrationWatchdog: Timer?

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
            guard self.hudManager.currentMode == .dictationMic else { return }
            self.scheduleDictationRender(transcript)
        }
        
        // Conversación continua: al detectar silencio, consultamos a Gemini y respondemos hablando.
        speechManager.onSilenceSubmit = { [weak self] phrase in
            guard let self = self else { return }
            Task { await self.handleAgentPrompt(phrase) }
        }
        
        // QR de un stand: descargamos su README y lo inyectamos como contexto del agente.
        cameraManager.onQRDetected = { [weak self] payload in
            guard let self = self else { return }
            Task {
                // El mismo escáner alimenta dos flujos distintos según dónde estemos:
                // auditoría técnica del sitio, o contexto del stand para Shiki.
                if self.hudManager.currentMode == .projectAudit {
                    await self.handleScannedProject(payload)
                } else {
                    await self.handleScannedStand(payload)
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
    
    /// Agenda un render del HUD coalescido: cancela el pendiente y respeta el intervalo mínimo,
    /// de modo que siempre se pinta el último texto pero nunca más de una vez por intervalo.
    private func scheduleDictationRender(_ transcript: String) {
        guard transcript != lastRenderedTranscript else { return }
        
        pendingDictationRender?.cancel()
        let delay = max(0, dictationRenderInterval - Date().timeIntervalSince(lastDictationRenderAt))
        
        pendingDictationRender = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self = self else { return }
            guard self.hudManager.currentMode == .dictationMic else { return }
            
            self.lastDictationRenderAt = Date()
            self.lastRenderedTranscript = transcript
            await self.hudManager.renderCurrentState()
        }
    }
    
    /// Maneja las acciones secundarias al cambiar de modo (iniciar/detener streaming de cámara o audio)
    private func handleModeSwitch(_ mode: HUDMode) async {
        logger.log(.info, tag: "Mode", message: "Cambiando a modo: \(mode.rawValue)")
        
        // Un escaneo en curso sobrevive al cambio de modo: entrar al modo de
        // auditoría apagaba el propio escaneo que se acababa de pedir, así que
        // el stream moría y nunca llegaba un frame donde buscar el código.
        let scanningInProgress = cameraManager.isScanningQR

        // La voz solo se calla al ir a un modo donde la mascota no aparece.
        // Antes se cortaba en cualquier modo distinto de Shiki, así que entrar a
        // la auditoría silenciaba el veredicto que estaba a punto de decir.
        let mascotModes: Set<HUDMode> = [.shikiAgent, .welcome, .projectAudit]
        if !mascotModes.contains(mode) {
            avatarManager.stopAll()
        }

        if mode != .shikiAgent && !scanningInProgress {
            cameraManager.stopQRScanning()
        }

        switch mode {
        case .welcome, .gridMenu:
            if !scanningInProgress { cameraManager.stopStream() }
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
            lastRenderedTranscript = ""
            
        case .deviceDiagnostics, .interactiveGuide:
            if !scanningInProgress { cameraManager.stopStream() }
            speechManager.stopListening()

        case .projectAudit:
            speechManager.stopListening()
            // El modo auditoría es justo donde se escanea: cortar el stream aquí
            // dejaba al detector sin frames.
            if !scanningInProgress { cameraManager.stopStream() }

        case .shikiAgent:
            if !scanningInProgress { cameraManager.stopStream() }
            let greeting = aiManager.lastResponse.isEmpty
                ? "¡Hola! Soy Shiki. Pregúntame lo que quieras."
                : aiManager.lastResponse
            aiManager.lastResponse = greeting
            await avatarManager.refreshAvatarFrame(text: greeting)
            avatarManager.isContinuousSpeechMode = true
            avatarManager.startSpeakingAnimation(textToSpeak: greeting)
        }
    }
    
    /// Ciclo del agente: pensar -> consultar Gemini -> responder hablando.
    private func handleAgentPrompt(_ prompt: String) async {
        logger.log(.info, tag: "Agent", message: "Consulta del usuario: \(prompt)")
        
        avatarManager.isGeneratingAI = true
        avatarManager.startThinkingAnimation()
        
        let response = await LLMRouter.shared.complete(
            prompt: aiManager.standContext.map { "[CONTEXTO DEL STAND]\n\($0)\n\n[PREGUNTA]\n\(prompt)" } ?? prompt,
            system: Self.shikiSystemPrompt,
            maxTokens: 400
        )
        aiManager.lastResponse = response
        
        avatarManager.isGeneratingAI = false
        avatarManager.resetThinkingState()
        avatarManager.isContinuousSpeechMode = speechManager.isContinuousMode
        avatarManager.startSpeakingAnimation(textToSpeak: response)
        
        logger.log(.success, tag: "Agent", message: "Respuesta generada (\(response.count) caracteres).")
    }
    
    /// Shiki responde corto: su texto se proyecta en el waveguide.
    private static let shikiSystemPrompt = [
        "Eres Shiki, un guia de feria de ciencias que habla por unas gafas.",
        "Responde en espanol, maximo 2 frases cortas, sin markdown ni emojis.",
        "Si te dan contexto de un stand, respondes solo sobre ese proyecto."
    ].joined(separator: "\n")

    /// Audita el sitio apuntado por el QR: cascada de análisis y pintado progresivo.
    private func handleScannedProject(_ payload: String) async {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            ProjectAuditAgent.shared.statusLine = "El QR no contiene una URL http(s)"
            logger.log(.warning, tag: "Audit", message: "QR ignorado, no es una URL analizable: \(payload)")
            await hudManager.renderCurrentState(force: true)
            return
        }
        
        await ProjectAuditAgent.shared.audit(url: url)
    }
    
    /// Carga el README del repositorio apuntado por el QR como contexto del stand.
    private func handleScannedStand(_ urlString: String) async {
        await avatarManager.refreshAvatarFrame(text: "Descargando stand...")
        
        do {
            let context = try await aiManager.fetchRepositoryContext(url: urlString)
            aiManager.standContext = context
            
            let message = "¡Stand cargado con éxito! Hazme preguntas sobre este repositorio."
            aiManager.lastResponse = message
            avatarManager.startSpeakingAnimation(textToSpeak: message)
            logger.log(.success, tag: "Agent", message: "Contexto del stand cargado desde \(urlString).")
        } catch {
            aiManager.standContext = nil
            let message = "No pude acceder al repositorio del stand. Comprueba que sea público."
            aiManager.lastResponse = message
            avatarManager.startSpeakingAnimation(textToSpeak: message)
            logger.log(.error, tag: "Agent", message: "Fallo al cargar el stand: \(error.localizedDescription)")
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
                telemetry.lastErrorDescription = "El SDK de Meta nunca estuvo disponible. Verifica que Meta AI esté instalada, que Bluetooth esté encendido y que Developer Mode esté activo en Meta AI (Settings > App Info > 5 toques en App version)."
                logger.log(.error, tag: "Registration", message: "Timeout: el registro no salió de .unavailable en \(Double(Self.registrationReadyTicks) * 0.5)s.")
                return
            }

            if registration != .registered {
                connectionState = .registeringMetaAI
                awaitingRegistrationCallback = true
                validateMWDATConfiguration()
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
                    telemetry.deviceType = device.deviceType().rawValue
                    telemetry.supportsDisplay = device.supportsDisplay()
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
            
            // PASO 6: Adjuntar Display Capability (solo en gafas con HUD, p. ej. Meta Ray-Ban Display)
            let hasDisplay = wearables.deviceForIdentifier(validDeviceId)?.supportsDisplay() ?? false
            telemetry.supportsDisplay = hasDisplay
            
            if hasDisplay {
                logger.log(.info, tag: "Display", message: "Paso 6: Adjuntando canal de pantalla (Display)...")
                do {
                    let displayCapability = try deviceSession.addDisplay()
                    hudManager.attachDisplayCapability(displayCapability)
                    telemetry.isDisplayReady = true
                } catch {
                    telemetry.isDisplayReady = false
                    logger.log(.error, tag: "Display", message: "No se pudo adjuntar el HUD: \(error.localizedDescription). Se continúa sin pantalla.")
                }
            } else {
                telemetry.isDisplayReady = false
                logger.log(.warning, tag: "Display", message: "Paso 6 omitido: '\(telemetry.deviceType)' no tiene HUD waveguide. El menú 2x2 se renderiza solo en el simulador del iPhone.")
            }
            
            // PASO 7: Adjuntar Camera Capability (no debe abortar la sesión si falla)
            logger.log(.info, tag: "Camera", message: "Paso 7: Adjuntando canal de cámara...")
            do {
                if let cameraCapability = try deviceSession.addCamera(config: CameraStreamManager.streamConfiguration) {
                    cameraManager.attachCameraCapability(cameraCapability)
                }
            } catch {
                logger.log(.error, tag: "Camera", message: "No se pudo adjuntar la cámara: \(error.localizedDescription)")
            }
            
            // Vigilancia del enlace: térmica y caídas inesperadas
            startLinkWatch(for: validDeviceId)

            // PASO 8: Renderizar Menú Cuadrícula en el HUD
            isGlassesOffline = false
            offlineReason = nil
            showsManualConnectButton = false
            connectionState = .connected
            logger.log(.success, tag: "HUD", message: "Paso 8: Mostrando bienvenida en las gafas.")
            // Primero el saludo, no la rejilla: la mascota dice qué se puede
            // hacer antes de mostrar seis botones.
            await avatarManager.refreshAvatarFrame(text: "¡Hola!")
            await hudManager.switchMode(.welcome)
            
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
        // Desconectó a propósito: que el botón vuelva a estar disponible.
        showsManualConnectButton = true

        teardownEverything()

        // La bandera se limpia tras dar tiempo al callback asíncrono del SDK.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.isIntentionalDisconnect = false
        }

        logger.log(.info, tag: "Connection", message: "Desconexión completada.")
    }

    /// Intenta enlazar sin que el usuario pida nada. Si a los 10 s no lo logró,
    /// muestra el botón manual en vez de seguir en silencio.
    ///
    /// El intento sigue vivo después del plazo: si conecta más tarde por su
    /// cuenta, el botón desaparece solo.
    func autoConnectOnLaunch() async {
        guard connectionState == .disconnected, !isConnecting else { return }

        isAutoConnecting = true
        showsManualConnectButton = false
        logger.log(.info, tag: "Connection", message: "Intentando enlazar automáticamente con las gafas…")

        // El plazo corre en paralelo: no cancela el intento, solo destapa el botón.
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoConnectTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.connectionState != .connected {
                self.showsManualConnectButton = true
                self.logger.log(.warning, tag: "Connection",
                    message: "El enlace automático no terminó en \(Int(Self.autoConnectTimeout))s. Puedes conectarlas a mano.")
            }
        }

        await connectGlasses()
        deadline.cancel()

        isAutoConnecting = false
        showsManualConnectButton = connectionState != .connected
    }

    /// Corte de emergencia: las gafas se fueron sin avisar (se plegaron, se
    /// guardaron, salieron de rango o murió la sesión).
    ///
    /// Todo depende del hardware, así que dejar corriendo la cámara, el escáner o
    /// el micrófono tras perder el enlace solo produce errores en cascada y
    /// consume batería. Se apaga todo y la UI muestra un único mensaje.
    func handleUnexpectedDisconnection(reason: String) {
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
    ///
    /// `PhoneQRSession` NO se toca: usa la cámara del teléfono y sigue siendo
    /// válida sin gafas; pararla dejaría al usuario sin forma de escanear justo
    /// cuando más la necesita.
    private func teardownEverything() {
        clearRegistrationWatchdog()
        linkWatchTask?.cancel()
        linkWatchTask = nil

        pendingDictationRender?.cancel()
        pendingDictationRender = nil

        QRScanner.shared.stop()
        avatarManager.stopAll()
        cameraManager.detachCamera()
        hudManager.detachDisplay()
        speechManager.stopListening()

        connectionTokens.removeAll()
        session?.stop()
        session = nil

        telemetry.isDisplayReady = false
        telemetry.isCameraStreaming = false
    }

    /// Vigila el enlace mientras la sesión vive. `deviceStateStream` entrega el
    /// nivel térmico, que es la otra causa de corte.
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
        switch level {
        case .severe:
            logger.log(.warning, tag: "Thermal",
                       message: "Las gafas se están calentando. Reduciendo actividad.")
            QRScanner.shared.stop()

        case .critical, .emergency, .shutdown:
            handleUnexpectedDisconnection(
                reason: "Se sobrecalentaron. Déjalas enfriar un minuto.")

        default:
            break
        }
    }
    
    /// Verifica las 4 claves que MWDATCore exige bajo `MWDAT` en Info.plist.
    /// El SDK aborta con "Partial attestation configuration detected. ClientToken and/or
    /// teamID are missing" si faltan. En Developer Mode la atestación no se usa y valen dummies.
    private func validateMWDATConfiguration() {
        let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] ?? [:]
        let placeholders: Set<String> = ["", "0", "REPLACE_WITH_CLIENT_TOKEN"]
        
        let pending = ["MetaAppID", "ClientToken", "TeamID", "AppLinkURLScheme"].compactMap { key -> String? in
            let value = (mwdat[key] as? String) ?? ""
            guard placeholders.contains(value) else { return nil }
            return "\(key)=\(value.isEmpty ? "ausente" : value)"
        }
        
        guard !pending.isEmpty else {
            logger.log(.success, tag: "Registration", message: "Configuración MWDAT completa.")
            return
        }
        
        let detail = pending.joined(separator: ", ")
        telemetry.lastErrorDescription = "Configuración MWDAT incompleta: \(detail)"
        logger.log(
            .warning,
            tag: "Registration",
            message: "Credenciales MWDAT sin configurar (\(detail)). Para probar así, activa Developer Mode en la app Meta AI: Ajustes > App Info > toca 5 veces la versión > activa el toggle > Confirmar. Sin Developer Mode necesitas MetaAppID y ClientToken reales de wearables.developer.meta.com."
        )
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
                self.telemetry.lastErrorDescription = "Meta AI no devolvió la autorización en \(Int(Self.registrationCallbackTimeout))s. Abre Meta AI > Settings > App Info, toca 5 veces App version y activa Developer Mode."
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
            // Si el estado ya bajó, la desconexión fue intencional: llamar aquí a
            // `disconnectGlasses()` sería recursivo.
            if connectionState == .connected && !isIntentionalDisconnect {
                handleUnexpectedDisconnection(
                    // El título del aviso ya dice que se perdió el enlace: aquí
                    // solo va lo accionable.
                    reason: "Revisa que estén abiertas, puestas y con batería.")
            }

        case .paused:
            // Ocurre al plegarlas o guardarlas en el estuche.
            handleUnexpectedDisconnection(
                reason: "Se plegaron o están en el estuche. Ábrelas y póntelas.")

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
