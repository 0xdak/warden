#!/bin/zsh
# Builds dist/<APP_NAME>.app from the Swift package (no Xcode required).
#
#   scripts/build_app.sh            # universal (arm64 + x86_64) if possible, else arm64
#   ARCHS="arm64" scripts/build_app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh   # real signing
#
# Bundle layout:
#   Contents/MacOS/<APP_NAME>     menu-bar app (LSUIElement)
#   Contents/MacOS/<HOOK_NAME>    hook CLI; copied to ~/Library/Application Support/<APP_NAME>/bin on install
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/brand.env"

ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"     # "-" = ad-hoc
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"      # optional: keychain holding the identity
kc_args=(); [[ -n "$SIGN_KEYCHAIN" ]] && kc_args=(--keychain "$SIGN_KEYCHAIN")
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

cd "$ROOT"
app_bins=(); hook_bins=()
for arch in ${=ARCHS}; do
  echo "==> swift build -c release --arch $arch"
  if swift build -c release --arch "$arch" --product "$EXECUTABLE_TARGET" && \
     swift build -c release --arch "$arch" --product "$HOOK_TARGET"; then
    app_bins+=("$ROOT/.build/$arch-apple-macosx/release/$EXECUTABLE_TARGET")
    hook_bins+=("$ROOT/.build/$arch-apple-macosx/release/$HOOK_TARGET")
  else
    echo "!! build for $arch failed — continuing without it" >&2
  fi
done
(( ${#app_bins} > 0 )) || { echo "no architecture built" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${app_bins[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
lipo -create "${hook_bins[@]}" -output "$APP/Contents/MacOS/$HOOK_NAME"
echo "    archs: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

ICON="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
  echo "    generating placeholder icon"
  mkdir -p "$ROOT/Resources"
  swift "$ROOT/scripts/make_icon.swift" "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign -s - --force --timestamp=none -i "$BUNDLE_ID.hook" "$APP/Contents/MacOS/$HOOK_NAME"
  codesign -s - --force --timestamp=none "$APP"
else
  codesign -s "$SIGN_IDENTITY" "${kc_args[@]}" --force --options runtime --timestamp -i "$BUNDLE_ID.hook" "$APP/Contents/MacOS/$HOOK_NAME"
  codesign -s "$SIGN_IDENTITY" "${kc_args[@]}" --force --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    signature OK"
echo "==> done: $APP"
