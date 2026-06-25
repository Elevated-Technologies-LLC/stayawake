#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="Elevated-Technologies-LLC/stayawake"
DEFAULT_UPDATE_REPO="Elevated-Technologies-LLC/stayawake-updates"

trim_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

clean_value() {
  local trimmed
  trimmed="$(trim_value "${1:-}")"
  if [[ -n "$trimmed" ]]; then
    printf '%s' "$trimmed"
  fi
}

update_repo() {
  local explicit
  explicit="$(clean_value "${STAYAWAKE_UPDATE_REPOSITORY:-${STAYAWAKE_UPDATE_REPO:-}}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi

  local repo
  repo="$(clean_value "${STAYAWAKE_GITHUB_REPOSITORY:-${STAYAWAKE_GITHUB_REPO:-${STAYAWAKE_REPO:-}}}")"
  repo="${repo:-$DEFAULT_REPO}"
  if [[ "$repo" == "$DEFAULT_REPO" ]]; then
    printf '%s\n' "$DEFAULT_UPDATE_REPO"
  else
    printf '%s\n' "$repo"
  fi
}

update_manifest_url() {
  local explicit
  explicit="$(clean_value "${STAYAWAKE_UPDATE_MANIFEST_URL:-}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi

  local base
  base="$(clean_value "${STAYAWAKE_UPDATE_ASSET_BASE_URL:-}")"
  base="${base%/}"
  if [[ -z "$base" ]]; then
    base="https://github.com/$(update_repo)/releases/latest/download"
  fi
  printf '%s/stayawake-manifest.json\n' "$base"
}

installer_manifest_url() {
  local explicit
  explicit="$(clean_value "${STAYAWAKE_INSTALLER_MANIFEST_URL:-}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi

  local base
  base="$(clean_value "${STAYAWAKE_UPDATE_ASSET_BASE_URL:-}")"
  base="${base%/}"
  if [[ -z "$base" ]]; then
    base="https://github.com/$(update_repo)/releases/latest/download"
  fi
  printf '%s/stayawake-installer-manifest.json\n' "$base"
}

APP_MANIFEST_URL="$(update_manifest_url)"
INSTALLER_MANIFEST_URL="$(installer_manifest_url)"
INSTALL_DIR="${STAYAWAKE_INSTALL_DIR:-/Applications}"
APP_PATH="$INSTALL_DIR/StayAwake.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.elvtech.stayawake.plist"
LOG_DIR="$HOME/Library/Logs"

MODE="${STAYAWAKE_INSTALL_MODE:-}"
if [[ -z "$MODE" ]]; then
  if [[ -n "${SSH_CONNECTION:-}" || -n "${CI:-}" ]]; then
    MODE="direct"
  else
    MODE="gui"
  fi
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

extract_json_value() {
  local file="$1"
  local key="$2"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "$file" | head -n 1
}

extract_installer_zip_field() {
  local file="$1"
  local field="$2"
  awk -v field="$field" '
    /"mac_arm64_zip"[[:space:]]*:/ { inside=1; next }
    inside {
      if ($0 ~ "^[[:space:]]*}") {
        inside=0
        next
      }
      if ($0 ~ "\"" field "\"[[:space:]]*:[[:space:]]*\"") {
        line = $0
        sub("^.*\"" field "\"[[:space:]]*:[[:space:]]*\"", "", line)
        sub("\".*$", "", line)
        print line
        exit
      }
    }
  ' "$file"
}

verify_sha() {
  local file="$1"
  local expected="$2"
  if [[ -n "$expected" ]]; then
    local actual
    actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      echo "Checksum mismatch."
      echo "Expected: $expected"
      echo "Actual:   $actual"
      exit 1
    fi
  fi
}

run_gui_installer() {
  local manifest="$WORK_DIR/stayawake-installer-manifest.json"
  local zip="$WORK_DIR/Install-StayAwake-mac-arm64.zip"
  local extract="$WORK_DIR/gui"
  local bundle="$extract/Install StayAwake.app"

  echo "Downloading StayAwake installer manifest..."
  if ! /usr/bin/curl -fsSL "$INSTALLER_MANIFEST_URL" -o "$manifest"; then
    return 1
  fi
  local zip_url expected_sha
  zip_url="$(extract_installer_zip_field "$manifest" url)"
  expected_sha="$(extract_installer_zip_field "$manifest" sha256)"
  if [[ -z "$zip_url" ]]; then
    echo "Installer manifest did not include a macOS ZIP asset."
    return 1
  fi

  echo "Downloading Install StayAwake..."
  if ! /usr/bin/curl -fL "$zip_url" -o "$zip"; then
    return 1
  fi
  verify_sha "$zip" "$expected_sha"

  mkdir -p "$extract"
  if ! /usr/bin/ditto -x -k "$zip" "$extract"; then
    return 1
  fi
  if [[ ! -d "$bundle" ]]; then
    echo "Install StayAwake.app was not found in the downloaded ZIP."
    return 1
  fi

  echo "Launching Install StayAwake..."
  STAYAWAKE_INSTALL_DIR="$INSTALL_DIR" "$bundle/Contents/MacOS/Install StayAwake"
}

run_direct_install() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"

  local manifest="$WORK_DIR/stayawake-manifest.json"
  local zip="$WORK_DIR/StayAwake-mac-arm64.zip"

  echo "Downloading StayAwake manifest..."
  /usr/bin/curl -fsSL "$APP_MANIFEST_URL" -o "$manifest"
  local expected_sha app_zip_url
  expected_sha="$(extract_json_value "$manifest" sha256)"
  app_zip_url="$(extract_json_value "$manifest" url)"
  if [[ -z "$app_zip_url" ]]; then
    echo "StayAwake manifest did not include a macOS ZIP asset."
    exit 1
  fi

  echo "Downloading StayAwake..."
  /usr/bin/curl -fL "$app_zip_url" -o "$zip"
  verify_sha "$zip" "$expected_sha"

  /usr/bin/pkill -x StayAwake >/dev/null 2>&1 || true
  /bin/sleep 1

  if [[ -d "$APP_PATH" ]]; then
    local backup
    backup="$INSTALL_DIR/StayAwake.app.backup.$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
    /bin/mv "$APP_PATH" "$backup"
  fi

  /usr/bin/ditto -x -k "$zip" "$WORK_DIR"
  if [[ ! -d "$WORK_DIR/StayAwake.app" ]]; then
    echo "StayAwake.app was not found in the downloaded ZIP."
    exit 1
  fi

  /usr/bin/ditto "$WORK_DIR/StayAwake.app" "$APP_PATH"
  /usr/bin/xattr -cr "$APP_PATH" >/dev/null 2>&1 || true

  mkdir -p "$(dirname "$LAUNCH_AGENT")"
  cat > "$LAUNCH_AGENT" <<PLIST
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
	    <string>-gj</string>
	    <string>$APP_PATH</string>
	  </array>
	  <key>AssociatedBundleIdentifiers</key>
	  <array>
	    <string>com.elvtech.stayawake</string>
	  </array>
	  <key>LimitLoadToSessionType</key>
	  <string>Aqua</string>
	  <key>RunAtLoad</key>
	  <true/>
	  <key>KeepAlive</key>
	  <false/>
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
}

case "$MODE" in
  gui)
    if ! run_gui_installer; then
      echo "Graphical installer unavailable; falling back to direct install..."
      run_direct_install
    fi
    ;;
  direct)
    run_direct_install
    ;;
  *)
    echo "Unknown STAYAWAKE_INSTALL_MODE: $MODE" >&2
    exit 64
    ;;
esac
