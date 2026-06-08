#!/usr/bin/env bash
# rolling.sh — Rolling update deployment strategy
#
# Replaces instances one at a time (or in batches), verifying health
# after each batch before proceeding.
#
# Usage:
#   source lib/common.sh
#   source lib/rolling.sh
#   rolling_deploy "myapp" "registry/myapp:v2" 3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Configuration ───────────────────────────────────────────────────────────
ROLLING_LOCK="/tmp/rolling-deploy.lock"

# ── Core Functions ──────────────────────────────────────────────────────────

# get_instances <service>
# Returns space-separated container IDs for the service.
get_instances() {
  local service="${1:?Service required}"
  docker ps \
    --filter "label=deploy.service=${service}" \
    --format '{{.ID}}'
}

# get_instance_count <service>
get_instance_count() {
  local service="${1:?Service required}"
  get_instances "$service" | wc -w
}

# deploy_instance <service> <image> <instance_number> [total] [extra_docker_args...]
deploy_instance() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  local instance_num="${3:?Instance number required}"
  local total="${4:-1}"
  shift 4
  local extra_args=("$@")

  local container_name="${service}-${instance_num}"
  local port_offset=$((instance_num - 1))
  local host_port=$(( ${BASE_PORT:-8080} + port_offset ))

  log_info "Deploying instance $instance_num/$total: $container_name ($image)"

  # Stop existing instance
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    log_info "Stopping existing instance: $container_name"
    stop_container "$container_name" 30
    docker rm "$container_name" 2>/dev/null || true
  fi

  docker run -d \
    --name "$container_name" \
    --label "deploy.service=${service}" \
    --label "deploy.instance=${instance_num}" \
    --label "deploy.version=${image}" \
    -p "${host_port}:${CONTAINER_PORT:-8080}" \
    "${extra_args[@]}" \
    "$image"

  log_info "Instance $container_name started on port $host_port"
}

# health_check_instance <service> <instance_number>
health_check_instance() {
  local service="${1:?Service required}"
  local instance_num="${2:?Instance number required}"
  local port_offset=$((instance_num - 1))
  local host_port=$(( ${BASE_PORT:-8080} + port_offset ))
  local url="${HEALTH_URL:-http://localhost:${host_port}/health}"

  check_health "$url" "200" 5 "${HEALTH_RETRIES:-6}" "${HEALTH_INTERVAL:-10}"
}

# remove_instance <service> <instance_number>
remove_instance() {
  local service="${1:?Service required}"
  local instance_num="${2:?Instance number required}"
  local container_name="${service}-${instance_num}"

  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker rm -f "$container_name" 2>/dev/null || true
    log_info "Removed instance: $container_name"
  fi
}

# ── Main Orchestrator ──────────────────────────────────────────────────────

# rolling_deploy <service> <image> [count] [batch_size] [extra_docker_args...]
# - service:      Service name
# - image:        Docker image to deploy
# - count:        Number of instances (default: current count or 1)
# - batch_size:   How many to update at once (default: 1)
rolling_deploy() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  local count="${3:-}"
  local batch_size="${4:-1}"
  shift 2
  [[ -n "${3:-}" ]] && shift 1
  [[ -n "${4:-}" ]] && shift 1
  local extra_args=("$@")

  acquire_lock "$ROLLING_LOCK"
  trap 'release_lock "$ROLLING_LOCK"' EXIT

  # Auto-detect instance count if not specified
  if [[ -z "$count" ]]; then
    count=$(get_instance_count "$service")
    if [[ "$count" -eq 0 ]]; then
      count=1
      log_info "No existing instances found — deploying 1"
    else
      log_info "Auto-detected $count existing instances"
    fi
  fi

  log_info "=== Rolling Deploy: $service ==="
  log_info "Instances: $count, Batch size: $batch_size, Image: $image"

  # Pull once
  pull_image "$image"

  # Roll through in batches
  local updated=0
  local failed=0

  while ((updated < count)); do
    local batch_end=$((updated + batch_size))
    if ((batch_end > count)); then
      batch_end=$count
    fi

    log_info "--- Batch: instances $((updated + 1)) to $batch_end ---"

    # Deploy batch
    for ((i = updated + 1; i <= batch_end; i++)); do
      deploy_instance "$service" "$image" "$i" "$count" "${extra_args[@]}"
    done

    # Health check batch
    local batch_ok=true
    for ((i = updated + 1; i <= batch_end; i++)); do
      if ! health_check_instance "$service" "$i"; then
        log_error "Health check failed for instance $i"
        batch_ok=false
        break
      fi
    done

    if [[ "$batch_ok" == "false" ]]; then
      log_error "Batch failed — stopping rolling deploy"
      log_error "Instances 1-$updated are on the new version, $batch_end-$count are on the old version"
      log_warn "Manual intervention may be required"
      return 1
    fi

    updated=$batch_end
    log_info "Batch complete ($updated/$count instances updated)"

    # Brief pause between batches
    if ((updated < count)); then
      sleep "${BATCH_PAUSE:-5}"
    fi
  done

  log_info "=== Rolling deploy complete: all $count instances updated ==="
}

# ── Utility: Scale ─────────────────────────────────────────────────────────

# scale_service <service> <image> <target_count>
# Scale up or down to exactly target_count instances.
scale_service() {
  local service="${1:?Service required}"
  local image="${2:?Image required}"
  local target="${3:?Target count required}"

  local current
  current=$(get_instance_count "$service")

  log_info "Scaling $service: $current → $target instances"

  if ((target > current)); then
    # Scale up
    for ((i = current + 1; i <= target; i++)); do
      deploy_instance "$service" "$image" "$i" "$target"
      health_check_instance "$service" "$i" || {
        log_error "New instance $i failed health check"
        return 1
      }
    done
    log_info "Scaled up to $target instances"
  elif ((target < current)); then
    # Scale down (remove highest-numbered instances first)
    for ((i = current; i > target; i--)); do
      remove_instance "$service" "$i"
    done
    log_info "Scaled down to $target instances"
  else
    log_info "Already at $target instances — nothing to do"
  fi
}
