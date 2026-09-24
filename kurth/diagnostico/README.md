# Diagnóstico visual (rama kurth)

Herramientas para medir la transparencia y el difuminado de la ventana sin tocar el cursor.
Compilar cada una con `swiftc -O <archivo>.swift -o <nombre>`.

- `rojo <windowNumber> x y w h` — ventana roja sin borde, justo DEBAJO de esa ventana, 2.2 s.
  Mide cuánto deja pasar: compara un punto con y sin rojo. Así se midió Superconductor
  (sidebar #F8F8F9 al 76 %) y el material .sidebar de Apple (~6 %).
- `rayas <windowNumber> x y w h [segundos]` — rayas negras/blancas de 12 pt debajo de la ventana.
  Si se ven rayas a través: transparencia literal. Si sale un gris parejo: hay difuminado.
- `strip <png> <x>` — colores de una columna (16 muestras). `hline <png> <y> <x0> <x1>` — canal
  verde a lo largo de una fila, cada 6 px (para ver si las rayas llegan).

El número de ventana y su marco salen de CGWindowListCopyWindowInfo (ver `nookwin` en el
historial de la bitácora del 23 sep), y la captura con `screencapture -x -R x,y,w,h`.
Con la pantalla bloqueada las capturas salen negras.
