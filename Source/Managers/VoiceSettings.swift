import Foundation
import AVFoundation
import Combine

/// Voz y ritmo con los que habla el avatar.
///
/// Antes la voz se elegia una sola vez al arrancar, dentro de un `static let`, y no
/// habia forma de cambiarla sin recompilar. Aqui se elige, se prueba y se recuerda.
///
/// Nota: Apple Intelligence no interviene en esto. `FoundationModels` genera texto;
/// la voz sale de `AVSpeechSynthesizer` y de las voces instaladas en el sistema.
@MainActor
class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    @Published var voiceIdentifier: String {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "TTSVoiceIdentifier") }
    }

    /// 0.4 lento, 0.5 normal. Por encima de 0.55 se pierde en el auricular de las
    /// gafas, que va en banda estrecha.
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: "TTSRate") }
    }

    private let synthesizer = AVSpeechSynthesizer()

    private init() {
        let defaults = UserDefaults.standard
        rate = defaults.object(forKey: "TTSRate") as? Float ?? 0.48
        voiceIdentifier = defaults.string(forKey: "TTSVoiceIdentifier") ?? ""

        if voiceIdentifier.isEmpty {
            voiceIdentifier = Self.bestAvailable()?.identifier ?? ""
        }
    }

    /// Voces en español del sistema, de mejor a peor calidad.
    ///
    /// Premium suena claramente mejor que Enhanced, pero hay que bajarla a mano en
    /// Ajustes > Accesibilidad > Contenido hablado > Voces. Si no aparece ninguna
    /// Premium en la lista, es que no esta descargada, no que no exista.
    static var spanishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    /// Voces preferidas por nombre, en orden.
    ///
    /// Se ordena por nombre y no por idioma porque el criterio real es como suena,
    /// no de que pais es. Antes se prefería es-MX y eso descartaba a Francisca, que
    /// es es-CL, por mucho que estuviera descargada y sonara mejor.
    static let preferredNames = ["Francisca", "Paulina", "Mónica", "Monica"]

    static func bestAvailable() -> AVSpeechSynthesisVoice? {
        let voices = spanishVoices

        // Primero la calidad, y dentro de cada nivel el orden de preferencia por
        // nombre. Una Enhanced con buen nombre gana a una Estándar cualquiera.
        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default] {
            let atThisLevel = voices.filter { $0.quality == quality }
            guard !atThisLevel.isEmpty else { continue }

            for name in preferredNames {
                if let match = atThisLevel.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    return match
                }
            }
            return atThisLevel.first
        }
        return voices.first
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? Self.bestAvailable()
    }

    /// Nombre legible de la voz activa, con su calidad.
    var selectedDescription: String {
        guard let voice = selectedVoice else { return "Sin voz en español instalada" }
        return "\(voice.name) · \(Self.qualityLabel(voice.quality)) · \(voice.language)"
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Estándar"
        }
    }

    /// ¿Hay alguna Premium instalada? Si no, merece la pena decirlo: es el salto
    /// de calidad mas grande y solo cuesta descargarla.
    var hasPremiumInstalled: Bool {
        Self.spanishVoices.contains { $0.quality == .premium }
    }

    /// Salta a la mejor voz instalada ahora mismo.
    ///
    /// La eleccion se guarda entre arranques, asi que si se descarga una voz mejor
    /// despues, la app sigue con la de antes: hace bien en respetar lo elegido, pero
    /// hace falta una forma explicita de decir "usa la nueva".
    func useBestAvailable() {
        guard let best = Self.bestAvailable() else { return }
        voiceIdentifier = best.identifier
        DiagnosticLogger.shared.log(.info, tag: "Voz", message: "Voz: \(selectedDescription).")
    }

    /// Estado de la Voz Personal.
    ///
    /// Es lo mas cercano a "la voz de Siri" que un tercero puede usar: la de Siri en
    /// si no esta expuesta -no hay API para ella en AVFAudio, solo menciones a
    /// interrupciones de audio-. La Voz Personal la graba el usuario (unos 15
    /// minutos leyendo frases en Ajustes) y luego aparece en la lista como una voz
    /// mas, siempre que se pida permiso.
    @Published private(set) var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined

    var personalVoiceHint: String {
        switch personalVoiceStatus {
        case .authorized:
            return Self.spanishVoices.contains { $0.voiceTraits.contains(.isPersonalVoice) }
                ? "Voz Personal disponible en la lista."
                : "Permiso concedido, pero no hay ninguna Voz Personal grabada."
        case .denied:        return "Permiso denegado. Se cambia en Ajustes › Privacidad."
        case .unsupported:   return "Este dispositivo no admite Voz Personal."
        default:             return "Sin solicitar."
        }
    }

    func refreshPersonalVoiceStatus() {
        personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    }

    func requestPersonalVoice() {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            Task { @MainActor in
                self?.personalVoiceStatus = status
                DiagnosticLogger.shared.log(.info, tag: "Voz",
                    message: "Permiso de Voz Personal: \(status.rawValue).")
            }
        }
    }

    /// Prueba en el altavoz para poder comparar antes de dejarla puesta.
    func preview() {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hola, así sonarán las preguntas en las gafas.")
        utterance.voice = selectedVoice
        utterance.rate = rate
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }
}
