import SwiftUI
import AVFoundation

/// Primera pantalla al abrir: la mascota saluda y ofrece entender un proyecto.
///
/// La app arranca hablando en vez de mostrando un panel de control. La mascota
/// dice para qué sirve y deja una sola acción clara, así no hay que deducir por
/// dónde empezar entre seis tarjetas.
struct WelcomeView: View {
    @ObservedObject private var connection = GlassesConnectionManager.shared
    @ObservedObject private var avatar = AvatarHUDManager.shared

    /// Empezar a entender un proyecto.
    var onStart: () -> Void
    /// Entrar al panel completo sin pasar por el escaneo.
    var onSkip: () -> Void

    @State private var mood: MascotMood = .greeting
    @State private var showContent = false
    @State private var typedGreeting = ""

    private let greeting = "¡Hola! ¿Quieres entender un nuevo proyecto?"
    private let spokenGreeting = "¡Hola! ¿Quieres entender un nuevo proyecto? "
        + "Escanea su código o pégame su enlace, y te digo qué es, cómo está hecho y si vale la pena."

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                Spacer()

                ShikiMascot(mood: mood,
                            speechPulse: avatar.speechPulse,
                            pixelSize: 12)
                    .scaleEffect(showContent ? 1 : 0.8)
                    .opacity(showContent ? 1 : 0)

                // Burbuja de diálogo: el texto aparece escribiéndose al ritmo de
                // la voz, de modo que leer y oír van juntos.
                Text(typedGreeting)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .top)
                    .padding(.horizontal, 28)
                    .padding(.top, 26)

                Spacer()

                actions
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 18)
            }
        }
        .onAppear { begin() }
        .onDisappear { avatar.stopSpeakingAnimation() }
    }

    // MARK: - Fondo

    private var backdrop: some View {
        // El halo va como `overlay` y no como hermano en un ZStack.
        //
        // Antes era un hermano de 520x520, y en un ZStack el contenedor toma el
        // tamaño del hijo más grande: en un iPhone de ~390 pt de ancho eso hacía
        // que el contenido se centrara sobre un lienzo más ancho que la pantalla
        // y el texto se cortara por los lados. Un `overlay` no influye en el
        // tamaño del padre, así que el halo se dibuja sin arrastrar el layout.
        Color(white: 0.04)
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(colors: [mood.tint.opacity(0.28), .clear],
                                       center: .center, startRadius: 10, endRadius: 260)
                    )
                    .frame(width: 520, height: 520)
                    .offset(y: -110)
                    .blur(radius: 40)
            )
            .clipped()
            .ignoresSafeArea()
    }

    // MARK: - Acciones

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                avatar.stopSpeakingAnimation()
                onStart()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Entender un proyecto")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(mood.tint)
                .cornerRadius(15)
            }

            Button {
                avatar.stopSpeakingAnimation()
                onSkip()
            } label: {
                Text("Ir al panel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
            }

            connectionHint
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 34)
    }

    /// Estado del enlace, sin exigir nada: la app funciona igual sin gafas.
    private var connectionHint: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connection.connectionState == .connected ? Color.brand : Color.gray)
                .frame(width: 7, height: 7)
            Text(connectionStatusText)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(.top, 6)
    }

    private var connectionStatusText: String {
        if connection.connectionState == .connected { return "Gafas conectadas" }
        if connection.isAutoConnecting { return "Buscando tus gafas…" }
        return "Sin gafas · funciona con el teléfono"
    }

    // MARK: - Entrada en escena

    private func begin() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) {
            showContent = true
        }

        // El saludo se dice y se escribe a la vez. Medio segundo de margen para
        // que la mascota ya esté en pantalla cuando empiece a hablar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            typeGreeting()
            avatar.startSpeakingAnimation(textToSpeak: spokenGreeting)
            mood = .talking
        }
    }

    /// Escribe el saludo letra a letra.
    private func typeGreeting() {
        typedGreeting = ""
        for (index, character) in greeting.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.035) {
                typedGreeting.append(character)
                if index == greeting.count - 1 {
                    // Al terminar de escribir vuelve al gesto de saludo.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if mood == .talking { mood = .greeting }
                    }
                }
            }
        }
    }
}
