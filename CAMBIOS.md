# Cambios de la rama `truena-fepro`

Qué se agregó, por qué se agregó y qué problema concreto resuelve cada cosa.

Los diagnósticos de aquí salen de tres fuentes: los logs de ejecución en el
iPhone, la lectura del binario del SDK (`MWDAT 0.9.0`) y pruebas contra sitios
reales. Donde algo **no** está verificado en hardware, se dice.

---

## Índice

1. [Mascota](#1-mascota)
2. [Pantalla de bienvenida](#2-pantalla-de-bienvenida)
3. [Módulo "Entiende el proyecto"](#3-módulo-entiende-el-proyecto)
4. [Motor de análisis de enlaces](#4-motor-de-análisis-de-enlaces)
5. [Los tres bugs que impedían que la mascota hablara](#5-los-tres-bugs-que-impedían-que-la-mascota-hablara)
6. [Escaneo de QR](#6-escaneo-de-qr)
7. [Voz](#7-voz)
8. [Micrófono mudo](#8-micrófono-mudo)
9. [Cámara](#9-cámara)
10. [Conexión automática](#10-conexión-automática)
11. [Guard de desconexión](#11-guard-de-desconexión)
12. [Preguntas al agente](#12-preguntas-al-agente)
13. [Deployment target](#13-deployment-target)
14. [Qué falta por verificar](#qué-falta-por-verificar)

---

## 1. Mascota

**Archivos:** `Views/Phone/ShikiMascot.swift`, `Managers/MascotHUDRenderer.swift`

**Qué hace.** Un robot pixelado con cabeza-pantalla y `>_` en el pecho. Tiene
siete estados —`idle`, `greeting`, `scanning`, `thinking`, `talking`, `success`,
`error`— y cada uno cambia color, gesto y movimiento. En `scanning` los ojos
barren de lado a lado; en `greeting` saluda con la mano; en `talking` la boca
late con la voz.

**Por qué existe en dos versiones.** La del teléfono está hecha en SwiftUI con
celdas animables por separado. La del HUD se dibuja con Core Graphics en un
`UIImage` de 300×300, porque el waveguide necesita otra cosa: sin color, con
bordes duros y sin degradados, que se pierden en la óptica.

**Qué resuelve.** El HUD mostraba solo texto: números sueltos que había que
interpretar. La mascota convierte la auditoría en alguien que te explica algo.

**Detalle no obvio:** el cuerpo va en gris `0.78`, no en blanco puro. El
waveguide proyecta luz sobre lo que estás viendo y el blanco deslumbra. Ojos y
boca sí van más brillantes (`0.94`) porque son el punto de atención.

`AvatarHUDManager.usesPixelMascot = false` recupera el avatar de assets anterior
sin borrar nada.

---

## 2. Pantalla de bienvenida

**Archivos:** `Views/Phone/WelcomeView.swift`, modo `HUDMode.welcome`

**Qué hace.** La app abre con la mascota saludando y diciendo en voz alta:

> *"¡Hola! ¿Quieres entender un nuevo proyecto? Escanea su código o pégame su
> enlace, y te digo qué es, cómo está hecho y si vale la pena."*

El texto se escribe letra a letra al ritmo de la voz. Hay una sola acción
principal; el panel completo queda como opción secundaria.

**Qué resuelve.** Antes la app abría con una rejilla de seis botones que no
decía por dónde empezar. En las gafas pasaba lo mismo.

**Por qué el texto hablado es más largo que el escrito:** al oído da contexto sin
saturar una pantalla de 600×600.

---

## 3. Módulo "Entiende el proyecto"

**Archivo:** `Views/Phone/ScanStandView.swift` (antes "Escanear Stand")

**Qué hace.** Pantalla propia con la mascota como sujeto, visor con línea de
barrido, chips de estado (gafas / teléfono / segundos), campo para pegar el
enlace y selector de cámara **Automático / Gafas / Teléfono**.

**Qué resuelve.** El botón anterior **no abría ninguna pantalla**: cambiaba de
modo, arrancaba el escaneo en segundo plano y solo cambiaba el subtítulo de una
tarjeta. No había forma de ver el visor ni de saber si estaba funcionando.

**Por qué el selector de cámara es manual y no solo automático.** La elección
automática miraba `isStreaming`, así que con las gafas conectadas pero incapaces
de leer el código (mala luz, ángulo, stream a medias) no había forma de saltar al
teléfono sin desconectarlas. "Fallar" no es solo desconectarse.

A los 15 segundos sin detectar avisa que suele ser encuadre o luz, no un fallo
del código.

---

## 4. Motor de análisis de enlaces

**Archivos:** `Analysis/LinkAnalyzer.swift`, `Models/LinkAnalysis.swift`

**Qué hace.** Analiza una URL en cuatro capas y emite resultado parcial en cuanto
cada una termina, en vez de bloquear hasta el final:

| Capa | Coste | Qué entrega |
|---|---|---|
| 0 | 0 ms | Dominio (viene del propio QR, sin red) |
| 1 | ~200 ms | Headers de seguridad y framework |
| 2 | +20 ms | Identidad, reutilizando el HTML ya recibido |
| 3 | ~1 s | Artesanía: source maps, `prefers-reduced-motion`, tipografía |

**Por qué en cascada.** Las capas 1 y 2 comparten **una sola** petición de red, así
que la identidad sale casi gratis. La pantalla se llena con información real
mientras llega, en vez de con un spinner.

**Medición real contra `verdana-loop.vercel.app`:**

```
[    0ms] Detectado   verdana-loop.vercel.app
[  433ms] Seguridad   SEC 0/100
[  452ms] Identidad   VERDANA Loop
[  591ms] Artesanía   CRAFT 86/100
Segunda pasada (caché): 0ms
```

**Calibración** (para comprobar que discrimina y no reparte ceros):

| Sitio | Seguridad | Artesanía |
|---|---|---|
| github.com | 80/100 | 69/100 |
| verdana-loop.vercel.app | 0/100 | 86/100 |

El score de seguridad cuenta **solo** los headers que el dueño del sitio
controla. HSTS queda fuera a propósito: Vercel y Netlify lo inyectan solos y
premiarlo inflaría la nota sin mérito.

---

## 5. Los tres bugs que impedían que la mascota hablara

Tres fallos encadenados. Ninguno lanzaba error, por eso costaba verlos.

### 5.1 · El HUD descartaba los cuadros de la cara

```swift
func renderIfAgentMode() async {
    guard currentMode == .shikiAgent else { return }   // ← solo modo Shiki
    await renderCurrentState()
}
```

Cada cuadro de la mascota (boca al hablar, parpadeo) **se descartaba salvo en
modo Shiki**. Como la mascota vive también en bienvenida y auditoría, ahí quedaba
congelada en su primer cuadro: **el audio sonaba pero la boca no se movía**.

**Arreglo:** un conjunto `mascotModes` con los tres modos donde aparece.

### 5.2 · Entrar en auditoría silenciaba el veredicto

```swift
if mode != .shikiAgent {
    avatarManager.stopAll()      // ← mataba la voz
}
```

`handleModeSwitch` callaba la voz en cualquier modo distinto de Shiki. Entrar en
la auditoría silenciaba justo el veredicto que estaba a punto de decirse.

**Arreglo:** la voz solo se corta al ir a un modo sin mascota.

### 5.3 · Dos rutas competían por el mismo QR

El callback del manager disparaba la auditoría automática, y a la vez
`ScanStandView` reaccionaba por su cuenta al mismo código. **El mismo escaneo
lanzaba dos flujos que se pisaban.**

**Arreglo:** mientras la vista está abierta toma el control de ambos
manejadores y los devuelve al cerrarse.

---

## 6. Escaneo de QR

### 6.1 · Detecciones en paralelo saturándose

```swift
self.isDecodingFrame = false     // ← el candado se soltaba ANTES de detectar
...
let payload = await Task.detached { Self.detectQRCode(in: image) }.value
```

A 30 fps se lanzaban **decenas de detecciones Vision en paralelo**. Se saturaban
entre sí, ninguna convergía y de paso calentaban el equipo.

**Arreglo:** candado propio del detector y techo de **4 inspecciones por
segundo**. Suficiente para sentirse inmediato sin castigar CPU ni térmica.

### 6.2 · CIDetector → Vision

`CIDetector` solo acierta con el código quieto y de frente: mal negocio para una
cámara montada en la cabeza, que da frames movidos y en ángulo. Ahora usa
`VNDetectBarcodesRequest`, con CIDetector como respaldo para frames muy
contrastados.

### 6.3 · Resolución

`.medium@24fps` → **`.high@15fps`**. Un QR necesita píxeles, no cuadros: a media
resolución los módulos del código se funden. Bajar el frameRate compensa el
bitrate, así que el enlace aguanta igual.

### 6.4 · El cambio de modo apagaba el escaneo

```swift
if mode != .shikiAgent { cameraManager.stopQRScanning() }
case .projectAudit:    cameraManager.stopStream()
```

Entrar al modo de escaneo **apagaba el escaneo que se acababa de pedir**. Sin
stream no hay frames; sin frames no hay QR. Ahora un escaneo en curso sobrevive
al cambio de modo.

### 6.5 · Respaldo con la cámara del teléfono

**Archivo:** `Analysis/PhoneQRSession.swift`

Usa `AVCaptureMetadataOutput`, que detecta QR por hardware: más barato que Vision
por frame y sin coste térmico.

**Por qué existe.** El escaneo dependía de `camera != nil`, así que sin gafas
conectadas no se podía escanear nada. En una demostración en vivo eso significa
quedarse sin nada que mostrar cuando la conexión falla.

Dos detalles que suelen romper este código y quedan resueltos:

- `setMetadataObjectsDelegate` va **después** de `addOutput`; antes,
  `availableMetadataObjectTypes` viene vacío y el filtro `.qr` no se aplica.
- La capa de vista previa se reposiciona en `layoutSubviews`; sin eso queda con
  tamaño cero y se ve negra.

La normalización de payloads (`QRScanner.navigableURL`) está verificada con
**11 casos, 11 correctos**: acepta dominios sin esquema, recorta espacios y
rechaza `mailto:`, `tel:` y `WIFI:`.

---

## 7. Voz

| Problema | Causa | Arreglo |
|---|---|---|
| Sonaba lenta | `rate = 0.48`, por debajo del default de iOS (0.5) | `0.53`, conversacional en español |
| Se comía la primera sílaba | Por Bluetooth la ruta tarda en abrir | `preUtteranceDelay = 0.15` |
| La boca no iba con la voz | La movía un `Timer` fijo a 5,5 fps, desacoplado del habla | La mueve `willSpeakRangeOfSpeechString` |
| Aviso `unsafeForcedSync` | `speechVoices()` es cara y síncrona, y se llamaba en cada frase | Cacheada en `static let` |

**Sobre la sincronía:** el sintetizador avisa antes de pronunciar cada fragmento.
Esa es la señal que mueve la boca ahora. Se conserva un techo de tasa para no
saturar el canal Bluetooth, que es la razón original del temporizador.

**Conflicto TTS / micrófono.** Compartían `AVAudioSession`; reconfigurar la
categoría con el motor de audio corriendo invalidaba el tap del micrófono. El
avatar ahora detiene el dictado antes de hablar y lo reanuda al terminar.

---

## 8. Micrófono mudo

**Archivo:** `Managers/SpeechAudioManager.swift`

**El síntoma:** el dictado no transcribía nada y en los logs aparecía

```
AVAudioBuffer.mm:281  mBuffers[0].mDataByteSize (0) should be non-zero
```

**La causa:**

```swift
let recordingFormat = inputNode.outputFormat(forBus: 0)
```

Se leía el formato **inmediatamente después** de `setActive(true)`, cuando el
nodo de entrada todavía devuelve sample rate 0. El tap instalado con ese formato
entrega buffers vacíos: el reconocedor recibe silencio y **el micrófono queda
mudo sin lanzar ningún error**.

**El arreglo,** en tres partes:

1. `inputFormat` en vez de `outputFormat` (es el formato real del micrófono).
2. Detener y resetear el motor antes de reconfigurar la sesión.
3. Si el nodo devuelve un formato inválido, caer a uno válido del hardware.

---

## 9. Cámara

**Archivo:** `Managers/CameraStreamManager.swift`

### 9.1 · El hardware nunca se liberaba

```swift
func detachCamera() {
    stopStream()
    camera = nil        // ← soltaba la referencia SIN liberar el hardware
}
```

El SDK dice que `Camera` **es dueña del recurso de hardware** y que `stop()` lo
libera. Al no llamarlo, el firmware lo mantenía tomado y el siguiente
`addCamera()` fallaba. **Ésta era la razón de que la cámara fallara más en el
segundo intento que en el primero.**

### 9.2 · El resto

| Problema | Arreglo |
|---|---|
| `stopStream()` tenía `guard isStreaming` que impedía detenerlo si la bandera se desincronizaba | Guard eliminado |
| `isStreaming = true` justo tras `start()`, que es asíncrono: la UI decía "Transmitiendo" sin frames | La bandera la pone `statePublisher` |
| `statePublisher` solo escribía al log | Es ahora la fuente de verdad del estado |
| Los errores no bajaban la bandera | `handleStreamError` la sincroniza |
| Errores crípticos | Mensajes accionables por caso |

**Mensajes por error:** `hingesClosed` → *"Las gafas están plegadas. Ábrelas y
póntelas"*; `timeout` → *"Revisa que estén en el mismo Wi-Fi, sin VPN"*;
`batteryCritical`, `thermalCritical`, `peakPowerShutdown` con su causa real.

---

## 10. Conexión automática

**Qué hace.** La app intenta enlazar sola al abrirse. Mientras lo intenta muestra
*"Enlazando con tus gafas…"* sin pedir nada. Si a los **10 segundos** no lo
consigue, aparece el botón manual.

**Detalle:** el intento sigue vivo después del plazo. Si conecta más tarde por su
cuenta, el botón desaparece solo. El plazo solo destapa la alternativa, no
cancela nada.

---

## 11. Guard de desconexión

**Archivos:** `Views/Phone/GlassesOfflineOverlay.swift`, `GlassesConnectionManager`

**Qué hace.** Al perder el enlace apaga en orden lo que depende del hardware
—escáner de gafas, cámara, HUD, micrófono, sesión— y muestra un aviso con el
motivo concreto y dos salidas: reconectar, o seguir con el teléfono.

**Qué NO apaga:** `PhoneQRSession`. Usa la cámara del teléfono y sigue siendo
válida sin gafas; pararla dejaría al usuario sin forma de escanear justo cuando
más la necesita.

**Vigilancia térmica.** `deviceStateStream` entrega el nivel térmico. En `.severe`
detiene el escaneo; en `.critical` corta y avisa **antes que el firmware**, para
que no parezca que la app se rompió cuando en realidad son las gafas
protegiéndose.

**Desconexión intencional vs. caída.** `session.stop()` hace que el SDK emita
`.stopped` de forma asíncrona. Sin distinguirlo, salía "gafas sin conexión"
cuando era el usuario quien había pulsado desconectar. Ahora el estado baja antes
del teardown y una bandera cubre la ventana del callback.

---

## 12. Preguntas al agente

**Qué hace.** Tras la auditoría aparece **"❓ Preguntar"** en el HUD. La mascota
propone en voz alta qué se le puede preguntar, anclado a lo que encontró:

> *"Puedes preguntarme por qué le faltan los headers de seguridad, o qué señales
> me hacen pensar que está bien hecho, o si vale la pena como proyecto."*

Y deja el micrófono abierto.

**Por qué sugiere en vez de solo escuchar.** Frente a un micrófono vacío nadie
sabe qué decir. Las sugerencias salen del análisis real, no de una lista fija:
preguntar en abstracto no lleva a ningún lado, pero *"¿por qué le faltan
headers?"* sí.

---

## 13. Deployment target

`project.yml` declaraba iOS **16.0**, pero el SDK declara `MinimumOSVersion`
**17.2** (target triple `arm64-apple-ios17.2`, confirmado en el CHANGELOG de
MWDAT 0.9.0). El proyecto compilaba, pero **la app no arrancaría en un iPhone con
iOS 16.x**.

---

## Qué falta por verificar

Todo lo anterior compila (`xcodebuild -destination 'generic/platform=iOS
Simulator'` → `BUILD SUCCEEDED`) y lo que se pudo probar contra sitios reales
está medido. **Falta probar en las gafas:**

| Qué probar | Qué debería pasar |
|---|---|
| Escanear un QR con las gafas | Detecta (§6.1–6.4 atacan las causas probables) |
| La mascota durante la auditoría | La boca se mueve mientras habla (§5.1) |
| Escuchar el veredicto completo | No se corta al entrar en auditoría (§5.2) |
| Escanear con la vista abierta | La auditoría arranca **una** vez (§5.3) |
| Dictar sin gafas | Transcribe, sin `mDataByteSize (0)` en el log |
| Conectar → desconectar → conectar | Funciona al segundo intento (§9.1) |
| Pulsar Desconectar | **No** sale el aviso de sin conexión (§11) |

Si el QR con gafas sigue fallando, el contador `qrFramesInspected` dice cuántos
frames llegó a inspeccionar: si sube y aun así no detecta, el problema es óptico
(distancia o tamaño del código), no de software.

---

## Límites del SDK que condicionan el diseño

Verificado leyendo el binario de MWDAT 0.9.0, no la documentación:

- **No hay micrófono de las gafas.** `Permission` tiene un único caso: `.camera`.
  El dictado usa el micrófono del iPhone. Ese canal es de Meta AI.
- **No hay acceso a la Meta Neural Band.** Los gestos de muñeca no están
  expuestos.
- **El HUD no tiene color.** `TextColor` solo expone `.primary` y `.secondary`;
  un semáforo rojo/verde es imposible. Escape: `Image(UIImage)` acepta cualquier
  imagen renderizada, que es como se dibuja la mascota.
- **Telemetría mínima.** `DeviceState` solo expone `thermalLevel`. No hay
  batería (aunque `StreamError.batteryCritical` sirve de señal indirecta).
- **`MWDATMockDevice.xcframework`** permite desarrollar y demostrar sin hardware.

Esto define la forma del producto: un agente que **ve** y **muestra**, donde el
usuario responde **tocando** (`Button.onClick` y `FlexBox.onTap` sí funcionan).
No uno que escucha y conversa por las gafas.
