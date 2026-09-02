# 🔬 GlassesInstructor - QA & Security Testing Environment

**Propósito:** Ambiente controlado para identificar, documentar y demostrar vulnerabilidades y puntos débiles en un proyecto iOS real.

**Audiencia:** Estudiantes, desarrolladores, QA engineers  
**Contexto:** Presentación académica sobre "Quebrar Proyectos en Ambiente Controlado"

---

## 📂 Estructura del Repositorio QA

```
glassesInstructor-qa/
├── README_QA.md                          # ← Este archivo
├── QA_SECURITY_ANALYSIS.md              # Análisis detallado de vulnerabilidades
├── TESTING_EXECUTION_PLAN.md            # Plan de pruebas con procedimientos
├── VULNERABILITY_FIXES.md               # Ejemplos de código seguro
├── Source/                               # Código fuente original de la app
│   ├── GlassesInstructorApp.swift
│   ├── Managers/
│   │   ├── GlassesConnectionManager.swift
│   │   ├── HUDGridManager.swift
│   │   ├── CameraStreamManager.swift
│   │   ├── SpeechAudioManager.swift
│   │   └── DiagnosticLogger.swift
│   ├── Models/
│   ├── Views/
│   └── ...
├── project.yml                           # Configuración XcodeGen
├── GlassesInstructor.xcodeproj/         # Proyecto Xcode generado
├── Info.plist                            # Configuración de iOS
├── KNOWLEDGE_BASE.md                     # Base de conocimiento del proyecto
├── AI_AGENT_PLAYBOOK.md                  # Documentación de arquitectura
└── README.md                             # README original del proyecto
```

---

## 🚀 Inicio Rápido

### 1. Clonar / Preparar el Proyecto

```bash
cd "/Users/chasse/PROYECTOS PERSONALES/LIFE OF CHASSE/PROGRAMMING/qa/glassesInstructor-qa"

# Generar proyecto Xcode
xcodegen generate

# Verificar que se creó correctamente
ls -la GlassesInstructor.xcodeproj
```

### 2. Abrir en Xcode

```bash
open GlassesInstructor.xcodeproj
```

### 3. Compilar para Simulator

En Xcode:
1. Seleccionar dispositivo: iPhone 15 Simulator (o el disponible)
2. Pulsar ▶️ **Play** o presionar **Cmd+R**
3. Esperar compilación (2-3 minutos)

### 4. Explorar Documentación de QA

- **Para entender qué probar:** Lee `QA_SECURITY_ANALYSIS.md`
- **Para ejecutar pruebas:** Sigue `TESTING_EXECUTION_PLAN.md`
- **Para ver soluciones:** Consulta `VULNERABILITY_FIXES.md`

---

## 🎯 Objetivos de Aprendizaje

Al completar este lab, los estudiantes entenderán:

1. **Seguridad de URLs en iOS**
   - Cómo validar esquemas de URL
   - Riesgos de callbacks sin autenticación
   - Técnicas de certificate pinning

2. **Gestión de Memoria y Recursos**
   - Identificar memory leaks en Xcode
   - Usar Combine correctamente
   - Limpiar recursos en deinit

3. **Resiliencia de Red**
   - Implementar timeouts en conexiones
   - Reintentos exponenciales
   - Recuperación ante desconexiones

4. **Seguridad de Red**
   - UDP vs DTLS/TLS
   - Encriptación end-to-end
   - Captura de tráfico con tcpdump

5. **Testing y QA**
   - Pruebas manuales sistemáticas
   - Automatización de pruebas
   - Herramientas de profiling (Instruments)

---

## 📊 Vulnerabilidades Críticas Encontradas

| # | Nombre | Severidad | Estado | Doc |
|---|--------|-----------|--------|-----|
| 1 | URL Callback sin validación | 🔴 CRÍTICO | ⚠️ No Mitigado | QA_SECURITY_ANALYSIS.md #1 |
| 2 | Sin timeout de sesión | 🟠 ALTO | ⚠️ No Mitigado | QA_SECURITY_ANALYSIS.md #2 |
| 3 | Falta validación Bluetooth | 🟠 ALTO | ⚠️ No Mitigado | QA_SECURITY_ANALYSIS.md #3 |
| 4 | Inyección en telemetría | 🟡 MEDIO | ⚠️ No Mitigado | QA_SECURITY_ANALYSIS.md #4 |
| 5 | UDP sin encriptación | 🟡 MEDIO | ⚠️ No Mitigado | QA_SECURITY_ANALYSIS.md #5 |
| 6 | Memory leaks | 🟢 BAJO | 🔍 Investigar | QA_SECURITY_ANALYSIS.md #6 |

**Total:** 6 vulnerabilidades identificadas  
**Impacto:** De crítico a bajo  
**Solucionables:** Sí (ver VULNERABILITY_FIXES.md)

