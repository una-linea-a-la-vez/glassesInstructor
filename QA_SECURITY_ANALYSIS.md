# 🔍 Análisis de QA & Seguridad - GlassesInstructor

**Última actualización:** 2026-09-01  
**Versión de App:** 1.0.0 (Initial Release)  
**Plataforma:** iOS 16.0+  
**Hardware:** Meta Ray-Ban Display (Wearables DAT SDK 0.9.0+)

---

## 📋 Resumen Ejecutivo

GlassesInstructor es una aplicación iOS demostrativa para Meta Ray-Ban Display que cubre tres canales principales:
1. **Display (HUD):** Renderizado de matriz 2x2 en 600x600px
2. **Camera:** Streaming de video frontal en tiempo real
3. **Microphone:** Dictado en vivo con transcripción

Este documento analiza vectores de ataque, puntos débiles y escenarios de prueba críticos para identificar fallos, degradación de rendimiento y comportamientos inesperados.

---

## 🚨 Vulnerabilidades Identificadas

### 1. **Manejo Inseguro de URLs Callback (CRÍTICO)**

**Ubicación:** `GlassesInstructorApp.swift:10-19`

**Problema:**
```swift
.onOpenURL { url in
    Task {
        _ = try await Wearables.shared.handleUrl(url)
        // ⚠️ No valida el esquema ni el origen de la URL
    }
}
```

**Riesgo:**
- Una aplicación maliciosa podría invocar esquema `metaglassesinstructor://` con payload arbitrario
- Posible inyección de comandos o tokens de sesión falsos
- No hay validación de certificados SSL/TLS en la URL

**Prueba de Explotación:**
```bash
# Desde otra app o mediante simulador
xcrun simctl openurl booted "metaglassesinstructor://malicious?token=fake&cmd=reset"
```

**Recomendación:**
```swift
.onOpenURL { url in
    guard url.scheme == "metaglassesinstructor",
          let host = url.host,
          host.isEmpty else {
        logger.log(.error, tag: "Security", message: "URL scheme inválido bloqueado: \(url)")
        return
    }
    // Validar componentes antes de pasar al SDK
}
```

---

### 2. **Ausencia de Validación de Permisos Bluetooth (ALTO)**

**Ubicación:** `GlassesConnectionManager.swift:94-100`

**Problema:**
- No hay verificación de estado `CBCentralManagerState` antes de iniciar conexión
- El SDK puede ser inicializado sin que Bluetooth esté habilitado
- Error genérico `API MISUSE: CBCentralManager` en logs

**Prueba:**
1. Apagar Bluetooth en ajustes del iPhone
2. Tocar "Conectar" en la app
3. Observar estado de la conexión (debería fallar gracefully)

**Resultado Esperado vs Actual:**
```
ESPERADO: "Bluetooth está deshabilitado. Actívalo en Ajustes."
ACTUAL: Desconexión silenciosa + error críptico en logs
```

**Recomendación:**
```swift
func checkBluetoothStatus() -> Bool {
    let manager = CBCentralManager()
    return manager.state == .poweredOn
}
```

---

### 3. **Gestión de Sesiones Sin Timeout (ALTO)**

**Ubicación:** `GlassesConnectionManager.swift:27`

**Problema:**
- La `DeviceSession` no tiene timeout explícito
- Si la conexión se pierde, la app puede quedar en estado colgado
- Consumo de batería indefinido

**Escenario Crítico:**
1. Conectar a gafas exitosamente
2. Ponerlas en estuche (desconexión física)
3. Observar que la app intenta reconectar infinitamente sin límite

**Prueba de Resistencia:**
```
⏱️ Tiempo máximo esperado de reconexión: 30s
⏱️ Tiempo actual observado: Indefinido
```

**Recomendación:**
```swift
let SESSION_TIMEOUT: TimeInterval = 30
Timer.scheduledTimer(withTimeInterval: SESSION_TIMEOUT, repeats: false) { [weak self] _ in
    if self?.connectionState == .connecting {
        self?.handleTimeout()
    }
}
```

---

### 4. **Inyección de Comandos en Telemetría (MEDIO)**

**Ubicación:** `DiagnosticLogger.swift` (inferred)

**Problema:**
- Los logs se escriben sin sanitización
- Si se sincroniza con servidor remoto, podría permitir inyección de comandos

**Prueba:**
```swift
logger.log(.info, tag: "Test", message: "'); DROP TABLE logs; --")
```

**Riesgo de Escalación:**
Si la telemetría se envía a un backend:
```
POST /api/telemetry
{
    "message": "'); DROP TABLE logs; --"
}
```

---

### 5. **Falta de Encriptación en Red Local (MEDIO)**

**Ubicación:** `GlassesConnectionManager.swift:82-90` (UDP broadcast sin protección)

**Problema:**
```swift
let connection = NWConnection(host: "224.0.0.251", port: 5353, using: .udp)
connection.send(content: "glasses_ping".data(using: .utf8), ...)
```

