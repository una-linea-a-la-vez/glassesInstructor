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
    @ObservedObject private var auditAgent = ProjectAuditAgent.shared

    @State private var manualURL: String = ""
    @State private var mood: MascotMood = .idle
    @State private var detectedURL: String?
    @State private var scanElapsed: Int = 0
    @State private var timer: Timer?
    /// Manejadores originales, para devolverlos al cerrar la vista.
    @State private var previousPhoneHandler: ((URL) -> Void)?
    @State private var previousGlassesHandler: ((String) -> Void)?

    /// Código ya leído por quien presenta esta vista.
    ///
    /// Con valor, la vista no escanea: acompaña al análisis que ya arrancó. Sin
    /// él, escanea nada más abrirse.
    var detected: String? = nil

    /// Qué hacer con la URL una vez leída.
    var onURLReady: (String) -> Void

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                ActiveChannelsBar()

                ScrollView {
                    VStack(spacing: 22) {
                        ShikiMascot(mood: mood, pixelSize: 10)
                            .padding(.top, 10)

                        if phoneSession.isRunning && detectedURL == nil {
                            viewfinder
                        }

                        sourceStatus

                        if let detectedURL {
                            detectedCard(detectedURL)
                        }

                        if detectedURL == nil {
                            manualEntry
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            // Se guardan SIEMPRE, tambien en la rama que no escanea: `onDisappear`
            // los devuelve pase lo que pase, y si aqui quedaran a nil dejaria sin
            // manejador al escaner de toda la app.
            previousPhoneHandler = PhoneQRSession.shared.onDetect
            previousGlassesHandler = cameraManager.onQRDetected

            // Abierta con el código ya leído: aquí solo acompaña al análisis, no
            // vuelve a escanear ni le quita el escáner a nadie.
            if let detected {
                detectedURL = detected
                mood = .thinking
                return
            }

            mood = .idle
            // Mientras esta vista está abierta manda ella sobre el código leído.
            // Si no, el mismo QR dispara dos flujos a la vez —el automático del
            // manager y el de aquí— y la auditoría arranca por duplicado.
            PhoneQRSession.shared.onDetect = { url in
                handleDetection(url.absoluteString)
            }
            cameraManager.onQRDetected = { payload in
                handleDetection(payload)
            }
            // Sin botón intermedio: quien abre esta vista ya dijo que quiere
            // escanear, así que preguntárselo otra vez no decide nada.
            startScanning()
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
        // El análisis terminó: la home ya muestra el proyecto cargado, así que
        // esta vista no tiene nada más que decir y se quita de en medio.
        .onChange(of: auditAgent.isAnalyzing) { wasAnalyzing, nowAnalyzing in
            guard wasAnalyzing, !nowAnalyzing, detectedURL != nil else { return }
            dismiss()
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ENTIENDE EL PROYECTO")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text(detectedURL != nil
                     ? "Entendiendo el proyecto"
                     : (connection.connectionState == .connected
                        ? "Gafas · el teléfono entra de relevo"
                        : "Solo teléfono"))
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

            // Ya no hay nada que confirmar: apuntar al código era la confirmación.
            HStack(spacing: 8) {
                if auditAgent.isAnalyzing || auditAgent.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.brand)
                }
                Text(auditAgent.statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(Color.brand.opacity(0.12))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.brand.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Acciones

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
                    // Por el mismo camino que un código leído: pegar el enlace y
                    // apuntar al QR dicen exactamente lo mismo.
                    handleDetection(manualURL.trimmingCharacters(in: .whitespaces))
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
        mood = .thinking
        // Directo al análisis. Antes esperaba a un segundo botón que solo repetía
        // lo que el usuario ya había dicho al apuntar la cámara.
        onURLReady(url.absoluteString)
    }
}
