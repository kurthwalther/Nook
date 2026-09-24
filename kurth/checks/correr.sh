#!/bin/zsh
# Compila el cliente ACP que sí se envía, junto con su verificación, y lo corre de verdad.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/acpcheck
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthACPClient.swift" \
  "$REPO/kurth/checks/KurthACPCheck.swift" \
  -o "$SALIDA"
"$SALIDA"
