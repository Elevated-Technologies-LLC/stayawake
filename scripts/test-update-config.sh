#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/update-config.sh"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stayawake-update-config-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

expect_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

expect_in_subshell() {
  local expected="$1"
  local message="$2"
  shift 2
  local actual
  actual="$(
    (
      "$@"
    )
  )"
  expect_eq "$actual" "$expected" "$message"
}

expect_eq "$(stayawake_github_repository)" "Elevated-Technologies-LLC/stayawake" "default source repo should stay on stayawake"
expect_eq "$(stayawake_update_repository)" "Elevated-Technologies-LLC/stayawake-updates" "default update repo should use the public updates repo"
expect_eq "$(stayawake_update_manifest_url)" "https://github.com/Elevated-Technologies-LLC/stayawake-updates/releases/latest/download/stayawake-manifest.json" "default manifest URL should use the updates repo"
expect_eq "$(stayawake_installer_manifest_url)" "https://github.com/Elevated-Technologies-LLC/stayawake-updates/releases/latest/download/stayawake-installer-manifest.json" "default installer manifest should use the updates repo"

expect_in_subshell "example/source" "custom source repo should double as the update repo when no override is present" bash -lc "source '$ROOT/scripts/update-config.sh'; export STAYAWAKE_GITHUB_REPOSITORY='example/source'; stayawake_update_repository"
expect_in_subshell "https://github.com/example/updates/releases/latest/download/stayawake-manifest.json" "explicit update repo should shape the manifest URL" bash -lc "source '$ROOT/scripts/update-config.sh'; export STAYAWAKE_GITHUB_REPOSITORY='example/source' STAYAWAKE_UPDATE_REPOSITORY='example/updates'; stayawake_update_manifest_url"
expect_in_subshell "https://updates.example.invalid/stayawake/stayawake-manifest.json" "custom base URL should trim trailing slash" bash -lc "source '$ROOT/scripts/update-config.sh'; export STAYAWAKE_UPDATE_ASSET_BASE_URL='https://updates.example.invalid/stayawake/'; stayawake_update_manifest_url"
expect_in_subshell "https://mirror.example.invalid/stayawake/stayawake-installer-manifest.json" "explicit installer manifest URL should win" bash -lc "source '$ROOT/scripts/update-config.sh'; export STAYAWAKE_INSTALLER_MANIFEST_URL='https://mirror.example.invalid/stayawake/stayawake-installer-manifest.json'; stayawake_installer_manifest_url"

printf 'StayAwake shell update config tests passed\n'

swiftc \
  "$ROOT/Sources/Shared/UpdateConfig.swift" \
  "$ROOT/Sources/Shared/UpdateConfigTests.swift" \
  -o "$BUILD_DIR/stayawake-update-config-tests"

"$BUILD_DIR/stayawake-update-config-tests"