---

## 🧪 Pruebas Recomendadas por Nivel

### Nivel 1: Principiante (30 minutos)

```
✅ TC-001: Validación de URL Callback
   - Ejecutar URLs maliciosas en simulator
   - Observar si la app se rompe
   - Leer logs en Xcode Console

✅ TC-004: Seguridad de Red (UDP)
   - Capturar tráfico con tcpdump
   - Ver paquetes en claro
   - Entender riesgo de MITM
```

### Nivel 2: Intermedio (1 hora)

```
✅ TC-002: Ciclos de Conexión
   - Usar Xcode Instruments > Memory
   - Observar crecimiento de memoria
   - Identificar leak con debugger

✅ TC-003: Conectividad
   - Simular corte de WiFi
   - Ver cómo app responde
   - Cronometrar reconexión
```

### Nivel 3: Avanzado (2+ horas)

```
✅ TC-005: Rendimiento bajo Carga
   - Profiling completo con Instruments
   - CPU, Memory, Energy, Network
   - Optimización de hotspots

✅ Implementar Soluciones
   - Corregir vulnerabilidades del código
   - Ejecutar pruebas nuevamente
   - Confirmar mejoras
```

---

## 🛠️ Herramientas Necesarias

### Instaladas en el Sistema
```bash
# Xcode (obligatorio)
xcode-select --install

# XcodeGen (para generar proyecto)
brew install xcodegen

# Herramientas de red
brew install tcpdump
brew install Charles  # Proxy para capturar tráfico
```

### Nativas de Xcode
- **Instruments** (Product > Profile)
- **Debugger** (Xcode Console)
- **Network Link Conditioner** (simular latencia)

### Opcionales para Presentación
```bash
# Video capture
brew install ffmpeg

# Diagramas
brew install graphviz

# Análisis de código
brew install swiftlint
```

---

## 📝 Procedimiento para Ejecutar Prueba

### Ejemplo: TC-001 URL Callback Injection

**Duración:** 5 minutos  
**Complejidad:** Baja

#### Paso 1: Compilar

```bash
open GlassesInstructor.xcodeproj
# En Xcode: Cmd+B (Build)
# En Xcode: Cmd+R (Run)
```

#### Paso 2: Aplicar URL Maliciosa

Con el simulator corriendo, abrir Terminal:

```bash
# Obtener nombre del simulator
DEVICE_NAME="iPhone 15"

# Enviar URL maliciosa (SQL injection)
xcrun simctl openurl "$DEVICE_NAME" \
  "metaglassesinstructor://callback?data='; DROP TABLE users; --"
```

#### Paso 3: Observar Resultado

En Xcode Console, buscar:

```
✓ ESPERADO: "URL scheme inválido bloqueado"
✗ ACTUAL: (ver qué sucede realmente)
```

#### Paso 4: Documentar

Captura de pantalla del comportamiento:
```bash
# Tomar screenshot del simulator
xcrun simctl io "$DEVICE_NAME" screenshot /tmp/qa_test_001.png
open /tmp/qa_test_001.png
```

#### Paso 5: Reproducir en Presentación

```
[Demostración en vivo]
1. Mostrar código vulnerable
2. Ejecutar comando de prueba
3. Mostrar resultado en console
4. Explicar por qué es un problema
5. Mostrar solución en código
```

---

## 📊 Matriz de Selección de Pruebas

Elige pruebas según tu objetivo:

**Para Presentación General (15-20 min):**
- TC-001 (URL Injection) ✅
- TC-002 (Memory Leak) ✅
- TC-004 (Network Security) ✅
- TC-005 (Performance) ❓ (solo si hay tiempo)

**Para Laboratorio de Seguridad (2-3 horas):**
- TC-001 ✅
- TC-002 ✅
- TC-003 ✅
- TC-004 ✅
- TC-005 ✅

**Para Optimización (4+ horas):**
- Todas las pruebas ✅
- Implementar soluciones ✅
- Re-probar y medir mejoras ✅

---

## 📋 Checklist Pre-Presentación

- [ ] Proyecto compilado correctamente
- [ ] Simulator iniciado y funcional
- [ ] Xcode Console visible
- [ ] Instruments instalado y probado
- [ ] Comandos de prueba probados localmente
- [ ] Capturas de pantalla tomadas
- [ ] Notas de demostración preparadas
- [ ] Código de soluciones preparado
- [ ] Internet disponible (por si necesitas referencias)

---

## 🎓 Estructura de Presentación (20 minutos)

