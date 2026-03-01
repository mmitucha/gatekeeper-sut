# gatekeeper-sut

> **Docker image pre-push build gate — inspired by Docker Hub's Automated Repository Tests**

A platform-agnostic shell-based SUT (System Under Test) runner that enforces Docker image quality
by running containerized tests **before** allowing a `docker push`. Pure bash, no extra dependencies
beyond Docker.

> Vibe-coded with [Claude Code](https://claude.ai/code).

---

## Table of Contents

- [Inspiration](#inspiration)
- [How It Works](#how-it-works)
- [The `hooks/` Convention](#the-hooks-convention)
- [Repository Structure](#repository-structure)
- [Quick Start](#quick-start)
- [Test File Format](#test-file-format)
- [Runner CLI](#runner-cli)
- [CI Integration](#ci-integration)
- [Compatibility & Validation](#compatibility--validation)
- [Open Roadmap](#open-roadmap)

---

## Inspiration

### Docker Hub Automated Repository Tests

Docker Hub has a built-in feature called **Automated Repository Tests** (now largely deprecated/hidden
behind paid plans). When enabled, Docker Hub would spin up a special `sut` service defined in a
`docker-compose.test.yml` alongside your image and run it as a test gate — if the `sut` container
exited non-zero, the push was blocked.

This project brings that same concept **outside Docker Hub**, so any CI/CD platform can enforce the
same quality gate on every push.

### The `hooks/` Naming

The `hooks/` directory name is a deliberate double reference:

1. **Git hooks** — the familiar `/.git/hooks/pre-push` pattern, where you run checks before an
   action is allowed to proceed.
2. **Docker Hub's SUT convention** — test definitions live under `hooks/pre_push/` inside the
   tested application's repo, mirroring the lifecycle event that triggers them.

The result: any developer who has used git hooks or Docker Hub automated tests will immediately
recognize what the folder does.

---

## How It Works

```
app-repo/                          gatekeeper-sut/
└── hooks/                         └── sut-runner.sh   ← fetched by CI
    └── pre_push/
        ├── smoke.test.yaml   ──→  sut-runner.sh discovers, runs, and
        └── smoke_test.sh          enforces exit-code from the sut service
                                          │
                                          ▼
                                   Docker push allowed  /  blocked
```

1. CI fetches `sut-runner.sh` from this repo (or pins a tagged release).
2. Runner discovers all `*.test.yaml` / `*.test.yml` files in the app's `hooks/pre_push/` dir.
3. **Each test gets its own temporary, isolated Docker network** — created just before the test, injected automatically, destroyed immediately after. Your `*.test.yaml` needs no `networks:` block.
4. The `sut` service exit code determines pass/fail — same semantics as Docker Hub.
5. If **any** test fails → runner exits non-zero → CI blocks the Docker push job.

### Isolated test networks

This is a key design feature. For every test file the runner:

1. Creates a uniquely named external Docker network before `docker compose up`
2. Injects it via a second `-f` compose override — overriding the `default` network without touching your yaml
3. Destroys the network after the test completes — always, via `trap cleanup EXIT` in a subshell

**Network naming:** `sut_net_<testname>_<pid>_<timestamp>`

| Segment | Purpose |
|---------|---------|
| `sut_net_` | prefix — easy to spot in `docker network ls` |
| `<testname>` | human-readable — derived from the yaml filename |
| `<pid>` | process ID — prevents collision if two runner instances start simultaneously |
| `<timestamp>` | Unix epoch — additional uniqueness for sequential re-runs |

**Why this matters:**
- Tests are fully isolated from each other and from any existing networks on the host
- Safe to run multiple CI agents in parallel on the same Docker host — no name conflicts
- Cleanup is guaranteed on pass, fail, crash, `Ctrl+C`, or `SIGTERM` — the `trap` fires regardless
- App test yamls stay clean — no network boilerplate, no awareness of the runner's internals

---

## The `hooks/` Convention

Tests live **inside the application repo**, not here. This keeps each app responsible for its own
quality contract.

```
your-app-repo/
└── hooks/
    └── pre_push/
        ├── smoke.test.yaml        # minimal sanity check
        ├── integration.test.yaml  # heavier integration test
        └── smoke_test.sh          # script referenced by a sut container
```

### Rules

| Rule | Detail |
|------|--------|
| File naming | `*.test.yaml` or `*.test.yml` |
| Required service | Every compose file **must** define a `sut` service |
| Exit code | `sut` container exit code = test result (0 = pass, non-zero = fail) |
| Network | Runner creates a unique isolated network per test and injects it via compose override — **no `networks:` block needed** in your yaml |
| Cleanup | `trap cleanup EXIT` in a subshell guarantees compose stack + network teardown on pass, fail, crash, or signal |

---

## Repository Structure

```
gatekeeper-sut/
├── sut-runner.sh           # Main runner — the only file CI needs
├── examples/
│   └── hooks/
│       └── pre_push/
│           ├── smoke.test.yaml    # Minimal example: alpine echo test
│           └── smoke_test.sh      # Example script-based test placeholder
└── docs/
    └── plans/              # Design docs and POC notes
```

---

## Quick Start

### 1. Add tests to your app repo

```
your-app/hooks/pre_push/smoke.test.yaml
```

```yaml
services:
  sut:
    image: alpine:3.19
    command: ["sh", "-c", "echo 'Smoke test passed' && exit 0"]
```

### 2. Run the runner locally

```bash
curl -fsSL https://raw.githubusercontent.com/mmitucha/gatekeeper-sut/main/sut-runner.sh \
  -o /tmp/sut-runner.sh
chmod +x /tmp/sut-runner.sh

/tmp/sut-runner.sh --tests-dir ./hooks/pre_push
```

### 3. Wire it as a build gate in CI

Runner exits non-zero on any failure — make the Docker push job depend on it.

---

## Test File Format

Follows the Docker Hub SUT convention. The compose file defines your app services plus a `sut`
service that exercises them.

```yaml
# hooks/pre_push/integration.test.yaml

services:
  app:
    image: myorg/myapp:${IMAGE_TAG:-latest}
    environment:
      - DATABASE_URL=postgres://db/test

  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_DB=test
      - POSTGRES_PASSWORD=test

  sut:
    image: alpine:3.19
    depends_on:
      - app
      - db
    command: ["sh", "/tests/smoke_test.sh"]
    volumes:
      - ./smoke_test.sh:/tests/smoke_test.sh:ro
```

Key points:
- **No `networks:` block needed** — runner injects an isolated network via a compose override.
- **`sut` service exit code drives everything** — `--exit-code-from sut` is passed automatically.
- Scripts referenced by `sut` can be mounted from the same `hooks/pre_push/` directory.

---

## Runner CLI

```
Usage: sut-runner.sh --tests-dir <path>

Discovers and runs Docker Compose SUT tests.

Options:
  --tests-dir <path>  Directory containing *.test.yaml / *.test.yml files (required)
  -h, --help          Show this help message

Exit codes:
  0  All tests passed
  1  One or more tests failed
  2  No test files found in --tests-dir
  3  Missing prerequisites (docker / docker compose)
```

### Compose compatibility

Runner auto-detects `docker compose` (v2 plugin) or `docker-compose` (v1 standalone) at startup.

---

## CI Integration

### GitHub Actions

```yaml
jobs:
  sut-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run SUT tests
        run: |
          curl -fsSL https://raw.githubusercontent.com/mmitucha/gatekeeper-sut/main/sut-runner.sh \
            -o /tmp/sut-runner.sh
          chmod +x /tmp/sut-runner.sh
          /tmp/sut-runner.sh --tests-dir ./hooks/pre_push

  docker-push:
    needs: sut-tests
    runs-on: ubuntu-latest
    steps:
      - name: Push image
        run: docker push myorg/myapp:latest
```

### Azure DevOps

```yaml
jobs:
  - job: SUT_Tests
    steps:
      - script: |
          curl -fsSL https://raw.githubusercontent.com/mmitucha/gatekeeper-sut/main/sut-runner.sh \
            -o /tmp/sut-runner.sh
          chmod +x /tmp/sut-runner.sh
          /tmp/sut-runner.sh --tests-dir ./hooks/pre_push

  - job: DockerPush
    dependsOn: SUT_Tests
    condition: succeeded()
    steps:
      - script: docker push myorg/myapp:latest
```

### Local pre-push git hook

Drop this in your app repo's `.git/hooks/pre-push` (or manage via [husky](https://typicode.github.io/husky)):

```bash
#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/mmitucha/gatekeeper-sut/main/sut-runner.sh \
  -o /tmp/sut-runner.sh
chmod +x /tmp/sut-runner.sh
exec /tmp/sut-runner.sh --tests-dir ./hooks/pre_push
```

---

## Compatibility & Validation

### Platform compatibility

`sut-runner.sh` targets **bash 3.2+** for macOS/Linux compatibility (macOS ships bash 3.2 by default).

| Platform | Tested |
|----------|--------|
| macOS (Darwin) | Yes |
| Linux (Ubuntu/Debian) | Yes |
| CI runners (GitHub Actions, Azure DevOps) | Yes |

Avoid bash 4+ features (`declare -A`, `mapfile`, etc.) unless explicitly tested on macOS.
Use `date +%s` and POSIX-compatible `sed` patterns — BSD `sed` (macOS) differs from GNU `sed`.

### Shell validation with shellcheck

All bash scripts in this repo are validated with [shellcheck](https://www.shellcheck.net/).
Run before committing any shell changes:

```bash
shellcheck sut-runner.sh
shellcheck examples/hooks/pre_push/smoke_test.sh
```

Install:
```bash
# macOS
brew install shellcheck

# Linux
apt-get install shellcheck
# or
dnf install shellcheck
```

shellcheck catches portability issues, quoting bugs, and common shell pitfalls — run it on any new
shell script added to this repo or to `hooks/pre_push/` in your app.

---

## Open Roadmap

- [ ] Per-test timeout (`timeout 120 sut-runner.sh ...`)
- [ ] `SUT_SKIP=1` env var escape hatch for emergency bypass
- [ ] Versioned releases — pin CI to a tag instead of `main`
- [ ] GitHub Actions self-test (dogfooding gatekeeper-sut with itself)
- [ ] Parallel test execution option

---

> **Keep this README up to date.** When behavior, CLI options, file conventions, or CI patterns
> change — update the relevant section here first. The README is the primary reference for users
> integrating gatekeeper-sut into their pipelines.
