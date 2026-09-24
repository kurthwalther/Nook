# Estado al 23 sep, 21:40 (lo actualiza quien avance)

**Hecho:** toda la primera tanda (§2: temas + selector, esquina, sombra de página, barra al hover,
apertura de ventana, paleta). De la segunda: cruce del tema al cambiar de Space (temas-05 f1).
De la tercera: barra al hover con el tema (temas-07), pero con vidrio + tinte, no base opaca.
Además, fuera del plan: transparencia real (KurthVibrancy: material .sidebar sin su capa de
color, ventana isOpaque = false; superficie del tema = base blanca + tinte + grano con opacidad
0.30–1), blanco alcanzable (clic en lienzo = modo libre, blanco en la página 1), ajustes en vivo
por MCP (KurthMCPTools, kurth/mcp.sh), herramientas en kurth/diagnostico.

**Abierto (bug):** tema blanco con opacidad baja se ve casi como modo oscuro; Superconductor con
alfa bajo se ve claro. Ver la nota en la bitácora de José del 23 sep y el mensaje de handoff.

**Pendiente:** el resto de la segunda y tercera tanda (§3) y el motor (§4), en el orden que
propone §4 para memoria: motor-02 → motor-03 (con una semana solo registrando).

---

# Plan de integración Zen → Nook

*23 sep 2026 · José (Developer). Sale de 4 investigaciones (temas, chrome, movimiento y motor), cada una revisada por un verificador escéptico. En esta pasada no compilé ni corrí nada en Nook, así que todo lo marcado "verificar en runtime" sigue pendiente.*

## 1. Veredicto

- **Sí vale la pena traer el lenguaje visual de Zen**: tema translúcido de 0 a 3 colores con su selector, radios concéntricos, sombra ligera bajo la página y resortes cortos y asimétricos. Todo se puede hacer en SwiftUI y AppKit (los dos frameworks de interfaz de macOS: el declarativo nuevo y el clásico), dentro de `Nook/Kurth/`, con ganchos `kurth:` de una línea en upstream. Upstream es el repo original de Nook del que sale tu rama kurth; un gancho es una línea marcada en un archivo de upstream que llama a código tuyo.
- **Del motor de Zen no hay nada que traer.** Gecko (el motor de Firefox) no entra en Nook, que usa WebKit (el motor de Safari) a través de WKWebView. Zen tampoco trae ajustes de memoria para Mac: sus ajustes de rendimiento son de scroll y excluyen macOS. Firefox estable en Mac ni siquiera descarga pestañas por presión de memoria (`browser.lowMemoryResponseMask = 0` fuera de Nightly, firefox.js:1260-1263).
- **Sobre el peso de las páginas:** la página que tienes enfrente pesa lo que decidan el sitio y WebKit. YouTube medido: 611 MB, de los cuales 362 son JS+DOM. El margen real está en las pestañas ocultas, y ahí el problema es de Nook: las fijadas, las carpetas fijadas y los favoritos **nunca** se descargan solos. Las palancas son una política de descarga propia y el bloqueador, no algo copiado de Zen.

## 2. Primera tanda

Orden sugerido: 2.2, 2.3, 2.4 y 2.6 son chicas e independientes. 2.1 es la pieza grande y avanza en paralelo. 2.5 va al final porque usa los tokens.

**Prerrequisito (S): `Nook/Kurth/KurthMotion.swift` (mov-01).** Es un `extension NookDesign.Motion` con los resortes de Zen ya convertidos. Un resorte (spring) es una animación calculada con física, no una curva fija: SwiftUI lo describe con el tiempo que tarda en asentarse y el amortiguamiento (1 = llega sin rebote).
- La conversión está verificada contra el SDK 27: Zen `{duration d, bounce b}` = `Spring(settlingDuration: d, dampingRatio: 1 − b)`. Da la misma rigidez y fricción (k 1364, c 73.9 para 0.25 s).
- Tokens:
  - `structural = Spring(settlingDuration: 0.25, dampingRatio: 1)`: cambio de Space y movimientos de estructura.
  - `reveal = .spring(duration: 0.21, bounce: 0.18)`: entrada de la barra lateral, con 1.1 % de rebote.
  - `dismiss = .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15)`: el `ease` de CSS, para salidas.
  - `arrive = Spring(settlingDuration: 0.5, dampingRatio: 0.8)`, con 1.5 % de rebote.
  - `rowIn = .easeOut(0.12)` y `rowOut = .easeOut(0.10)`.
  - `stagger 0.03`, `secondaryDelay 0.15`, `hoverGrace 0.15` y `pressScale 0.985`.
- Cuidado con `NSAnimationContext.animate(<Animation de SwiftUI>)`: solo le pasa la duración a AppKit y deja la curva en nil (medido). Para animaciones internas de AppKit, como `NSPageController`, hay que usar `runAnimationGroup` con la curva explícita.
- Aquí también va `reduceMotion` (mov-10): con "Reducir movimiento", todo movimiento pasa a fundido de 0.12 s. Hoy Nook solo lo respeta en SpaceSeparator.swift:19.

