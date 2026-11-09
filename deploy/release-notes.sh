#!/usr/bin/env bash
# Prints the GitHub release notes for a version from CHANGELOG.md:
# the version's section, install/update instructions and a compare link.
#
#   bash deploy/release-notes.sh v0.3.0 > notes.md
#
# Fails if CHANGELOG.md has no (non-empty) section for the version.

set -euo pipefail

REPO=${REPO:-StefanRiese/ranzen}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:?usage: release-notes.sh vX.Y.Z}
version=${version#v}

# Lines after "## [X.Y.Z]" up to the next "## [" heading or the link references,
# without leading/trailing blank lines.
section=$(awk -v v="$version" '
  index($0, "## [" v "]") == 1 { found = 1; next }
  found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
  found { lines[++n] = $0 }
  END {
    first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
    last = n;  while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = first; i <= last; i++) print lines[i]
  }
' "$ROOT/CHANGELOG.md")

if [[ -z ${section//[[:space:]]/} ]]; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi

previous=$(git -C "$ROOT" describe --tags --abbrev=0 "v$version^" 2>/dev/null || true)
if [[ -n $previous ]]; then
  compare="https://github.com/$REPO/compare/$previous...v$version"
else
  compare="https://github.com/$REPO/commits/v$version"
fi

cat <<NOTES
$section

### Installation / Update

\`\`\`sh
# first installation (Debian/Ubuntu, e.g. Proxmox LXC)
curl -fsSLO https://raw.githubusercontent.com/$REPO/main/deploy/install.sh
bash install.sh

# update an existing installation
bash /opt/ranzen/deploy/install.sh
\`\`\`

**Windows (x64):** download \`ranzen-windows-x64.exe\` and start it – it runs in the
notification area (right click on the icon for the menu).
**macOS (Apple Silicon + Intel):** unzip \`ranzen-macos-universal.zip\`, move the app
to Programme and open it with right click → Öffnen the first time; it runs in the menu bar.
See [deploy/DESKTOP.md](https://github.com/$REPO/blob/v$version/deploy/DESKTOP.md).

**Full Changelog**: $compare
NOTES
