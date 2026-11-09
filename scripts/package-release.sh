#!/bin/bash
# Packages dist/Burrow.app into the files attached to a GitHub release:
# Burrow.zip for install.sh, Burrow.dmg for manual installs, and SHA256SUMS.
set -euo pipefail

cd "$(dirname "$0")/../dist"

[[ -d Burrow.app ]] || { echo "dist/Burrow.app is missing. Run scripts/build-app.sh first." >&2; exit 1; }
rm -rf Burrow.zip Burrow.dmg SHA256SUMS dmg

ditto -c -k --keepParent Burrow.app Burrow.zip

mkdir dmg
cp -R Burrow.app dmg/
ln -s /Applications dmg/Applications
hdiutil create -quiet -volname Burrow -srcfolder dmg -format UDZO Burrow.dmg
rm -rf dmg

shasum -a 256 Burrow.zip Burrow.dmg > SHA256SUMS
cat SHA256SUMS
