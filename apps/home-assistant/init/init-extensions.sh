#!/bin/sh
# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, idempotent installer for Home Assistant integrations
#              and frontend UI plugins. Utilizes a Manifest Cache pattern to
#              bypass heavy downloads if up-to-date. Rebuilds the internal
#              .storage/lovelace_resources database dynamically on every boot
#              to guarantee strict configuration parity.
#
# Usage: ./init-extensions.sh [type=author/repo:version] ...
# Example: ./init-extensions.sh integration=custom-components/hacs:latest frontend=thomasloven/lovelace-card-mod:v4.2.1
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"
DIR_STORAGE="/config/.storage"
FILE_RESOURCES="${DIR_STORAGE}/lovelace_resources"
MANIFEST_FILE="/config/.ha_extension_manifest.json"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "[INIT] Installing required dependencies: jq, unzip, wget..."
  apk add --no-cache -q jq unzip wget
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Create required directory structure
mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

# Validate or reset corrupted Manifest Cache
if [ ! -f "$MANIFEST_FILE" ] || ! jq . "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "[INIT] Manifest cache missing or corrupted. Resetting baseline..."
  echo "{}" > "$MANIFEST_FILE"
fi

# Always reset internal lovelace_resources JSON database to a clean slate
echo '{"version":1,"minor_version":1,"key":"lovelace_resources","data":{"items":[]}}' > "$FILE_RESOURCES"
echo "[INIT] Reset internal lovelace_resources database to baseline."

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

  if [ "$status" -ne 0 ] || [ ! -f "$response_file" ]; then
    echo "[ERROR] GitHub API request failed (Status: ${status}). Check connectivity or GITHUB_TOKEN."
    exit 1
  fi

  cat "$response_file"
}

get_latest_version() {
  local repo="$1"
  local json_payload=""
  local res=""

  # Isolated assignment blocks to bypass pipeline subshell exit code swallowing
  json_payload=$(github_api_req "repos/${repo}/releases/latest")
  res=$(echo "$json_payload" | jq -r '.tag_name // empty')

  if [ -z "$res" ]; then
    echo "[ERROR] Could not extract valid release tag information for repository: ${repo}"
    exit 1
  fi
  echo "$res"
}

get_cached_data() {
  local repo="$1"
  local key="$2"
  jq -r --arg r "$repo" --arg k "$key" '.[$r]?[$k] // empty' "$MANIFEST_FILE"
}

# Atomic cache writing to prevent corruption on unexpected container stops
update_cache() {
  local repo="$1"
  local type="$2"
  local version="$3"
  local target_val="$4"
  local tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"

  if [ "$type" = "integration" ]; then
    jq --arg r "$repo" --arg v "$version" --arg f "$target_val" \
      '.[$r] = {version: $v, folder: $f, type: "integration"}' "$MANIFEST_FILE" > "$tmp_file"
  else
    jq --arg r "$repo" --arg v "$version" --arg js "$target_val" \
      '.[$r] = {version: $v, js_filename: $js, type: "frontend"}' "$MANIFEST_FILE" > "$tmp_file"
  fi

  mv "$tmp_file" "$MANIFEST_FILE"
}

# ------------------------------------------------------------------------------
# 3. File System & Lovelace Pipelines
# ------------------------------------------------------------------------------

download_and_extract() {
  local url="$1"
  local extract_dir="${TEMP_WORKSPACE}/$(cat /proc/sys/kernel/random/uuid)"
  local temp_zip="${extract_dir}/archive.zip"

  mkdir -p "$extract_dir"
  wget -qO "$temp_zip" "$url"
  unzip -q -o "$temp_zip" -d "$extract_dir"
  rm -f "$temp_zip"

  echo "$extract_dir"
}

find_frontend_asset() {
  local search_dir="$1"
  local repo_name="$2"
  local short_name="${repo_name#lovelace-}"
  local target_file=""

  target_file=$(find "$search_dir" -type f \( -ipath "*/dist/*.js" -o -ipath "*/release/*.js" \) \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)
  [ -z "$target_file" ] && target_file=$(find "$search_dir" -type f -ipath "*/dist/*.js" | head -n 1)
  [ -z "$target_file" ] && target_file=$(find "$search_dir" -type f -name "*.js" -not -path "*/node_modules/*" -not -path "*/src/*" \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)
  [ -z "$target_file" ] && target_file=$(find "$search_dir" -type f -name "*.js" -not -path "*/node_modules/*" -not -path "*/src/*" -not -name "*config*" | head -n 1)

  echo "$target_file"
}

