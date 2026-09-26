#!/bin/zsh
# Prueba el replay exacto de workflows sin abrir Nook: graba con KurthGrabadora.js sobre
# replay/original.html y repite con el bucle real (KurthWorkflowsReplayModelo.swift) y el localizador
# real (KurthCopilot.js + KurthReplay.js) contra la misma página y contra replay/cambiado.html servida
# en la misma dirección. No toca la app instalada ni sus datos (las páginas van a una carpeta temporal).
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/replay
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthWorkflowsModelo.swift" \
  "$REPO/Nook/Kurth/KurthWorkflowsReplayModelo.swift" \
  "$REPO/kurth/checks/replay.swift" \
  -o "$SALIDA"
"$SALIDA" "$REPO"
