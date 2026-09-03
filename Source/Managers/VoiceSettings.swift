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

    static func bestAvailable() -> AVSpeechSynthesisVoice? {
        let voices = spanishVoices
        // Se prefiere es-MX a igualdad de calidad: es el acento del sitio.
        return voices.first { $0.quality == .premium && $0.language == "es-MX" }
            ?? voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced && $0.language == "es-MX" }
            ?? voices.first { $0.quality == .enhanced }
            ?? voices.first
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
