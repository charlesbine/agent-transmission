#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$PROJECT_DIR/dist/Codex Transmission.app"
PLIST="$PROJECT_DIR/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ARCHIVE="$PROJECT_DIR/dist/Codex-Transmission-$VERSION-macOS.zip"
SIGN_IDENTITY=${CODEX_TRANSMISSION_SIGN_IDENTITY:--}
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-transmission-package.XXXXXX")
STAGED_APP="$STAGING_DIR/Codex Transmission.app"
CONTENTS_DIR="$STAGED_APP/Contents"
trap 'rm -rf "$STAGING_DIR"' EXIT

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$CONTENTS_DIR/MacOS"
mkdir -p "$CONTENTS_DIR/Resources"
install -m 755 ".build/release/CodexTransmission" "$CONTENTS_DIR/MacOS/CodexTransmission"
/usr/bin/strip -S "$CONTENTS_DIR/MacOS/CodexTransmission"
install -m 644 "$PLIST" "$CONTENTS_DIR/Info.plist"
install -m 644 "LICENSE" "$CONTENTS_DIR/Resources/LICENSE.txt"
install -m 644 "NOTICE" "$CONTENTS_DIR/Resources/NOTICE.txt"

if [ "$SIGN_IDENTITY" = "-" ]; then
    /usr/bin/codesign --force --sign - "$STAGED_APP"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP"
fi

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

case "$APP_DIR" in
    "$PROJECT_DIR/dist/"*.app) ;;
    *) echo "Refusing unsafe app destination: $APP_DIR" >&2; exit 2 ;;
esac

mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_DIR" "$ARCHIVE"

echo "$APP_DIR"
/usr/bin/shasum -a 256 "$ARCHIVE"
echo "$ARCHIVE"
