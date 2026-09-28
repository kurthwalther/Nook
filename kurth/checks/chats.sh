#!/bin/zsh
# Prueba KurthChatsModelo sin abrir Nook: el título que sale del primer mensaje y la hora corta de
# cada fila de la lista de conversaciones. No toca la app instalada.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/chats
xcrun swiftc -O -parse-as-library \
  "$REPO/Nook/Kurth/KurthChatsModelo.swift" \
  "$REPO/kurth/checks/chats.swift" \
  -o "$SALIDA"
"$SALIDA"
