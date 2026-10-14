# Review report format (schema_version 1)

This is the contract between `go-code-review`, which writes the report, and `prod-deployment-planner`, which reads it. Change it only by bumping `schema_version`. The planner rejects versions it doesn't know.

## Location

    ~/.claude/release-evidence/<repo_slug>/<first 12 chars of head_sha>/review-<YYYYMMDDTHHMMSSZ>.md

`repo_slug` and the folder come from `review-context.sh` (`evidence_dir`). Deployment plans are saved in the same folder tree. Nothing is written inside the repository.

## Header (YAML front matter, required)

```yaml
---
report: go-code-review
schema_version: 1
repo_slug: github.com/acme/payments
repo_root: /Users/me/src/payments
branch: feat/refund-retry              # DETACHED for a detached HEAD
head_sha: <40 hex>
target_input: main
target_ref: refs/remotes/origin/main
target_sha: <40 hex>
target_last_fetch: 2026-10-09T08:12:44Z   # or unknown
merge_base: <40 hex>
merge_base_count: 1
commits_reviewed: 7
worktree_dirty: false                  # uncommitted changes are never reviewed
generated_at: 2026-10-09T13:05:00Z
excluded_paths: ["vendor/**", "internal/gen/**"]
findings: {critical: 0, high: 1, medium: 2, low: 1}
blocking_ids: [GCR-1]                  # every critical and high finding
validation:
  - {id: 1, cmd: "go vet ./internal/refund/...", exit: 0, result: pass, log: "logs/1.log"}
  - {id: 2, cmd: "go test -count=1 -v ./internal/refund/...", exit: 1, result: infra-unavailable, log: "logs/2.log", note: "postgres connection refused"}
  - {id: 3, cmd: "go test -count=1 ./...", result: not-run, note: declined}
---
```

Field rules:

- SHAs are full 40-character hashes.
- `validation` lists every proposed check, including ones that didn't run. Omit `exit` when a check didn't run.
- `result` is one of `pass`, `fail`, `build-error`, `infra-unavailable`, `timeout`, `skipped`, `no-tests`, `not-run`.
- `log` paths are relative to the report's folder.

## Body (required sections, in this order)

### 1. Comparison
Branch, HEAD, target ref and SHA, how the target was chosen (`target_note`), merge base, commits reviewed, last fetch, uncommitted changes excluded (yes/no).

### 2. Scope reviewed
Functional areas and files reviewed in depth, files skimmed, files excluded and why (generated, vendored, docs-only).

### 3. Findings
Most severe first. If there are none, write "No confirmed findings." and point to section 8.

```
### GCR-1 · High · internal/refund/worker.go:118
**What:** one or two sentences.
**Failure scenario:** concrete inputs or state, then the wrong outcome.
**Why this change causes it:** the changed lines, or the change that makes a pre-existing defect reachable.
**Fix:** a concrete recommendation.
**Evidence:** what you traced or ran (for example: callers at api/refund.go:40; validation #2).
```

Number IDs in severity order. They stay fixed within a report.

### 4. Test gaps
New behavior or failure paths without tests, each tied to a file and line.

### 5. Validation
| # | Command | Result | Exit | Log | Notes |

Then: "Proposed but not run", with reasons.

### 6. Remaining risks and open questions
Unconfirmed concerns, each with the evidence that would settle it.

### 7. Deployment signals
Facts from the diff that matter for release planning. Give each with a file and line, or write "none found":

- Migrations and schema changes
- Configuration and environment variables (names only)
- Secrets (names only, never values)
- API, proto and event contract changes
- Background workers, consumers, producers and scheduled jobs
- External providers and third-party calls
- Feature flags
- Changes to persisted data or business state

The planner re-derives these from Git and flags any mismatch. It doesn't rely on this section alone.

### 8. Limitations and closing statement
What could not be checked (infrastructure, runtime config, other repositories, skimmed areas), then:
*This review is advisory. It is not a statement that the change is safe or bug-free, and it does not authorize a deployment.*

## Severity

- **Critical:** likely severe financial, security or data-integrity damage. Examples: double charge, ledger imbalance, authorization bypass, data loss.
- **High:** a significant production defect or reliability risk. Examples: panic on a request path, goroutine leak under normal load, a rollout-breaking incompatibility.
- **Medium:** a meaningful correctness issue with more limited impact. Examples: wrong status code, a mishandled edge case that has a recovery path.
- **Low:** a minor but concrete defect, or a maintainability issue likely to cause a future bug.

When torn between two levels, choose the lower one and state the condition that would raise it.

## Lifecycle

- A saved report never changes. It describes `head_sha` only.
- Fixing a finding creates a new commit, which needs a new review and a new report.
- Accepting the risk of an unfixed finding is recorded in the deployment plan, never by editing the review.

## Matching a report to a candidate commit (used by the planner)

Accept a report for candidate commit `C` only if `report: go-code-review`, `schema_version: 1`, `repo_slug` matches, and one of these holds:

- **a. Same commit:** `head_sha == C`.
- **b. Identical content:** `git diff --quiet <head_sha> <C>` exits 0.
- **c. Squash merge:** the first field of `git diff <merge_base> <head_sha> | git patch-id --stable` equals the first field of `git diff <C>^ <C> | git patch-id --stable`. Empty output never matches.

Otherwise the report is **stale** for `C`.

## Coverage of a release range (used by the planner)

For release range `D..C` (deployed to candidate), each commit `X` in `git rev-list D..C` is covered when any report `R` for the same repository satisfies one of:

- `X` is inside `R`'s range: `git merge-base --is-ancestor X <R.head_sha>` succeeds and `git merge-base --is-ancestor X <R.merge_base>` fails.
- `X` is the squash of `R`: rule c above, with `X` in place of `C`.
- `X` is a clean merge commit: `git show --cc --format= X` prints nothing. The commits it brings in must be covered themselves.

If commits were rebased after review, their SHAs no longer match. List them as uncovered and mention rebasing as the likely cause.