### 2.1 Temas: fondo sin degradado obligatorio y selector de color
*(temas-01, temas-03 y temas-02; chrome-10 se fusiona aquí)*

**Qué es.** Se reemplaza `NookDesign.Surface.containerGradient` por un fondo de tema por Space, de 0 a 3 colores, con un selector propio que se abre desde la ventana. El degradado de hoy (NookDesign.swift:165-176) es opaco: arriba, el acento mezclado 55 % con el fondo; abajo, el fondo. En oscuro con naranja queda café: rgb(124,62,43) → rgb(30,30,30).

**De Zen (valores):**
- **Tinte** (ZenGradientGenerator.mjs:1335-1389):
  - 0 colores: transparente en claro, negro .4 en oscuro.
  - 1 color: plano, sin degradado.
  - 2 colores: lineal de 150° con c0 sólido hasta 30 % y transparente en 120 %, sobre un lineal de −30° igual con c1.
  - 3 colores: lineal de −5° (c2 de 10 % a 80 %), más radial en (95 %, 0) (c1 de 0 a 75 %), más radial en (0, 0) (primario de 10 a 70 %).
- **Mezcla entre capas:** `background-blend-mode: lighten`, es decir, por canal gana el valor más claro (zen-browser-ui.css:64 y 76). Por eso los cruces no salen lodosos.
- **Cada color:** con opacidad 0.5 queda 92 % color + 8 % blanco. El alfa es la opacidad del tema: de 0.30 a 0.80, 0.5 por defecto (mjs:1258-1281; theme-picker.inc:132-140).
- **Grano:** alfa medio de 0.124 × la intensidad de textura, en 16 pasos.
- **Selector:**
  - Panel de 380 pt, padding 10, radio 12. Lienzo neutro con puntos de 1 px cada 6 px.
  - Hasta 3 puntos: el primario de 38 pt con borde blanco de 6; los secundarios de 16 con borde de 3; escala 1.2 al arrastrar.
  - Ángulo = tono y distancia al centro = luminosidad.
  - Armonías: complementaria (180°), análoga (310°), dividida (150/210), análoga doble (50/310), triádica (120/240) y libre.
  - Los movimientos que hace el selector solo van con un spring de 0.4 s y bounce 0.3.
  - 5 páginas de 8 presets de 26 pt.
  - Opacidad con perilla que crece de 40×10 a 55×25 y háptica cada 0.1. Textura de 16 pasos con háptica.
  - La vista previa es en vivo y se guarda al cerrar.

**En Nook:**
- **`KurthTheme.swift` (temas-03, S).**
  - Modelo Codable: versión, hasta 3 puntos con hex y x/y, armonía, opacidad y grano.
  - Se guarda en `Application Support/com.gstudios.nook/Kurth/themes.json` con escritura atómica. No en UserDefaults: KurthChrome escucha `UserDefaults.didChangeNotification` (KurthChrome.swift:84-91) y cada arrastre lo despertaría.
  - Se escribe solo al cerrar el selector. En ese momento se llama `tabs.updateSpace(id, name: nil, icon: nil, accentHex: primario)` (TabsController+Intents.swift:496-499).
  - structure.json no cambia de formato. Si falta el archivo, el Space cae a un tema de 1 color con accentHex, que es lo de hoy.
- **`KurthThemeBackground.swift` (M), en tres capas:**
  1. **Base.** Por defecto "Opaco": windowBackgroundColor, con el mismo costo que hoy. La opción "Translúcido" reusa `Nook/Utils/BlurEffectView.swift` con `.hudWindow`, `blendingMode: .behindWindow` y `state: .followsWindowActiveState`.
     - NSVisualEffectView es la vista de AppKit que pinta un material del sistema. Con behindWindow desenfoca lo que hay detrás de la ventana, y lo compone WindowServer, el proceso de macOS que arma la pantalla.
     - Va envuelta con `hitTest → nil`, como KurthBackdropBlur.swift:79, para que no se coma los clics.
     - Con la ventana inactiva, el tinte se multiplica por 0.6.
  2. **Tinte** dentro de `.compositingGroup()` (SwiftUI aplana ese subárbol en una sola capa antes de mezclar).
     - Las capas superiores van con `.blendMode(.lighten)`.
     - Las paradas van de `color` a `color.opacity(0)`, nunca a `Color.clear`, que mete un halo gris.
     - El alfa se recalcula donde el CSS pasa del 100 %.
  3. **Grano** con el asset `noise_texture`, que Nook ya trae sin usar. El PNG de Zen es MPL y no conviene copiarlo.
  - El tema se lee de `windowState.spaceID`, no de GradientColorManager. Con eso se corrige que hoy las ventanas inactivas pinten el color del Space de la ventana activa (WindowView.swift:170-178, 193).
