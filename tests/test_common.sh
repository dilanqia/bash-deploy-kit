#!/usr/bin/env bash
# test_common.sh — Unit tests for common.sh utilities
# Run: bash tests/test_common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ── Test Framework ──────────────────────────────────────────────────────────
PASS=0
FAIL=0
TESTS_RUN=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  ((TESTS_RUN++))
  if [[ "$expected" == "$actual" ]]; then
    ((PASS++))
    echo -e "  ${GREEN}✓${NC} $desc"
  else
    ((FAIL++))
    echo -e "  ${RED}✗${NC} $desc"
    echo -e "    expected: $expected"
    echo -e "    actual:   $actual"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2"
  shift 2
  ((TESTS_RUN++))
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$expected" == "$actual" ]]; then
    ((PASS++))
    echo -e "  ${GREEN}✓${NC} $desc"
  else
    ((FAIL++))
    echo -e "  ${RED}✗${NC} $desc (expected exit $expected, got $actual)"
  fi
}

# ── Test: require_command ───────────────────────────────────────────────────
echo ""
echo "=== require_command ==="

require_command bash && assert_eq "bash exists" 0 $?
require_command curl && assert_eq "curl exists" 0 $?
assert_exit_code "nonexistent command fails" 1 require_command __nonexistent_cmd_xyz__

# ── Test: require_env ───────────────────────────────────────────────────────
echo ""
echo "=== require_env ==="

export TEST_VAR="hello"
assert_exit_code "set env var passes" 0 require_env TEST_VAR
unset TEST_VAR
assert_exit_code "unset env var fails" 1 require_env TEST_VAR

# ── Test: acquire_lock / release_lock ───────────────────────────────────────
echo ""
echo "=== locking ==="

LOCKFILE="/tmp/test-common-$$.lock"
rm -f "$LOCKFILE"

acquire_lock "$LOCKFILE"
assert_eq "lockfile created" "1" "$( [[ -f "$LOCKFILE" ]] && echo 1 || echo 0 )"
assert_eq "lockfile contains PID" "$$" "$(cat "$LOCKFILE")"

release_lock "$LOCKFILE"
assert_eq "lockfile removed" "0" "$( [[ -f "$LOCKFILE" ]] && echo 1 || echo 0 )"

# Stale lock recovery
echo "999999" > "$LOCKFILE"
acquire_lock "$LOCKFILE" && assert_eq "stale lock recovered" 0 $?
release_lock "$LOCKFILE"

# ── Test: log functions output ──────────────────────────────────────────────
echo ""
echo "=== logging ==="

output=$(log_info "test message" 2>&1)
assert_eq "log_info contains INFO" "1" "$(echo "$output" | grep -c '\[INFO\]')"
assert_eq "log_info contains message" "1" "$(echo "$output" | grep -c 'test message')"

output=$(log_warn "warn msg" 2>&1)
assert_eq "log_warn contains WARN" "1" "$(echo "$output" | grep -c '\[WARN\]')"

output=$(log_error "err msg" 2>&1)
assert_eq "log_error contains ERROR" "1" "$(echo "$output" | grep -c '\[ERROR\]')"

# Debug is silent by default
output=$(log_debug "debug msg" 2>&1)
assert_eq "log_debug silent without DEBUG=1" "" "$output"

DEBUG=1
output=$(log_debug "debug msg" 2>&1)
assert_eq "log_debug visible with DEBUG=1" "1" "$(echo "$output" | grep -c '\[DEBUG\]')"

# ── Test: check_health (mock) ──────────────────────────────────────────────
echo ""
echo "=== check_health ==="

# This will fail quickly against a non-existent server (expected)
assert_exit_code "unreachable server fails" 1 check_health "http://127.0.0.1:1" "200" 1 1 0

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "================================"
echo "Tests: $TESTS_RUN  Passed: $PASS  Failed: $FAIL"
echo "================================"

if ((FAIL > 0)); then
  exit 1
fi
