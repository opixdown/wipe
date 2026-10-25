#!/bin/sh
# Publishes site/ (website, installers and site/dist binaries) to wipemode.vercel.app.
# Run scripts/build.sh first so the binaries are current.
set -e
cd "$(dirname "$0")/../site"
[ -f dist/wipe-macos ] || { echo "site/dist is empty — run scripts/build.sh first"; exit 1; }
npx -y vercel@latest deploy --prod --yes
