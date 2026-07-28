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

# ------------------------------------------------------------------------------
# 2. HELPER FUNCTIONS (Clean Code / DRY)
# ------------------------------------------------------------------------------

_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    if [ "$level" = "ERROR" ]; then
        echo -e "${color}[${level}]\e[0m ${message}" >&2
    else
        echo -e "${color}[${level}]\e[0m ${message}"
    fi

    if [ "$EUID" -eq 0 ]; then
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi
}

log_info()    { _log "INFO"    "\e[34m" "$1"; }
log_success() { _log "SUCCESS" "\e[32m" "$1"; }
log_error()   { _log "ERROR"   "\e[31m" "$1"; }
log_warn()    { _log "WARN"    "\e[33m" "$1"; }

execute() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: $*"
    else
        "$@" 2>&1 | tee -a "$LOG_FILE"
    fi
}

execute_quiet() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: $*"
    else
        "$@"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root to preserve file permissions."
        log_error "Please run with: sudo $0 $*"
        exit 1
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
  sudo $0 --dry-run restore /mnt/backups/home-ops-backup_2023-10-25_14-00-00.tar.gz
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# 3. DISCOVERY & MAPPING LOGIC
# ------------------------------------------------------------------------------

get_data_dirs() {
    find "${PROJECT_ROOT}" -type d -name "data" \
        -not -path "*/\.git/*" \
        -not -path "*/core/routing/traefik/*"
}

get_yml_for_data_dir() {
    local data_path="$1"
    local parent_dir
    parent_dir="$(dirname "$data_path")"

    local app_name
    app_name="$(basename "$parent_dir")"

    local expected_yml="${parent_dir}/${app_name}.yml"

    if [[ -f "$expected_yml" ]]; then
        echo "$expected_yml"
    fi
}

