#!/usr/bin/env bash

# ==============================================================================
# Home-Ops Data Manager (Backup & Restore)
# ==============================================================================
# Description: Safely backs up and restores all dynamically found 'data'
#              directories across the modular Docker Compose stack.
# Note: Performs scoped "Cold Backups" by mapping data directories to their
#       adjacent `<service>.yml` files, minimizing downtime. Restores perform
#       a "Clean Slate" wipe to prevent merging corrupted data with backups.
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
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
ARCHIVE_NAME="home-ops-backup_${TIMESTAMP}.tar.gz"
TAG_FILENAME=".backup_git_tag"

# Standardized Administrative Log Location
LOG_FILE="/var/log/home-ops-data-manager.log"

# CLI Flags
DRY_RUN=false
COMMAND=""
TARGET_PATH=""

# Dynamic State Tracking for Safe Error Recovery
DESTRUCTIVE_PHASE=false
ACTIVE_STOPPED_YMLS=()

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
  else
    echo -e "${color}[${level}]\e[0m ${message}"
  fi

  # File Logging (Only if root to prevent permission errors)
  if [ "$EUID" -eq 0 ]; then
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
  fi
}

log_info()    { _log "INFO"    "\e[34m" "$1"; }
log_success() { _log "SUCCESS" "\e[32m" "$1"; }
log_error()   { _log "ERROR"   "\e[31m" "$1"; }
log_warn()    { _log "WARN"    "\e[33m" "$1"; }

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
  if [[ $exit_code -ne 0 ]]; then
    log_error "Script failed with exit code ${exit_code}."

    # 1. Safe Cleanup: Remove lingering tag file if present
    execute_quiet rm -f "${PROJECT_ROOT}/${TAG_FILENAME}"

    # 2. Safe Cleanup: Restore stashed .env if it was left behind
    restore_stashed_env

    # 3. Context-Aware Stack Recovery
    if [[ "$DESTRUCTIVE_PHASE" == true ]]; then
      log_error "================================================================="
      log_error "CRITICAL FAILURE DURING DESTRUCTIVE RESTORE PHASE!"
      log_error "Data directories may be in a partial, wiped, or corrupted state."
      log_error "Automatic container restart has been ABORTED to prevent corruption."
      log_error "Please investigate the issue and intervene manually."
      log_error "================================================================="
    elif [[ ${#ACTIVE_STOPPED_YMLS[@]} -gt 0 ]]; then
      log_warn "Attempting safe recovery restart of stopped stacks (no data was modified)..."
      start_scoped_stacks "${ACTIVE_STOPPED_YMLS[@]}" || log_error "Failed to restart some stacks automatically."
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

show_usage() {
  cat << EOF
Usage: $0 [options] <command> <target_path>

Options:
  --dry-run               Simulate the process without modifying files or states

Commands:
  backup  <dest_dir>      Stops scoped containers and backs up data dirs to <dest_dir>
  restore <archive_file>  Stops scoped containers, WIPES current data, and extracts <archive_file>

Examples:
  sudo $0 backup /mnt/backups
  sudo $0 restore /mnt/backups/home-ops-backup_2023-10-25_14-00-00.tar.gz --dry-run
EOF
  exit 1
}

# ------------------------------------------------------------------------------
# 3. DISCOVERY & MAPPING LOGIC
# ------------------------------------------------------------------------------

# Finds 'data' directories intended for backup/restore operations (excluding ephemeral state)
get_backup_data_dirs() {
  find "${PROJECT_ROOT}" -type d -name "data" \
    -not -path "*/\.git/*" \
    -not -path "*/core/routing/ddns-updater/*" \
    -not -path "*/core/routing/traefik/*"
}

# Finds ALL 'data' directories on disk (unfiltered) for complete state purging
get_all_data_dirs() {
  find "${PROJECT_ROOT}" -type d -name "data" -not -path "*/\.git/*"
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

# Unified Compose execution function for starting/stopping scoped stacks
_manage_stacks() {
  local action="$1"
  shift
  local ymls=("$@")
  local env_arg=()
  local project_name
  project_name="$(basename "${PROJECT_ROOT}")"

  [[ -f "${PROJECT_ROOT}/.env" ]] && env_arg=("--env-file" "${PROJECT_ROOT}/.env")

  for yml in "${ymls[@]}"; do
    local stack_name="${yml#${PROJECT_ROOT}/}"
    local yml_dir
    yml_dir="$(dirname "$yml")"
    local yml_file
    yml_file="$(basename "$yml")"

    (
      cd "$yml_dir" || exit 1
      if [[ "$action" == "stop" ]]; then
        log_info "Stopping associated stack: ${stack_name}"
        execute docker compose -p "$project_name" "${env_arg[@]:-}" -f "$yml_file" stop
      else
        log_info "Starting associated stack: ${stack_name}"
        execute docker compose -p "$project_name" "${env_arg[@]:-}" -f "$yml_file" up -d
      fi
    )
  done
}


stop_scoped_stacks() {
  _manage_stacks "stop" "$@"
  ACTIVE_STOPPED_YMLS=("${@}")
}

start_scoped_stacks() {
  _manage_stacks "start" "$@"
  ACTIVE_STOPPED_YMLS=()
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
  echo -e "\n========================================" >> "$LOG_FILE"
  log_info "INITIATING BACKUP PROCESS"

  # 1. Discover backup-eligible data directories
  local data_dirs
  _load_array data_dirs get_backup_data_dirs

  if [[ ${#data_dirs[@]} -eq 0 ]]; then
    log_warn "No eligible 'data' directories found. Nothing to backup."
    exit 0
  fi

  # 2. Map data directories to unique service YML files
  local target_ymls
  _load_array target_ymls get_unique_ymls "${data_dirs[@]}"

  # 3. Stop running containers on target stacks
  [[ ${#target_ymls[@]} -gt 0 ]] && stop_scoped_stacks "${target_ymls[@]}"

  # 4. Prepare targets relative to project root
  cd "${PROJECT_ROOT}" || exit 1
  local targets=()
  for dir in "${data_dirs[@]}"; do
    targets+=("${dir#${PROJECT_ROOT}/}")
  done
  [[ -f ".env" ]] && targets+=(".env")

  # 5. Embed Git tag metadata into backup payload
  local current_tag
  current_tag=$(get_current_git_tag)
  log_info "Pinning backup to Git tag: $current_tag"

  if [[ "$DRY_RUN" == false ]]; then
    echo "$current_tag" > "$TAG_FILENAME"
  else
    log_info "[DRY-RUN] Would write Git tag '$current_tag' to $TAG_FILENAME"
  fi
  targets+=("$TAG_FILENAME")

  # 6. Create compressed archive
  log_info "Creating backup archive at: ${dest_file}"
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] tar -czpvf ${dest_file} ${targets[*]}"
  else
    tar -czpvf "${dest_file}" "${targets[@]}" 2>&1 | tee -a "$LOG_FILE"
    rm -f "$TAG_FILENAME"
  fi

  # 7. Restart target stacks
  [[ ${#target_ymls[@]} -gt 0 ]] && start_scoped_stacks "${target_ymls[@]}"

  log_success "Backup completed successfully: ${dest_file}"
}

# ------------------------------------------------------------------------------
# 5. CORE LOGIC: RESTORE
# ------------------------------------------------------------------------------

wipe_current_state() {
  local dirs=("$@")
  log_info "Wiping ALL existing data directories to achieve a clean slate..."
  cd "${PROJECT_ROOT}" || exit 1

  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      log_info "Deleting folder: ${dir#${PROJECT_ROOT}/}"
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
  backup_tag=$(tar -xzf "$archive_file" -O "$TAG_FILENAME" 2>/dev/null || echo "missing_in_archive")
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

  echo -e "\n========================================" >> "$LOG_FILE"
  log_info "INITIATING RESTORE PROCESS"

  verify_git_tag "$archive_file"

  # 1. Discover ALL existing data directories to ensure complete shutdown & wipe
  local wipe_data_dirs wipe_ymls=()
  _load_array wipe_data_dirs get_all_data_dirs

  if [[ ${#wipe_data_dirs[@]} -gt 0 ]]; then
    _load_array wipe_ymls get_unique_ymls "${wipe_data_dirs[@]}"
  fi

  # 2. Stop running stacks on all existing data directories
  [[ ${#wipe_ymls[@]} -gt 0 ]] && stop_scoped_stacks "${wipe_ymls[@]}"

  # Flag active: Any failure past this point requires manual intervention
  DESTRUCTIVE_PHASE=true

  # 3. Wipe ALL existing data directories (achieving a pure clean slate)
  [[ ${#wipe_data_dirs[@]} -gt 0 ]] && wipe_current_state "${wipe_data_dirs[@]}"

  # 4. Extract archive
  log_info "Extracting backup from: ${archive_file}"
  cd "${PROJECT_ROOT}" || exit 1
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] tar -xzpvf ${archive_file}"
  else
    tar -xzpvf "${archive_file}" 2>&1 | tee -a "$LOG_FILE"

    restore_stashed_env
    execute_quiet rm -f "${PROJECT_ROOT}/.env.bak"
  fi

  # 5. Discover post-restore target stacks
  local post_data_dirs post_ymls=()
  _load_array post_data_dirs get_backup_data_dirs

  if [[ ${#post_data_dirs[@]} -gt 0 ]]; then
    _load_array post_ymls get_unique_ymls "${post_data_dirs[@]}"
  fi

  # Extraction successful. Destructive phase over.
  DESTRUCTIVE_PHASE=false

  # 6. Bring restored stacks back online
  [[ ${#post_ymls[@]} -gt 0 ]] && start_scoped_stacks "${post_ymls[@]}"

  log_success "Restore completed successfully."
}

# ------------------------------------------------------------------------------
# 6. ENTRYPOINT
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    backup|restore)
      if [[ -n "$COMMAND" ]]; then
        log_error "Multiple commands specified: '$COMMAND' and '$1'"
        show_usage
      fi
      COMMAND="$1"
      TARGET_PATH="${2:-}"

      if [[ -z "$TARGET_PATH" || "$TARGET_PATH" == --* ]]; then
        log_error "Target path is required for $COMMAND"
        show_usage
      fi

      # Resolve target path to an absolute path before working directory changes
      if [[ ! "$TARGET_PATH" = /* ]]; then
        TARGET_PATH="$(pwd)/$TARGET_PATH"
      fi

      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      show_usage
      ;;
  esac
done

[[ -z "$COMMAND" ]] && show_usage

check_root

if [[ "$DRY_RUN" == true ]]; then
  log_warn "RUNNING IN DRY-RUN MODE. NO CHANGES WILL BE MADE."
fi

case "$COMMAND" in
  backup)  do_backup "$TARGET_PATH" ;;
  restore) do_restore "$TARGET_PATH" ;;
esac