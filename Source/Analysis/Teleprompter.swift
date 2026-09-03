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
///
/// Y no pasa solo. Hubo un avance por reloj calculado sobre el largo de la frase,
/// pero ningún reloj sabe que el alumno lleva medio minuto contestando: la línea
/// se iba mientras seguías en la anterior. La única señal buena de que una frase
/// se acabó es que quien la lee toque "Siguiente".
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

    /// Devuelve el veredicto de la linea actual. Si esta puesto, el HUD enseña los
    /// botones de bien y mal; si no, no ocupan sitio.
    var onVerdict: ((Int, Bool) -> Void)?

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
    ///
    /// Deja el guion parado donde diga `startAt`. Pasar es cosa de "Siguiente ▶",
    /// igual en preguntas, en grietas y en fallos.
    /// - Parameter startAt: linea de arranque, para los modulos que llevan su
    ///   propio cursor. Va aqui y no en un metodo aparte porque colocarlo despues
    ///   de cambiar de modo cuesta un segundo envio de pantalla entera, y el SDK
    ///   no tiene actualizacion parcial: se veria saltar de la primera a la suya.
    func present(_ newLines: [String],
                 title newTitle: String,
                 kind newKind: Kind = .questions,
                 support newSupport: [String] = [],
                 startAt: Int = 0) async {
        load(newLines, title: newTitle, kind: newKind, support: newSupport)
        guard !lines.isEmpty else { return }
        if lines.indices.contains(startAt) { index = startAt }
        // Nada de voz: si algo estaba hablando, aqui se calla. Leer el HUD con el
        // sintetizador encima es exactamente lo que se queria quitar.
        AvatarHUDManager.shared.stopAll()
        await HUDGridManager.shared.switchMode(.teleprompter)
    }

    var currentSupport: String? {
        support.indices.contains(index) ? support[index] : nil
    }

    // MARK: - Avance

    /// Avanza en circulo: al llegar al final vuelve a la primera. Con cuatro
    /// preguntas delante del stand, quedarse clavado en la ultima obligaria a
    /// salir y volver a entrar solo para repasar.
    func next() {
        guard !lines.isEmpty else { return }
        index = (index + 1) % lines.count
    }

    func previous() {
        guard !lines.isEmpty else { return }
        index = index == 0 ? lines.count - 1 : index - 1
    }
}
