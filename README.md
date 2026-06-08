# bash-deploy-kit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)

Pure Bash deployment strategies — blue/green, canary, and rolling updates. No dependencies beyond Docker and curl. Designed to be sourced into your own deploy scripts or used as a CI/CD toolkit.

## Strategies

| Strategy | File | Description |
|----------|------|-------------|
| **Blue/Green** | `lib/blue-green.sh` | Deploys to the inactive environment, validates health, then switches traffic instantly |
| **Canary** | `lib/canary.sh` | Gradually shifts traffic (e.g., 10% → 25% → 50% → 100%) with health checks between steps |
| **Rolling** | `lib/rolling.sh` | Replaces instances in configurable batch sizes with health verification |
| **Common** | `lib/common.sh` | Shared utilities: logging, health checks, locking, rollback helpers |

## Quick Start

```bash
# Clone or copy lib/ into your project
git clone https://github.com/dilanqia/bash-deploy-kit.git

# Source the strategy you need
source bash-deploy-kit/lib/common.sh
source bash-deploy-kit/lib/blue-green.sh

# Deploy
blue_green_deploy "myapp" "registry/myapp:v2" "http://localhost:8080/health"
```

## Blue/Green

Deploy to the inactive slot (blue ↔ green), health-check, then switch traffic:

```bash
source lib/common.sh
source lib/blue-green.sh

blue_green_deploy "myapp" "registry/myapp:v2" "http://localhost:8080/health"
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BLUE_PORT` | `8081` | Host port for blue environment |
| `GREEN_PORT` | `8082` | Host port for green environment |
| `CONTAINER_PORT` | `8080` | Container internal port |
| `DEBUG` | `0` | Set to `1` for debug logging |

### Custom proxy integration

Override `_switch_traffic_proxy` to integrate with your load balancer:

```bash
_switch_traffic_proxy() {
  local service="$1" color="$2" port="$3"
  # Update nginx, traefik, etc.
  sed -i "s|proxy_pass .*;|proxy_pass http://127.0.0.1:${port};|" /etc/nginx/conf.d/${service}.conf
  nginx -s reload
}
```

## Canary

Gradual traffic shifting with automatic rollback on failure:

```bash
source lib/common.sh
source lib/canary.sh

# Roll out in steps: 10% → 25% → 50% → 100%
canary_deploy "myapp" "registry/myapp:v2" 10 25 50 100
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STABLE_PORT` | `8081` | Host port for stable version |
| `CANARY_PORT` | `8082` | Host port for canary version |
| `CANARY_STEP_WAIT` | `30` | Seconds to wait between percentage steps |
| `CANARY_HEALTH_URL` | `http://localhost:8082/health` | Health check URL for canary |

### Custom proxy integration

Override `_set_proxy_weight` to control traffic splitting:

```bash
_set_proxy_weight() {
  local service="$1" percentage="$2"
  # Update weighted upstream in nginx, envoy, etc.
}
```

## Rolling

Batch-by-batch instance replacement:

```bash
source lib/common.sh
source lib/rolling.sh

# Update 3 instances, 1 at a time
rolling_deploy "myapp" "registry/myapp:v2" 3 1

# Update 6 instances, 2 at a time
rolling_deploy "myapp" "registry/myapp:v2" 6 2

# Scale to exactly 5 instances
scale_service "myapp" "registry/myapp:v2" 5
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_PORT` | `8080` | Starting host port (instances get 8080, 8081, ...) |
| `CONTAINER_PORT` | `8080` | Container internal port |
| `HEALTH_RETRIES` | `6` | Health check retry count |
| `HEALTH_INTERVAL` | `10` | Seconds between health retries |
| `BATCH_PAUSE` | `5` | Seconds between batches |

## Common Utilities

All strategies use `lib/common.sh` which provides:

- **Logging:** `log_info`, `log_warn`, `log_error`, `log_debug` (colored, timestamped)
- **Health checks:** `check_health <url> [status] [timeout] [retries]`, `check_health_tcp <host> <port>`
- **Locking:** `acquire_lock <file>`, `release_lock <file>` (prevents concurrent deploys)
- **Docker helpers:** `pull_image`, `get_running_containers`, `stop_container`
- **Validation:** `require_command <cmd>`, `require_env <VAR>`
- **Rollback:** `rollback_deployment <service> <version>` (override `_do_rollback` for custom logic)

## Testing

```bash
bash tests/test_common.sh
```

## License

[MIT](LICENSE) © 2026 [dilanqia](https://github.com/dilanqia)
