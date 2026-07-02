#!/usr/bin/env bash
#
# Package Sort.app into a double-clickable, drag-to-Applications .dmg — the real install experience.
#
# Ad-hoc signed (free): the DMG installs and runs on THIS Mac with no Apple Developer account. To
# hand it to OTHER people without a Gatekeeper warning you need Developer ID + notarization (see the
# notes at the bottom of make_app.sh).
#
# Usage:
#   ./packaging/make_dmg.sh                 # release build → build/Sort-<version>.dmg
#   CONFIG=debug ./packaging/make_dmg.sh    # faster debug build
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Build + sign the sandboxed .app via the existing assembler (honors CONFIG / SIGN_ID).
./packaging/make_app.sh

APP="build/Sort.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="build/Sort-${VERSION}.dmg"

# 2. Build into an explicitly-sized read-write image, then compress. (srcfolder auto-sizing
#    under-allocates for the ~83 MB model — an APFS clone-vs-actual-bytes quirk — and fails.)
APP_MB="$(du -sm "$APP" | cut -f1)"
SIZE_MB="$(( APP_MB + 80 ))"
RWDIR="$(mktemp -d)"
RW="$RWDIR/rw.dmg"
MNT="$(mktemp -d)"
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$RWDIR" "$MNT"' EXIT

hdiutil create -volname "Sort ${VERSION}" -size "${SIZE_MB}m" -fs HFS+ -ov "$RW" >/dev/null
hdiutil attach "$RW" -mountpoint "$MNT" -nobrowse >/dev/null
cp -R "$APP" "$MNT/Sort.app"
ln -s /Applications "$MNT/Applications"          # drag-to-install target
hdiutil detach "$MNT" >/dev/null

# 3. Compress to the final read-only DMG.
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null

# 4. (Optional) Notarize for distribution to OTHER Macs. Runs ONLY with a real Developer ID and a
#    stored notarytool keychain profile — ad-hoc local builds skip this entirely (unchanged behavior).
SIGN_ID="${SIGN_ID:--}"
if [ "$SIGN_ID" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing $DMG (profile: $NOTARY_PROFILE)…"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✅ Notarized + stapled — installs on any Mac with no Gatekeeper prompt."
elif [ "$SIGN_ID" != "-" ]; then
    echo "ℹ️  Developer ID build but NOTARY_PROFILE unset → signed, not notarized. One-time setup:"
    echo "    xcrun notarytool store-credentials AC_NOTARY --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>"
    echo "    then: SIGN_ID=\"\$DEVELOPER_ID\" NOTARY_PROFILE=AC_NOTARY ./packaging/make_dmg.sh"
fi

echo "✅ Built $DMG"
echo "   Install:  open \"$DMG\"  →  drag Sort.app onto Applications  →  launch from Applications."
echo "   If macOS blocks it (Gatekeeper), right-click Sort.app → Open the first time."
