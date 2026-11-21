#!/bin/bash
# Compile BuzzDock (universel Apple Silicon + Intel) et fabrique build/BuzzDock.app (signature locale).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BINDIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
BIN="$BINDIR/BuzzDock"

APP="build/BuzzDock.app"
rm -rf "build/BuzzDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BuzzDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BINDIR/BuzzWebApp" "$APP/Contents/Resources/BuzzWebApp"
# Signature stable (certificat Apple Development s'il existe) : macOS garde alors les autorisations
# (Accessibilité, automatisation) d'une version à l'autre. Sinon signature locale.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ] && perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signé avec : $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signature locale (ad hoc)"
fi

echo "OK : $APP"
