import Foundation
import AVFoundation
import UIKit
import SwiftUI

/// Escaneo de QR con la cámara del **iPhone**, como respaldo de las gafas.
///
/// Existe por una razón práctica: si el escaneo depende solo de
/// `camera != nil` (la capacidad MWDAT), entonces sin gafas conectadas no se
/// puede escanear nada — y en una demostración en vivo eso significa quedarse
/// sin nada que mostrar cuando la conexión falla.
///
/// Usa `AVCaptureMetadataOutput`, que detecta QR en hardware. Es más barato que
/// correr Vision por frame y no calienta nada.
@MainActor
final class PhoneQRSession: NSObject, ObservableObject {
    static let shared = PhoneQRSession()

    @Published private(set) var isRunning = false
    @Published private(set) var lastPayload: String?
    @Published private(set) var permissionDenied = false

    /// Se dispara una sola vez por QR nuevo.
    var onDetect: ((URL) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    /// Continuacion viva mientras se espera el disparo.
    private var photoContinuation: CheckedContinuation<Data?, Never>?
    private let sessionQueue = DispatchQueue(label: "phone.qr.session")

    private var lastAcceptedPayload: String?
    private var lastAcceptedAt = Date.distantPast
    private let rearmInterval: TimeInterval = 3.0

    private let logger = DiagnosticLogger.shared

    /// Capa de vista previa para mostrar lo que ve la cámara del teléfono.
    private(set) lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private override init() {
        super.init()
        observeSessionHealth()
    }

    /// Traduce los fallos de `AVCaptureSession` a algo accionable.
    ///
    /// Cuando la sesión no puede abrir la cámara, iOS no lanza ningún error a la app:
    /// vuelca en consola un assert de CoreMedia del tipo
    /// `FigCaptureSourceRemote ... Fig assert: "err == 0" ... (err=-17281)`, que no
    /// dice qué pasó ni de qué cámara habla — y aquí, con las gafas de por medio,
    /// parece un fallo de las gafas cuando es la cámara del teléfono.
    private func observeSessionHealth() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                           object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let explanation: String
            switch reason {
            case .videoDeviceNotAvailableInBackground:
                explanation = "la app no está en primer plano"
            case .videoDeviceInUseByAnotherClient:
                explanation = "otra app tiene tomada la cámara"
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                explanation = "la pantalla está partida con otra app"
            case .videoDeviceNotAvailableDueToSystemPressure:
                explanation = "el teléfono está demasiado caliente"
            case .audioDeviceInUseByAnotherClient:
                explanation = "otra app tiene tomado el micrófono"
            default:
                explanation = "motivo \(raw.map(String.init) ?? "desconocido")"
            }
            Task { @MainActor in
                self?.logger.log(.warning, tag: "QR",
                    message: "La cámara del teléfono se interrumpió: \(explanation). Siguen escaneando las gafas.")
            }
        }

        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                           object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.logger.log(.info, tag: "QR", message: "La cámara del teléfono volvió a estar disponible.")
            }
        }

        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                           object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let detail = error.map { "\($0.localizedDescription) (código \($0.code))" } ?? "sin detalle"
            Task { @MainActor in
                self?.logger.log(.error, tag: "QR",
                    message: "Error de la cámara del teléfono: \(detail).")
                self?.isRunning = false
            }
        }

        center.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                           object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.logger.log(.success, tag: "QR", message: "Cámara del teléfono lista como respaldo.")
            }
        }
    }

    func start() async {
        guard !isRunning else { return }

        // 1. Permiso de cámara del teléfono (distinto al de las gafas)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            permissionDenied = true
            logger.log(.error, tag: "QR",
                       message: "Permiso de cámara del teléfono denegado. Actívalo en Ajustes > GlassesInstructor.")
            return
        }
        permissionDenied = false

        // 2. Configurar una sola vez
        if session.inputs.isEmpty {
            guard configureSession() else { return }
        }

        // 3. Arrancar fuera del hilo principal: startRunning bloquea
        isRunning = true
        logger.log(.info, tag: "QR", message: "Escaneo con la cámara del teléfono activo.")
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        logger.log(.info, tag: "QR", message: "Escaneo con la cámara del teléfono detenido.")
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Toma una foto con la camara del telefono. Devuelve JPEG o nil.
    ///
    /// Existe para que leer el ambiente no dependa del enlace con las gafas: si el
    /// linkState no llega a connected, esto sigue funcionando.
    func capturePhoto() async -> Data? {
        guard isRunning, session.outputs.contains(photoOutput) else {
            logger.log(.warning, tag: "Ambiente", message: "La camara del telefono no esta activa.")
            return nil
        }
        guard photoContinuation == nil else { return nil }

        return await withCheckedContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            logger.log(.error, tag: "QR", message: "No se pudo abrir la cámara trasera del teléfono.")
            return false
        }
        session.addInput(input)

        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            logger.log(.error, tag: "QR", message: "No se pudo añadir el detector de códigos.")
            return false
        }
        session.addOutput(metadataOutput)

        // Salida de foto para leer el ambiente sin depender de las gafas.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else {
            logger.log(.warning, tag: "QR", message: "Sin salida de foto: no se podra leer el ambiente con el telefono.")
        }

        // Cierre de la configuración ANTES de tocar los tipos.
        //
        // `availableMetadataObjectTypes` solo está poblado una vez que la conexión
        // entre input y output existe, es decir, después de commitConfiguration().
        // Consultarlo dentro del bloque devuelve una lista vacía, el filtro se queda
        // sin tipos y el delegate no se llama jamás: la cámara "escanea" pero no
        // detecta nada, que es exactamente el sintoma que teniamos.
        session.commitConfiguration()

        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)

        let available = metadataOutput.availableMetadataObjectTypes
        if available.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        } else if !available.isEmpty {
            // Mejor escuchar todo lo que haya que quedarse sin ningún tipo.
            metadataOutput.metadataObjectTypes = available
            logger.log(.warning, tag: "QR", message: "Sin tipo .qr disponible; escuchando todos los códigos.")
        } else {
            logger.log(.error, tag: "QR", message: "El detector no expone ningún tipo de código. No se podrá escanear.")
            return false
        }

        logger.log(.info, tag: "QR", message: "Detector listo. Tipos activos: \(metadataOutput.metadataObjectTypes.count).")
        return true
    }
}

