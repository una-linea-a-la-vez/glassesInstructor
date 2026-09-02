# 🧪 Plan de Ejecución de Pruebas - GlassesInstructor

**Objetivo:** Identificar y documentar fallos, comportamientos inesperados y vulnerabilidades en un entorno controlado para presentación escolar.

---

## 📋 Requisitos de Laboratorio

### Hardware Mínimo
- Mac con Xcode 15+
- iPhone 13+ con iOS 16.0+
- Simulator de iOS (para pruebas iniciales)
- (Opcional) Meta Ray-Ban Display real

### Software
```bash
# Instalaciones requeridas
xcode-select --install
brew install xcodegen
brew install swiftformat
brew install swiftlint

# Para análisis de seguridad
brew install charles  # o mitmproxy
sudo pip install burpsuite-api
```

---

## 🏗️ Setup del Entorno de Pruebas

### 1. Preparar el Simulator

```bash
# Listar simuladores disponibles
xcrun simctl list devices

# Crear un nuevo simulator de pruebas
xcrun simctl create "iOS16-Test" com.apple.CoreSimulator.SimDeviceType.iPhone14 com.apple.CoreSimulator.SimRuntime.iOS-16-4

# Iniciar el simulator
xcrun simctl boot iOS16-Test
open -a Simulator

# Descargar la app de Meta View en el simulator
xcrun simctl install iOS16-Test ~/path/to/MetaView.app
```

### 2. Compilar GlassesInstructor

```bash
cd "/Users/chasse/PROYECTOS PERSONALES/LIFE OF CHASSE/PROGRAMMING/qa/glassesInstructor-qa"

# Generar proyecto Xcode desde project.yml
xcodegen generate

# Compilar para simulator
xcodebuild -scheme GlassesInstructor -destination 'generic/platform=iOS Simulator' build

# O abrir en Xcode
open GlassesInstructor.xcodeproj
```

### 3. Configurar Herramientas de Monitoreo

**Opción A: Xcode Instruments**
```bash
xcrun instruments -l  # Listar plantillas disponibles

# Luego en Xcode: Product > Profile
# Seleccionar: Memory, Energy Impact, System Trace
```

**Opción B: Terminal Monitoring**
```bash
# Monitorear logs en tiempo real
log stream --predicate 'process == "GlassesInstructor"' --level debug

# Monitorear uso de red
nettop -p <PID>

# Monitorear energía
powermetrics -n 1
```

---

## 🎯 Casos de Prueba Detallados

### TC-001: Validación de URL Callback

**Categoría:** Seguridad  
**Prioridad:** CRÍTICA  
**Duración:** 5 minutos

**Precondiciones:**
- Simulator iniciado
- GlassesInstructor compilada
- App abierta

**Pasos:**

```bash
# Paso 1: URL con esquema inválido
xcrun simctl openurl iOS16-Test "https://malicious.com/callback?token=fake"
# ✓ Esperado: App ignora la URL gracefully
# ✗ Actual: [Ejecutar y observar comportamiento]

# Paso 2: URL con caracteres especiales
xcrun simctl openurl iOS16-Test "metaglassesinstructor://'; DROP TABLE users; --"
# ✓ Esperado: Logger registra intento sospechoso, no procesa
# ✗ Actual: [Observar logs]

# Paso 3: URL excesivamente larga (DoS)
PAYLOAD=$(python3 -c "print('x' * 50000)")
xcrun simctl openurl iOS16-Test "metaglassesinstructor://callback?data=$PAYLOAD"
# ✓ Esperado: App rechaza sin lag
# ✗ Actual: [Monitorear CPU/memoria]

# Paso 4: URL con null bytes
xcrun simctl openurl iOS16-Test "metaglassesinstructor://callback%00injection"
# ✓ Esperado: Rechazada
# ✗ Actual: [Observar si causa crash]
```

**Resultado Esperado:**
```
✓ App rechaza URLs inválidas
✓ Logger registra eventos sospechosos
✓ No hay crash ni memoria excesiva
✓ Manejo de errores graceful
```

