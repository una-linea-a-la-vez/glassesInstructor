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
    
    // Managers subsidiarios
    let hudManager = HUDGridManager.shared
    let cameraManager = CameraStreamManager.shared
    let speechManager = SpeechAudioManager.shared
    let logger = DiagnosticLogger.shared
    
    private var session: DeviceSession?
    private var connectionTokens: [any AnyListenerToken] = []
    private var serviceBrowser: NetServiceBrowser?
    
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
            let registration = wearables.registrationState
            logger.log(.info, tag: "Registration", message: "Paso 2: Estado de registro: \(registration.description)")
            
            if registration != .registered {
                connectionState = .registeringMetaAI
                validateMetaAppIDConfiguration()
                logger.log(.warning, tag: "Registration", message: "Abriendo app Meta AI para autorizar esquema...")
                try await wearables.startRegistration()
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
                if let cameraCapability = try deviceSession.addCamera() {
                    cameraManager.attachCameraCapability(cameraCapability)
                }
            } catch {
                logger.log(.error, tag: "Camera", message: "No se pudo adjuntar la cámara: \(error.localizedDescription)")
            }
            
            // PASO 8: Renderizar Menú Cuadrícula en el HUD
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
        cameraManager.detachCamera()
        hudManager.detachDisplay()
        speechManager.stopListening()
        
        connectionTokens.removeAll()
        session?.stop()
        session = nil
        
        connectionState = .disconnected
        telemetry.isDisplayReady = false
        telemetry.isCameraStreaming = false
        logger.log(.info, tag: "Connection", message: "Desconexión completada.")
    }
    
    /// Verifica que Info.plist declare un MetaAppID real. El SDK valida la identidad de la app
    /// vía App Attest contra un App ID registrado en el Wearables Developer Center; "0" no es válido.
    private func validateMetaAppIDConfiguration() {
        let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
        let metaAppID = mwdat?["MetaAppID"] as? String
        
        if let metaAppID, metaAppID != "0", !metaAppID.isEmpty {
            logger.log(.info, tag: "Registration", message: "MetaAppID configurado: \(metaAppID)")
            return
        }
        
        telemetry.lastErrorDescription = "MetaAppID inválido en Info.plist. El registro con Meta AI no puede completarse."
        logger.log(
            .error,
            tag: "Registration",
            message: "MetaAppID inválido (\(metaAppID ?? "ausente")). No existe un bypass con App ID \"0\": registra la app en wearables.developer.meta.com, añade tu Bundle ID y Apple Team ID, y copia el App ID numérico real a Info.plist > MWDAT > MetaAppID. Sin eso el estado se queda en .registering para siempre."
        )
    }
    
    private func handleRegistrationChange(_ state: RegistrationState) {
        logger.log(.info, tag: "Registration", message: "Estado de registro actualizado: \(state.description)")
        if state == .registered && connectionState == .registeringMetaAI {
            Task {
                await connectGlasses()
            }
        }
    }
    
    private func handleSessionState(_ state: DeviceSessionState) {
        logger.log(.info, tag: "Session", message: "Estado de sesión cambió a: \(state)")
        if state == .stopped {
            disconnectGlasses()
        }
    }
}
