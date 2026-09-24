# Pendientes de Nook (rama kurth)

Una sola lista para las dos Macs. Quien avance, la actualiza en el mismo commit.
Detalle de Zen en `kurth/plan-zen.md`.

## Ahora

1. **Página sin pestañas** (bug visual, Kurth 24 sep): sin pestañas, el área de la página queda
   transparente con "Ah, peace." y la barra muestra atrás/recargar sin página. Propuesta: la
   tarjeta de página de siempre con un buscador al centro, y en la barra solo lo que sirve sin
   página (sidebar y chat). Espera OK de Kurth.
2. **Modelo y esfuerzo en el panel del agente**, como el CLI. El adaptador los da en
   `configOptions` de `session/new`: mode (default/acceptEdits/plan/auto/bypassPermissions),
   model (default, opus[1m], claude-fable-5-1[1m], sonnet, haiku), effort
   (default/low/medium/high/xhigh/max), fast (on/off). Se cambian con
   `session/set_config_option`.

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
