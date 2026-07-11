#!/bin/sh
# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, idempotent installer for oCIS web extensions.
#              Utilizes a Manifest Cache pattern to bypass heavy downloads
#              and unnecessary extraction if extensions are already up-to-date.
#              Orphaned extensions managed by THIS script are surgically purged
#              to ensure strict parity, without affecting shared volume assets
#              installed by other init containers.
#
# Usage: ./init-extensions.sh [author/repo:version] ...
# Example: ./init-extensions.sh LukasHirt/web-app-excalidraw:latest mschlachter/ocis-app-tokens:1.0.0
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DEST_DIR="/apps"
MANIFEST_FILE="${DEST_DIR}/.extension_manifest.json"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "[INIT] Installing required dependencies: jq, unzip, tar, wget..." >&2
  apk add --no-cache -q jq unzip tar wget
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Initialize and validate the Manifest Cache
mkdir -p "$DEST_DIR"
if [ ! -f "$MANIFEST_FILE" ] || ! jq . "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "[INIT] Manifest cache missing or corrupted. Resetting baseline..." >&2
  echo "{}" > "$MANIFEST_FILE"
fi

# ------------------------------------------------------------------------------
# 2. Cache & API Helpers (DRY)
# ------------------------------------------------------------------------------

# Wrapper for GitHub API requests with network error handling
github_api_req() {
  local endpoint="$1"
  local response_file="${TEMP_WORKSPACE}/api_response.json"
  local status=0

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    wget -qO "$response_file" --header="Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/${endpoint}" || status=$?
  else
    wget -qO "$response_file" "https://api.github.com/${endpoint}" || status=$?
  fi

  # Redirect diagnostic logs to stderr to protect stdout data streams
  if [ "$status" -ne 0 ] || [ ! -f "$response_file" ]; then
    echo "[ERROR] GitHub API request failed (Status: ${status}). Check connectivity or GITHUB_TOKEN." >&2
    exit 1
  fi

  cat "$response_file"
}

get_latest_version() {
  local repo="$1"
  local json_payload=""
  local res=""

  json_payload=$(github_api_req "repos/${repo}/releases/latest")
  res=$(echo "$json_payload" | jq -r '.tag_name // empty')

  if [ -z "$res" ]; then
    echo "[ERROR] Could not extract valid release tag information for repository: ${repo}" >&2
    exit 1
  fi
  echo "$res"
}

get_cached_version() {
  local repo="$1"
  # Safe navigation index removed due to isolated string pipe execution handling
  jq -r --arg r "$repo" '.[$r].version // empty' "$MANIFEST_FILE"
}

# Atomic cache writing to prevent corruption on unexpected container stops
update_cache() {
  local repo="$1"
  local version="$2"
  local tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"

  jq --arg r "$repo" --arg v "$version" '.[$r] = {version: $v}' "$MANIFEST_FILE" > "$tmp_file"
  mv "$tmp_file" "$MANIFEST_FILE"
}

# ------------------------------------------------------------------------------
# 3. File System Pipelines
# ------------------------------------------------------------------------------

download_and_extract() {
  local url="$1"
  local extract_dir="${TEMP_WORKSPACE}/$(cat /proc/sys/kernel/random/uuid)"
  local filename="${url##*/}"
  local archive="${extract_dir}/${filename}"

  mkdir -p "$extract_dir"
  wget -qO "$archive" "$url"

  # Route extraction method based on file extension
  if echo "$filename" | grep -q -i '\.zip$'; then
    unzip -q -o "$archive" -d "$extract_dir"
  elif echo "$filename" | grep -q -iE '\.(tar\.gz|tgz)$'; then
    tar -xzf "$archive" -C "$extract_dir" 2>/dev/null
  else
    echo "[ERROR] Unsupported archive format for ${filename}" >&2
    exit 1
  fi

  rm -f "$archive"
  echo "$extract_dir"
}

