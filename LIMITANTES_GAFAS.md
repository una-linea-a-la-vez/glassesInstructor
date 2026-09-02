# 👓 Limitantes reales de Meta Ray-Ban Display

**Fecha:** 2026-09-01
**Fuentes:** binario del SDK `MWDAT 0.9.0` (`.swiftinterface`), CHANGELOG del SDK,
`KNOWLEDGE_BASE.md` del repo, y la página oficial de producto.

> Todo lo marcado **[binario]** está leído del framework compilado, no de documentación.
> Cuando el SDK y la página de marketing se contradicen, manda el binario.

---

## 🚨 Las cinco limitantes que definen la arquitectura del agente

### 1. NO hay acceso al micrófono de las gafas **[binario]**

```swift
// MWDATCore.swiftinterface:93
public enum Permission : Swift.Sendable, Swift.CaseIterable {
  case camera        // ← el único caso. No existe .microphone
}
```

**El SDK expone exactamente un permiso: cámara.** No hay API de audio en `MWDATCore`,
`MWDATCamera` ni `MWDATDisplay`.

El "dictado" que ya existe en el repo usa `AVAudioEngine` + `SFSpeechRecognizer`
**del iPhone**, no el array de micrófonos de las gafas. Funciona, pero significa que
el teléfono tiene que estar escuchando — no las gafas.

**Consecuencia para tu agente:** el usuario **no puede hablarle a las gafas** para
activar tu agente. Ese canal pertenece a Meta AI y no está expuesto a terceros.

### 2. NO hay acceso a la Meta Neural Band **[página oficial + ausencia en binario]**

