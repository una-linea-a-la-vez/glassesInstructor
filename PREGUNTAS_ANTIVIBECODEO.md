# 🎯 Cómo interrogar un proyecto para saber si está vibecodeado

**El principio:** quien generó código sin entenderlo **puede describir qué hace**. No puede
explicar **por qué se eligió eso sobre la alternativa**, ni **qué pasa cuando falla**.

Toda pregunta buena apunta a una de esas dos cosas: *el porqué* o *el borde*.

Preguntar "¿qué stack usaste?" no sirve — eso se lee de los headers en 200 ms, y cualquiera
lo repite. Pregunta por decisiones.

---

## 🔘 Botones e interacción

**1. ¿Este botón es un `<button>` o un `<div>` con onClick? ¿Por qué?**

- 🟢 *"Es `<a>` porque navega, no ejecuta una acción. Así funciona clic derecho, abrir en pestaña nueva y Cmd+clic."*
- 🔴 *"Es un div porque así se veía mejor."* — Un `<div onClick>` no recibe foco de teclado, no lo anuncia el lector de pantalla y no responde a Enter.

**2. Navega tu sitio completo solo con Tab, sin tocar el mouse. ¿Puedes llegar a todo?**

La prueba más rápida que existe. Pídele que lo haga **en vivo, frente a ti**. Si el foco desaparece, salta en orden ilógico o queda atrapado en un modal, el código no se pensó para teclado.

**3. ¿Qué pasa si hago doble clic rápido en enviar?**

- 🟢 *"El botón se deshabilita en el primer clic"* o *"hay idempotencia en el backend."*
- 🔴 Silencio, o *"pues... se enviaría dos veces."* — Pedidos duplicados, cobros dobles.

**4. ¿Dónde está el estado de carga de este botón?**

Si no existe: en una conexión lenta el usuario clickea cinco veces creyendo que no funcionó.

---

## ✨ Animaciones

**5. ¿Respetas `prefers-reduced-motion`?**

**La pregunta más discriminante de toda la lista.** Es una media query de tres líneas que apaga las animaciones para quien tiene vértigo, migraña o epilepsia fotosensible.

- 🟢 Sabe qué es y lo implementó *(VERDANA Loop lo hace — señal genuina de criterio)*
- 🔴 *"¿Eso qué es?"* — nunca consideró que alguien pudiera necesitar apagarlas

**6. ¿Por qué animaste con CSS y no con framer-motion? (o al revés)**

- 🟢 *"CSS puro porque son transiciones simples; framer-motion me costaba 50 KB para lo mismo."*
- 🔴 *"Porque sí"* / *"es lo que había en el ejemplo."*

**7. ¿Qué propiedades animas? ¿`transform` y `opacity`, o `width` y `top`?**

- 🟢 `transform`/`opacity` — corren en GPU, no disparan reflow
- 🔴 `width`, `height`, `top`, `left` — provocan relayout en cada frame y hacen tartamudear la animación en móvil

**8. ¿Cuánto dura esta transición y por qué ese número?**

- 🟢 *"150 ms para feedback inmediato, 300 ms para cambios de layout."*
- 🔴 *"El default."* — Los defaults suelen ir a 500 ms y se sienten lentos.

---

## 🗄️ Estado y datos

**9. Enséñame de dónde salen estos datos. Sígueme el hilo desde la base de datos hasta el pixel.**

Pídele que lo haga **navegando el código en vivo**. Quien lo escribió salta entre archivos sin dudar. Quien lo generó abre archivos a ver cuál era.

**10. ¿Este dashboard consume datos reales o hay un array hardcodeado?**

*(Aplicable directo a `/panel` de VERDANA Loop: desde fuera no se distingue.)*

**11. ¿Qué se ve cuando no hay datos todavía?**

El estado vacío es lo primero que se olvida. 🟢 Tiene un diseño pensado. 🔴 Tabla en blanco o un crash.

**12. ¿Qué pasa si la petición tarda 30 segundos? ¿Y si falla?**

- 🟢 *"Timeout a los N segundos, se muestra error con botón de reintentar."*
- 🔴 *"Se queda cargando."* — Es exactamente el bug que tuvimos en las gafas: la app se queda callada.

---

## 🔒 Seguridad

**13. Ábreme los headers de respuesta. ¿Dónde está tu CSP?**

Verificable en 5 segundos con DevTools → Network → cualquier request → Headers. Sin CSP ni `X-Frame-Options`, tu sitio se puede embeber en un iframe ajeno.

**14. Si escribo `<script>alert(1)</script>` en este campo, ¿qué pasa?**

- 🟢 Se guarda como texto plano y se muestra escapado
- 🔴 *"Nunca lo probé."*

**15. ¿Dónde validas los datos: en el cliente, en el servidor, o en ambos?**

- 🟢 **"En ambos.** El cliente para UX, el servidor porque el cliente es manipulable."
- 🔴 *"En el cliente"* — cualquiera abre DevTools y lo salta.

**16. ¿Están tus source maps públicos en producción?**

