#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT_DIR/apps/mac/Locus/Locus.xcodeproj"
SCHEME="${LOCUS_RELEASE_SCHEME:-Locus}"
CONFIGURATION="${LOCUS_RELEASE_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${LOCUS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived-release}"
OUTPUT_DIR="${LOCUS_RELEASE_OUTPUT_DIR:-$ROOT_DIR/target/release-artifacts}"
CODE_SIGN_IDENTITY="${LOCUS_CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${LOCUS_DEVELOPMENT_TEAM:-}"

mkdir -p "$OUTPUT_DIR"

echo "== Build macOS release app =="
if [ -n "$DEVELOPMENT_TEAM" ]; then
    xcodebuild \
        -quiet \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        build
else
    xcodebuild \
        -quiet \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        build
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Locus.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Locus"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
ARCHIVE_PATH="$OUTPUT_DIR/Locus-macOS.zip"

echo
echo "== Verify code signature =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "== Verify hardened runtime =="
if ! codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -q "flags=.*runtime"; then
    echo "error: release app is not signed with hardened runtime" >&2
    exit 1
fi

echo
echo "== Verify bundled metadata =="
/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:0" "$INFO_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :LSSupportsOpeningDocumentsInPlace" "$INFO_PLIST" >/dev/null

echo
echo "== Verify Rust core is statically linked =="
if otool -L "$EXECUTABLE_PATH" | grep -E 'app_ffi|core/target' >/dev/null; then
    echo "error: release app still references the Rust core dynamically" >&2
    exit 1
fi

echo
echo "== Package app archive =="
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"

echo
echo "app: $APP_PATH"
echo "archive: $ARCHIVE_PATH"
echo "signing_identity: $CODE_SIGN_IDENTITY"
