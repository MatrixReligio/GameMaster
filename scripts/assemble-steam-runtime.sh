#!/usr/bin/env bash
# Assembles the Steam run runtime GameMaster ships for D3D11 games:
#   Sikarugir Wine 10.0_6 engine (exports macdrv_functions, so DXMT can
#   create its Metal presentation layer — vanilla Gcenx builds strip it)
# + Sikarugir Wrapper Template runtime dylibs (libinotify for wineserver,
#   freetype/gnutls/… resolved via the unixlibs' @loader_path/../../ rpath)
# + DXMT (Direct3D 10/11 → Metal) installed as wine builtins, keeping the
#   original wined3d DLLs as *.dll.wined3d backups.
#
# Produces gamemaster-runtime-<ID>.tar.xz plus a .sha256 file. Upload the
# tarball to a GitHub release and pin URL + digest in runtime-manifest.json.
set -euo pipefail

RUNTIME_ID="sikarugir-10.0-6-dxmt-0.80"

ENGINE_URL="https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz"
TEMPLATE_URL="https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"

ENGINE_SHA256="9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2"
TEMPLATE_SHA256="9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"

OUT_DIR="${1:-$PWD/dist}"
CACHE_DIR="${RUNTIME_CACHE_DIR:-$OUT_DIR/cache}"
mkdir -p "$OUT_DIR" "$CACHE_DIR"

fetch() { # url sha256 -> echoes cached path
    local url="$1" sha="$2" file
    file="$CACHE_DIR/$(basename "$url")"
    if [[ ! -f "$file" ]]; then
        curl -fL --retry 3 -o "$file.tmp" "$url"
        mv "$file.tmp" "$file"
    fi
    echo "$sha  $file" | shasum -a 256 -c - >&2
    echo "$file"
}

echo "==> Fetching components" >&2
ENGINE_TAR="$(fetch "$ENGINE_URL" "$ENGINE_SHA256")"
TEMPLATE_TAR="$(fetch "$TEMPLATE_URL" "$TEMPLATE_SHA256")"
DXMT_TAR="$(fetch "$DXMT_URL" "$DXMT_SHA256")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gm-runtime.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> Extracting engine" >&2
tar xJf "$ENGINE_TAR" -C "$WORK"
BUNDLE="$WORK/wswine.bundle"
[[ -x "$BUNDLE/bin/wine" ]] || { echo "engine layout unexpected" >&2; exit 1; }

echo "==> Merging wrapper runtime dylibs" >&2
mkdir -p "$WORK/template"
tar xJf "$TEMPLATE_TAR" -C "$WORK/template"
FRAMEWORKS="$(find "$WORK/template" -type d -name Frameworks | head -1)"
[[ -n "$FRAMEWORKS" ]] || { echo "template Frameworks not found" >&2; exit 1; }
cp "$FRAMEWORKS"/*.dylib "$BUNDLE/lib/"
[[ -f "$BUNDLE/lib/libinotify.0.dylib" ]] || { echo "libinotify missing" >&2; exit 1; }

echo "==> Installing DXMT as wine builtins" >&2
mkdir -p "$WORK/dxmt"
tar xzf "$DXMT_TAR" -C "$WORK/dxmt"
DXMT_ROOT="$(find "$WORK/dxmt" -type d -name "x86_64-windows" -maxdepth 2 | head -1 | xargs dirname)"
for dll in d3d11 dxgi d3d10core; do
    for arch in x86_64-windows i386-windows; do
        if [[ -f "$BUNDLE/lib/wine/$arch/$dll.dll" && -f "$DXMT_ROOT/$arch/$dll.dll" ]]; then
            cp "$BUNDLE/lib/wine/$arch/$dll.dll" "$BUNDLE/lib/wine/$arch/$dll.dll.wined3d"
            cp "$DXMT_ROOT/$arch/$dll.dll" "$BUNDLE/lib/wine/$arch/$dll.dll"
        fi
    done
done
cp "$DXMT_ROOT/x86_64-windows/winemetal.dll" "$BUNDLE/lib/wine/x86_64-windows/"
cp "$DXMT_ROOT/i386-windows/winemetal.dll" "$BUNDLE/lib/wine/i386-windows/"
cp "$DXMT_ROOT/x86_64-unix/winemetal.so" "$BUNDLE/lib/wine/x86_64-unix/"

echo "==> Injecting license bundle" >&2
# Vendored license texts + per-component notices (scripts/licenses/, committed
# to the repository for auditability). The bundle redistributes LGPL and other
# open-source binaries; their license texts and source pointers travel with it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LICENSE_SRC="$SCRIPT_DIR/licenses"
[[ -f "$LICENSE_SRC/THIRD-PARTY-NOTICES.txt" ]] || { echo "scripts/licenses missing" >&2; exit 1; }
mkdir -p "$BUNDLE/licenses"
cp "$LICENSE_SRC"/*.txt "$BUNDLE/licenses/"
mv "$BUNDLE/licenses/THIRD-PARTY-NOTICES.txt" "$BUNDLE/THIRD-PARTY-NOTICES.txt"

echo "==> Packing" >&2
OUT_TAR="$OUT_DIR/gamemaster-runtime-$RUNTIME_ID.tar.xz"
rm -f "$OUT_TAR"
tar cJf "$OUT_TAR" --options xz:compression-level=6 -C "$WORK" wswine.bundle
shasum -a 256 "$OUT_TAR" | tee "$OUT_TAR.sha256"
echo "==> Done: $OUT_TAR" >&2
