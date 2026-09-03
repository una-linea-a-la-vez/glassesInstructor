import Foundation
import Combine

/// Un stand que se quiere tener listo antes de pisar la feria.
struct PreloadEntry: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    var isReady: Bool = false
    var note: String = "Sin precargar"
}

/// Deja los proyectos analizados y con preguntas hechas antes de que haga falta.
///
/// La feria tiene internet a ratos, y el rato en que no lo tiene suele coincidir con
/// el momento de usarlo. Precargar en casa convierte cada consulta del dia siguiente
/// en una lectura de memoria: ni red ni espera.
///
/// Se precargan las dos mitades caras, no solo una: el analisis del sitio y una
/// tanda de preguntas. Analizar sin preguntas dejaria la espera larga justo cuando
/// tienes al alumno delante.
@MainActor
class ProjectPreloader: ObservableObject {
    static let shared = ProjectPreloader()

    @Published var entries: [PreloadEntry] = []
    @Published var isWorking: Bool = false
    @Published var progress: String = ""

    private let storeKey = "PreloadEntries"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([PreloadEntry].self, from: data) {
            // El estado de "listo" no sobrevive al reinicio: las cachés viven en
            // memoria, así que al abrir de nuevo hay que volver a precargar.
            entries = saved.map { PreloadEntry(url: $0.url) }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    // MARK: - Lista

    func add(_ raw: String) {
        guard let url = QRScanner.navigableURL(from: raw.trimmingCharacters(in: .whitespaces)) else { return }
        let entry = PreloadEntry(url: url.absoluteString)
        guard !entries.contains(entry) else { return }
        entries.append(entry)
        persist()
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        persist()
    }

    /// Añade los proyectos ya escaneados, que es de donde salen sin teclear.
    func addFromRegistry() {
        for project in ProjectRegistry.shared.projects {
            add(project.url.absoluteString)
        }
    }

    // MARK: - Precarga

    func preloadAll() async {
        guard !entries.isEmpty else { return }
        isWorking = true
        defer { isWorking = false; progress = "" }

        // Se guarda el proyecto activo para devolverlo al final: precargar no debe
        // cambiar sobre cuál estás trabajando.
        let previouslyActive = ProjectAuditAgent.shared.analysis?.url

        for index in entries.indices {
            guard let url = URL(string: entries[index].url) else { continue }
            progress = "\(index + 1)/\(entries.count) · \(url.host ?? entries[index].url)"

            await ProjectAuditAgent.shared.audit(url: url)

            guard ProjectAuditAgent.shared.analysis != nil else {
                entries[index].isReady = false
                entries[index].note = "No se pudo alcanzar"
                continue
            }

            // La otra mitad cara: dejar una tanda de preguntas hecha.
            await QuestionSession.shared.ensureQuestions()

            entries[index].isReady = true
            let questions = QuestionSession.shared.questions.count
            entries[index].note = "Listo · \(questions) preguntas"
            DiagnosticLogger.shared.log(.success, tag: "Precarga",
                message: "\(url.host ?? "") listo con \(questions) preguntas.")
        }

        if let previouslyActive {
            await ProjectAuditAgent.shared.audit(url: previouslyActive)
        }
        persist()
    }
}
