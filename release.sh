#!/bin/bash
# Builds a universal Dockyard.app, zips it and publishes a GitHub release for the
# version in Resources/Info.plist. Bump CFBundleShortVersionString (and CFBundleVersion) first.
#   ./release.sh            build + zip only (build/Dockyard-<version>.zip)
#   ./release.sh --publish  also tag v<version>, push, and create the GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Dockyard-$VERSION.zip"

./build.sh --universal
rm -f "$ZIP"
# No extended attributes in the archive: Finder metadata would invalidate the signature
# once unzipped ("Dockyard is damaged").
ditto -c -k --norsrc --noextattr --keepParent build/Dockyard.app "$ZIP"
echo "Packaged $ZIP"

if [[ "${1:-}" == "--publish" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit your changes before publishing." >&2
        exit 1
    fi
    git tag "v$VERSION"
    git push origin HEAD "v$VERSION"
    gh release create "v$VERSION" "$ZIP" --title "Dockyard $VERSION" --generate-notes
fi
