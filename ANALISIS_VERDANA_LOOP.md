# 🔬 Análisis: verdana-loop.vercel.app

**Ejecutado:** 2026-09-01 · motor `LinkAnalyzer` en cascada
**Método:** medición real sobre la superficie pública. Cero suposiciones.

| | Veredicto | Score |
|---|---|---|
| **Seguridad** | 🔴 RIESGO | **0 / 100** |
| **Artesanía** | 🟢 OK | **86 / 100** |

Un perfil poco común y muy específico: **el código está bien hecho, la infraestructura está sin configurar.**

---

## 1. ¿Qué es el proyecto?

> *"Trazabilidad del pool de empaque reutilizable: ciclo, merma, retorno y CO₂ medidos por unidad."*

**VERDANA Loop** es una plataforma de **economía circular para empaque retornable**. No es una landing genérica: mide cuatro variables concretas por unidad de envase — ciclo, merma, retorno y huella de CO₂.

La arquitectura de rutas revela el modelo de negocio:

| Ruta | H1 / título | Lectura |
|---|---|---|
| `/` | "Elige tu papel en el ciclo" | Selector de rol de entrada |
| `/panel` | "Dashboard operativo · VERDANA Loop" | Vista de operador del pool |
| `/retailer` | — | Vista del comercio que recibe/devuelve |

**Es un marketplace de dos lados con roles asimétricos.** Quien opera el pool ve métricas de flota; el retailer ve su propio ciclo. Esa separación desde la raíz es una decisión de producto, no un accidente.

### ¿Es un proyecto de valor?

**Sí, con reservas honestas.** Lo que sostiene esa lectura:

- **Dominio específico y medible.** "Merma y CO₂ por unidad" es una métrica que le importa a alguien que paga. No es un clon de to-do list.
- **Modelo multi-actor pensado.** La bifurcación operador/retailer implica que se pensó en quién usa qué.
- **Timing de mercado.** Regulación de empaque de un solo uso está apretando en LATAM y la UE. El problema existe.

**Lo que no puedo afirmar desde fuera, y sería deshonesto insinuar:** no vi backend, base de datos, autenticación ni lógica de negocio. Todo el análisis es de la superficie pública renderizada. El `/panel` podría estar alimentado por datos reales o por un array hardcodeado — desde aquí no se distingue. Esa pregunta está en la batería del documento `PREGUNTAS_ANTIVIBECODEO.md`.

---

## 2. ¿Qué tecnología usaron?

Detectado por headers y assets, sin adivinar:

| Capa | Detectado | Evidencia |
|---|---|---|
| **Framework** | Next.js 15+ **App Router con RSC** | `x-nextjs-prerender: 1` + `vary: rsc, next-router-state-tree` |
| **Bundler** | **Turbopack** | chunk `turbopack-12keuhi9j75sp.js` |
| **Hosting** | Vercel, edge cache | `server: Vercel`, `x-vercel-cache: HIT` |
| **Render** | Prerender estático + ISR 300 s | `x-nextjs-stale-time: 300` |
| **CSS** | Tailwind con **design system propio** | `text-ink-strong`, `bg-brand-on-plum`, `text-accent-text` |
| **Tipografía** | Hanken Grotesk + Inter, **self-hosted** | `next/font` → `.woff2` en `/_next/static/media/` |
| **Animación** | **CSS puro, sin librerías** | 0 framer-motion, 0 GSAP, 0 lottie. 34 `transition`, 3 `animation`, 1 `@keyframes` |

### Sobre botones y animaciones, que preguntabas explícitamente

**No hay `<button>` ni `<form>` ni `<input>` en la home.** Los "botones" de selección de rol son `<a>` estilizados que navegan a `/panel` y `/retailer`. Es correcto: navegan, no ejecutan acciones — un `<a>` es lo semánticamente apropiado y funciona con clic derecho, abrir en pestaña nueva y teclado. **Un vibecodeador casi siempre pone `<div onClick>` aquí.** Esto no lo hizo.

