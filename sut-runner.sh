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
die()  { local msg="$1"; local code="${2:-1}"; err "$msg"; exit "$code"; }

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
      [[ $# -ge 2 ]] || die "--tests-dir requires a path" "$EXIT_MISSING_PREREQS"
      TESTS_DIR="$2"
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

test_output="$(discover_tests "$TESTS_DIR")" || exit $?
TEST_FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TEST_FILES+=("$line")
done <<< "$test_output"
log "Found ${#TEST_FILES[@]} test file(s):"
for f in "${TEST_FILES[@]}"; do
  log "  - $(basename "$f")"
done

# --- Run a single test ---
run_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "$test_file" | sed 's/\.test\.ya*ml$//')"
  local suffix
  suffix="${test_name}_$$_$(date +%s)"
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

  # Cleanup function — always runs (invoked via trap, not directly)
  # shellcheck disable=SC2317,SC2329
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
    PASSED=$((PASSED + 1))
    log "PASSED: $(basename "$test_file")"
  else
    FAILED=$((FAILED + 1))
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