inject_lovelace_resource() {
  local repo_name="$1"
  local js_basename="$2"
  local resource_url="/local/community/${repo_name}/${js_basename}"
  local uuid=$(cat /proc/sys/kernel/random/uuid)
  local tmp_json="${TEMP_WORKSPACE}/tmp_storage.json"

  jq --arg url "$resource_url" --arg id "$uuid" \
    '.data.items += [{"id": $id, "type": "module", "url": $url}]' \
    "$FILE_RESOURCES" > "$tmp_json"

  mv "$tmp_json" "$FILE_RESOURCES"
  echo "[LOVELACE] Injected ${js_basename} into .storage database."
}

# ------------------------------------------------------------------------------
# 4. Installation Handlers
# ------------------------------------------------------------------------------

install_integration() {
  local repo="$1"
  local version="$2"

  echo "[INSTALL] Integration: ${repo} @ ${version}..."

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local zip_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)

  [ -z "$zip_url" ] && zip_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"

  local extracted_dir=$(download_and_extract "$zip_url")
  local manifest_file=$(find "$extracted_dir" -name "manifest.json" | head -n 1)

  if [ -n "$manifest_file" ]; then
    local component_name=$(jq -r '.domain // empty' "$manifest_file")
    local dest_path="${DIR_INTEGRATIONS}/${component_name}"

    if [ -z "$component_name" ]; then
      local component_dir=$(dirname "$manifest_file")
      component_name=$(basename "$component_dir")
    fi

    rm -rf "$dest_path"
    mv "$(dirname "$manifest_file")" "$dest_path"

    update_cache "$repo" "integration" "$version" "$component_name"

    # Secure internal state transmission via temporary tracking workspace file
    echo "$component_name" > "${TEMP_WORKSPACE}/.last_integration"
    echo "[SUCCESS] Installed component: ${component_name}"
  else
    echo "[ERROR] manifest.json not found inside release archive for ${repo}!"
    exit 1
  fi
}

install_frontend() {
  local repo="$1"
  local version="$2"
  local repo_name="${repo##*/}"
  local dest_path="${DIR_FRONTEND}/${repo_name}"
  local final_js_file=""

  echo "[INSTALL] Frontend: ${repo} @ ${version}..."

  rm -rf "$dest_path"
  mkdir -p "$dest_path"

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local js_asset_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".js")) | .browser_download_url' | head -n 1)

  if [ -n "$js_asset_url" ]; then
    local filename="${js_asset_url##*/}"
    wget -qO "${dest_path}/${filename}" "$js_asset_url"
    final_js_file="${dest_path}/${filename}"
    echo "[INFO] Downloaded compiled asset directly."
  else
    echo "[INFO] Initiating deep recursive source scan..."
    local source_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"

    local extracted_dir=$(download_and_extract "$source_url")
    local found_js=$(find_frontend_asset "$extracted_dir" "$repo_name")

    if [ -n "$found_js" ]; then
      local filename=$(basename "$found_js")
      mv "$found_js" "${dest_path}/${filename}"
      final_js_file="${dest_path}/${filename}"
    else
      echo "[ERROR] No valid frontend .js assets located for ${repo}!"
      exit 1
    fi
  fi

  if [ -n "$final_js_file" ]; then
    local js_basename=$(basename "$final_js_file")
    update_cache "$repo" "frontend" "$version" "$js_basename"
    inject_lovelace_resource "$repo_name" "$js_basename"
    echo "[SUCCESS] Installed frontend: ${repo_name}"
  fi
}

# ==============================================================================
# 5. Main Execution (The Cache Logic Controller)
# ==============================================================================

if [ "$#" -eq 0 ]; then
  echo "[INIT] No extensions specified to install."
  exit 0
fi

# POSIX strings to track valid components for declarative cleanup
VALID_INTEGRATIONS=":"
VALID_FRONTENDS=":"
VALID_REPOS=":"

