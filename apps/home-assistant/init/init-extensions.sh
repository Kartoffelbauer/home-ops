#!/bin/sh
# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, idempotent installer for Home Assistant integrations,
#              frontend UI plugins, and themes. Utilizes a Manifest Cache pattern
#              to bypass heavy downloads if up-to-date. Rebuilds the internal
#              .storage/lovelace_resources database dynamically on every boot
#              using an atomic transaction pattern to prevent empty states.
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"
DIR_THEMES="/config/themes"
DIR_STORAGE="/config/.storage"
FILE_RESOURCES="${DIR_STORAGE}/lovelace_resources"
MANIFEST_FILE="/config/.ha_extension_manifest.json"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "[INIT] Installing required dependencies: jq, unzip, wget..." >&2
  apk add --no-cache -q jq unzip wget
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Create required directory structure
mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_THEMES" "$DIR_STORAGE"

# Validate or reset corrupted Manifest Cache
if [ ! -f "$MANIFEST_FILE" ] || ! jq . "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "[INIT] Manifest cache missing or corrupted. Resetting baseline..." >&2
  echo "{}" > "$MANIFEST_FILE"
fi

# Create a safe in-memory staging target for the database rebuild
# The production file will not be touched until the entire network loop succeeds.
FILE_RESOURCES_STAGING="${TEMP_WORKSPACE}/lovelace_resources.tmp"
echo '{"version":1,"minor_version":1,"key":"lovelace_resources","data":{"items":[]}}' > "$FILE_RESOURCES_STAGING"


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
    echo "[ERROR] GitHub API request failed (Status: ${status}). Check connectivity or GITHUB_TOKEN." >&2
    exit 1
  fi

  cat "$response_file"
}

# Queries GitHub for the latest release tag
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

# Extracts a specific property from the local manifest cache
get_cached_data() {
  local repo="$1" key="$2"
  jq -r --arg r "$repo" --arg k "$key" 'if .[$r] then .[$r][$k] else empty end' "$MANIFEST_FILE"
}

# Atomic cache writing to prevent corruption on unexpected container stops
update_cache() {
  local repo="$1" type="$2" version="$3" target_val="$4"
  local tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"

  if [ "$type" = "frontend" ]; then
    jq --arg r "$repo" --arg v "$version" --arg js "$target_val" \
      '.[$r] = {version: $v, js_filename: $js, type: "frontend"}' "$MANIFEST_FILE" > "$tmp_file"
  else
    jq --arg r "$repo" --arg v "$version" --arg f "$target_val" --arg t "$type" \
      '.[$r] = {version: $v, folder: $f, type: $t}' "$MANIFEST_FILE" > "$tmp_file"
  fi

  mv "$tmp_file" "$MANIFEST_FILE"
}


# ------------------------------------------------------------------------------
# 3. File System & Discovery Pipelines
# ------------------------------------------------------------------------------

# Downloads and extracts a zip archive to a unique temporary directory
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

# Shortcut helper to download a GitHub source archive directly
download_source_zip() {
  local repo="$1" version="$2"
  download_and_extract "https://github.com/${repo}/archive/refs/tags/${version}.zip"
}

# Sequential heuristic scanner for finding the correct javascript asset in an archive
find_frontend_asset() {
  local search_dir="$1" repo_name="$2"
  local short_name="${repo_name#lovelace-}"
  local target_file=""

  # Priority 1: Dist/Release folder with accurately named file
  target_file=$(find "$search_dir" -type f \( -ipath "*/dist/*.js" -o -ipath "*/release/*.js" \) \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)
  if [ -n "$target_file" ]; then echo "$target_file"; return 0; fi

  # Priority 2: Any JS file in Dist/Release folder
  target_file=$(find "$search_dir" -type f -ipath "*/dist/*.js" | head -n 1)
  if [ -n "$target_file" ]; then echo "$target_file"; return 0; fi

  # Priority 3: Accurately named file anywhere outside node_modules/src
  target_file=$(find "$search_dir" -type f -name "*.js" -not -path "*/node_modules/*" -not -path "*/src/*" \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)
  if [ -n "$target_file" ]; then echo "$target_file"; return 0; fi

  # Fallback: Any valid JS file outside excluded paths
  find "$search_dir" -type f -name "*.js" -not -path "*/node_modules/*" -not -path "*/src/*" -not -name "*config*" | head -n 1
}

# Safely injects the Javascript resource definition into the staging database
inject_lovelace_resource() {
  local repo_name="$1" js_basename="$2"
  local resource_url="/local/community/${repo_name}/${js_basename}"
  local tmp_json="${TEMP_WORKSPACE}/tmp_storage.json"

  jq --arg url "$resource_url" --arg id "$(cat /proc/sys/kernel/random/uuid)" \
    '.data.items += [{"id": $id, "type": "module", "url": $url}]' \
    "$FILE_RESOURCES_STAGING" > "$tmp_json"

  mv "$tmp_json" "$FILE_RESOURCES_STAGING"
  echo "[LOVELACE] Staged resource: ${js_basename}" >&2
}


