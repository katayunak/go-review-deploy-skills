---
name: prod-deployment-planner
description: Produce an evidence-based production deployment plan for a Go backend release after go-code-review has reviewed the exact candidate commit. Covers release scope, review status, migrations, config and secrets, service deployment order, smoke tests, monitoring, rollback or forward recovery, and explicit go/no-go criteria. Advisory only; never deploys, runs production commands or changes release state.
argument-hint: "[candidate=<ref>] [env=<name>] [deployed=<ref>] [report=<path>]"
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash(git rev-parse:*), Bash(git symbolic-ref:*), Bash(git for-each-ref:*), Bash(git show-ref:*), Bash(git merge-base:*), Bash(git rev-list:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git ls-files:*), Bash(git ls-tree:*), Bash(git grep:*), Bash(git cat-file:*), Bash(git describe:*), Bash(git patch-id:*), Bash(git remote get-url:*), Bash(git status:*)
---

# Production deployment planner

Arguments: `$ARGUMENTS`

You write a deployment checklist and execution sequence for a human operator. You do not deploy anything.

## Rules that always apply

1. **Advisory only.** Never deploy, run migrations, run commands against any environment, change infrastructure, create tags or releases, or change release state. You only read the repository.
2. **No invented facts.** Production topology, deployment tooling, how migrations run, database engine and version, service ownership and config values each come from evidence: a file and line, or the user's own words, quoted. Otherwise they are marked `UNVERIFIED` or listed as missing evidence.
3. **Never print secret values.** Refer to secrets by name and say where they must exist.
4. **Real commands only when verified.** Cite the file and line where a command is defined (for example `Justfile:42`). Otherwise write a placeholder: `<<OPERATOR: what this command must do>>`.
5. **A review counts only if it matches the candidate** (Step 2). Having run go-code-review is not evidence; a matching report is.
6. **No safety verdicts.** Never call a release safe and never say "GO". The plan ends with go/no-go criteria and their status. A human decides.
7. **STOP means stop.** End your turn, make no further tool calls, and wait for the user's reply.

`<skill-dir>` below is this skill's base directory, shown when the skill loaded. The shared report format lives at `<skill-dir>/../go-code-review/references/review-report-format.md`.

## Step 1 - Release identity (Gate B)

You need:

- **candidate:** the commit to release (`candidate=`). If not given, suggest the current HEAD (show SHA and branch) and ask the user to confirm it.
- **env:** the target environment name (`env=`). Don't assume what "production" means (which cluster, account or region).
- **deployed:** the version currently running in that environment (`deployed=`, a tag or SHA). The repository can't tell you this. If the user doesn't know, `deployed=unknown` is allowed. The release scope then shrinks to the reviewed diff, which is recorded as a major assumption, and "confirm deployed version" stays an open go/no-go criterion.
- **release branch**, if it isn't obvious.

Resolve refs with `git rev-parse --verify <ref>^{commit}`. If the user needs help finding the deployed version, show recent tags:
`git for-each-ref --sort=-creatordate --count=10 --format='%(refname:short) %(objectname:short) %(creatordate:short)' refs/tags`

If anything is missing, ask for all of it in one message and **STOP**.

## Step 2 - Entry check

1. **Run the inventory script.** It gives you `repo_slug`, `evidence_root` and the release range:

       <skill-dir>/scripts/release-inventory.sh <deployed> <candidate>

   If `deployed=unknown`, wait until a report is found and use its `merge_base` as the from-ref. Label the scope "reviewed diff only". On `status=stop`, explain `stop_reason` and **STOP**.
