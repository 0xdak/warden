#!/bin/zsh
# Developer ID build + DMG + notarize + staple.
#   SIGN_IDENTITY=<sha1|name> SIGN_KEYCHAIN=<kc> NOTARY_PROFILE=<profile> scripts/release.sh
# The keychain must already be unlocked.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/scripts/brand.env"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}" "${SIGN_KEYCHAIN:?set SIGN_KEYCHAIN}" "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
APP="$ROOT/dist/$APP_NAME.app"; DMG="$ROOT/dist/$APP_NAME.dmg"

rm -rf "$APP"
SIGN_IDENTITY="$SIGN_IDENTITY" SIGN_KEYCHAIN="$SIGN_KEYCHAIN" "$ROOT/scripts/build_app.sh"
"$ROOT/scripts/make_dmg.sh"
codesign -s "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --timestamp --force "$DMG"

echo "==> notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --keychain "$SIGN_KEYCHAIN" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> released: $DMG"
