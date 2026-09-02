# 🔴 Punto Muerto Confirmado: la conexión muere en `.registering`

**Estado:** ✅ Diagnosticado y corregido en la rama `truena-fepro`
**Método:** Log de ejecución real en iPhone + lectura del binario del SDK
**Fecha:** 2026-09-01

> Este hallazgo es de distinta naturaleza al resto de `QA_SECURITY_ANALYSIS.md`. Aquel documento
> contiene riesgos **potenciales**, algunos inferidos por lectura superficial. Éste es un fallo
> **reproducido en hardware real**, con causa raíz verificada contra el binario del SDK.

---

## 1. La evidencia

Log capturado en un iPhone real al pulsar *Conectar*:

```
[INFO]    [System]       Motor de diagnóstico inicializado.
[INFO]    [Network]      Disparando paquete UDP multicast...
[INFO]    [Mode]         Cambiando a modo: Cámara en Vivo
[ERROR]   [Camera]       Intento de iniciar cámara sin hardware asignado.   ← bug secundario
[INFO]    [Connection]   Iniciando secuencia de enlace con gafas...
[INFO]    [SDK]          Paso 1: Configurando Wearables SDK bajo demanda...
[SUCCESS] [SDK]          Wearables SDK configurado exitosamente.
[INFO]    [Registration] Estado de registro actualizado: RegistrationState(rawValue: 0)
[INFO]    [Registration] Paso 2: Estado de registro: RegistrationState(rawValue: 0)
[WARN]    [Registration] Abriendo app Meta AI para autorizar esquema...
[INFO]    [Registration] Estado de registro actualizado: RegistrationState(rawValue: 2)
                                                                            ← FIN. Nada más.
```

El log **no está truncado**. La app efectivamente dejó de trabajar ahí.

---

## 2. Qué significan esos números

Extraído de `MWDATCore.framework/Modules/MWDATCore.swiftmodule/arm64-apple-ios.swiftinterface:137`:

```swift
@objc(MWDATRegistrationState) @frozen public enum RegistrationState : Swift.Int {
  case unavailable   // 0
  case available     // 1
  case registering   // 2
  case registered    // 3
}
```

| Log | Estado real | Lectura |
|---|---|---|
| `rawValue: 0` | `.unavailable` | El SDK **todavía no estaba listo** |
| `rawValue: 2` | `.registering` | El registro arrancó y **se quedó ahí** |

**Nunca alcanzó `.registered` (3).**

---

## 3. Causa raíz

### 3.1 Se lanzó el registro sobre un SDK que no estaba listo

`GlassesConnectionManager.swift`, código original:

```swift
try Wearables.configure()
try? await Task.sleep(nanoseconds: 300_000_000)   // 300 ms fijos

let registration = wearables.registrationState     // → .unavailable
if registration != .registered {                   // .unavailable != .registered → true
    try await wearables.startRegistration()        // ⚠️ registro sobre SDK no listo
    return
}
```

El código trata **cualquier cosa distinta de `.registered`** como "hay que registrar". Pero
`.unavailable` no significa *"no registrado"*, significa *"el SDK aún no sabe"*. Los 300 ms
fijos no alcanzaron. Se inició la ceremonia de registro prematuramente y quedó atorada
en `.registering`, sin callback de vuelta.

### 3.2 Y nadie retomaba la secuencia

El `return` de esa rama **abandona la función**. La reanudación existía, pero exigía una
igualdad exacta que nunca se cumplió:

```swift
private func handleRegistrationChange(_ state: RegistrationState) {
    if state == .registered && connectionState == .registeringMetaAI {
        Task { await connectGlasses() }   // ← jamás se disparó: el estado se quedó en .registering
    }
}
```

Además, `.onOpenURL` en `GlassesInstructorApp.swift` procesaba el callback de Meta AI con
`handleUrl(url)` pero **no reanudaba la conexión**. El retorno desde Meta AI caía en el vacío.

**Consecuencia:** los pasos 3 a 8 del flujo documentado (scanner Bluetooth → linkState →
DeviceSession → handshake → Display → Camera) **nunca se ejecutaron ni una sola vez**.

---

## 4. La corrección

### 4.1 Esperar a que el SDK esté listo

Sustituye los 300 ms fijos por una espera real sobre el estado, con techo de 10 s:

