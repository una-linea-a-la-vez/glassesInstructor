import SwiftUI

extension Color {
    /// Color de acento de toda la app del teléfono.
    ///
    /// Antes el verde estaba escrito a mano en 76 sitios, así que cambiarlo obligaba
    /// a tocar diez archivos. Aquí vive una sola vez.
    ///
    /// Nota: esto es solo para la pantalla del iPhone. El HUD de las gafas es
    /// monocromo y no admite color, así que allí no aplica.
    static let brand = Color(red: 0.42, green: 0.76, blue: 1.0)
}
