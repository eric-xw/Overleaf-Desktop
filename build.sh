#!/bin/bash
# Build Overleaf Desktop and wrap the executable into a proper .app bundle.
# Usage:
#   ./build.sh            # release build, produces ./OverleafDesktop.app
#   ./build.sh debug      # debug build
#   ./build.sh run        # release build and launch the app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="release"
RUN_AFTER=0
case "${1:-}" in
    debug) CONFIG="debug" ;;
    run) RUN_AFTER=1 ;;
    "" ) ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
esac

APP_NAME="OverleafDesktop"
APP_DISPLAY="Overleaf Desktop"
BUNDLE_DIR="$SCRIPT_DIR/$APP_NAME.app"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXE="$BIN_PATH/$APP_NAME"
if [[ ! -x "$EXE" ]]; then
    echo "✗ Build did not produce $EXE"
    exit 1
fi

echo "→ Assembling $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$EXE" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Sources/OverleafDesktop/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Copy any SPM-bundled resources next to the executable so Bundle.module works.
RESOURCE_BUNDLE="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$BUNDLE_DIR/Contents/MacOS/"
fi

# Ad-hoc sign so Gatekeeper lets us launch it locally.
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true

echo "✓ Built $BUNDLE_DIR"

if [[ "$RUN_AFTER" -eq 1 ]]; then
    echo "→ Launching"
    open "$BUNDLE_DIR"
fi
