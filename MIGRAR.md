# Migrar de `truena-fepro` a `unalineaalavez/glassesInstructor`

Los dos repos divergieron: tú tienes Shiki (`AIManager`, `AvatarHUDManager`,
`ProjectAuditAgent`) y yo tengo el guard de desconexión y el escaneo por
teléfono. **Un `git merge` te pisaría el trabajo**, así que esto va en dos
partes: lo que se copia sin riesgo y lo que se aplica a mano.

## Estado actual

| Archivo | Estado |
|---|---|
| `Models/LinkAnalysis.swift` | ✅ ya migrado (idéntico) |
| `Analysis/LinkAnalyzer.swift` | ✅ ya migrado (idéntico) |
| `Analysis/ProjectAuditAgent.swift` | tuyo, no lo toco |
| `Analysis/PhoneQRSession.swift` | ⬜ falta — **el que resuelve tu problema** |
| `Views/Phone/GlassesOfflineOverlay.swift` | ⬜ falta |
| `Analysis/QRScanner.swift` | ⬜ opcional |
| `Managers/AvatarNarrator.swift` | ⬜ opcional (ya tienes tu TTS) |
| `Models/AvatarScript.swift` | ⬜ opcional |
| `Views/Phone/AvatarAIView.swift` | ⬜ opcional (ya tienes Shiki) |

---

# Parte 1 · Copiar archivos nuevos

```bash
cd "…/qa/glassesInstructor-qa/.claude/worktrees/truena-fepro"
./migrar-a-unalineaalavez.sh --dry-run   # revisa qué haría
./migrar-a-unalineaalavez.sh             # copia
```

Nunca sobrescribe: si un archivo ya existe allá, lo omite.

**Mínimo para lo que pediste:** `PhoneQRSession.swift` y
`GlassesOfflineOverlay.swift`. Los demás son opcionales porque ya tienes Shiki.

> `PhoneQRSession` usa `QRScanner.navigableURL(...)`. Si no copias
> `QRScanner.swift`, pega ese método dentro de `PhoneQRSession` como
> `static func navigableURL` y cambia la llamada a `Self.navigableURL(...)`.

---

# Parte 2 · Cambios a mano

Estos archivos divergieron demasiado para copiarse. Aplica solo el fragmento.

## 2.1 · `SpeechAudioManager.swift` — el micrófono mudo

**El más rentable: una línea y recuperas el dictado.**

Busca (cerca de la línea 150):

```swift
let inputNode = audioEngine.inputNode
let recordingFormat = inputNode.outputFormat(forBus: 0)

inputNode.removeTap(onBus: 0)
```

Sustituye por:

```swift
// El motor debe estar detenido antes de reconfigurar la sesión: cambiar la
// categoría con el engine corriendo invalida el formato del input node y el
// tap empieza a recibir buffers de 0 bytes (micrófono mudo, sin error).
audioEngine.stop()
audioEngine.inputNode.removeTap(onBus: 0)
audioEngine.reset()

let inputNode = audioEngine.inputNode
// `inputFormat` es el formato real del micrófono. Con `outputFormat` justo
// después de activar la sesión llega sampleRate 0, y el tap instalado con ese
// formato produce "mBuffers[0].mDataByteSize (0) should be non-zero".
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
```

> El bloque debe ir **antes** de `setCategory`, y `audioSession` debe estar ya
> declarado. Si en tu archivo `setCategory` viene después, mueve el
> `audioEngine.stop()/reset()` arriba del todo.

## 2.2 · `AIManager.swift` — que el TTS no mate el micrófono

Tu TTS y el dictado comparten `AVAudioSession`. Reconfigurar la categoría con
el engine corriendo invalida el tap. **En tu método que habla**, antes de
`synthesizer.speak(...)`:

```swift
private var wasListeningBeforeSpeech = false

// … dentro del método que habla, antes de speak():
wasListeningBeforeSpeech = SpeechAudioManager.shared.isListening
if wasListeningBeforeSpeech {
    SpeechAudioManager.shared.stopListening()
}
```

Y en `didFinish` / `didCancel` del `AVSpeechSynthesizerDelegate`:

```swift
if wasListeningBeforeSpeech {
    wasListeningBeforeSpeech = false
    SpeechAudioManager.shared.startListening()
}
```

## 2.3 · `AIManager.swift` — el aviso `unsafeForcedSync`

`speechVoices()` es cara y síncrona; la llamas en cada reproducción. Cachéala:

```swift
private static let cachedVoice: AVSpeechSynthesisVoice? = {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    return voices.first { $0.language == "es-MX" && $0.quality != .default }
        ?? voices.first { $0.language == "es-MX" }
        ?? AVSpeechSynthesisVoice(language: "es-ES")
}()
```

Y usa `utterance.voice = Self.cachedVoice`.

## 2.4 · `CameraStreamManager.swift` — los 6 fixes

**(a) Liberar el hardware.** El más grave: sin `camera.stop()` el firmware
mantiene el recurso tomado y el siguiente `addCamera()` falla. Por eso fallaba
más al segundo intento.