Las animaciones son **CSS puro**: 34 transiciones, 3 animaciones, 1 `@keyframes`. Cero peso de librería. Y respetan `prefers-reduced-motion`.

---

## 3. Seguridad: 0/100

El score cuenta **solo los headers que tú controlas**. HSTS queda excluido a propósito: Vercel lo inyecta solo, premiarlo inflaría la nota sin mérito tuyo.

| Header | Estado | Qué previene |
|---|---|---|
| `content-security-policy` | ❌ AUSENTE | Inyección de scripts de terceros |
| `x-frame-options` | ❌ AUSENTE | **Clickjacking**: tu sitio embebido en un iframe ajeno |
| `x-content-type-options` | ❌ AUSENTE | MIME sniffing |
| `referrer-policy` | ❌ AUSENTE | Fuga de URLs internas al navegar afuera |
| `permissions-policy` | ❌ AUSENTE | Acceso no declarado a cámara/micrófono/geo |
| `strict-transport-security` | ✅ presente | *(automático de Vercel, no cuenta)* |

**Riesgo real, sin dramatizar:** la home no tiene formularios ni inputs, así que la superficie de ataque hoy es baja. **Pero `/panel` es un dashboard.** En el momento en que tenga login o datos de cliente, la ausencia de `X-Frame-Options` y CSP pasa de teórica a explotable — clickjacking sobre un panel autenticado es un ataque real.

También noté `access-control-allow-origin: *` en el HTML. Para contenido estático público es inofensivo; si algún endpoint de API hereda esa política, no lo es.

### Arreglo: 10 minutos, un archivo

```js
// next.config.js
const securityHeaders = [
  { key: 'X-Frame-Options',        value: 'SAMEORIGIN' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy',        value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy',     value: 'camera=(), microphone=(), geolocation=()' },
  { key: 'Content-Security-Policy',
    value: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'" },
];

module.exports = {
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};
```

> Ajusta el CSP antes de publicar: si usas Vercel Analytics o fuentes externas, hay que
> permitirlas explícitamente o romperás el sitio. Prueba primero con
> `Content-Security-Policy-Report-Only`.

Con eso solo, el score pasa de **0/100 a 100/100**.

---

## 4. Artesanía: 86/100 — esto **no** está vibecodeado

Las señales que suman son precisamente las que el código generado sin criterio no produce:

| Peso | Señal | Por qué importa |
|---|---|---|
| **+12** | Respeta `prefers-reduced-motion` | Apaga animaciones para quien tiene vértigo o migraña. **Casi nadie lo hace.** |
| **+10** | Source maps protegidos (403) | Tu código fuente original no es público |
| **+8** | Tipografía fluida con `clamp()` | Escala con el viewport sin breakpoints a saltos |
| **+8** | 4 `aria-label` | Hay intención de accesibilidad |
| **+6** | `text-balance` | Control fino de saltos de línea en títulos |
| **+5** | `<html lang="es">` | Los lectores de pantalla usan la fonética correcta |
| **−5** | Sin `<h2>`/`<h3>` en la home | Estructura no navegable por lector de pantalla |
| **−8** | Sin Open Graph | Compartir el link no genera preview |
| **0** | `dangerouslySetInnerHTML` | **Falso positivo:** es el error boundary de Next.js, no código tuyo |

### El detalle que más delata trabajo humano

```html
<h1 class="max-w-[16ch] font-display text-[clamp(26px,3.2vw,38px)]
           leading-[1.05] tracking-tight text-ink-strong text-balance">
```

Cuatro decisiones que nadie toma por accidente:

1. **`max-w-[16ch]`** — ancho medido en caracteres, no en píxeles. Es cómo piensa alguien que estudió tipografía.
2. **`clamp(26px, 3.2vw, 38px)`** — escala fluida con piso y techo.
3. **`leading-[1.05]`** — interlineado apretado, correcto para títulos grandes.
4. **`text-balance`** — equilibra las líneas del título.

