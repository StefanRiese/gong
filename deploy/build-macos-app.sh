#!/usr/bin/env bash
# Builds the macOS app bundle from one or two server builds of
# build-release.sh (macOS, one per architecture). With arm64 and x64 the
# binaries are merged with lipo into a universal app:
#
#   bash deploy/build-macos-app.sh dist/macos-arm64 dist/macos-x64
#   → dist/schulportal-client-macos-universal.zip (+ .sha256)
#
# Each input directory contains bin/server, lib/ (SQLite) and VERSION.
# The app is signed ad hoc (no Apple Developer ID): on first start, open it
# with right click → Öffnen.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST="$ROOT/dist"
NAME="Schulportal-Client"

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 <build-dir> [<build-dir>]" >&2; exit 64; }
inputs=("$@")
for d in "${inputs[@]}"; do
  [[ -x $d/bin/server ]] || { echo "$d/bin/server missing" >&2; exit 1; }
done

version=$(cat "${inputs[0]}/VERSION")
short=${version#v}
short=${short%%-*}
[[ $short =~ ^[0-9]+(\.[0-9]+)*$ ]] || short=0.0.0
if [[ $# -eq 2 ]]; then suffix=universal; else suffix=$(lipo -archs "${inputs[0]}/bin/server" | tr ' ' '-'); fi
zip="schulportal-client-macos-$suffix.zip"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/$NAME.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/bin" "$contents/Resources/lib"

# Fat binary from the per-architecture files (or a copy for one input).
merge() {
  local rel=$1 out=$2
  local files=()
  for d in "${inputs[@]}"; do files+=("$d/$rel"); done
  lipo -create "${files[@]}" -output "$out"
}

echo "Merging server binaries"
merge bin/server "$contents/Resources/bin/server"
chmod +x "$contents/Resources/bin/server"
for lib in "${inputs[0]}"/lib/*; do
  merge "lib/$(basename "$lib")" "$contents/Resources/lib/$(basename "$lib")"
done

echo "Compiling menu bar app"
targets=()
for d in "${inputs[@]}"; do
  for a in $(lipo -archs "$d/bin/server"); do targets+=("$a"); done
done
slices=()
for a in "${targets[@]}"; do
  swiftc -O -target "$a-apple-macos11" -o "$work/launcher-$a" "$ROOT/deploy/macos/main.swift"
  slices+=("$work/launcher-$a")
done
lipo -create "${slices[@]}" -output "$contents/MacOS/SchulportalClient"

echo "Resources"
sed -e "s/@VERSION@/$version/" -e "s/@SHORT_VERSION@/$short/" \
  "$ROOT/deploy/macos/Info.plist" > "$contents/Info.plist"
plutil -lint "$contents/Info.plist"
cp "$ROOT/deploy/desktop/MenuBarIcon.png" "$ROOT/deploy/desktop/MenuBarIcon@2x.png" "$contents/Resources/"
cp "$ROOT/LICENSE" "$contents/Resources/"
echo "$version" > "$contents/Resources/VERSION"

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ROOT/web/icon-512.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  if [[ $d -le 512 ]]; then
    sips -z "$d" "$d" "$ROOT/web/icon-512.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  fi
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"

echo "Signing (ad hoc)"
codesign --force --sign - "$contents/Resources/lib/"* "$contents/Resources/bin/server"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

echo "Checking"
for a in "${targets[@]}"; do
  case $a in
    arm64) [[ $(uname -m) == arm64 ]] || continue ;;
    x86_64) arch -x86_64 /usr/bin/true 2>/dev/null || { echo "(no Rosetta, skipping x86_64 check)"; continue; } ;;
  esac
  echo "-- $a"
  arch "-$a" "$contents/Resources/bin/server" check --desktop
done
for f in "$contents/MacOS/SchulportalClient" "$contents/Resources/bin/server" "$contents/Resources/lib/"*; do
  echo "$(basename "$f"): $(lipo -archs "$f")"
done

mkdir -p "$DIST"
rm -f "$DIST/$zip" "$DIST/$zip.sha256"
ditto -c -k --keepParent "$app" "$DIST/$zip"
(cd "$DIST" && shasum -a 256 "$zip" > "$zip.sha256")
echo "Created dist/$zip"
cat "$DIST/$zip.sha256"
