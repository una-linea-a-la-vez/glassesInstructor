import Foundation
import Combine

/// Acciones que se pueden colgar de un botón del HUD.
///
/// **Por qué esto y no gestos.** La Neural Band no expone sus gestos al SDK: no hay
/// eventos de pellizco, deslizamiento ni EMG en `MWDATCore`, `MWDATCamera` ni
/// `MWDATDisplay` (verificado sobre los binarios). Lo único que llega a la app es el
/// `onClick` de un botón del HUD. La pulsera es el mando que lo activa, pero quien
/// decide qué pasa es este mapeo. Configurar "gestos" seria prometer algo que el
/// hardware no entrega; configurar acciones de botón es lo que de verdad se puede.
enum GlassesAction: String, CaseIterable, Identifiable, Codable {
    case photoScan
    case videoScan
    case readEnvironment
    case questions
    case openMenu
    case openQuestionsOnPhone
    case openScanOnPhone
    case demolish

    var id: String { rawValue }

    /// Etiqueta para el botón del HUD. Corta a propósito: el waveguide no admite más.
    var hudLabel: String {
        switch self {
        case .photoScan:       return "📷 Foto del código"
        case .videoScan:       return "🎥 Buscar en video"
        case .readEnvironment: return "👁 ¿Dónde estoy?"
        case .questions:       return "❓ Preguntas"
        case .openMenu:        return "☰ Menú"
        case .openQuestionsOnPhone: return "📱 Preguntas"
        case .openScanOnPhone:      return "📱 Escanear"
        case .demolish:             return "🔨 Tronarlo"
        }
    }

    /// Nombre largo para la pantalla de ajustes del teléfono.
    var label: String {
        switch self {
        case .photoScan:       return "Escanear con foto"
        case .videoScan:       return "Escanear con video"
        case .readEnvironment: return "Leer el entorno"
        case .questions:       return "Generar preguntas"
        case .openMenu:        return "Abrir el menú"
        case .openQuestionsOnPhone: return "Abrir preguntas en el teléfono"
        case .openScanOnPhone:      return "Abrir escaneo en el teléfono"
        case .demolish:             return "Tronar el proyecto"
        }
    }

    var detail: String {
        switch self {
        case .photoScan:       return "Una foto a resolución completa. Lo más fiable para un QR."
        case .videoScan:       return "Stream continuo. Calienta y depende del Wi-Fi."
        case .readEnvironment: return "Describe dónde estás y cuánta gente hay."
        case .questions:       return "Preguntas sobre el último proyecto escaneado."
        case .openMenu:        return "Muestra la cuadrícula completa."
        case .openQuestionsOnPhone: return "Trae al teléfono la lista de preguntas."
        case .openScanOnPhone:      return "Trae al teléfono el visor de escaneo."
        case .demolish:             return "Busca grietas entre lo que dice y lo que mide el sitio."
        }
    }
}

/// Qué hacen los dos botones del HUD de bienvenida.
@MainActor
class GlassesActionSettings: ObservableObject {
    static let shared = GlassesActionSettings()

    @Published var primary: GlassesAction {
        didSet { UserDefaults.standard.set(primary.rawValue, forKey: "HUDPrimaryAction") }
    }
    @Published var secondary: GlassesAction {
        didSet { UserDefaults.standard.set(secondary.rawValue, forKey: "HUDSecondaryAction") }
    }

    /// Pantalla del teléfono que el HUD ha pedido abrir.
    ///
    /// Los gestos de la pulsera no llegan, pero la pulsación de un botón del HUD sí,
    /// y desde ahí se puede gobernar el teléfono. La vista principal observa esto y
    /// lo traduce en la presentación que toque; se limpia al consumirlo para que no
    /// se reabra sola al volver.
    @Published var phoneScreenRequest: PhoneScreen? = nil

    enum PhoneScreen: Equatable {
        case questions
        case scan
        case demolition
    }

    /// Deja la bienvenida con UN solo destino tocable.
    ///
    /// Es lo mas parecido a "doble toque y escanea" que permite el hardware. El SDK
    /// no entrega el gesto de la pulsera, solo la pulsacion que provoca; pero si en
    /// la pantalla no hay nada mas que enfocar, cualquier toque dispara la accion
    /// principal y no hay que navegar. Ademas del boton, la tarjeta entera queda
    /// tocable con FlexBox.onTap, para que no haga falta apuntar.
    @Published var singleActionMode: Bool {
        didSet { UserDefaults.standard.set(singleActionMode, forKey: "HUDSingleAction") }
    }

    private init() {
        let defaults = UserDefaults.standard
        // Por defecto el video: `capturePhoto` con el stream apagado lo rechaza el
        // firmware ("Las gafas rechazaron la captura"), así que la foto no llegaba a
        // intentarse. El stream continuo con Vision/CIDetector es el que sí lee.
        primary = GlassesAction(rawValue: defaults.string(forKey: "HUDPrimaryAction") ?? "") ?? .videoScan
        secondary = GlassesAction(rawValue: defaults.string(forKey: "HUDSecondaryAction") ?? "") ?? .openMenu
        // Encendido salvo que se apague a mano. `defaults.bool` devuelve false
        // cuando la clave no existe, y ese false silencioso dejaba tres botones
        // compitiendo por el foco: el toque de la pulsera caia en cualquiera.
        singleActionMode = defaults.object(forKey: "HUDSingleAction") as? Bool ?? true

        // Migración de una sola vez: quien ya usó la app tiene `photoScan` grabado
        // en UserDefaults, así que el nuevo valor por defecto no le llegaría nunca
        // y su botón del HUD seguiría muriendo en "Las gafas rechazaron la captura".
        // Se hace una vez: si después elige foto a mano, se respeta.
        if !defaults.bool(forKey: "HUDPhotoScanMigrated") {
            defaults.set(true, forKey: "HUDPhotoScanMigrated")
            if primary == .photoScan {
                primary = .videoScan
            }
        }
    }

    /// Ejecuta la acción elegida. Vive aquí para que el HUD no tenga que saber de
    /// cámaras ni de agentes.
    func perform(_ action: GlassesAction) async {
        let hud = HUDGridManager.shared

        switch action {
        case .photoScan:
            await hud.switchMode(.projectAudit)
            ProjectAuditAgent.shared.statusLine = "Enfoca el código..."
            await hud.renderCurrentState(force: true, duringScan: true)
            await CameraStreamManager.shared.scanQRFromPhoto()

        case .videoScan:
            await hud.switchMode(.projectAudit)
            await CameraStreamManager.shared.startQRScanning()

        case .readEnvironment:
            await hud.switchMode(.projectAudit)
            await ProjectAuditAgent.shared.scanEnvironment()

        case .questions:
            await hud.switchMode(.projectAudit)
            await QuestionSession.shared.ensureQuestions(present: true)

        case .openMenu:
            await hud.switchMode(.gridMenu)

        case .openQuestionsOnPhone:
            // Las preguntas se generan aqui para que el telefono las encuentre listas.
            await hud.switchMode(.projectAudit)
            await QuestionSession.shared.ensureQuestions(present: true)
            phoneScreenRequest = .questions

        case .openScanOnPhone:
            phoneScreenRequest = .scan

        case .demolish:
            await DemolitionSession.shared.run()
            phoneScreenRequest = .demolition
        }
    }
}