# ------------------------------------------------------------------------------
# 4. Installation Handlers
# ------------------------------------------------------------------------------

# Resolves, downloads, and extracts Home Assistant custom components atomically
install_integration() {
  local repo="$1" version="$2"

  echo "[INSTALL] Integration: ${repo} @ ${version}..." >&2

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local zip_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)

  if [ -z "$zip_url" ]; then
    zip_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"
  fi

  local extracted_dir=$(download_and_extract "$zip_url")
  local manifest_file=$(find "$extracted_dir" -name "manifest.json" | head -n 1)

  if [ -n "$manifest_file" ]; then
    local component_name=$(jq -r '.domain // empty' "$manifest_file")

    if [ -z "$component_name" ]; then
      component_name=$(basename "$(dirname "$manifest_file")")
    fi

    local dest_path="${DIR_INTEGRATIONS}/${component_name}"
    rm -rf "$dest_path" && mv "$(dirname "$manifest_file")" "$dest_path"

    update_cache "$repo" "integration" "$version" "$component_name"
    echo "$component_name" > "${TEMP_WORKSPACE}/.last_integration"
    echo "[SUCCESS] Installed component: ${component_name}" >&2
  else
    echo "[ERROR] manifest.json not found inside release archive for ${repo}!" >&2
    exit 1
  fi
}

# Locates, downloads, and installs Lovelace frontend resources atomically
install_frontend() {
  local repo="$1" version="$2" repo_name="${1##*/}"
  local dest_path="${DIR_FRONTEND}/${repo_name}"
  local temp_dest="${TEMP_WORKSPACE}/frontend_${repo_name}"
  local final_js_file=""

  echo "[INSTALL] Frontend: ${repo} @ ${version}..." >&2

  mkdir -p "$temp_dest"

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local asset_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".js")) | .browser_download_url' | head -n 1)

  if [ -n "$asset_url" ]; then
    final_js_file="${temp_dest}/${asset_url##*/}"
    wget -qO "$final_js_file" "$asset_url"
  else
    local extracted_dir=$(download_source_zip "$repo" "$version")
    local found_asset=$(find_frontend_asset "$extracted_dir" "$repo_name")

    if [ -n "$found_asset" ]; then
      final_js_file="${temp_dest}/$(basename "$found_asset")"
      mv "$found_asset" "$final_js_file"
    fi
  fi

  if [ -n "$final_js_file" ]; then
    local js_basename=$(basename "$final_js_file")

    rm -rf "$dest_path" && mv "$temp_dest" "$dest_path"

    update_cache "$repo" "frontend" "$version" "$js_basename"
    inject_lovelace_resource "$repo_name" "$js_basename"
    echo "[SUCCESS] Installed frontend: ${repo_name}" >&2
  else
    echo "[ERROR] No valid frontend .js assets located for ${repo}!" >&2
    exit 1
  fi
}

# Locates, downloads, and installs YAML theme files atomically
install_theme() {
  local repo="$1" version="$2" repo_name="${1##*/}"
  local dest_path="${DIR_THEMES}/${repo_name}"
  local temp_dest="${TEMP_WORKSPACE}/theme_${repo_name}"

  echo "[INSTALL] Theme: ${repo} @ ${version}..." >&2

  mkdir -p "$temp_dest"

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local asset_urls=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".yaml")) | .browser_download_url')

  if [ -n "$asset_urls" ]; then
    for url in $asset_urls; do
      wget -qO "${temp_dest}/${url##*/}" "$url"
    done
  else
    local extracted_dir=$(download_source_zip "$repo" "$version")
    local themes_dir=$(find "$extracted_dir" -type d \( -iname "themes" -o -iname "theme" \) | head -n 1)

    if [ -n "$themes_dir" ]; then
      find "$themes_dir" -type f -name "*.yaml" -exec mv {} "$temp_dest/" \;
    else
      local short_name="${repo_name#theme-}"
      find "$extracted_dir" -type f -name "*.yaml" -not -path "*/.*" \( -iname "*${repo_name}*.yaml" -o -iname "*${short_name}*.yaml" \) -exec mv {} "$temp_dest/" \;
    fi
  fi

  local count=$(find "$temp_dest" -maxdepth 1 -type f -name "*.yaml" | wc -l)
  if [ "$count" -gt 0 ]; then
    rm -rf "$dest_path" && mv "$temp_dest" "$dest_path"

    update_cache "$repo" "theme" "$version" "$repo_name"
    echo "$repo_name" > "${TEMP_WORKSPACE}/.last_theme"
    echo "[SUCCESS] Installed theme directory with ${count} variation(s): ${repo_name}" >&2
  else
    echo "[ERROR] No valid theme .yaml assets located for ${repo}!" >&2
    exit 1
  fi
}


# ==============================================================================
# 5. Main Execution (The Cache Logic Controller)
# ==============================================================================

if [ "$#" -eq 0 ]; then
  echo "[INIT] No extensions specified. Proceeding to cleanup phase..." >&2
fi

