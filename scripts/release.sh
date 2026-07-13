#!/usr/bin/env bash
#
# Build, sign (Developer ID), notarize, staple, and package GameMaster into a
# DMG, then generate the Sparkle appcast.
# Requires a stored notarytool keychain profile named "gamemaster-notary":
#
#   xcrun notarytool store-credentials gamemaster-notary \
#       --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Usage: ./scripts/release.sh [version]
set -euo pipefail

VERSION="${1:-0.1.0}"
VERSION="${VERSION#v}"
SCHEME="GameMaster"
APP="build/Build/Products/Release/GameMaster.app"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-gamemaster-notary}"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $SCHEME ($VERSION)"
# Build unsigned, then sign inside-out with scripts/sign.sh.
xcodebuild -project GameMaster.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO clean build

echo "==> Signing (Developer ID, inside-out)"
./scripts/sign.sh "$APP"

# Guard against a version mismatch: the VERSION argument only names the DMG and
# the appcast download URL, while the app's real CFBundleShortVersionString
# comes from project.yml. Require a match so tag/DMG/appcast/app agree.
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "ERROR: built app version '$BUILT_VERSION' != requested '$VERSION' — bump project.yml." >&2
  exit 1
fi
case "$BUILT_BUILD" in
  '' | *[!0-9]*)
    echo "ERROR: CFBundleVersion '$BUILT_BUILD' is not numeric." >&2
    exit 1
    ;;
esac

# The Sparkle public key must be present or shipped builds can never verify
# updates — refuse to release without it.
SU_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
if [ -z "$SU_KEY" ]; then
  echo "ERROR: SUPublicEDKey is empty in Info.plist — set it in project.yml." >&2
  exit 1
fi
echo "==> Version check OK: $BUILT_VERSION (build $BUILT_BUILD)"

mkdir -p "$DIST"
DMG="$DIST/GameMaster-$VERSION.dmg"
# A stale appcast from a previous run must never ship with this release:
# remove it up front so the only way to end the script with an appcast is
# generate_appcast writing a fresh one below.
rm -f "$DIST/appcast.xml"

echo "==> Building DMG: $DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "GameMaster" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# Notarize the DMG itself (covers the signed app inside), then staple the DMG.
echo "==> Submitting DMG for notarization"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Gatekeeper-verify the notarized app *inside* the DMG (a DMG itself is not
# code-signed, so a direct spctl assessment of the DMG is not meaningful).
echo "==> Verifying app Gatekeeper acceptance"
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
# Capture spctl's own exit status; `|| status=$?` keeps `set -e` from aborting
# before we can clean up the mount.
gatekeeper_status=0
spctl -a -t exec -vvv "$MOUNT/GameMaster.app" || gatekeeper_status=$?
hdiutil detach "$MOUNT" -quiet || true
rm -rf "$MOUNT"
if [ "$gatekeeper_status" -ne 0 ]; then
  echo "ERROR: Gatekeeper rejected the app inside the DMG (spctl status $gatekeeper_status)." >&2
  exit 1
fi

# Generate the EdDSA-signed Sparkle appcast so auto-update can detect this
# build. generate_appcast signs with the EdDSA private key (login keychain
# locally, or SPARKLE_PRIVATE_KEY in CI) and writes dist/appcast.xml whose
# enclosure URL points at the GitHub release asset.
SPARKLE_BIN="${SPARKLE_BIN:-}"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[ -n "$SPARKLE_BIN" ] || GENERATE_APPCAST="$(command -v generate_appcast || true)"
if [ -x "$GENERATE_APPCAST" ]; then
  echo "==> Generating Sparkle appcast"
  # Local runs sign with the "GameMaster" keychain account (macnet owns the
  # default account on this machine); CI passes the key via env instead.
  KEYARGS=(--account GameMaster)
  KEYFILE=""
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # generate_appcast's --ed-key-file needs a real, seekable file path.
    KEYFILE="$(mktemp)"
    # Remove the private-key temp file on ANY exit so the EdDSA signing key
    # never lingers in /tmp.
    trap 'rm -f "$KEYFILE"' EXIT
    printf '%s' "$SPARKLE_PRIVATE_KEY" >"$KEYFILE"
    KEYARGS=(--ed-key-file "$KEYFILE")
  fi
  # The `${arr[@]+"${arr[@]}"}` idiom expands to nothing when the array is
  # empty (macOS bash 3.2 + set -u would otherwise abort).
  "$GENERATE_APPCAST" ${KEYARGS[@]+"${KEYARGS[@]}"} \
    --download-url-prefix "https://github.com/MatrixReligio/GameMaster/releases/download/v$VERSION/" \
    "$DIST"
  echo "appcast: $DIST/appcast.xml"
else
  # Fail closed: a release without a fresh, signed appcast would strand every
  # existing install on the old version (or worse, ship a stale appcast).
  echo "ERROR: generate_appcast not found — install Sparkle tools or set SPARKLE_BIN." >&2
  exit 1
fi

echo "==> Done: $DMG"
