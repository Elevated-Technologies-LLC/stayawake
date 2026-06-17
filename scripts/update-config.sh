#!/usr/bin/env bash
set -euo pipefail

readonly STAYAWAKE_DEFAULT_GITHUB_REPOSITORY="Elevated-Technologies-LLC/stayawake"
readonly STAYAWAKE_DEFAULT_UPDATE_REPOSITORY="Elevated-Technologies-LLC/stayawake-updates"

trim_stayawake_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

clean_stayawake_value() {
  local trimmed
  trimmed="$(trim_stayawake_value "${1:-}")"
  if [[ -n "$trimmed" ]]; then
    printf '%s' "$trimmed"
  fi
}

clean_stayawake_base_url() {
  local value
  value="$(clean_stayawake_value "${1:-}")"
  value="${value%/}"
  printf '%s' "$value"
}

stayawake_github_repository() {
  local value
  value="$(clean_stayawake_value "${STAYAWAKE_GITHUB_REPOSITORY:-${STAYAWAKE_GITHUB_REPO:-}}")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$STAYAWAKE_DEFAULT_GITHUB_REPOSITORY"
  fi
}

stayawake_update_repository() {
  local explicit
  explicit="$(clean_stayawake_value "${STAYAWAKE_UPDATE_REPOSITORY:-${STAYAWAKE_UPDATE_REPO:-}}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi

  local repository
  repository="$(stayawake_github_repository)"
  if [[ "$repository" == "$STAYAWAKE_DEFAULT_GITHUB_REPOSITORY" ]]; then
    printf '%s\n' "$STAYAWAKE_DEFAULT_UPDATE_REPOSITORY"
  else
    printf '%s\n' "$repository"
  fi
}

stayawake_update_asset_base_url() {
  local explicit
  explicit="$(clean_stayawake_base_url "${STAYAWAKE_UPDATE_ASSET_BASE_URL:-}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi
  printf 'https://github.com/%s/releases/latest/download\n' "$(stayawake_update_repository)"
}

stayawake_update_manifest_url() {
  local explicit
  explicit="$(clean_stayawake_value "${STAYAWAKE_UPDATE_MANIFEST_URL:-}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi
  printf '%s/stayawake-manifest.json\n' "$(stayawake_update_asset_base_url)"
}

stayawake_installer_manifest_url() {
  local explicit
  explicit="$(clean_stayawake_value "${STAYAWAKE_INSTALLER_MANIFEST_URL:-}")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return
  fi
  printf '%s/stayawake-installer-manifest.json\n' "$(stayawake_update_asset_base_url)"
}
