#!/bin/bash
# Releases the version in Resources/Info.plist. Bump CFBundleShortVersionString and
# CFBundleVersion first, and write the release notes:
#   ReleaseNotes/<version>.md    GitHub release page
#   ReleaseNotes/<version>.html  Sparkle's update window
#
#   ./release.sh                 build a universal, Developer ID-signed app, notarize and staple it,
#                                zip it (build/Dockyard-<version>.zip) and write the Sparkle appcast
#                                (build/appcast.xml), signed with the "dockyard" EdDSA key in the Keychain
#   ./release.sh --publish       also tag v<version>, push, and create the GitHub release
#   ./release.sh --update-notes  refresh an already published release's notes and appcast from
#                                ReleaseNotes/, without rebuilding
#
# Notarization uses the keychain profile from:
#   xcrun notarytool store-credentials dockyard --apple-id <id> --team-id NZN9M2VV5J
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
PROFILE="${DOCKYARD_NOTARY_PROFILE:-dockyard}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
ZIP="build/Dockyard-$VERSION.zip"
NOTES_MD="ReleaseNotes/$VERSION.md"
NOTES_HTML="ReleaseNotes/$VERSION.html"

# Sparkle appcast: the update feed the app checks (SUFeedURL points at the latest release's copy).
write_appcast() {
    local signature notes
    signature=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account dockyard "$ZIP")
    if [[ -f "$NOTES_HTML" ]]; then
        notes="<description><![CDATA[$(cat "$NOTES_HTML")]]></description>"
    else
        notes="<sparkle:releaseNotesLink>https://github.com/MaxiG0D/Dockyard/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
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
      $notes
      <enclosure url="https://github.com/MaxiG0D/Dockyard/releases/download/v$VERSION/Dockyard-$VERSION.zip"
                 type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
APPCAST
    echo "Wrote build/appcast.xml"
}

# GitHub release text: ReleaseNotes/<version>.md, or install steps plus generated notes.
github_notes_args() {
    if [[ -f "$NOTES_MD" ]]; then
        echo --notes-file "$NOTES_MD"
    else
        echo --generate-notes
    fi
}

if [[ "$MODE" == "--update-notes" ]]; then
    mkdir -p build
    # Sign exactly what's published.
    gh release download "v$VERSION" --pattern "Dockyard-$VERSION.zip" --dir build --clobber
    write_appcast
    # shellcheck disable=SC2046
    gh release edit "v$VERSION" $(github_notes_args)
    gh release upload "v$VERSION" build/appcast.xml --clobber
    echo "Updated notes and appcast for v$VERSION"
    exit 0
fi

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

write_appcast

if [[ "$MODE" == "--publish" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit your changes before publishing." >&2
        exit 1
    fi
    [[ -f "$NOTES_MD" ]] || echo "Note: no $NOTES_MD; the release page gets generated notes only." >&2
    git tag "v$VERSION"
    git push origin HEAD "v$VERSION"
    # shellcheck disable=SC2046
    gh release create "v$VERSION" "$ZIP" build/appcast.xml --title "Dockyard $VERSION" $(github_notes_args)
fi
