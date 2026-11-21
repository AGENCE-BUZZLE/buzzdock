#!/bin/bash
# Fabrique build/BuzzDock.dmg (app + raccourci vers Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

STAGE="build/dmg"
rm -rf "build/dmg" "build/BuzzDock.dmg"
mkdir -p "$STAGE"
cp -R build/BuzzDock.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "BuzzDock" -srcfolder "$STAGE" -ov -format UDZO build/BuzzDock.dmg

echo "OK : build/BuzzDock.dmg"
