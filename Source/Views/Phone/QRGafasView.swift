import SwiftUI

/// Módulo de prueba `qr-gafas`: un solo botón que escanea con la cámara de las gafas.
///
/// Existe para aislar el escaneo del resto de la app. Si el QR falla, aquí se ve si el
/// problema es el escáner o el flujo que lo envuelve — sin menús, sin modos, sin HUD.
struct QRGafasView: View {
    @ObservedObject private var connectionManager = GlassesConnectionManager.shared
    @ObservedObject private var cameraManager = CameraStreamManager.shared

    @State private var lastPayload: String? = nil
    @State private var errorText: String? = nil
    @State private var previousHandler: ((String) -> Void)? = nil

    private var isReady: Bool { connectionManager.connectionState == .connected }

    var body: some View {
        VStack(spacing: 24) {
            Text("QR · GAFAS")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundColor(.gray)

            Circle()
                .strokeBorder(cameraManager.isScanningQR ? Color.brand : Color.gray.opacity(0.4), lineWidth: 3)
                .frame(width: 120, height: 120)
                .overlay(
                    Image(systemName: cameraManager.isScanningQR ? "viewfinder" : "qrcode")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(cameraManager.isScanningQR ? .brand : .gray)
                )
                .animation(.easeInOut, value: cameraManager.isScanningQR)

            Text(statusText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(cameraManager.isScanningQR ? .brand : .gray)
                .multilineTextAlignment(.center)

            Button(action: scan) {
                Text(cameraManager.isScanningQR ? "Escaneando..." : "Escanear con gafas")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(isReady ? Color.brand : Color.gray)
                    .cornerRadius(14)
            }
            .disabled(!isReady || cameraManager.isScanningQR)

            if let lastPayload {
                VStack(spacing: 6) {
                    Text("DETECTADO")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text(lastPayload)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.06))
                .cornerRadius(12)
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05).ignoresSafeArea())
        .onAppear(perform: bindCallback)
        .onDisappear {
            cameraManager.stopQRScanning()
            cameraManager.onQRDetected = previousHandler
        }
    }

    private var statusText: String {
        if !isReady { return "Conecta las gafas primero" }
        if cameraManager.isScanningQR { return "Apunta a un código QR" }
        return "Listo para escanear"
    }

    /// El escáner es compartido, así que este módulo se apropia del callback mientras está
    /// en pantalla y lo devuelve al flujo normal al salir.
    private func bindCallback() {
        previousHandler = cameraManager.onQRDetected
        cameraManager.onQRDetected = { payload in
            Task { @MainActor in
                lastPayload = payload
                errorText = nil
            }
        }
    }

    private func scan() {
        errorText = nil
        lastPayload = nil
        Task {
            // Este módulo aísla el escáner de las gafas: si el teléfono entrara
            // de relevo, dejaría de probar lo que dice probar.
            await cameraManager.startQRScanning(source: .glasses)
            if let streamError = cameraManager.lastStreamError {
                errorText = streamError
            }
        }
    }
}
