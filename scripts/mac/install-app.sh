#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIGURATION="${LOCUS_RELEASE_CONFIGURATION:-Release}"
DEFAULT_DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/Locus-Install"
DEFAULT_OUTPUT_DIR="$HOME/Library/Caches/Locus/release-artifacts"
INSTALL_PATH="${LOCUS_INSTALL_APP_PATH:-/Applications/Locus.app}"
OPEN_APP=1
QUIT_APP=1
BUILD_APP=1

usage() {
  cat <<'USAGE'
Usage: scripts/mac/install-app.sh [options]

Builds the Release macOS app outside the repository and installs it for daily use.

Default install path:
  /Applications/Locus.app

Options:
  --destination PATH   Install to PATH instead of /Applications/Locus.app
  --user              Install to ~/Applications/Locus.app
  --skip-build        Install the existing built app from the derived data path
  --no-open           Do not open Locus after installation
  --no-quit           Do not quit a running Locus before replacing the app
  -h, --help          Show this help

Environment:
  LOCUS_INSTALL_APP_PATH       Override the install path
  LOCUS_DERIVED_DATA_PATH      Override Xcode derived data path
  LOCUS_RELEASE_OUTPUT_DIR     Override release archive output path
  LOCUS_CODE_SIGN_IDENTITY     Override signing identity (defaults to ad-hoc)
  LOCUS_DEVELOPMENT_TEAM       Developer team for Developer ID builds
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination)
      if [ "$#" -lt 2 ]; then
        echo "error: --destination requires a path" >&2
        exit 2
      fi
      INSTALL_PATH="$2"
      shift
      ;;
    --user)
      INSTALL_PATH="$HOME/Applications/Locus.app"
      ;;
    --system)
      INSTALL_PATH="/Applications/Locus.app"
      ;;
    --skip-build)
      BUILD_APP=0
      ;;
    --no-open)
      OPEN_APP=0
      ;;
    --no-quit)
      QUIT_APP=0
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

: "${LOCUS_DERIVED_DATA_PATH:=$DEFAULT_DERIVED_DATA_PATH}"
: "${LOCUS_RELEASE_OUTPUT_DIR:=$DEFAULT_OUTPUT_DIR}"
export LOCUS_DERIVED_DATA_PATH
export LOCUS_RELEASE_OUTPUT_DIR

APP_PATH="$LOCUS_DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Locus.app"

if [ "$BUILD_APP" = "1" ]; then
  "$ROOT_DIR/scripts/release/build-macos-app.sh"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "error: built app not found: $APP_PATH" >&2
  echo "run without --skip-build or set LOCUS_DERIVED_DATA_PATH to the build location" >&2
  exit 1
fi

if [ "$QUIT_APP" = "1" ] && pgrep -x Locus >/dev/null 2>&1; then
  echo
  echo "== Quit running Locus =="
  osascript -e 'tell application "Locus" to quit' >/dev/null 2>&1 || true

  attempts=0
  while pgrep -x Locus >/dev/null 2>&1 && [ "$attempts" -lt 50 ]; do
    sleep 0.2
    attempts=$((attempts + 1))
  done

  if pgrep -x Locus >/dev/null 2>&1; then
    echo "error: Locus is still running; quit it and rerun the installer" >&2
    exit 1
  fi
fi

INSTALL_PARENT="$(dirname "$INSTALL_PATH")"
TEMP_PATH="$INSTALL_PARENT/.Locus.app.install.$$"

echo
echo "== Install Locus.app =="
mkdir -p "$INSTALL_PARENT"
rm -rf "$TEMP_PATH"
ditto "$APP_PATH" "$TEMP_PATH"
rm -rf "$INSTALL_PATH"
mv "$TEMP_PATH" "$INSTALL_PATH"

codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"

echo
echo "installed: $INSTALL_PATH"
echo "archive: $LOCUS_RELEASE_OUTPUT_DIR/Locus-macOS.zip"

if [ "$OPEN_APP" = "1" ]; then
  open "$INSTALL_PATH"
fi
