import Foundation
import SwiftUI

/// Capa de la cascada que ya completó. El HUD pinta en cuanto cambia,
/// sin esperar a que termine el análisis completo.
enum AnalysisLayer: Int, Comparable {
    case detected = 0      // 0 ms   · URL decodificada del QR
    case security = 1      // ~200ms · headers de la respuesta
    case identity = 2      // ~600ms · HTML ya recibido en la capa anterior
    case craft = 3         // ~1.5s  · artesanía y bundle

    static func < (lhs: AnalysisLayer, rhs: AnalysisLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .detected: return "Detectado"
        case .security: return "Seguridad"
        case .identity: return "Identidad"
        case .craft: return "Artesanía"
        }
    }
}

/// Semáforo que se pinta en el HUD. Alto contraste, legible en waveguide.
enum Verdict: String {
    case unknown = "—"
    case good = "OK"
    case warning = "REVISAR"
    case bad = "RIESGO"

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .good: return .green
        case .warning: return .yellow
        case .bad: return .red
        }
    }

    var glyph: String {
        switch self {
        case .unknown: return "?"
        case .good: return "OK"
        case .warning: return "!"
        case .bad: return "X"
        }
    }
}

/// Una señal concreta encontrada, con su evidencia. Nunca una opinión suelta:
/// siempre apunta a algo verificable en la respuesta del servidor.
struct AnalysisSignal: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let weight: Int          // negativo resta al score, positivo suma
    let isFalsePositiveRisk: Bool

    init(title: String, detail: String, weight: Int, isFalsePositiveRisk: Bool = false) {
        self.title = title
        self.detail = detail
        self.weight = weight
        self.isFalsePositiveRisk = isFalsePositiveRisk
    }
}

/// Resultado progresivo. Cada capa lo enriquece sin invalidar lo anterior.
struct LinkAnalysis {
    let url: URL
    var layer: AnalysisLayer = .detected

    // Capa 0
    var domain: String { url.host ?? url.absoluteString }

    // Capa 1 · seguridad (solo headers, una petición)
    var ttfbMilliseconds: Int?
    var httpStatus: Int?
    var presentSecurityHeaders: [String] = []
    var missingSecurityHeaders: [String] = []
    var server: String?
    var framework: String?

    // Capa 2 · identidad (mismo HTML de la capa 1)
    var title: String?
    var metaDescription: String?
    var language: String?
    var hasOpenGraph: Bool = false
    var headingCount: Int = 0
    var landmarkCount: Int = 0
    var interactiveCount: Int = 0

    // Capa 3 · artesanía
    var transferredBytes: Int?
    var sourceMapsExposed: Bool?
    var respectsReducedMotion: Bool?
    var ariaLabelCount: Int = 0
    var signals: [AnalysisSignal] = []

    /// 0-100. Solo cuenta headers que el dueño del sitio controla.
    var securityScore: Int {
        let total = presentSecurityHeaders.count + missingSecurityHeaders.count
        guard total > 0 else { return 0 }
        return Int((Double(presentSecurityHeaders.count) / Double(total)) * 100)
    }

    /// Arranca en 50 y se mueve con la evidencia acumulada.
    var craftScore: Int {
        let base = 50
        let delta = signals.reduce(0) { $0 + $1.weight }
        return max(0, min(100, base + delta))
    }

    var securityVerdict: Verdict {
        switch securityScore {
        case 0..<34: return .bad
        case 34..<67: return .warning
        default: return .good
        }
    }

    var craftVerdict: Verdict {
        guard layer >= .craft else { return .unknown }
        switch craftScore {
        case 0..<40: return .bad
        case 40..<70: return .warning
        default: return .good
        }
    }

    /// Cuatro líneas máximo: es lo que cabe legible en el waveguide 600x600.
    var hudLines: [String] {
        var lines: [String] = [domain]
        if layer >= .security {
            lines.append("SEC \(securityVerdict.glyph) \(securityScore)/100 · \(ttfbMilliseconds ?? 0)ms")
        }
        if layer >= .identity, let title {
            lines.append(String(title.prefix(28)))
        }
        if layer >= .craft {
            lines.append("CRAFT \(craftVerdict.glyph) \(craftScore)/100")
        }
        return lines
    }
}
