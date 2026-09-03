import UIKit

/// Dibuja la mascota pixelada para el HUD de las gafas.
///
/// No reutiliza la vista SwiftUI porque el waveguide necesita otra cosa: un
/// `UIImage` de 300×300, sin color (solo blanco sobre negro, que el HUD vuelve
/// transparente) y con bordes duros que sobrevivan a la óptica. Un degradado o
/// un gris medio se pierde en la lente.
enum MascotHUDRenderer {

    /// Rejilla base de la mascota. Cada celda es un píxel gordo.
    /// 0 = vacío · 1 = cuerpo · 2 = pantalla oscura de la cara
    private static let bodyGrid: [[Int]] = [
        [0,0,0,0,0,1,0,0,0,0,0],
        [0,0,0,0,0,1,0,0,0,0,0],
        [0,1,1,1,1,1,1,1,1,1,0],
        [1,1,2,2,2,2,2,2,2,1,1],
        [1,1,2,2,2,2,2,2,2,1,1],
        [1,1,2,2,2,2,2,2,2,1,1],
        [0,1,1,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,1,0,1,1,0,0,0],
        [0,0,0,1,1,0,1,1,0,0,0],
    ]

    /// Lado de cada pixel gordo.
    ///
    /// A 22 la mascota ocupaba 242x264 de un lienzo de 300: casi toda la pantalla,
    /// y en el teleprompter competia con el texto, que es lo que de verdad hay que
    /// leer. A 16 baja a 176x192 y deja sitio.
    private static let cell: CGFloat = 16
    private static let canvas = CGSize(width: 300, height: 300)

    /// El waveguide proyecta luz sobre lo que estás viendo: el blanco puro
    /// deslumbra y cansa. Un gris claro se lee igual de bien y resulta mucho
    /// más tranquilo de tener delante del ojo.
    private static let bodyTone = UIColor(white: 0.78, alpha: 1.0)
    /// Los ojos y la boca sí van más brillantes: son el punto de atención y
    /// necesitan destacar sobre el cuerpo.
    private static let faceTone = UIColor(white: 0.94, alpha: 1.0)

    /// Compone un fotograma.
    /// - Parameters:
    ///   - mouthLevel: 0 cerrada … 2 abierta. La mueve el ritmo del habla.
    ///   - isBlinking: ojos entornados.
    ///   - step: fase de la flotación, para que respire.
    static func render(mouthLevel: Int, isBlinking: Bool, step: Double) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Fondo negro: el HUD lo interpreta como transparente.
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: canvas))

            let gridWidth = CGFloat(bodyGrid[0].count) * cell
            let gridHeight = CGFloat(bodyGrid.count) * cell
            let originX = (canvas.width - gridWidth) / 2 + CGFloat(sin(step) * 5)
            let originY = (canvas.height - gridHeight) / 2 + CGFloat(cos(step * 1.3) * 4)

            // Cuerpo
            for (row, cells) in bodyGrid.enumerated() {
                for (col, value) in cells.enumerated() where value != 0 {
                    let rect = CGRect(
                        x: originX + CGFloat(col) * cell,
                        y: originY + CGFloat(row) * cell,
                        width: cell, height: cell
                    )
                    cg.setFillColor(value == 1 ? bodyTone.cgColor : UIColor.black.cgColor)
                    cg.fill(rect)
                }
            }

            drawFace(cg, originX: originX, originY: originY,
                     mouthLevel: mouthLevel, isBlinking: isBlinking)
            drawChestPrompt(cg, originX: originX, originY: originY)
        }
    }

    /// Ojos y boca dentro de la pantalla de la cara.
    private static func drawFace(_ cg: CGContext, originX: CGFloat, originY: CGFloat,
                                 mouthLevel: Int, isBlinking: Bool) {
        cg.setFillColor(faceTone.cgColor)

        // Ojos: cuadrados; al parpadear se aplastan, como en el pixel art.
        let eyeY = originY + cell * 3.6
        let eyeHeight: CGFloat = isBlinking ? cell * 0.25 : cell * 1.1
        let eyeOffsetY = isBlinking ? cell * 0.45 : 0

        for eyeCol in [3.0, 6.0] as [CGFloat] {
            cg.fill(CGRect(x: originX + cell * eyeCol,
                           y: eyeY + eyeOffsetY,
                           width: cell * 0.9,
                           height: eyeHeight))
        }

        // Boca: barra que crece con la voz. Cerrada es un guion.
        let mouthHeights: [CGFloat] = [cell * 0.25, cell * 0.6, cell * 1.0]
        let height = mouthHeights[min(max(mouthLevel, 0), 2)]
        cg.fill(CGRect(x: originX + cell * 4.0,
                       y: originY + cell * 5.1,
                       width: cell * 3.0,
                       height: height))
    }

    /// La marca `>_` del pecho: es lo que la vuelve reconocible de lejos.
    private static func drawChestPrompt(_ cg: CGContext, originX: CGFloat, originY: CGFloat) {
        let text = ">_"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: cell * 1.5, weight: .black),
            .foregroundColor: UIColor.black
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = CGPoint(
            x: originX + (CGFloat(bodyGrid[0].count) * cell - size.width) / 2,
            y: originY + cell * 8.1
        )
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
