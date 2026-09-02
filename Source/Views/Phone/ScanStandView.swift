import SwiftUI

/// Módulo de escaneo. La mascota es el sujeto de la pantalla: reacciona al
/// estado (buscando, encontrado, error) para que el escaneo se sienta como
/// pedirle algo a alguien, no como esperar a una barra de progreso.
struct ScanStandView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var cameraManager = CameraStreamManager.shared
    @ObservedObject private var phoneSession = PhoneQRSession.shared
    @ObservedObject private var connection = GlassesConnectionManager.shared
    @ObservedObject private var speech = SpeechAudioManager.shared

    @State private var manualURL: String = ""
    @State private var mood: MascotMood = .idle
    @State private var detectedURL: String?
    @State private var scanElapsed: Int = 0
    @State private var timer: Timer?
    /// Manejadores originales, para devolverlos al cerrar la vista.
    @State private var previousPhoneHandler: ((URL) -> Void)?
    @State private var previousGlassesHandler: ((String) -> Void)?

    /// Qué hacer con la URL una vez leída.
    var onURLReady: (String) -> Void

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                activeChannelsBar

                ScrollView {
                    VStack(spacing: 22) {
                        ShikiMascot(mood: mood, pixelSize: 10)
                            .padding(.top, 10)

                        if phoneSession.isRunning {
                            viewfinder
                        }

                        sourceStatus

                        if let detectedURL {
                            detectedCard(detectedURL)
                        }

                        actionButtons
                        manualEntry
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            mood = .idle
            // Mientras esta vista está abierta manda ella sobre el código leído.
            // Si no, el mismo QR dispara dos flujos a la vez —el automático del
            // manager y el de aquí— y la auditoría arranca por duplicado.
            previousPhoneHandler = PhoneQRSession.shared.onDetect
            PhoneQRSession.shared.onDetect = { url in
                handleDetection(url.absoluteString)
            }
            previousGlassesHandler = cameraManager.onQRDetected
            cameraManager.onQRDetected = { payload in
                handleDetection(payload)
            }
        }
        .onDisappear {
            stopScanning()
            // Devolver los manejadores: fuera de esta vista el escaneo vuelve a
            // comportarse como antes.
            PhoneQRSession.shared.onDetect = previousPhoneHandler
            cameraManager.onQRDetected = previousGlassesHandler
        }
        .onChange(of: phoneSession.permissionDenied) { _, denied in
            if denied { mood = .error }
        }
    }

    // MARK: - Fondo

    private var background: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()
            // Rejilla tenue: da textura sin robar atención a la mascota.
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 34
                    for x in stride(from: 0, through: geo.size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for y in stride(from: 0, through: geo.size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(mood.tint.opacity(0.06), lineWidth: 1)
            }
            .ignoresSafeArea()
        }
    }

    /// Barra de canales activos, con un corte independiente para cada uno.
    ///
    /// Se separan a proposito: el microfono y el video son dos canales distintos y
    /// casi nunca quieres cortar los dos. Pausar la transcripcion mientras el
    /// participante habla con otra persona es lo habitual; cortar el video ademas
    /// dejaria de buscar el QR.
    @ViewBuilder
    private var activeChannelsBar: some View {
        if speech.isListening || cameraManager.isStreaming {
            VStack(spacing: 6) {
                if speech.isListening {
                    channelRow(
                        label: "Transcribiendo audio",
                        detail: speech.transcriptText.isEmpty ? nil : "\(speech.transcriptText.count) car.",
                        action: "Pausar"
                    ) {
                        speech.stopListening()
                    }
                }

                if cameraManager.isStreaming {
                    channelRow(
                        label: "Video de las gafas",
                        detail: cameraManager.totalFramesReceived > 0
                            ? "\(cameraManager.totalFramesReceived) frames"
                            : "sin frames",
                        action: "Detener"
                    ) {
                        cameraManager.stopStream()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(white: 0.12))
        }
    }

    private func channelRow(label: String,
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ENTIENDE EL PROYECTO")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text(connection.connectionState == .connected ? "Gafas + teléfono" : "Solo teléfono")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            Spacer()
            Button { stopScanning(); dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.08).ignoresSafeArea(edges: .top))
    }

    // MARK: - Visor

    private var viewfinder: some View {
        ZStack {
            PhoneQRPreview()
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Esquinas del visor: dicen dónde encuadrar sin tapar la imagen.
            RoundedRectangle(cornerRadius: 16)
                .stroke(mood.tint.opacity(0.8), lineWidth: 2)
                .frame(height: 230)

            if mood == .scanning {
                scanLine
            }
        }
    }

    /// Línea que barre el visor: señal viva de que está mirando.
    private var scanLine: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2.0) + 1) / 2   // 0…1
            Rectangle()
                .fill(
                    LinearGradient(colors: [.clear, mood.tint, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .frame(height: 2)
                .offset(y: (phase - 0.5) * 200)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Estado

    private var sourceStatus: some View {
        HStack(spacing: 10) {
            statusChip(icon: "eyeglasses",
                       label: "Gafas",
                       active: cameraManager.isStreaming)
            statusChip(icon: "iphone.gen3",
                       label: "Teléfono",
                       active: phoneSession.isRunning)
            if mood == .scanning {
                statusChip(icon: "clock", label: "\(scanElapsed)s", active: true)
            }
        }
    }

    private func statusChip(icon: String, label: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(active ? mood.tint : Color(white: 0.4))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(active ? mood.tint.opacity(0.15) : Color(white: 0.1))
        .cornerRadius(20)
    }

    private func detectedCard(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CÓDIGO LEÍDO")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.brand)
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(2)

            Button {
                onURLReady(url)
                dismiss()
            } label: {
                Text("Entender este proyecto")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.brand)
                    .cornerRadius(10)
            }
        }
        .padding(14)
        .background(Color.brand.opacity(0.12))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.brand.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Acciones

    private var actionButtons: some View {
        Button(action: toggleScanning) {
            HStack(spacing: 8) {
                Image(systemName: mood == .scanning ? "stop.fill" : "qrcode.viewfinder")
                Text(mood == .scanning ? "Detener" : "Buscar código QR")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(mood == .scanning ? .white : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(mood == .scanning ? Color(white: 0.2) : mood.tint)
            .cornerRadius(13)
        }
    }

    private var manualEntry: some View {
        VStack(spacing: 10) {
            HStack {
                Rectangle().fill(Color(white: 0.2)).frame(height: 1)
                Text("o pega la dirección")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Rectangle().fill(Color(white: 0.2)).frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("https://…", text: $manualURL)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.11))
                    .cornerRadius(11)

                Button {
                    let trimmed = manualURL.trimmingCharacters(in: .whitespaces)
                    guard let url = QRScanner.navigableURL(from: trimmed) else {
                        mood = .error
                        return
                    }
                    stopScanning()
                    onURLReady(url.absoluteString)
                    dismiss()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(manualURL.isEmpty ? Color(white: 0.25) : mood.tint)
                }
                .disabled(manualURL.isEmpty)
            }
        }
    }

    // MARK: - Lógica

    private func toggleScanning() {
        mood == .scanning ? stopScanning() : startScanning()
    }

    private func startScanning() {
        detectedURL = nil
        scanElapsed = 0
        mood = .scanning

        Task { await cameraManager.startQRScanning() }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                scanElapsed += 1
                // Aviso a los 15s: casi siempre es encuadre o luz, no un fallo del código.
                if scanElapsed == 15 {
                    DiagnosticLogger.shared.log(.warning, tag: "QR",
                        message: "15s sin detectar. Acerca el código, mejora la luz o evita reflejos.")
                }
            }
        }
    }

    private func stopScanning() {
        timer?.invalidate()
        timer = nil
        cameraManager.stopQRScanning()
        PhoneQRSession.shared.stop()
        if mood == .scanning { mood = .idle }
    }

    private func handleDetection(_ payload: String) {
        guard let url = QRScanner.navigableURL(from: payload) else {
            mood = .error
            return
        }
        stopScanning()
        detectedURL = url.absoluteString
        mood = .success
    }
}
