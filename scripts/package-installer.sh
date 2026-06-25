#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/update-config.sh"

version="${STAYAWAKE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
build="${STAYAWAKE_BUILD:-${GITHUB_RUN_NUMBER:-1}}"
dist="${DIST_DIR:-dist}"
build_dist="${STAYAWAKE_INSTALLER_BUILD_DIST:-$(mktemp -d "${TMPDIR:-/tmp}/stayawake-installer-build.XXXXXX")}"
app_name="Install StayAwake"
app_dir="$build_dist/$app_name.app"
zip_name="Install-StayAwake-mac-arm64.zip"
dmg_name="Install-StayAwake.dmg"
manifest_name="stayawake-installer-manifest.json"

notarization_requested() {
  case "${STAYAWAKE_NOTARIZE:-0}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

enforce_internal_release_policy() {
  if notarization_requested; then
    printf 'STAYAWAKE_NOTARIZE=1 requested, but this internal release flow is configured not to contact Apple.\n' >&2
    printf 'Use a dedicated notarization flow if an external distribution ever needs Apple notarization.\n' >&2
    exit 64
  fi
}

internal_signature_report() {
  local signed_app="$1"
  local label="$2"
  local signature_info
  signature_info="$(codesign -dv --verbose=4 "$signed_app" 2>&1)"
  if grep -F 'Authority=Developer ID Application: Elevated Technologies LLC (8HBASZNPZ4)' <<<"$signature_info" >/dev/null; then
    printf '%s verification: Developer ID signed, notarization intentionally skipped for internal company deployment.\n' "$label"
  else
    printf '%s verification: codesign valid, notarization intentionally skipped for internal company deployment.\n' "$label"
    grep -m 1 '^Authority=' <<<"$signature_info" | sed 's/^/Signing identity: /' || true
  fi
}

signature_notes() {
  local signed_app="$1"
  local signature_info
  signature_info="$(codesign -dv --verbose=4 "$signed_app" 2>&1)"
  if grep -F 'Authority=Developer ID Application: Elevated Technologies LLC (8HBASZNPZ4)' <<<"$signature_info" >/dev/null; then
    printf 'Developer ID signed StayAwake installer for internal company deployment; notarization intentionally skipped.'
  elif grep -F 'Signature=adhoc' <<<"$signature_info" >/dev/null; then
    printf 'Ad-hoc signed StayAwake installer local validation build; rebuild with the Elevated Technologies Developer ID identity before company deployment.'
  else
    printf 'Codesigned StayAwake installer for internal company deployment; notarization intentionally skipped.'
  fi
}

cleanup() {
  if [[ -z "${STAYAWAKE_INSTALLER_BUILD_DIST:-}" ]]; then
    rm -rf "$build_dist"
  fi
}
trap cleanup EXIT

clean_app_metadata() {
  local path="$1"
  find "$path" -name '._*' -delete 2>/dev/null || true
  find "$path" -name '.DS_Store' -delete 2>/dev/null || true
  xattr -cr "$path" 2>/dev/null || true
  find "$path" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
  find "$path" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
  find "$path" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
}

enforce_internal_release_policy

mkdir -p "$dist"
rm -rf "$app_dir" "$dist/$zip_name" "$dist/$dmg_name" "$dist/$manifest_name"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

swiftc -O -parse-as-library \
  -framework AppKit \
  -framework CryptoKit \
  Sources/Shared/UpdateConfig.swift \
  Sources/InstallStayAwake/main.swift \
  -o "$app_dir/Contents/MacOS/$app_name"
chmod 755 "$app_dir/Contents/MacOS/$app_name"

cp -X "$ROOT/Assets/StayAwake.icns" "$app_dir/Contents/Resources/AppIcon.icns"
if [[ -f "$dist/StayAwake-mac-arm64.zip" && -f "$dist/stayawake-manifest.json" ]]; then
  cp -X "$dist/StayAwake-mac-arm64.zip" "$app_dir/Contents/Resources/StayAwake-mac-arm64.zip"
  cp -X "$dist/stayawake-manifest.json" "$app_dir/Contents/Resources/stayawake-manifest.json"
else
  printf 'Warning: app package assets were not found; installer will download the current public release at runtime.\n' >&2
fi

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleExecutable</key>
  <string>$app_name</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.elvtech.stayawake.installer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$build</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Install StayAwake may request administrator approval to copy StayAwake into Applications.</string>
</dict>
</plist>
PLIST

plutil -lint "$app_dir/Contents/Info.plist" >/dev/null
clean_app_metadata "$app_dir"

sign_identity="${STAYAWAKE_CODESIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
developer_id_identity="Developer ID Application: Elevated Technologies LLC (8HBASZNPZ4)"
if [[ -z "$sign_identity" ]] && security find-identity -v -p codesigning | grep -F "$developer_id_identity" >/dev/null 2>&1; then
  sign_identity="$developer_id_identity"
fi
if [[ -z "$sign_identity" ]]; then
  sign_identity="-"
fi

codesign_args=(--force --sign "$sign_identity")
if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
  codesign_args+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
if [[ -n "${CODE_SIGN_OPTIONS:-}" ]]; then
  # shellcheck disable=SC2206
  code_sign_options_array=(${CODE_SIGN_OPTIONS})
  codesign_args+=("${code_sign_options_array[@]}")
elif [[ "$sign_identity" == Developer\ ID\ Application:* ]]; then
  codesign_args+=(--options runtime --timestamp)
fi
if [[ -n "${CODE_SIGN_ENTITLEMENTS:-}" ]]; then
  codesign_args+=(--entitlements "$CODE_SIGN_ENTITLEMENTS")
fi

codesign "${codesign_args[@]}" "$app_dir/Contents/MacOS/$app_name" >/dev/null
clean_app_metadata "$app_dir"
codesign "${codesign_args[@]}" "$app_dir" >/dev/null
clean_app_metadata "$app_dir"
codesign --verify --deep --strict "$app_dir"
internal_signature_report "$app_dir" "Installer app"

ditto --noextattr --norsrc -c -k --keepParent "$app_dir" "$dist/$zip_name"
hdiutil create -quiet -volname "$app_name" -srcfolder "$app_dir" -ov -format UDZO "$dist/$dmg_name"

zip_sha="$(shasum -a 256 "$dist/$zip_name" | awk '{print $1}')"
dmg_sha="$(shasum -a 256 "$dist/$dmg_name" | awk '{print $1}')"
zip_size="$(stat -f%z "$dist/$zip_name")"
dmg_size="$(stat -f%z "$dist/$dmg_name")"
released_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
release_notes="$(signature_notes "$app_dir")"
asset_base_url="$(stayawake_update_asset_base_url)"

cat > "$dist/$manifest_name" <<JSON
{
  "app": "Install StayAwake",
  "version": "$version",
  "released_at": "$released_at",
  "minimum_macos": "13.0",
  "notes": "$release_notes",
  "assets": {
    "mac_arm64_zip": {
      "url": "$asset_base_url/$zip_name",
      "sha256": "$zip_sha",
      "size": $zip_size
    },
    "mac_arm64_dmg": {
      "url": "$asset_base_url/$dmg_name",
      "sha256": "$dmg_sha",
      "size": $dmg_size
    }
  }
}
JSON

shasum -a 256 "$dist/$zip_name" "$dist/$dmg_name" "$dist/$manifest_name"
printf 'Installer artifacts:\n%s\n%s\n%s\n%s\n' "$app_dir" "$dist/$zip_name" "$dist/$dmg_name" "$dist/$manifest_name"
printf 'Signed with %s\n' "$sign_identity"
