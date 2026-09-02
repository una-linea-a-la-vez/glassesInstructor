import Foundation
import Combine

/// Los tres papeles que puede adoptar el agente sobre un proyecto ya escaneado.
/// Todos parten de la **misma evidencia** recogida por `LinkAnalyzer`: ninguno
/// opina sin un dato medido detrás.
enum AuditRole: String, CaseIterable, Identifiable {
    /// Qué está expuesto y qué se puede romper desde fuera.
    case vulnerabilities
    /// Preguntas para saber si quien lo presenta entiende lo que presenta.
    case interrogate
    /// Cómo tirarlo: los bordes donde se cae.
    case stress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vulnerabilities: return "Vulnerabilidades"
        case .interrogate: return "Preguntas"
        case .stress: return "Tronarlo"
        }
    }

    /// Etiqueta corta: el waveguide no admite botones largos.
    var hudLabel: String {
        switch self {
        case .vulnerabilities: return "🔓 Exposición"
        case .interrogate: return "❓ Preguntas"
        case .stress: return "💥 Tronarlo"
        }
    }

    var systemPrompt: String {
        let common = """
        Respondes sobre un proyecto web de una feria de ciencias, a partir de evidencia \
        medida por un analizador automático. Reglas estrictas de formato porque tu salida \
        se proyecta en unas gafas con pantalla monocroma:
        - Devuelve entre 3 y 5 líneas.
        - Una idea por línea, máximo 60 caracteres por línea.
        - Sin markdown, sin negritas, sin numeración, sin emojis.
        - Nunca inventes un dato que no esté en la evidencia. Si algo no se midió, dilo.
        """

        switch self {
        case .vulnerabilities:
            return common + """

            Papel: auditor de seguridad. Señala qué está expuesto y qué falta, citando el \
            header o el hallazgo concreto. Distingue lo que es riesgo real de lo que sólo \
            es higiene. Si hay source maps expuestos, es lo primero que dices.
            """
        case .interrogate:
            return common + """

            Papel: jurado técnico. Genera preguntas para distinguir a quien entendió su \
            código de quien lo generó sin entenderlo. Una buena pregunta apunta al PORQUÉ \
            de una decisión o al BORDE donde falla; nunca a datos que se leen de los \
            headers. Cada línea es una pregunta directa al estudiante, en segunda persona.
            """
        case .stress:
            return common + """

            Papel: probador de carga y bordes. Propón formas concretas de tirar o degradar \
            este proyecto, derivadas de la evidencia (TTFB alto, ausencia de límites, peso \
            del bundle, estado de carga inexistente). Cada línea, una prueba ejecutable.
            """
        }
    }
}

/// Une las dos mitades que ya existían por separado: el escaneo de QR de las gafas y
/// la cascada de análisis. Pinta el HUD en cuanto hay algo que pintar y sólo después
/// llama al modelo, de modo que la latencia del LLM caiga sobre una pantalla que ya
/// tiene contenido.
@MainActor
class ProjectAuditAgent: ObservableObject {
    static let shared = ProjectAuditAgent()

    @Published var analysis: LinkAnalysis? = nil
    @Published var statusLine: String = "Sin proyecto escaneado"
    @Published var isAnalyzing: Bool = false
    @Published var isGenerating: Bool = false

    @Published var activeRole: AuditRole? = nil
    /// Salida del papel activo, ya partida en líneas que caben en el waveguide.
    @Published var findings: [String] = []
    /// Línea visible: el HUD muestra de una en una para no saturar.
    @Published var cursor: Int = 0

    /// Objetivos de prueba para ensayar el flujo completo sin depender de un QR físico
    /// ni de las gafas. Útil para medir voz y latencia antes de la feria.
    static let demoTargets: [URL] = [
        "https://verdana-loop.vercel.app/"
    ].compactMap(URL.init(string:))

    private init() {}

    // MARK: - Escaneo

    /// Analiza el primer objetivo de prueba, saltándose la cámara.
    func auditDemoTarget() async {
        guard let url = Self.demoTargets.first else { return }
        DiagnosticLogger.shared.log(.info, tag: "Audit", message: "Ejecutando objetivo de prueba: \(url.absoluteString)")
        await audit(url: url)
    }

