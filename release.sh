#!/bin/bash
# Builds a universal, Developer ID-signed Dockyard.app, notarizes and staples it, zips it,
# and optionally publishes a GitHub release for the version in Resources/Info.plist.
# Bump CFBundleShortVersionString (and CFBundleVersion) first.
#   ./release.sh            build, notarize, staple, zip (build/Dockyard-<version>.zip) and
#                           write the Sparkle appcast (build/appcast.xml), signed with the
#                           "dockyard" EdDSA key in the Keychain (from generate_keys)
#   ./release.sh --publish  also tag v<version>, push, and create the GitHub release
# Notarization uses the keychain profile from:
#   xcrun notarytool store-credentials dockyard --apple-id <id> --team-id NZN9M2VV5J
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${DOCKYARD_NOTARY_PROFILE:-dockyard}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Dockyard-$VERSION.zip"

./build.sh --universal --developer-id

# No extended attributes in archives: Finder metadata would invalidate the signature
# once unzipped ("Dockyard is damaged").
pack() { rm -f "$ZIP"; ditto -c -k --norsrc --noextattr --keepParent build/Dockyard.app "$ZIP"; }

pack
echo "Submitting to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Dockyard.app
# Re-zip so the download carries the stapled ticket and opens offline without warnings.
pack
spctl --assess --type execute --verbose build/Dockyard.app
echo "Packaged $ZIP"

# Sparkle appcast: the update feed the app checks (SUFeedURL points at the latest release's copy).
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
SPARKLE_SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account dockyard "$ZIP")
NOTES_HTML="ReleaseNotes/$VERSION.html"
if [[ -f "$NOTES_HTML" ]]; then
    NOTES_XML="<description><![CDATA[$(cat "$NOTES_HTML")]]></description>"
else
    NOTES_XML="<sparkle:releaseNotesLink>https://github.com/MaxiG0D/Dockyard/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi
cat > build/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dockyard</title>
    <link>https://github.com/MaxiG0D/Dockyard</link>
    <item>
      <title>Dockyard $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      $NOTES_XML
      <enclosure url="https://github.com/MaxiG0D/Dockyard/releases/download/v$VERSION/Dockyard-$VERSION.zip"
                 type="application/octet-stream" $SPARKLE_SIG />
    </item>
  </channel>
</rss>
APPCAST
echo "Wrote build/appcast.xml"

INSTALL_NOTES='## Install

Download **Dockyard-*.zip** below, unzip it, move **Dockyard.app** to Applications and open it.
Signed and notarized by Apple.

Requires macOS 14 or later · Apple Silicon and Intel'

if [[ "${1:-}" == "--publish" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit your changes before publishing." >&2
        exit 1
    fi
    git tag "v$VERSION"
    git push origin HEAD "v$VERSION"
    gh release create "v$VERSION" "$ZIP" build/appcast.xml --title "Dockyard $VERSION" --generate-notes --notes "$INSTALL_NOTES"
fi
