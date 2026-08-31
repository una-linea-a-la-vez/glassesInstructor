import SwiftUI

/// Vista detallada del micrófono y transcripción en vivo para el iPhone
struct DictationDetailView: View {
    @ObservedObject var speechManager = SpeechAudioManager.shared
    @ObservedObject var hudManager = HUDGridManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                HStack {
                    Button(action: {
                        speechManager.stopListening()
                        Task {
                            await hudManager.switchMode(.gridMenu)
                            dismiss()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Menú")
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    Text("MICRÓFONO & DICTADO")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Circle()
                        .fill(speechManager.isListening ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal)
                
                // Visualizador de Onda de Audio
                VStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(0..<18) { index in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(speechManager.isListening ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 6, height: CGFloat(max(8, Double(speechManager.audioLevel * 100) * Double((index % 5 + 2)) / 5.0)))
                                .animation(.spring(response: 0.15, dampingFraction: 0.5), value: speechManager.audioLevel)
                        }
                    }
                    .frame(height: 60)
                    
                    Text(speechManager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(white: 0.12))
                .cornerRadius(16)
                .padding(.horizontal)
                
                // Tarjeta de Transcripción
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "text.bubble.fill")
                            .foregroundColor(.green)
                        Text("Subtítulos Transmitidos al HUD")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    
                    ScrollView {
                        Text(speechManager.transcriptText.isEmpty ? "(Habla para ver el dictado en tiempo real proyectado en las gafas...)" : speechManager.transcriptText)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(speechManager.transcriptText.isEmpty ? .gray : .white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color(white: 0.12))
                .cornerRadius(16)
                .padding(.horizontal)
                
                // Botón de Inicio / Parada
                Button(action: {
                    if speechManager.isListening {
                        speechManager.stopListening()
                    } else {
                        speechManager.startListening()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: speechManager.isListening ? "stop.fill" : "mic.fill")
                        Text(speechManager.isListening ? "Detener Grabación" : "Iniciar Grabación de Voz")
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(speechManager.isListening ? Color.red : Color.blue)
                    .cornerRadius(14)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 12)
        }
    }
}