El código vibecodeado escribe `text-3xl font-bold` y se acabó. Esto es otra cosa.

Los tokens semánticos (`ink-strong`, `brand-on-plum`, `accent-text`) confirman lo mismo: hay un design system con nombres de intención, no colores sueltos tipo `text-gray-800`.

### Lo que sí falta

- **Open Graph.** Compartir el link en WhatsApp sale sin preview. Para un proyecto que se presenta, es la carencia más visible. ~15 minutos con `generateMetadata` de Next.
- **Jerarquía de encabezados en la home.** Un solo `<h1>` sin `<h2>`. El `/panel` sí tiene 4 — ahí la estructura está mejor.

---

## 5. Rendimiento medido

| Métrica | Valor | Lectura |
|---|---|---|
| TTFB | **235 ms** | Servido desde caché edge (`x-vercel-cache: HIT`) |
| HTML comprimido | **6.5 KB** | Muy liviano |
| JS comprimido (brotli) | **~162 KB** | Sano para App Router. Sin bloat de librerías |
| JS sin comprimir | 624 KB | Brotli lo reduce ~74% |
| Chunks | 8 | Code splitting activo |

**Sin librerías de animación** es la razón principal de que el bundle esté contenido. Meter framer-motion habría sumado ~50 KB para lograr lo mismo que ya hacen 34 transiciones CSS.

---

## 6. Veredicto

**Es un proyecto real, bien construido en frontend, con la infraestructura sin terminar.**

La forma del problema es reveladora: todo lo que requiere **criterio de código** está bien (accesibilidad, tipografía, semántica, peso). Todo lo que requiere **acordarse de configurar la plataforma** está sin hacer (headers, OG tags).

Eso es el patrón típico de un proyecto **en desarrollo activo que aún no cruzó a producción** — no el de uno generado sin entender. Un proyecto vibecodeado falla al revés: se ve bien en la primera pantalla y se cae en accesibilidad, en el borde y en el detalle tipográfico. Aquí pasa lo contrario.

### Prioridad de arreglo

| # | Acción | Esfuerzo | Impacto |
|---|---|---|---|
| 1 | Headers en `next.config.js` | 10 min | 0 → 100 en seguridad |
| 2 | Open Graph + `og:image` | 15 min | El link deja de verse roto al compartirse |
| 3 | `<h2>` en secciones de la home | 20 min | Estructura navegable |
| 4 | Revisar CORS `*` si hay API | 30 min | Cierra superficie si se expone data |

**Las dos primeras suman 25 minutos** y son las que se notan en una demostración pública.

---

## 7. Reproducir este análisis

```bash
# Motor compilado como binario de línea de comandos
swiftc -O LinkAnalysis.swift LinkAnalyzer.swift main.swift -o analyzer
./analyzer "https://verdana-loop.vercel.app/"
```

Salida real de la cascada:

```
[    0ms] capa=Detectado      HUD | verdana-loop.vercel.app
[  433ms] capa=Seguridad      HUD | SEC X 0/100 · 433ms
[  452ms] capa=Identidad      HUD | VERDANA Loop
[  591ms] capa=Artesanía      HUD | CRAFT OK 86/100

=== SEGUNDA PASADA (cache): 0ms ===
```

**La Capa 2 costó 19 ms** sobre la Capa 1 porque reutiliza el HTML ya descargado — ese es el punto de la arquitectura en cascada. Y la segunda pasada sale de caché en **0 ms**.

### Control de calibración

Para verificar que el motor discrimina y no reparte ceros:

| Sitio | Seguridad | Artesanía |
|---|---|---|
| `github.com` | **80/100** (4 de 5 headers) | 69/100 |
| `verdana-loop.vercel.app/` | 0/100 | **86/100** |
| `verdana-loop.vercel.app/panel` | 0/100 | **83/100** |

GitHub gana en seguridad; VERDANA gana en artesanía. El motor separa las dos dimensiones en vez de colapsarlas en una nota única, que es justo lo que hace útil el diagnóstico.
