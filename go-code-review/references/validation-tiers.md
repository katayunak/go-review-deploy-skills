# Validation tiers

How to discover, propose, run and record checks. Nothing in tiers T1 to T4 runs before the user approves it at Gate A.

## 1. Find out what the repository uses

- **CI workflows:** the exact `go test` invocation (flags, `-tags`, `-race`, environment variables, `services:` such as postgres) and lint steps.
- **Task-runner recipes:** open each recipe and its dependencies, recursively. Propose a target only if every step it runs falls in T1 to T4. Example: `check: fmt lint test`, where `fmt` runs `gofmt -w`, must not be proposed. Propose the read-only equivalents one by one instead.
- **`.golangci.*`:** config version, enabled linters, and whether auto-fix is turned on (`fix: true`). If it is, propose golangci-lint only with `--fix=false` and say why.
- **Build tags:** `//go:build integration` or `e2e` in changed test files.
- **Test infrastructure:** imports of testcontainers or dockertest, a `TestMain` that connects to a database or broker, and environment variables that tests read (`DATABASE_URL` and similar).
- **Go toolchain:** compare the `go` and `toolchain` lines in go.mod with `local_go`. With the default `GOTOOLCHAIN=auto`, go commands run inside the module may download a newer toolchain. List that as a side effect.

## 2. Tiers

| Tier | Approval | Commands |
|---|---|---|
| T0 | not needed | Read-only git commands, file reads, `go version` run outside the module with `GOTOOLCHAIN=local` (the facts script does this) |
| T1 static/compile | required | `go vet ./<pkg>/...` (type-checks packages and their tests); `gofmt -l <changed .go files>` (lists unformatted files, never `-w`); `go mod tidy -diff` (Go 1.23 or later only; prints the changes without writing); `golangci-lint run --new-from-rev=<merge_base> ./...` (only if installed and not auto-fixing) |
| T2 targeted tests | required | `go test -count=1 -v ./<changed pkg>/...`, optionally `-run '<NewTests>'`, optionally `-race` (needs cgo, slower) |
| T3 broad | required | `go test -count=1 ./...`, `go test -count=1 -race ./...` |
| T4 needs infrastructure | required, listed separately | Integration build tags, testcontainers or Docker, databases, brokers, network. Never start Docker or a compose stack unless that exact command is an approved item. |

Propose T1 and T2 before T3. Give each item a reason tied to the change, such as "covers the new retry path in worker.go".

## 3. Side effects to disclose for every item

- Writes to the Go build and test cache (`GOCACHE`), outside the repository.
- May download modules into `GOMODCACHE` (network) if they aren't cached. Since Go 1.16, `-mod=readonly` is the default, so go.mod and go.sum are not rewritten. A `vendor/` folder means `-mod=vendor`.
- May download a toolchain (`GOTOOLCHAIN=auto`).
- Tests themselves may write files, call services named in environment variables, or update golden files when given flags such as `-update`. Never pass such flags.

## 4. Never run

`go mod tidy` (without `-diff`), `go get`, `go generate`, `go fix`, `go install`, `go clean`, `gofmt -w`, `goimports -w`, `golangci-lint --fix`, any task-runner target with a step that modifies files, `docker compose up` or `down` (unless approved as a T4 item), any `git` command that writes, and anything that touches a remote environment.

## 5. Running an approved item

The folder is `evidence_dir` from the facts script, outside the repository.

    mkdir -p <evidence_dir>/logs
    <approved command> > <evidence_dir>/logs/<n>.log 2>&1; echo "exit=$?"

Then read the summary lines and the end of the log:

    grep -E -- '^(--- FAIL|--- SKIP|FAIL|ok |panic:|\?   )' <evidence_dir>/logs/<n>.log
    tail -n 60 <evidence_dir>/logs/<n>.log

Give the Bash call a timeout that fits the tier. If it's hit, the result is `timeout`.

## 6. Labelling results

| Result | Meaning |
|---|---|
| `pass` | Exit 0 and tests ran (`ok` lines). |
| `no-tests` | Exit 0, but every package reported `[no test files]`. |
| `skipped` | Tests reported `--- SKIP` (visible with `-v`). Note which ones and why, if a reason is printed. Without `-v`, skips are invisible; say so. |
| `fail` | `--- FAIL` or `FAIL` from test assertions. |
| `build-error` | Compile errors, `[build failed]`, `[setup failed]`, or `go vet` errors. |
| `infra-unavailable` | Failed because infrastructure was missing: connection refused, no such host, Docker daemon not running, missing credentials. Quote the line. |
| `timeout` | `panic: test timed out` or the tool timeout was hit. |
| `not-run` | Proposed but declined, not approved, or not reached. |

Never report `pass` for a command that did not run, or for a run whose output you didn't read.
