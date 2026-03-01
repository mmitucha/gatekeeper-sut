#!/usr/bin/env bash
# test-exit-codes.sh — validates sut-runner.sh CLI error paths (no Docker required)
set -euo pipefail

RUNNER="$(cd "$(dirname "$0")/.." && pwd)/sut-runner.sh"
PASS=0
FAIL=0

assert_exit() {
  local description="$1"
  local expected="$2"
  shift 2
  local actual
  actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  PASS: $description (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description — expected exit $expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== sut-runner exit-code tests ==="

assert_exit "--help exits 0"              0 "$RUNNER" --help
assert_exit "no args exits 3"             3 "$RUNNER"
assert_exit "unknown flag exits 3"        3 "$RUNNER" --unknown-flag
assert_exit "missing --tests-dir value exits 3" 3 "$RUNNER" --tests-dir
assert_exit "non-existent dir exits 3"    3 "$RUNNER" --tests-dir /nonexistent/path/abc
assert_exit "empty dir exits 2"           2 "$RUNNER" --tests-dir "$(mktemp -d)"

echo "==================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==================================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