- **`KurthEmptyPage.swift`:** página vacía transparente, con radio 8. Hoy EmptyWebsiteView repite el degradado con radio 12, contra 8 de la página.
- **`KurthThemeMath.swift`, `KurthThemePicker.swift` y `KurthThemePickerOverlay.swift` (L).**
  - Punto de partida: el editor que upstream borró, `git show 92ef7db^:Nook/Components/ColorPicker/GradientCanvasEditor.swift` (583 líneas, ya con rejilla, 3 nodos, recorte al círculo y hápticos).
  - Es una capa dentro de la ventana, con el patrón de ExtensionLibraryOverlay.swift:20-75.
  - Anclaje: al borde de la ventana (leading + ancho de la barra si está fija; leading + 8 si no). **Nunca** al overlay de hover, porque ese se cierra en cuanto el cursor sale (SidebarHoverOverlayView.swift:28-60). Mientras el selector esté abierto, HoverSidebarManager mantiene visible la barra para que se vea la vista previa.
  - Entradas: "Editar tema…" en el menú de la barra lateral, y ⌘⇧G, que hoy abre Ajustes (KeyboardShortcutManager.swift:557-558).
- **Ganchos en upstream:**
  - WindowView.swift:196, el fondo. Se conservan `.contextMenu` "Space Settings...", `.backgroundDraggable()` y privateTint.
  - WebsiteView.swift:236, la página vacía.
  - Un `.overlay` en WindowView para el selector.
  - Un Button en SpacesSideBarView.swift:257-288.
  - La redirección de ⌘⇧G.
- **En código propio:** KurthTopBarView debe quedar `.clear` cuando no hay pestaña. Hoy pinta windowBackgroundColor opaco (KurthTopBarView.swift:96-99, 314-318) y sería una franja flotando sobre el tema.

**Esfuerzo:** S (store) + M (fondo) + L (selector).

**Riesgo: medio.**
- El modo translúcido deshace una decisión de upstream: 60d0d34 (16 sep) quitó justo `BlurEffectView(material: .sidebar, blendingMode: .behindWindow)` por costo. Por eso el default es "Opaco" hasta medir con Instruments (el perfilador de Xcode) en la Air.
- La fila seleccionada de vidrio (d9be642) nunca ha corrido sobre un material.
- Hasta que entre temas-04, un tema oscuro con el sistema en claro deja texto oscuro sobre fondo oscuro.
- GradientColorManager sigue dando el acento a diálogos, chat de IA y LinkStatusBar. En ventanas inactivas, esos seguirán mostrando el Space de la ventana activa.
- Licencia: lo traducido de ZenGradientGenerator.mjs es una modificación bajo MPL-2.0 (la licencia de Zen, que va por archivo). Lleva el encabezado MPL con la ruta de origen (§3.1) y se puede combinar con GPL-3.0 (§3.3). Las constantes y los valores de color son datos.

**No rompe:**
- El contrato de accentHex: los puntos del switcher, las carpetas, Ajustes y la importación de Arc siguen igual.
- Un build de upstream sobre los mismos datos ve el acento correcto.
- La cápsula, el blur, los semáforos y el rebote viven sobre la página y no cambian.
- La ventana ya es `.clear` (NookApp.swift:273).

### 2.2 El huequito de la esquina superior izquierda
*(chrome-01 confirmada; contornos-01 ajustada)*

**Qué es.** La barra que aparece al pasar el mouse es la de tu modo (`sidebarVisible = 0`). Es una tarjeta de vidrio de radio 12 con 8 pt de margen, dentro de una ventana de radio 16 (medido: `NSThemeFrame._cornerRadius = 16` con cualquier toolbar). Los radios no son concéntricos: en la diagonal de la esquina la separación es de 9.63 pt, contra 8 en los lados, y ese exceso es el hueco. Con la barra fija no hay hueco, porque no pinta fondo propio.

**De Zen.** La barra compacta queda a 4 px de las tres orillas, y su radio sale del de la ventana más la separación: 9.1 + 4 = 13.1 px (sidebar.inc.css:54-56, 65-102).

**En Nook:**
- En `KurthChrome.swift`: `overlayInset = 4` y `overlayShape = ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)`. ConcentricRectangle es una forma de SwiftUI (macOS 26) cuyo radio es el del contenedor menos la distancia a su orilla. En tu Mac resuelve 16 pegada a la orilla y 8 con margen de 8.
- Ganchos: SidebarHoverOverlayView.swift:23-24 (los márgenes) y :52 (`.nookGlassEffect(in: KurthChrome.overlayShape)`).
- Resultado: radio 12, igual que hoy, pero concéntrico. La diagonal queda en 3.97 pt contra 4 en los lados. Si prefieres el aire de 8 pt: margen 8 y `minimum: 8`, y el radio resuelve a 8.
- De paso: hoy el título del Space dentro de la barra queda 8 pt más abajo que los semáforos. Con margen 4 la diferencia baja a 4. Para eliminarla, el overlay pasa su margen por Environment (un valor que SwiftUI propaga a todas las vistas hijas) y la franja del título lo resta.
- La página no necesita cambios: 16 − 8 = 8, ya es concéntrica. Lo único que no cuadra es la página vacía de radio 12, y eso lo arregla KurthEmptyPage (2.1).

**Esfuerzo:** S. **Riesgo:** bajo; son dos líneas marcadas. Pero nadie vio tu captura #9: antes de darlo por cerrado, mándame una captura con zoom de la esquina.

