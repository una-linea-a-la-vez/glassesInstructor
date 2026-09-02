import SwiftUI

/// Estado de ánimo de la mascota. Cada uno cambia ojos, color y movimiento.
enum MascotMood {
    case idle        // respirando, esperando
    case greeting    // saludando con la mano
    case scanning    // buscando el código: ojos barren de lado a lado
    case thinking    // analizando
    case talking     // hablando: la boca late con la voz
    case success     // encontró algo
    case error       // algo salió mal

    var tint: Color {
        switch self {
        case .idle:     return Color(red: 0.42, green: 0.45, blue: 0.85)
        case .greeting: return Color(red: 0.40, green: 0.68, blue: 0.98)
        case .scanning: return Color(red: 0.30, green: 0.78, blue: 0.90)
        case .thinking: return Color(red: 0.55, green: 0.45, blue: 0.92)
        case .talking:  return Color(red: 0.35, green: 0.72, blue: 0.95)
        case .success:  return Color(red: 0.30, green: 0.82, blue: 0.55)
        case .error:    return Color(red: 0.90, green: 0.38, blue: 0.38)
        }
    }

    var caption: String {
        switch self {
        case .idle:     return "Listo"
        case .greeting: return "¡Hola!"
        case .scanning: return "Buscando código…"
        case .thinking: return "Analizando…"
        case .talking:  return "Hablando"
        case .success:  return "¡Encontrado!"
        case .error:    return "Algo falló"
        }
    }
}

/// Mascota de Shiki: un robot pixelado con cara de terminal.
///
/// Dibujada con una rejilla de celdas en vez de imágenes, para que cada píxel
/// pueda animarse por separado (parpadeo, barrido de escaneo, latido de voz) y
/// para que escale sin perder el borde duro característico del pixel art.
struct ShikiMascot: View {
    var mood: MascotMood = .idle
    /// Contador que sube con cada fragmento hablado: sincroniza la boca con la voz.
    var speechPulse: Int = 0
    var pixelSize: CGFloat = 9

