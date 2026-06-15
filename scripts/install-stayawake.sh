#!/usr/bin/env bash
set -euo pipefail

REPO="${STAYAWAKE_REPO:-Elevated-Technologies-LLC/stayawake}"
MANIFEST_URL="https://github.com/${REPO}/releases/latest/download/stayawake-manifest.json"
ZIP_URL="https://github.com/${REPO}/releases/latest/download/StayAwake-mac-arm64.zip"
INSTALL_DIR="${STAYAWAKE_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/StayAwake.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.elvtech.stayawake.plist"
LOG_DIR="$HOME/Library/Logs"

mkdir -p "$INSTALL_DIR" "$LOG_DIR"
WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

MANIFEST="$WORK_DIR/stayawake-manifest.json"
ZIP="$WORK_DIR/StayAwake-mac-arm64.zip"

echo "Downloading StayAwake manifest..."
/usr/bin/curl -fsSL "$MANIFEST_URL" -o "$MANIFEST"
EXPECTED_SHA="$(/usr/bin/sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$MANIFEST" | /usr/bin/head -1)"

echo "Downloading StayAwake..."
/usr/bin/curl -fL "$ZIP_URL" -o "$ZIP"

if [[ -n "$EXPECTED_SHA" ]]; then
  ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
  if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "Checksum mismatch."
    echo "Expected: $EXPECTED_SHA"
    echo "Actual:   $ACTUAL_SHA"
    exit 1
  fi
fi

/usr/bin/pkill -x StayAwake >/dev/null 2>&1 || true
/bin/sleep 1

if [[ -d "$APP_PATH" ]]; then
  BACKUP="$INSTALL_DIR/StayAwake.app.backup.$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  /bin/mv "$APP_PATH" "$BACKUP"
fi

/usr/bin/ditto -x -k "$ZIP" "$WORK_DIR"
if [[ ! -d "$WORK_DIR/StayAwake.app" ]]; then
  echo "StayAwake.app was not found in the downloaded ZIP."
  exit 1
fi

/usr/bin/ditto "$WORK_DIR/StayAwake.app" "$APP_PATH"
/usr/bin/xattr -cr "$APP_PATH" >/dev/null 2>&1 || true

mkdir -p "$(dirname "$LAUNCH_AGENT")"
/bin/cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.elvtech.stayawake</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-W</string>
    <string>$APP_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/StayAwake.launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/StayAwake.launchd.err</string>
</dict>
</plist>
PLIST

/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
/bin/launchctl enable "gui/$(/usr/bin/id -u)/com.elvtech.stayawake" >/dev/null 2>&1 || true
/usr/bin/open "$APP_PATH"

echo "StayAwake installed at $APP_PATH"