**No rompe:**
- La transición `.move` no deforma el radio (medido).
- El disparador de 6 pt es el mismo.
- Los semáforos siguen visibles con la barra abierta.

### 2.3 Sombra ligera en el borde de la página
*(chrome-02 y contornos-02, ajustadas)*

**Qué es.** Hoy la tarjeta lleva `.nookElevation(.raised)`: negro .05, radio 2, y 1 (NookDesign.swift:190-199). Casi no se ve, y cuando la página es del mismo color que el chrome la orilla desaparece.

**De Zen.** Tu Zen instalado (1.22.3b) sí le pone sombra a la página: `rgba(0,0,0,.24) 0 3px 8px` en claro y en oscuro (zen-browser-container.css:12-13 del omni.ja instalado, el archivo comprimido donde Zen guarda su CSS). En main (4c92731) esa sombra ya no está, así que puede desaparecer en la próxima versión de Zen. Zen no pone contorno en la página.

**En Nook:**
- `Nook/Kurth/KurthPageEdge.swift`: la sombra va en una forma **hermana, detrás** de la tarjeta, no en el grupo del WKWebView:
  `.background { Radius.shape(Radius.md).fill(Surface.windowBackground).shadow(color: .black.opacity(0.24), radius: 4, y: 3) }`
  Un blur de CSS de 8 px equivale a radius 4 en SwiftUI. Si en claro se ve pesada, bajarla a 0.16.
- Gancho en WindowView.swift:268-275, solo con `!splitManager.isSplit(for:)`. WebsiteView.swift:229 pasa a `.flat` en el camino kurth.
- Sin `clipShape` exterior: WebsiteView.swift:186-199 ya recorta.
- Contorno de 1 px físico (`1/displayScale`, que en Retina es 0.5 pt) detrás del default `kurth.pageOutline`, **apagado**. Te quejaste justo de los contornos.
- Sin sombra cuando no hay pestaña: el relleno asomaría detrás de la página vacía transparente.

**Esfuerzo:** S. **Riesgo:** bajo mientras la sombra vaya en la forma hermana. No hay que agrandar la sombra que hoy va después de `.compositingGroup()` sobre el WKWebView (WebsiteView.swift:224-229): eso recalcula el desenfoque de una capa del tamaño de la página en cada cuadro de scroll o de video.

**No rompe:** el rebote, `KurthChrome.syncObscuredInset` ni el muestreo de color. **Ojo con split:** SplitPaneView enmascara cada panel aparte, con 8 pt de hueco (SplitPaneView.swift:79-87). Un relleno detrás de todo pintaría ese hueco. En split, la sombra va por panel o no va.

### 2.4 Barra lateral al hover: entra con resorte, sale rápido y espera 150 ms
*(chrome-03 ajustada; mov-05 confirmada)*

**Qué es.** Hoy entra y sale con easeInOut de 0.15 s más un fundido: a los 50 ms lleva 23 % del recorrido, contra 50 % del resorte de Zen. Además hay dos animaciones peleando por el mismo estado: el hotspot con `Motion.quick` (SidebarHoverOverlayView.swift:36) y el manager con easeInOut 0.15 (HoverSidebarManager.swift:140). Y se oculta sin gracia en cuanto el mouse sale de la zona de 52 pt.

**De Zen:**
- Entrada: curva `linear()` de 0.25 s que equivale a `.spring(response: 0.208, dampingFraction: 0.82)`, con pico de 1.011 y asentada a los 0.237 s (verificado contra la curva).
- Salida: `0.15s ease`.
- Mantiene la barra 150 ms después de que sale el mouse.
- Tolera que el mouse se aleje 200 px en horizontal y 100 en vertical **fuera de la ventana** antes de cerrarla.

**En Nook:**
- Un solo punto de animación: `.animation(isOverlayVisible ? .reveal : .dismiss, value:)`, y se quitan los dos `withAnimation`.
- Al ocultar, un `DispatchWorkItem` (tarea programada que se puede cancelar) de 150 ms, que se cancela si el mouse vuelve.
- La tolerancia va en la zona de **mantener abierta**: con la barra visible, `inKeepOpenZone` (:125) acepta `mouse.x >= frame.minX − 200`, y en vertical 100. `overshootSlack` (:25) se queda en 12: subirlo abriría la barra con el cursor sobre el Dock.
- Semáforos: animar su `alphaValue` con `animator()` y la misma curva, en vez de `isHidden` (KurthTopBarView.swift:437-443). Es código propio.
- Opcional, midiendo antes: dejar la barra montada y moverla con `.offset`, para no construirla en el primer cuadro.

**Esfuerzo:** S (M con el montaje persistente). **Riesgo:** bajo. Una gracia de más de 200 ms ya se siente como retraso. Con montaje persistente hay que probar que arrastrar una pestaña al borde siga abriendo la barra: SpacesSideBarView publica su frame en `NookDragSessionManager.shared.sidebarScreenFrame`.

**No rompe:** el overlay flota sobre la página, así que no provoca relayout (recalcular la posición y el tamaño) del WKWebView.

### 2.5 Apertura de la ventana
*(mov-02 ajustada)*

