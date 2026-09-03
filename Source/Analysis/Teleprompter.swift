import Foundation
import Combine

/// Guion que se lee EN LA PANTALLA de las gafas. Sin voz, a propósito.
///
/// Preguntas y grietas ya existían, pero repartidas en varias líneas pequeñas que
/// obligaban a descifrar la pantalla mientras hablas. Un teleprompter hace lo
/// contrario: una sola frase grande cada vez, para levantar la vista y soltarla
/// sin perder el hilo ni mirar el teléfono.
///
/// El avatar dictaba cada línea por el auricular. Delante del alumno eso estorba:
/// se habla encima de ti, marca el ritmo por su cuenta y no puedes callarlo sin
/// tocar el HUD. Aquí manda quien lee: el texto se ve, no se oye.
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
    /// - Parameter autoAdvance: pasar de línea solo, al ritmo de lectura. Va bien
    ///   en un guion que se suelta seguido (preguntas, grietas) y mal en algo que
    ///   se lee y se piensa, como un veredicto: ahí se pasa a mano.
    func present(_ newLines: [String],
                 title newTitle: String,
                 kind newKind: Kind = .questions,
                 support newSupport: [String] = [],
                 autoAdvance: Bool = true) async {
        load(newLines, title: newTitle, kind: newKind, support: newSupport)
        guard !lines.isEmpty else { return }
        // Nada de voz: si algo estaba hablando, aqui se calla. Leer el HUD con el
        // sintetizador encima es exactamente lo que se queria quitar.
        AvatarHUDManager.shared.stopAll()
        await HUDGridManager.shared.switchMode(.teleprompter)

        // Arranca solo: pasar de linea con la pulsera obliga a un envio entero de
        // pantalla cada vez, y encadenar toques ahi es donde se notaba el retraso.
        // Leyendo al ritmo del texto no hace falta tocar nada.
        if autoAdvance { toggleAuto() }
    }

    /// Coloca el guion en una línea concreta. Lo usan los módulos que llevan su
    /// propio cursor y necesitan que el HUD enseñe la misma línea que ellos.
    func go(to newIndex: Int) {
        guard lines.indices.contains(newIndex) else { return }
        index = newIndex
        rearmIfAuto()
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

    /// Corta el avance automatico. Lo llama el boton de salir del HUD.
    func stopEverything() {
        stopAuto()
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
