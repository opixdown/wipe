#!/bin/sh
# Tags the current version and attaches the binaries to a GitHub release.
# Usage: scripts/release.sh   (after scripts/build.sh)
set -e
cd "$(dirname "$0")/.."
v="v$(site/dist/wipe-macos -v)"
gh release create "$v" site/dist/wipe-macos site/dist/wipe-windows-amd64.exe site/dist/wipe-windows-arm64.exe \
  --title "wipe ${v#v}" --generate-notes
