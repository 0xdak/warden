#!/bin/zsh
# Packages dist/<APP_NAME>.app into dist/<APP_NAME>.dmg (drag-to-Applications layout).
#   scripts/make_dmg.sh            # builds the app first if missing
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/scripts/brand.env"

APP="$ROOT/dist/$APP_NAME.app"
[[ -d "$APP" ]] || "$ROOT/scripts/build_app.sh"

DMG="$ROOT/dist/$APP_NAME.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> $DMG"
