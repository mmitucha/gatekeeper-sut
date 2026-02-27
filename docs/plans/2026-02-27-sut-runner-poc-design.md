# sut-runner.sh POC Design

## Purpose

Shell-based SUT runner that discovers and executes Docker Compose test definitions,
enforcing image quality by blocking Docker push on test failure.

## Architecture

Single bash script. Sequential flow:

```
CLI args -> validate -> detect compose cmd -> discover tests -> run each -> report -> exit
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0    | All tests passed |
| 1    | One or more tests failed |
| 2    | No test files found |
| 3    | Prerequisites missing (docker, compose) |

## CLI Interface

```
sut-runner.sh --tests-dir <path>
```

Required: `--tests-dir` — path to directory containing `*.test.yaml` / `*.test.yml` files.

## Test File Discovery

- Glob both `*.test.yaml` and `*.test.yml` in `--tests-dir`
- Zero files found -> exit 2 with message

## Per-Test Execution

1. Generate unique suffix: `<basename>_<pid>_<timestamp>`
2. Create external Docker network: `sut_net_<suffix>`
3. Generate temp compose override YAML forcing `default` network to external network
4. Run compose: `up --build --abort-on-container-exit --exit-code-from sut`
5. Cleanup always (trap): `compose down`, `docker network rm`, remove temp override

## Network Override

Override file injected via second `-f`:

```yaml
networks:
  default:
    name: sut_net_<suffix>
    external: true
```

App test.yaml must use implicit `default` network (no named network declarations).

## Docker Compose Detection

Check `docker compose version` (v2) first, fall back to `docker-compose --version` (v1).
Neither found -> exit 3.

## Cleanup Strategy

- `trap cleanup EXIT` in subshell per test
- Removes containers (`compose down -v`), network, temp files
- Runs on success, failure, or signal (INT/TERM)

## Compose Working Directory

Each test runs with the compose file's directory as context (via `-f` with absolute path
or `cd` to test dir), so relative build context paths in test.yaml resolve correctly.

## Conventions

- Docker Hub SUT convention: `sut` service exit code drives pass/fail
- `--exit-code-from sut` always

## App Repo Requirements

- Test files: `hooks/pre_push/*.test.yaml` or `*.test.yml`
- Must have a `sut` service (the test executor)
- Must NOT define custom named networks (use implicit `default`)

## Out of Scope (Future)

- `--timeout` per test (wrap with `timeout N`)
- `SUT_SKIP=1` env var escape hatch
- Parallel test execution
- Versioned releases (pin via git tag)
- Dogfooding via GitHub Actions
