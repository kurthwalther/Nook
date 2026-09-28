#!/bin/zsh
# Prueba KurthZoom sin abrir Nook: pasos de 10 %, límites y redondeo. No toca la app instalada.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/zoom
xcrun swiftc -O -parse-as-library "$REPO/Nook/Kurth/KurthZoom.swift" "$REPO/kurth/checks/zoom.swift" -o "$SALIDA"
"$SALIDA"
