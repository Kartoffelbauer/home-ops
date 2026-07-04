#!/bin/sh
set -e

# ==============================================================================
# Script: init-extensions.sh
# Environment: Alpine (POSIX sh)
# Description: Automatically downloads and installs oCIS web extensions from
#              GitHub releases. Extracts archives, places valid extensions
#              (identified by manifest.json) into the /apps directory,
#              and fixes file ownership.
#
# Usage: ./init-extensions.sh [author/repo:version] ...
# Example: ./init-extensions.sh LukasHirt/web-app-excalidraw:latest mschlachter/ocis-app-tokens:1.0.0
# ==============================================================================

# Ensure the target installation directory exists
DEST_DIR="/apps"
mkdir -p "$DEST_DIR"

# ------------------------------------------------------------------------------
# Installation Pipelines
# ------------------------------------------------------------------------------

install_extension() {
  local REPO="$1"
  local VERSION="$2"
  local APP_NAME="${REPO##*/}"

  echo "Processing ${REPO}..."

  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | \
              grep '"tag_name":' | \
              sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  fi
  echo "Target version: ${VERSION}"

  local ASSET_URL=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}" | \
                    grep '"browser_download_url":' | \
                    grep -E '\.(tar\.gz|tgz|zip)"' | \
                    head -n 1 | \
                    sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

  if [ -z "$ASSET_URL" ]; then
    echo "Error: Could not find a suitable .zip or .tar.gz release asset for ${REPO}."
    exit 1
  fi

  local FILE_NAME="${ASSET_URL##*/}"
  echo "Downloading ${FILE_NAME}..."
  wget -qO "/tmp/${FILE_NAME}" "$ASSET_URL"

  echo "Extracting ${FILE_NAME}..."
  mkdir -p "/tmp/ext_${APP_NAME}"

  if echo "$FILE_NAME" | grep -q '\.zip$'; then
    unzip -q -o "/tmp/${FILE_NAME}" -d "/tmp/ext_${APP_NAME}/"
  else
    tar -xzf "/tmp/${FILE_NAME}" -C "/tmp/ext_${APP_NAME}/"
  fi

  local MANIFEST_DIR=$(find "/tmp/ext_${APP_NAME}" -name "manifest.json" -exec dirname {} \; | head -n 1)

  if [ -n "$MANIFEST_DIR" ]; then
    rm -rf "${DEST_DIR}/${APP_NAME}"
    mv "$MANIFEST_DIR" "${DEST_DIR}/${APP_NAME}"
    echo "Successfully installed ${APP_NAME} into ${DEST_DIR}/${APP_NAME}"
  else
    echo "Error: manifest.json not found inside ${REPO} release archive!"
    exit 1
  fi

  rm -rf "/tmp/ext_${APP_NAME}" "/tmp/${FILE_NAME}"
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
  REPO="${arg%%:*}"
  VERSION="${arg##*:}"
  if [ "$REPO" = "$VERSION" ]; then
    VERSION="latest"
  fi
  install_extension "$REPO" "$VERSION"
done

# ==============================================================================
# Post-Installation
# ==============================================================================

echo "Applying permissions (PUID: ${OCIS_PUID:-1005} / PGID: ${OCIS_PGID:-1005})..."
chown -R ${OCIS_PUID:-1005}:${OCIS_PGID:-1005} "$DEST_DIR"

echo "Extension initialization complete."