**Qué es.** Hoy la ventana aparece por partes: fondo, barra, tarjeta blanca (PageSession.swift:342 la pinta de blanco hasta el primer dibujo) y al final la página. Encima corre la animación por defecto de AppKit, porque nadie fija `NSWindow.animationBehavior`.

**De Zen.** El "watermark" (ZenStartup.mjs:117-156) deja todo el chrome en opacidad 0 salvo el fondo, y cuando la sesión está restaurada lo muestra todo junto en 0.1 s. Zen no escalona nada.

**En Nook.** Un `Nook/Kurth/KurthWindowIntro.swift` con una línea en WindowView. Corre solo en la primera aparición de cada ventana y solo con `didFinishOnboarding` (si no, se reproduciría invisible detrás del onboarding).
1. En t = 0 se ve el fondo; barra y tarjeta están en opacidad 0.
2. La barra entra de inmediato con `structural`.
3. La tarjeta entra **solo con opacidad** con lo primero que ocurra: `loadingState` llega a `.didCommit` o `.didFinish`, no hay página, o pasan 300 ms. El escalonado de 40 ms es diseño nuestro; lo de Zen tal cual es todo junto en 0.1 s.
4. Con Reducir movimiento: fundido de 0.12 s.

Además:
- Decidir `window.animationBehavior` en BackgroundWindowModifier (NookApp.swift:263-290): dejar la animación de AppKit o poner `.none`.
- Limpieza: TransitionView.swift:47-50 deja OnboardingView (con un material `.hudWindow`) montado a opacidad 0 en cada ventana, para siempre. Desmontarlo es seguro.
- Opcional: la señal de "primer dibujo no vacío" de WebKit (`_webView:renderingProgressDidChange:`) quita del todo el destello blanco. Es un método del navigation delegate, que vive en PageSession (NookWeb, upstream). No se puede condicionar con `responds(to:)`.

**Esfuerzo:** M. **Riesgo:** bajo-medio. En la tarjeta nada de `offset`: en la rama kurth, mover su frame dispara `KurthBarProbe → setBarRect → markWebViewsForLayout`, que marca **todos** los WKWebView de la ventana para relayout en cada cuadro. Opacidad y escala son transformaciones de capa (la GPU mueve la imagen ya dibujada, sin recalcular layout) y no pasan por ahí.

### 2.6 Apertura de la paleta ⌘T / ⌘L
*(mov-03 ajustada)*

**Qué es.** Es la apertura más frecuente del navegador, y aparece y desaparece de golpe: la opacidad cambia sin animación (CommandPaletteView.swift:295-296), aunque NookDesign.swift:133 le asigna `Motion.spring`.

**De Zen.** Al entrar en búsqueda por sitio hace un pulso de escala [1, 0.98, 1] en 0.25 s (ZenUIManager.mjs:451-475). La urlbar flotante lleva una sombra de `0 30px 140px -15px`.

**En Nook** (2 o 3 líneas `kurth:`):
- `.scaleEffect(isVisible ? 1 : 0.97, anchor: .top)` **solo** en el VStack de vidrio, no en el ZStack. El ZStack incluye el `Color.clear` que cierra la paleta al tocar.
- Opacidad con `.animation(isVisible ? .reveal : .dismiss, value: isVisible)` y `.allowsHitTesting(isVisible)`.
- Diferir la limpieza de `text`, `suggestions` y `activeSiteSearch` (CommandPaletteView.swift:318-323) hasta que termine `dismiss`, y cancelarla si se reabre antes. Sin esto, la tarjeta se encoge **vacía** al cerrar.
- El pulso de búsqueda por sitio con `keyframeAnimator` (ya pasó el typecheck).

**Esfuerzo:** S. **Riesgo:** bajo; la vista sigue montada y el foco no cambia.

## 3. Segunda y tercera tanda

El valor va de 1 a 5, como lo puntuó el investigador y lo corrigió el verificador.

### Segunda tanda