- UDP multicast en red local sin protección
- Un atacante en la misma red Wi-Fi podría:
  - Capturar pings y aprender sobre dispositivos conectados
  - Enviar paquetes falsos usando ARP spoofing

**Prueba:**
```bash
# En la misma red Wi-Fi
sudo tcpdump -i en0 'udp port 5353'
# Verá: 224.0.0.251:5353 <- "glasses_ping"
```

**Mitigación:**
```swift
// Implementar mDNS con TLS
// Usar certificados de cliente para validar identidad
```

---

### 6. **Gestión de Memoria sin Límites (BAJO)**

**Ubicación:** Todos los managers

**Problema:**
- Los `@Published` properties acumulan observadores sin límite
- Si la app se abre/cierra múltiples veces, podría haber memory leak
- Los tokens de conexión no se limpian explícitamente

**Prueba de Stress:**
```bash
# Simular 50 conexiones y desconexiones rápidas
for i in {1..50}; do
    # Tocar conectar
    # Esperar 0.5s
    # Tocar desconectar
done
# Monitorear Memory en Xcode Instruments
```

**Esperado:** Memoria stable ~50MB  
**Riesgo:** Crescimento a 200-400MB

---

## 🧪 Plan de Pruebas de QA

### Pruebas Funcionales Críticas

#### 1. Ciclo de Conexión Completo
```
[ ] 1. App inicia sin gafas (debe mostrar "Desconectadas")
[ ] 2. Tocar "Conectar"
[ ] 3. Ingresar a Meta View para registrar gafas
[ ] 4. Volver a la app con callback URL
[ ] 5. HUD muestra matriz 2x2
[ ] 6. Cada botón es táctil y funciona
```

#### 2. Streaming de Cámara
```
[ ] 1. Seleccionar modo "Cámara Frontal"
[ ] 2. En iPhone: ver feed de cámara de gafas
[ ] 3. En HUD: ver representación en tiempo real
[ ] 4. FPS debe ser ≥ 15 (sin lag visible)
[ ] 5. Desconectar gafas: video debe pausarse gracefully
```

#### 3. Dictado de Voz
```
[ ] 1. Activar modo "Micrófono & Dictado"
[ ] 2. Hablar claramente: "Hola mundo"
[ ] 3. Transcripción debe aparecer en 2s
[ ] 4. Subtítulos en HUD visibles
[ ] 5. Precisión de transcripción ≥ 85%
```

#### 4. Diagnóstico de Hardware
```
[ ] 1. Estado Bluetooth: debe mostrar "Conectado"
[ ] 2. Batería de gafas: debe mostrar nivel real
[ ] 3. Señal Wi-Fi: debe mostrar SSID actual
[ ] 4. Latencia de sesión: debe ser < 100ms
```

---

### Pruebas de Estrés & Resistencia

#### 1. Ciclos Repetitivos de Conexión
**Objetivo:** Detectar memory leaks y estado inconsistente

```
Procedimiento:
1. Conectar a gafas ✓
2. Esperar 10s
3. Desconectar (poner gafas en estuche)
4. Esperar 10s
5. Conectar nuevamente
6. Repetir 20 veces

Métricas:
- Memoria: debe volver a ~50MB después de cada ciclo
- Tiempo de conexión: debe ser consistente (~5-10s)
- Errores en logs: debe haber 0 excepciones no manejadas
```

#### 2. Pérdida Abrupta de Conectividad
**Objetivo:** Validar recuperación ante desconexión inesperada

```
Procedimiento:
1. Conectar a gafas en WiFi
2. Iniciar streaming de cámara
3. Desactivar WiFi en router (simular desconexión)
4. Esperar 30s
5. Reactivar WiFi
6. Validar reconexión automática

Esperado:
- App notifica "Conexión perdida" en 2-3s
- Reconecta automáticamente
- No hay corrupción de datos
```

#### 3. Exceso de Demanda de Recursos
**Objetivo:** Verificar que la app maneja contención de recursos

```
Procedimiento:
1. Abrir app en fondo
2. Reproducir video HD en otra app (YouTube)
3. Descargar archivo grande en background
4. Retornar a GlassesInstructor
5. Intentar reconectar

Esperado:
- App responde sin lag
- Conexión se recupera
- No hay crash
```

---

### Pruebas de Seguridad

#### 1. Validación de URLs Maliciosas
```
Prueba 1: URL sin esquema válido
xcrun simctl openurl booted "https://malicious.com/callback"

Prueba 2: Inyección de parámetros
xcrun simctl openurl booted "metaglassesinstructor://hack?token=<script>alert('xss')</script>"

Prueba 3: URL muy larga
xcrun simctl openurl booted "metaglassesinstructor://$(python3 -c 'print("x"*10000)')"

Esperado:
- App rechaza todas estas URLs gracefully
- No hay crash ni error críptico
- Logger registra intentos sospechosos
```

