#!/bin/zsh
# Compila la rama actual, cierra Nook (guarda pestañas), instala y lo vuelve a abrir.
# Uso: kurth/instalar.sh [--sin-abrir]
set -euo pipefail

REPO=${0:A:h:h}
DD=~/Library/Developer/Xcode/DerivedData/Nook-kurth   # fuera de ~/Documents: iCloud rompe codesign
APP=$DD/Build/Products/Release/Nook.app

# Xcode: la beta donde esté (la Air la tiene en ~/Downloads, la Pro en /Applications).
if [[ -z ${DEVELOPER_DIR:-} ]]; then
  for CANDIDATO in $HOME/Downloads/Xcode-beta.app /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d $CANDIDATO ]] && { export DEVELOPER_DIR=$CANDIDATO/Contents/Developer; break }
  done
fi

# Firma: cualquier Apple Development válida de esta Mac. El hash cambia de máquina a máquina
# aunque el equipo sea el mismo (VRFY7KFRYP). El equipo sale del OU del certificado, NO del
# paréntesis del nombre, que en un Apple Development es el id del miembro, no el del equipo.
# Se puede forzar con IDENTIDAD=<hash> EQUIPO=<team>.
if [[ -z ${IDENTIDAD:-} ]]; then
  LINEA=$(security find-identity -v -p codesigning | grep "Apple Development" | grep -v CSSMERR | head -1)
  [[ -n $LINEA ]] || { echo "❌ no hay ningún certificado Apple Development válido en esta Mac"; exit 1 }
  IDENTIDAD=$(echo $LINEA | awk '{print $2}')
  NOMBRE=$(echo $LINEA | sed -E 's/^[^"]*"([^"]+)".*/\1/')
  EQUIPO=$(security find-certificate -c "$NOMBRE" -p | openssl x509 -noout -subject \
           | sed -E 's/.*OU=([A-Z0-9]+).*/\1/')
fi

cd $REPO
inicio=$(date +%s)
xcodebuild -scheme Nook -configuration Release -arch arm64 -derivedDataPath $DD \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$EQUIPO CODE_SIGN_IDENTITY=$IDENTIDAD \
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
