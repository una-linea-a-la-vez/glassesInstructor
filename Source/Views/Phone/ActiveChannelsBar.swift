import SwiftUI

/// Barra de canales activos: micrófono y video, cada uno con su corte.
///
/// Vive fuera de cualquier pantalla concreta porque el problema era justo ese: el
/// botón de pausa solo existía dentro de la vista de escaneo, así que si la
/// transcripción arrancaba en otro sitio no había forma de pararla. Ahora se
/// muestra donde se coloque, y se esconde sola cuando no hay nada corriendo.
///
/// Los dos canales se separan a propósito: casi nunca quieres cortar ambos. Cortar
/// el video además dejaría de buscar el código.
struct ActiveChannelsBar: View {
    @ObservedObject private var speech = SpeechAudioManager.shared
    @ObservedObject private var camera = CameraStreamManager.shared

    var body: some View {
        if speech.isListening || camera.isStreaming {
            VStack(spacing: 6) {
                if speech.isListening {
                    row(label: "Transcribiendo audio",
                        detail: speech.transcriptText.isEmpty ? nil : "\(speech.transcriptText.count) car.",
                        action: "Pausar") {
                        speech.stopListening()
                    }
                }

                if camera.isStreaming {
                    // Los frames recibidos distinguen "funcionando" de "encendido
                    // y calentando sin entregar nada".
                    row(label: "Video de las gafas",
                        detail: camera.totalFramesReceived > 0
                            ? "\(camera.totalFramesReceived) frames"
                            : "sin frames",
                        action: "Detener") {
                        camera.stopStream()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(white: 0.12))
        }
    }

    private func row(label: String,
                     detail: String?,
                     action: String,
                     onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }

            Spacer()

            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "pause.fill")
                    Text(action)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.brand)
                .cornerRadius(8)
            }
        }
    }
}
