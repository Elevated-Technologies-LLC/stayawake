#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE_ID="com.elvtech.stayawake"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.elvtech.stayawake.plist"
CONTROL_CENTER_PREF="$HOME/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
STATUS_POSITION_KEY="NSStatusItem Preferred Position StayAwakeStatusItem"

section() {
  printf '\n== %s ==\n' "$1"
}

check_processes() {
  section "Processes"
  if pgrep -x StayAwake >/dev/null; then
    pgrep -alf StayAwake
  else
    printf 'FAIL: StayAwake process is not running.\n'
    return 1
  fi

  if pgrep -x caffeinate >/dev/null; then
    pgrep -alf caffeinate
  else
    printf 'FAIL: caffeinate process is not running.\n'
    return 1
  fi
}

check_legacy_launch_agent() {
  section "Legacy LaunchAgent"
  if [[ -f "$LAUNCH_AGENT" ]]; then
    plutil -p "$LAUNCH_AGENT" || true
    printf 'FAIL: legacy StayAwake LaunchAgent still exists. StayAwake should use SMAppService instead.\n'
    return 1
  fi

  printf 'PASS: no legacy StayAwake LaunchAgent found.\n'
}

check_status_item_position() {
  section "Status Item Position"
  if /usr/bin/defaults read com.elvtech.stayawake "$STATUS_POSITION_KEY" >/dev/null 2>&1; then
    printf 'PASS: %s = %s\n' "$STATUS_POSITION_KEY" "$(/usr/bin/defaults read com.elvtech.stayawake "$STATUS_POSITION_KEY")"
  else
    printf 'FAIL: missing persisted StayAwake status item position key: %s\n' "$STATUS_POSITION_KEY"
    return 1
  fi
}

check_control_center_ownership() {
  section "Control Center Ownership"
  if [[ ! -f "$CONTROL_CENTER_PREF" ]]; then
    printf 'WARN: Control Center preference file was not found: %s\n' "$CONTROL_CENTER_PREF"
    return 0
  fi

  python3 - "$CONTROL_CENTER_PREF" "$APP_BUNDLE_ID" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
app_bundle_id = sys.argv[2]

outer = plistlib.load(path.open("rb"))
tracked_blob = outer.get("trackedApplications")
if not isinstance(tracked_blob, bytes):
    print("WARN: trackedApplications was not encoded data.")
    raise SystemExit(0)

tracked = plistlib.loads(tracked_blob)
bad_owners = []
own_rows = []

def entry_bundle(entry):
    if not isinstance(entry, dict):
        return None
    bundle = entry.get("location", {}).get("bundle") or entry.get("bundle") or {}
    if isinstance(bundle, dict):
        return bundle.get("_0")
    return None

def location_bundle(location):
    if not isinstance(location, dict):
        return None
    bundle = location.get("bundle") or {}
    if isinstance(bundle, dict):
        return bundle.get("_0")
    return None

for item in tracked:
    if not isinstance(item, dict):
        continue
    owner = entry_bundle(item)
    locations = [location_bundle(loc) for loc in item.get("menuItemLocations") or []]
    if owner == app_bundle_id:
        own_rows.append((item.get("isAllowed"), locations))
    elif app_bundle_id in locations:
        bad_owners.append((owner, item.get("isAllowed"), locations))

print(f"StayAwake own rows: {own_rows}")
if bad_owners:
    print("FAIL: StayAwake is listed under other menu-bar owners:")
    for owner, allowed, locations in bad_owners:
        print(f"  owner={owner} allowed={allowed} locations={locations}")
    raise SystemExit(2)

if not own_rows:
    print("FAIL: StayAwake has no own Control Center row.")
    raise SystemExit(3)

if not any(allowed is True and app_bundle_id in locations for allowed, locations in own_rows):
    print("FAIL: StayAwake own Control Center row is not allowed/visible.")
    raise SystemExit(4)

print("PASS: StayAwake is owned only by its own menu-bar row.")
PY
}

cat <<'EOF'
StayAwake menu-bar independence regression

Manual UI step for full validation:
1. Open System Settings > Menu Bar.
2. Turn Codex on and confirm StayAwake is visible/controllable.
3. Turn Codex off and confirm StayAwake remains visible/controllable.
4. Run this script after each state change.

The script does not modify Control Center settings.
EOF

check_processes
check_legacy_launch_agent
check_status_item_position
check_control_center_ownership
