import SwiftUI

/// Manual interactivo de conexión y checklist de resolución de problemas dentro de la app
struct ConnectionGuideSheetView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(white: 0.08).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Header explicativo
                        VStack(spacing: 8) {
                            Image(systemName: "eyeglasses")
                                .font(.system(size: 48))
                                .foregroundColor(.green)
                            Text("Manual de Conexión de Gafas")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Text("Guía paso a paso para enlazar las Meta Ray-Ban Display con el iPhone de manera robusta.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.top, 12)
                        
                        // 1. Checklist de Hardware
                        VStack(alignment: .leading, spacing: 14) {
                            Label("1. Verificación Previa de Hardware", systemImage: "checklist")
                                .font(.headline)
                                .foregroundColor(.green)
                            
                            GuideCheckRow(icon: "face.smiling", title: "Gafas Puestas en el Rostro", description: "El sensor óptico del puente nasal debe detectar contacto. Si estás en escritorio, cubre el puente nasal con cinta opaca.")
                            
                            GuideCheckRow(icon: "wifi", title: "Misma Red Wi-Fi sin VPN", description: "iPhone y gafas deben compartir exactamente la misma SSID (2.4/5GHz). Desactiva VPNs y bloqueadores DNS como AdGuard.")
                            
                            GuideCheckRow(icon: "antenna.radiowaves.left.and.right", title: "Bluetooth Classic Activado", description: "Asegúrate de que las gafas aparezcan como conectadas en Ajustes > Bluetooth de tu iPhone.")
                        }
                        .padding()
                        .background(Color(white: 0.14))
                        .cornerRadius(16)
                        .padding(.horizontal)
                        
                        // 2. Proceso de Enlace Software
                        VStack(alignment: .leading, spacing: 14) {
                            Label("2. Secuencia de Comunicación SDK", systemImage: "cpu")
                                .font(.headline)
                                .foregroundColor(.cyan)
                            
                            GuideStepRow(step: "Paso 1", title: "Inicialización Lazy", description: "El SDK se inicializa al pulsar 'Conectar' para no bloquear CoreBluetooth.")
                            
                            GuideStepRow(step: "Paso 2", title: "Bypass de Registro (App ID 0)", description: "Redirige momentáneamente a la app Meta AI / Meta View para certificar el esquema metaglasseslab://.")
                            
                            GuideStepRow(step: "Paso 3", title: "Apertura de Canales Display y Cámara", description: "Negocia el canal seguro y levanta el renderizador de 600x600 px en la lente derecha.")
                        }
                        .padding()
                        .background(Color(white: 0.14))
                        .cornerRadius(16)
                        .padding(.horizontal)
                        
                        // 3. Matriz de Errores Comunes
                        VStack(alignment: .leading, spacing: 14) {
                            Label("3. Solución Rápida de Errores", systemImage: "exclamationmark.shield.fill")
                                .font(.headline)
                                .foregroundColor(.orange)
                            
                            TroubleRow(error: "Session already stopped", fix: "Ocurre si intentas activar la cámara antes de que la sesión esté en estado .started. Espera la confirmación verde.")
                            
                            TroubleRow(error: "API MISUSE (CBCentralManager)", fix: "El Bluetooth de tu iPhone estaba apagado o se intentó escanear sin permiso. Reinicia el Bluetooth en Ajustes.")
                            
                            TroubleRow(error: "Device unavailable", fix: "Las gafas entraron en modo reposo. Ábrelas, póntelas o presiona el botón físico de encendido en la patilla.")
                        }
                        .padding()
                        .background(Color(white: 0.14))
                        .cornerRadius(16)
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cerrar") {
                        dismiss()
                    }
                    .foregroundColor(.green)
                    .fontWeight(.bold)
                }
            }
        }
    }
}

private struct GuideCheckRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.green)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

private struct GuideStepRow: View {
    let step: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan)
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

private struct TroubleRow: View {
    let error: String
    let fix: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⚠️ \(error)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.orange)
            Text(fix)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
    }
}
