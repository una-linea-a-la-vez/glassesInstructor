import SwiftUI

/// Área sobre la que se quiere apretar.
///
/// Sin enfoque, el modelo reparte: una de diseño, una de backend, una de seguridad.
/// Eso está bien para abrir, pero no sirve cuando ya sospechas por dónde se cae el
/// proyecto. Elegir un área concentra las preguntas ahí y evita gastar turnos en
/// terreno donde el alumno ya demostró que se defiende.
enum ReviewFocus: String, CaseIterable, Identifiable, Codable {
    case general
    case design
    case backend
    case security
    case originality
    case performance
    case accessibility

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .design:        return "Diseño"
        case .backend:       return "Backend"
        case .security:      return "Seguridad"
        case .originality:   return "Originalidad"
        case .performance:   return "Rendimiento"
        case .accessibility: return "Accesibilidad"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "square.grid.2x2"
        case .design:        return "paintbrush"
        case .backend:       return "server.rack"
        case .security:      return "lock.shield"
        case .originality:   return "fingerprint"
        case .performance:   return "gauge.high"
        case .accessibility: return "figure.stand"
        }
    }

    /// Instrucción que se añade al prompt. Cada una apunta a decisiones y bordes,
    /// no a datos que se leen de los headers en 200 ms.
    var guidance: String {
        switch self {
        case .general:
            return "Reparte las preguntas entre distintas areas del proyecto."

        case .design:
            return """
            Céntrate en decisiones de interfaz: jerarquía, espaciado, estados de \
            carga y error, qué pasa al pulsar dos veces, por qué eligió ese \
            componente y no el nativo. Pregunta por el porqué de cada elección \
            visual, no por gustos.
            """

        case .backend:
            return """
            Céntrate en el servidor y los datos: de dónde salen, qué pasa si el \
            servicio no responde, si hay validación, si los datos son reales o \
            simulados, y cómo distingue un fallo de red de un dato vacío.
            """

        case .security:
            return """
            Céntrate en qué está expuesto y qué falta, citando el header o el \
            hallazgo concreto. Distingue riesgo real de higiene. Pregunta qué \
            haría un tercero con lo que hoy es público.
            """

        case .originality:
            return """
            Céntrate en distinguir lo suyo de lo generado o copiado. Busca señales: \
            andamiaje del framework sin tocar, textos por defecto, decisiones que \
            nadie sabría justificar. Pregunta por qué se eligio ESO sobre la \
            alternativa, y qué parte reescribiría hoy y por qué.
            """

        case .performance:
            return """
            Céntrate en tiempos y peso: qué ocurre antes del primer byte, qué se \
            carga que no hace falta, qué pasaría con conexión lenta o con diez \
            veces más datos.
            """

        case .accessibility:
            return """
            Céntrate en quién queda fuera: navegación con teclado, lectores de \
            pantalla, contraste, y si respeta prefers-reduced-motion. Pide que lo \
            demuestre en vivo, no que lo afirme.
            """
        }
    }

    var tint: Color {
        switch self {
        case .general:       return .brand
        case .design:        return .purple
        case .backend:       return .teal
        case .security:      return .orange
        case .originality:   return .pink
        case .performance:   return .yellow
        case .accessibility: return .mint
        }
    }
}
