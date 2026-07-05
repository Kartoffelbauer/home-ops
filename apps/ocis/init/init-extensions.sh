#!/bin/sh
# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, ephemeral installer for oCIS web extensions.
#              Purges stale state on boot to ensure strict configuration parity.
#              Downloads, extracts, and provisions valid extensions (identified
#              by manifest.json) and gracefully handles GitHub API limits.
#
# Usage: ./init-extensions.sh [author/repo:version] ...
# Example: ./init-extensions.sh LukasHirt/web-app-excalidraw:latest mschlachter/ocis-app-tokens:1.0.0
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DEST_DIR="/apps"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing required dependencies: jq, unzip, tar, wget..."
  apk add --no-cache -q jq unzip tar wget
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Enforce strict declarative state: Purge existing modules before initializing
echo "Purging existing extensions to guarantee a clean baseline..."
find "$DEST_DIR" -mindepth 1 -delete
mkdir -p "$DEST_DIR"

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
  local filename="${url##*/}"
  local archive="${extract_dir}/${filename}"

  mkdir -p "$extract_dir"
  wget -qO "$archive" "$url"

  # Route extraction method based on file extension
  if echo "$filename" | grep -q -i '\.zip$'; then
    unzip -q -o "$archive" -d "$extract_dir"
  elif echo "$filename" | grep -q -iE '\.(tar\.gz|tgz)$'; then
    # Suppress unknown macOS extended header warnings by routing stderr to /dev/null
    tar -xzf "$archive" -C "$extract_dir" 2>/dev/null
  else
    echo "Error: Unsupported archive format for ${filename}"
    exit 1
  fi

  rm -f "$archive"
  echo "$extract_dir"
}

# ------------------------------------------------------------------------------
# Installation Pipelines
# ------------------------------------------------------------------------------

install_extension() {
  local repo="$1"
  local version="$2"
  local app_name="${repo##*/}"

  echo "Processing oCIS extension: ${repo}..."

  local api_json=$(github_api_req "repos/${repo}/releases/tags/${version}")

  # Select the first attached asset that is a zip, tar.gz, or tgz file
  local asset_url=$(echo "$api_json" | jq -r '
    .assets[]? |
    select(.name | test("\\.(zip|tar\\.gz|tgz)$"; "i")) |
    .browser_download_url
  ' | head -n 1)

  if [ -z "$asset_url" ]; then
    echo "Error: Could not find a suitable .zip or .tar.gz release asset for ${repo} at version ${version}."
    exit 1
  fi

  echo "Downloading ${asset_url##*/}..."
  local extracted_dir=$(download_and_extract "$asset_url")

  # Locate the sub-directory containing the actual extension manifest
  local manifest_file=$(find "$extracted_dir" -name "manifest.json" | head -n 1)

  if [ -n "$manifest_file" ]; then
    local component_dir=$(dirname "$manifest_file")
    mv "$component_dir" "${DEST_DIR}/${app_name}"
    echo "Successfully installed ${app_name}."
  else
    echo "Error: manifest.json not found inside release archive for ${repo}!"
    exit 1
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
  # Parse repository and version
  REPO="${arg%%:*}"
  VERSION="${arg##*:}"

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

  install_extension "$REPO" "$VERSION"
done

# ==============================================================================
# Post-Installation
# ==============================================================================

# Default to 1005 if variables are unset to match oCIS standard
PUID="${OCIS_PUID:-1005}"
PGID="${OCIS_PGID:-1005}"

echo "Applying permissions (PUID: ${PUID} / PGID: ${PGID}) to ensure oCIS access..."
chown -R "${PUID}:${PGID}" "$DEST_DIR"

echo "Extension initialization complete."