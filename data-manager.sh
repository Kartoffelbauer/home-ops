#!/usr/bin/env bash

# ==============================================================================
# Home-Ops Data Manager (Backup & Restore)
# ==============================================================================
# Description: Safely backs up and restores all dynamically found 'data'
#              directories across the modular Docker Compose stack.
# Note: Performs scoped, sequential "Cold Backups" per module to minimize
#       service downtime. Resolves dependencies by targeting the root compose
#       file. Restores perform a "Clean Slate" wipe before extraction.
# Log Output: /var/log/home-ops-data-manager.log
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. STRICT MODE & GLOBAL VARIABLES
# ------------------------------------------------------------------------------
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error.
# set -o pipefail: Return pipeline status as the last non-zero command status.
set -euo pipefail

# Project and Backup Variables
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT_COMPOSE="${PROJECT_ROOT}/docker-compose.yml"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
ARCHIVE_NAME="home-ops-backup_${TIMESTAMP}.tar.gz"
TAG_FILENAME=".backup_git_tag"

# Standardized Administrative Log Location
LOG_FILE="/var/log/home-ops-data-manager.log"

# CLI Flags
DRY_RUN=false
STAGE_ON_TARGET=false
COMMAND=""
TARGET_PATH=""

# Dynamic State Tracking for Safe Error Recovery
DESTRUCTIVE_PHASE=false
ACTIVE_STOPPED_SERVICES=()
STAGE_DIR=""

# ------------------------------------------------------------------------------
# 2. HELPER FUNCTIONS
# ------------------------------------------------------------------------------

# Centralized logging function handling terminal output and root file logging
_log() {
  local level="$1"
  local color="$2"
  local message="$3"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Terminal Output (Colorized)
  if [ "$level" = "ERROR" ]; then
    echo -e "${color}[${level}]\e[0m ${message}" >&2
  elif [ "$level" = "EMPTY" ]; then
    echo ""
  else
    echo -e "${color}[${level}]\e[0m ${message}"
  fi

  # File Logging (Only if root to prevent permission errors)
  if [ "$EUID" -eq 0 ]; then
    if [ "$level" = "EMPTY" ]; then
      echo "" >> "$LOG_FILE"
    else
      echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi
  fi
}

log_info()    { _log "INFO"    "\e[34m" "$1"; }
log_success() { _log "SUCCESS" "\e[32m" "$1"; }
log_error()   { _log "ERROR"   "\e[31m" "$1"; }
log_warn()    { _log "WARN"    "\e[33m" "$1"; }
log_empty()   { _log "EMPTY"   ""       ""; }

# Wrapper for executing shell commands with DRY-RUN support and logging
execute() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would execute: $*"
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

# Wrapper for quiet shell operations (e.g., file removals) with DRY-RUN support
execute_quiet() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would execute: $*"
  else
    "$@"
  fi
}

# Safely restores a stashed .env file if the original is missing
restore_stashed_env() {
  if [[ -f "${PROJECT_ROOT}/.env.bak" && ! -f "${PROJECT_ROOT}/.env" ]]; then
    log_warn "Restoring stashed .env file..."
    execute_quiet mv -f "${PROJECT_ROOT}/.env.bak" "${PROJECT_ROOT}/.env"
  fi
}

