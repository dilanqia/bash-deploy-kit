#!/usr/bin/env bash
# canary.sh — Canary deployment strategy
#
# Gradually shifts traffic from the stable version to the new version
# in configurable percentage increments. Rolls back if health checks fail.
#
# Usage:
#   source lib/common.sh
#   source lib/canary.sh
#   canary_deploy "myapp" "registry/myapp:v2" 10 25 50 100

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Configuration ───────────────────────────────────────────────────────────
CANARY_LOCK="/tmp/canary-deploy.lock"
CANARY_STABLE_LABEL="deploy.slot=stable"
CANARY_CANARY_LABEL="deploy.slot=canary"

# ── Core Functions ──────────────────────────────────────────────────────────

# get_stable_version <service>
get_stable_version() {
  local service="${1:?Service required}"
  docker ps \
    --filter "label=deploy.service=${service}" \
    --filter "label=${CANARY_STABLE_LABEL}" \
    --format '{{.Image}}' | head -1
}

# get_canary_version <service>
get_canary_version() {
  local service="${1:?Service required}"
  docker ps \
    --filter "label=deploy.service=${service}" \
    --filter "label=${CANARY_CANARY_LABEL}" \
    --format '{{.Image}}' | head -1
}

# deploy_stable <service> <image> [extra_docker_args...]
deploy_stable() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  shift 2
  local extra_args=("$@")
  local container_name="${service}-stable"

  log_info "Deploying stable: $image"

  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker rm -f "$container_name" 2>/dev/null || true
  fi

  docker run -d \
    --name "$container_name" \
    --label "deploy.service=${service}" \
    --label "${CANARY_STABLE_LABEL}" \
    --label "deploy.version=${image}" \
    -p "${STABLE_PORT:-8081}:${CONTAINER_PORT:-8080}" \
    "${extra_args[@]}" \
    "$image"
}

# deploy_canary <service> <image> [extra_docker_args...]
deploy_canary() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  shift 2
  local extra_args=("$@")
  local container_name="${service}-canary"

  log_info "Deploying canary: $image"

  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker rm -f "$container_name" 2>/dev/null || true
  fi

  docker run -d \
    --name "$container_name" \
    --label "deploy.service=${service}" \
    --label "${CANARY_CANARY_LABEL}" \
    --label "deploy.version=${image}" \
    -p "${CANARY_PORT:-8082}:${CONTAINER_PORT:-8080}" \
    "${extra_args[@]}" \
    "$image"
}

# set_canary_weight <service> <percentage>
# Adjusts traffic split. Override _set_proxy_weight for your proxy.
set_canary_weight() {
  local service="${1:?Service required}"
  local percentage="${2:?Percentage required}"

  log_info "Setting canary weight: ${service} → ${percentage}%"

  if type _set_proxy_weight &>/dev/null; then
    _set_proxy_weight "$service" "$percentage"
  else
    log_warn "No _set_proxy_weight defined. Weight change is a no-op."
    log_warn "Implement _set_proxy_weight(service, percentage) for your proxy."
  fi
}

# collect_canary_metrics <service> [duration_seconds]
# Returns 0 if canary is healthy, 1 if metrics indicate problems.
collect_canary_metrics() {
  local service="${1:?Service required}"
  local duration="${2:-60}"

  log_info "Collecting canary metrics for ${duration}s..."

  if type _check_canary_metrics &>/dev/null; then
    _check_canary_metrics "$service" "$duration"
  else
    # Default: just check container health via HTTP
    local port="${CANARY_PORT:-8082}"
    local url="${CANARY_HEALTH_URL:-http://localhost:${port}/health}"
    check_health "$url" "200" 5 3 10
  fi
}

# promote_canary <service>
# Makes the canary version the new stable.
promote_canary() {
  local service="${1:?Service required}"
  local canary_image stable_container canary_container

  canary_image=$(get_canary_version "$service")
  stable_container="${service}-stable"
  canary_container="${service}-canary"

  log_info "Promoting canary to stable: $canary_image"

  # Stop old stable
  if docker ps --format '{{.Names}}' | grep -q "^${stable_container}$"; then
    stop_container "$stable_container" 30
    docker rm "$stable_container" 2>/dev/null || true
  fi

  # Rename canary → stable
  if docker ps --format '{{.Names}}' | grep -q "^${canary_container}$"; then
    docker stop "$canary_container"
    docker rm "$canary_container" 2>/dev/null || true
  fi

  # Deploy fresh as stable
  deploy_stable "$service" "$canary_image"
}

# rollback_canary <service>
# Removes canary and keeps stable.
rollback_canary() {
  local service="${1:?Service required}"
  local canary_container="${service}-canary"

  log_warn "Rolling back canary for $service"

  set_canary_weight "$service" 0

  if docker ps -a --format '{{.Names}}' | grep -q "^${canary_container}$"; then
    docker rm -f "$canary_container" 2>/dev/null || true
  fi

  log_info "Canary removed. Traffic is 100% on stable."
}

# ── Main Orchestrator ──────────────────────────────────────────────────────

# canary_deploy <service> <image> [percentages...]
# Example: canary_deploy "myapp" "registry/myapp:v2" 10 25 50 100
canary_deploy() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  shift 2
  local percentages=("${@:-10 25 50 100}")

  # Default rollout steps if none provided
  if [[ ${#percentages[@]} -eq 0 ]]; then
    percentages=(10 25 50 100)
  fi

  acquire_lock "$CANARY_LOCK"
  trap 'release_lock "$CANARY_LOCK"' EXIT

  log_info "=== Canary Deploy: $service ==="
  log_info "Rollout steps: ${percentages[*]}%"

  # Step 1: Pull image
  pull_image "$image"

  # Step 2: Deploy canary alongside stable
  deploy_canary "$service" "$image"

  # Step 3: Gradual traffic shift
  for pct in "${percentages[@]}"; do
    log_info "--- Canary step: ${pct}% traffic ---"
    set_canary_weight "$service" "$pct"

    # Wait and collect metrics between steps
    if [[ "$pct" -lt 100 ]]; then
      sleep "${CANARY_STEP_WAIT:-30}"

      if ! collect_canary_metrics "$service"; then
        log_error "Canary metrics failed at ${pct}% — rolling back"
        rollback_canary "$service"
        return 1
      fi
    fi
  done

  # Step 4: Promote canary to stable
  promote_canary "$service"

  log_info "=== Canary deploy complete: $service ==="
}
