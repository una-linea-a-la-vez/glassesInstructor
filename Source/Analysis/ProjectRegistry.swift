import Foundation
import Combine

/// Un proyecto ya escaneado, con lo que se midió y lo que se le preguntó.
struct RegisteredProject: Identifiable, Equatable {
    /// La URL identifica el proyecto: escanear dos veces el mismo QR no crea otro.
    var id: String { url.absoluteString }

    let url: URL
    let domain: String
    let scannedAt: Date
    var securityScore: Int
    var craftScore: Int
    var answeredCount: Int = 0

    static func == (a: RegisteredProject, b: RegisteredProject) -> Bool { a.id == b.id }
}

/// Historial de proyectos de la feria.
///
/// Antes, escanear un stand nuevo pisaba al anterior y su análisis se perdía. En
/// una feria vas de mesa en mesa y luego quieres volver sobre lo que viste, así que
/// el que estaba pasa al registro y el recién escaneado queda activo. Reactivar uno
/// no cuesta red: `LinkAnalyzer` ya guarda su análisis.
@MainActor
class ProjectRegistry: ObservableObject {
    static let shared = ProjectRegistry()

    /// Más reciente primero.
    @Published private(set) var projects: [RegisteredProject] = []
    @Published private(set) var activeID: String?

    private init() {}

    var active: RegisteredProject? {
        projects.first { $0.id == activeID }
    }

    /// Los que ya no están activos: el material para revisar con calma.
    var archived: [RegisteredProject] {
        projects.filter { $0.id != activeID }
    }

    /// Registra el análisis recién hecho y lo deja activo.
    /// - Returns: `true` si es un proyecto que no se había visto antes.
    @discardableResult
    func register(_ analysis: LinkAnalysis) -> Bool {
        let entry = RegisteredProject(
            url: analysis.url,
            domain: analysis.domain,
            scannedAt: Date(),
            securityScore: analysis.securityScore,
            craftScore: analysis.craftScore
        )

        let isNew = !projects.contains(where: { $0.id == entry.id })

        if let index = projects.firstIndex(where: { $0.id == entry.id }) {
            // Ya estaba: se actualizan las notas pero se conserva su historial.
            projects[index].securityScore = entry.securityScore
            projects[index].craftScore = entry.craftScore
        } else {
            projects.insert(entry, at: 0)
        }

        activeID = entry.id

        DiagnosticLogger.shared.log(.success, tag: "Registro",
            message: isNew
                ? "Proyecto nuevo: \(entry.domain). \(projects.count) en total."
                : "Vuelto a \(entry.domain), ya estaba registrado.")

        return isNew
    }

    /// Vuelve a un proyecto archivado sin repetir la red.
    func activate(_ project: RegisteredProject) async {
        activeID = project.id
        DiagnosticLogger.shared.log(.info, tag: "Registro", message: "Volviendo a \(project.domain).")
        // El analizador guarda su resultado, así que esto sale de memoria.
        await ProjectAuditAgent.shared.audit(url: project.url)
    }

    /// Refleja cuántas respuestas se han recogido, para saber qué queda a medias.
    func noteAnswers(for url: URL, count: Int) {
        guard let index = projects.firstIndex(where: { $0.url == url }) else { return }
        projects[index].answeredCount = count
    }
}