extension PhoneQRSession: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue else {
            // Sin esto no hay forma de distinguir "no ve el codigo" de "lo ve pero
            // el payload viene vacio".
            if !metadataObjects.isEmpty {
                DiagnosticLogger.shared.log(.warning, tag: "QR", message: "Código visto pero sin texto legible.")
            }
            return
        }

        Task { @MainActor in
            self.accept(payload)
        }
    }

    private func accept(_ payload: String) {
        let now = Date()
        // Un QR frente a la cámara dispara decenas de veces por segundo.
        if payload == lastAcceptedPayload,
           now.timeIntervalSince(lastAcceptedAt) < rearmInterval { return }

        lastPayload = payload

        guard let url = QRScanner.navigableURL(from: payload) else {
            logger.log(.warning, tag: "QR",
                       message: "QR leído pero no es un enlace: \(payload.prefix(60))")
            return
        }

        lastAcceptedPayload = payload
        lastAcceptedAt = now
        logger.log(.success, tag: "QR", message: "QR detectado con el teléfono: \(url.absoluteString)")
        onDetect?(url)
    }
}

/// Vista previa de la cámara del teléfono para colocar bajo el visor de QR.
struct PhoneQRPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.backgroundColor = .black
        view.layer.addSublayer(PhoneQRSession.shared.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {}

    /// `UIView` que reposiciona la capa en cada layout: sin esto la vista previa
    /// queda con tamaño cero y se ve negra.
    final class PreviewContainer: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            PhoneQRSession.shared.previewLayer.frame = bounds
        }
    }
}


extension PhoneQRSession: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.finishPhoto(data)
        }
    }
}

extension PhoneQRSession {
    /// Reanuda la espera una sola vez, gane quien gane.
    fileprivate func finishPhoto(_ data: Data?) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(returning: data)
    }
}
