#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
APP="$DIST/StayAwake.app"
ZIP="$DIST/StayAwake-mac-arm64.zip"
PKG="$DIST/StayAwake-mac-arm64.pkg"
MANIFEST="$DIST/stayawake-manifest.json"
INSTALLER="$DIST/install-stayawake.sh"

"$ROOT/scripts/build.sh"

/bin/rm -f "$ZIP" "$PKG" "$MANIFEST" "$INSTALLER"
(
  cd "$DIST"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "StayAwake.app" "$ZIP"
)

if command -v pkgbuild >/dev/null 2>&1; then
  /usr/bin/pkgbuild \
    --component "$APP" \
    --install-location "/Applications" \
    --identifier "com.elvtech.stayawake.pkg" \
    --version "$VERSION" \
    "$PKG"
fi

/bin/cp "$ROOT/scripts/install-stayawake.sh" "$INSTALLER"
/bin/chmod +x "$INSTALLER"

SHA256="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
SIZE="$(/usr/bin/stat -f '%z' "$ZIP")"
NOW="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

/bin/cat > "$MANIFEST" <<JSON
{
  "version": "$VERSION",
  "published_at": "$NOW",
  "minimum_system_version": "13.0",
  "notes": "StayAwake $VERSION",
  "assets": {
    "mac_arm64": {
      "url": "https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/StayAwake-mac-arm64.zip",
      "sha256": "$SHA256",
      "size": $SIZE
    }
  }
}
JSON

echo "Packaged:"
echo "  $ZIP"
echo "  $MANIFEST"
echo "  $INSTALLER"
if [[ -f "$PKG" ]]; then
  echo "  $PKG"
fi