for arg in "$@"; do
  TYPE="integration"
  REPO_VERSION="$arg"

  if echo "$arg" | grep -q "="; then
    TYPE="${arg%%=*}"
    REPO_VERSION="${arg#*=}"
  fi

  REPO="${REPO_VERSION%%:*}"
  TARGET_VERSION="${REPO_VERSION##*:}"
  APP_NAME="${REPO##*/}"
  VALID_REPOS="${VALID_REPOS}${REPO}:"

  # Resolve "latest" tag definitions via isolation variable assignments
  if [ "$REPO" = "$TARGET_VERSION" ] || [ "$TARGET_VERSION" = "latest" ] || [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(get_latest_version "$REPO")
  fi

  CACHED_VERSION=$(get_cached_data "$REPO" "version")

  if [ "$TYPE" = "frontend" ]; then
    CACHED_JS=$(get_cached_data "$REPO" "js_filename")

    if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -n "$CACHED_JS" ] && [ -d "${DIR_FRONTEND}/${APP_NAME}" ]; then
      echo "[CACHE] Frontend ${REPO} up-to-date (${TARGET_VERSION}). Injecting resource..."
      inject_lovelace_resource "$APP_NAME" "$CACHED_JS"
      VALID_FRONTENDS="${VALID_FRONTENDS}${APP_NAME}:"
    else
      echo "[UPDATE] Frontend ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})"
      install_frontend "$REPO" "$TARGET_VERSION"
      VALID_FRONTENDS="${VALID_FRONTENDS}${APP_NAME}:"
    fi

  else
    # Integration Flow
    CACHED_FOLDER=$(get_cached_data "$REPO" "folder")

    if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -n "$CACHED_FOLDER" ] && [ -d "${DIR_INTEGRATIONS}/${CACHED_FOLDER}" ]; then
      echo "[CACHE] Integration ${REPO} up-to-date (${TARGET_VERSION})."
      VALID_INTEGRATIONS="${VALID_INTEGRATIONS}${CACHED_FOLDER}:"
    else
      echo "[UPDATE] Integration ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})"
      install_integration "$REPO" "$TARGET_VERSION"

      NEW_FOLDER=$(cat "${TEMP_WORKSPACE}/.last_integration")
      VALID_INTEGRATIONS="${VALID_INTEGRATIONS}${NEW_FOLDER}:"
    fi
  fi
done

# ==============================================================================
# 6. Declarative Reconciliation & Post-Installation
# ==============================================================================

echo "[CLEANUP] Reconciling declarative state..."

TRACKED_REPOS=$(jq -r 'keys[]' "$MANIFEST_FILE" 2>/dev/null || echo "")

for repo in $TRACKED_REPOS; do
  cached_type=$(get_cached_data "$repo" "type")

  if ! echo "$VALID_REPOS" | grep -q ":${repo}:"; then
    if [ "$cached_type" = "frontend" ]; then
      folder_name="${repo##*/}"
      if ! echo "$VALID_FRONTENDS" | grep -q ":${folder_name}:"; then
        echo "[CLEANUP] Removing orphaned frontend: ${folder_name}"
        rm -rf "${DIR_FRONTEND}/${folder_name}"
      fi
    else
      folder_name=$(get_cached_data "$repo" "folder")
      if [ -n "$folder_name" ] && ! echo "$VALID_INTEGRATIONS" | grep -q ":${folder_name}:"; then
        echo "[CLEANUP] Removing orphaned integration: ${folder_name}"
        rm -rf "${DIR_INTEGRATIONS}/${folder_name}"
      fi
    fi

    # Delete the repo entry from the manifest to keep the cache clean
    echo "[CLEANUP] Removing stale manifest cache entry for ${repo}"
    tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"
    jq --arg r "$repo" 'del(.[$r])' "$MANIFEST_FILE" > "$tmp_file"
    mv "$tmp_file" "$MANIFEST_FILE"
  fi
done

echo "[PERMISSIONS] Applying (PUID: 0 / PGID: 0) to ensure Home Assistant access..."
chown -R 0:0 "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

echo "[SUCCESS] Extension initialization complete."