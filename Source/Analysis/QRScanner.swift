import Foundation
import Vision
import CoreMedia
import UIKit

/// Detecta códigos QR en los frames de la cámara de las gafas.
///
/// Diseñado para lo que el hardware permite, no para lo ideal:
/// - **No analiza cada frame.** A 30 fps, correr Vision en todos calienta las gafas
///   y dispara `thermalCritical`. Muestrea a intervalo fijo.
/// - **Descarta frames si Vision va atrasado**, en vez de encolarlos: con una cola
///   creciente el QR detectado corresponde a lo que el usuario miraba hace segundos.
/// - **Antirrebote por payload**: un QR en cámara se detecta decenas de veces
///   seguidas; sin esto dispararías el análisis una y otra vez.
@MainActor
final class QRScanner: ObservableObject {
    static let shared = QRScanner()

    @Published private(set) var isScanning = false
    @Published private(set) var lastDetectedPayload: String?
    @Published private(set) var framesInspected = 0

    /// Se dispara una vez por QR nuevo detectado.
    var onDetect: ((URL) -> Void)?

    /// Cada cuánto se inspecciona un frame. 4/seg basta para que se sienta
    /// inmediato y deja la CPU (y la térmica) tranquilas.
    private let inspectionInterval: TimeInterval = 0.25
    /// Tiempo que hay que esperar para volver a aceptar el mismo payload.
    private let rearmInterval: TimeInterval = 3.0

    private var lastInspection = Date.distantPast
    private var lastAcceptedPayload: String?
    private var lastAcceptedAt = Date.distantPast
    private var isBusy = false

    private let logger = DiagnosticLogger.shared

    private init() {}

    func start() {
        guard !isScanning else { return }
        isScanning = true
        framesInspected = 0
        lastDetectedPayload = nil
        lastAcceptedPayload = nil
        logger.log(.info, tag: "QR", message: "Escáner de QR activo. Apunta las gafas al código.")
    }

    func stop() {
        guard isScanning else { return }
        isScanning = false
        logger.log(.info, tag: "QR", message: "Escáner de QR detenido.")
    }

    /// Punto de entrada desde el pipeline de cámara. Barato de llamar por frame:
    /// descarta casi todos antes de tocar Vision.
    func inspect(_ sampleBuffer: CMSampleBuffer) {
        guard isScanning, !isBusy else { return }

        let now = Date()
        guard now.timeIntervalSince(lastInspection) >= inspectionInterval else { return }
        lastInspection = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isBusy = true
        framesInspected += 1

        Task.detached(priority: .userInitiated) {
            let payloads = Self.detectPayloads(in: pixelBuffer)
            await self.finishInspection(payloads)
        }
    }

    /// Variante para cuando solo tienes la imagen ya convertida (p. ej. `capturePhoto`
    /// o una foto puntual, que es el modo recomendado por consumo térmico).
    func inspect(image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        guard !isBusy else { return }

        isBusy = true
        framesInspected += 1

        Task.detached(priority: .userInitiated) {
            let payloads = Self.detectPayloads(in: cgImage)
            await self.finishInspection(payloads)
        }
    }

    private func finishInspection(_ payloads: [String]) {
        isBusy = false
        guard let payload = payloads.first else { return }
        accept(payload)
    }

    /// Filtra repeticiones y payloads que no son enlaces navegables.
    private func accept(_ payload: String) {
        let now = Date()
        if payload == lastAcceptedPayload,
           now.timeIntervalSince(lastAcceptedAt) < rearmInterval {
            return  // mismo QR, todavía en ventana de rebote
        }

        lastDetectedPayload = payload

        guard let url = Self.navigableURL(from: payload) else {
            logger.log(.warning, tag: "QR",
                       message: "QR detectado pero no es un enlace navegable: \(payload.prefix(60))")
            return
        }

        lastAcceptedPayload = payload
        lastAcceptedAt = now
        logger.log(.success, tag: "QR", message: "QR detectado: \(url.absoluteString)")
        onDetect?(url)
    }

    // MARK: - Vision

    private nonisolated static func detectPayloads(in pixelBuffer: CVPixelBuffer) -> [String] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        return runRequest(with: handler)
    }

    private nonisolated static func detectPayloads(in cgImage: CGImage) -> [String] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return runRequest(with: handler)
    }

    private nonisolated static func runRequest(with handler: VNImageRequestHandler) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .filter { !$0.isEmpty }
    }

    // MARK: - Normalización de URL

    /// Los QR del mundo real traen `example.com` sin esquema, o `HTTPS://` en
    /// mayúsculas. Sin normalizar, `URL(string:)` produce basura que luego falla
    /// en la red y parece un fallo del escáner.
    static func navigableURL(from payload: String) -> URL? {
        var text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let scheme = URL(string: text)?.scheme?.lowercased() {
            // Rechaza esquemas que no se pueden analizar por HTTP (mailto, tel, wifi…)
            guard scheme == "http" || scheme == "https" else { return nil }
            return URL(string: text)
        }

        // Sin esquema: asumimos https si parece un dominio
        guard text.contains("."), !text.contains(" ") else { return nil }
        text = "https://" + text
        return URL(string: text)
    }
}