```swift
var registration = wearables.registrationState

if registration == .unavailable {
    var ticks = 0
    while registration == .unavailable && ticks < Self.registrationReadyTicks {
        try? await Task.sleep(nanoseconds: 500_000_000)
        registration = wearables.registrationState
        ticks += 1
    }
}

guard registration != .unavailable else {
    connectionState = .error
    telemetry.lastErrorDescription = "El SDK de Meta nunca estuvo disponible. Verifica que Meta AI esté instalada, que Bluetooth esté encendido y que Wearables DAT Developer Mode esté activo."
    return
}
```

### 4.2 Doble vía de reanudación

El listener de estado no siempre dispara al volver a foreground. Ahora el callback URL
también reanuda:

```swift
// GlassesInstructorApp.swift
_ = try await Wearables.shared.handleUrl(url)
await GlassesConnectionManager.shared.resumeAfterRegistrationCallback()
```

### 4.3 Watchdog de 90 s

Si Meta AI nunca devuelve la autorización, la app deja de esperar para siempre y emite una
instrucción accionable en vez de quedarse muda:

> *"Meta AI no devolvió la autorización en 90s. Abre Meta View > Ajustes > Acerca de,
> toca 7 veces la versión y activa Wearables DAT Developer Mode."*

### 4.4 Logs legibles

`RegistrationState(rawValue: 2)` no dice nada en campo. Ahora:

```
[INFO] [Registration] Paso 2: Estado de registro: registering(2) · esperando callback de Meta AI
```

### 4.5 Bug secundario: cámara sin hardware

El `[ERROR] Intento de iniciar cámara sin hardware asignado` aparecía **antes** de conectar
porque la UI entraba en modo cámara con `camera == nil`. Ahora hay guarda previa:

```swift
case .cameraStream:
    guard connectionState == .connected else {
        logger.log(.warning, tag: "Mode", message: "Modo cámara solicitado sin sesión activa. Conecta las gafas primero.")
        return
    }
    await cameraManager.startStream()
```

---

## 5. Cómo verificar el fix

Vuelve a correr en el iPhone y compara. Debes ver estas líneas **nuevas**, que antes eran
imposibles:

```
[INFO]    [Registration] Paso 2: Estado de registro: unavailable(0) · SDK aún no listo
[INFO]    [Registration] SDK aún no disponible. Esperando a que el registro se poble...
[INFO]    [Registration] Estado tras esperar 1.5s: available(1) · listo para registrar
[WARN]    [Registration] Abriendo Meta AI para autorizar esquema (estado actual: available(1)...)
[INFO]    [Registration] Callback de Meta AI recibido. Estado: registered(3) · autorizado
[SUCCESS] [Registration] Registro completado. Reanudando secuencia de conexión...
[INFO]    [Discovery]    Paso 3: Suscribiendo listener para despertar Bluetooth Scanner...   ← ¡NUEVO!
```

**La línea que importa es `Paso 3`.** Si aparece, el punto muerto quedó atrás.

### Escenarios de fallo, ahora con mensaje claro

| Situación | Antes | Ahora |
|---|---|---|
| Meta AI no instalada | Silencio en `.registering` | Error tras 10 s con instrucción |
| Usuario no autoriza | Espera infinita | Watchdog a 90 s con pasos a seguir |
| Developer Mode apagado | Silencio | Instrucción explícita de cómo activarlo |
| Cámara antes de conectar | `[ERROR]` confuso | `[WARN]` explicando que falta conectar |

---

## 6. Estado de compilación

```
xcodebuild -scheme GlassesInstructor -destination 'generic/platform=iOS Simulator' build
** BUILD SUCCEEDED **
```

> Los avisos de SourceKit sobre `No such module 'UIKit'` / `'MWDATCore'` son falsos positivos
> del editor (intenta resolver hacia macOS). La compilación real para iOS pasa limpia.

---

## 7. Lo que este hallazgo enseña para la presentación

Es un caso de estudio mucho más fuerte que una vulnerabilidad de libro, porque combina
**tres antipatrones** que aparecen constantemente en código real:

1. **`sleep` fijo en lugar de esperar un estado.** Los 300 ms funcionaban en la máquina de
   quien lo escribió. En hardware real, no.
2. **Tratar un enum como booleano.** `!= .registered` colapsó cuatro estados distintos en
   dos, y perdió justo la distinción que importaba: *"no listo"* ≠ *"no registrado"*.
3. **Máquina de estados sin salida.** Un `return` que abandona el flujo confiando en que
   *alguien más* lo retome, sin timeout que detecte que nadie lo hizo.

Ninguno de los tres produce un crash. Producen algo peor de depurar: **una app que se queda
callada.** El log parecía normal — simplemente se detenía.
