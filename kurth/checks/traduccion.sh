#!/bin/zsh
# Prueba KurthTraduccion.js y KurthTraduccionLotes.swift en un WKWebView sin abrir Nook, con un
# traductor falso (mayúsculas). No toca la app instalada ni descarga idiomas.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/traduccion
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthTraduccionLotes.swift" \
  "$REPO/kurth/checks/traduccion.swift" \
  -o "$SALIDA"
"$SALIDA" "$REPO"