install_extension() {
  local repo="$1"
  local version="$2"
  local app_name="${repo##*/}"
  local final_dest="${DEST_DIR}/${app_name}"

  echo "[INSTALL] Target: ${repo} @ ${version}..." >&2

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local asset_url=$(echo "$api_json" | jq -r '
    .assets[]? |
    select(.name | test("\\.(zip|tar\\.gz|tgz)$"; "i")) |
    .browser_download_url
  ' | head -n 1)

  if [ -z "$asset_url" ]; then
    echo "[ERROR] No suitable .zip or .tar.gz release asset found for ${repo}." >&2
    exit 1
  fi

  echo "[INSTALL] Downloading archive from ${asset_url##*/}..." >&2
  local extracted_dir=$(download_and_extract "$asset_url")
  local manifest_file=$(find "$extracted_dir" -name "manifest.json" | head -n 1)

  if [ -z "$manifest_file" ]; then
    echo "[ERROR] manifest.json not found inside release archive for ${repo}!" >&2
    exit 1
  fi

  local component_dir=$(dirname "$manifest_file")

  # Cleanly overwrite during an update
  rm -rf "$final_dest"
  mv "$component_dir" "$final_dest"

  update_cache "$repo" "$version"
  echo "[SUCCESS] Installed ${app_name} successfully." >&2
}

# ==============================================================================
# 4. Main Execution (The Cache Logic Controller)
# ==============================================================================

if [ "$#" -eq 0 ]; then
  echo "[INIT] No extensions specified to install." >&2
  exit 0
fi

# POSIX strings to track valid components for declarative cleanup
VALID_APPS=":"
VALID_REPOS=":"

for arg in "$@"; do
  REPO="${arg%%:*}"
  TARGET_VERSION="${arg##*:}"
  APP_NAME="${REPO##*/}"
  VALID_REPOS="${VALID_REPOS}${REPO}:"

  # Resolve "latest" tag definitions via isolation variable assignments
  if [ "$REPO" = "$TARGET_VERSION" ] || [ "$TARGET_VERSION" = "latest" ] || [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(get_latest_version "$REPO")
  fi

  VALID_APPS="${VALID_APPS}${APP_NAME}:"
  CACHED_VERSION=$(get_cached_version "$REPO")

  # Verify folder existence along with version match to catch uncompleted pipeline updates
  if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -d "${DEST_DIR}/${APP_NAME}" ]; then
    echo "[CACHE] ${REPO} is up-to-date (${TARGET_VERSION}). Skipping download." >&2
  else
    echo "[UPDATE] ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})" >&2
    install_extension "$REPO" "$TARGET_VERSION"
  fi
done

# ==============================================================================
# 5. Declarative Reconciliation (Manifest-Driven Cleanup)
# ==============================================================================

echo "[CLEANUP] Reconciling declarative state..." >&2

# Only read repos that this script itself manages in its manifest
TRACKED_REPOS=$(jq -r 'keys[]' "$MANIFEST_FILE" 2>/dev/null || echo "")

for repo in $TRACKED_REPOS; do
  folder_name="${repo##*/}"

  # Verify the tracked repository string remains requested inside current container arguments
  if ! echo "$VALID_REPOS" | grep -q ":${repo}:"; then

    # Avoid wiping asset directory if another custom manifest repo targets the identical folder name
    if ! echo "$VALID_APPS" | grep -q ":${folder_name}:"; then
      echo "[CLEANUP] Removing orphaned custom extension: ${folder_name}" >&2
      if [ -d "${DEST_DIR}/${folder_name}" ]; then
        rm -rf "${DEST_DIR}/${folder_name}"
      fi
    fi

    # Delete the repo entry from the manifest to keep the cache clean
    echo "[CLEANUP] Removing stale manifest cache entry for ${repo}" >&2
    tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"
    jq --arg r "$repo" 'del(.[$r])' "$MANIFEST_FILE" > "$tmp_file"
    mv "$tmp_file" "$MANIFEST_FILE"
  fi
done

# ==============================================================================
# 6. Permissions & Post-Installation
# ==============================================================================

# Default to 1005 if variables are unset to match oCIS standard
PUID="${OCIS_PUID:-1005}"
PGID="${OCIS_PGID:-1005}"

echo "[PERMISSIONS] Applying (PUID: ${PUID} / PGID: ${PGID}) to ${DEST_DIR}..." >&2
chown -R "${PUID}:${PGID}" "$DEST_DIR"

echo "[SUCCESS] Extension initialization complete." >&2