#### 2. Captura de Datos en Red
```
Procedimiento:
1. Conectar iPhone a Proxy (Charles/Burp Suite)
2. Iniciar sesión con gafas
3. Monitorear tráfico de red

Buscar:
- ¿Se envían tokens sin encriptación?
- ¿Se revelan identidades de dispositivos?
- ¿Hay comunicación no autorizada?
```

#### 3. Persistencia de Credenciales
```
Procedimiento:
1. Conectar a gafas exitosamente
2. Navegar a Ajustes > Privacidad > Bluetooth
3. Olvidar dispositivo
4. Retornar a app
5. Intentar conectar nuevamente

Esperado:
- No se almacena token en Keychain sin encriptación
- No hay reemplazo automático de credenciales
```

---

## 📊 Matriz de Riesgos

| Vulnerabilidad | Severidad | Probabilidad | Impacto | Estado |
|---|---|---|---|---|
| URL Callback sin validación | CRÍTICO | MEDIA | ALTA | ⚠️ No Mitigado |
| Ausencia de validación Bluetooth | ALTO | ALTA | MEDIA | ⚠️ No Mitigado |
| Gestión de sesiones sin timeout | ALTO | MEDIA | ALTA | ⚠️ No Mitigado |
| Inyección en telemetría | MEDIO | BAJA | MEDIA | ⚠️ No Mitigado |
| UDP multicast sin encriptación | MEDIO | MEDIA | BAJA | ⚠️ No Mitigado |
| Memory leak en ciclos de conexión | BAJO | MEDIA | BAJA | 🔍 Investigar |

---

## 🎯 Escenarios de Prueba para Presentación Escolar

### Demostración 1: "Quebrar la Seguridad de URLs"
**Duración:** 3 minutos

```
Paso 1: Mostrar código vulnerable en GlassesInstructorApp.swift
Paso 2: Ejecutar comando malicioso simulado
Paso 3: Demostrar que la app no valida origen
Paso 4: Mostrar solución recomendada en código
```

### Demostración 2: "Detectar Memory Leaks bajo Estrés"
**Duración:** 5 minutos

```
Paso 1: Abrir Xcode Instruments > Memory
Paso 2: Conectar/desconectar 10 veces rápidamente
Paso 3: Mostrar gráfico de memoria que no baja
Paso 4: Explicar por qué ocurre (tokens no liberados)
Paso 5: Demostrar con debugger dónde está el leak
```

### Demostración 3: "Capturar Datos en Red sin Encriptación"
**Duración:** 4 minutos

```
Paso 1: Abrir Charles Proxy / tcpdump
Paso 2: Conectar app a gafas
Paso 3: Ver paquetes UDP sin protección
Paso 4: Mostrar que un atacante podría:
       - Bloquear mensajes
       - Inyectar comandos falsos
       - Descubrir estructura de red
```

### Demostración 4: "Timeout Infinito de Sesión"
**Duración:** 3 minutos

```
Paso 1: Conectar a gafas normalmente
Paso 2: Poner gafas en estuche (simular desconexión)
Paso 3: Mostrar app intentando reconectar indefinidamente
Paso 4: Abrirr Xcode Debugger y mostrar bucle infinito
Paso 5: Proponer solución (timer con timeout)
```

---

## ✅ Checklist de QA Pre-Producción

### Seguridad
- [ ] Validar todos los esquemas de URL
- [ ] Implementar encriptación en red local
- [ ] Usar Keychain para almacenamiento seguro
- [ ] Sanitizar todos los logs antes de sincronizar
- [ ] Implementar rate limiting en conexiones

### Rendimiento
- [ ] Profiling de memoria bajo ciclos repetitivos
- [ ] Latencia de streaming < 100ms
- [ ] CPU < 30% en modo idle
- [ ] Batería: consumo < 5% por hora
- [ ] Frame rate ≥ 15 FPS en video

### Estabilidad
- [ ] 0 crashes en 100 ciclos conexión/desconexión
- [ ] Recuperación automática ante pérdida de WiFi
- [ ] Manejo correcto de permisos denegados
- [ ] Comportamiento correcto con Bluetooth apagado
- [ ] Limpieza de recursos al cerrar app

### Compatibilidad
- [ ] iOS 16.0 (mínimo)
- [ ] iPhone 12/13/14/15 series
- [ ] Meta Ray-Ban Display (firmware actual)
- [ ] WiFi 2.4GHz y 5GHz

---

## 📝 Notas de Implementador

Este documento está diseñado para:
1. **QA Engineers:** Guía de pruebas manuales y automatizadas
2. **Desarrolladores:** Mapa de vulnerabilidades a corregir
3. **Security Researchers:** Base para auditoría de seguridad
4. **Estudiantes (Presentación):** Ejemplos reales de debilidades en apps

Todos los escenarios descritos son **reproducibles en un ambiente controlado** sin necesidad de dispositivos Meta Ray-Ban reales (pueden simularse en el Xcode simulator).

