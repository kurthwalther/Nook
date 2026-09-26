#!/bin/zsh
# Prueba KurthLinksExternosModelo sin abrir Nook: qué links web se abren en su app (Zoom, Teams,
# Spotify, WhatsApp) y cuáles se quedan para el navegador. No toca la app instalada.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/links
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthLinksExternosModelo.swift" \
  "$REPO/kurth/checks/links.swift" \
  -o "$SALIDA"
"$SALIDA"