**Criterio de Aceptación:**
- [ ] Ninguna URL maliciosa causa crash
- [ ] Logger registra 4/4 intentos de inyección
- [ ] Tiempo de respuesta < 500ms

---

### TC-002: Ciclos de Conexión Repetitiva

**Categoría:** Estabilidad / Memory Management  
**Prioridad:** ALTA  
**Duración:** 10 minutos

**Precondiciones:**
- Xcode Instruments abierto con Memory profiler
- App abierta

**Pasos:**

```bash
# Ejecutar profiler
xcrun instruments -t "Memory" -D "/tmp/memory.trace" -l 60 \
  /path/to/GlassesInstructor.app

# Monitorear en paralelo
log stream --predicate 'process == "GlassesInstructor"' > /tmp/logs.txt &
```

**Procedimiento Manual en Simulator:**

```
Iteración 1-20:
  1. Tocar botón "Conectar Gafas"
  2. Esperar 5 segundos (simulando handshake)
  3. Observar estado -> "Conectadas"
  4. Tocar botón "Desconectar"
  5. Esperar 2 segundos
  6. Observar estado -> "Desconectadas"
  7. Captura de pantalla de Instruments después de iteración 10
  8. Captura de pantalla de Instruments después de iteración 20
```

**Métricas a Medir:**

```
Iteración | Memoria Inicial | Memoria Pico | Después de GC | Delta
----------|-----------------|--------------|---------------|---------
1         | 45 MB           | 60 MB        | 48 MB         | +3 MB
10        | 85 MB           | 100 MB       | 87 MB         | +2 MB  (aceptable)
20        | 150 MB          | 180 MB       | 155 MB        | +5 MB  (!!!)

✓ Criterio: Delta < 1MB entre iteraciones
✗ Actual: Delta crece (~2-5MB por iteración)
```

**Análisis de Logs:**

```bash
# Buscar leaks en los logs
grep "warning\|error" /tmp/logs.txt | wc -l

# Buscar acumulación de tokens
grep "ListenerToken" /tmp/logs.txt | wc -l
# ✗ Esperado: ~40 (2 por conexión)
# ✗ Actual: ~400 (acumulación)
```

**Resultado Esperado:**
```
✓ Memoria regresa a ~50MB después de cada ciclo
✓ Ningún warning en logs de Combine
✓ Tokens correctamente liberados
```

**Criterio de Aceptación:**
- [ ] Memoria después de GC permanece plana (±5MB)
- [ ] 0 errores no manejados en logs
- [ ] Tiempo de conexión consistente (5-10s)

---

### TC-003: Pérdida Abrupta de Conectividad

**Categoría:** Resilencia / Error Handling  
**Prioridad:** ALTA  
**Duración:** 8 minutos

**Setup:**

```bash
# Terminal 1: Monitorear logs
log stream --predicate 'process == "GlassesInstructor"' --level debug

# Terminal 2: Simular pérdida de WiFi
# (requiere acceso de admin a router o IP spoofing)
sudo ifconfig en0 down
```

**Procedimiento:**

```
1. App abierta, conectada a "gafas" (simuladas)
2. Iniciado streaming de cámara con video fluyendo
3. Terminal 2: sudo ifconfig en0 down (simular corte de WiFi)
4. Cronómetro: medir tiempo hasta que app detecte
5. Observar: ¿Reintentos automáticos? ¿Notificación al usuario?
6. Terminal 2: sudo ifconfig en0 up (restaurar WiFi)
7. Cronómetro: medir tiempo de reconexión automática
8. Validar: Stream se reanuda sin corrupción
```

**Cronómetro Esperado:**

```
Evento                           | Tiempo Esperado | Actual
---------------------------------|-----------------|----------
WiFi cortado detectado           | 2-3 segundos    | ???
Notificación al usuario          | 3-5 segundos    | ???
Primer reintento de conexión     | 10 segundos     | ???
Reconexión exitosa               | 15-20 segundos  | ???
Stream reanudado sin corrupción  | 20-25 segundos  | ???
```

