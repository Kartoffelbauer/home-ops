#!/bin/sh
# ==============================================================================
# Script: init-storage.sh
# Environment: Alpine (POSIX sh)
# Description: Declarative, idempotent provisioner for Home Assistant internal
#              storage (.storage) configurations. Ensures required settings
#              (MQTT broker credentials, HTTP server config, etc.) are present
#              and correct on every boot. Uses atomic file transactions to
#              prevent state corruption. Modular design allows easy extension.
# ==============================================================================

# Exit on error (-e), treat unset variables as an error (-u), and fail pipes (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Global Configuration & Environment Initialization
# ------------------------------------------------------------------------------

DIR_STORAGE="/config/.storage"

# Storage Files
FILE_CONFIG_ENTRIES="${DIR_STORAGE}/core.config_entries"
FILE_HTTP_CONFIG="${DIR_STORAGE}/http"

# Environment Variables
MQTT_PASS="${ZIGBEE_MOSQUITTO_PASSWORD_HA:-}"
HTTP_SERVER_PORT="${HOMEASSISTANT_HTTP_SERVER_PORT:-8123}"
HTTP_TRUSTED_PROXIES="${HOMEASSISTANT_HTTP_TRUSTED_PROXIES:-127.0.0.1/32,172.16.0.0/12,::1/128,fd00:172:29::/64}"

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

# --- Baseline Initializations ---
# Validate or reset baseline configurations if missing or corrupted

# Baseline: core.config_entries (MQTT, Integrations)
if [ ! -f "$FILE_CONFIG_ENTRIES" ] || ! jq . "$FILE_CONFIG_ENTRIES" >/dev/null 2>&1; then
  echo "[SETUP] 'core.config_entries' is missing or invalid. Initializing baseline..." >&2
  echo '{"version": 1, "minor_version": 5, "key": "core.config_entries", "data": {"entries": []}}' > "$FILE_CONFIG_ENTRIES"
fi

# Baseline: http (Reverse Proxy, Port)
if [ ! -f "$FILE_HTTP_CONFIG" ] || ! jq . "$FILE_HTTP_CONFIG" >/dev/null 2>&1; then
  echo "[SETUP] 'http' configuration is missing or invalid. Initializing baseline..." >&2
  echo '{"version": 2, "minor_version": 2, "key": "http", "data": {"stable": null, "pending": null, "yaml_migration_done": true}}' > "$FILE_HTTP_CONFIG"
fi

# ------------------------------------------------------------------------------
# 2. Storage Provisioning Modules (DRY & Isolated)
# ------------------------------------------------------------------------------

generate_entry_id() {
  # Generates a 26-character Crockford Base32 compliant ULID string
  tr -dc '0-9A-GHJKMNP-TV-Z' < /dev/urandom | fold -w 26 | head -n 1
}

# --- Module: MQTT Broker ---
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

# --- Module: HTTP Configuration ---
provision_http_config() {
  local staging_file="${TEMP_WORKSPACE}/http.tmp"
  local existing_port
  local existing_proxies

  # Format the comma-separated environment variable into a valid JSON array
  local proxies_json
  proxies_json=$(echo "$HTTP_TRUSTED_PROXIES" | tr ',' '\n' | jq -R . | jq -s .)

  # Minify proxies for accurate string comparison
  local desired_proxies_min
  desired_proxies_min=$(echo "$proxies_json" | jq -c .)

  # Extract existing state (if any)
  existing_port=$(jq -r '.data.stable.server_port // empty' "$FILE_HTTP_CONFIG")
  existing_proxies=$(jq -c '.data.stable.trusted_proxies // []' "$FILE_HTTP_CONFIG")

  # State Reconciliation
  if [ "$existing_port" = "$HTTP_SERVER_PORT" ] && [ "$existing_proxies" = "$desired_proxies_min" ]; then
    echo "[SKIP] HTTP configuration is already up to date. No changes needed." >&2
    return 0
  else
    echo "[ACTION] Configuration mismatch detected. Injecting HTTP settings (Port: $HTTP_SERVER_PORT)..." >&2

    # Perform atomic injection for the exact HTTP configuration payload
    jq \
      --argjson port "$HTTP_SERVER_PORT" \
      --argjson proxies "$proxies_json" \
      '.data.stable = {
        "use_x_forwarded_for": true,
        "trusted_proxies": $proxies,
        "server_port": $port,
        "ip_ban_enabled": true,
        "cors_allowed_origins": [
          "https://cast.home-assistant.io"
        ],
        "use_x_frame_options": true,
        "ssl_profile": "modern",
        "login_attempts_threshold": -1,
        "created_at": (now | strftime("%Y-%m-%dT%H:%M:%S.000000+00:00")),
        "error": null,
        "error_message": null
      } | .data.pending = null | .data.yaml_migration_done = true' "$FILE_HTTP_CONFIG" > "$staging_file"
  fi

  # Commit transaction to production file atomically
  mv "$staging_file" "$FILE_HTTP_CONFIG"
  echo "[SUCCESS] HTTP configuration provisioned successfully." >&2
}

# ==============================================================================
# 3. Main Execution
# ==============================================================================

echo "[INFO] Starting Home Assistant storage provisioning sequence..." >&2

# Execute modular provisioners
provision_mqtt_broker
provision_http_config

echo "[SETUP] Applying file ownership (PUID: 0 / PGID: 0) for Home Assistant..." >&2
chown -R 0:0 "$DIR_STORAGE"

echo "[INFO] Storage initialization sequence complete." >&2