Prueba en un segundo: toma un `.js` del bundle y agrégale `.map`. Si responde **200**, tu código fuente original es público. *(VERDANA Loop responde 403 — bien.)*

**17. ¿Alguna API key vive en el código del cliente?**

Todo lo que llega al navegador es visible. Busca `NEXT_PUBLIC_` en el bundle: si ahí hay una clave con permisos de escritura, es un incidente.

---

## 🧨 Casos borde — donde se cae el código sin criterio

**18. ¿Qué pasa si un nombre tiene 200 caracteres? ¿Si tiene emoji? ¿Si está en árabe?**

El código generado asume texto corto en alfabeto latino. El diseño se rompe con nombres largos y RTL.

**19. ¿Qué se ve con 10 000 registros en esta tabla?**

- 🟢 Paginación o virtualización
- 🔴 *"No lo probé con tantos"* — el navegador se congela

**20. Apaga el WiFi a media carga. ¿Qué ve el usuario?**

**21. ¿Funciona en un iPhone SE?** (375 px de ancho)

Muchos proyectos se prueban solo en la pantalla de quien los hizo.

---

## ♿ Accesibilidad — el delator más confiable

Lo que salta primero cuando nadie revisó el código.

**22. ¿Cuál es tu contraste de texto? ¿Pasa AA (4.5:1)?**

Gris claro sobre blanco es la firma del vibecodeo estético.

**23. ¿Tus imágenes tienen `alt` descriptivo?**

- 🟢 `alt="Gráfica de retorno de envases por mes"`
- 🔴 `alt="imagen"` o `alt=""` en imágenes con contenido

**24. Sin mirar, dime tu jerarquía de encabezados.**

Un `<h1>`, luego `<h2>` para secciones. 🔴 Saltar de `<h1>` a `<h4>` porque "se veía del tamaño correcto" — clásico de estilizar sin estructurar.

---

## ⚡ Rendimiento

**25. ¿Cuánto pesa tu bundle JavaScript comprimido?**

- 🟢 Sabe el número, o sabe cómo medirlo
- 🔴 *"No sé"* — nunca lo miró, probablemente lleva 3 librerías para lo que hace una

**26. ¿Cargas fuentes de Google Fonts o self-hosted?**

Self-hosted evita un round-trip externo y una fuga de IPs a un tercero. *(VERDANA Loop las self-hostea vía `next/font`.)*

---

## 💣 Las tres preguntas matadoras

Si solo tienes tiempo para tres:

### **27. "Cambia esto delante de mí."**

Pide una modificación pequeña y concreta: *"haz que este botón sea rojo y que muestre un contador."* Quien entiende su código lo hace en dos minutos. Quien no, empieza a pedirle a una IA que se lo arregle — y ahí termina la conversación.

### **28. "¿Qué parte de esto volverías a escribir distinto y por qué?"**

Todo el que construyó algo real tiene una respuesta inmediata y específica: *"el manejo de estado del panel, quedó enredado."* Quien generó el código no tiene opinión, porque nunca sufrió ninguna decisión.

### **29. "¿Qué se rompió mientras lo hacías?"**

El desarrollo real es una secuencia de cosas rotas. Quien lo vivió cuenta la historia con detalle y hasta con gracia. Quien no, dice *"todo salió bien."* Nada sale bien de una.

---

## 📋 Hoja de puntuación rápida

| Señal | Peso | Cómo verificar |
|---|---|---|
| Respeta `prefers-reduced-motion` | 🟢🟢🟢 | Buscar en el CSS |
| Navegable solo con teclado | 🟢🟢🟢 | Tab por todo el sitio |
| Validación en cliente **y** servidor | 🟢🟢🟢 | Preguntar y ver el código |
| Estados vacíos y de error diseñados | 🟢🟢 | Pedir que los muestre |
| Source maps protegidos | 🟢🟢 | Agregar `.map` a un chunk |
| Headers de seguridad configurados | 🟢🟢 | DevTools → Network |
| Contraste AA | 🟢 | DevTools → Lighthouse |
| `<div onClick>` en vez de `<button>` | 🔴🔴 | Inspeccionar elemento |
| `console.log` en producción | 🔴 | Abrir la consola |
| No sabe el peso de su bundle | 🔴 | Preguntar |
| No puede modificar su código en vivo | 🔴🔴🔴 | **Pedírselo** |

---

## ⚖️ Una advertencia sobre el uso de esto

Usar IA para escribir código no es el problema — **no entender lo que se entregó, sí.**
Un desarrollador que generó código con IA, lo leyó, entendió por qué funciona y puede
defender cada decisión, hizo su trabajo. La distinción no es *"usó IA o no"*, es
**"sabe qué construyó o no"**.

Por eso las tres preguntas matadoras no mencionan IA en ningún momento: preguntan por
**comprensión**. Y la comprensión no se puede fingir cuando pides que cambien algo enfrente de ti.

Aplícalo también hacia adentro: es una herramienta para revisar tu propio trabajo antes
de que lo revise alguien más.