**Validaciones:**

```bash
# En logs, buscar la secuencia esperada:
grep -n "connectionLost\|reconnecting\|success" /tmp/logs.txt

# ✓ Patrón correcto:
# [10s] connectionLost
# [15s] reconnecting
# [20s] reconnected: success

# ✗ Patrón incorrecto (timeout infinito):
# [10s] connectionLost
# [20s] reconnecting
# [30s] reconnecting
# [40s] reconnecting  <- ¡¡¡ Sin timeout !!!
```

**Resultado Esperado:**
```
✓ App detecta pérdida en < 5s
✓ Notificación clara al usuario
✓ Reintentos automáticos cada 10s (máximo 3)
✓ Timeout después de 30s, solicita acción manual
✓ Stream se reanuda sin corrupción de datos
```

**Criterio de Aceptación:**
- [ ] Detección de desconexión < 5s
- [ ] Máximo 3 reintentos automáticos
- [ ] Timeout después de 30s
- [ ] 0 crashes durante el proceso

---

### TC-004: Seguridad de Red (UDP Multicast)

**Categoría:** Seguridad / Privacidad  
**Prioridad:** MEDIA  
**Duración:** 6 minutos

**Setup:**

```bash
# Terminal: Capturar tráfico UDP
sudo tcpdump -i en0 -n 'udp port 5353' -X > /tmp/network_capture.txt

# Otra terminal: Ejecutar app
# (esto genera paquetes UDP multicast)
```

**Procedimiento:**

```
1. Terminal tcpdump corriendo
2. Abrir app GlassesInstructor
3. Tocar "Conectar Gafas"
4. Esperar 5 segundos
5. Cancelar tcpdump (Ctrl+C)
6. Analizar captura
```

**Análisis de Captura:**

```bash
# Ver qué se está enviando
cat /tmp/network_capture.txt | grep -A 5 "glasses_ping"

# Esperado: ✗ PROBLEMA DETECTADO
# ___________________________________________
# 192.168.1.100.52345 > 224.0.0.251.5353: UDP  12 bytes
#    glasses_ping
# ^^^^^^^^^^^^^^^
# ¡¡¡ Enviado EN CLARO sin encriptación !!!
```

**Análisis de Riesgo:**

```
Escenario de Ataque 1: Reconocimiento de Red
  Atacante: Conectado a la misma WiFi
  Acción:   Captura todos los "glasses_ping"
  Riesgo:   Enumera dispositivos Meta en la red
  Impacto:  Bajo (información no crítica)

Escenario de Ataque 2: Spoofing de Dispositivo
  Atacante: Envía falso "glasses_connected" vía UDP
  Acción:   App cree que hay gafas disponibles
  Riesgo:   La app intenta conectar a dispositivo falso
  Impacto:  Medio (denial of service)

Escenario de Ataque 3: Man-in-the-Middle
  Atacante: Posiciona ARP spoofing para interceptar
  Acción:   Modifica paquetes de streaming de video
  Riesgo:   Video corrupto o inyección de contenido
  Impacto:  Medio (integridad de datos)
```

**Mitigación Recomendada:**

```swift
// Usar mDNS con TLS en lugar de UDP crudo
// Implementar certificados autofirmados para validación local
// Añadir timestamp y firma HMAC a paquetes
```

**Resultado Esperado:**
```
✗ UDP multicast observable en clear (PROBLEMA CONFIRMADO)
✓ Logging de tráfico mostrado
✓ Recomendaciones de mitigación documentadas
```

**Criterio de Aceptación:**
- [ ] Captura de tráfico en claro documentada
- [ ] Análisis de riesgo completado
- [ ] Propuesta de mitigación creada

---

### TC-005: Rendimiento bajo Carga

**Categoría:** Rendimiento  
**Prioridad:** MEDIA  
**Duración:** 10 minutos

**Setup:**

```bash
# Herramienta: Xcode Instruments
# Instrumentos: Energy, CPU, Memory, Disk I/O, Network

# Iniciar profiling
xcrun instruments -t "System Trace" -D "/tmp/system.trace"
```