get_unique_ymls() {
    local dirs=("$@")
    local ymls=()

    for dir in "${dirs[@]}"; do
        local yml
        yml=$(get_yml_for_data_dir "$dir")
        if [[ -n "$yml" ]]; then
            ymls+=("$yml")
        fi
    done

    if [[ ${#ymls[@]} -gt 0 ]]; then
        printf "%s\n" "${ymls[@]}" | sort -u
    fi
}

# Scoped start/stop handlers mapping YMLs to Compose commands
# Note: Explicitly sets project directory and env file to maintain root context
stop_scoped_stacks() {
    local ymls=("$@")
    local env_arg=()

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        env_arg=("--env-file" "${PROJECT_ROOT}/.env")
    fi

    for yml in "${ymls[@]}"; do
        log_info "Stopping associated stack: ${yml#${PROJECT_ROOT}/}"
        # ${env_arg[@]:-} safely expands to nothing if the array is empty under 'set -u'
        execute docker compose --project-directory "${PROJECT_ROOT}" "${env_arg[@]:-}" -f "$yml" stop
    done
}

start_scoped_stacks() {
    local ymls=("$@")
    local env_arg=()

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        env_arg=("--env-file" "${PROJECT_ROOT}/.env")
    fi

    for yml in "${ymls[@]}"; do
        log_info "Starting associated stack: ${yml#${PROJECT_ROOT}/}"
        execute docker compose --project-directory "${PROJECT_ROOT}" "${env_arg[@]:-}" -f "$yml" up -d
    done
}

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

    local data_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && data_dirs+=("$dir")
    done < <(get_data_dirs)

    if [[ ${#data_dirs[@]} -eq 0 ]]; then
        log_warn "No 'data' directories found. Nothing to backup."
        exit 0
    fi

    local target_ymls=()
    local ymls_raw
    ymls_raw=$(get_unique_ymls "${data_dirs[@]}")
    [[ -n "$ymls_raw" ]] && readarray -t target_ymls <<< "$ymls_raw"

    if [[ ${#target_ymls[@]} -gt 0 ]]; then
        stop_scoped_stacks "${target_ymls[@]}"
    fi

    cd "${PROJECT_ROOT}"
    local targets=()
    for dir in "${data_dirs[@]}"; do
        targets+=("${dir#${PROJECT_ROOT}/}")
    done
    [[ -f ".env" ]] && targets+=(".env")

    local current_tag
    current_tag=$(get_current_git_tag)
    log_info "Pinning backup to Git tag: $current_tag"
    if [[ "$DRY_RUN" == false ]]; then
        echo "$current_tag" > "$TAG_FILENAME"
    fi
    targets+=("$TAG_FILENAME")

    log_info "Creating backup archive at: ${dest_file}"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] tar -czpvf ${dest_file} ${targets[*]}"
    else
        tar -czpvf "${dest_file}" "${targets[@]}" 2>&1 | tee -a "$LOG_FILE"
        rm -f "$TAG_FILENAME"
    fi

    if [[ ${#target_ymls[@]} -gt 0 ]]; then
        start_scoped_stacks "${target_ymls[@]}"
    fi

    log_success "Backup completed successfully: ${dest_file}"
}

# ------------------------------------------------------------------------------
# 5. CORE LOGIC: RESTORE
# ------------------------------------------------------------------------------
wipe_current_state() {
    local dirs=("$@")
    log_info "Wiping existing data directories to ensure a clean slate..."
    cd "${PROJECT_ROOT}"

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Deleting folder: ${dir#${PROJECT_ROOT}/}"
            execute_quiet rm -rf "$dir"
        fi
    done

    if [[ -f ".env" ]]; then
        log_info "Deleting file: .env"
        execute_quiet rm -f ".env"
    fi

    log_success "Clean slate achieved."
}

verify_git_tag() {
    local archive_file="$1"
    local current_tag
    current_tag=$(get_current_git_tag)
    local backup_tag="unknown"

    # Always read the archive, even in dry-run, as it's non-destructive
    if tar -tf "$archive_file" | grep -q "^${TAG_FILENAME}$"; then
        backup_tag=$(tar -xzf "$archive_file" -O "$TAG_FILENAME" 2>/dev/null || echo "unknown")
    else
        backup_tag="missing_in_archive"
    fi

    if [[ "$backup_tag" != "$current_tag" ]]; then
        log_warn "Git tag mismatch! Backup tag: \e[1m$backup_tag\e[0m \e[33m| Current tag:\e[0m \e[1m$current_tag\e[0m"

        if [[ "$DRY_RUN" == false ]]; then
            read -p "Are you absolutely sure you want to proceed with the restore? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Restore aborted by user."
                exit 0
            fi
        else
            log_info "[DRY-RUN] Would pause for user confirmation here."
        fi
    fi
}

do_restore() {
    local archive_file="$1"

    if [[ ! -f "$archive_file" ]]; then
        log_error "Archive file '$archive_file' does not exist."
        exit 1
    fi

    if [[ "$DRY_RUN" == false ]]; then
        echo -e "\e[31m[CRITICAL WARNING]\e[0m This will COMPLETELY DELETE all current data directories and replace them with the backup."
        read -p "Are you absolutely sure you want to proceed? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "\e[34m[INFO]\e[0m Restore aborted by user."
            exit 0
        fi
    fi

    echo -e "\n========================================" >> "$LOG_FILE"
    log_info "INITIATING RESTORE PROCESS"

    verify_git_tag "$archive_file"

    local pre_data_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && pre_data_dirs+=("$dir")
    done < <(get_data_dirs)

    local pre_ymls=()
    local pre_ymls_raw
    if [[ ${#pre_data_dirs[@]} -gt 0 ]]; then
        pre_ymls_raw=$(get_unique_ymls "${pre_data_dirs[@]}")
        [[ -n "$pre_ymls_raw" ]] && readarray -t pre_ymls <<< "$pre_ymls_raw"
    fi

    if [[ ${#pre_ymls[@]} -gt 0 ]]; then
        stop_scoped_stacks "${pre_ymls[@]}"
    fi

    if [[ ${#pre_data_dirs[@]} -gt 0 ]]; then
        wipe_current_state "${pre_data_dirs[@]}"
    fi

    log_info "Extracting backup from: ${archive_file}"
    cd "${PROJECT_ROOT}"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] tar -xzpvf ${archive_file}"
    else
        tar -xzpvf "${archive_file}" 2>&1 | tee -a "$LOG_FILE"
    fi

    local post_data_dirs=()
    local post_ymls=()
    local post_ymls_raw

    # In dry-run, fallback to pre-dirs since tar didn't actually extract new folders
    if [[ "$DRY_RUN" == true ]]; then
        post_ymls=("${pre_ymls[@]:-}")
    else
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && post_data_dirs+=("$dir")
        done < <(get_data_dirs)

        if [[ ${#post_data_dirs[@]} -gt 0 ]]; then
            post_ymls_raw=$(get_unique_ymls "${post_data_dirs[@]}")
            [[ -n "$post_ymls_raw" ]] && readarray -t post_ymls <<< "$post_ymls_raw"
        fi
    fi

    if [[ ${#post_ymls[@]} -gt 0 ]]; then
        start_scoped_stacks "${post_ymls[@]}"
    fi

    log_success "Restore completed successfully."
}

# ------------------------------------------------------------------------------
# 6. ENTRYPOINT (Argument Parsing & Execution)
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        backup|restore)
            COMMAND="$1"
            TARGET_PATH="${2:-}"

            if [[ -z "$TARGET_PATH" ]]; then
                log_error "Target path is required for $COMMAND"
                show_usage
            fi

            # Ensure TARGET_PATH is absolute to survive 'cd' operations later
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

if [[ -z "$COMMAND" ]]; then
    show_usage
fi

check_root

if [[ "$DRY_RUN" == true ]]; then
    log_warn "RUNNING IN DRY-RUN MODE. NO CHANGES WILL BE MADE."
fi

case "$COMMAND" in
    backup)
        do_backup "$TARGET_PATH"
        ;;
    restore)
        do_restore "$TARGET_PATH"
        ;;
esac