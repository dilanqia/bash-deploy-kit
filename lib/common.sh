#!/usr/bin/env bash
# common.sh — Shared utilities: logging, health checks, rollback helpers
# Source this file from other scripts: source "$(dirname "$0")/common.sh"

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── Logging ─────────────────────────────────────────────────────────────────
_log() {
  local level="$1" color="$2"
  shift 2
  echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [${level}]${NC} $*" >&2
}

log_info()  { _log "INFO"  "$GREEN"  "$@"; }
log_warn()  { _log "WARN"  "$YELLOW" "$@"; }
log_error() { _log "ERROR" "$RED"    "$@"; }
log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    _log "DEBUG" "$BLUE" "$@"
  fi
}

# ── Health Check ────────────────────────────────────────────────────────────
# check_health <url> [expected_status] [timeout_seconds] [retries]
# Returns 0 if healthy, 1 otherwise.
check_health() {
  local url="${1:?URL required}"
  local expected_status="${2:-200}"
  local timeout="${3:-5}"
  local retries="${4:-12}"
  local interval="${5:-5}"

  log_info "Health check: GET $url (expect $expected_status, timeout ${timeout}s, retries $retries)"

  for ((i = 1; i <= retries; i++)); do
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")

    if [[ "$status" == "$expected_status" ]]; then
      log_info "Health check passed on attempt $i (HTTP $status)"
      return 0
    fi

    log_warn "Attempt $i/$retries: got HTTP $status, expected $expected_status"
    if ((i < retries)); then
      sleep "$interval"
    fi
  done

  log_error "Health check failed after $retries attempts"
  return 1
}

# check_health_tcp <host> <port> [timeout_seconds] [retries]
check_health_tcp() {
  local host="${1:?Host required}"
  local port="${2:?Port required}"
  local timeout="${3:-5}"
  local retries="${4:-12}"
  local interval="${5:-5}"

  log_info "TCP health check: $host:$port (timeout ${timeout}s, retries $retries)"

  for ((i = 1; i <= retries; i++)); do
    if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
      log_info "TCP health check passed on attempt $i"
      return 0
    fi

    log_warn "Attempt $i/$retries: $host:$port unreachable"
    if ((i < retries)); then
      sleep "$interval"
    fi
  done

  log_error "TCP health check failed after $retries attempts"
  return 1
}

# ── Rollback ────────────────────────────────────────────────────────────────
# rollback_deployment <service> <previous_version>
# Generic rollback — override this function for platform-specific logic.
rollback_deployment() {
  local service="${1:?Service name required}"
  local previous_version="${2:?Previous version required}"

  log_warn "ROLLING BACK $service to version $previous_version"

  # Default: just a hook — override in your deployment script
  if type _do_rollback &>/dev/null; then
    _do_rollback "$service" "$previous_version"
  else
    log_warn "No _do_rollback function defined. Implement platform-specific rollback."
    return 1
  fi
}

# ── Locking ─────────────────────────────────────────────────────────────────
# acquire_lock <lockfile>
acquire_lock() {
  local lockfile="${1:?Lockfile path required}"
  if [[ -f "$lockfile" ]]; then
    local lock_pid
    lock_pid=$(cat "$lockfile" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      log_error "Deployment already in progress (PID $lock_pid)"
      return 1
    fi
    log_warn "Stale lockfile found, removing"
    rm -f "$lockfile"
  fi
  echo $$ > "$lockfile"
  log_debug "Acquired lock: $lockfile (PID $$)"
}

release_lock() {
  local lockfile="${1:?Lockfile path required}"
  rm -f "$lockfile"
  log_debug "Released lock: $lockfile"
}

# ── Docker Helpers ──────────────────────────────────────────────────────────
# pull_image <image:tag>
pull_image() {
  local image="${1:?Image required}"
  log_info "Pulling image: $image"
  docker pull "$image"
}

# get_running_containers <label> <value>
get_running_containers() {
  local label="${1:?Label required}"
  local value="${2:?Value required}"
  docker ps --filter "label=${label}=${value}" --format '{{.ID}}'
}

# stop_container <container_id> [timeout]
stop_container() {
  local container="${1:?Container ID required}"
  local timeout="${2:-30}"
  log_info "Stopping container $container (timeout ${timeout}s)"
  docker stop -t "$timeout" "$container" 2>/dev/null || true
}

# ── Validation ──────────────────────────────────────────────────────────────
require_command() {
  local cmd="${1:?Command name required}"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required command not found: $cmd"
    return 1
  fi
}

require_env() {
  local var="${1:?Variable name required}"
  if [[ -z "${!var:-}" ]]; then
    log_error "Required environment variable not set: $var"
    return 1
  fi
}