# POSIX strings to track valid components for declarative cleanup
VALID_INTEGRATIONS=":"
VALID_FRONTENDS=":"
VALID_THEMES=":"
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

  case "$TYPE" in
    frontend)
    CACHED_JS=$(get_cached_data "$REPO" "js_filename")
      if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -n "$CACHED_JS" ] && [ -f "${DIR_FRONTEND}/${APP_NAME}/${CACHED_JS}" ]; then
      echo "[CACHE] Frontend ${REPO} up-to-date (${TARGET_VERSION}). Injecting resource..." >&2
      inject_lovelace_resource "$APP_NAME" "$CACHED_JS"
    else
      echo "[UPDATE] Frontend ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})" >&2
      install_frontend "$REPO" "$TARGET_VERSION"
      fi
      VALID_FRONTENDS="${VALID_FRONTENDS}${APP_NAME}:"
      ;;

    theme)
    CACHED_FOLDER=$(get_cached_data "$REPO" "folder")
    if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -n "$CACHED_FOLDER" ] && [ -d "${DIR_THEMES}/${CACHED_FOLDER}" ]; then
      echo "[CACHE] Theme ${REPO} up-to-date (${TARGET_VERSION})." >&2
      VALID_THEMES="${VALID_THEMES}${CACHED_FOLDER}:"
    else
      echo "[UPDATE] Theme ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})" >&2
      install_theme "$REPO" "$TARGET_VERSION"
        VALID_THEMES="${VALID_THEMES}$(cat "${TEMP_WORKSPACE}/.last_theme"):"
    fi
      ;;

    integration)
    CACHED_FOLDER=$(get_cached_data "$REPO" "folder")
    if [ "$TARGET_VERSION" = "$CACHED_VERSION" ] && [ -n "$CACHED_FOLDER" ] && [ -d "${DIR_INTEGRATIONS}/${CACHED_FOLDER}" ]; then
      echo "[CACHE] Integration ${REPO} up-to-date (${TARGET_VERSION})." >&2
      VALID_INTEGRATIONS="${VALID_INTEGRATIONS}${CACHED_FOLDER}:"
    else
      echo "[UPDATE] Integration ${REPO} (Local: ${CACHED_VERSION:-None} -> Remote: ${TARGET_VERSION})" >&2
      install_integration "$REPO" "$TARGET_VERSION"
        VALID_INTEGRATIONS="${VALID_INTEGRATIONS}$(cat "${TEMP_WORKSPACE}/.last_integration"):"
  fi
      ;;
  esac
done


# ==============================================================================
# 6. Declarative Reconciliation & Post-Installation
# ==============================================================================

echo "[CLEANUP] Reconciling declarative state..." >&2

# Only read repos that this script itself manages in its manifest
TRACKED_REPOS=$(jq -r 'keys[]' "$MANIFEST_FILE" 2>/dev/null || echo "")

for repo in $TRACKED_REPOS; do
  cached_type=$(get_cached_data "$repo" "type")

  if ! echo "$VALID_REPOS" | grep -q ":${repo}:"; then
    if [ "$cached_type" = "frontend" ]; then
      folder_name="${repo##*/}"
      if ! echo "$VALID_FRONTENDS" | grep -q ":${folder_name}:"; then
        echo "[CLEANUP] Removing orphaned frontend: ${folder_name}" >&2
        rm -rf "${DIR_FRONTEND}/${folder_name}"
      fi
    else
      folder_name=$(get_cached_data "$repo" "folder")
      if [ -n "$folder_name" ]; then
        if [ "$cached_type" = "theme" ] && ! echo "$VALID_THEMES" | grep -q ":${folder_name}:"; then
          echo "[CLEANUP] Removing orphaned theme: ${folder_name}" >&2
          rm -rf "${DIR_THEMES}/${folder_name}"
        elif [ "$cached_type" = "integration" ] && ! echo "$VALID_INTEGRATIONS" | grep -q ":${folder_name}:"; then
        echo "[CLEANUP] Removing orphaned integration: ${folder_name}" >&2
        rm -rf "${DIR_INTEGRATIONS}/${folder_name}"
        fi
      fi
    fi

    # Delete the repo entry from the manifest to keep the cache clean
    echo "[CLEANUP] Removing stale manifest cache entry for ${repo}" >&2
    tmp_file="${TEMP_WORKSPACE}/manifest.tmp.json"
    jq --arg r "$repo" 'del(.[$r])' "$MANIFEST_FILE" > "$tmp_file"
    mv "$tmp_file" "$MANIFEST_FILE"
  fi
done

# Overwrite the real Lovelace resource file atomically
# Only executed if all download routines and queries exited with zero status codes
echo "[COMMIT] Committing staging Lovelace database transaction to production..." >&2
mv "$FILE_RESOURCES_STAGING" "$FILE_RESOURCES"

echo "[PERMISSIONS] Applying (PUID: 0 / PGID: 0) to ensure Home Assistant access..." >&2
chown -R 0:0 "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_THEMES" "$DIR_STORAGE"

echo "[SUCCESS] Extension initialization complete." >&2