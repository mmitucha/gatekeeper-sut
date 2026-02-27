# sut-runner.sh POC Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a working `sut-runner.sh` that discovers Docker Compose test files, runs them with isolated networks, and exits non-zero on failure — tested against the springboot-poc repo.

**Architecture:** Single bash script with sequential flow: parse CLI args, validate prerequisites (docker + compose), discover `*.test.{yaml,yml}` files, run each in a subshell with its own Docker network and cleanup trap, report results. Network isolation achieved via compose override file injected with `-f`.

**Tech Stack:** Bash, Docker, Docker Compose

---

### Task 1: Create sut-runner.sh scaffold with CLI parsing and prerequisite checks

**Files:**
- Create: `sut-runner.sh`

**Step 1: Write the script with header, usage, arg parsing, and prerequisite validation**

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Constants ---
readonly EXIT_SUCCESS=0
readonly EXIT_TEST_FAILED=1
readonly EXIT_NO_TESTS=2
readonly EXIT_MISSING_PREREQS=3

# --- Logging ---
log()  { echo "[sut-runner] $*"; }
err()  { echo "[sut-runner] ERROR: $*" >&2; }
die()  { err "$@"; exit "${2:-1}"; }

# --- Usage ---
usage() {
  cat <<EOF
Usage: $(basename "$0") --tests-dir <path>

Discovers and runs Docker Compose SUT tests.

Options:
  --tests-dir <path>  Directory containing *.test.yaml / *.test.yml files (required)
  -h, --help          Show this help message

Exit codes:
  0  All tests passed
  1  One or more tests failed
  2  No test files found in --tests-dir
  3  Missing prerequisites (docker / docker compose)
EOF
}

# --- Parse args ---
TESTS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tests-dir)
      TESTS_DIR="${2:?--tests-dir requires a path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use --help for usage." "$EXIT_MISSING_PREREQS"
      ;;
  esac
done

if [[ -z "$TESTS_DIR" ]]; then
  usage >&2
  die "--tests-dir is required." "$EXIT_MISSING_PREREQS"
fi

if [[ ! -d "$TESTS_DIR" ]]; then
  die "--tests-dir '$TESTS_DIR' is not a directory." "$EXIT_MISSING_PREREQS"
fi

# --- Detect prerequisites ---
check_docker() {
  if ! command -v docker &>/dev/null; then
    die "docker is not installed or not in PATH." "$EXIT_MISSING_PREREQS"
  fi
  if ! docker info &>/dev/null; then
    die "Docker daemon is not running." "$EXIT_MISSING_PREREQS"
  fi
}

detect_compose_cmd() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null && docker-compose --version &>/dev/null; then
    echo "docker-compose"
  else
    die "Neither 'docker compose' (v2) nor 'docker-compose' (v1) found." "$EXIT_MISSING_PREREQS"
  fi
}

