import Foundation
import Combine

/// Guion que se lee en voz alta desde las gafas.
///
/// Preguntas y grietas ya existían, pero repartidas en varias líneas pequeñas que
/// obligaban a descifrar la pantalla mientras hablas. Un teleprompter hace lo
/// contrario: una sola frase grande cada vez, para levantar la vista y soltarla
/// sin perder el hilo ni mirar el teléfono.
@MainActor
class Teleprompter: ObservableObject {
    static let shared = Teleprompter()

    /// Qué se está leyendo. El HUD pinta distinto cada uno: una pregunta se suelta
    /// tal cual, una grieta necesita el dato a la vista para poder citarlo.
    enum Kind {
        case questions
        case challenges
    }

    @Published private(set) var kind: Kind = .questions
    /// Apoyo opcional por linea. En grietas es el dato medido que la sostiene.
    @Published private(set) var support: [String] = []

    @Published private(set) var lines: [String] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var title: String = ""
    @Published private(set) var isAutoAdvancing: Bool = false

    /// El avatar dicta cada línea. Cuando está activo el avance NO va por reloj:
    /// espera a que termine de hablar, que es la unica señal fiable de que la
    /// frase se acabó. Un temporizador cortaría a media palabra en las largas.
    @Published private(set) var isDictating: Bool = false

    /// Devuelve el veredicto de la linea actual. Si esta puesto, el HUD enseña los
    /// botones de bien y mal; si no, no ocupan sitio.
    var onVerdict: ((Int, Bool) -> Void)?

    private var timer: Timer?

    private init() {}

    var current: String? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    var position: String {
        lines.isEmpty ? "" : "\(index + 1)/\(lines.count)"
    }

    var isEmpty: Bool { lines.isEmpty }

    // MARK: - Carga

    /// Marca la linea actual y pasa a la siguiente: comprobar y avanzar son el
    /// mismo gesto cuando vas fallo por fallo delante del stand.
    func judge(_ passed: Bool) {
        onVerdict?(index, passed)
        next()
    }

    func load(_ newLines: [String],
              title newTitle: String,
              kind newKind: Kind = .questions,
              support newSupport: [String] = []) {
        stopAuto()
        lines = newLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        support = newSupport
        // Sin esto, un guion de preguntas heredaria el juez del modulo de fallos.
        if newKind == .questions { onVerdict = nil }
        index = 0
        title = newTitle
        kind = newKind
        DiagnosticLogger.shared.log(.info, tag: "Teleprompter",
            message: "\(lines.count) líneas cargadas: \(newTitle).")
    }

    /// Carga y se muestra en las gafas sin que nadie pulse nada.
    ///
    /// Antes habia que darle a un boton en el telefono, que es justo lo que no
    /// puedes hacer con el alumno delante: si acabas de pedir las preguntas, es
    /// obvio que las quieres leer.
    func present(_ newLines: [String],
                 title newTitle: String,
                 kind newKind: Kind = .questions,
                 support newSupport: [String] = [],
                 dictate: Bool = true) async {
        load(newLines, title: newTitle, kind: newKind, support: newSupport)
        guard !lines.isEmpty else { return }
        await HUDGridManager.shared.switchMode(.teleprompter)

        if dictate {
            startDictation()
            return
        }
        // Arranca solo: pasar de linea con la pulsera obliga a un envio entero de
        // pantalla cada vez, y encadenar toques ahi es donde se notaba el retraso.
        // Leyendo al ritmo del texto no hace falta tocar nada.
        toggleAuto()
    }

    // MARK: - Dictado

    /// El avatar lee la línea actual y encadena con la siguiente al terminar.
    func startDictation() {
        stopAuto()
        isDictating = true

        AvatarHUDManager.shared.onSpeechFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.isDictating else { return }
                // Respiro entre frases: encadenar sin pausa suena a maquina y no
                // deja hueco para que el alumno empiece a contestar.
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard self.isDictating else { return }
                self.next()
                await HUDGridManager.shared.renderCurrentState(force: true)
                self.speakCurrent()
            }
        }

        speakCurrent()
    }

    func stopDictation() {
        isDictating = false
        AvatarHUDManager.shared.onSpeechFinished = nil
        AvatarHUDManager.shared.stopAll()
    }

    private func speakCurrent() {
        guard let current else { return }
        AvatarHUDManager.shared.startSpeakingAnimation(textToSpeak: current)
    }

    var currentSupport: String? {
        support.indices.contains(index) ? support[index] : nil
    }

    // MARK: - Avance

    func next() {
        guard !lines.isEmpty else { return }
        index = (index + 1) % lines.count
        rearmIfAuto()
    }

    func previous() {
        guard !lines.isEmpty else { return }
        index = index == 0 ? lines.count - 1 : index - 1
        rearmIfAuto()
    }

    /// Avance solo, al ritmo al que se lee la frase en voz alta.
    func toggleAuto() {
        isAutoAdvancing ? stopAuto() : startAuto()
    }

    private func startAuto() {
        guard !lines.isEmpty else { return }
        isAutoAdvancing = true
        rearmIfAuto()
    }

    func stopAuto() {
        isAutoAdvancing = false
        timer?.invalidate()
        timer = nil
    }

    /// Corta todo: reloj y voz. Lo llama el boton de salir del HUD.
    func stopEverything() {
        stopAuto()
        stopDictation()
    }

    /// El intervalo sale del largo de la frase, no de un valor fijo: una pregunta
    /// de diez palabras y una de treinta no se leen en el mismo tiempo, y un ritmo
    /// fijo te deja a medias en la larga o esperando en la corta.
    private func rearmIfAuto() {
        timer?.invalidate()
        guard isAutoAdvancing, let current else { return }

        // ~12 caracteres por segundo leyendo en voz alta, con un mínimo para que
        // ninguna frase pase antes de poder soltarla.
        let seconds = max(3.5, Double(current.count) / 12.0)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAutoAdvancing else { return }
                self.next()
                await HUDGridManager.shared.renderCurrentState()
            }
        }
    }
}