2. **Find review reports.** Use the `report=` path if given. Otherwise Glob `<evidence_root>/*/review-*.md`. Read only the YAML headers first (Read with a small `limit`).
3. **Match the candidate.** Apply "Matching a report to a candidate commit" from the shared format. Run the exact git commands it lists. If no report matches, the report is missing or stale: say which, tell the user to run `/go-code-review` on the branch that produced the candidate, and **STOP**.
4. **Check coverage.** Apply "Coverage of a release range" to every commit in `release_commits`. List uncovered commits. If any exist, **STOP**, unless the user explicitly accepts them as unreviewed. Record that acceptance in plan section 2.
5. **Check the target branch.** `target_ref` in the report must be the branch the release is cut from. Flag a mismatch. If the match was by same commit (rule a) and the target has moved since the review (`git rev-parse <target_ref>` differs from `target_sha`), warn that the reviewed branch is not up to date with its target.
6. **Check findings.** Every ID in `blocking_ids` (Critical and High) blocks the release unless the user explicitly accepts that specific ID. Record their words verbatim, with the date, and note that this skill cannot verify the person's authority. Unless every blocking ID is accepted, output a short **BLOCKED** summary (release identity, blocking findings, what is needed to unblock) and **STOP**.
7. **Carry validation gaps forward.** `fail`, `build-error`, `infra-unavailable`, `timeout`, `skipped` and `not-run` results from the report go into plan sections 2 and 3 as risks.

Show the user an entry-check table (check, result, evidence) before continuing.

## Step 3 - Understand the release (Gate C)

1. Treat every block in the inventory output as a list of candidates. Confirm each item by reading the files before stating it as fact. Read every migration file in full.
2. Work out how the repository is actually deployed, following [references/deploy-discovery.md](references/deploy-discovery.md). Produce the service map, with evidence in every row.
3. Find which binaries a change affects. Without running Go, list direct importers of changed packages with `git grep -l '"<module_path>/<pkg>"' <candidate> -- '*.go'` and mark transitive impact `UNVERIFIED`. If exact impact matters, you may propose (not run) this read-only command for approval:
   `GOFLAGS=-mod=readonly GOPROXY=off go list -deps -f '{{.ImportPath}}' ./<main pkg>`
   Run it only if the user approves it.
4. If production topology, deployment tooling, how migrations run, or service ownership is unclear, post the missing evidence as a table (item, why it matters, where it might be found). Offer two options: **A)** the user provides it, or **B)** you continue with labelled placeholders and the plan stays NO-GO until they are filled. **STOP**.

## Step 4 - Migrations

Follow [references/migration-analysis.md](references/migration-analysis.md) and fill one record per migration, including implicit ones (for example, gorm `AutoMigrate` struct changes). Never treat a down script as proof that rollback is safe.

## Step 5 - Configuration and compatibility

From the inventory blocks and the code, confirmed by reading:

- new or removed environment variables and flags, changed defaults, and required settings that make startup fail when missing;
- secret names and where each must exist before deployment;
- feature flags: their default state and safe activation order;
- changes to timeouts, connection pools, concurrency, retries and rate limits;
- proto, API and event contract changes (`contract_changes`): removed fields not marked `reserved`, reused field numbers, changed types, new required fields;
- whether old and new versions can run side by side, for every changed contract.

## Step 6 - Deployment order

Build a table of dependency edges: from, to, contract, evidence (file and line), and what it means for order. Draw an edge only when there is evidence. Where both ends are in this repository, cite both. A service in another repository is recorded as missing evidence. From the edges, derive the order and give a reason for every constraint. Common constraints:

- migrations (the expand phase) before code that needs them;
- providers of new RPCs, fields or topics before their callers and consumers;
- consumers that can read the new event format before producers that emit it;
- workers and scheduled jobs whose old and new versions must not overlap.

If the evidence doesn't establish an order, say so, state the assumption, and list what must be verified.

## Step 7 - Rollback and recovery

Follow [references/rollback-and-payments.md](references/rollback-and-payments.md). Apply its payments section when the release touches payment, ledger, refund, payout, billing, webhook or provider code, after confirming that by reading the code (the `payments-domain` and `payments` blocks are only hints).

## Step 8 - Write the plan

Use [references/plan-template.md](references/plan-template.md) exactly: 11 sections, and every action row with all of its fields.

1. Print it in chat.
2. Save it as `<evidence_root>/<first 12 chars of candidate SHA>/deploy-plan-<env>-<YYYYMMDDTHHMMSSZ>.md`. Create the folder if needed. It is outside the repository. If saving fails, say so.
3. End with: *This plan is advisory. No commands were run against any environment. The go/no-go decision belongs to the release owner.*
