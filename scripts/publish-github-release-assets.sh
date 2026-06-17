#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/update-config.sh"

version="${STAYAWAKE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
tag="${STAYAWAKE_RELEASE_TAG:-v$version}"
dist="${DIST_DIR:-dist}"
source_repo="$(stayawake_github_repository)"
update_repo="$(stayawake_update_repository)"
current_branch="$(git rev-parse --abbrev-ref HEAD)"
release_title="${STAYAWAKE_RELEASE_TITLE:-StayAwake $version}"
release_notes="${STAYAWAKE_RELEASE_NOTES:-StayAwake $version}"
mirror_target="${STAYAWAKE_INSTALLER_ASSET_TARGET:-ai-mreaves@192.168.53.240:/data/applications/stayawake}"

required_assets=(
  "StayAwake-mac-arm64.zip"
  "StayAwake-mac-arm64.pkg"
  "stayawake-manifest.json"
  "install-stayawake.sh"
  "Install-StayAwake-mac-arm64.zip"
  "Install-StayAwake.dmg"
  "stayawake-installer-manifest.json"
)

asset_paths=()
for asset in "${required_assets[@]}"; do
  path="$dist/$asset"
  if [[ ! -f "$path" ]]; then
    printf 'Missing release asset: %s\n' "$path" >&2
    exit 1
  fi
  asset_paths+=("$path")
done

ensure_release() {
  local repo="$1"
  local create_args=(release create "$tag" --repo "$repo" --title "$release_title" --notes "$release_notes")
  if [[ "$repo" == "$source_repo" ]]; then
    create_args+=(--target "$current_branch")
  fi

  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    return
  fi
  gh "${create_args[@]}"
}

upload_assets() {
  local repo="$1"
  gh release upload "$tag" "${asset_paths[@]}" --repo "$repo" --clobber
}

publish_mirror() {
  local host remote_dir remote_stage
  host="${mirror_target%%:*}"
  remote_dir="${mirror_target#*:}"
  if [[ -z "$host" || -z "$remote_dir" || "$host" == "$mirror_target" ]]; then
    printf 'STAYAWAKE_INSTALLER_ASSET_TARGET must look like host:/path, got: %s\n' "$mirror_target" >&2
    exit 1
  fi
  remote_stage="/tmp/stayawake-release-assets-${tag//[^A-Za-z0-9_.-]/-}"

  ssh "$host" "rm -rf '$remote_stage' && mkdir -p '$remote_stage'"
  scp "${asset_paths[@]}" "$host:$remote_stage/"

  read -r -d '' install_command <<EOF || true
mkdir -p '$remote_dir'
install -m 0644 '$remote_stage/StayAwake-mac-arm64.zip' '$remote_dir/StayAwake-mac-arm64.zip'
install -m 0644 '$remote_stage/StayAwake-mac-arm64.pkg' '$remote_dir/StayAwake-mac-arm64.pkg'
install -m 0644 '$remote_stage/stayawake-manifest.json' '$remote_dir/stayawake-manifest.json'
install -m 0755 '$remote_stage/install-stayawake.sh' '$remote_dir/install-stayawake.sh'
install -m 0644 '$remote_stage/Install-StayAwake-mac-arm64.zip' '$remote_dir/Install-StayAwake-mac-arm64.zip'
install -m 0644 '$remote_stage/Install-StayAwake.dmg' '$remote_dir/Install-StayAwake.dmg'
install -m 0644 '$remote_stage/stayawake-installer-manifest.json' '$remote_dir/stayawake-installer-manifest.json'
EOF
  ssh "$host" "sudo -n sh -lc $(printf '%q' "$install_command")"
  ssh "$host" "rm -rf '$remote_stage'"
  printf 'Published StayAwake mirror assets to %s\n' "$mirror_target"
}

ensure_release "$source_repo"
upload_assets "$source_repo"

if [[ "$update_repo" != "$source_repo" ]]; then
  ensure_release "$update_repo"
  upload_assets "$update_repo"
fi

if [[ "${PUBLISH_INSTALLER_MIRROR:-0}" == "1" ]]; then
  publish_mirror
fi

printf 'Published StayAwake GitHub release assets for %s.\n' "$tag"
printf 'Source repo: %s\n' "$source_repo"
printf 'Update repo: %s\n' "$update_repo"
