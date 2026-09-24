# Pendientes de Nook (rama kurth)

Una sola lista para las dos Macs. Quien avance, la actualiza en el mismo commit.
Detalle de Zen en `kurth/plan-zen.md`.

## Para mañana (25 sep)

1. **Sonido de error en el chat** — sigue sonando; mi teoría del campo desactivado era falsa.
   `KurthBeepProbe` (temporal) intercepta `noResponderFor:`: hasta las 10:53 no hubo ningún
   keyDown sin destinatario (solo keyUp y mouse, que no suenan). Si vuelve a sonar, viene de un
   NSBeep directo. Siguiente paso: depurador con `get-task-allow` en nuestro build (en la Air
   SIP está activo) y `b NSBeep`, o interceptar NSBeep. Pedirle a Kurth que diga cuándo suena.
2. **Verificar con Kurth:** el agente responde "¿qué estamos viendo?" con la pestaña activa
   (se manda como `resource_link`), y la caja de texto ya no se sale del panel.
3. Guardar la conversación del chat al cerrar Nook.
4. Memoria (Zen motor-02 → motor-03), después iCloud fase 1.

## Copiloto en el navegador (24 sep) ✅

Herramientas nuevas del MCP (KurthCopilot.swift + KurthCopilot.js + KurthDialogs.swift), todas con
`tabId`: snapshot (foto con @e1…), click, type_text, press_key, hover, scroll, select_option,
handle_dialog, run_js, read_page (Defuddle 0.19.4, MIT, en Nook/Kurth/Vendor), list_tabs, open_tab
(en segundo plano por defecto), navigate_tab, close_tab. clickElement y getInteractiveElements se
esconden del MCP (las reemplazan).
- **Nativo** (pestaña a la vista): NSEvent directo a mouseDown/mouseUp del WKWebView, escritura con
  `_executeEditCommand:InsertText`, hover con `_simulateMouseMove:`. Verificado en una página local
  con React 18: click, hover y tecla con isTrusted=true, onChange de React, diálogo cancelado.
- **JavaScript** (pestaña sin ventana): verificado igual en segundo plano, incluido React y el
  diálogo aceptado. La pestaña del agente sin ventana se crea a 1280×800.
- Un diálogo detiene el JS de la página: las acciones esperan "lo primero que pase" y avisan.
- Pendiente: eventos nativos en segundo plano (necesitan una ventana invisible, como Bun.WebView);
  `select` nativo (el menú es modal); evaluar la SPI de agentes de WebKit (`_performInteraction:`,
  `_extractDebugTextWithConfiguration:`), macOS 26.4+. Informe del Researcher del 24 sep.

## Hecho el 24 sep

- ✅ Sin pestañas: "Ah, peace.", barra lateral a la vista y la URL lista para escribir (`bf01f69`).
- ✅ Modelo, esfuerzo, permisos y rápido en el chat del agente (`b12f15b`).
- ✅ Barra lateral flotante con el mismo material que la fija (`865b4dc`) y redimensionable (`42e7f34`).
- El agente recibe la pestaña activa con cada mensaje; el menú de modelo ya no desborda la caja
  (instalado, falta que Kurth lo vea).

## Agente (chat lateral por ACP)

- ✅ Arranque 15.7 s → 4.7 s (sync en paralelo, kurth-team `8cff6e5`).
- ✅ Se apaga 30 s después de cerrar el último panel y retoma la sesión (`b37011a`). Probado
  por Kurth el 24 sep.
- ✅ Arranca desde el Finder: PATH del shell de inicio de sesión (`8f8dcd6`).
- Guardar la conversación visible entre reinicios de Nook (el contexto ya se puede retomar con
  `session/resume`; lo que se pierde es lo que se ve).
- Pintar el razonamiento.
- Pestaña propia del agente: hoy el MCP actúa sobre la pestaña seleccionada y te interrumpe.
- Comentarios anclados a la página.
- Tareas en segundo plano.
- Detalle: `kurth_get_settings` reporta el override del vidrio como 1 cuando está en automático.

## iCloud (CloudKit, cuenta de desarrollador de paga)

- Fase 1: favoritos, Spaces, fijadas, carpetas, temas y ajustes (`CKSyncEngine`).
- Fase 2: historial (SwiftData tiene 6 `@Attribute(.unique)` que CloudKit no acepta).
- Nunca la base de datos en una carpeta de iCloud Drive.

## Zen

motor-02 → motor-03 (memoria), temas-04 (contraste del texto según el tema), chrome-05, mov-06,
mov-04, mov-08, mov-09, chrome-06.
