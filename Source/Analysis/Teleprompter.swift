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

    @Published private(set) var lines: [String] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var title: String = ""
    @Published private(set) var isAutoAdvancing: Bool = false

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

    func load(_ newLines: [String], title newTitle: String) {
        stopAuto()
        lines = newLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        index = 0
        title = newTitle
        DiagnosticLogger.shared.log(.info, tag: "Teleprompter",
            message: "\(lines.count) líneas cargadas: \(newTitle).")
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
                await HUDGridManager.shared.renderCurrentState(force: true)
            }
        }
    }
}
