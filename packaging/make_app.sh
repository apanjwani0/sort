#!/usr/bin/env bash
#
# Assemble a double-clickable Sort.app from the SwiftPM-built sort-app binary (D2).
#
# The app is SANDBOXED (packaging/sort.entitlements): the user grants a folder via the in-app
# picker and Sort persists read+write access with a security-scoped bookmark — no Full Disk Access,
# no manual steps. Folder permissions survive rebuilds because they're keyed to the bundle id.
#
# Signing (no paid Apple Developer account needed for personal use):
#   • Default        — ad-hoc signed ("-"); the sandboxed app runs on THIS Mac with no warning. Free.
#   • Developer ID   — only needed to share with OTHERS / ship to the App Store ($99/yr);
#                      see the notarization steps at the bottom.
#
# Usage:
#   ./packaging/make_app.sh                       # release build → build/Sort.app (sandboxed, ad-hoc)
#   CONFIG=debug ./packaging/make_app.sh          # use the debug build
#   SIGN_ID="Developer ID Application: …" ./packaging/make_app.sh
#   APP_OUT=/tmp/Sort.app ./packaging/make_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="${APP_OUT:-build/Sort.app}"
SIGN_ID="${SIGN_ID:--}"     # "-" = ad-hoc (free, local)

echo "Building sort-app ($CONFIG)…"
swift build -c "$CONFIG" --product sort-app
BIN="$(swift build -c "$CONFIG" --product sort-app --show-bin-path)/sort-app"
[ -x "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/sort-app"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Bundle the face model so a sandboxed/installed build can actually use it (the sandbox can't read the
# global ~/Library/Application Support path the CLI/dev build uses). The DMG ships AuraFace v1
# (Apache-2.0, commercial-clean); a personal arcface/buffalo_l swap is honoured too. ~80 MB.
MODELS_DIR="${SORT_MODELS_DIR:-$HOME/Library/Application Support/sort/models}"
MODEL_SRC="${FACE_MODEL:-${ARCFACE_MODEL:-}}"     # explicit override (FACE_MODEL preferred)
if [ -z "$MODEL_SRC" ]; then
    for cand in auraface arcface; do
        if [ -d "$MODELS_DIR/$cand.mlmodelc" ]; then MODEL_SRC="$MODELS_DIR/$cand.mlmodelc"; break; fi
    done
fi
MODEL_NAME="$(basename "${MODEL_SRC:-auraface.mlmodelc}")"
if [ -n "$MODEL_SRC" ] && [ -d "$MODEL_SRC" ]; then
    echo "Bundling face model: $MODEL_SRC → Resources/$MODEL_NAME"
    cp -R "$MODEL_SRC" "$APP/Contents/Resources/$MODEL_NAME"
elif [ "${ALLOW_NO_MODEL:-}" = "1" ]; then
    echo "⚠️  No face model found in $MODELS_DIR — building anyway (ALLOW_NO_MODEL=1). The app will"
    echo "    fall back to Vision feature-print (much weaker grouping). Dev/test builds only."
else
    echo "❌ No face model found in $MODELS_DIR (looked for auraface.mlmodelc, arcface.mlmodelc)." >&2
    echo "   Convert one with tools/convert_arcface_to_coreml.py, or set FACE_MODEL=<path>." >&2
    echo "   To build a dev/test app without it, set ALLOW_NO_MODEL=1." >&2
    exit 1
fi

# Fail loud if the model didn't actually land in the bundle (so we never ship a silently-modelless app).
if [ "${ALLOW_NO_MODEL:-}" != "1" ] && [ ! -d "$APP/Contents/Resources/$MODEL_NAME" ]; then
    echo "❌ $MODEL_NAME missing from $APP/Contents/Resources after assembly." >&2
    exit 1
fi

echo "Signing ($([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID")) + App Sandbox entitlements…"
# Sign inside-out (nested items first, app last) instead of the deprecated `--deep`, which doesn't
# reliably seal a nested .mlmodelc under hardened runtime. Hardened runtime + a secure timestamp are
# REQUIRED for notarization but need a real identity + network, so they're added only for a real
# Developer ID; ad-hoc stays free and offline.
if [ "$SIGN_ID" = "-" ]; then
    SIGN_OPTS=(--force)
else
    SIGN_OPTS=(--force --options runtime --timestamp)
fi
# No `--deep`: Sort.app has no nested code (just the main binary). The bundled .mlmodelc is a
# RESOURCE — sealed automatically by the app signature's CodeResources, not signed as its own bundle
# (codesign rejects a .mlmodelc as "bundle format unrecognized"). --deep added nothing here and is
# Apple-deprecated for distribution signing.
codesign "${SIGN_OPTS[@]}" --entitlements packaging/sort.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP" && echo "✅ Signed (sandboxed)."

echo "✅ Built $APP"
echo "   Run it:  open \"$APP\""
echo "   (Locally-built apps aren't quarantined, so it opens with no Gatekeeper prompt.)"

# ---------------------------------------------------------------------------
# Share with OTHER Macs without the "unidentified developer" warning → paid Apple Developer account
# ($99/yr) for a Developer ID. The signing above is already notarization-ready: inside-out, with
# hardened runtime + secure timestamp whenever SIGN_ID is a real identity. Notarization itself is
# wired into make_dmg.sh — one-time credential setup, then one command:
#
#   xcrun notarytool store-credentials AC_NOTARY --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=AC_NOTARY ./packaging/make_dmg.sh
#
# Without paying, share the ad-hoc DMG; the recipient opens it once via right-click → Open, or:
#   xattr -dr com.apple.quarantine /path/Sort.app
# ---------------------------------------------------------------------------
