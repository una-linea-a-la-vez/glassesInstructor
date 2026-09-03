import SwiftUI

/// Apartado de IA: el avatar presenta la auditoría hablando, en vez de volcar tablas.
///
/// El flujo es el mismo de la cascada: el avatar reacciona en cuanto hay dominio,
/// va enriqueciendo mientras llegan las capas, y narra al completarse.
struct AvatarAIView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var narrator = AvatarNarrator.shared
    @StateObject private var phoneSession = PhoneQRSession.shared
    @ObservedObject private var cameraManager = CameraStreamManager.shared
    @ObservedObject private var connectionManager = GlassesConnectionManager.shared

    @State private var urlText: String = "https://verdana-loop.vercel.app/"
    @State private var analysis: LinkAnalysis?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var scanSource: ScanSource = .automatic

    /// El manejador de QR de las gafas es compartido con el resto de la app
    /// (el de `GlassesConnectionManager`, que inyecta el stand como contexto).
    /// Esta vista se lo apropia mientras está en pantalla y lo devuelve al salir.
    @State private var previousGlassesHandler: ((String) -> Void)? = nil

    /// De dónde salen los frames para buscar el QR. El usuario puede forzarlo:
    /// las gafas pueden estar conectadas y aun así no detectar (mala luz, ángulo,
    /// stream a medias), y en ese caso hay que poder saltar al teléfono a mano.
    private enum ScanSource: String, CaseIterable {
        case automatic = "Automático"
        case glasses   = "Gafas"
        case phone     = "Teléfono"
    }

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 24) {
                        AvatarOrb(isSpeaking: narrator.isSpeaking,
                                  pulse: narrator.speechPulse,
                                  isThinking: isAnalyzing)
                            .frame(height: 180)
                            .padding(.top, 8)

                        statusCaption

                        inputRow

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                        }

                        if let script = narrator.script {
                            scriptTranscript(script)
                        }

                        if let analysis, analysis.layer >= .security {
                            metricsRow(analysis)
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear {
            // El QR detectado por las gafas dispara el análisis sin que el usuario
            // teclee nada: ése es el punto de que el agente sea autónomo.
            bindPhoneHandler()
            previousGlassesHandler = cameraManager.onQRDetected
            cameraManager.onQRDetected = { payload in
                handleScannedPayload(payload)
            }
        }
        .onDisappear {
            cameraManager.stopQRScanning()
            phoneSession.stop()
            phoneSession.onDetect = nil
            cameraManager.onQRDetected = previousGlassesHandler
            narrator.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AVATAR IA")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text(narrator.routedToGlasses ? "Voz por las gafas" : "Voz por el teléfono")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(narrator.routedToGlasses ? .brand : .gray)
                }
            }
            Spacer()
            Button(action: { narrator.stop(); dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.09).ignoresSafeArea(edges: .top))
    }

    private var statusCaption: some View {
        Text(caption)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.gray)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private var caption: String {
        if isAnalyzing { return "Analizando…" }
        if narrator.isSpeaking { return "Hablando" }
        if narrator.script != nil { return "Listo. Toca reproducir para escucharlo otra vez." }
        return "Dame un enlace y te cuento qué encontré."
    }

    // MARK: - Entrada

    private var inputRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundColor(.gray)
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.12))
            .cornerRadius(12)

            HStack(spacing: 10) {
                Button(action: analyze) {
                    Label(isAnalyzing ? "Analizando…" : "Analizar y narrar",
                          systemImage: "waveform.badge.magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isAnalyzing ? Color.gray : Color.cyan)
                        .cornerRadius(12)
                }
                .disabled(isAnalyzing)

                if narrator.script != nil {
                    Button(action: { narrator.toggle() }) {
                        Image(systemName: narrator.isSpeaking ? "stop.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.cyan)
                            .frame(width: 48, height: 44)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(12)
                    }
                }
            }

            qrScanRow
        }
        .padding(.horizontal, 20)
    }

    /// Escaneo de QR. Usa las gafas cuando su cámara transmite; si no, cae a la
    /// cámara del teléfono. Así el escaneo nunca queda bloqueado por el hardware.
    private var qrScanRow: some View {
        VStack(spacing: 8) {
            // Fuente de la cámara. Visible siempre: si las gafas están conectadas
            // pero no logran leer el código, se salta al teléfono sin desconectar.
            HStack(spacing: 6) {
                Text("Cámara")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                Picker("Cámara", selection: $scanSource) {
                    ForEach(ScanSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isScanningAnywhere)
            }

            Button(action: toggleScan) {
                HStack(spacing: 8) {
                    Image(systemName: isScanningAnywhere ? "viewfinder.circle.fill" : "qrcode.viewfinder")
                    Text(scanButtonTitle)
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isScanningAnywhere ? Color.brand.opacity(0.25) : Color(white: 0.12))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isScanningAnywhere ? Color.brand : .clear, lineWidth: 1)
                )
            }

            // Vista previa solo cuando escanea con el teléfono: con las gafas,
            // la imagen ya se ve en el espejo del HUD.
            if phoneSession.isRunning {
                PhoneQRPreview()
                    .frame(height: 180)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.brand.opacity(0.6), lineWidth: 2)
                    )
            }

            if phoneSession.permissionDenied {
                Text("Permiso de cámara denegado. Actívalo en Ajustes › GlassesInstructor.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else if cameraManager.isScanningQR {
                Text("Buscando con las gafas · \(cameraManager.qrFramesInspected) frames")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.brand)
            } else if phoneSession.isRunning {
                Text("Buscando con la cámara del teléfono")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.brand)
            } else if scanSource == .glasses && !isGlassesReady {
                Text("Conecta las gafas o cambia la cámara a Teléfono.")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            } else if !isGlassesReady {
                Text("Sin gafas: se usará la cámara del teléfono.")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
    }

    private var isScanningAnywhere: Bool {
        cameraManager.isScanningQR || phoneSession.isRunning
    }

    /// Lo que decide si las gafas pueden escanear es que estén **conectadas**, no
    /// que su cámara ya esté transmitiendo: el stream se enciende al escanear.
    private var isGlassesReady: Bool {
        connectionManager.connectionState == .connected
    }

    private var scanButtonTitle: String {
        if isScanningAnywhere { return "Escaneando… apunta al QR" }
        switch scanSource {
        case .glasses: return "Escanear QR con las gafas"
        case .phone:   return "Escanear QR con el teléfono"
        case .automatic:
            return isGlassesReady ? "Escanear QR con las gafas"
                                  : "Escanear QR con el teléfono"
        }
    }

    private func toggleScan() {
        if isScanningAnywhere {
            cameraManager.stopQRScanning()
            phoneSession.stop()
            return
        }

        errorMessage = nil

        switch scanSource {
        case .glasses:
            guard isGlassesReady else {
                errorMessage = "Conecta tus gafas primero para escanear con ellas."
                return
            }
            Task { await cameraManager.startQRScanning(source: .glasses) }

        case .phone:
            Task { await cameraManager.startQRScanning(source: .phone) }

        case .automatic:
            // El propio manager resuelve la cámara: gafas si están vinculadas,
            // teléfono si no, y teléfono de relevo si las gafas no leen.
            Task { await cameraManager.startQRScanning() }
        }
    }

    private func bindPhoneHandler() {
        phoneSession.onDetect = { url in
            handleScannedPayload(url.absoluteString)
        }
    }

    /// Punto único de llegada del QR, venga de las gafas o del teléfono.
    private func handleScannedPayload(_ payload: String) {
        guard let url = QRScanner.navigableURL(from: payload) else {
            errorMessage = "El código no contiene un enlace navegable."
            return
        }
        urlText = url.absoluteString
        cameraManager.stopQRScanning()
        phoneSession.stop()
        analyze()
    }

    // MARK: - Transcripción

    private func scriptTranscript(_ script: AvatarScript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(script.lines.enumerated()), id: \.element.id) { index, line in
                let isCurrent = index == narrator.currentLineIndex
                HStack(alignment: .top, spacing: 10) {
                    Text(line.tone.glyph)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(color(for: line.tone))
                        .frame(width: 14)

                    Text(line.written)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? .white : Color(white: 0.62))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isCurrent ? Color.cyan.opacity(0.12) : Color(white: 0.09))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isCurrent ? Color.cyan.opacity(0.5) : .clear, lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.2), value: isCurrent)
            }
        }
        .padding(.horizontal, 20)
    }

    private func color(for tone: ScriptTone) -> Color {
        switch tone {
        case .neutral:  return .gray
        case .positive: return .brand
        case .concern:  return .orange
        case .verdict:  return .cyan
        case .action:   return .yellow
        }
    }

    // MARK: - Métricas

    private func metricsRow(_ a: LinkAnalysis) -> some View {
        HStack(spacing: 10) {
            MetricChip(label: "SEGURIDAD",
                       value: "\(a.securityScore)",
                       tint: a.securityVerdict.color)
            if a.layer >= .craft {
                MetricChip(label: "ARTESANÍA",
                           value: "\(a.craftScore)",
                           tint: a.craftVerdict.color)
            }
            if let ms = a.ttfbMilliseconds {
                MetricChip(label: "RESPUESTA", value: "\(ms)ms", tint: .gray)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Acción

    private func analyze() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Ese enlace no es válido. Debe empezar con http o https."
            return
        }

        errorMessage = nil
        narrator.stop()
        analysis = nil
        isAnalyzing = true

        Task {
            for await partial in LinkAnalyzer.shared.analyze(url) {
                analysis = partial

                // En cuanto la cascada completa, el avatar tiene qué decir.
                if partial.layer >= .craft {
                    narrator.load(AvatarScript.build(from: partial))
                    narrator.speak()
                }
            }
            isAnalyzing = false

            if analysis == nil {
                errorMessage = "No pude alcanzar ese sitio. Revisa la conexión o el dominio."
            }
        }
    }
}

