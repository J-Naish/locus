#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED_DATA_PATH="${LOCUS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived}"
CONFIGURATION="${LOCUS_XCODE_CONFIGURATION:-Debug}"
OPEN_APP=1

usage() {
  cat <<'USAGE'
Usage: scripts/mac/run-app.sh [--debug|--release] [--no-open]

Builds the macOS app with xcodebuild and opens the resulting Locus.app.

Options:
  --debug      Build Debug configuration (default)
  --release    Build Release configuration
  --no-open    Build only; do not open the app
  -h, --help   Show this help

Environment:
  LOCUS_DERIVED_DATA_PATH      Override Xcode derived data path
  LOCUS_XCODE_CONFIGURATION    Override build configuration
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      CONFIGURATION=Debug
      ;;
    --release)
      CONFIGURATION=Release
      ;;
    --no-open)
      OPEN_APP=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "error: unsupported configuration: $CONFIGURATION" >&2
    echo "expected Debug or Release" >&2
    exit 2
    ;;
esac

xcodebuild \
  -project "$ROOT_DIR/apps/mac/Locus/Locus.xcodeproj" \
  -scheme Locus \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination 'platform=macOS' \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Locus.app"

if [ "$OPEN_APP" = "1" ]; then
  open "$APP_PATH"
else
  echo "$APP_PATH"
fi
