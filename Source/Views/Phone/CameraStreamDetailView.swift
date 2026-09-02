import SwiftUI

/// Vista detallada de la cámara frontal de las gafas para el iPhone
struct CameraStreamDetailView: View {
    @ObservedObject var cameraManager = CameraStreamManager.shared
    @ObservedObject var hudManager = HUDGridManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 16) {
                // Header
                HStack {
                    Button(action: {
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
                    
                    Text("CÁMARA DE LAS GAFAS")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // Indicador de streaming
                    Circle()
                        .fill(cameraManager.isStreaming ? Color.brand : Color.red)
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal)
                
                // Visualizador de Stream
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.1))
                    
                    if let frame = cameraManager.latestFrame {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.slash.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.gray)
                            Text(cameraManager.streamStatusMessage)
                                .foregroundColor(.gray)
                                .font(.subheadline)
                        }
                    }
                    
                    // Overlay de Telemetría
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("FPS: \(String(format: "%.1f", cameraManager.currentFPS))")
                                Text("Frames: \(cameraManager.totalFramesReceived)")
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.brand)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .padding(.horizontal)
                
                // Controles de Cámara
                HStack(spacing: 16) {
                    Button(action: {
                        if cameraManager.isStreaming {
                            cameraManager.stopStream()
                        } else {
                            Task { await cameraManager.startStream() }
                        }
                    }) {
                        HStack {
                            Image(systemName: cameraManager.isStreaming ? "pause.fill" : "play.fill")
                            Text(cameraManager.isStreaming ? "Pausar Stream" : "Iniciar Stream")
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(cameraManager.isStreaming ? Color.red : Color.brand)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                
                if let error = cameraManager.lastStreamError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.top, 12)
        }
    }
}
