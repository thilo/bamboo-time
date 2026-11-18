#!/bin/sh
# Build BambooTime.app and wrap it in build/BambooTime.dmg.
# SIGN_IDENTITY=<cert name> signs with a self-signed cert instead of ad-hoc
# (stable identity → no Keychain prompt after updates). Set it in the
# git-ignored .env to keep it out of the repo.
# BAMBOO_CLIENT_ID and BAMBOO_CLIENT_SECRET (required) come from the OAuth app
# on developers.bamboohr.com, usually via .env.
set -eu
VERSION="${1:?usage: scripts/bundle.sh VERSION}"
cd "$(dirname "$0")/.."
[ -f .env ] && . ./.env
: "${BAMBOO_CLIENT_ID:?set BAMBOO_CLIENT_ID (OAuth app on developers.bamboohr.com) in .env}"
: "${BAMBOO_CLIENT_SECRET:?set BAMBOO_CLIENT_SECRET in .env}"
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
cp Support/Instructions.md build/dmg/
# ponytail: values must not contain "|", "&" or "\\" (sed); BambooHR ids/secrets are alphanumeric.
sed -e "s|__VERSION__|$VERSION|g" -e "s|__CLIENT_ID__|$BAMBOO_CLIENT_ID|" \
    -e "s|__CLIENT_SECRET__|$BAMBOO_CLIENT_SECRET|" \
    Support/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname BambooTime -srcfolder build/dmg -ov -format UDZO build/BambooTime.dmg
# A symlink to /Applications left in the workspace makes editor file crawlers walk all apps.
rm build/dmg/Applications
echo "→ build/BambooTime.dmg ($VERSION)"
