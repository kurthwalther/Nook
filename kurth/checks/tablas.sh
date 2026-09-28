#!/bin/zsh
# Prueba KurthMarkdownTablas sin abrir Nook: qué se vuelve tabla y qué se queda como texto.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/tablas
xcrun swiftc -O -parse-as-library "$REPO/Nook/Kurth/KurthMarkdownTablas.swift" "$REPO/kurth/checks/tablas.swift" -o "$SALIDA"
"$SALIDA"
