#!/bin/sh
set -e

# ==============================================================================
# Script: init-extensions.sh (Home Assistant)
# Environment: Alpine (POSIX sh)
# Description: Modular installer for Home Assistant integrations and frontend UI
#              plugins (HACS equivalents) from GitHub releases.
#
# Usage: ./init-extensions.sh [type=]<author/repo>[:version] ...
#
# Types:
#   integration (default) -> Installed to /config/custom_components
#   frontend              -> Installed to /config/www/community
#
# Examples:
#   ./init-extensions.sh smartHomeHub/SmartIR:1.17.6
#   ./init-extensions.sh frontend=piitaya/lovelace-mushroom:latest
# ==============================================================================

# --- Global Configurations ---
DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"

mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND"

# ------------------------------------------------------------------------------
# API Helpers
# ------------------------------------------------------------------------------

get_latest_version() {
  local repo="$1"
  wget -qO- "https://api.github.com/repos/${repo}/releases/latest" | \
    grep '"tag_name":' | \
    sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

get_release_assets() {
  local repo="$1"
  local version="$2"
  # Fetches all download URLs attached to a specific release
  wget -qO- "https://api.github.com/repos/${repo}/releases/tags/${version}" | \
    grep '"browser_download_url":' | \
    sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/'
}

# ------------------------------------------------------------------------------
# Installation Pipelines
# ------------------------------------------------------------------------------

install_integration() {
  local repo="$1"
  local version="$2"
  local temp_zip="/tmp/ext_archive.zip"
  local temp_dir="/tmp/ext_extract"

  echo "[Integration] Installing ${repo} @ ${version}..."

  # 1. Discover Asset
  local asset_urls=$(get_release_assets "$repo" "$version")
  local zip_url=$(echo "$asset_urls" | grep -i '\.zip$' | head -n 1)

  # Fallback to source code if no compiled zip is provided
  if [ -z "$zip_url" ]; then
    zip_url="https://github.com/${repo}/archive/refs/tags/${version}.zip"
  fi

  # 2. Download & Extract
  wget -qO "$temp_zip" "$zip_url"
  mkdir -p "$temp_dir"
  unzip -q -o "$temp_zip" -d "$temp_dir/"

  # 3. Locate Manifest & Install
  # We dynamically find the component root regardless of how the zip is structured
  local manifest_path=$(find "$temp_dir" -name "manifest.json" | head -n 1)

  if [ -n "$manifest_path" ]; then
    local component_dir=$(dirname "$manifest_path")
    local component_name=$(basename "$component_dir")
    local dest_path="${DIR_INTEGRATIONS}/${component_name}"

    rm -rf "$dest_path"
    mv "$component_dir" "$dest_path"
    echo "  -> Success: Saved to ${dest_path}"
  else
    echo "  -> Error: manifest.json not found in archive!"
    exit 1
  fi

  # 4. Cleanup
  rm -rf "$temp_dir" "$temp_zip"
}

install_frontend() {
  local repo="$1"
  local version="$2"
  local repo_name="${repo##*/}"
  local dest_path="${DIR_FRONTEND}/${repo_name}"

  echo "[Frontend] Installing ${repo} @ ${version}..."

  local asset_urls=$(get_release_assets "$repo" "$version")
  local zip_url=$(echo "$asset_urls" | grep -i '\.zip$' | head -n 1)

  rm -rf "$dest_path"
  mkdir -p "$dest_path"

  # Frontend plugins are either packed in a .zip or provided as raw .js/.css files
  if [ -n "$zip_url" ]; then
    local temp_zip="/tmp/ext_archive.zip"
    wget -qO "$temp_zip" "$zip_url"
    unzip -q -o "$temp_zip" -d "$dest_path/"
    rm -f "$temp_zip"
    echo "  -> Success: Extracted zip to ${dest_path}"
  else
    local found_assets=0
    # Loop through all attached files and download JS/CSS directly
    for url in $asset_urls; do
      if echo "$url" | grep -qE '\.(js|css)$'; then
        wget -q -P "$dest_path" "$url"
        echo "  -> Downloaded $(basename "$url")"
        found_assets=1
      fi
    done

    if [ "$found_assets" -eq 0 ]; then
      echo "  -> Error: No valid frontend assets (.zip, .js, .css) found!"
      exit 1
    fi
    echo "  -> Success: Saved to ${dest_path}"
  fi
}

# ==============================================================================
# Main Execution Loop
# ==============================================================================

if [ "$#" -eq 0 ]; then
  echo "No extensions specified. Exiting."
  exit 0
fi

for arg in "$@"; do
  # 1. Parse Type (Default to integration if no prefix is provided)
  TYPE="integration"
  REPO_VERSION="$arg"

  if echo "$arg" | grep -q "="; then
    TYPE="${arg%%=*}"
    REPO_VERSION="${arg#*=}"
  fi

  # 2. Parse Repo and Version
  REPO="${REPO_VERSION%%:*}"
  VERSION="${REPO_VERSION##*:}"

  if [ "$REPO" = "$VERSION" ]; then
    VERSION="latest"
  fi

  # 3. Resolve 'latest' tag via GitHub API
  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(get_latest_version "$REPO")
  fi

  # 4. Route to the correct installation pipeline
  if [ "$TYPE" = "frontend" ]; then
    install_frontend "$REPO" "$VERSION"
  else
    install_integration "$REPO" "$VERSION"
  fi
done

# ==============================================================================
# Post-Installation
# ==============================================================================

echo "Applying permissions (PUID: 0 / PGID: 0) to ensure container access..."
chown -R 0:0 "$DIR_INTEGRATIONS"
chown -R 0:0 "$DIR_FRONTEND"

echo "Extension initialization complete."