# Señalar — Kurth y el agente se apuntan cosas en la página

Pedido de Kurth (24 sep): como los comentarios de los Artifacts, pero en cualquier página y en los
dos sentidos. Él señala algo y el agente entiende exactamente qué; el agente le señala algo
("aquí dice que no acepta American Express") y él lo ve marcado.

## La pieza común: el ancla

Cómo se describe un pedazo de página para que los dos lo encuentren, aunque la página se recargue
o cambie un poco. Es el modelo de W3C Web Annotation que usa Hypothesis:

- `TextQuoteSelector`: el texto exacto + ~32 caracteres antes y después (para desempatar).
- `TextPositionSelector`: posición en el texto de la página (atajo cuando nada cambió).
- Si es un elemento: su referencia del snapshot (@eN), rol y nombre, y un selector CSS.
- Dirección de la página.

Re-anclar: buscar el texto exacto; si aparece varias veces, gana el que coincide con antes/después.

## Tú → agente

1. **Seleccionas texto** y aparece una pastilla "Preguntar" junto a la selección. Además, si al
   escribir en el chat tienes texto seleccionado, entra solo como chip ("Sobre: «…»") con una ×.
2. **Elementos** (botón, precio, imagen): ⌥-clic los señala con un contorno y los agrega como chip.
3. El agente recibe el ancla completa + un recorte de captura de esa zona (sirve para imágenes).

## Agente → tú

1. Herramienta `highlight` {tabId, ref | texto, nota?}: resalta texto o un elemento, hace scroll
   hasta ahí y, si hay nota, pone una etiqueta junto. Devuelve un id de marca.
2. En su respuesta, "aquí" va como enlace `kurth-marca:<id>`: en el chat es un chip 📍 que al
   tocarlo lleva a la marca y la hace destellar (se intercepta en el openURL del panel).
3. Modo guía (`point_to`): anillo que pulsa sobre donde debes dar clic, sin que el agente lo haga.

## Cómo se pinta sin romper la página

- **Texto:** API de resaltado de CSS (`new Highlight(range)` + `CSS.highlights` +
  `::highlight(nombre)`). No toca el HTML de la página ni rompe React. Verificado en WebKit 27.
- **Contornos, notas, pastilla y pines:** una capa propia dentro de un shadow root cerrado, en
  coordenadas del documento (se mueve con el scroll sola). La página no la puede estilizar ni leer.
  Solo la pastilla y los pines reciben clics.
- Colores distintos: lo del agente en ámbar, lo de Kurth en azul.
- Alternativa nativa ya disponible: fragmentos de texto (`#:~:text=`), verificado en WebKit 27.
  Sirve de respaldo para "llévame a este texto" sin inyectar nada.

## Fases

1. Agente → tú: `highlight`, chips 📍 en el chat, limpiar marcas. ~1 día.
2. Tú → agente: selección → pastilla y chip; ⌥-clic en elementos; ancla + recorte al agente. ~1–1.5 días.
3. Comentarios que se quedan: pines por página que reaparecen al volver (re-anclaje), lista en el
   chat. ~1–2 días.
4. Modo guía. ~0.5 día.

## Decisiones de Kurth

- Por dónde empezar (recomendado: fase 1, es independiente y se usa de inmediato).
- Disparador para elementos: ⌥-clic, o un modo "señalar" con contorno al pasar el mouse.
- ¿Las marcas del agente se borran solas al seguir la conversación, o se quedan hasta limpiarlas?
