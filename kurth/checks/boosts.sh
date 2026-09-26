#!/bin/zsh
# Prueba los Boosts (KurthBoostsModelo.swift) en un WKWebView sin abrir Nook. No toca la app
# instalada ni sus datos.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/boosts
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthBoostsModelo.swift" \
  "$REPO/kurth/checks/boosts.swift" \
  -o "$SALIDA"
"$SALIDA"
