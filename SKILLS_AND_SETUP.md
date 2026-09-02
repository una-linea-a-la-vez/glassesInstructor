# 🛠️ Skills Disponibles y Setup Adicional

**Contexto:** Este documento describe las skills (herramientas y automatizaciones) disponibles en gstack y cómo usarlas en el contexto del proyecto GlassesInstructor QA.

---

## 📋 Skills Disponibles (gstack)

Tu máquina tiene instalado [gstack](https://github.com/garrytan/gstack) en `~/.claude/skills/gstack` con las siguientes skills:

### 🔍 Skills Útiles para Este Proyecto

#### `/browse` - Web Browsing
**Uso:** Buscar información en internet sobre vulnerabilidades o mejores prácticas.

```bash
/browse "iOS security best practices for URL callbacks"
/browse "OWASP Mobile Top 10 2024"
```

#### `/plan-ceo-review` / `/plan-eng-review`
**Uso:** Generar planes de revisión de código.

```bash
# Ejemplo: Revisar cambios de seguridad
/plan-eng-review
# Esto genera un plan para revisar cambios en GlassesConnectionManager
```

#### `/review` - Code Review
**Uso:** Revisar código buscando vulnerabilidades.

```bash
# Desde el directorio del proyecto
/review Source/GlassesInstructorApp.swift
# Busca: URL handling vulnerabilities
```

#### `/ship` / `/land-and-deploy`
**Uso:** Para cuando la app esté lista para producción (no aplica ahora).

#### `/investigate` - Investigación
**Uso:** Investigar problemas específicos.

```bash
/investigate "Why memory leaks happen with Combine listeners"
```

#### `/qa` y `/qa-only`
**Uso:** Ejecutar QA automation (relevante para este proyecto).

```bash
/qa
# Ejecutaría pruebas automatizadas del proyecto
```

#### `/document-release` - Documentación de Release
**Uso:** Generar documentación para una versión.

```bash
/document-release "v1.0.0 - Security Hardening"
```

### 🎯 Skills para Setup y Configuración

#### `/setup-browser-cookies`
**Uso:** Configurar cookies para navegación.

#### `/gstack-upgrade`
**Uso:** Actualizar gstack a la última versión.

```bash
~/.claude/skills/gstack/gstack-upgrade
```

---

## 🔧 Configuración del Proyecto

### 1. Xcode & Swift Setup

```bash
# Verificar versión de Xcode
xcode-select --print-path
# Debe ser: /Applications/Xcode.app/Contents/Developer

# Verificar versión de Swift
swift --version
# Debe ser: swift-driver version 1.87.1
# Apple Swift version 5.9 o mayor

# Actualizar command line tools si es necesario
xcode-select --install
```

### 2. Instalar Dependencias

```bash
# XcodeGen (para generar proyecto desde YAML)
brew install xcodegen
xcodegen --version

# Verificar Pod dependencies
cd "/Users/chasse/PROYECTOS PERSONALES/LIFE OF CHASSE/PROGRAMMING/qa/glassesInstructor-qa"
pod install  # Si usa CocoaPods (verifica Podfile)

# Actualizar SPM (Swift Package Manager)
# En Xcode: File > Packages > Update Package Dependencies
```

### 3. Configurar Build Settings

```bash
# Verificar DEVELOPMENT_TEAM en project.yml
cat project.yml | grep DEVELOPMENT_TEAM
# Debe ser: DEVELOPMENT_TEAM: 9SXKS62RC8

# Si necesitas cambiar:
# 1. Abre project.yml
# 2. Cambia el DEVELOPMENT_TEAM a tu Apple Team ID
# 3. Ejecuta: xcodegen generate
```

### 4. Simulador

```bash
# Listar simuladores disponibles
xcrun simctl list

# Crear simulator iOS 16 de pruebas
xcrun simctl create "GlassesQA" \
  com.apple.CoreSimulator.SimDeviceType.iPhone14 \
  com.apple.CoreSimulator.SimRuntime.iOS-16-4

# Iniciar simulador
xcrun simctl boot GlassesQA
open -a Simulator  # Abre app Simulator.app

# Borrar simulador cuando termines
xcrun simctl delete GlassesQA
```

---

## 🎯 Workflow Recomendado para Este Proyecto

### Sesión de QA Típica (1 hora)

```bash
# [0:00] Setup
cd "/Users/chasse/PROYECTOS PERSONALES/LIFE OF CHASSE/PROGRAMMING/qa/glassesInstructor-qa"
open GlassesInstructor.xcodeproj
# En Xcode: Cmd+B (Build)

# [0:05] Pruebas Iniciales
# En Xcode: Cmd+R (Run en simulator)

# [0:10] Monitoreo de Recursos
# Abrir: Xcode > Product > Profile > Memory

# [0:20] Pruebas de Seguridad
xcrun simctl openurl "iPhone 15" \
  "metaglassesinstructor://injection?data=malicious"

# [0:30] Captura de Tráfico
log stream --predicate 'process == "GlassesInstructor"' > /tmp/logs.txt &

# [0:50] Documentar Hallazgos
# Actualizar: FINDINGS.md o TESTING_LOG.md

# [1:00] Limpiar
# Terminar procesos en background
# Guardar screenshots y logs
```

### Workflow de Fixing (Implementar Soluciones)

```bash
# [Paso 1] Identificar vulnerabilidad
# Leer: QA_SECURITY_ANALYSIS.md

# [Paso 2] Preparar rama de fix
git checkout -b fix/url-validation-security
# (Si estuvieras en git)

# [Paso 3] Aplicar solución
# Editar: Source/GlassesInstructorApp.swift
# Referencia: VULNERABILITY_FIXES.md

# [Paso 4] Compilar y probar
xcodebuild build  # CLI
# O en Xcode: Cmd+B

# [Paso 5] Verificar que prueba falla en original
# Ejecutar: TC-001
# Resultado esperado: ✓ PASA (vulnerabilidad confirmada)

# [Paso 6] Aplicar fix
# Copiar código de VULNERABILITY_FIXES.md

# [Paso 7] Re-compilar
xcodebuild build

# [Paso 8] Verificar que prueba pasa en fixed
# Ejecutar: TC-001
# Resultado esperado: ✓ PASA (vulnerabilidad mitigada)

# [Paso 9] Documentar cambio
# Actualizar: VULNERABILITY_FIXES.md con resultado
```

---

## 📊 Métricas para Monitoreo

### Usando Xcode Instruments

```
Lanzar Instruments:
1. En Xcode: Product > Profile
2. Seleccionar plantilla deseada
3. Seleccionar target: GlassesInstructor
4. Seleccionar dispositivo: Simulator
5. Click "Profile"

Plantillas útiles:
├── Memory (profiling de memoria)
├── System Trace (CPU, GPU, I/O)
├── Energy Impact (consumo de batería)
├── Network (tráfico de red)
├── File Activity (acceso a disco)
└── Allocations (memoria detallada)
```

### Usando CLI

```bash
# Monitoreo de memoria en tiempo real
ps aux | grep GlassesInstructor

# Logs en tiempo real
log stream --predicate 'process == "GlassesInstructor"' --level debug

# Captura de tráfico de red
sudo tcpdump -i en0 -w /tmp/network.pcap host <IP>

# Análisis de performancia
xcrun simctl spawn <device-id> log collect --output-directory /tmp
```

---

## 🚨 Troubleshooting Común

### Problema 1: "API MISUSE: CBCentralManager"

**Causa:** Inicialización de CBCentralManager en hilo principal sin @MainActor  
**Solución:**
```swift
// ❌ Incorrecto
class Manager {
    let centralManager = CBCentralManager()
}

// ✅ Correcto
@MainActor
class Manager {
    let centralManager = CBCentralManager()
}
```

### Problema 2: Proyecto no genera con xcodegen

**Causa:** DEVELOPMENT_TEAM no configurado  
**Solución:**
```bash
# Obtener tu Apple Team ID
security find-identity -p codesigning -v | grep "Personal Team"
# Salida: "E7ABCDEF123456 "Apple Development: ..."" (el número es tu Team ID)

# Actualizar project.yml
sed -i '' 's/9SXKS62RC8/E7ABCDEF123456/g' project.yml

# Regenerar
xcodegen generate
```

### Problema 3: Simulator no responde

**Solución:**
```bash
# Reiniciar simulator
xcrun simctl shutdown <device-id>
xcrun simctl boot <device-id>

# O reiniciar completamente
killall "com.apple.CoreSimulator.CoreSimulatorService"
open -a Simulator
```

### Problema 4: Memoria creciendo infinitamente

**Análisis:**
```bash
# Usar Instruments para identificar leak
xcrun instruments -t Allocations \
  -D /tmp/allocations.trace \
  /path/to/GlassesInstructor.app

# En Xcode, ir a Debug > View Memory Graph
```

---

## 📚 Recursos Descargables

### Herramientas Recomendadas

**Para Captura de Tráfico:**
```bash
brew install wireshark  # GUI para pcaps
brew install mitmproxy  # Proxy transparente
```

**Para Análisis de Código:**
```bash
brew install swiftformat  # Formatter
brew install swiftlint    # Linter
```

**Para Documentación:**
```bash
brew install graphviz     # Diagramas
brew install mermaid-cli  # Diagramas Mermaid
```

### Testing Frameworks (Si quieres más pruebas)

```swift
// En el proyecto, agregar a Package.swift o Podfile:

// Para unit tests
dependencies: [
    .package(url: "https://github.com/Quick/Quick", from: "5.0.0"),
    .package(url: "https://github.com/Quick/Nimble", from: "11.0.0")
]

// Para UI tests (nativo de Xcode)
// File > New > Target > iOS UI Testing Bundle
```

---

## 🎯 Próximos Pasos Recomendados

### Fase 1: Exploración (Hoy)
- [ ] Leer todos los documentos de análisis
- [ ] Compilar el proyecto
- [ ] Ejecutar TC-001 (URL Injection)
- [ ] Capturar screenshots

### Fase 2: Testing (Día 2)
- [ ] Ejecutar todas las pruebas (TC-001 a TC-005)
- [ ] Documentar resultados
- [ ] Tomar screenshots/videos
- [ ] Registrar métricas en hoja de cálculo

### Fase 3: Fixing (Día 3)
- [ ] Implementar soluciones del VULNERABILITY_FIXES.md
- [ ] Recompilar
- [ ] Re-ejecutar pruebas
- [ ] Verificar que fallos son mitigados

### Fase 4: Presentación (Día 4)
- [ ] Preparar slides
- [ ] Grabar demostraciones
- [ ] Hacer presentación en vivo
- [ ] Recopilar preguntas

---

## 📞 Contacto & Soporte

**Para preguntas sobre el proyecto:**
- Revisar primero: `KNOWLEDGE_BASE.md`
- Documentación Apple: https://developer.apple.com/documentation/

**Para problemas técnicos:**
- Xcode Help > Documentation and API Reference
- Stack Overflow (tag: `ios`, `swift`, `security`)
- OWASP Mobile: https://owasp.org/www-project-mobile-top-10/

**Para reporte de bugs:**
- Crea issue en: `FINDINGS.md` o `TESTING_LOG.md`
- Incluye: reproducción exacta, logs, capturas

---

## 📝 Checklist Final

- [ ] Xcode 15+ instalado
- [ ] XcodeGen instalado (`xcodegen --version`)
- [ ] Swift 5.9+ (`swift --version`)
- [ ] Simulator creado y funcional
- [ ] Proyecto compilado sin errores
- [ ] Todos los documentos QA leídos
- [ ] Primer script de prueba ejecutado
- [ ] Screenshots iniciales tomados
- [ ] Notas de environment guardadas

---

## 🎓 Recursos de Aprendizaje

**Swift Security:**
- https://developer.apple.com/swift/

**iOS Security:**
- https://developer.apple.com/security/
- https://www.hackingwithswift.com/articles

**OWASP:**
- https://owasp.org/www-project-mobile-top-10/
- https://cheatsheetseries.owasp.org/

**Debugging:**
- [Xcode Debugging Guide](https://developer.apple.com/documentation/xcode/debugging)
- [WWDC: Debugging with Xcode](https://developer.apple.com/videos/play/wwdc2021/10207/)

---

**Última actualización:** 2026-09-01  
**Estado:** Listo para QA & Presentación

¡Que disfrutes el laboratorio! 🚀

