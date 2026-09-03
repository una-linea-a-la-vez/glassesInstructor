import Foundation
import UIKit
import Combine
import AVFoundation

/// Compone y anima el avatar 2D multicapa de "Shiki" que se proyecta en el HUD.
///
/// No envía nada a las gafas por sí mismo: prepara el fotograma y delega la transmisión en
/// `HUDGridManager`, que es el único dueño del canal `Display`. Toda la composición pesada
/// (dibujo de capas y compresión JPEG) ocurre fuera del main actor.
@MainActor
class AvatarHUDManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = AvatarHUDManager()

    /// Imagen a tamaño completo para el espejo del iPhone.
    @Published var currentAvatarImage: UIImage = UIImage()
    /// Fotograma ya comprimido que se envía a las gafas.
    @Published var hudFrame: UIImage? = nil
    @Published var hudText: String = "Pregúntame algo..."
    @Published var avatarState: String = "Normal"
    @Published var isSpeaking: Bool = false
    @Published var isGeneratingAI: Bool = false
    @Published var isContinuousSpeechMode: Bool = false

    // Índices de las capas activas
    @Published var currentBodyIndex: Int = 0
    @Published var currentBrowIndex: Int = 0
    @Published var currentEyeIndex: Int = 0
    @Published var currentMouthIndex: Int = 0

    /// Capas PNG precargadas en memoria (sólo lectura, por eso puede ser `nonisolated`).
    nonisolated private let sourceImageCache: [String: UIImage]
    /// Caché de composiciones ya montadas, indexada por combinación de capas.
    private var compositeCache: [String: UIImage] = [:]

    private var animationTimer: Timer?
    /// Dibuja la mascota pixelada en vez del avatar de assets. Ponlo en `false`
    /// para recuperar el avatar anterior sin borrar nada.
    var usesPixelMascot = true
    /// Última vez que se repintó la boca, para no saturar el canal Bluetooth.
    private var lastMouthRender = Date.distantPast
    /// Contador de fragmentos hablados. La mascota del teléfono lo usa para latir
    /// en sincronía con la voz real.
    @Published private(set) var speechPulse: Int = 0

    private var thinkingTimer: Timer?
    private var blinkTimer: Timer?

    /// El MVP proyecta ondas tipo parlante en vez del avatar: se lee mucho mejor en el
    /// waveguide monocromo y no depende de 45 PNG. Ponlo en false para volver al avatar.
    @Published var useWaveform: Bool = false
    /// Origen de tiempo de la onda.
    ///
    /// La fase se calcula por RELOJ, no sumando un paso en cada fotograma. Sumando
    /// por fotograma la onda iba al ritmo del temporizador que tocara: un ciclo
    /// tardaba 3,2 s hablando, 9 s pensando y 72 s en reposo, o sea que apenas se
    /// movia. Por reloj el movimiento es el mismo siempre y un frame rate mas bajo
    /// solo lo muestrea mas grueso, en vez de frenarlo.
    private let waveEpoch = Date()
    /// Radianes por segundo. 6.0 deja el ciclo en algo mas de un segundo, que es el
    /// vaiven que se lee como "esta hablando".
    private static let waveSpeed: Double = 6.0

    private var wavePhase: Double { Date().timeIntervalSince(waveEpoch) * Self.waveSpeed }

    /// Se llama al terminar una locución. El teleprompter lo usa para pasar de
    /// línea cuando de verdad se acabó de hablar, en vez de a ciegas por reloj.
    var onSpeechFinished: (() -> Void)?

    private let speechSynthesizer = AVSpeechSynthesizer()

    private override init() {
        self.sourceImageCache = Self.prefetchAvatarAssets()
        super.init()
        speechSynthesizer.delegate = self
        setupBlinkingLoop()
    }

    // MARK: - Carga y composición de capas

    nonisolated private static func prefetchAvatarAssets() -> [String: UIImage] {
        var cache: [String: UIImage] = [:]
        for category in ["体", "眉", "目", "口", "他"] {
            for i in 0...12 {
                let name = String(format: "%02d", i)
                if let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: "Avatar/\(category)"),
                   let image = UIImage(contentsOfFile: path) {
                    cache["\(category)_\(name)"] = image
                }
            }
        }
        DiagnosticLogger.shared.log(.info, tag: "Avatar", message: "Precargadas \(cache.count) capas del avatar.")
        return cache
    }

    nonisolated private func loadAvatarPart(category: String, name: String) -> UIImage? {
        sourceImageCache["\(category)_\(name)"]
    }

    /// Superpone las capas (cuerpo, cejas, ojos, boca) en una sola imagen.
    nonisolated private func compositeBaseAvatarImage(body: Int, brow: Int, eye: Int, mouth: Int) -> UIImage {
        let size = CGSize(width: 300, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let bodyImg = loadAvatarPart(category: "体", name: String(format: "%02d", body))
        let browImg = loadAvatarPart(category: "眉", name: String(format: "%02d", brow))
        let eyeImg = loadAvatarPart(category: "目", name: String(format: "%02d", eye))
        let mouthImg = loadAvatarPart(category: "口", name: String(format: "%02d", mouth))

        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            if let bodyImg {
                bodyImg.draw(in: rect)
            } else {
                context.cgContext.setFillColor(UIColor.darkGray.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: 75, y: 75, width: 150, height: 150))
            }
            browImg?.draw(in: rect)
            eyeImg?.draw(in: rect)
            mouthImg?.draw(in: rect)
        }
    }

    /// Añade la flotación/respiración continua sobre fondo negro (el HUD lo vuelve transparente).
    nonisolated private func applyFloatingOffset(to baseImage: UIImage, step: Double) -> UIImage {
        let size = CGSize(width: 300, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let dx = CGFloat(sin(step) * 6.0)
        let dy = CGFloat(cos(step * 1.3) * 4.0)

        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            baseImage.draw(in: CGRect(x: dx, y: dy, width: size.width, height: size.height))
        }
    }

    /// Recompone el fotograma actual y pide a `HUDGridManager` que lo transmita.
    func refreshAvatarFrame(text: String? = nil) async {
        if let text { hudText = text }

        let (body, brow, eye, mouth) = (currentBodyIndex, currentBrowIndex, currentEyeIndex, currentMouthIndex)
        // Misma razon que la onda: por reloj, no por fotograma.
        let step = Date().timeIntervalSince(waveEpoch) * 1.4

        // Las ondas van primero: es lo que se pidio para la bienvenida.
        // La mascota pixelada de truena-fepro queda detras como alternativa
        // (useWaveform = false), y los PNG del avatar como tercera opcion.
        if useWaveform {
            await refreshWaveFrame()
            return
        }

        // La mascota pixelada se dibuja entera por código: ya trae su propia
        // flotación y sale en blanco y negro duro, que es lo que el waveguide
        // reproduce sin perder bordes. Los assets del avatar anterior se
        // conservan para poder volver a ellos con `usesPixelMascot = false`.
        if usesPixelMascot {
            let blinking = (currentEyeIndex != 0)
            // Las ondas acompañan a la mascota como indicador pequeño al pie: la
            // mascota dice en que estado esta y las ondas dan el pulso de la voz.
            // Ninguna de las dos sola contaba las dos cosas.
            let level = isSpeaking ? 1.0 : (isGeneratingAI ? 0.55 : 0.20)
            let (fullImage, compressed) = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage?) in
                let mascot = MascotHUDRenderer.render(mouthLevel: mouth, isBlinking: blinking, step: step)

                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: mascot.size, format: format).image { ctx in
                    mascot.draw(at: .zero)
                    // Esquina superior derecha. Al pie pisaba las piernas de la
                    // mascota (su rejilla llega hasta y=282 de 300) y en monocromo
                    // dos formas superpuestas se vuelven una mancha. Aqui no hay
                    // nada dibujado: la antena queda al centro y el cuerpo empieza
                    // mas abajo.
                    let strip = CGRect(x: mascot.size.width - 94,
                                       y: 26,
                                       width: 72,
                                       height: 20)
                    WaveHUDRenderer.draw(in: strip, context: ctx.cgContext, phase: step, amplitude: level)
                }

                guard let data = image.jpegData(compressionQuality: 0.2) else { return (image, nil) }
                return (image, UIImage(data: data))
            }.value

            currentAvatarImage = fullImage
            hudFrame = compressed
            await HUDGridManager.shared.renderIfAgentMode()
            return
        }

        let key = "\(body)_\(brow)_\(eye)_\(mouth)"
        let baseImage: UIImage
        if let cached = compositeCache[key] {
            baseImage = cached
        } else {
            baseImage = await Task.detached(priority: .userInitiated) {
                self.compositeBaseAvatarImage(body: body, brow: brow, eye: eye, mouth: mouth)
            }.value
            compositeCache[key] = baseImage
        }

        // Flotación + compresión JPEG fuera del main actor: es lo caro y no debe competir con el audio.
        let (fullImage, compressed) = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage?) in
            let image = self.applyFloatingOffset(to: baseImage, step: step)
            guard let data = image.jpegData(compressionQuality: 0.15) else { return (image, nil) }
            return (image, UIImage(data: data))
        }.value

        currentAvatarImage = fullImage
        hudFrame = compressed

        await HUDGridManager.shared.renderIfAgentMode()
    }


    // MARK: - Indicador de conversación

    /// Compone el fotograma de ondas y lo manda al HUD. Mismo pipeline que el avatar:
    /// el dibujo y la compresion ocurren fuera del main actor.
    private func refreshWaveFrame() async {
        let phase = wavePhase
        // Cuando habla, las ondas suben; en reposo laten suave.
        let amplitude = isSpeaking ? 1.0 : (isGeneratingAI ? 0.55 : 0.22)

        let (fullImage, compressed) = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage?) in
            let image = WaveHUDRenderer.render(phase: phase, amplitude: amplitude)
            guard let data = image.jpegData(compressionQuality: 0.5) else { return (image, nil) }
            return (image, UIImage(data: data))
        }.value

        currentAvatarImage = fullImage
        hudFrame = compressed
        await HUDGridManager.shared.renderIfAgentMode()
    }

    // MARK: - Animaciones

    private func setupBlinkingLoop() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSpeaking else { return }
                for (index, pause) in [(1, 80), (2, 120), (1, 80), (0, 0)] {
                    self.currentEyeIndex = index
                    await self.refreshAvatarFrame()
                    if pause > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(pause) * 1_000_000)
                    }
                }
            }
        }
    }

    func startSpeakingAnimation(textToSpeak: String) {
        isSpeaking = true
        avatarState = "Hablando"
        animationTimer?.invalidate()
        thinkingTimer?.invalidate()

        // Gesto de saludo al arrancar a hablar, que vuelve a reposo tras 1,2 s.
        currentBodyIndex = 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.isSpeaking else { return }
            self.currentBodyIndex = 0
        }

        // Sin esto no se oye nada: SpeechAudioManager deja la sesión en mode .measurement,
        // que desactiva el procesado de audio y hunde la ganancia de salida. Hay que
        // devolverla a .default antes de sintetizar.
        configureAudioSessionForSpeaking()
        
        let utterance = AVSpeechUtterance(string: textToSpeak)
        utterance.voice = VoiceSettings.shared.selectedVoice
        // 0.48 iba por debajo del ritmo normal (el default de iOS es 0.5) y se
        // notaba arrastrado. 0.53 suena conversacional en español sin atropellar.
        utterance.rate = VoiceSettings.shared.rate
        utterance.pitchMultiplier = 1.02
        utterance.volume = 1.0
        // Sin esto el sintetizador arranca en seco y se come la primera sílaba
        // cuando la salida es Bluetooth (tarda en abrir la ruta).
        utterance.preUtteranceDelay = 0.15
        
        if let voice = utterance.voice {
            DiagnosticLogger.shared.log(.info, tag: "Avatar", message: "Voz TTS: \(voice.name) (\(voice.language)).")
        } else {
            DiagnosticLogger.shared.log(.warning, tag: "Avatar", message: "Sin voz en español instalada. Ajustes > Accesibilidad > Contenido hablado > Voces.")
        }
        
        speechSynthesizer.speak(utterance)

        // La boca ya no la mueve un temporizador fijo: la mueve el propio
        // sintetizador desde `willSpeakRangeOfSpeechString`, así va al ritmo real
        // del habla en vez de a un compás suelto que nunca coincidía.
        // El throttle de `advanceMouth()` conserva el techo de ~5,5 FPS para no
        // ahogar el audio por Bluetooth.
    }

    /// Avanza un cuadro de boca. Lo llama el delegate por cada fragmento hablado.
    private func advanceMouth() {
        // Techo de tasa: el HUD viaja por Bluetooth y re-renderizar más seguido
        // compite con el audio.
        let now = Date()
        guard now.timeIntervalSince(lastMouthRender) >= 0.16 else { return }
        lastMouthRender = now

        let sequence = [0, 1, 2, 1]
        let current = sequence.firstIndex(of: currentMouthIndex) ?? 0
        currentMouthIndex = sequence[(current + 1) % sequence.count]

        Task { @MainActor in
            await self.refreshAvatarFrame(text: AIManager.shared.lastResponse)
        }
    }

    /// Prepara la sesión de audio para reproducir voz. Se mantiene `.playAndRecord` para no
    /// perder la ruta HFP del micrófono en modo conversación continua, pero con `mode: .default`
    /// para recuperar ganancia y procesado normales.
    private func configureAudioSessionForSpeaking() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DiagnosticLogger.shared.log(.error, tag: "Avatar", message: "No se pudo preparar el audio para hablar: \(error.localizedDescription)")
        }
    }
    
    func stopSpeakingAnimation() {
        isSpeaking = false
        avatarState = "Normal"
        animationTimer?.invalidate()
        currentMouthIndex = 0
        Task { await refreshAvatarFrame(text: AIManager.shared.lastResponse) }
    }

    func startThinkingAnimation() {
        avatarState = "Pensando"
        thinkingTimer?.invalidate()
        animationTimer?.invalidate()
        currentBodyIndex = 2

        var step = 0
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let eyeSequence = [0, 3, 0, 4]
                self.currentEyeIndex = eyeSequence[step % eyeSequence.count]
                self.currentBrowIndex = 1
                step += 1
                await self.refreshAvatarFrame(text: "Shiki está pensando...")
            }
        }
    }

    func resetThinkingState() {
        thinkingTimer?.invalidate()
        currentBrowIndex = 0
        currentEyeIndex = 0
        currentBodyIndex = 0
    }

    /// Detiene voz y animaciones; se llama al salir del modo agente o al desconectar.
    func stopAll() {
        isContinuousSpeechMode = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        animationTimer?.invalidate()
        thinkingTimer?.invalidate()
        isSpeaking = false
        isGeneratingAI = false
        resetThinkingState()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// El sintetizador avisa antes de pronunciar cada fragmento. Ésta es la señal
    /// que sincroniza la boca con la voz: antes la movía un temporizador fijo y
    /// por eso nunca coincidía con lo que se escuchaba.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechPulse &+= 1
            self.advanceMouth()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.stopSpeakingAnimation()
            self.onSpeechFinished?()

            // Conversación continua: al terminar de hablar reabrimos el micrófono solo.
            guard self.isContinuousSpeechMode else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.isContinuousSpeechMode else { return }
            SpeechAudioManager.shared.startListening()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.stopSpeakingAnimation()
        }
    }
}
