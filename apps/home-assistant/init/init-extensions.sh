#!/bin/sh
set -e

# ==============================================================================
# Script: init-extensions.sh (Home Assistant)
# Environment: Alpine (POSIX sh)
# Description: Automatically downloads and installs Home Assistant Custom Components
#              (HACS equivalents) from GitHub releases. Extracts archives, locates
#              the component via manifest.json, and places it into the correct
#              custom_components directory.
#
# Usage: ./init-extensions.sh [author/repo:version] ...
# Example: ./init-extensions.sh smartHomeHub/SmartIR:1.17.6 custom-components/hacs:latest
# ==============================================================================

# Ensure the target installation directory exists within the Home Assistant config
DEST_DIR="/config/custom_components"
mkdir -p "$DEST_DIR"

# ------------------------------------------------------------------------------
# Function: install_extension
# Description: Fetches, downloads, extracts, and installs a single HA custom component.
# Arguments:
#   $1 - GitHub Repository (e.g., "author/repo")
#   $2 - Target Version (e.g., "1.17.6" or "latest")
# ------------------------------------------------------------------------------
install_extension() {
  local REPO="$1"
  local VERSION="$2"

  echo "Processing ${REPO}..."

  # 1. Determine Target Version
  # If version is "latest" or empty, query the GitHub API to find the newest release tag.
  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | \
              grep '"tag_name":' | \
              sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  fi
  echo "Target version: ${VERSION}"

  # 2. Locate Download URL
  # Query the specific release and look for a compiled .zip asset.
  local ASSET_URL=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}" | \
                    grep '"browser_download_url":' | \
                    grep -E '\.(zip)"' | \
                    head -n 1 | \
                    sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

  # Fallback mechanism: If developers don't attach compiled binaries (very common
  # for Python scripts), gracefully fallback to downloading the source code archive.
  if [ -z "$ASSET_URL" ]; then
    echo "No compiled asset found, falling back to source code archive..."
    ASSET_URL="https://github.com/${REPO}/archive/refs/tags/${VERSION}.zip"
  fi

  # 3. Download and Extract the Asset
  # Extract into an isolated temporary directory to prevent file conflicts
  local FILE_NAME="ext_archive.zip"
  echo "Downloading from ${ASSET_URL}..."
  wget -qO "/tmp/${FILE_NAME}" "$ASSET_URL"

  mkdir -p "/tmp/ext_extract"
  unzip -q -o "/tmp/${FILE_NAME}" -d "/tmp/ext_extract/"

  # 4. Install the Application
  # HA components are often deeply nested in zips (e.g., repo-name-main/custom_components/smartir).
  # We dynamically find the correct root by locating the component's 'manifest.json' file.
  local MANIFEST_DIR=$(find "/tmp/ext_extract" -name "manifest.json" -exec dirname {} \; | head -n 1)

  if [ -n "$MANIFEST_DIR" ]; then
    local COMPONENT_NAME=$(basename "$MANIFEST_DIR")

    # Clear any existing installation to ensure a clean slate and prevent orphaned files
    rm -rf "${DEST_DIR}/${COMPONENT_NAME}"

    # Move the located component directory into the Home Assistant configuration
    mv "$MANIFEST_DIR" "${DEST_DIR}/${COMPONENT_NAME}"
    echo "Successfully installed ${COMPONENT_NAME} into ${DEST_DIR}/${COMPONENT_NAME}"
  else
    echo "Error: manifest.json not found inside ${REPO} release archive!"
    exit 1
  fi

  # 5. Cleanup
  # Remove temporary extraction folders and downloaded zip files
  rm -rf "/tmp/ext_extract" "/tmp/${FILE_NAME}"
  echo "----------------------------------------"
}


# ==============================================================================
# Main Execution
# ==============================================================================

# Abort cleanly if no arguments are provided
if [ "$#" -eq 0 ]; then
  echo "No extensions specified to install."
  exit 0
fi

# Iterate over all provided arguments
for arg in "$@"; do
  # Split argument into REPO and VERSION based on the colon ':' delimiter
  REPO="${arg%%:*}"
  VERSION="${arg##*:}"

  # Fallback to 'latest' if the user omitted the version tag (e.g., just "author/repo")
  if [ "$REPO" = "$VERSION" ]; then
    VERSION="latest"
  fi

  # Execute installation
  install_extension "$REPO" "$VERSION"
done

# 6. Apply Correct Permissions
# Ensure the newly created files are owned by the Home Assistant container user
# to prevent read/write errors when the application boots up.
echo "Applying permissions (PUID: 0 / PGID: 0)..."
chown -R 0:0 "$DEST_DIR"

echo "Extension initialization complete."