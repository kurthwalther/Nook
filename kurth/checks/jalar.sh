#!/bin/zsh
# Prueba KurthJalarParaRecargar con gestos sintéticos en un WKWebView sin ventana. No abre Nook.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/jalar
xcrun swiftc -O -parse-as-library "$REPO/Nook/Kurth/KurthJalarParaRecargar.swift" "$REPO/kurth/checks/jalar.swift" -o "$SALIDA"
"$SALIDA"
