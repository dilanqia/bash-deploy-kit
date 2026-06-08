#!/usr/bin/env bash
# blue-green.sh — Blue/Green deployment strategy
#
# Deploys to the inactive environment (blue ↔ green), validates health,
# then switches traffic. Rolls back automatically on failure.
#
# Usage:
#   source lib/common.sh
#   source lib/blue-green.sh
#   blue_green_deploy "myapp" "registry/myapp:v2" "http://localhost:8080/health"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Configuration ───────────────────────────────────────────────────────────
BLUE_GREEN_LOCK="/tmp/blue-green-deploy.lock"
BLUE_GREEN_LABEL="deploy.color"

# ── Core Functions ──────────────────────────────────────────────────────────

# get_active_color <service>
# Returns "blue" or "green" based on which is currently serving traffic.
get_active_color() {
  local service="${1:?Service required}"

  # Check which containers have the active label
  local blue_running green_running
  blue_running=$(docker ps --filter "label=${BLUE_GREEN_LABEL}=blue" \
    --filter "label=deploy.service=${service}" --format '{{.ID}}' | wc -l)
  green_running=$(docker ps --filter "label=${BLUE_GREEN_LABEL}=green" \
    --filter "label=deploy.service=${service}" --format '{{.ID}}' | wc -l)

  if ((blue_running > 0 && green_running == 0)); then
    echo "blue"
  elif ((green_running > 0 && blue_running == 0)); then
    echo "green"
  elif ((blue_running == 0 && green_running == 0)); then
    echo "none"
  else
    # Both running — check which one the proxy points to
    # Default to blue if ambiguous
    log_warn "Both blue and green running for $service, defaulting active=blue"
    echo "blue"
  fi
}

# get_inactive_color <service>
get_inactive_color() {
  local active
  active=$(get_active_color "$1")
  if [[ "$active" == "blue" ]]; then
    echo "green"
  else
    echo "blue"
  fi
}

# get_port_for_color <color>
# Maps color to a host port. Override these for your setup.
get_port_for_color() {
  local color="$1"
  case "$color" in
    blue)  echo "${BLUE_PORT:-8081}" ;;
    green) echo "${GREEN_PORT:-8082}" ;;
    *)     log_error "Unknown color: $color"; return 1 ;;
  esac
}

# deploy_to_color <service> <image> <color> [extra_docker_args...]
deploy_to_color() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  local color="${3:?Color required}"
  shift 3
  local extra_args=("$@")

  local port
  port=$(get_port_for_color "$color")
  local container_name="${service}-${color}"

  log_info "Deploying $image to $color environment (port $port)"

  # Stop existing container for this color
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    log_info "Removing existing $color container: $container_name"
    docker rm -f "$container_name" 2>/dev/null || true
  fi

  # Start new container
  docker run -d \
    --name "$container_name" \
    --label "${BLUE_GREEN_LABEL}=${color}" \
    --label "deploy.service=${service}" \
    --label "deploy.version=${image}" \
    -p "${port}:${CONTAINER_PORT:-8080}" \
    "${extra_args[@]}" \
    "$image"

  log_info "Container $container_name started on port $port"
}

# switch_traffic <service> <new_color>
# Override this for your specific proxy/load balancer (nginx, traefik, etc.)
switch_traffic() {
  local service="${1:?Service required}"
  local new_color="${2:?New color required}"
  local port
  port=$(get_port_for_color "$new_color")

  log_info "Switching traffic for $service → $new_color (port $port)"

  # Default implementation: update a symlink or config file
  # Override _switch_traffic_proxy for your setup
  if type _switch_traffic_proxy &>/dev/null; then
    _switch_traffic_proxy "$service" "$new_color" "$port"
  else
    log_warn "No _switch_traffic_proxy defined. Traffic switch is a no-op."
    log_warn "Implement _switch_traffic_proxy(service, color, port) for your proxy."
  fi
}

# stop_old_color <service> <old_color>
stop_old_color() {
  local service="${1:?Service required}"
  local old_color="${2:?Old color required}"
  local container_name="${service}-${old_color}"

  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    log_info "Stopping old $old_color container: $container_name"
    stop_container "$container_name" 30
    docker rm "$container_name" 2>/dev/null || true
  fi
}

# ── Main Orchestrator ──────────────────────────────────────────────────────

# blue_green_deploy <service> <image> [health_url] [extra_docker_args...]
blue_green_deploy() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  local health_url="${3:-}"
  shift 2
  [[ -n "${3:-}" ]] && shift 1  # shift health_url if provided
  local extra_args=("$@")

  acquire_lock "$BLUE_GREEN_LOCK"
  trap 'release_lock "$BLUE_GREEN_LOCK"' EXIT

  local active_color inactive_color
  active_color=$(get_active_color "$service")
  inactive_color=$(get_inactive_color "$service")

  if [[ "$active_color" == "none" ]]; then
    inactive_color="blue"
    log_info "No active deployment found — starting with blue"
  fi

  log_info "=== Blue/Green Deploy: $service ==="
  log_info "Active: $active_color → Deploying to: $inactive_color"

  # Step 1: Pull image
  pull_image "$image"

  # Step 2: Deploy to inactive color
  deploy_to_color "$service" "$image" "$inactive_color" "${extra_args[@]}"

  # Step 3: Health check
  if [[ -n "$health_url" ]]; then
    local port
    port=$(get_port_for_color "$inactive_color")
    # Replace port in health URL if it contains a port
    local check_url
    check_url=$(echo "$health_url" | sed "s|:[0-9]*|:${port}|")

    if ! check_health "$check_url"; then
      log_error "Health check failed on $inactive_color — rolling back"
      docker rm -f "${service}-${inactive_color}" 2>/dev/null || true
      return 1
    fi
  fi

  # Step 4: Switch traffic
  switch_traffic "$service" "$inactive_color"

  # Step 5: Stop old environment
  if [[ "$active_color" != "none" ]]; then
    stop_old_color "$service" "$active_color"
  fi

  log_info "=== Deploy complete: $service is now on $inactive_color ==="
}
