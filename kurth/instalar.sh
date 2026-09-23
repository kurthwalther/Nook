#!/bin/zsh
# Compila la rama actual, cierra Nook (guarda pestañas), instala y lo vuelve a abrir.
# Uso: kurth/instalar.sh [--sin-abrir]
set -euo pipefail

REPO=${0:A:h:h}
DD=~/Library/Developer/Xcode/DerivedData/Nook-kurth   # fuera de ~/Documents: iCloud rompe codesign
APP=$DD/Build/Products/Release/Nook.app
IDENTIDAD=7878A148379AF0DCC33F248744CD43BDAA8DC56C    # Apple Development de Kurth, equipo VRFY7KFRYP
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Downloads/Xcode-beta.app/Contents/Developer}

cd $REPO
inicio=$(date +%s)
xcodebuild -scheme Nook -configuration Release -arch arm64 -derivedDataPath $DD \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=VRFY7KFRYP CODE_SIGN_IDENTITY=$IDENTIDAD \
  CODE_SIGN_ENTITLEMENTS="$REPO/Nook/Nook-CI.entitlements" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  > /tmp/nook-kurth-build.log 2>&1 || { grep -E "error:" /tmp/nook-kurth-build.log | head -20; echo "❌ no compiló (log: /tmp/nook-kurth-build.log)"; exit 1; }
codesign --verify --deep --strict $APP
echo "✅ compiló en $(( $(date +%s) - inicio )) s ($(git -C $REPO rev-parse --short HEAD))"

# Salir por Apple Event pasa por applicationShouldTerminate: guarda pestañas y no muestra el aviso de ⌘Q.
if pgrep -x Nook >/dev/null; then
  osascript -e 'tell application "Nook" to quit'
  for _ in {1..40}; do pgrep -x Nook >/dev/null || break; sleep 0.25; done
  pgrep -x Nook >/dev/null && { echo "❌ Nook no cerró; no instalo"; exit 1; }
fi

rm -rf /Applications/Nook.app
ditto $APP /Applications/Nook.app
echo "✅ instalado"
[[ ${1:-} == --sin-abrir ]] || open -a /Applications/Nook.app
