#!/bin/bash
# Builds build/Dockyard.app.
#   --universal     build for both Apple Silicon and Intel (used for releases)
#   --developer-id  sign with the Developer ID certificate and hardened runtime (needed for notarization)
#   --install       copy the app to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
INSTALL=0
SIGN_FLAGS=(--force --sign -)
for arg in "$@"; do
    case "$arg" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        --install) INSTALL=1 ;;
        --developer-id)
            IDENTITY="${DOCKYARD_SIGN_IDENTITY:-Developer ID Application: MAXIME GARIEPY (NZN9M2VV5J)}"
            SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --timestamp) ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

# Assemble and sign outside the project: synced folders (e.g. iCloud Drive's Documents)
# keep adding Finder metadata, which codesign rejects.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED="$STAGE/Dockyard.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Helpers" "$STAGED/Contents/Resources"
cp "$BIN/Dockyard" "$STAGED/Contents/MacOS/Dockyard"
cp "$BIN/DockyardStub" "$STAGED/Contents/Helpers/DockyardStub"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
"$STAGED/Contents/MacOS/Dockyard" --render-app-icon "$STAGED/Contents/Resources/AppIcon.icns"
xattr -cr "$STAGED"
codesign "${SIGN_FLAGS[@]}" "$STAGED/Contents/Helpers/DockyardStub"
codesign "${SIGN_FLAGS[@]}" "$STAGED"
codesign --verify --strict "$STAGED"

APP="build/Dockyard.app"
mkdir -p build
rm -rf "$APP"
ditto --norsrc --noextattr "$STAGED" "$APP"

echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
    pkill -x Dockyard 2>/dev/null || true
    rm -rf /Applications/Dockyard.app
    cp -R "$APP" /Applications/
    open /Applications/Dockyard.app
    echo "Installed to /Applications/Dockyard.app"
fi