// MARK: - Orbe del avatar

/// Avatar abstracto: anillos concéntricos que laten con la voz.
/// Se pulsa desde `speechPulse`, que el sintetizador emite por fragmento hablado,
/// así que el movimiento va sincronizado con la voz real y no con un timer suelto.
private struct AvatarOrb: View {
    let isSpeaking: Bool
    let pulse: Int
    let isThinking: Bool

    @State private var beat: CGFloat = 1.0
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(
                        LinearGradient(colors: [.cyan.opacity(0.7), .blue.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2
                    )
                    .frame(width: 96 + CGFloat(ring) * 30, height: 96 + CGFloat(ring) * 30)
                    .scaleEffect(beat - CGFloat(ring) * 0.03)
                    .opacity(isSpeaking ? 1.0 : 0.45)
                    .rotationEffect(.degrees(rotation + Double(ring) * 24))
            }

            Circle()
                .fill(
                    RadialGradient(colors: [.cyan.opacity(0.85), .blue.opacity(0.1)],
                                   center: .center, startRadius: 2, endRadius: 60)
                )
                .frame(width: 84, height: 84)
                .scaleEffect(beat)
                .blur(radius: isSpeaking ? 0.5 : 2)

            Image(systemName: isThinking ? "ellipsis" : "sparkles")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .symbolEffect(.pulse, isActive: isThinking)
        }
        .onChange(of: pulse) { _, _ in
            // Late una vez por fragmento hablado.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
                beat = 1.10
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(0.10)) {
                beat = 1.0
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct MetricChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }
}
