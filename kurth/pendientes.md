# Pendientes de Nook (rama kurth)

Una sola lista para las dos Macs. Quien avance, la actualiza en el mismo commit.
Detalle de Zen en `kurth/plan-zen.md`.

## Ahora

1. **Página sin pestañas** — hecho, falta que Kurth lo vea: "Ah, peace." de vuelta, la barra
   lateral se queda a la vista aunque esté oculta, y el espacio de la URL es un campo listo para
   escribir. Sin página, la barra ya no muestra atrás ni recargar. (Kurth descartó la tarjeta
   con buscador al centro.)
2. ✅ **Modelo y esfuerzo en el panel del agente** (`b12f15b`): menú "Opus 5.5 · xhigh" con
   modelo, esfuerzo, permisos y rápido; se recuerdan salvo los permisos.
3. **Sonido de error al enviar en el chat** — arreglo instalado (`b12f15b`, el campo ya no se
   desactiva a media pulsación); falta que Kurth confirme que ya no suena.

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
