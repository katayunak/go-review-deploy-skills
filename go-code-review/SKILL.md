---
name: go-code-review
description: Review everything the current Go feature branch introduces relative to its target branch (default main) for correctness, panics, error handling, concurrency, context and timeouts, transactions, idempotency, security, compatibility and test gaps. Read-only and advisory. Runs builds, tests or linters only after the user approves a validation plan. Writes a report in the shared release-evidence format that prod-deployment-planner consumes.
argument-hint: "[target-branch]"
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash(git rev-parse:*), Bash(git symbolic-ref:*), Bash(git for-each-ref:*), Bash(git show-ref:*), Bash(git merge-base:*), Bash(git rev-list:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git ls-files:*), Bash(git ls-tree:*), Bash(git grep:*), Bash(git cat-file:*), Bash(git describe:*), Bash(git remote get-url:*), Bash(git status:*), Bash(go version:*)
---

# Go branch code review

Target branch: `$ARGUMENTS` (empty means `main`).

You review the code this branch introduces and produce a findings report. You do not change code.

## Rules that always apply

1. **Whole branch, never just the last commit.** The review covers `merge_base..HEAD`.
2. **No changes to the repository.** Do not edit files, switch branches, fetch, pull, stash, reset, commit, push, create or delete refs, or run formatters, generators or `go mod tidy`. If the user asks for fixes, finish the review and tell them fixing is a separate request.
3. **No unapproved execution.** Builds, tests, `go vet`, linters and task-runner targets run only after Gate A, exactly as approved.
4. **No invented facts.** Never state a command result, test outcome, runtime behavior or configuration value you did not observe. Write "not run", "not visible in the repository" or "unknown".
5. **Findings must be real.** Each finding needs a code path you traced, a realistic failure scenario, and a link to lines this branch changed (or a pre-existing defect that the change newly makes reachable). Anything less is an open question, or nothing.
6. **No safety verdicts.** Never call the change safe, correct or bug-free. If there are no findings, say so and list the limitations.
7. **STOP means stop.** End your turn, make no further tool calls, and wait for the user's reply.

## Step 0 - Read the repository's own rules

Read whatever applies (Step 1's script lists the files it found):

- `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` at the root and in every parent folder of a changed file (`changed_dirs_with_instructions`), and `CONTRIBUTING.md`.
- Documentation covering the changed areas (`docs/`, package READMEs, ADRs). Read it before reviewing that code.
- `.golangci.*`, Makefile/Justfile/Taskfile recipes and CI workflow test steps. You need these for Gate A.

Where the repository's rules are stricter than this skill, follow the repository.

## Step 1 - Establish the comparison

Run the facts script from inside the repository. `<skill-dir>` is this skill's base directory, shown when the skill loaded:

    <skill-dir>/scripts/review-context.sh <target>

It only reads. It prints `key=value` lines and `*_begin`/`*_end` blocks and ends with `status=ok` or `status=stop`.

- **`status=stop`:** explain `stop_reason` in plain words and what the user can do (fetch the remote themselves, pass an explicit target such as `refs/heads/main` or `origin/main`, or check out the feature branch). Then **STOP**. Never fetch or switch branches yourself.
- **`status=ok`:** show a short comparison block (branch, HEAD, target ref and SHA with `target_note`, merge base, commits in branch, diff size, `last_fetch`) and continue. Call out:
  - `last_fetch` older than a day, or `unknown`: the remote-tracking target may be stale.
  - `merge_base_count` above 1: criss-cross history; the diff uses one merge base.
  - `worktree_dirty=true`: uncommitted changes are not reviewed. Read changed files with `git show HEAD:<path>`, not from disk.
  - `shallow_clone=true`: history may be incomplete.
  - `size_warning=large`: review in risk order and list areas you could only skim under limitations.

## Step 2 - Understand the change

1. `git log --no-decorate --format='%h %s' <merge_base>..HEAD` for the intent of the branch.
2. `git diff -M --stat <merge_base> HEAD`, then per file `git diff -M -U20 <merge_base> HEAD -- <path>`.
3. Review in risk order: migrations and SQL; money, balances and state transitions; concurrency, workers and consumers; external calls and retries; API, proto, event and config contracts; remaining code; tests last (to judge coverage).
4. For each changed function or type, check:
   - callers (Grep for `Name(`, including through interfaces), callees, and interfaces it implements;
   - previous behavior: `git show <merge_base>:<path>`;
   - error paths, cleanup, context use and locking;
   - SQL statements and transaction boundaries it takes part in;
   - tests that exercise it (Grep in `*_test.go`).
5. Apply [references/go-risk-checklist.md](references/go-risk-checklist.md). Check `go_directive` before reasoning about version-dependent behavior such as loop-variable capture.
6. Generated code (`generated_files` block, or a `// Code generated ... DO NOT EDIT.` header): don't review it line by line. Check that it changed together with its source (`.proto`, sqlc queries, mocked interfaces), and review the source.
7. Sort every candidate issue into **confirmed** (becomes a finding), **needs evidence** (an open question that says what would settle it) or **discarded**.

## Step 3 - Gate A: draft findings and validation plan

Read [references/validation-tiers.md](references/validation-tiers.md). Then find out which checks the repository actually uses: CI steps, task-runner recipe bodies, lint configuration, build tags and test infrastructure.

Post, in this order:

1. The comparison block.
2. **Draft findings (UNVALIDATED)**, using the finding format in [references/review-report-format.md](references/review-report-format.md), most severe first.
3. **Proposed validation plan**: a numbered table with command, why, tier, side effects, infrastructure needed (or none) and rough duration. List targeted checks first. Never include anything from the never-run list.
4. The question: *Reply with the numbers to run (for example `1,2`), `all`, or `none`.*

**STOP.**

## Step 4 - Run only the approved checks

- Before the first command, record `git status --porcelain=v1 --untracked-files=all`. After each command, compare. If anything changed, stop running checks, report exactly what changed, don't revert anything, and **STOP**.
- Run each approved command verbatim, with output logged as described in validation-tiers.md, and record the exit code.
- Label each result `pass`, `fail`, `build-error`, `infra-unavailable`, `timeout`, `skipped`, `no-tests` or `not-run`. Never call something a pass unless it ran and exited 0.
- Anything else (a different flag, an extra package, a re-run) needs approval: ask and **STOP**.
- If a failure might be pre-existing, say you could not tell. Finding out would mean running on the merge base, which needs a checkout this skill doesn't do.
- Update the draft: confirm, revise or withdraw findings based on the results.

If the user replied `none`, record every proposed check as `not-run` with the note `declined`.

## Step 5 - Final report

Write the report exactly as specified in [references/review-report-format.md](references/review-report-format.md).

1. Print it in chat.
2. Save it as `<evidence_dir>/review-<YYYYMMDDTHHMMSSZ>.md`, where `evidence_dir` comes from Step 1. Create the folder if needed. It is outside the repository, so it never dirties the working tree. If saving fails, say so.
3. End with: *This review is advisory. It is not a statement that the change is safe or bug-free, and it does not authorize a deployment.*
