#!/bin/zsh
# Prueba los workflows sin abrir Nook: el modelo (KurthWorkflowsModelo.swift: uniones de pasos,
# secretos, texto para el agente, programación, lectura del resultado, tienda en disco) y el grabador
# (KurthGrabadora.js) en un WKWebView sin ventana con workflows.html. No toca la app instalada ni
# sus datos: la tienda se prueba en una carpeta temporal.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/workflows
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthWorkflowsModelo.swift" \
  "$REPO/Nook/Kurth/KurthWorkflowsReplayModelo.swift" \
  "$REPO/kurth/checks/workflows.swift" \
  -o "$SALIDA"
"$SALIDA" "$REPO"