```
[0:00-2:00] Introducción
  - Qué es QA en ambiente controlado
  - Por qué es importante
  - Mapa de vulnerabilidades

[2:00-5:00] Demostración 1: Inyección de URLs
  - Mostrar código vulnerable
  - Ejecutar comando malicioso
  - Explicar impacto: acceso no autorizado

[5:00-9:00] Demostración 2: Memory Leaks
  - Abrir Instruments
  - Ejecutar ciclos de conexión
  - Gráfico muestra crecimiento indefinido
  - Explicar causa: tokens no liberados

[9:00-12:00] Demostración 3: Seguridad de Red
  - tcpdump captura UDP sin encriptación
  - Mostrar paquet en claro
  - Explicar riesgo: interception + spoofing

[12:00-15:00] Demostración 4: Timeout Infinito
  - Simular desconexión (poner gafas en estuche)
  - App intenta reconectar indefinidamente
  - Mostrar cómo esto consume batería
  - Explicar solución: timer con timeout

[15:00-18:00] Soluciones Propuestas
  - Mostrar código seguro para cada vulnerabilidad
  - Explicar cambios clave
  - Demostrar que funciona

[18:00-20:00] Preguntas & Conclusiones
  - Resumen ejecutivo
  - Impacto en producción
  - Próximos pasos
```

---

## 📚 Referencias Adicionales

### Dentro del Repo
- `KNOWLEDGE_BASE.md` - Base de conocimiento técnico del proyecto
- `AI_AGENT_PLAYBOOK.md` - Arquitectura y patrones de diseño
- `README.md` - Documentación original

### Externas (Recomendadas)
- [OWASP Top 10 Mobile](https://owasp.org/www-project-mobile-top-10/)
- [iOS Security Best Practices](https://developer.apple.com/security/)
- [SwiftUI Memory Management](https://www.hackingwithswift.com/forums/swiftui/swiftui-memory-management/59507)
- [Network Security in Swift](https://developer.apple.com/videos/play/wwdc2020/10110/)

---

## ❓ FAQ

**P: ¿Necesito las gafas Meta Ray-Ban Display reales?**  
R: No, el simulator es suficiente para todas las pruebas. Las gafas solo serían necesarias para pruebas de integración end-to-end.

**P: ¿Cuánto tiempo lleva hacer todas las pruebas?**  
R: Para una presentación: 20-30 minutos. Para un lab completo: 3-4 horas.

**P: ¿Puedo modificar el código para probar soluciones?**  
R: Sí, está diseñado para eso. Implementa las soluciones de `VULNERABILITY_FIXES.md` y re-prueba.

**P: ¿Cómo capturan las pruebas automatizadas?**  
R: Con scripts Bash y Python. Ver ejemplos en `TESTING_EXECUTION_PLAN.md > Scripts`.

**P: ¿Qué pasa si tengo errores de compilación?**  
R: Verifica `project.yml` tiene `DEVELOPMENT_TEAM` correcto. Ejecuta `xcodegen generate` nuevamente.

---

## 🔗 Links Rápidos

| Documento | Propósito | Audiencia |
|-----------|----------|-----------|
| [QA_SECURITY_ANALYSIS.md](./QA_SECURITY_ANALYSIS.md) | Análisis detallado de vulnerabilidades | Developers, QA |
| [TESTING_EXECUTION_PLAN.md](./TESTING_EXECUTION_PLAN.md) | Procedimientos de prueba paso a paso | QA Engineers, Testers |
| [VULNERABILITY_FIXES.md](./VULNERABILITY_FIXES.md) | Código seguro vs vulnerable | Developers |
| [KNOWLEDGE_BASE.md](./KNOWLEDGE_BASE.md) | Base de conocimiento técnico | Todos |
| [README.md](./README.md) | Documentación original del proyecto | Todos |

---

## 📝 Notas Finales

Este ambiente está diseñado para:
- **Educación:** Aprender cómo identificar vulnerabilidades reales
- **Demostrativo:** Mostrar impacto de mala seguridad/arquitectura
- **Práctico:** Reproducible sin hardware especial
- **Escalable:** Puedes añadir más pruebas y vulnerabilidades

**Última actualización:** 2026-09-01  
**Versión:** 1.0  
**Mantenedor:** Estudiante de Ciberseguridad

---

## 🎬 Quick Start Commands

```bash
# Setup completo (5 minutos)
cd "/Users/chasse/PROYECTOS PERSONALES/LIFE OF CHASSE/PROGRAMMING/qa/glassesInstructor-qa"
xcodegen generate
open GlassesInstructor.xcodeproj

# En Xcode:
# 1. Cmd+B (compilar)
# 2. Cmd+R (ejecutar)

# En Terminal (prueba TC-001):
DEVICE="iPhone 15"
xcrun simctl openurl "$DEVICE" "metaglassesinstructor://'; DROP TABLE users; --"

# Ver resultado en Xcode Console
```

¡Listo para iniciar! 🚀