**Procedimiento:**

```
Fase 1: Idle (30 segundos)
  - App abierta, sin conexión
  - Medir: CPU, Batería, Memoria

Fase 2: Conexión (30 segundos)
  - Tocar "Conectar Gafas"
  - Medir: CPU pico, Batería, Memoria pico

Fase 3: Streaming Activo (60 segundos)
  - Streaming de cámara en tiempo real
  - Medir: CPU sostenido, FPS, Batería/hora, Memoria

Fase 4: Dictado (60 segundos)
  - Modo dictado activado
  - Hablar continuamente
  - Medir: CPU, Reconocimiento de voz, Latencia
```

**Métricas a Registrar:**

```
┌─────────────────────────────────────────────────────┐
│ IDLE                                                │
├─────────────────────────────────────────────────────┤
│ CPU:              0-2%                              │
│ Memoria:          45-50 MB                          │
│ Battery drain:    0.5%/hora (goal)                 │
│ FPS:              0 (app inactive)                  │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ DURANTE CONEXIÓN                                    │
├─────────────────────────────────────────────────────┤
│ CPU Pico:         25-35% (aceptable)               │
│ Memoria Pico:     80-100 MB                         │
│ Battery drain:    3-5%/hora (durante conexión)     │
│ Tiempo total:     10-15 segundos                    │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ DURANTE STREAMING ACTIVO                            │
├─────────────────────────────────────────────────────┤
│ CPU Sostenido:    15-25%                            │
│ Memoria:          120-150 MB (estable)              │
│ FPS:              30 (60fps goal para futuro)       │
│ Latencia:         < 100ms (end-to-end)              │
│ Battery drain:    15-20%/hora (expected)            │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ DURANTE DICTADO                                     │
├─────────────────────────────────────────────────────┤
│ CPU Sostenido:    20-30%                            │
│ Memoria:          100-120 MB                        │
│ Latencia de STT:  1-2 segundos                      │
│ Precisión:        ≥ 85%                             │
│ Battery drain:    10-12%/hora                       │
└─────────────────────────────────────────────────────┘
```

**Análisis de Resultados:**

```bash
# Ver reporte de Instruments
open /tmp/system.trace

# Buscar picos anómalos de CPU
grep "CPU" /tmp/system.trace | awk '{print $NF}' | sort -rn | head -5

# Identificar threads con alto uso
# En Instruments: View > Threads
```

**Resultado Esperado:**
```
✓ CPU sostenido < 30% durante streaming
✓ Memoria estable con GC periódico
✓ FPS ≥ 15 (sin drops visibles)
✓ Battery drain razonable (< 20%/hora)
```

**Criterio de Aceptación:**
- [ ] CPU Pico < 35% durante conexión
- [ ] CPU Sostenido < 25% durante streaming
- [ ] Memoria no crece indefinidamente
- [ ] FPS ≥ 15 sin drops visibles
- [ ] Battery drain < 20%/hora durante uso

---

## 🎬 Scripts de Automatización

### Script 1: Test Loop Automatizado (Bash)

```bash
#!/bin/bash
# test_connection_loop.sh - Automatizar ciclos de conexión

APP_IDENTIFIER="com.aaron.GlassesInstructor"
ITERATIONS=20
LOG_FILE="/tmp/test_loop.log"

echo "=== Connection Loop Test - $ITERATIONS iterations ===" > $LOG_FILE

for i in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $i/$ ITERATIONS ---" >> $LOG_FILE
    
    # Simulación: Tocar botón "Conectar"
    # (Esto requería UI automation o simulación en código)
    # xcrun simctl interact iOS16-Test touch 100 200
    
    sleep 5
    
    # Capturar memoria
    PID=$(pgrep -f "GlassesInstructor")
    if [ ! -z "$PID" ]; then
        MEMORY=$(ps aux | grep $PID | grep -v grep | awk '{print $6}')
        echo "Memory: ${MEMORY} KB" >> $LOG_FILE
    fi
    
    sleep 2
    
    # Simulación: Tocar botón "Desconectar"
    sleep 2
done

echo "\n=== Test Complete ===" >> $LOG_FILE
cat $LOG_FILE
```