check_docker
COMPOSE_CMD=$(detect_compose_cmd)
log "Using compose command: $COMPOSE_CMD"
```

**Step 2: Make it executable and verify arg parsing works**

Run: `chmod +x sut-runner.sh && ./sut-runner.sh --help`
Expected: Usage text printed, exit 0

Run: `./sut-runner.sh`
Expected: Error about --tests-dir required, exit 3

Run: `./sut-runner.sh --tests-dir /nonexistent`
Expected: Error about not a directory, exit 3

**Step 3: Commit**

```
git add sut-runner.sh
git commit -m "feat: add sut-runner.sh scaffold with CLI parsing and prereq checks"
```

---

### Task 2: Add test file discovery

**Files:**
- Modify: `sut-runner.sh` (append after prereq checks)

**Step 1: Add discovery logic after the compose detection block**

```bash
# --- Discover test files ---
discover_tests() {
  local dir="$1"
  local tests=()

  # Glob both extensions
  for f in "$dir"/*.test.yaml "$dir"/*.test.yml; do
    [[ -f "$f" ]] && tests+=("$f")
  done

  if [[ ${#tests[@]} -eq 0 ]]; then
    err "No *.test.yaml or *.test.yml files found in '$dir'."
    exit "$EXIT_NO_TESTS"
  fi

  printf '%s\n' "${tests[@]}"
}

mapfile -t TEST_FILES < <(discover_tests "$TESTS_DIR")
log "Found ${#TEST_FILES[@]} test file(s):"
for f in "${TEST_FILES[@]}"; do
  log "  - $(basename "$f")"
done
```

**Step 2: Verify discovery works**

Run: `./sut-runner.sh --tests-dir ./examples/hooks/pre_push` (assuming no files there yet)
Expected: Exit 2 with "No *.test.yaml or *.test.yml files found"

Run: Create a dummy file `mkdir -p /tmp/test-discovery && touch /tmp/test-discovery/smoke.test.yaml && ./sut-runner.sh --tests-dir /tmp/test-discovery`
Expected: "Found 1 test file(s)" then proceed (will fail later since it's empty, that's fine)

**Step 3: Commit**

```
git add sut-runner.sh
git commit -m "feat: add test file discovery for *.test.yaml and *.test.yml"
```

---

### Task 3: Add per-test execution with network isolation and cleanup

**Files:**
- Modify: `sut-runner.sh` (append after discovery)

**Step 1: Add the run_test function and main execution loop**

```bash
# --- Run a single test ---
run_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "$test_file" | sed 's/\.\(test\.ya\?ml\)$//')"
  local suffix="${test_name}_$$_$(date +%s)"
  local network_name="sut_net_${suffix}"
  local project_name="sut_${suffix}"
  local test_dir
  test_dir="$(cd "$(dirname "$test_file")" && pwd)"
  local test_filename
  test_filename="$(basename "$test_file")"
  local override_file
  override_file="$(mktemp "${TMPDIR:-/tmp}/sut-override-XXXXXX.yml")"

  # Generate network override
  cat > "$override_file" <<YAML
networks:
  default:
    name: ${network_name}
    external: true
YAML

  log "--- Running test: $test_name ---"

  # Cleanup function — always runs
  cleanup() {
    log "Cleaning up test: $test_name"
    # Compose down (suppress errors — best effort)
    $COMPOSE_CMD -p "$project_name" \
      -f "$test_dir/$test_filename" \
      -f "$override_file" \
      down -v --remove-orphans 2>/dev/null || true
    # Remove network
    docker network rm "$network_name" 2>/dev/null || true
    # Remove temp override
    rm -f "$override_file"
  }

  # Run in subshell so trap is scoped
  (
    trap cleanup EXIT

    # Create the external network
    if ! docker network create "$network_name" &>/dev/null; then
      err "Failed to create network '$network_name'"
      exit 1
    fi

    # Run compose
    $COMPOSE_CMD -p "$project_name" \
      -f "$test_dir/$test_filename" \
      -f "$override_file" \
      up --build --abort-on-container-exit --exit-code-from sut
  )
}

# --- Main execution loop ---
FAILED=0
PASSED=0

for test_file in "${TEST_FILES[@]}"; do
  if run_test "$test_file"; then
    ((PASSED++))
    log "PASSED: $(basename "$test_file")"
  else
    ((FAILED++))
    log "FAILED: $(basename "$test_file")"
  fi
done

# --- Summary ---
log "========================="
log "Results: $PASSED passed, $FAILED failed (${#TEST_FILES[@]} total)"
log "========================="

if [[ $FAILED -gt 0 ]]; then
  exit "$EXIT_TEST_FAILED"
fi

exit "$EXIT_SUCCESS"
```

**Step 2: Commit**

```
git add sut-runner.sh
git commit -m "feat: add per-test execution with network isolation and cleanup"
```

---

### Task 4: Create example test fixtures

**Files:**
- Create: `examples/hooks/pre_push/smoke.test.yaml`
- Create: `examples/hooks/pre_push/smoke_test.sh`

**Step 1: Create a minimal self-contained smoke test**

`examples/hooks/pre_push/smoke.test.yaml`:
```yaml
services:
  sut:
    image: alpine:3.19
    command: ["sh", "-c", "echo 'Smoke test passed' && exit 0"]
```

`examples/hooks/pre_push/smoke_test.sh`:
```bash
#!/bin/bash
# Placeholder — the smoke.test.yaml runs inline for simplicity
echo "This script is an example for tests that need a separate script."
exit 0
```

**Step 2: Run the example**

Run: `./sut-runner.sh --tests-dir ./examples/hooks/pre_push`
Expected: Network created, alpine container runs, prints "Smoke test passed", cleanup runs, exit 0.

**Step 3: Commit**

```
git add examples/
git commit -m "feat: add example smoke test fixtures"
```

---

### Task 5: End-to-end test against springboot-poc

**Prerequisites:** The springboot-poc repo needs adjustment — its `docker-compose.test.yml` must:
1. Rename `test-runner` service to `sut` (the test executor)
2. Rename current `sut` to `app` (the system under test)
3. Remove the custom `test-network` network declaration (use implicit `default`)
4. Rename file from `docker-compose.test.yml` to something matching `*.test.yaml` or `*.test.yml`

**Step 1: Clone springboot-poc and verify structure**

Run: `git clone https://github.com/mmitucha/springboot-poc.git /tmp/springboot-poc-e2e`
Expected: Repo cloned, `hooks/pre_push/` directory exists with test files.

**Step 2: Adapt springboot-poc test file for SUT convention (manual or scripted)**

The key changes in `hooks/pre_push/docker-compose.test.yml` → `hooks/pre_push/api.test.yml`:
- Service `sut` renamed to `app`
- Service `test-runner` renamed to `sut`
- `depends_on.sut` changed to `depends_on.app`
- `API_BASE_URL=http://sut:8080` changed to `API_BASE_URL=http://app:8080` (etc.)
- Remove `networks:` section entirely (both top-level and per-service)

**Step 3: Run sut-runner against adapted springboot-poc**

Run: `./sut-runner.sh --tests-dir /tmp/springboot-poc-e2e/hooks/pre_push`
Expected: Builds Spring Boot app, runs API tests, all pass, cleanup, exit 0.

**Step 4: Verify failure case — break a test and confirm exit 1**

Edit the test script to force a failure, re-run, confirm exit 1.

---

### Task 6: Update CLAUDE.md status

**Files:**
- Modify: `.CLAUDE.md` — update Current Status checkboxes

**Step 1: Mark completed items**

- [x] sut-runner.sh — core runner implemented
- [x] Network override injection — implemented
- [x] Examples — smoke.test.yaml + smoke_test.sh

**Step 2: Commit**

```
git add .CLAUDE.md
git commit -m "docs: update CLAUDE.md status after POC implementation"
```
