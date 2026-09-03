import Foundation

/// Lo que el repositorio cuenta sobre cómo se construyó el proyecto.
///
/// El sitio desplegado enseña el resultado; el historial enseña el proceso. Doce
/// commits en cinco horas de la víspera dicen algo que ningún header revela.
struct RepoAnalysis {
    let owner: String
    let name: String

    var createdAt: Date?
    var pushedAt: Date?
    var description: String?
    var license: String?
    var languages: [String] = []

    var commitCount: Int = 0
    var firstCommit: Date?
    var lastCommit: Date?
    var contributors: [String] = []
    /// Proporción de mensajes vacíos de contenido ("update", "fix", "wip"...).
    var genericMessageRatio: Double = 0
    /// El primer commit trae ya el proyecto entero.
    var startsWithBigDump: Bool = false

    var hasTests: Bool = false
    var hasCI: Bool = false
    var hasReadme: Bool = false

    /// Días entre el primer y el último commit vistos.
    var activeSpanDays: Int? {
        guard let first = firstCommit, let last = lastCommit else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0)
    }

    /// Resumen para el modelo. Solo hechos; la lectura la hace él.
    var evidenceLines: [String] {
        var lines = ["REPOSITORIO: \(owner)/\(name)"]

        if let description { lines.append("Descripción: \(description)") }
        if !languages.isEmpty { lines.append("Lenguajes: \(languages.joined(separator: ", "))") }
        lines.append("Commits vistos: \(commitCount)")

        if let span = activeSpanDays {
            lines.append(span == 0
                ? "Todos los commits caen en el MISMO día"
                : "Actividad repartida en \(span) días")
        }
        if let first = firstCommit { lines.append("Primer commit: \(Self.day.string(from: first))") }
        if let last = lastCommit { lines.append("Último commit: \(Self.day.string(from: last))") }

        lines.append("Personas que han commiteado: \(contributors.count)"
                     + (contributors.isEmpty ? "" : " (\(contributors.prefix(4).joined(separator: ", ")))"))

        if commitCount > 0 {
            lines.append("Mensajes de commit genéricos: \(Int(genericMessageRatio * 100))%")
        }
        if startsWithBigDump {
            lines.append("El historial arranca con un único commit que ya trae el proyecto entero")
        }

        lines.append("Tests: \(hasTests ? "sí" : "no se ven")")
        lines.append("Integración continua: \(hasCI ? "sí" : "no se ve")")
        lines.append("Licencia: \(license ?? "ninguna")")

        return lines
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Lee un repositorio público de GitHub. Sin credenciales: la API anónima basta y
/// permite 60 peticiones por hora, de sobra para una feria si se guarda el resultado.
actor RepoAnalyzer {
    static let shared = RepoAnalyzer()

    private var cache: [String: RepoAnalysis] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Mensajes que no dicen qué se hizo ni por qué.
    private static let genericMessages = [
        "update", "updates", "fix", "fixes", "wip", "changes", "commit",
        "initial commit", "first commit", "test", "new", "add", "edit", "."
    ]

    /// Saca owner/repo de una URL de GitHub. Devuelve nil si no lo es.
    nonisolated static func repoPath(from url: URL) -> (owner: String, name: String)? {
        guard url.host?.contains("github.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
    }

    func analyze(owner: String, name: String) async -> RepoAnalysis? {
        let key = "\(owner)/\(name)"
        if let cached = cache[key] { return cached }

        guard var analysis = await fetchMetadata(owner: owner, name: name) else { return nil }
        // Las tres llamadas son independientes entre si, asi que van a la vez.
        // En fila costaban la suma de las cuatro esperas de red; asi cuestan la
        // mas lenta de las tres mas la de metadatos.
        async let commits = commitFacts(owner: owner, name: name)
        async let languages = languageList(owner: owner, name: name)
        async let rootFiles = rootFileFlags(owner: owner, name: name)

        let (facts, langs, flags) = await (commits, languages, rootFiles)

        analysis.commitCount = facts.count
        analysis.firstCommit = facts.first
        analysis.lastCommit = facts.last
        analysis.contributors = facts.authors
        analysis.genericMessageRatio = facts.genericRatio
        analysis.startsWithBigDump = facts.isDump
        analysis.languages = langs
        analysis.hasReadme = flags.readme
        analysis.hasCI = flags.ci
        analysis.hasTests = flags.tests

        cache[key] = analysis
        DiagnosticLogger.shared.log(.success, tag: "Repo",
            message: "\(key): \(analysis.commitCount) commits, \(analysis.contributors.count) personas.")
        return analysis
    }

    // MARK: - Llamadas

    private func fetchMetadata(owner: String, name: String) async -> RepoAnalysis? {
        guard let root = await json(at: "https://api.github.com/repos/\(owner)/\(name)") as? [String: Any] else {
            return nil
        }

        var analysis = RepoAnalysis(owner: owner, name: name)
        analysis.description = root["description"] as? String
        analysis.createdAt = Self.parseDate(root["created_at"])
        analysis.pushedAt = Self.parseDate(root["pushed_at"])
        if let license = root["license"] as? [String: Any] {
            analysis.license = license["spdx_id"] as? String
        }
        return analysis
    }

    struct CommitFacts {
        var count = 0
        var first: Date?
        var last: Date?
        var authors: [String] = []
        var genericRatio: Double = 0
        var isDump = false
    }

    /// Historial: cuantos commits, cuando, quien y con que mensajes.
    private func commitFacts(owner: String, name: String) async -> CommitFacts {
        var facts = CommitFacts()
        let path = "https://api.github.com/repos/\(owner)/\(name)/commits?per_page=100"
        guard let list = await json(at: path) as? [[String: Any]], !list.isEmpty else { return facts }

        facts.count = list.count

        var dates: [Date] = []
        var authors: Set<String> = []
        var generic = 0

        for entry in list {
            guard let commit = entry["commit"] as? [String: Any] else { continue }
            if let author = commit["author"] as? [String: Any],
               let date = Self.parseDate(author["date"]) {
                dates.append(date)
            }
            if let login = (entry["author"] as? [String: Any])?["login"] as? String {
                authors.insert(login)
            } else if let author = commit["author"] as? [String: Any],
                      let named = author["name"] as? String {
                authors.insert(named)
            }
            if let message = commit["message"] as? String, Self.isGeneric(message) {
                generic += 1
            }
        }

        facts.first = dates.min()
        facts.last = dates.max()
        facts.authors = authors.sorted()
        facts.genericRatio = Double(generic) / Double(list.count)

        // Un unico commit, o el historial entero en menos de una hora: el proyecto
        // no se fue construyendo, se volco de golpe.
        if let first = facts.first, let last = facts.last {
            facts.isDump = list.count == 1 || last.timeIntervalSince(first) < 3600
        }
        return facts
    }

    private func languageList(owner: String, name: String) async -> [String] {
        let path = "https://api.github.com/repos/\(owner)/\(name)/languages"
        guard let map = await json(at: path) as? [String: Any] else { return [] }
        // De mas usado a menos, que es como se lee.
        return map
            .compactMap { key, value in (value as? Int).map { (key, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Señales de oficio que se ven sin clonar: tests, CI y README.
    private func rootFileFlags(owner: String, name: String) async -> (readme: Bool, ci: Bool, tests: Bool) {
        let path = "https://api.github.com/repos/\(owner)/\(name)/contents/"
        guard let entries = await json(at: path) as? [[String: Any]] else { return (false, false, false) }

        let names = entries.compactMap { ($0["name"] as? String)?.lowercased() }
        return (
            readme: names.contains { $0.hasPrefix("readme") },
            ci: names.contains(".github") || names.contains { $0.hasPrefix(".gitlab-ci") },
            tests: names.contains { $0 == "tests" || $0 == "test" || $0 == "__tests__" || $0 == "spec" }
        )
    }

    private func json(at urlString: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        guard http.statusCode == 200 else {
            DiagnosticLogger.shared.log(.warning, tag: "Repo",
                message: "GitHub respondió \(http.statusCode) en \(urlString.suffix(40)).")
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    nonisolated static func isGeneric(_ message: String) -> Bool {
        let first = message
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return genericMessages.contains(first) || first.count <= 3
    }
}
