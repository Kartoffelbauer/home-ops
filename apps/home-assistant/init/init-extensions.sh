#!/bin/sh
# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, ephemeral installer for Home Assistant integrations
#              and frontend UI plugins. Purges stale state on boot to ensure
#              strict configuration parity. Surgically injects frontend resources
#              directly into Home Assistant's internal JSON database (.storage)
#              and handles GitHub API rate-limiting elegantly via tokens.
#
# Usage: ./init-extensions.sh [type=author/repo:version] ...
# Example: ./init-extensions.sh integration=custom-components/hacs:latest frontend=thomasloven/lovelace-card-mod:v4.2.1
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"
DIR_STORAGE="/config/.storage"
FILE_RESOURCES="${DIR_STORAGE}/lovelace_resources"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing required dependencies: jq, unzip, wget..."
  apk add --no-cache -q jq unzip wget
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Enforce strict declarative state: Purge existing modules before initializing
echo "Purging existing extensions to guarantee a clean baseline..."
rm -rf "$DIR_INTEGRATIONS" "$DIR_FRONTEND"
mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

# Clear and re-initialize Lovelace resource database file on every boot
echo '{"version":1,"minor_version":1,"key":"lovelace_resources","data":{"items":[]}}' > "$FILE_RESOURCES"
echo "Reset internal lovelace_resources JSON database to baseline."

# ------------------------------------------------------------------------------
# API & File System Helpers
# ------------------------------------------------------------------------------

# Wrapper for GitHub API requests to handle optional authentication
github_api_req() {
  local endpoint="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    wget -qO- --header="Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/${endpoint}"
  else
    wget -qO- "https://api.github.com/${endpoint}"
  fi
}

get_latest_version() {
  local repo="$1"
  github_api_req "repos/${repo}/releases/latest" | jq -r '.tag_name // empty'
}

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

  # Priority 1: Search inside standard production deployment folders
  target_file=$(find "$search_dir" -type f \( -ipath "*/dist/*.js" -o -ipath "*/release/*.js" \) \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)

  # Priority 2: Fallback to any generic module nested in target distribution path
  [ -z "$target_file" ] && target_file=$(find "$search_dir" -type f -ipath "*/dist/*.js" | head -n 1)

  # Priority 3: Scan anywhere, aggressively skipping development environments
  [ -z "$target_file" ] && target_file=$(find "$search_dir" -type f -name "*.js" -not -path "*/node_modules/*" -not -path "*/src/*" \( -iname "${repo_name}.js" -o -iname "${short_name}.js" \) | head -n 1)

  # Priority 4: Ultimate desperation sweep - isolate raw structure while ignoring build/config files
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
  echo "Injected ${js_basename} into internal .storage Lovelace database."
}

# ------------------------------------------------------------------------------
# Installation Pipelines
# ------------------------------------------------------------------------------

install_integration() {
  local repo="$1"
  local version="$2"

  echo "Processing integration ${repo}..."

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local zip_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)

  if [ -z "$zip_url" ]; then
    zip_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"
  fi

  local extracted_dir=$(download_and_extract "$zip_url")
  local manifest_file=$(find "$extracted_dir" -name "manifest.json" | head -n 1)

  if [ -n "$manifest_file" ]; then
    local component_dir=$(dirname "$manifest_file")
    local component_name=$(basename "$component_dir")
    local dest_path="${DIR_INTEGRATIONS}/${component_name}"

    mv "$component_dir" "$dest_path"
    echo "Successfully installed component: ${component_name}"
  else
    echo "Error: manifest.json not found inside release archive for ${repo}!"
    exit 1
  fi
  echo "----------------------------------------"
}

install_frontend() {
  local repo="$1"
  local version="$2"
  local repo_name="${repo##*/}"
  local dest_path="${DIR_FRONTEND}/${repo_name}"
  local final_js_file=""

  echo "Processing frontend ${repo}..."
  mkdir -p "$dest_path"

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")
  local js_asset_url=$(echo "$api_json" | jq -r '.assets[]? | select(.name | endswith(".js")) | .browser_download_url' | head -n 1)

  if [ -n "$js_asset_url" ]; then
    local filename="${js_asset_url##*/}"
    wget -qO "${dest_path}/${filename}" "$js_asset_url"
    final_js_file="${dest_path}/${filename}"
    echo "Downloaded compiled asset directly from release artifacts."
  else
    echo "No compiled asset attached. Initiating deep recursive source scan..."
    local source_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"

    local extracted_dir=$(download_and_extract "$source_url")
    local found_js=$(find_frontend_asset "$extracted_dir" "$repo_name")

    if [ -n "$found_js" ]; then
      local filename=$(basename "$found_js")
      mv "$found_js" "${dest_path}/${filename}"
      final_js_file="${dest_path}/${filename}"
      echo "Surgically extracted ${filename} from deep repository tree."
    else
      echo "Error: No valid frontend .js assets located anywhere in release target for ${repo}!"
      exit 1
    fi
  fi

  if [ -n "$final_js_file" ]; then
    inject_lovelace_resource "$repo_name" "$(basename "$final_js_file")"
  fi
  echo "----------------------------------------"
}

# ==============================================================================
# Main Execution
# ==============================================================================

if [ "$#" -eq 0 ]; then
  echo "No extensions specified to install."
  exit 0
fi

for arg in "$@"; do
  TYPE="integration"
  REPO_VERSION="$arg"

  # Parse type definition if present
  if echo "$arg" | grep -q "="; then
    TYPE="${arg%%=*}"
    REPO_VERSION="${arg#*=}"
  fi

  # Parse repository and version
  REPO="${REPO_VERSION%%:*}"
  VERSION="${REPO_VERSION##*:}"

  # Fallback logic for version mapping
  if [ "$REPO" = "$VERSION" ]; then
    VERSION="latest"
  fi

  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(get_latest_version "$REPO")
    if [ -z "$VERSION" ]; then
      echo "Error: Could not resolve latest version for ${REPO}. Check GitHub API limits or verify GITHUB_TOKEN."
      exit 1
    fi
  fi

  # Route payload to correct installer pipeline
  if [ "$TYPE" = "frontend" ]; then
    install_frontend "$REPO" "$VERSION"
  else
    install_integration "$REPO" "$VERSION"
  fi
done

# ==============================================================================
# Post-Installation
# ==============================================================================

echo "Applying permissions (PUID: 0 / PGID: 0) to ensure Home Assistant access..."
chown -R 0:0 "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

echo "Extension initialization complete."