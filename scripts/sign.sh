#!/usr/bin/env bash
#
# Signs GameMaster.app inside-out with Developer ID + Hardened Runtime.
# Sparkle ships nested helpers (XPC services, the updater app, the Autoupdate
# tool) that must each be signed inside-out before the framework and the app,
# or notarization/Gatekeeper rejects them.
#
# Usage: ./scripts/sign.sh <path-to-GameMaster.app>
set -euo pipefail

APP="${1:-build/Build/Products/Release/GameMaster.app}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MatrixReligio LLC (4DUQGD879H)}"
# Secure timestamp by default (required for notarization). A local-only install
# can pass TIMESTAMP=--timestamp=none to avoid contacting Apple's timestamp
# server; such a build is NOT notarizable.
TS="${TIMESTAMP:---timestamp}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
TEAM_ID="4DUQGD879H"

if [ -d "$SPARKLE" ]; then
  echo "==> Signing Sparkle components"
  SV="$SPARKLE/Versions/B"
  codesign --force $TS --options runtime --sign "$IDENTITY" \
    "$SV/XPCServices/Downloader.xpc" \
    "$SV/XPCServices/Installer.xpc"
  codesign --force $TS --options runtime --sign "$IDENTITY" "$SV/Updater.app"
  codesign --force $TS --options runtime --sign "$IDENTITY" "$SV/Autoupdate"
  codesign --force $TS --options runtime --sign "$IDENTITY" "$SPARKLE"
fi

# Debug builds created by recent Xcode versions put most application code in
# loadable debug dylibs. They must carry the same Developer ID Team ID as the
# launcher binary, otherwise dyld refuses to map them under Hardened Runtime.
DEBUG_DYLIBS=()
while IFS= read -r -d '' DYLIB; do
  DEBUG_DYLIBS+=("$DYLIB")
done < <(find "$APP" -path "*/Contents/MacOS/*.dylib" -type f -print0)

if [ "${#DEBUG_DYLIBS[@]}" -gt 0 ]; then
  echo "==> Signing debug support dylibs"
  for DYLIB in "${DEBUG_DYLIBS[@]}"; do
    codesign --force $TS --options runtime --sign "$IDENTITY" "$DYLIB"
  done
fi

echo "==> Signing app"
codesign --force $TS --options runtime \
  --entitlements App/GameMaster.entitlements \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "${#DEBUG_DYLIBS[@]}" -gt 0 ]; then
  echo "==> Verifying debug support dylib Team IDs"
  for DYLIB in "${DEBUG_DYLIBS[@]}"; do
    DYLIB_SIGNATURE="$(codesign -dvv "$DYLIB" 2>&1)"
    if ! grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$DYLIB_SIGNATURE"; then
      echo "ERROR: $DYLIB is not signed with Team ID $TEAM_ID" >&2
      grep -E "Signature=|TeamIdentifier=|Authority=" <<<"$DYLIB_SIGNATURE" >&2 || true
      exit 1
    fi
  done
fi
echo "OK"