| Área | Cambio | Esf. | Valor | Lo que hay que saber |
|---|---|---|---|---|
| Temas | **Contraste derivado del tema** (temas-04) | M+ | 4 | Zen compone blanco α0.9 y negro α0.6 sobre el primario y gana el de mayor contraste según WCAG (la norma de contraste de accesibilidad). El texto es 80 % blanco o negro + 20 % primario, α0.9. Hay que calcularlo contra lo que realmente se ve, no contra el primario crudo como hace Zen. Se aplica en tres puntos: encabezado (WindowView.SpacesSidebar), la lista (que vive en un NSHostingView propio por Space, PlatformPageView+macOS.swift:275: fijar `pageController.view.appearance`) y el overlay de hover. |
| Temas | **Cruce de fondo al cambiar de Space** (temas-05, fase 1) | S | 4 | Dos capas, la anterior y la actual, con `.smooth(duration: 0.25)`, el equivalente del spring de 250 ms de Zen. Se puede ir de un tema de 2 colores a uno de 3. |
| Temas | **Crear un Space con tema** (temas-06) | S | 3 | El botón del diálogo marca "abrir al crear" en KurthThemeStore, y la capa Kurth abre el selector cuando cambia `spaceID`. El único gancho es SpaceCreationDialog.swift, que casi no se mueve. |
| Movimiento | **Pestañas que aparecen y se van** (mov-06) | S | 4 | Entran con opacidad, escala 0.95 y blur de 1 px en 0.12 s easeOut, y salen en 0.10 s. Hay que decidir las carpetas: hoy animan con `Motion.spring` (TabFolderView.swift:44) y esto lo pisa. |
| Movimiento | **Cambio de Space por clic que se desliza** (mov-04) | M | 4 | El crossfade de hoy sale de un `.id(...)` que reconstruye el pager. Existe porque `Coordinator.parent` es `let` y nunca se actualiza (PlatformPageView+macOS.swift:69). Primero `var parent` + `coordinator.parent = self`; después se deja de alternar el trigger. `runAnimationGroup` de 0.25–0.3 s con curva (0.2, 0.9, 0.25, 1). Probar con 2, 5 y 8 Spaces. |
| Movimiento | **Popup de zoom y toasts** (mov-08) | S + S/M | 3 | Zoom: subir el `.animation` al contenedor (WindowView.swift:97-111). Toasts: entran con escala 0.85 y salen con 0.9, con pausa al hover. Los temporizadores de CopyURLToast y TabClosureToast están en NookUI y no se pueden cancelar hoy. |
| Movimiento | **⌘S deslizando** (mov-09) | S | 3 | `Spring(settlingDuration: 0.12–0.15, dampingRatio: 1)`, **no** `structural`: cada cuadro cambia el ancho de la tarjeta y vuelve a disparar el relayout de todos los WKWebView. |
| Chrome | **Hairlines de 1 px físico donde se ven** (chrome-06) | S | 3 | `1/displayScale` con `.strokeBorder` solo en RowSelection dentro del vidrio (View+GlassEffect.swift:50) y en el favorito activo (PinnedTabView.swift:58). **Sin tocar** `hairlineWidth` ni `.raised` globales. |
| Chrome | **Fila seleccionada tipo chip** (chrome-05 + mov-12) | M | 4 | En tu modo la fila ya es un chip sólido. El cambio: sin hairline, acento al 2–5 %, sombra `0.15/0.05 r0.75 y0.8`, radio 10, hover al 7 % y escala de 0.985 al presionar con un ButtonStyle (el estilo que define cómo se dibuja un botón presionado), apagada durante el drag. Se controla con una Environment key. Limitarlo a macOS. |

### Tercera tanda

