#!/bin/sh
# ==============================================================================
# Script: init-mqtt.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, idempotent provisioner for Home Assistant MQTT
#              configuration. Ensures the core.config_entries storage file
#              contains the MQTT broker credentials on every boot. Uses atomic
#              file transactions to prevent state corruption. Automatically
#              detects and updates credentials if the environment changes.
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DIR_STORAGE="/config/.storage"
FILE_CONFIG_ENTRIES="${DIR_STORAGE}/core.config_entries"

# Environment variables
MQTT_PASS="${ZIGBEE_MOSQUITTO_PASSWORD_HA:-}"

# Ensure runtime dependencies are met
if ! command -v jq >/dev/null 2>&1; then
  echo "[SETUP] Installing required dependency: jq..." >&2
  apk add --no-cache -q jq
fi

# Setup automatic cleanup of temporary workspace directories on exit or failure
TEMP_WORKSPACE=$(mktemp -d)
trap 'rm -rf "$TEMP_WORKSPACE"' EXIT

# Ensure required directory structure exists
mkdir -p "$DIR_STORAGE"

# Validate or reset baseline configuration if missing or corrupted
if [ ! -f "$FILE_CONFIG_ENTRIES" ] || ! jq . "$FILE_CONFIG_ENTRIES" >/dev/null 2>&1; then
  echo "[SETUP] 'core.config_entries' is missing or invalid. Initializing baseline..." >&2
  echo '{"version": 1, "minor_version": 5, "key": "core.config_entries", "data": {"entries": []}}' > "$FILE_CONFIG_ENTRIES"
fi

# ------------------------------------------------------------------------------
# 2. Logic & Injection Helpers (DRY)
# ------------------------------------------------------------------------------

generate_entry_id() {
  # Generates a 26-character Crockford Base32 compliant ULID string
  tr -dc '0-9A-GHJKMNP-TV-Z' < /dev/urandom | fold -w 26 | head -n 1
}

provision_mqtt_broker() {
  local staging_file="${TEMP_WORKSPACE}/core.config_entries.tmp"
  local domain_exists
  local existing_pass

  # Validation guard
  if [ -z "$MQTT_PASS" ]; then
    echo "[ERROR] ZIGBEE_MOSQUITTO_PASSWORD_HA is missing in the environment. Cannot provision MQTT." >&2
    exit 1
  fi

  # Extract existing state (if any)
  domain_exists=$(jq -r 'first(.data.entries[] | select(.domain == "mqtt") | .domain) // empty' "$FILE_CONFIG_ENTRIES")
  existing_pass=$(jq -r 'first(.data.entries[] | select(.domain == "mqtt") | .data.password) // empty' "$FILE_CONFIG_ENTRIES")

  # State Reconciliation
  if [ "$domain_exists" = "mqtt" ]; then
    if [ "$existing_pass" = "$MQTT_PASS" ]; then
      echo "[SKIP] MQTT domain is already configured and password matches. No changes needed." >&2
      return 0
    else
      echo "[ACTION] Password change detected. Updating existing MQTT Broker credentials..." >&2
      # Update the password and modified_at timestamp on the existing entry
      jq \
        --arg pass "$MQTT_PASS" \
        '.data.entries |= map(
          if .domain == "mqtt" then
            .data.password = $pass |
            .modified_at = (now | strftime("%Y-%m-%dT%H:%M:%S.000000+00:00"))
          else
            .
          end
        )' "$FILE_CONFIG_ENTRIES" > "$staging_file"
    fi
  else
    echo "[ACTION] Injecting MQTT Broker configuration (localhost:1883)..." >&2
    local entry_id
    entry_id=$(generate_entry_id)

    # Perform atomic injection for a completely new entry
    jq \
      --arg pass "$MQTT_PASS" \
      --arg id "$entry_id" \
      '.data.entries += [{
        "created_at": (now | strftime("%Y-%m-%dT%H:%M:%S.000000+00:00")),
        "data": {
          "broker": "localhost",
          "password": $pass,
          "port": 1883,
          "protocol": "5",
          "username": "homeassistant"
        },
        "disabled_by": null,
        "discovery_keys": {},
        "domain": "mqtt",
        "entry_id": $id,
        "minor_version": 1,
        "modified_at": (now | strftime("%Y-%m-%dT%H:%M:%S.000000+00:00")),
        "options": {},
        "pref_disable_new_entities": false,
        "pref_disable_polling": false,
        "source": "user",
        "subentries": [],
        "title": "localhost",
        "unique_id": null,
        "version": 2
      }]' "$FILE_CONFIG_ENTRIES" > "$staging_file"
  fi

  # Commit transaction to production file atomically
  mv "$staging_file" "$FILE_CONFIG_ENTRIES"

  echo "[SUCCESS] MQTT Broker configured successfully." >&2
}

# ==============================================================================
# 3. Main Execution
# ==============================================================================

provision_mqtt_broker

echo "[SETUP] Applying file ownership (PUID: 0 / PGID: 0) for Home Assistant..." >&2
chown -R 0:0 "$DIR_STORAGE"

echo "[INFO] MQTT initialization sequence complete." >&2