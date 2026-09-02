import Foundation
import Speech
import AVFoundation
import Combine

/// Gestor de captura de audio y reconocimiento de voz en tiempo real
@MainActor
class SpeechAudioManager: ObservableObject {
    static let shared = SpeechAudioManager()
    
    @Published var isListening: Bool = false
    @Published var transcriptText: String = ""
    @Published var audioLevel: Float = 0.0
    @Published var permissionGranted: Bool = false
    @Published var statusMessage: String = "Micrófono en espera"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var onTranscriptUpdated: ((String) -> Void)?
    
    private init() {}
    
    /// Solicita permisos de Micrófono y Reconocimiento de Voz
    func requestPermissions() async -> Bool {
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        var micAllowed = (micStatus == .granted)
        
        if micStatus == .undetermined {
            micAllowed = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        var speechAllowed = (speechStatus == .authorized)
        
        if speechStatus == .notDetermined {
            speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
        
        let granted = micAllowed && speechAllowed
        self.permissionGranted = granted
        
        if granted {
            DiagnosticLogger.shared.log(.success, tag: "Speech", message: "Permisos de Micrófono y Reconocimiento de Voz concedidos.")
        } else {
            DiagnosticLogger.shared.log(.warning, tag: "Speech", message: "Permisos de Micrófono o Reconocimiento denegados.")
        }
        
        return granted
    }
    
    /// Inicia la captura de audio y la transcripción en vivo
    func startListening() {
        guard !isListening else { return }
        
        Task {
            let hasPermission = await requestPermissions()
            guard hasPermission else {
                statusMessage = "Faltan permisos de micrófono"
                return
            }
            
            do {
                try setupAndStartAudioEngine()
                isListening = true
                statusMessage = "Escuchando dictado en vivo..."
                DiagnosticLogger.shared.log(.info, tag: "Speech", message: "Captura de micrófono iniciada.")
            } catch {
                statusMessage = "Error al iniciar micrófono: \(error.localizedDescription)"
                DiagnosticLogger.shared.log(.error, tag: "Speech", message: "Fallo al iniciar audio engine: \(error.localizedDescription)")
            }
        }
    }
    
    /// Detiene la captura y transcripción
    func stopListening() {
        guard isListening else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        
        isListening = false
        audioLevel = 0.0
        statusMessage = "Micrófono detenido"
        DiagnosticLogger.shared.log(.info, tag: "Speech", message: "Captura de micrófono detenida.")
    }
    
    private func setupAndStartAudioEngine() throws {
        // Cancelar tareas previas
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // El motor debe estar detenido antes de reconfigurar la sesión: cambiar
        // la categoría con el engine corriendo invalida el formato del input node
        // y el tap empieza a recibir buffers de 0 bytes (mic mudo).
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // `inputFormat` es el formato real del micrófono. Con `outputFormat` justo
        // después de activar la sesión llega sampleRate 0, y el tap instalado con
        // ese formato produce "mBuffers[0].mDataByteSize (0) should be non-zero".
        var recordingFormat = inputNode.inputFormat(forBus: 0)

        if recordingFormat.sampleRate == 0 || recordingFormat.channelCount == 0 {
            let hardwareRate = audioSession.sampleRate > 0 ? audioSession.sampleRate : 44_100
            guard let fallback = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1) else {
                throw NSError(domain: "GlassesInstructor", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "El micrófono devolvió un formato inválido. Cierra otras apps que usen audio."
                ])
            }
            DiagnosticLogger.shared.log(.warning, tag: "Speech",
                message: "Formato de micrófono inválido; usando \(Int(hardwareRate)) Hz mono.")
            recordingFormat = fallback
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self?.recognitionRequest?.append(buffer)
            
            // Medir nivel de audio para la onda visual
            if let channelData = buffer.floatChannelData?[0] {
                let channelDataValue = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                let sum = channelDataValue.reduce(0) { $0 + abs($1) }
                let avg = sum / Float(buffer.frameLength)
                Task { @MainActor in
                    self?.audioLevel = min(max(avg * 10, 0.05), 1.0)
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw NSError(domain: "GlassesInstructor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reconocedor de voz no disponible en este dispositivo"])
        }
        
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] (result, error) in
            guard let self = self else { return }
            
            if let result = result {
                let bestString = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcriptText = bestString
                    self.onTranscriptUpdated?(bestString)
                }
            }
            
            if let error = error {
                Task { @MainActor in
                    DiagnosticLogger.shared.log(.warning, tag: "Speech", message: "Aviso de speech recognizer: \(error.localizedDescription)")
                }
            }
        }
    }
}