| Área | Cambio | Esf. | Valor | Lo que hay que saber |
|---|---|---|---|---|
| Temas / Mov. | **El color sigue al dedo en el swipe** (temas-05 f2 + mov-04 f2) | L | 4 | En Zen, la opacidad = 1 − \|offset\|/200. Hoy `trackSwipeHaptic` deja de acumular al 15 % e ignora el momentum (PlatformPageView+macOS.swift:92-97), así que hay que reescribir el acumulador. |
| Temas / Chrome | **Barra al hover con el tema** (temas-07 + chrome-04) | M | 3 | Contradice CLAUDE.md:233-235 (vidrio en capas flotantes), así que decides tú. Solo tinte y grano sobre base opaca (#e9e9e9 / #131313). **Nunca** el material behindWindow: dejaría ver el escritorio a través de la página. |
| Movimiento | **Peek que nace del enlace** (mov-07) | M / L | 4 | Nace en escala 0.2 anclada al Option-clic (con timestamp; si pasó más de 1 s, desde el centro). La página de atrás baja a 0.97 en lugar del telón negro. Hay que conservar una capa transparente para cerrar al tocar. |
| Chrome | **Semáforos monocromos** (chrome-09) | M | 3 | Solo con la barra visible. Sin ella, los discos caerían sobre tus botones de barra, atrás y recargar. |
| Movimiento | **Indicador de carga que respira** (mov-11) | S | 2 | Pulso 0.85↔0.95 solo en `.didStartProvisionalNavigation` y `.didCommit`: en `.idle` quedaría en bucle. Mantener los 8 pt de alto. |
| Movimiento | **El arrastre aterriza** (mov-13) | M | 2 | Animar la vista previa hasta la fila y después `orderOut`, sin ocultar la fila real. |
| Movimiento | **Barrido después de actualizar** (mov-14) | S | 2 | KurthUpdates bloquea Sparkle y no guarda versiones. Hace falta `KurthWhatsNew.swift` con el hash de git como clave. |
| Movimiento | Íconos vivos (mov-12) | S | 2 | `.symbolEffect(.bounce)` o `.drawOn` al hover. |
| Chrome | Halo del favicon (chrome-07) | S | ~0 hoy | No tienes favoritos. |
| Chrome | Asa discreta para redimensionar (chrome-08) | S | ~0 hoy | Solo existe con la barra fija. |

## 4. Motor: memoria y CPU

**Dónde está el margen:**
- WebKit ya suspende las pestañas que Nook saca de la ventana, **4 min** después de dejarlas. Suspender libera cachés y gráficos, pero conserva JS y DOM. Solo **descargar** libera el proceso WebContent completo: el proceso aparte donde corre cada página.
- El descargador de Nook deja fuera siempre fijadas, carpetas fijadas y favoritos (`isPinned` resuelve por la cadena de carpetas, TabTree.swift:71). Con uso tipo Arc casi no hace nada.
- El aviso de presión de Nook solo dispara cuando el nivel **cambia**. Tu Air hoy está en nivel 2 (advertencia) con 5.5 de 6.1 GB de swap: nunca llega el evento.
- Descargar hoy pierde historial, scroll y formularios (PageSession.swift:377-406, 324-327).

**La pregunta de fondo: ¿vives en fijadas o en carpetas fijadas?** Si sí, lo que mueve la aguja es aceptar que se descarguen solas, con motor-02 para no perder nada.

**Sin código, lo decides tú:**

| Cambio | Impacto | Costo |
|---|---|---|
| Ajustes > On Startup: "Last Tab Only" (motor-01) | Hoy solo precarga las pestañas normales del Space. Con tus 2, ahorra como mucho un proceso. | Esperar la carga al abrirlas. |
| `defaults write com.gstudios.nook DebugWebProcessSuspensionDelay -int 60` (motor-07) | Las ocultas sueltan cachés y gráficos a los 60 s y no a los 4 min (en YouTube, 133 MB de gráficos). No libera JS ni DOM. Se revierte con `defaults delete`. | WhatsApp Web, Gmail o Teams ocultos dejan de actualizarse antes. Que la clave exista en macOS 27 es inferencia: se comprueba con `/usr/bin/log`. Tú eliges 30, 60 o 120 s. |
| Encender el bloqueador con excepciones (motor-05) | Datos publicados sobre sitios de noticias, que no verifiqué: −44 % de carga (Kontaxis y Chew 2015) y 33–66 % menos memoria (Brave 2019, estudio propio del fabricante, en Chromium). En YouTube, poco. | Tiene su propio costo: el motor en el proceso de la app, un script en cada marco y hasta 2 s al arrancar. **Esconde los anuncios de Meta en el feed.** Excepciones desde el día uno: sitios de Grupo Ultra y Krei, facebook.com, instagram.com, ads.google.com y business.facebook.com. |

**Con código, en este orden:**

| # | Cambio | Impacto | Esf. | Riesgo |
|---|---|---|---|---|
| motor-02 | Guardar `interactionState` (el Data de WKWebView con historial, scroll y formularios) al descargar y restaurarlo al volver. | 0 MB directo, pero quita el costo de descargar y habilita todo lo demás. | S-M (1–1.5 días) | En macOS, restaurar acepta HTML viejo del caché (FrameLoader.cpp:4783-4791). Mitigación: guardar la hora y hacer `reload()` si la respuesta es anterior. Probar noticias, Gmail, POST y el scroll con los 40 pt de inset. En privadas, el estado vive solo en memoria. |
| motor-04 | Que el video mudo ya no exima de la descarga (:180 y :195). | Entran las pestañas ocultas con video silenciado, como en Firefox. | S | Bajo. |
| motor-09 | Descargar este Space, los otros o una carpeta. | Hoy es la única forma de liberar fijadas en bloque. | S | Bajo. Usar `items(inSpace:)`. |
| motor-03 | `KurthMemoryWatcher.swift`: leer `kern.memorystatus_vm_pressure_level` con sysctl (lectura de una variable del kernel). Mientras sea ≥ 2, cada 10–30 s descargar **una** pestaña oculta con 10 min o más sin uso, la de mayor `physicalFootprint` (SPI `_webContentProcessInfo`; SPI es API privada de Apple, llamada solo si `responds(to:)`). | Cada vuelta libera el proceso completo de la más pesada. | M | Es política propia, no "como Firefox". Incluye fijadas (decides tú si pesan ×2 o entran solo en nivel crítico). Una semana en modo solo registro antes de encenderlo. Requiere motor-02. |
| motor-01 p2 | "Last Tab Only" por defecto con 8 GB o menos, y un tope de pestañas en Standard. | Acota el peor caso. | S | El tope no toca fijadas. |
| motor-06 | `_setInvisibleAutoplayNotPermitted:` | Solo afecta a `<video autoplay>` fuera de vista. No toca YouTube ni los feeds. | S | Valor 2. |
| motor-08 | Detectar audio por KVO (observación de propiedades de Objective-C) de `_isPlayingAudio` y quitar el MutationObserver de PiP (el aviso de JS por cada cambio del DOM). | Solo CPU, sin medir. | S | Conservar el observer de medios o el estado de audio se queda pegado. |
| motor-10 | Vaciar el caché de procesos de WebKit. | Probablemente nulo: bajo presión WebKit no cachea, y hoy no hay ninguno. | S | Medir primero con `lsappinfo`. |

## 5. Lo que no se puede traer, y la alternativa

| De Zen | Por qué no | Alternativa |
|---|---|---|
| Gecko: procesos, WebRender, recolector de basura, cachés | Nook es WebKit, y Zen tampoco ajusta nada de eso. | motor-02 y motor-03, más los ajustes de WebKit de la sección 4. |
| TabUnloader de Firefox tal cual | En Firefox estable para Mac no descarga por presión. | motor-03 como política propia. |
| `mediaController` de Gecko | Es API de Gecko. | KVO de `_isPlayingAudio` (motor-08). |
| `corner-shape: superellipse(1.3)` | SwiftUI no expone una superelipse con exponente configurable. | `RoundedRectangle(style: .continuous)` y ConcentricRectangle. |
| El radio "nativo" de Zen (11 px fijo en Tahoe) | Es una suposición, no la esquina real. | ConcentricRectangle resuelve contra la ventana real (16). |
| `grain-bg.png` | Es un binario bajo MPL. | `noise_texture` de Nook a 0.124 × grano. |
| Material behindWindow en capas flotantes | Ignora el contenido de la ventana: se vería el escritorio a través de la página. | Tinte y grano sobre una base opaca. |
| Motion, la librería JS de animación de Zen | Es JS. | `Spring(settlingDuration:dampingRatio:)`, que resuelve la misma ecuación. |
| El resorte dentro de NSPageController | `NSAnimationContext.animate` solo pasa la duración. | `runAnimationGroup` con la curva explícita. |

## 6. Riesgos generales

- **Rebase** (volver a aplicar la rama kurth encima de cada versión nueva de upstream):
  - Los archivos calientes son SpacesSideBarView (cambia casi a diario), WindowView y NookDesign.swift (tres commits esta semana cada uno).
  - Regla: la lógica vive en `Nook/Kurth/`; en upstream, solo ganchos de una línea; ningún token global.
  - NookDesign y NookUI también los usa NookiOS (9 archivos): un cambio ahí viaja al iPhone.
- **Deshacer decisiones de upstream.** El material translúcido revierte 60d0d34, y el editor de degradados se borró a propósito (92ef7db). Por eso todo va en Nook/Kurth y lo translúcido es opcional.
- **SPI privada.** Siempre condicionada con `responds(to:)` y con una ruta pública de respaldo. Los selectores de motor están confirmados en macOS 27. Los métodos de delegate no se pueden condicionar así. Las claves `Debug*` de WebKit pueden desaparecer; si pasa, se vuelve a los 4 min sin romper nada. Evitar el pool propio de motor-07: `WKProcessPool` está deprecado.
- **Rendimiento en la Air de 8 GB con swap.** Animar con opacidad y escala, no con frames ni offsets. No agrandar la sombra del grupo del WKWebView. Medir con Instruments (Animation Hitches, FPS, Energy) el material translúcido, el montaje persistente de la barra y ⌘S antes de dejarlos encendidos.
- **El clon no es tu Zen instalado.** 4c92731 (main) no es 1.22.3b: la sombra de la página solo está en el instalado. Todo valor "de Zen" se coteja con el omni.ja instalado. El clon real ahora está en `scratchpad/zen-motor`, y los prototipos de `/tmp` se perdieron con el reinicio.
- **Documentación desactualizada.** El CLAUDE.md de Nook se contradice: la línea 233 dice que la barra lateral usa `BlurEffectView(.sidebar)`, y la 236 y el código dicen que ya es el degradado. La 236 además dice que se persiste un SpaceGradient, y ya no. Hay que corregirlo en su lugar cuando se pueda tocar el repo.
- **Nada corrió en pantalla todavía.** Falta verificar el vidrio de la fila sobre material, que el esquema de color cruce el NSHostingView de la lista, el radio concéntrico dentro del overlay y el scroll restaurado con el inset.

## Decisiones que son tuyas

1. "Apertura": cubrí ventana, paleta y barra lateral. Si pensabas en otra, dime cuál.
2. Una captura con zoom de la esquina para cerrar 2.2.
3. Base del tema: "Opaco" o "Translúcido" (después de medir).
4. Barra al hover: vidrio o tema.
5. ¿Fijadas que se descargan solas? Con motor-02 regresan igual.
6. Bloqueador contra ver los anuncios de Meta en el feed.
7. Retraso de suspensión: 30, 60 o 120 s.

## Refutadas

Ninguna propuesta salió refutada. Sí cayeron estas premisas dentro de las ajustadas:
- "Firefox/Zen descargan pestañas por presión en Mac": falso en la versión estable.
- "El material de fondo tapa el huequito": no hay mecanismo; el hueco sale de la barra al hover con radio 12 y margen 8.
- "Zen no pone sombra a la página": falso en tu Zen instalado.
- "Upstream quitó un blur .withinWindow, así que el material sale gratis": quitó el behindWindow, y por costo.
- "`.raised` en (0.12, r0.75, y0.8) quita el trazo": lo oscurece 2.4 veces, y el token lo usan la página, los diálogos y PiP.
- "`hairlineWidth` global a 0.5": adelgaza la onda del separador y el recuadro de favoritos.
- "Subir `overshootSlack` a 40": abriría la barra con el cursor fuera de la ventana.
- "InvisibleAutoplayNotPermitted frena YouTube y los feeds": solo aplica a `<video autoplay>`.
- "`register(defaults:)` enciende el bloqueador": NookSettingsService lo pisa (:421).
- "NookDragSourceView recibe mouseDown" y "KurthUpdates guarda versiones": ninguna de las dos es cierta.