    /// Precalienta los objetivos conocidos para que la demo salga de caché y no pague la red.
    func warmDemoTargets() async {
        await LinkAnalyzer.shared.warm(Self.demoTargets)
        DiagnosticLogger.shared.log(.success, tag: "Audit", message: "Objetivos de prueba precalentados (\(Self.demoTargets.count)).")
    }

    /// Consume la cascada de `LinkAnalyzer` repintando el HUD en cada capa.
    func audit(url: URL) async {
        analysis = nil
        findings = []
        activeRole = nil
        cursor = 0
        isAnalyzing = true
        statusLine = "Analizando \(url.host ?? url.absoluteString)..."

        DiagnosticLogger.shared.log(.info, tag: "Audit", message: "Iniciando análisis de \(url.absoluteString)")
        await HUDGridManager.shared.renderCurrentState(force: true)

        for await partial in LinkAnalyzer.shared.analyze(url) {
            analysis = partial
            statusLine = partial.layer.label
            // Cada capa repinta; la puerta de transmisión del HUD evita saturar el canal.
            await HUDGridManager.shared.renderCurrentState()
        }

        isAnalyzing = false

        guard let analysis else {
            statusLine = "No se pudo alcanzar el sitio"
            DiagnosticLogger.shared.log(.error, tag: "Audit", message: "El análisis no devolvió resultado (sitio inalcanzable).")
            await HUDGridManager.shared.renderCurrentState(force: true)
            return
        }

        statusLine = "Listo · elige un agente"
        DiagnosticLogger.shared.log(
            .success,
            tag: "Audit",
            message: "Análisis completo: SEC \(analysis.securityScore)/100, CRAFT \(analysis.craftScore)/100, \(analysis.signals.count) señales."
        )
        await HUDGridManager.shared.renderCurrentState(force: true)
    }

    // MARK: - Agentes

    func run(role: AuditRole) async {
        guard let analysis else {
            statusLine = "Escanea un QR primero"
            return
        }

        activeRole = role
        isGenerating = true
        cursor = 0
        findings = []
        statusLine = "\(role.label): pensando..."
        await HUDGridManager.shared.renderCurrentState(force: true)

        let response = await ClaudeManager.shared.complete(
            prompt: Self.evidenceBlock(from: analysis),
            system: role.systemPrompt,
            maxTokens: 400
        )

        findings = Self.splitIntoHUDLines(response)
        isGenerating = false
        statusLine = findings.isEmpty ? "Sin resultados" : "\(role.label) 1/\(findings.count)"

        DiagnosticLogger.shared.log(.success, tag: "Audit", message: "\(role.label): \(findings.count) líneas en \(ClaudeManager.shared.lastLatencyMs) ms.")
        await HUDGridManager.shared.renderCurrentState(force: true)
    }

    /// Instrucciones de formato para la lectura del ambiente.
    private static let environmentSystemPrompt = [
        "Describes el entorno de una feria de proyectos estudiantiles a partir de una foto",
        "tomada desde unas gafas. Tu salida se proyecta en una pantalla monocroma diminuta:",
        "- Entre 3 y 5 lineas.",
        "- Una idea por linea, maximo 60 caracteres por linea.",
        "- Sin markdown, sin numeracion, sin emojis.",
        "- Solo lo que se ve. Si algo no se distingue, no lo inventes."
    ].joined(separator: "\n")

    /// Toma **una** foto con las gafas y se la manda a Claude para leer el ambiente.
    /// Usa captura puntual, no stream: el streaming sostenido dispara el corte térmico.
    func scanEnvironment() async {
        findings = []
        activeRole = nil
        cursor = 0
        isGenerating = true
        statusLine = "Tomando foto..."
        await HUDGridManager.shared.renderCurrentState(force: true)

        do {
            let jpeg = try await CameraStreamManager.shared.capturePhotoOnce()
            statusLine = "Leyendo el ambiente..."
            await HUDGridManager.shared.renderCurrentState(force: true)

            let response = await ClaudeManager.shared.complete(
                prompt: "Describe que proyectos o stands se ven en esta foto de una feria de ciencias. Si distingues carteles, pantallas o codigos QR, dilo.",
                system: Self.environmentSystemPrompt,
                imageJPEG: jpeg,
                maxTokens: 400
            )

            findings = Self.splitIntoHUDLines(response)
            statusLine = findings.isEmpty
                ? "Sin lectura"
                : "Ambiente 1/\(findings.count) · \(ClaudeManager.shared.lastLatencyMs) ms"
            DiagnosticLogger.shared.log(.success, tag: "Ambiente", message: "Lectura en \(ClaudeManager.shared.lastLatencyMs) ms.")
        } catch {
            statusLine = error.localizedDescription
            DiagnosticLogger.shared.log(.error, tag: "Ambiente", message: "Fallo la captura: \(error.localizedDescription)")
        }

        isGenerating = false
        await HUDGridManager.shared.renderCurrentState(force: true)
    }