La pulsera EMG es el método de entrada principal del producto ("navega con gestos
naturales e intuitivos"). **No aparece en ninguna parte del SDK.** No hay eventos de
gesto, ni de touchpad de patilla.

**Consecuencia:** los gestos de muñeca solo controlan Meta AI. Tu agente no los recibe.

### 3. El HUD no tiene color **[binario]**

```swift
// MWDATDisplay.swiftinterface:675
public enum TextColor { case primary, secondary }   // ← eso es todo
public enum TextStyle { case heading, body, meta }
public enum Background { case none, card }
```

**No existe rojo, verde ni amarillo.** Un semáforo de color es imposible en el HUD.

> ⚠️ Esto corrige un supuesto de nuestro propio código: `Verdict.color` en
> `LinkAnalysis.swift` devuelve un `Color` de SwiftUI. Sirve para el espejo del HUD
> **en la pantalla del iPhone**, pero **no se puede enviar al waveguide**. Lo que sí
> viaja es `Verdict.glyph` (`OK` / `!` / `X`), que ya está implementado. Para las gafas,
> el estado se comunica con **glifo + palabra**, nunca con color.

### 4. Límite térmico, con corte duro **[binario]**

```swift
// MWDATCore.swiftinterface:447
public enum ThermalLevel {
  case unknown, none, light, moderate, severe, critical, emergency, shutdown
}

// MWDATCamera: el stream muere con estos errores
case thermalCritical
case thermalEmergency
case hingesClosed        // ← gafas plegadas
```

Ocho niveles térmicos, y el stream de cámara **se corta solo** al llegar a crítico.
`DeviceState` expone `thermalLevel` justamente para que lo vigiles.

**Consecuencia:** un agente que mantenga la cámara encendida en streaming continuo
**se apagará solo**. Esta es la limitante más dura para el diseño que quieres.

### 5. La telemetría es casi inexistente **[binario]**

```swift
// MWDATCore.swiftinterface:316
public struct DeviceState {
  public var thermalLevel: ThermalLevel   // ← el único campo
}
```

**No hay nivel de batería en el SDK.** El `DeviceTelemetry` del repo tiene campos que
no se pueden llenar desde el SDK. El panel de "Diagnóstico" del HUD solo puede mostrar
de verdad: nombre del dispositivo, `linkState`, estado de sesión y nivel térmico.

---

## 🐛 Bug encontrado: el proyecto declara una versión de iOS imposible

| Fuente | Valor |
|---|---|
| `project.yml:12` | `deploymentTarget: "16.0"` |
| `README.md` (badge) | `iOS 16.0+` |
| **SDK `MinimumOSVersion`** **[binario]** | **17.2** |
| **Target triple del binario** | `arm64-apple-ios17.2` |

El CHANGELOG del SDK 0.9.0 lo confirma:
> *"Minimum deployment target bumped from iOS 15.2 to iOS 17.2. Apps targeting older
> iOS versions can no longer link the SDK."*

**El proyecto compila** (los xcframeworks binarios no siempre fuerzan la validación al
enlazar), **pero un iPhone con iOS 16.x no podrá ejecutar la app.** Hay que subir
`deploymentTarget` a `17.2` y corregir el README.

---

## 🎨 Qué SÍ puedes dibujar en el HUD **[binario]**

600×600 px, monocular, lente derecha.

| Componente | Opciones |
|---|---|
| `Text` | 3 estilos (`heading`/`body`/`meta`) × 2 colores (`primary`/`secondary`) |
| `Button` | 3 estilos (`primary`/`secondary`/`outline`), icono opcional, **`onClick` funcional** |
| `ButtonGroup` | agrupación con alineación `start`/`center`/`end` |
| `Icon` | **220 iconos** integrados, en `filled` u `outline` |
| `Image` | `UIImage` arbitraria — la vía de escape para gráficos complejos |
| `FlexBox` | dirección, spacing, alineación, wrap, padding, `onTap` |
| `VideoPlayer` | reproduce video por URI (mp4) |

**Lo que sí hay y vale oro para tu agente:** `Button.onClick` y `FlexBox.onTap`
**funcionan**. El usuario puede responder tocando opciones en el HUD aunque no tengas
ni voz ni gestos.

**El escape:** `Image(UIImage)` acepta cualquier imagen. Puedes renderizar lo que
quieras con `UIGraphicsImageRenderer` a 600×600 — incluido color real — y mandarlo
como imagen. Cuesta ancho de banda y batería, pero rompe el techo de 2 colores.

### Modelo de envío

```swift
final public func send(_ view: some DisplayableView) async throws
final public func clearDisplay() async throws
```

`send()` **reemplaza la pantalla completa**. No hay actualización parcial: cada cambio
es un re-render total. Para tu cascada de análisis, eso significa **4 `send()`**, uno
por capa.

---

## 📱 Hardware (página oficial de Meta)

| Spec | Valor |
|---|---|
| Batería gafas | **6 h de uso mixto**, +24 h con estuche |
| Batería Neural Band | 18 h |
| Cámara | 12 MP, zoom 3x |
| Foto / video | hasta 3K Ultra HD / 1080p+ a 30 fps |
| Resistencia | **IPX4** (salpicaduras; no sumergible) |
| Graduación | −4.00 a +4.00 |
| Requiere | app Meta AI + cuenta Meta + internet |

**6 horas es de uso mixto.** Con la cámara transmitiendo, es sustancialmente menos.

> **Nota de disponibilidad:** la página mexicana marca el producto como *"disponible
> para comprar únicamente en tienda"*. Vale la pena confirmar que el hardware que vas a
> usar en la presentación está en tus manos antes de comprometerte a demo en vivo.

---

## 🤖 Arquitectura recomendada para el agente

Dado que **no hay voz ni gestos**, el disparador tiene que ser **visual**, y la
respuesta tiene que **caber en 4 líneas sin color**.

```
   Cámara de las gafas
        ↓  (captura puntual, NO stream continuo)
   Vision en el iPhone → VNDetectBarcodesRequest
        ↓
   URL del QR → LinkAnalyzer (cascada de 4 capas)
        ↓
   Agente LLM resume a ≤4 líneas sin color
        ↓
   display.send() → HUD 600×600
        ↓
   Button.onClick → el usuario pide más detalle
```

### Las cuatro decisiones que importan

**1. `capturePhoto` en vez de `stream`, por la térmica.**

```swift
camera.stream.capturePhoto(format: .jpeg)   // puntual
```

Tomar una foto cada N segundos para buscar QR consume una fracción de lo que consume
mantener el stream a 30 fps. Es lo que evita `thermalCritical` y salva batería. Si
necesitas stream, usa `StreamingResolution.low` y baja el `frameRate`.

**2. Vigilar `thermalLevel` y degradar solo.**

```swift
for await state in wearables.deviceStateStream(for: deviceId) {
    switch state.thermalLevel {
    case .light, .moderate: break                    // seguir
    case .severe:           reducirFrecuenciaDeCaptura()
    case .critical, .emergency, .shutdown:
                            pausarCamara()           // antes de que lo haga el firmware
    default: break
    }
}
```

Adelantarte al corte es la diferencia entre degradar con gracia y morir a media demo.

**3. El agente escribe para 600×600 monocromo.**

El prompt del agente tiene que llevar el límite adentro, no como sugerencia:

> *Responde en máximo 4 líneas de 28 caracteres. Sin color: comunica estado con
> `OK`, `!` o `X` al inicio de la línea. Sin markdown. Sin emojis. Primera línea:
> el veredicto. Nada de preámbulo.*

`LinkAnalysis.hudLines` ya produce exactamente esa forma — el agente puede tomarla
como plantilla en vez de inventar el formato.

**4. La interacción es por botón, no por voz.**

```swift
ButtonGroup {
    Button(label: "Detalle", iconName: .info) { mostrarSeñales() }
    Button(label: "Cerrar",  iconName: .close) { volverAlMenu() }
}
```

Es el único canal de entrada que el SDK te da. Úsalo.

### Presupuesto de latencia end-to-end

| Etapa | Costo | Nota |
|---|---|---|
| Captura de foto | ~300–600 ms | por Bluetooth/Wi-Fi |
| Detección de QR (Vision) | ~30–80 ms | on-device, barato |
| Análisis capas 0–2 | ~450 ms | ya medido contra verdana-loop |
| Llamada al agente LLM | **~800–2000 ms** | **el cuello de botella** |
| `display.send()` | ~100–200 ms | por Bluetooth |

**Total realista: 1.7 a 3.3 segundos.**

La cascada resuelve esto igual que en el analizador: **manda el primer `send()` con
el dominio antes de llamar al agente.** El usuario ve respuesta en ~700 ms y el
veredicto del agente llega después, sobre una pantalla que ya no está vacía.

---

## ⚠️ Riesgos para la demostración

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Corte térmico a media demo | **Alta** si usas stream | `capturePhoto` puntual + vigilar `thermalLevel` |
| Sesión muere al plegar las gafas | Alta | `hingesClosed`: mantenerlas puestas o tapar el sensor nasal |
| iOS 16 en el teléfono de prueba | Media | **Subir `deploymentTarget` a 17.2** |
| Latencia del LLM visible | Alta | Primer `send()` antes de llamar al agente |
| Wi-Fi del recinto bloquea UDP | **Alta en escuelas** | Hotspot propio; nada de VPN |
| Meta AI no autoriza el registro | Media | Ya mitigado con el watchdog de 90 s |

**La red de la escuela es el riesgo que más subestima la gente.** Las redes
institucionales suelen aislar clientes entre sí (client isolation), lo que rompe el
canal UDP/QUIC del que depende el streaming. Lleva tu propio hotspot.

---

## 🧪 Se puede probar sin gafas

El SDK trae `MWDATMockDevice.xcframework` y `MWDATMockDeviceTestClient.xcframework`.
Del CHANGELOG:

> *`MockCameraKit.setCameraFeed(cameraFacing:)` is now synchronous.*

Hay un simulador de dispositivo con feed de cámara falso. **Toda la Etapa 3 se puede
desarrollar y demostrar sin el hardware puesto**, lo que elimina el riesgo de que la
demo dependa de que las gafas conecten en vivo.

---

## 📋 Resumen: qué puede y qué no puede tu agente

| Capacidad | ¿Disponible? |
|---|---|
| Renderizar texto/botones/iconos en el HUD | ✅ Sí |
| Recibir toques en botones del HUD | ✅ Sí |
| Ver por la cámara (fotos o stream) | ✅ Sí, con techo térmico |
| Mostrar imágenes arbitrarias (color incluido) | ✅ Vía `UIImage` |
| Reproducir video en el HUD | ✅ Sí |
| **Escuchar por el micrófono de las gafas** | ❌ **No existe en el SDK** |
| **Recibir gestos de la Neural Band** | ❌ **No expuesto** |
| **Texto de color en el HUD** | ❌ Solo primary/secondary |
| **Leer batería de las gafas** | ❌ Solo `thermalLevel` |
| Funcionar en iOS 16 | ❌ Requiere 17.2 |

**La forma del producto que puedes construir:** un agente que **ve** y **muestra**,
donde el usuario responde **tocando**. No uno que escucha y conversa — ese sigue
siendo territorio exclusivo de Meta AI.
