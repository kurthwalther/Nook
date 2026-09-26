#!/bin/zsh
# Prueba KurthExtensionesModelo sin abrir Nook: qué publica una Mac de sus extensiones, qué hace la otra
# con eso, que nada rebote ni reviva un borrado. No toca la app instalada.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/extensiones
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthExtensionesModelo.swift" \
  "$REPO/kurth/checks/extensiones.swift" \
  -o "$SALIDA"
"$SALIDA"
