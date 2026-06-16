#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="${STAYAWAKE_BUILD:-${GITHUB_RUN_NUMBER:-1}}"
DIST="$ROOT/dist"
APP="$DIST/StayAwake.app"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/stayawake-build.XXXXXX")"
BUILD_APP="$WORK_DIR/StayAwake.app"
DEFAULT_CODESIGN_IDENTITY="Developer ID Application: Elevated Technologies LLC (8HBASZNPZ4)"
CODESIGN_IDENTITY="${STAYAWAKE_CODESIGN_IDENTITY:-}"
EXPECTED_TEAM_ID="${STAYAWAKE_TEAM_ID:-8HBASZNPZ4}"

cleanup() {
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -z "$CODESIGN_IDENTITY" ]] && /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$DEFAULT_CODESIGN_IDENTITY"; then
  CODESIGN_IDENTITY="$DEFAULT_CODESIGN_IDENTITY"
fi

rm -rf "$APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$DIST"

/usr/bin/sed \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__BUILD__/$BUILD/g" \
  "$ROOT/Info.plist" > "$BUILD_APP/Contents/Info.plist"

/usr/bin/swiftc \
  "$ROOT/Sources/StayAwake/StayAwake.swift" \
  -o "$BUILD_APP/Contents/MacOS/StayAwake"

/bin/cp -X "$ROOT/Assets/StayAwake.icns" "$BUILD_APP/Contents/Resources/StayAwake.icns"
/usr/bin/touch "$BUILD_APP"
/usr/bin/xattr -cr "$BUILD_APP" >/dev/null 2>&1 || true

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$BUILD_APP"
else
  /usr/bin/codesign --force --deep --sign - "$BUILD_APP"
fi

/usr/bin/codesign --verify --deep --strict "$BUILD_APP"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$BUILD_APP" 2>&1 | /usr/bin/sed -nE 's/^TeamIdentifier=(.*)$/\1/p' | /usr/bin/head -1)"
  if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "Expected TeamIdentifier $EXPECTED_TEAM_ID but found ${TEAM_ID:-none}." >&2
    exit 1
  fi
fi

/usr/bin/ditto "$BUILD_APP" "$APP"
echo "Built $APP ($VERSION build $BUILD)"
