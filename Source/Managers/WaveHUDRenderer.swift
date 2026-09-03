import UIKit

/// Dibuja el indicador de conversación para el HUD de las gafas.
///
/// Sustituye al dibujo anterior, que salía lavado en el waveguide. El fallo no era
/// el motivo sino la técnica: usaba trazos finos con alfa variable, y eso produce
/// **grises medios**, que es justo lo que la óptica no reproduce. Aquí todo son
/// bloques gruesos de tono sólido y borde duro, como en `MascotHUDRenderer`.
///
/// La forma es la barra de ecualizador simétrica que ya usan los asistentes de voz:
/// se entiende sin explicación y no necesita icono de bocina.
enum WaveHUDRenderer {

    private static let canvas = CGSize(width: 300, height: 300)

    // Barras compactas: el indicador acompaña, no protagoniza. Ocupando media
    // pantalla no dejaba sitio al texto, que es lo que de verdad hay que leer.
    private static let barCount = 5
    private static let barWidth: CGFloat = 16
    private static let barGap: CGFloat = 11

    /// Perfil de reposo: la del centro es la más alta, como una voz.
    private static let profile: [CGFloat] = [0.42, 0.72, 1.0, 0.72, 0.42]

    /// El blanco puro deslumbra en el waveguide y cansa la vista. Un gris claro
    /// se lee igual de bien. El acento central va algo más brillante para dar foco.
    private static let barTone = UIColor(white: 0.78, alpha: 1.0)
    private static let accentTone = UIColor(white: 0.94, alpha: 1.0)

    /// Dibuja las barras dentro de un rectangulo dado, para usarlas como indicador
    /// pequeño junto a otra cosa en vez de como pantalla entera.
    ///
    /// Mismas reglas que el resto: tonos solidos y bordes duros, nada de alfa ni
    /// grises medios, que es lo que la optica del waveguide no reproduce.
    nonisolated static func draw(in rect: CGRect, context: CGContext, phase: Double, amplitude: Double) {
        let level = max(0.12, min(1.0, amplitude))
        let width = rect.width / CGFloat(barCount) * 0.55
        let gap = (rect.width - width * CGFloat(barCount)) / CGFloat(barCount - 1)
        let centerY = rect.midY

        for index in 0..<barCount {
            let wobble = abs(sin(phase + Double(index) * 0.85))
            let reach = profile[index] * CGFloat(0.30 + 0.70 * wobble) * CGFloat(level)
            let height = max(width, rect.height * reach)

            let x = rect.minX + CGFloat(index) * (width + gap)
            let bar = CGRect(x: x, y: centerY - height / 2, width: width, height: height)

            (index == barCount / 2 ? accentTone : barTone).setFill()
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: width / 2).cgPath)
            context.fillPath()
        }
    }

    /// Compone un fotograma del indicador.
    /// - Parameters:
    ///   - phase: fase de la animación; avanza en cada frame.
    ///   - amplitude: 0…1. Alto cuando habla, bajo en reposo.
    static func render(phase: Double, amplitude: Double) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

        let level = max(0.12, min(1.0, amplitude))

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Fondo negro: el HUD lo vuelve transparente.
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: canvas))

            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
            let startX = (canvas.width - totalWidth) / 2
            let centerY = canvas.height / 2
            // En silencio las barras quedan como círculos: un estado de reposo que
            // se distingue de un vistazo del estado "hablando".
            let maxHeight = canvas.height * 0.30

            for index in 0..<barCount {
                let wobble = abs(sin(phase + Double(index) * 0.85))
                let reach = profile[index] * CGFloat(0.30 + 0.70 * wobble) * CGFloat(level)
                let height = max(barWidth, maxHeight * reach)

                let x = startX + CGFloat(index) * (barWidth + barGap)
                let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)

                let isCenter = index == barCount / 2
                (isCenter ? accentTone : barTone).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: barWidth / 2).fill()
            }
        }
    }
}
