# Pendientes de Nook (rama kurth)

Una sola lista para las dos Macs. Quien avance, la actualiza en el mismo commit.
Detalle de Zen en `kurth/plan-zen.md`.

## El cel (Remote Control) — 25 sep noche, instalado

Botón a la derecha del de permisos (`KurthRemoto.swift`, `KurthRemotoPopover.swift`, MCP
`kurth_remote_control` on/off/status): abre la conversación del panel con `--resume` y
`--remote-control` en un pseudo-terminal oculto, contesta los diálogos de arranque, pide la URL con
`/remote-control` y enseña el QR. Verificado por MCP: conecta en ~6 s, "Remote Control is active", el
agente contesta lo que se le manda por el pseudo-terminal. Kurth: el QR abre la app pero no brinca a
la sesión; hay que ir a Code › Nook (falta que confirme que sí aparece).
- **Hallazgo que cambia el diseño:** con Remote Control conectado, Claude Code guarda la conversación
  en los servidores de Anthropic y NO en el .jsonl local (doc + medido con cierre por señal y con
  /exit). Consecuencias: (1) no se puede pintar en el panel lo del cel leyendo el archivo; (2) al
  apagar el cel, el panel retoma la conversación como estaba ANTES del cel (`claude --resume` tampoco
  la trae). Hoy la caja queda pausada con el cel encendido.
- **Propuesta para bidireccional:** con el cel encendido, el panel muestra la terminal de esa sesión
  (SwiftTerm, MIT, headless o con vista) y la caja escribe en ella; se ven las dos direcciones sin
  raspar la pantalla. `KurthRemoto.enviar`/`interrumpir` ya escriben al pseudo-terminal. Esperar OK.
- Nook mantiene la Mac despierta mientras está encendido (beginActivity); con la tapa cerrada no.

## Al cerrar el 25 sep (José) — seguir en la Pro el fin

**Esperan su OK:**
- **Transición de las barras fijas.** Hoy comprimen la página y WebKit reacomoda el texto en cada
  cuadro (tiembla). Probé que entraran *encima* de la página y la página se ajustara al final: "se
  siente bien feo" (dos tiempos), revertido sin commit. Propuesta: que la barra **empuje** la
  página en un solo movimiento con el acomodo congelado (`_setFixedLayoutSize:` existe en su WebKit;
  `_setUseFixedLayout:` no, falta ver con qué se activa) y un fundido de 0.15 s al ajustarse. Otra
  opción: la página cambia de golpe y solo la barra entra con fundido. Para probar: MCP `kurth_panel`.
- **Cuadrícula:** buscar escribiendo y "cerradas recientemente" (`reopenLastClosed` ya existe).
- **Material de las barras:** el ◐ del encabezado del agente es temporal; quitarlo cuando elija
  vidrio o clásico (también está en Settings › Appearance).
- underPageBackgroundColor con el tema: "por ahora no".
- ✅ **Hecho el mismo 25 sep (`KurthAccesos`), falta que Kurth lo pruebe con clics:** el indicador es el
  resaltado de siempre, arriba y abajo a la vez (no puntito). Lo de abajo era la propuesta.
- **Favoritos y guardados como accesos rápidos (idea de Kurth al irse):** tocarlos abre (o lleva a)
  una pestaña normal abajo, en las del día; ellos nunca se "abren". Así todo lo que consume memoria
  se ve en una sola lista (el error de Arc que señaló). Propuesta de José: si ya hay una pestaña
  abierta desde ese acceso, llevar a ella en vez de abrir otra; un puntito bajo el acceso mientras
  su pestaña está abierta, como el Dock. Se pierde que el favorito guarde su propio estado aparte
  (los logins no: son por Space). Toca `TabsController.select` o los clics de favoritos y de
  SpaceTab. Ya hecho mientras tanto: la tira solo muestra favoritos y guardados abiertos (`3bab2034`).

**Instalado y sin probar con su mouse o trackpad:** deslizar la cápsula entre pestañas, pellizco a
la cuadrícula, reordenar arrastrando en la cuadrícula, recorte de Señalar con texto (miniatura en el
chip), y la franja de Robb Report con el color por votos (en una medición con scroll daba negro por
una línea en la orilla; ya muestrea 8 px adentro, falta verlo).

**Otros:** rutinas (diseño hablado, sin construir); "instalar apps" (recomendé el Agregar al Dock de
Safari); limpiar las reglas "permitir siempre" viejas de ~/.claude/settings.local.json (traen un
token de TickTick; necesita su OK).

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