# Context-aware error recovery executed if the script exits unexpectedly
on_error_cleanup() {
  local exit_code=$?

  # Clean up temporary staging directory if it exists
  if [[ -n "${STAGE_DIR:-}" && -d "$STAGE_DIR" ]]; then
    execute_quiet rm -rf "$STAGE_DIR"
  fi

  if [[ $exit_code -ne 0 ]]; then
    # Suppress generic error output for expected CLI usage errors (exit code 2)
    if [[ $exit_code -ne 2 ]]; then
      log_empty
      log_error "Script failed with exit code ${exit_code}."
    fi

    # 1. Safe Cleanup: Remove lingering tag file if present
    execute_quiet rm -f "${PROJECT_ROOT}/${TAG_FILENAME}"

    # 2. Safe Cleanup: Restore stashed .env if it was left behind
    restore_stashed_env

    # 3. Context-Aware Stack Recovery
    if [[ "$DESTRUCTIVE_PHASE" == true ]]; then
      log_empty
      log_error "CRITICAL FAILURE DURING DESTRUCTIVE RESTORE PHASE!"
      log_error "Data directories may be in a partial, wiped, or corrupted state."
      log_error "Automatic container restart has been ABORTED to prevent corruption."
      log_error "Please investigate the issue and intervene manually."
      log_empty
    elif [[ ${#ACTIVE_STOPPED_SERVICES[@]} -gt 0 ]]; then
      log_warn "Attempting safe recovery restart of stopped services..."
      start_services "${ACTIVE_STOPPED_SERVICES[@]}" || log_error "Failed to restart some services automatically."
    fi
  fi
}

# Attach the trap
trap on_error_cleanup EXIT

# Asserts root privileges to preserve file permissions and write logs
check_root() {
  if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root to preserve file permissions."
    log_error "Please run with: sudo $0 $*"
    exit 1
  fi
}

# Safely loads multiline command output into an array using Bash namerefs
_load_array() {
  local -n _array_ref=$1
  shift
  _array_ref=()
  [[ $# -eq 0 ]] && return 0 # Exit if no command is provided

  while IFS= read -r line; do
    [[ -n "$line" ]] && _array_ref+=("$line")
  done < <("$@")
}

# Unified user confirmation prompt for destructive actions
confirm_action() {
  local message="$1"
  if [[ "$DRY_RUN" == false ]]; then
    echo -e "${message}"
    read -p "Are you absolutely sure you want to proceed? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Action aborted by user."
      exit 0
    fi
  else
    log_info "[DRY-RUN] Would pause for user confirmation here."
  fi
}

# Explicit help: success exit, stdout, no error notices
show_help() {
  cat << EOF
Usage: $(basename "$0") [options] <command> <target_path>

Options:
  -h, --help              Show this help message and exit
  --dry-run               Simulate the process without modifying files or states
  --stage-on-target       Create the temporary staging directory directly on the target path
                          (useful if the internal drive is low on space, but may impact performance)

Commands:
  backup  <dest_dir>      Stops scoped containers and backs up data dirs to <dest_dir>
  restore <archive_file>  Stops scoped containers, WIPES current data, and extracts <archive_file>

Examples:
  sudo $(basename "$0") backup /mnt/backups
  sudo $(basename "$0") restore /mnt/backups/home-ops-backup_2023-10-25_14-00-00.tar.gz --dry-run
EOF
  exit 0
}

# Syntax failure: error exit, stderr, specific cause + quick hint
usage_error() {
  local message="$1"
  echo -e "\e[31m[ERROR]\e[0m ${message}" >&2
  echo "Try '$(basename "$0") --help' for more information." >&2
  exit 2
}

# ------------------------------------------------------------------------------
# 3. DISCOVERY & MAPPING LOGIC
# ------------------------------------------------------------------------------

# Finds top-level 'data' directories intended for operations.
# Uses -prune to prevent recursion into nested 'data/data' directories.
get_backup_data_dirs() {
  find "${PROJECT_ROOT}" -mindepth 1 \
    -type d -name ".git" -prune -o \
    -type d -path "*/core/routing/ddns-updater" -prune -o \
    -type d -path "*/core/routing/traefik" -prune -o \
    -type d -name "data" -prune -print
}

# Finds ALL top-level 'data' directories on disk for complete state purging.
# Uses -prune to prevent recursion into nested 'data/data' directories.
get_all_data_dirs() {
  find "${PROJECT_ROOT}" -mindepth 1 \
    -type d -name ".git" -prune -o \
    -type d -name "data" -prune -print
}

# Maps a single 'data' directory to its parent `<service>.yml` Compose file
get_yml_for_data_dir() {
  local data_path="$1"
  local parent_dir
  parent_dir="$(dirname "$data_path")"

  local expected_yml="${parent_dir}/$(basename "$parent_dir").yml"

  if [[ -f "$expected_yml" ]]; then
    echo "$expected_yml"
  fi
}

# Resolves an array of data paths into a deduplicated list of target YML files
get_unique_ymls() {
  local ymls=()
  for dir in "$@"; do
    local yml
    yml=$(get_yml_for_data_dir "$dir")
    [[ -n "$yml" ]] && ymls+=("$yml")
  done

  if [[ ${#ymls[@]} -gt 0 ]]; then
    printf "%s\n" "${ymls[@]}" | sort -u
  fi
}

# Statically extracts top-level service names from a compose file using robust YAML parsing
get_services_from_yml() {
  local yml="$1"
  awk '
    /^services:/ { in_services=1; indent=""; next }
    in_services {
      # Skip empty lines (including Windows CRLF) and full-line comments
      if (/^[ \t\r]*$/ || /^[ \t]*#/) next

      # If we hit a new unindented root key, stop parsing services
      if (/^[^ \t\r]/) { in_services=0; next }

      # Capture the exact indentation of the first service block
      if (indent == "") {
        match($0, /^[ \t]+/)
        indent = substr($0, RSTART, RLENGTH)
      }

      # Match keys at the exact indentation level to grab all sibling services
      regex = "^" indent "[a-zA-Z0-9_-]+:"
      if ($0 ~ regex) {
        name = $0
        sub(/^[ \t]+/, "", name)
        sub(/:.*/, "", name)
        print name
      }
    }
  ' "$yml"
}

# Resolves an array of data directories to a deduplicated list of active services
get_services_for_data_dirs() {
  local dirs=("$@")
  local ymls=() all_services=()

  [[ ${#dirs[@]} -eq 0 ]] && return 0

  _load_array ymls get_unique_ymls "${dirs[@]}"

  for yml in "${ymls[@]}"; do
    local srvs=()
    _load_array srvs get_services_from_yml "$yml"
    [[ ${#srvs[@]} -gt 0 ]] && all_services+=("${srvs[@]}")
  done

  if [[ ${#all_services[@]} -gt 0 ]]; then
    printf "%s\n" "${all_services[@]}" | sort -u
  fi
}

# Unified execution function targeting the root docker-compose to satisfy network and dependency trees
_manage_services() {
  local action="$1"
  shift
  local services=("$@")
  local env_arg=()

  [[ ${#services[@]} -eq 0 ]] && return 0

  if [[ ! -f "$ROOT_COMPOSE" ]]; then
    log_error "Root compose file missing at ${ROOT_COMPOSE}. Cannot manage cross-dependencies."
    exit 1
  fi

  [[ -f "${PROJECT_ROOT}/.env" ]] && env_arg=("--env-file" "${PROJECT_ROOT}/.env")

  (
    cd "${PROJECT_ROOT}" || exit 1
    if [[ "$action" == "stop" ]]; then
      execute docker compose "${env_arg[@]:-}" -f "$ROOT_COMPOSE" stop "${services[@]}"
    else
      # The --no-deps flag prevents Docker Compose from automatically starting chained services
      # (e.g., core routing) if they were deliberately taken offline.
      execute docker compose "${env_arg[@]:-}" -f "$ROOT_COMPOSE" up -d --no-deps "${services[@]}"
    fi
  )
}

stop_services() {
  _manage_services "stop" "$@"
  ACTIVE_STOPPED_SERVICES+=("$@")
}

start_services() {
  _manage_services "start" "$@"

  # Remove successfully started services from the active recovery tracking array
  local remaining=()
  for active in "${ACTIVE_STOPPED_SERVICES[@]}"; do
    local started=false
    for srv in "$@"; do
      if [[ "$active" == "$srv" ]]; then
        started=true
        break
      fi
    done
    [[ "$started" == false ]] && remaining+=("$active")
  done

  # Safely and completely empty the array if no services remain
  if [[ ${#remaining[@]} -eq 0 ]]; then
    ACTIVE_STOPPED_SERVICES=()
  else
    ACTIVE_STOPPED_SERVICES=("${remaining[@]}")
  fi
}

# Retrieves current Git tag or short commit hash
get_current_git_tag() {
  (cd "$PROJECT_ROOT" && git describe --tags --always 2>/dev/null) || echo "unknown"
}

# ------------------------------------------------------------------------------
# 4. CORE LOGIC: BACKUP
# ------------------------------------------------------------------------------

do_backup() {
  local dest_dir="$1"

  if [[ ! -d "$dest_dir" ]]; then
    log_error "Destination directory '$dest_dir' does not exist."
    exit 1
  fi

  local dest_file="${dest_dir}/${ARCHIVE_NAME}"
  log_empty
  log_info "Initiating sequential per-module backup process..."

  # 1. Discover backup-eligible data directories
  local data_dirs
  _load_array data_dirs get_backup_data_dirs

  if [[ ${#data_dirs[@]} -eq 0 ]]; then
    log_warn "No eligible 'data' directories found. Nothing to backup."
    exit 0
  fi

  # 2. Create temporary staging area for progressive file collection
  if [[ "$DRY_RUN" == false ]]; then
    if [[ "$STAGE_ON_TARGET" == true ]]; then
      STAGE_DIR=$(mktemp -d "${dest_dir}/.backup_stage_XXXXXX")
    else
      STAGE_DIR=$(mktemp -d "${PROJECT_ROOT}/.backup_stage_XXXXXX")
    fi
  else
    if [[ "$STAGE_ON_TARGET" == true ]]; then
      STAGE_DIR="${dest_dir}/.backup_stage_DRYRUN"
    else
      STAGE_DIR="${PROJECT_ROOT}/.backup_stage_DRYRUN"
    fi
  fi

  # 3. Iterate sequentially through data directories to minimize downtime per service
  for dir in "${data_dirs[@]}"; do
    local rel_dir="${dir#${PROJECT_ROOT}/}"
    local target_yml
    target_yml=$(get_yml_for_data_dir "$dir")

    local module_services=()
    if [[ -n "$target_yml" ]]; then
      _load_array module_services get_services_from_yml "$target_yml"
    fi

    log_empty
    log_info "Processing data directory: ${rel_dir}"

    # Stop module services
    if [[ ${#module_services[@]} -gt 0 ]]; then
      log_info "Stopping scoped services: ${module_services[*]}..."
      stop_services "${module_services[@]}"
    fi

    # Copy data payload into staging directory preserving relative structural paths
    if [[ "$DRY_RUN" == false ]]; then
      log_info "Staging data payload for ${rel_dir}..."
      mkdir -p "${STAGE_DIR}/$(dirname "$rel_dir")"
      execute_quiet cp --reflink=auto -a "${PROJECT_ROOT}/${rel_dir}" "${STAGE_DIR}/${rel_dir}"
    else
      log_info "[DRY-RUN] Would stage data payload for ${rel_dir}..."
    fi

    # Immediately restart module services
    if [[ ${#module_services[@]} -gt 0 ]]; then
      log_info "Restarting scoped services: ${module_services[*]}..."
      start_services "${module_services[@]}"
    fi
  done

  log_empty

  # 4. Append global environment metadata to staging
  if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    log_info "Staging global .env file..."
    execute_quiet cp -a "${PROJECT_ROOT}/.env" "${STAGE_DIR}/.env"
  fi

  # 5. Embed Git tag metadata into backup payload
  local current_tag
  current_tag=$(get_current_git_tag)
  log_info "Pinning backup to Git tag: ${current_tag}"

  if [[ "$DRY_RUN" == false ]]; then
    echo "$current_tag" > "${STAGE_DIR}/${TAG_FILENAME}"
  else
    log_info "[DRY-RUN] Would write Git tag '${current_tag}' to ${TAG_FILENAME}"
  fi

  # 6. Archive staged payload directly into final destination tarball
  log_info "Creating compressed archive at: ${dest_file}..."
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] tar -czpf ${dest_file} -C ${STAGE_DIR} ."
  else
    tar -czpf "${dest_file}" -C "${STAGE_DIR}" . 2>&1 | tee -a "$LOG_FILE"
  fi

  # 7. Clean up temporary staging directory upon successful creation
  if [[ -n "${STAGE_DIR:-}" && -d "$STAGE_DIR" ]]; then
    execute_quiet rm -rf "$STAGE_DIR"
    STAGE_DIR=""
  fi

  log_success "Backup completed successfully: ${dest_file}"
}

# ------------------------------------------------------------------------------
# 5. CORE LOGIC: RESTORE
# ------------------------------------------------------------------------------

wipe_current_state() {
  local dirs=("$@")
  log_info "Wiping all existing data directories to achieve a clean slate..."
  cd "${PROJECT_ROOT}" || exit 1

  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      log_info "Deleting folder: ${dir#${PROJECT_ROOT}/}..."
      execute_quiet rm -rf "$dir"
    fi
  done

  # Stash .env temporarily instead of hard-deleting to safeguard container variables
  if [[ -f ".env" ]]; then
    log_info "Stashing current .env file..."
    execute_quiet mv -f ".env" ".env.bak"
  fi

  log_success "Clean slate achieved."
}

verify_git_tag() {
  local archive_file="$1"
  local current_tag
  current_tag=$(get_current_git_tag)

  # Direct file extraction prevents SIGPIPE failures under set -o pipefail
  local backup_tag
  backup_tag=$(tar -xzpf "$archive_file" -O "$TAG_FILENAME" 2>/dev/null || echo "missing_in_archive")
  [[ -z "$backup_tag" ]] && backup_tag="missing_in_archive"

  if [[ "$backup_tag" != "$current_tag" ]]; then
    log_warn "Git tag mismatch! Backup tag: \e[1m$backup_tag\e[0m \e[33m| Current tag:\e[0m \e[1m$current_tag\e[0m"
    confirm_action "Are you absolutely sure you want to proceed with the restore despite the tag mismatch?"
  fi
}

do_restore() {
  local archive_file="$1"

  if [[ ! -f "$archive_file" ]]; then
    log_error "Archive file '$archive_file' does not exist."
    exit 1
  fi

  # Require explicit user opt-in before data destruction
  confirm_action "\e[31m[CRITICAL WARNING]\e[0m This will COMPLETELY DELETE all current data directories and replace them with the backup."

  log_empty
  log_info "Initiating restore process..."

  verify_git_tag "$archive_file"

  # 1. Discover ALL existing data directories to aggregate services that must be shut down
  local wipe_data_dirs all_services=()
  _load_array wipe_data_dirs get_all_data_dirs

  if [[ ${#wipe_data_dirs[@]} -gt 0 ]]; then
    _load_array all_services get_services_for_data_dirs "${wipe_data_dirs[@]}"
  fi

  # 2. Stop all running stacks associated with existing data directories
  [[ ${#all_services[@]} -gt 0 ]] && stop_services "${all_services[@]}"

  # Flag active: Any failure past this point requires manual intervention
  DESTRUCTIVE_PHASE=true

  # 3. Wipe ALL existing data directories (achieving a pure clean slate)
  [[ ${#wipe_data_dirs[@]} -gt 0 ]] && wipe_current_state "${wipe_data_dirs[@]}"

  # 4. Extract archive
  log_info "Extracting backup from: ${archive_file}..."
  cd "${PROJECT_ROOT}" || exit 1
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] tar -xzpf ${archive_file}"
  else
    tar -xzpf "${archive_file}" 2>&1 | tee -a "$LOG_FILE"
  fi

  # 5. Clean up extraction artifacts and finalize .env state
  execute_quiet rm -f "${PROJECT_ROOT}/${TAG_FILENAME}"
  restore_stashed_env
  execute_quiet rm -f "${PROJECT_ROOT}/.env.bak"

  # Extraction successful. Destructive phase over.
  DESTRUCTIVE_PHASE=false

  # 6. Discover post-restore target stacks and bring them back online
  local post_data_dirs post_services=()
  _load_array post_data_dirs get_backup_data_dirs

  if [[ ${#post_data_dirs[@]} -gt 0 ]]; then
    _load_array post_services get_services_for_data_dirs "${post_data_dirs[@]}"
  fi

  [[ ${#post_services[@]} -gt 0 ]] && start_services "${post_services[@]}"

  log_success "Restore completed successfully."
}

# ------------------------------------------------------------------------------
# 6. ENTRYPOINT
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --stage-on-target)
      STAGE_ON_TARGET=true
      shift
      ;;
    backup|restore)
      if [[ -n "$COMMAND" ]]; then
        usage_error "Multiple commands specified: '$COMMAND' and '$1'"
      fi
      COMMAND="$1"
      TARGET_PATH="${2:-}"

      if [[ -z "$TARGET_PATH" || "$TARGET_PATH" == --* ]]; then
        usage_error "Target path is required for $COMMAND"
      fi

      # Resolve target path to an absolute path before working directory changes
      if [[ ! "$TARGET_PATH" = /* ]]; then
        TARGET_PATH="$(pwd)/$TARGET_PATH"
      fi

      # Strip trailing slashes to prevent double-slash formatting artifacts in paths
      TARGET_PATH="${TARGET_PATH%/}"

      shift 2
      ;;
    *)
      usage_error "Unknown argument: $1"
      ;;
  esac
done

[[ -z "$COMMAND" ]] && usage_error "No command specified."

check_root

if [[ "$DRY_RUN" == true ]]; then
  log_warn "Running in DRY-RUN mode. No changes will be made."
fi

case "$COMMAND" in
  backup)  do_backup "$TARGET_PATH" ;;
  restore) do_restore "$TARGET_PATH" ;;
esac