**Uso:**

```bash
chmod +x test_connection_loop.sh
./test_connection_loop.sh
```

### Script 2: URL Injection Tester (Python)

```python
#!/usr/bin/env python3
# test_url_injection.py - Test malicious URLs

import subprocess
import sys

SIMULATOR_NAME = "iOS16-Test"
BUNDLE_ID = "com.aaron.GlassesInstructor"

test_cases = [
    {
        "name": "Valid URL",
        "url": "metaglassesinstructor://callback?token=valid",
        "expect_crash": False
    },
    {
        "name": "SQL Injection",
        "url": "metaglassesinstructor://callback?data='; DROP TABLE users; --",
        "expect_crash": False
    },
    {
        "name": "XSS Attempt",
        "url": "metaglassesinstructor://callback?data=<script>alert('xss')</script>",
        "expect_crash": False
    },
    {
        "name": "Buffer Overflow",
        "url": "metaglassesinstructor://callback?data=" + ("A" * 100000),
        "expect_crash": False
    },
    {
        "name": "Null Byte Injection",
        "url": "metaglassesinstructor://callback%00injection",
        "expect_crash": False
    }
]

for test in test_cases:
    print(f"\n[TEST] {test['name']}")
    print(f"  URL: {test['url'][:80]}...")
    
    try:
        cmd = f"xcrun simctl openurl {SIMULATOR_NAME} \"{test['url']}\""
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=5)
        
        # Check if app crashed
        ps_result = subprocess.run(
            f"xcrun simctl spawn {SIMULATOR_NAME} launchctl list | grep {BUNDLE_ID}",
            shell=True,
            capture_output=True
        )
        
        if ps_result.returncode == 0:
            print(f"  ✓ PASS: App still running (expected)")
        else:
            print(f"  ✗ FAIL: App crashed!")
            
    except subprocess.TimeoutExpired:
        print(f"  ✗ TIMEOUT: App unresponsive")

print("\n[Summary] All URL injection tests completed")
```

**Uso:**

```bash
python3 test_url_injection.py
```

---

## 📊 Registro de Resultados

Usar esta tabla para documentar cada prueba ejecutada:

```markdown
| Test ID | Nombre | Estado | Observaciones | Captura |
|---------|--------|--------|---------------|---------|
| TC-001  | URL Callback | ✓ PASS | Rechaza URL maliciosa | screenshot_001.png |
| TC-002  | Memory Loop | ✗ FAIL | Memory leak detectado en iteración 12 | memory_trace.trace |
| TC-003  | Conectividad | ✓ PASS | Reconecta en 18s | connection_log.txt |
| TC-004  | Network Security | ⚠️ INFO | UDP sin encriptación confirmado | pcap_capture.pcapng |
| TC-005  | Performance | ✓ PASS | CPU < 25%, FPS stable | instruments.trace |
```

---

## 🎓 Presentación Final

**Estructura de Presentación (15-20 minutos):**

```
1. Introducción (2 min)
   - Propósito: QA en ambiente controlado
   - Metodología: Pruebas automatizadas + manuales

2. Demostración 1: Inyección de URLs (3 min)
   - Mostrar código vulnerable
   - Ejecutar payload
   - Explicar impacto

3. Demostración 2: Memory Leaks (4 min)
   - Abrir Instruments
   - Ejecutar ciclos repetitivos
   - Gráfico de memoria creciente
   - Identificar dónde ocurre

4. Demostración 3: Seguridad de Red (3 min)
   - Mostrar captura tcpdump
   - Explicar tráfico en claro
   - Proponer mitigación

5. Demostración 4: Timeout de Sesión (3 min)
   - Simular desconexión
   - Mostrar reconexión infinita
   - Proponer solución con timer

6. Conclusiones (2 min)
   - Resumen de vulnerabilidades
   - Recomendaciones principales
   - Próximos pasos
```

