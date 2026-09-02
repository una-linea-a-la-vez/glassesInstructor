import Foundation

/// Tono de una línea del guion. Define cómo se pinta y con qué énfasis se lee.
enum ScriptTone {
    case neutral      // contexto
    case positive     // algo bien hecho
    case concern      // algo que revisar
    case verdict      // conclusión
    case action       // qué hacer

    var glyph: String {
        switch self {
        case .neutral: return "›"
        case .positive: return "+"
        case .concern: return "!"
        case .verdict: return "="
        case .action: return "→"
        }
    }
}

/// Una frase que el avatar dice. `spoken` puede diferir de `written` porque
/// "0/100" se lee mal: al oído funciona "cero de cien".
struct ScriptLine: Identifiable {
    let id = UUID()
    let written: String
    let spoken: String
    let tone: ScriptTone

    init(_ written: String, spoken: String? = nil, tone: ScriptTone = .neutral) {
        self.written = written
        self.spoken = spoken ?? written
        self.tone = tone
    }
}

/// Convierte un `LinkAnalysis` en algo que se pueda contar en voz alta.
///
/// Es determinista a propósito: se genera on-device en microsegundos, sin llamar
/// a ningún modelo. El avatar empieza a hablar de inmediato en vez de esperar a
/// una API. Un LLM puede reescribir estas líneas después para darles más color,
/// pero la versión hablable existe desde el primer frame.
struct AvatarScript {
    let lines: [ScriptLine]

    var fullSpokenText: String {
        lines.map(\.spoken).joined(separator: " ")
    }

    static func build(from analysis: LinkAnalysis) -> AvatarScript {
        var lines: [ScriptLine] = []

        // 1. Qué miré
        lines.append(ScriptLine(
            "Analicé \(analysis.domain)",
            spoken: "Analicé \(pronounceable(analysis.domain)).",
            tone: .neutral))

        // 2. Qué es
        if let title = analysis.title {
            var intro = "Se llama \(title)"
            if let framework = analysis.framework {
                intro += ", construido con \(framework)"
            }
            lines.append(ScriptLine(intro + ".", tone: .neutral))
        }

        if let description = analysis.metaDescription {
            lines.append(ScriptLine("\"\(description)\"",
                                    spoken: "Se describe así: \(description)",
                                    tone: .neutral))
        }

        // 3. Seguridad
        let secScore = analysis.securityScore
        let missing = analysis.missingSecurityHeaders.count
        if missing > 0 {
            lines.append(ScriptLine(
                "Seguridad: \(secScore)/100 — faltan \(missing) headers",
                spoken: "En seguridad saqué \(numberInWords(secScore)) de cien. "
                      + "Le faltan \(numberInWords(missing)) de los cinco headers que tú controlas.",
                tone: missing >= 4 ? .concern : .neutral))
        } else {
            lines.append(ScriptLine(
                "Seguridad: \(secScore)/100 — headers completos",
                spoken: "En seguridad saqué \(numberInWords(secScore)) de cien. "
                      + "Tiene sus headers configurados.",
                tone: .positive))
        }

        // 4. Artesanía, con la evidencia que más pesa
        if analysis.layer >= .craft {
            let craft = analysis.craftScore
            lines.append(ScriptLine(
                "Artesanía: \(craft)/100",
                spoken: "En artesanía saqué \(numberInWords(craft)) de cien.",
                tone: craft >= 70 ? .positive : (craft >= 40 ? .neutral : .concern)))

            // La señal positiva más fuerte es la que decide si está vibecodeado
            if let best = analysis.signals.filter({ $0.weight > 0 }).max(by: { $0.weight < $1.weight }) {
                lines.append(ScriptLine(
                    best.title,
                    spoken: "Lo que más me convence: \(best.title.lowercased()). \(best.detail).",
                    tone: .positive))
            }

            if let worst = analysis.signals.filter({ $0.weight < 0 }).min(by: { $0.weight < $1.weight }) {
                lines.append(ScriptLine(
                    worst.title,
                    spoken: "Lo que más le resta: \(worst.title.lowercased()). \(worst.detail).",
                    tone: .concern))
            }
        }

        // 5. Veredicto
        lines.append(ScriptLine(verdictWritten(analysis),
                                spoken: verdictSpoken(analysis),
                                tone: .verdict))

        // 6. Qué hacer
        if missing > 0 {
            lines.append(ScriptLine(
                "Configura los headers en next.config.js",
                spoken: "Mi recomendación: diez minutos configurando headers "
                      + "y pasas de \(numberInWords(secScore)) a cien.",
                tone: .action))
        }

        return AvatarScript(lines: lines)
    }

    // MARK: - Veredicto

    private static func verdictWritten(_ a: LinkAnalysis) -> String {
        guard a.layer >= .craft else { return "Análisis parcial" }
        if a.craftScore >= 70 && a.securityScore < 40 {
            return "Bien construido, infraestructura sin configurar"
        }
        if a.craftScore >= 70 { return "Proyecto sólido" }
        if a.craftScore < 40 { return "Señales de código sin criterio" }
        return "Proyecto correcto, con detalles pendientes"
    }

    private static func verdictSpoken(_ a: LinkAnalysis) -> String {
        guard a.layer >= .craft else {
            return "Todavía no termino de analizarlo."
        }
        if a.craftScore >= 70 && a.securityScore < 40 {
            return "Mi veredicto: el código está bien hecho, "
                 + "pero la infraestructura quedó sin configurar. "
                 + "No está vibecodeado: falla en lo que se configura, no en lo que se piensa."
        }
        if a.craftScore >= 70 {
            return "Mi veredicto: es un proyecto sólido. Se nota criterio en las decisiones."
        }
        if a.craftScore < 40 {
            return "Mi veredicto: tiene señales de código escrito sin entenderlo. "
                 + "Falla justo donde falla el código generado sin criterio."
        }
        return "Mi veredicto: es correcto, pero le faltan detalles de acabado."
    }

    // MARK: - Utilidades de pronunciación

    /// "verdana-loop.vercel.app" se lee horrible carácter por carácter.
    private static func pronounceable(_ domain: String) -> String {
        domain
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " punto ")
    }

    /// El sintetizador lee "0" como "cero" pero "0/100" lo parte raro.
    private static func numberInWords(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "es_MX")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
