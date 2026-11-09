#!/usr/bin/env bash
# Builds a release archive for the current OS/architecture:
#   dist/schulportal-client-<os>-<arch>.tar.gz (+ .sha256)
#
# Contents (top-level directory schulportal-client/):
#   bin/server, bin/hash_password   native executables
#   lib/                            bundled native libraries (SQLite)
#   web/                            web UI
#   deploy/                         systemd unit, install.sh, README
#   config.env.example, LICENSE, VERSION
#
# Linux binaries need a glibc at least as new as the build machine's; build on
# Debian 12 / Ubuntu 22.04 (or older) to run on Debian 12 and 13.

set -euo pipefail

APP=schulportal-client
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
dart pub get
rm -rf build/release
dart build cli -t bin/server.dart -o build/release/server
dart build cli -t bin/hash_password.dart -o build/release/hash_password

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/deploy"
cp "build/release/server/bundle/bin/server$exe" "$STAGE/bin/"
cp "build/release/hash_password/bundle/bin/hash_password$exe" "$STAGE/bin/"
cp -R build/release/server/bundle/lib/. "$STAGE/lib/"

cp -R "$ROOT/web" "$STAGE/web"
rm -f "$STAGE/web/README.md"
cp "$ROOT/deploy/schulportal-client.service" "$ROOT/deploy/install.sh" "$ROOT/deploy/README.md" "$STAGE/deploy/"
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
