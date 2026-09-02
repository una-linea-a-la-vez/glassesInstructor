import Foundation
import AVFoundation

/// Narra un `AvatarScript` en voz alta y publica el estado que la vista necesita
/// para animar el avatar en sincronía con el habla.
///
/// Ruteo de audio: el SDK de Wearables **no expone el audio de las gafas**, pero las
/// Ray-Ban Display se emparejan como salida Bluetooth normal. Poniendo la sesión en
/// `.playback` con A2DP, lo que sintetiza el iPhone sale por sus altavoces de oído
/// abierto. Es la vía para que el avatar se oiga en las gafas sin API de audio.
@MainActor
final class AvatarNarrator: NSObject, ObservableObject {
    static let shared = AvatarNarrator()

    @Published private(set) var script: AvatarScript?
    @Published private(set) var currentLineIndex: Int = -1
    @Published private(set) var isSpeaking: Bool = false
    /// Se incrementa en cada fragmento hablado. La vista lo usa para pulsar el
    /// avatar en sincronía real con la voz, no con un timer arbitrario.
    @Published private(set) var speechPulse: Int = 0
    @Published private(set) var routedToGlasses: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lineForUtterance: [ObjectIdentifier: Int] = [:]
    private let logger = DiagnosticLogger.shared

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Carga un guion sin empezar a hablar. La vista puede pintarlo de inmediato.
    func load(_ newScript: AvatarScript) {
        stop()
        script = newScript
        currentLineIndex = -1
    }

    func speak() {
        guard let script, !script.lines.isEmpty else { return }
        guard !isSpeaking else { return }

        configureAudioSession()

        // Una utterance por línea: así sabemos exactamente qué frase suena.
        for (index, line) in script.lines.enumerated() {
            let utterance = AVSpeechUtterance(string: line.spoken)
            utterance.voice = Self.preferredVoice()
            utterance.rate = 0.5
            utterance.pitchMultiplier = 1.0
            utterance.postUtteranceDelay = 0.25
            lineForUtterance[ObjectIdentifier(utterance)] = index
            synthesizer.speak(utterance)
        }

        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        lineForUtterance.removeAll()
        isSpeaking = false
        currentLineIndex = -1
    }

    func toggle() {
        isSpeaking ? stop() : speak()
    }

    // MARK: - Audio

    /// Deja la salida en A2DP para que suene por las gafas si están emparejadas.
    /// El dictado deja la sesión en `.record`, así que hay que devolverla.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let outputs = session.currentRoute.outputs
            routedToGlasses = outputs.contains { $0.portType == .bluetoothA2DP }

            let names = outputs.map(\.portName).joined(separator: ", ")
            logger.log(.info, tag: "Avatar",
                       message: "Salida de audio: \(names.isEmpty ? "ninguna" : names)"
                              + (routedToGlasses ? " · vía Bluetooth (gafas)" : " · altavoz del teléfono"))
        } catch {
            logger.log(.error, tag: "Avatar",
                       message: "No se pudo configurar la salida de audio: \(error.localizedDescription)")
        }
    }

    /// Prefiere una voz mejorada en español de México; cae a cualquier español.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let enhanced = voices.first(where: {
            $0.language == "es-MX" && $0.quality != .default
        }) { return enhanced }
        if let mexican = voices.first(where: { $0.language == "es-MX" }) { return mexican }
        return AVSpeechSynthesisVoice(language: "es-ES")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AvatarNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let index = self.lineForUtterance[ObjectIdentifier(utterance)] {
                self.currentLineIndex = index
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechPulse &+= 1
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.lineForUtterance.removeValue(forKey: ObjectIdentifier(utterance))
            if self.lineForUtterance.isEmpty {
                self.isSpeaking = false
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
