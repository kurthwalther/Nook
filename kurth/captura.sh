#!/bin/zsh
# Captura la ventana principal de Nook: kurth/captura.sh <salida.png> [ancho] [alto-a-recortar-desde-arriba]
set -e
WID=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const l=ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0,0)); let best=0,area=0; for (let i=0;i<l.count;i++){const w=l.objectAtIndex(i); if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName"))==="Nook" && ObjC.unwrap(w.objectForKey("kCGWindowLayer"))===0){const b=w.objectForKey("kCGWindowBounds"); const a=ObjC.unwrap(b.objectForKey("Width"))*ObjC.unwrap(b.objectForKey("Height")); if(a>area){area=a;best=ObjC.unwrap(w.objectForKey("kCGWindowNumber"))}}}; best')
screencapture -x -o -l "$WID" "$1"
sips -Z ${2:-2000} "$1" >/dev/null
if [[ -n ${3:-} ]]; then
  H=$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')
  W=$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')
  sips -c "$3" "$W" --cropOffset 0 0 "$1" >/dev/null 2>&1 || true
fi
