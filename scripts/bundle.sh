#!/bin/sh
# Build BambooTime.app and wrap it in build/BambooTime.dmg.
# SIGN_IDENTITY=<cert name> signs with a self-signed cert instead of ad-hoc
# (stable identity → no Keychain prompt after updates).
set -eu
VERSION="${1:?usage: scripts/bundle.sh VERSION}"
cd "$(dirname "$0")/.."
# The Command Line Tools alone lack parts of the toolchain; prefer Xcode if installed.
XCODE=/Applications/Xcode.app/Contents/Developer
[ -z "${DEVELOPER_DIR:-}" ] && [ -d "$XCODE" ] && export DEVELOPER_DIR="$XCODE"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BambooTime"

rm -rf build
APP=build/dmg/BambooTime.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" Support/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname BambooTime -srcfolder build/dmg -ov -format UDZO build/BambooTime.dmg
echo "→ build/BambooTime.dmg ($VERSION)"
