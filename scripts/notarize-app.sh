#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH=${1:-"$PROJECT_DIR/dist/Codex Transmission.app"}
PROFILE=${CODEX_TRANSMISSION_NOTARY_PROFILE:-}

if [ -z "$PROFILE" ]; then
    echo "Set CODEX_TRANSMISSION_NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
    exit 2
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 2
fi

SIGNATURE=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)
case "$SIGNATURE" in
    *"Signature=adhoc"*)
        echo "Notarization requires a Developer ID Application signature, not an ad-hoc signature." >&2
        exit 2
        ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
UPLOAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-transmission-notary.XXXXXX")
UPLOAD_ZIP="$UPLOAD_DIR/Codex-Transmission-$VERSION-macOS.zip"
FINAL_ZIP="$PROJECT_DIR/dist/Codex-Transmission-$VERSION-macOS.zip"
trap 'rm -rf "$UPLOAD_DIR"' EXIT

/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_PATH" "$UPLOAD_ZIP"
/usr/bin/xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP_PATH"
/usr/bin/xcrun stapler validate "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"

rm -f "$FINAL_ZIP"
/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_PATH" "$FINAL_ZIP"
/usr/bin/shasum -a 256 "$FINAL_ZIP"
echo "$FINAL_ZIP"
