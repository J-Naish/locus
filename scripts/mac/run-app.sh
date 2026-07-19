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
  # `open` reuses a running instance only when the bundle path matches
  # exactly, so an instance left over from another build path (Debug vs
  # Release, or a stale build) keeps running and the app shows up twice.
  # Terminate instances launched from this repo's build output first;
  # installed copies outside the build directories are untouched. Like
  # Xcode's Run, dev instances exit without save prompts.
  for pid in $(pgrep -x Locus 2>/dev/null || true); do
    exe_path="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$exe_path" in
      "$ROOT_DIR/.build/"*|"$DERIVED_DATA_PATH/"*)
        kill -TERM "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        ;;
    esac
  done
  open "$APP_PATH"
else
  echo "$APP_PATH"
fi
