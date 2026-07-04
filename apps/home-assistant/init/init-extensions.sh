#!/bin/sh
set -e

# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Modular installer for Home Assistant integrations and frontend UI
#              plugins. Surgically injects frontend resources directly into
#              Home Assistant's internal JSON database (.storage).
# ==============================================================================

# Ensure jq is installed for robust JSON manipulation
if ! command -v jq >/dev/null 2>&1; then
  apk add --no-cache -q jq
fi

# --- Global Configurations ---
DIR_INTEGRATIONS="/config/custom_components"
DIR_FRONTEND="/config/www/community"
DIR_STORAGE="/config/.storage"
FILE_RESOURCES="${DIR_STORAGE}/lovelace_resources"

mkdir -p "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

# Initialize Home Assistant's resource database if it doesn't exist (e.g., fresh install)
if [ ! -f "$FILE_RESOURCES" ]; then
  echo '{"version":1,"minor_version":1,"key":"lovelace_resources","data":{"items":[]}}' > "$FILE_RESOURCES"
  echo "Initialized fresh lovelace_resources JSON database."
fi

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

  if [ -z "$ZIP_URL" ]; then
    ZIP_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.zip"
  fi

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
    echo "Error: manifest.json not found inside archive!"
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

  if [ -n "$ZIP_URL" ]; then
    local TEMP_ZIP="/tmp/ext_archive.zip"
    wget -qO "$TEMP_ZIP" "$ZIP_URL"
    unzip -q -o "$TEMP_ZIP" -d "$DEST_PATH/"
    rm -f "$TEMP_ZIP"
  else
    local FOUND_ASSETS=0
    for url in $ASSET_URLS; do
      if echo "$url" | grep -qE '\.(js|css)$'; then
        wget -q -P "$DEST_PATH" "$url"
        FOUND_ASSETS=1
      fi
    done
    if [ "$FOUND_ASSETS" -eq 0 ]; then
      echo "Error: No valid frontend assets found!"
      exit 1
    fi
  fi
  echo "Extracted/Downloaded to ${DEST_PATH}"

  # --- JSON Injection: Safely register resource in Home Assistant ---
  local JS_FILE=$(find "$DEST_PATH" -name "*.js" | head -n 1)

  if [ -n "$JS_FILE" ]; then
    local JS_BASENAME=$(basename "$JS_FILE")
    local RESOURCE_URL="/local/community/${REPO_NAME}/${JS_BASENAME}"

    # Check if URL is already registered in the JSON to prevent duplicates
    local EXISTS=$(jq --arg url "$RESOURCE_URL" '.data.items[]? | select(.url == $url)' "$FILE_RESOURCES")

    if [ -z "$EXISTS" ]; then
      # Generate a UUID for the new entry
      local UUID=$(cat /proc/sys/kernel/random/uuid)

      # Inject the new object into the items array
      local TMP_JSON=$(mktemp)
      jq --arg url "$RESOURCE_URL" --arg id "$UUID" \
        '.data.items += [{"id": $id, "type": "module", "url": $url}]' \
        "$FILE_RESOURCES" > "$TMP_JSON"

      mv "$TMP_JSON" "$FILE_RESOURCES"
      echo "Injected ${JS_BASENAME} into internal .storage database."
    else
      echo "Resource ${JS_BASENAME} already registered. Skipping injection."
    fi
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

  if echo "$arg" | grep -q "="; then
    TYPE="${arg%%=*}"
    REPO_VERSION="${arg#*=}"
  fi

  REPO="${REPO_VERSION%%:*}"
  VERSION="${REPO_VERSION##*:}"

  if [ "$REPO" = "$VERSION" ]; then VERSION="latest"; fi
  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(get_latest_version "$REPO")
  fi

  if [ "$TYPE" = "frontend" ]; then
    install_frontend "$REPO" "$VERSION"
  else
    install_integration "$REPO" "$VERSION"
  fi
done

echo "Applying permissions (PUID: 0 / PGID: 0)..."
chown -R 0:0 "$DIR_INTEGRATIONS" "$DIR_FRONTEND" "$DIR_STORAGE"

echo "Extension initialization complete."