## Señalar (24 sep) — instalado, falta que Kurth pruebe el modo caja

Cajas libres (⌘⇧M), selección como chip, marcas del agente (highlight, point_to,
clear_highlights) con chips 📍, persistencia por dirección. Verificado: marcas del agente con nota,
anillo de guía y que las guardadas vuelven al abrir la página. **No probado con el mouse:** el
modo caja (arrastrar → recorte + texto + elementos → chip → mensaje con imagen). Diseño en
kurth/diseño-señalar.md.

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
  `select` nativo (el menú es modal); la SPI de agentes de WebKit ya está (page_text y act, 25 sep, `28890ed`): lee solo pestañas a la vista; filtros de WebKit apagados por defecto (el clasificador quitaba contenido legítimo).

## Contraseñas de Apple (24 sep noche) — instalado, falta que Kurth pruebe con Touch ID

`Nook/Kurth/KurthPasswords.swift` + `KurthPasswords.js`: llave dentro del campo de usuario o contraseña
con foco → campos nativos invisibles encima → AppKit dibuja "Passwords…" (vive en una `SPRoundedWindow`
propia, sin subvistas; se le manda un clic sintético en proceso) → Touch ID → el sistema llena los
nativos → se escriben en la página (setter nativo + input/change). La credencial se recuerda 2 min por
host para el paso 2 de Google. Ajuste `kurth.passwords`; diagnóstico en `kurth_passwords_status`.
- Verificado por MCP: llave visible, petición abierta, ventana del botón encontrada y, tras el clic, la app
  pierde la activación (el panel del sistema la toma). **No verificado:** el llenado tras Touch ID (José
  no tiene huella); probar en Gmail. Si el sistema no llena el campo de usuario, ver el orden de los
  campos nativos.
- Por qué no la extensión oficial: su ayudante tiene un launch constraint (lista de navegadores de Apple
  o entitlement `web-browser.public-key-credential`). Ese mismo entitlement daría passkeys en WKWebView
  (camino B: formulario de Apple, App ID propio + perfil; no exige App Store).
- Arreglo de paso: los user scripts de Señalar y de contraseñas llevan el prefijo "// Nook" (los tweaks
  vacían los scripts en cada navegación y solo reponen los marcados); Señalar no restauraba marcas al cargar.
- Pendiente: passkeys (solo con el entitlement); guardar contraseñas nuevas; iframes de login.

## Hecho el 24 sep

- ✅ Guardados como Arc: la sección de fijadas siempre a la vista (vacía: "Arrastra aquí lo que
  quieras guardar", se acorta según el ancho); las carpetas solo viven ahí (createFolder y move en
  TabsController); al arrancar suben las que hayan quedado abajo (KurthGuardados.swift). Falta que
  Kurth lo pruebe arrastrando y cerrando una guardada.

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

## iCloud — por iCloud Drive, no CloudKit (Kurth, 24 sep)

CloudKit obligaba a cambiar el identificador de Nook (com.gstudios.nook es del equipo de upstream)
y migrar sesiones (454 MB de WebKit), ajustes y permisos. Se eligió iCloud Drive: KurthSync.swift.
- ✅ Fase 1 (24 sep): Spaces, favoritos, fijadas, carpetas, temas y ajustes. Cada Mac escribe solo
  su archivo en iCloud Drive/Nook/Sync/<id>.json; gana el cambio más reciente por registro; los
  borrados viajan 30 días. Primera vez: mismo nombre de Space = mismo Space; misma dirección en el
  mismo lugar = misma fijada (alias). Probado con una Mac simulada: alta, alias sin duplicar y
  borrado (en ≤ 15 s aunque el archivo se sobrescriba en su lugar). **Con la Pro (24 sep noche):** la Pro
  instalada con `089f30a3` exporta su archivo y ya importa el de la Air (`kurth_sync_status`: otrasMacs =
  "MacBook Air de admin (2)", alias 0). Falta que Kurth vea que Spaces y favoritos quedaron bien en las dos.
- Ajustes de apariencia (kurth.*) al instante; los de la ventana de Ajustes al reabrir Nook.
- Diagnóstico: kurth_sync_status y kurth_sync_now en el MCP.
- Fase 2: historial (por meses, en archivos aparte).
- Nunca la base de datos en una carpeta de iCloud Drive.

## Zen

motor-02 → motor-03 (memoria), temas-04 (contraste del texto según el tema), chrome-05, mov-06,
mov-04, mov-08, mov-09, chrome-06.
