#!/bin/zsh
# Prueba KurthCopilot.js (snapshot, delta, find, fill_form, iframes, shadow DOM) en un WKWebView
# sin abrir Nook. No toca la app instalada ni sus datos.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/copiloto
xcrun swiftc -O "$REPO/kurth/checks/copiloto.swift" -o "$SALIDA"
"$SALIDA" "$REPO"
