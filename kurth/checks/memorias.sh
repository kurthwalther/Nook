#!/bin/zsh
# Prueba las Memorias de Nook sin abrir Nook (KurthMemoriasModelo.swift): guardar, fusionar duplicados,
# rechazar secretos, buscar por texto y por host, tienda en disco, memoria de workflow y mezcla con otra
# Mac. No toca la app instalada ni sus datos: la tienda se prueba en una carpeta temporal.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/memorias
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthMemoriasModelo.swift" \
  "$REPO/kurth/checks/memorias.swift" \
  -o "$SALIDA"
"$SALIDA"
