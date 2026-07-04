#!/bin/sh
set -e

# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Modular installer for Home Assistant integrations and frontend UI
#              plugins (HACS equivalents) from GitHub releases. Automatically
#              generates lovelace resources.yaml for frontend modules.
#
# Usage: ./init-extensions.sh [type=]<author/repo>[:version] ...
# Types: integration (default), frontend
# Example: ./init-extensions.sh smartHomeHub/SmartIR:1.17.6 frontend=piitaya/lovelace-mushroom:latest
# ==============================================================================

# Ensure the target installation directories exist
DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"
FILE_RESOURCES="/config/resources.yaml"

mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND"

# Initialize a clean resources file on every run to prevent duplicate entries
> "$FILE_RESOURCES"

# ------------------------------------------------------------------------------
# API Helpers
# ------------------------------------------------------------------------------

get_latest_version() {
  local REPO="$1"
  wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | \
    grep '"tag_name":' | \
    sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

get_release_assets() {
  local REPO="$1"
  local VERSION="$2"
  wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}" | \
    grep '"browser_download_url":' | \
    sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/'
}

# ------------------------------------------------------------------------------
# Installation Pipelines
# ------------------------------------------------------------------------------

install_integration() {
  local REPO="$1"
  local VERSION="$2"
  local TEMP_ZIP="/tmp/ext_archive.zip"
  local TEMP_DIR="/tmp/ext_extract"

  echo "[Integration] Processing ${REPO} @ ${VERSION}..."

  local ASSET_URLS=$(get_release_assets "$REPO" "$VERSION")
  local ZIP_URL=$(echo "$ASSET_URLS" | grep -i '\.zip$' | head -n 1)

  # Fallback to source code archive if no compiled release asset exists
  if [ -z "$ZIP_URL" ]; then
    ZIP_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.zip"
  fi

  echo "Downloading asset..."
  wget -qO "$TEMP_ZIP" "$ZIP_URL"
  mkdir -p "$TEMP_DIR"
  unzip -q -o "$TEMP_ZIP" -d "$TEMP_DIR/"

  local MANIFEST_DIR=$(find "$TEMP_DIR" -name "manifest.json" -exec dirname {} \; | head -n 1)

  if [ -n "$MANIFEST_DIR" ]; then
    local COMPONENT_NAME=$(basename "$MANIFEST_DIR")
    local DEST_PATH="${DIR_INTEGRATIONS}/${COMPONENT_NAME}"

    rm -rf "$DEST_PATH"
    mv "$MANIFEST_DIR" "$DEST_PATH"
    echo "Successfully installed to ${DEST_PATH}"
  else
    echo "Error: manifest.json not found inside ${REPO} release archive!"
    exit 1
  fi

  rm -rf "$TEMP_DIR" "$TEMP_ZIP"
  echo "----------------------------------------"
}

install_frontend() {
  local REPO="$1"
  local VERSION="$2"
  local REPO_NAME="${REPO##*/}"
  local DEST_PATH="${DIR_FRONTEND}/${REPO_NAME}"

  echo "[Frontend] Processing ${REPO} @ ${VERSION}..."

  local ASSET_URLS=$(get_release_assets "$REPO" "$VERSION")
  local ZIP_URL=$(echo "$ASSET_URLS" | grep -i '\.zip$' | head -n 1)

  rm -rf "$DEST_PATH"
  mkdir -p "$DEST_PATH"

  # Frontend modules can be packaged as archives or direct source files
  if [ -n "$ZIP_URL" ]; then
    local TEMP_ZIP="/tmp/ext_archive.zip"
    wget -qO "$TEMP_ZIP" "$ZIP_URL"
    unzip -q -o "$TEMP_ZIP" -d "$DEST_PATH/"
    rm -f "$TEMP_ZIP"
    echo "Extracted zip to ${DEST_PATH}"
  else
    local FOUND_ASSETS=0
    for url in $ASSET_URLS; do
      if echo "$url" | grep -qE '\.(js|css)$'; then
        wget -q -P "$DEST_PATH" "$url"
        echo "Downloaded $(basename "$url")"
        FOUND_ASSETS=1
      fi
    done

    if [ "$FOUND_ASSETS" -eq 0 ]; then
      echo "Error: No valid frontend assets (.zip, .js, .css) found for ${REPO}."
      exit 1
    fi
    echo "Successfully downloaded to ${DEST_PATH}"
  fi

  # --- Auto-Generate YAML Resource Entry ---
  local JS_FILE=$(find "$DEST_PATH" -name "*.js" | head -n 1)

  if [ -n "$JS_FILE" ]; then
    local JS_BASENAME=$(basename "$JS_FILE")
    echo "- url: /local/community/${REPO_NAME}/${JS_BASENAME}" >> "$FILE_RESOURCES"
    echo "  type: module" >> "$FILE_RESOURCES"
    echo "Linked ${JS_BASENAME} to resources.yaml"
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
  # Determine component type and target parameters
  TYPE="integration"
  REPO_VERSION="$arg"

  if echo "$arg" | grep -q "="; then
    TYPE="${arg%%=*}"
    REPO_VERSION="${arg#*=}"
  fi

  REPO="${REPO_VERSION%%:*}"
  VERSION="${REPO_VERSION##*:}"

  if [ "$REPO" = "$VERSION" ]; then
    VERSION="latest"
  fi

  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(get_latest_version "$REPO")
  fi

  # Route to respective pipeline
  if [ "$TYPE" = "frontend" ]; then
    install_frontend "$REPO" "$VERSION"
  else
    install_integration "$REPO" "$VERSION"
  fi
done

# ==============================================================================
# Post-Installation
# ==============================================================================

echo "Applying permissions (PUID: 0 / PGID: 0)..."
chown -R 0:0 "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$FILE_RESOURCES"

echo "Extension initialization complete."