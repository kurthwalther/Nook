#!/bin/zsh
# Prueba KurthAutoconsent (autoconsent de DuckDuckGo) en un WKWebView sin ventana, contra páginas
# locales que imitan banners de OneTrust y Didomi. No abre Nook ni toca sus datos.
set -euo pipefail
REPO=${0:A:h:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
SALIDA=$(mktemp -d)/autoconsent
xcrun swiftc -O -D KURTH_CHECK -parse-as-library "$REPO/Nook/Kurth/KurthAutoconsent.swift" "$REPO/kurth/checks/autoconsent.swift" -o "$SALIDA"
"$SALIDA" "$REPO"
