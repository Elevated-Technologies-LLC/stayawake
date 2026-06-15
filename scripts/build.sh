#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="${STAYAWAKE_BUILD:-${GITHUB_RUN_NUMBER:-1}}"
DIST="$ROOT/dist"
APP="$DIST/StayAwake.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

/usr/bin/sed \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__BUILD__/$BUILD/g" \
  "$ROOT/Info.plist" > "$APP/Contents/Info.plist"

/usr/bin/swiftc \
  "$ROOT/Sources/StayAwake/StayAwake.swift" \
  -o "$APP/Contents/MacOS/StayAwake"

/bin/cp "$ROOT/Assets/StayAwake.icns" "$APP/Contents/Resources/StayAwake.icns"
/usr/bin/touch "$APP"
/usr/bin/xattr -cr "$APP" >/dev/null 2>&1 || true

if [[ -n "${STAYAWAKE_CODESIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --deep --options runtime --sign "$STAYAWAKE_CODESIGN_IDENTITY" "$APP"
else
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

/usr/bin/codesign -v "$APP"
echo "Built $APP ($VERSION build $BUILD)"