```swift
func detachCamera() {
    stopStream()
    camera?.stop()          // ← AÑADIR
    streamTokens.removeAll()
    camera = nil
    latestFrame = nil
    currentFPS = 0.0
    isStreaming = false     // ← AÑADIR
    streamStatusMessage = "Cámara inactiva"
}
```

**(b) Quitar el guard que impide detener.** Si la bandera se desincroniza
(muerte por térmica o bisagras), el stream seguía vivo:

```swift
func stopStream() {
    // guard isStreaming else { return }   ← BORRAR esta línea
    camera?.stream.stop()
    isStreaming = false
    currentFPS = 0.0
    streamStatusMessage = "Cámara detenida"
}
```

**(c) No marcar `isStreaming` de forma optimista.** `start()` es asíncrono:

```swift
camera.stream.start()
// isStreaming = true                       ← BORRAR
streamStatusMessage = "Iniciando cámara…"   // la bandera la pone el statePublisher
```

**(d) Usar el `statePublisher` como fuente de verdad.** Reemplaza el listener
que solo loguea:

```swift
let stateToken = cameraCapability.stream.statePublisher.listen { [weak self] state in
    Task { @MainActor in self?.handleStreamState(state) }
}

// …y añade:
private func handleStreamState(_ state: StreamState) {
    switch state {
    case .streaming:
        isStreaming = true
        lastStreamError = nil
        streamStatusMessage = "Transmitiendo en vivo"
    case .waitingForDevice:
        isStreaming = false
        streamStatusMessage = "Esperando a las gafas…"
    case .starting:
        streamStatusMessage = "Iniciando cámara…"
    case .paused:
        isStreaming = false; currentFPS = 0
        streamStatusMessage = "Pausado por el dispositivo"
    case .stopping, .stopped:
        isStreaming = false; currentFPS = 0
        streamStatusMessage = "Cámara detenida"
    }
}
```

**(e) Errores accionables.** En el `errorPublisher`:

```swift
private func handleStreamError(_ error: StreamError) {
    isStreaming = false
    currentFPS = 0
    let message: String
    switch error {
    case .hingesClosed:
        message = "Las gafas están plegadas. Ábrelas y póntelas (o tapa el sensor nasal)."
    case .thermalCritical, .thermalEmergency:
        message = "Las gafas se calentaron y cortaron el video. Déjalas enfriar un minuto."
    case .peakPowerShutdown:
        message = "Corte por pico de consumo. Déjalas reposar."
    case .batteryCritical:
        message = "Batería crítica en las gafas. Ponlas a cargar."
    case .permissionDenied:
        message = "Permiso de cámara denegado. Habilítalo en la app Meta AI."
    case .deviceNotConnected: message = "Las gafas se desconectaron."
    case .deviceNotFound:     message = "No encuentro las gafas."
    case .photoCaptureFailed: message = "No se pudo capturar la foto."
    case .internalError:      message = "Error interno del SDK de cámara."
    case .timeout:
        message = "El video no respondió. Revisa que iPhone y gafas estén en el mismo Wi-Fi, sin VPN."
    case .videoStreamingError:
        message = "Falló el canal de video. Suele ser la red: prueba un hotspot propio."
    default: message = "Error de cámara: \(error)"
    }
    lastStreamError = message
    streamStatusMessage = "Error de cámara"
    DiagnosticLogger.shared.log(.error, tag: "Camera", message: message)
}
```

**(f) El QR ya no exige gafas.** En tu `startQRScanning()`:

```swift
func startQRScanning() async {
    if camera != nil {
        isScanningQR = true
        await startStream()
    } else {
        // Sin gafas: la cámara del teléfono. Tu demo deja de depender del hardware.
        await PhoneQRSession.shared.start()
    }
}
```

## 2.5 · `GlassesDeviceState.swift`

```swift
/// Único dato de salud que el SDK expone (`DeviceState.thermalLevel`).
var thermalLevel: String = "desconocido"
```

## 2.6 · `GlassesConnectionManager.swift` — el guard de desconexión

Propiedades nuevas:

```swift
@Published var isGlassesOffline: Bool = false
@Published var offlineReason: String?

private var linkWatchTask: Task<Void, Never>?
private var isIntentionalDisconnect = false
```

Métodos nuevos:

```swift
/// Corte de emergencia: las gafas se fueron sin avisar.
func handleUnexpectedDisconnection(reason: String) {
    guard !isIntentionalDisconnect else { return }
    guard connectionState != .disconnected, !isGlassesOffline else { return }

    logger.log(.error, tag: "Connection", message: "Enlace perdido: \(reason)")
    teardownEverything()

    connectionState = .error
    telemetry.lastErrorDescription = reason
    offlineReason = reason
    isGlassesOffline = true
}

func dismissOfflineBanner() {
    isGlassesOffline = false
    offlineReason = nil
    connectionState = .disconnected
}

/// Apaga todo lo que consume el enlace. `PhoneQRSession` NO se toca: usa la
/// cámara del teléfono y sigue siendo válida sin gafas.
private func teardownEverything() {
    clearRegistrationWatchdog()
    linkWatchTask?.cancel()
    linkWatchTask = nil

    cameraManager.detachCamera()
    hudManager.detachDisplay()
    speechManager.stopListening()

    connectionTokens.removeAll()
    session?.stop()
    session = nil

    telemetry.isDisplayReady = false
    telemetry.isCameraStreaming = false
}

/// Vigila térmica y caídas mientras la sesión vive.
private func startLinkWatch(for deviceId: DeviceIdentifier) {
    linkWatchTask?.cancel()
    linkWatchTask = Task { [weak self] in
        guard let self else { return }
        for await deviceState in Wearables.shared.deviceStateStream(for: deviceId) {
            if Task.isCancelled { return }
            await self.handleThermal(deviceState.thermalLevel)
        }
    }
}

private func handleThermal(_ level: ThermalLevel) {
    telemetry.thermalLevel = "\(level)"
    switch level {
    case .severe:
        logger.log(.warning, tag: "Thermal", message: "Las gafas se están calentando.")
    case .critical, .emergency, .shutdown:
        handleUnexpectedDisconnection(
            reason: "Las gafas se sobrecalentaron y cortaron la sesión. Déjalas enfriar un minuto.")
    default: break
    }
}
```

**`disconnectGlasses()`** — el estado baja **antes** del teardown, porque
`session.stop()` emite `.stopped` de forma asíncrona y si no, saldría el aviso
de "sin conexión" cuando fuiste tú quien desconectó:

```swift
func disconnectGlasses() {
    isIntentionalDisconnect = true
    connectionState = .disconnected
    isGlassesOffline = false
    offlineReason = nil

    teardownEverything()

    Task { [weak self] in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        self?.isIntentionalDisconnect = false
    }
}
```

**`handleSessionState`**:

```swift
private func handleSessionState(_ state: DeviceSessionState) {
    switch state {
    case .stopped:
        if connectionState == .connected && !isIntentionalDisconnect {
            handleUnexpectedDisconnection(
                reason: "Se perdió el enlace con las gafas. Revisa que estén abiertas, puestas y con batería.")
        }
    case .paused:
        handleUnexpectedDisconnection(
            reason: "Las gafas pausaron la sesión. Ábrelas y póntelas para continuar.")
    default: break
    }
}
```

Y en el **paso 8** de `connectGlasses()`, antes de `connectionState = .connected`:

```swift
startLinkWatch(for: validDeviceId)
isGlassesOffline = false
offlineReason = nil
```

## 2.7 · `FullScreenMainView.swift` — enganches

**El botón Shiki del HUD que no abre nada.** El HUD cambia el modo pero nadie
lo escucha:

```swift
.onReceive(hudManager.$currentMode) { mode in
    if mode == .aiAgent {        // el caso que nombraste Shiki
        showingShiki = true
    }
}
```

**El guard visual.** Nota que Shiki queda **fuera** de la lista: analiza
enlaces y escanea con el teléfono, así que sigue siendo útil sin gafas.

```swift
.glassesOfflineGuard(closing: Binding(
    get: { [showingCameraDetail, showingDictationDetail] },
    set: { values in
        showingCameraDetail    = values[0]
        showingDictationDetail = values[1]
    }
), onUsePhone: {
    showingShiki = true
})
```

## 2.8 · `project.yml` — iOS 17.2

El SDK declara `MinimumOSVersion 17.2`. Con 16.0 compila pero **la app no
arranca en iPhone con iOS 16.x**:

```yaml
deploymentTarget: "17.2"
```

---

# Parte 3 · Verificar

```bash
cd "…/unalineaalavez/glassesInstructor"
xcodegen generate
xcodebuild -scheme GlassesInstructor \
  -destination 'generic/platform=iOS Simulator' build
```

## Orden recomendado

Aplica de mayor a menor impacto, compilando entre pasos:

1. **2.1** micrófono mudo — una línea, recuperas el dictado
2. **2.4a/b** `camera.stop()` y el guard — arregla el fallo al reconectar
3. **Parte 1** + **2.4f** — QR por teléfono, tu demo deja de depender del hardware
4. **2.7** el botón Shiki
5. **2.6** + `GlassesOfflineOverlay` — el guard de desconexión
6. Lo demás

## Prueba rápida

| Qué probar | Resultado esperado |
|---|---|
| Dictar sin conectar gafas | Transcribe (sin `mDataByteSize (0)` en el log) |
| Conectar → desconectar → conectar | Funciona al segundo intento |
| Escanear QR sin gafas | Usa la cámara del teléfono |
| Plegar las gafas conectadas | Sale "GAFAS SIN CONEXIÓN" |
| Pulsar Desconectar | **No** sale el aviso (fue intencional) |
| Tocar Shiki en el HUD | Abre la vista en el teléfono |