    func advanceCursor() {
        guard !findings.isEmpty else { return }
        cursor = (cursor + 1) % findings.count
        if let activeRole {
            statusLine = "\(activeRole.label) \(cursor + 1)/\(findings.count)"
        }
    }

    func reset() {
        analysis = nil
        findings = []
        activeRole = nil
        cursor = 0
        statusLine = "Sin proyecto escaneado"
    }

    // MARK: - Presentación

    /// Máximo cuatro líneas: es lo que cabe legible en el waveguide 600x600.
    var hudLines: [String] {
        guard let analysis else { return [statusLine] }

        if !findings.isEmpty {
            return [analysis.domain, statusLine, findings[cursor]]
        }
        return Array(analysis.hudLines.prefix(4))
    }

    /// Aplana la respuesta del modelo a líneas cortas, descartando viñetas y numeración
    /// por si el modelo ignora la instrucción de formato.
    private static func splitIntoHUDLines(_ text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                while let first = trimmed.first, "-*•0123456789.".contains(first) {
                    trimmed.removeFirst()
                    trimmed = trimmed.trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    /// Serializa lo medido. El modelo sólo puede razonar sobre esto.
    private static func evidenceBlock(from a: LinkAnalysis) -> String {
        var lines: [String] = ["EVIDENCIA MEDIDA DEL PROYECTO", "URL: \(a.url.absoluteString)"]

        if let status = a.httpStatus { lines.append("HTTP: \(status)") }
        if let ttfb = a.ttfbMilliseconds { lines.append("TTFB: \(ttfb) ms") }
        if let server = a.server { lines.append("Servidor: \(server)") }
        if let framework = a.framework { lines.append("Framework detectado: \(framework)") }
        if let bytes = a.transferredBytes { lines.append("Bytes transferidos: \(bytes)") }

        lines.append("Score seguridad: \(a.securityScore)/100")
        lines.append("Headers presentes: \(a.presentSecurityHeaders.isEmpty ? "ninguno" : a.presentSecurityHeaders.joined(separator: ", "))")
        lines.append("Headers ausentes: \(a.missingSecurityHeaders.isEmpty ? "ninguno" : a.missingSecurityHeaders.joined(separator: ", "))")

        if let title = a.title { lines.append("Título: \(title)") }
        if let language = a.language { lines.append("Idioma declarado: \(language)") }
        lines.append("Open Graph: \(a.hasOpenGraph ? "sí" : "no")")
        lines.append("Encabezados: \(a.headingCount) · Landmarks: \(a.landmarkCount) · Interactivos: \(a.interactiveCount)")
        lines.append("Atributos ARIA: \(a.ariaLabelCount)")

        if let maps = a.sourceMapsExposed { lines.append("Source maps expuestos: \(maps ? "SÍ" : "no")") }
        if let motion = a.respectsReducedMotion { lines.append("Respeta prefers-reduced-motion: \(motion ? "sí" : "no")") }

        lines.append("Score artesanía: \(a.craftScore)/100")
        if !a.signals.isEmpty {
            lines.append("Señales:")
            for signal in a.signals {
                let caveat = signal.isFalsePositiveRisk ? " [posible falso positivo]" : ""
                lines.append("- \(signal.title): \(signal.detail) (peso \(signal.weight))\(caveat)")
            }
        }

        if a.layer < .craft {
            lines.append("NOTA: el análisis no llegó a la capa de artesanía; no afirmes nada sobre ella.")
        }

        return lines.joined(separator: "\n")
    }
}