    @State private var breathing = false
    @State private var isBlinking = false
    @State private var scanOffset: CGFloat = -1
    @State private var mouthOpen: CGFloat = 0.35
    @State private var antennaGlow = false
    @State private var waveAngle: Double = -18

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                auraLayer
                bodyLayer
            }
            .frame(width: pixelSize * 13, height: pixelSize * 15)
            .scaleEffect(breathing ? 1.03 : 0.98)
            .animation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true), value: breathing)

            Text(mood.caption)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(mood.tint)
                .contentTransition(.opacity)
        }
        .onAppear {
            breathing = true
            antennaGlow = true
            scheduleBlink()
            if mood == .greeting { startWaving() }
            if mood == .scanning { startScanSweep() }
        }
        .onChange(of: mood) { _, newMood in
            if newMood == .scanning { startScanSweep() }
            if newMood == .greeting { startWaving() }
        }
        .onChange(of: speechPulse) { _, _ in
            // Late una vez por fragmento de voz: la boca va con el habla real.
            withAnimation(.easeOut(duration: 0.09)) { mouthOpen = 1.0 }
            withAnimation(.easeIn(duration: 0.16).delay(0.09)) { mouthOpen = 0.35 }
        }
    }

    // MARK: - Capas

    private var auraLayer: some View {
        RoundedRectangle(cornerRadius: pixelSize * 2)
            .fill(
                RadialGradient(colors: [mood.tint.opacity(0.35), .clear],
                               center: .center, startRadius: pixelSize, endRadius: pixelSize * 9)
            )
            .blur(radius: pixelSize)
            .scaleEffect(breathing ? 1.12 : 0.95)
    }

    private var bodyLayer: some View {
        VStack(spacing: 0) {
            antenna
            head
            torso
            legs
        }
    }

    /// Antena con luz que parpadea: da señal de "está encendido".
    private var antenna: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(mood.tint)
                .frame(width: pixelSize, height: pixelSize)
                .opacity(antennaGlow ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: antennaGlow)
            Rectangle()
                .fill(mood.tint.opacity(0.65))
                .frame(width: pixelSize * 0.6, height: pixelSize * 0.9)
        }
    }

    /// Cabeza-pantalla: el rasgo que la vuelve reconocible, como el `>_` de una terminal.
    private var head: some View {
        ZStack {
            RoundedRectangle(cornerRadius: pixelSize * 0.5)
                .fill(mood.tint)
                .frame(width: pixelSize * 11, height: pixelSize * 7)

            RoundedRectangle(cornerRadius: pixelSize * 0.3)
                .fill(Color.black.opacity(0.82))
                .frame(width: pixelSize * 9, height: pixelSize * 5)

            face
        }
    }

    private var face: some View {
        HStack(spacing: pixelSize * 0.9) {
            eye
            eye
            mouth
        }
        .offset(x: scanSweepOffset)
    }

    /// Ojo cuadrado. Al parpadear se aplasta, que es como lo hace el pixel art.
    private var eye: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: pixelSize, height: isBlinking ? pixelSize * 0.2 : pixelSize * 1.4)
            .animation(.easeInOut(duration: 0.08), value: isBlinking)
    }

    /// Boca: una barra que crece con la voz. En reposo es un guion.
    private var mouth: some View {
        Rectangle()
            .fill(mood.tint)
            .frame(width: pixelSize * 2.2, height: pixelSize * mouthOpen * 1.2)
            .animation(.easeInOut(duration: 0.1), value: mouthOpen)
    }

    private var torso: some View {
        ZStack {
            RoundedRectangle(cornerRadius: pixelSize * 0.4)
                .fill(mood.tint.opacity(0.9))
                .frame(width: pixelSize * 9, height: pixelSize * 4)

            // Marca de terminal en el pecho
            Text(">_")
                .font(.system(size: pixelSize * 1.5, weight: .black, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            // Brazo que saluda. Solo aparece al saludar: tenerlo siempre le
            // quitaría fuerza al gesto.
            if mood == .greeting {
                wavingArm
                    .offset(x: pixelSize * 5.4, y: -pixelSize * 0.6)
            }
        }
    }

    /// Brazo pixelado que pivota desde el hombro, como un saludo de mano.
    private var wavingArm: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(mood.tint)
                .frame(width: pixelSize * 1.1, height: pixelSize * 1.1)
            Rectangle()
                .fill(mood.tint.opacity(0.9))
                .frame(width: pixelSize * 1.1, height: pixelSize * 2.2)
        }
        .rotationEffect(.degrees(waveAngle), anchor: .bottom)
        .animation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true), value: waveAngle)
    }

    private var legs: some View {
        HStack(spacing: pixelSize * 1.6) {
            Rectangle().fill(mood.tint.opacity(0.85))
                .frame(width: pixelSize * 1.6, height: pixelSize * 2)
            Rectangle().fill(mood.tint.opacity(0.85))
                .frame(width: pixelSize * 1.6, height: pixelSize * 2)
        }
    }

    // MARK: - Animaciones

    /// En modo escaneo la cara barre de lado a lado, como buscando.
    private var scanSweepOffset: CGFloat {
        mood == .scanning ? scanOffset * pixelSize * 0.8 : 0
    }

    private func startWaving() {
        withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
            waveAngle = 18
        }
    }

    private func startScanSweep() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            scanOffset = 1
        }
    }

    /// Parpadeo con pausa aleatoria: a intervalo fijo se ve mecánico.
    private func scheduleBlink() {
        let delay = Double.random(in: 2.2...5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isBlinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isBlinking = false
                scheduleBlink()
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 30) {
            ShikiMascot(mood: .scanning)
            ShikiMascot(mood: .talking, speechPulse: 3)
            ShikiMascot(mood: .success)
        }
    }
}
