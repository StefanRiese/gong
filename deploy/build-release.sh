#!/usr/bin/env bash
# Builds the release for the current OS/architecture:
#
#   Linux:   dist/gong-linux-<arch>.tar.gz (+ .sha256)
#              bin/server, bin/hash_password   native executables
#              lib/                            bundled native libraries (SQLite)
#              web/                            web UI
#              deploy/                         systemd unit, install.sh, README
#              config.env.example, LICENSE, VERSION
#   Windows: dist/gong-windows-<arch>.exe (+ .sha256)
#              single file: tray app with embedded web UI and icon, SQLite
#              from Windows (winsqlite3.dll), no console window
#   macOS:   dist/macos-<arch>/ (bin/server, lib/, VERSION) with embedded web UI;
#              deploy/build-macos-app.sh turns one or two of these (arm64 + x64)
#              into the (universal) app bundle
#
# Linux binaries need a glibc at least as new as the build machine's; build on
# Debian 12 / Ubuntu 22.04 (or older) to run on Debian 12 and 13.

set -euo pipefail

APP=gong
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST="$ROOT/dist"
STAGE="$DIST/$APP"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
exe=""
[[ $os == windows ]] && exe=".exe"

version=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "unknown")
echo "Building $APP $version for $os-$arch"

cd "$ROOT/server"

# Files changed for the build only; restored on exit.
backup=$(mktemp -d)
cp pubspec.yaml pubspec.lock lib/src/desktop/build_info.g.dart "$backup/"
restore() {
  cp "$backup/pubspec.yaml" "$backup/pubspec.lock" .
  cp "$backup/build_info.g.dart" lib/src/desktop/
  rm -rf "$backup"
}
trap restore EXIT

if [[ $os == windows ]]; then
  # Single-file exe: use the SQLite that ships with Windows 10/11.
  cat >> pubspec.yaml <<'YAML'

hooks:
  user_defines:
    sqlite3:
      source: system
      name:
        windows: winsqlite3
YAML
fi

embed=(--version "$version")
check=(check)
if [[ $os != linux ]]; then
  # Relative paths: Dart on Windows cannot open Git Bash paths (/d/a/...).
  embed+=(--web ../web --tray-icon ../deploy/desktop/tray-icon.png)
  check+=(--desktop)
fi

dart pub get
dart run tool/embed_assets.dart "${embed[@]}"
rm -rf build/release
dart build cli -t bin/server.dart -o build/release/server
if [[ $os == windows ]]; then
  # Before the check, so it verifies the exe still works with the icon.
  dart run tool/set_exe_icon.dart build/release/server/bundle/bin/server.exe ../deploy/desktop/app-icon.ico
fi
"build/release/server/bundle/bin/server$exe" "${check[@]}"

case $os in
  windows)
    out="$DIST/$APP-$os-$arch.exe"
    mkdir -p "$DIST"
    if compgen -G "build/release/server/bundle/lib/*" >/dev/null; then
      echo "Unexpected native libraries (single exe):" build/release/server/bundle/lib/* >&2
      exit 1
    fi
    cp "build/release/server/bundle/bin/server.exe" "$out"
    dart run tool/set_gui_subsystem.dart "../dist/$(basename "$out")"
    (cd "$DIST" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
    echo "Created ${out#"$ROOT"/}"
    cat "$out.sha256"
    exit 0
    ;;
  macos)
    out="$DIST/macos-$arch"
    rm -rf "$out"
    mkdir -p "$out/bin" "$out/lib"
    cp build/release/server/bundle/bin/server "$out/bin/"
    cp -R build/release/server/bundle/lib/. "$out/lib/"
    echo "$version" > "$out/VERSION"
    echo "Created ${out#"$ROOT"/} (→ deploy/build-macos-app.sh)"
    exit 0
    ;;
esac

dart build cli -t bin/hash_password.dart -o build/release/hash_password

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/deploy"
cp "build/release/server/bundle/bin/server" "$STAGE/bin/"
cp "build/release/hash_password/bundle/bin/hash_password" "$STAGE/bin/"
cp -R build/release/server/bundle/lib/. "$STAGE/lib/"
cp -R "$ROOT/web" "$STAGE/web"
rm -f "$STAGE/web/README.md"
cp "$ROOT/deploy/gong.service" "$ROOT/deploy/gong-update.path" \
  "$ROOT/deploy/gong-update.service" "$ROOT/deploy/install.sh" "$ROOT/deploy/README.md" "$STAGE/deploy/"
chmod +x "$STAGE/deploy/install.sh"
cp "$ROOT/server/.env.example" "$STAGE/config.env.example"
cp "$ROOT/LICENSE" "$STAGE/"
echo "$version" > "$STAGE/VERSION"

archive="$APP-$os-$arch.tar.gz"
rm -f "$DIST/$archive" "$DIST/$archive.sha256"
tar -czf "$DIST/$archive" -C "$DIST" "$APP"
(cd "$DIST" && { sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive"; } > "$archive.sha256")
rm -rf "$STAGE"

echo "Created dist/$archive"
cat "$DIST/$archive.sha256"
