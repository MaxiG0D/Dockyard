#!/bin/bash
# Builds build/Dockyard.app.
#   --universal     build for both Apple Silicon and Intel (used for releases)
#   --developer-id  require the Developer ID certificate, with a secure timestamp (needed for notarization)
#   --install       copy the app to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
INSTALL=0
IDENTITY="${DOCKYARD_SIGN_IDENTITY:-Developer ID Application: MAXIME GARIEPY (NZN9M2VV5J)}"
# Sign local builds with the Developer ID when it's installed: permissions macOS grants
# (e.g. Accessibility, for notification badges) survive rebuilds only with a stable identity.
# Anyone else building from source gets an ad-hoc signature.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --timestamp=none)
else
    SIGN_FLAGS=(--force --sign -)
fi
for arg in "$@"; do
    case "$arg" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        --install) INSTALL=1 ;;
        --developer-id) DEVELOPER_ID=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ ${DEVELOPER_ID:-0} == 1 ]]; then
    # Releases: Developer ID with a secure timestamp, as notarization requires.
    SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --timestamp)
fi

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
