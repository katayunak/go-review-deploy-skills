# go-review-deploy-skills

Two Claude Code skills for Go backend repositories: review a branch, then plan its production deployment.

| Skill | Run it with | Produces |
|---|---|---|
| `go-code-review` | `/go-code-review [target-branch]` | A severity-ranked review of everything the branch adds since its merge base with the target (default `main`) |
| `prod-deployment-planner` | `/prod-deployment-planner candidate=<ref> env=<name> deployed=<ref>` | A deployment checklist and ordered execution plan, with go/no-go criteria |

Both are advisory. They read the repository, never modify code or Git state, and never deploy. Both run only when you type the slash command (`disable-model-invocation: true`).

## Install

Clone the repo, then symlink both skills into your Claude Code user skills folder so they work in every repository:

```bash
git clone https://github.com/katayunak/go-review-deploy-skills.git
cd go-review-deploy-skills
mkdir -p ~/.claude/skills
ln -s "$PWD/go-code-review" ~/.claude/skills/go-code-review
ln -s "$PWD/prod-deployment-planner" ~/.claude/skills/prod-deployment-planner
```

Start a new Claude Code session afterwards, because skills are loaded when a session starts. With symlinks, `git pull` updates the installed skills. If your setup doesn't pick up symlinked skills, copy the two folders into `~/.claude/skills/` instead.

Keep the two folders side by side: the planner reads `go-code-review/references/review-report-format.md`.

## Flow

1. **Review.** On the feature branch, run `/go-code-review`. It:
   - establishes the comparison (read-only script, no fetch);
   - analyzes the diff;
   - posts draft findings and a validation plan (**Gate A**: you choose which checks run, or none);
   - runs only the approved checks;
   - writes the final report to `~/.claude/release-evidence/<repo>/<sha12>/review-<time>.md`.
2. **Plan.** Before the release, run `/prod-deployment-planner`. It:
   - confirms the release identity (**Gate B**);
   - checks that a review report matches the candidate commit (same commit, identical content, or squash-merge patch-id) and covers every commit since the deployed version;
   - blocks on Critical or High findings unless you accept specific IDs;
   - asks for missing deployment evidence (**Gate C**);
   - writes the plan next to the review report.

## Approval gates

| Gate | Skill | Fires when | You decide |
|---|---|---|---|
| Ambiguous target | review | local and remote target diverged, target missing | which ref to compare against |
| A: validation | review | after static analysis | which checks to run, if any |
| Re-approval | review | an unapproved command is needed, or files changed during a check | continue or stop |
| B: release identity | planner | candidate, environment or deployed version missing | provide them |
| Entry check | planner | report missing or stale, or commits not covered | re-review, or accept explicitly |
| Blocking findings | planner | Critical or High findings exist | accept specific IDs, or stop |
| C: missing evidence | planner | topology, migration execution or ownership unknown | provide it, or allow placeholders (plan stays NO-GO) |
| Go/no-go | you | end of the plan | always a human decision |

**How the gates are enforced.** The gates are instructions the skills follow. Each skill pre-approves only read-only git commands (`allowed-tools`). Any other command goes through your Claude Code permission mode, which is a backstop only in modes that prompt. For hard limits that apply no matter what a skill does, add deny rules to `~/.claude/settings.json`, for example:

```json
{ "permissions": { "deny": ["Bash(git push:*)", "Bash(kubectl:*)", "Bash(helm:*)", "Bash(terraform apply:*)", "Bash(pulumi up:*)"] } }
```

The helper scripts are not pre-approved, because their absolute path differs per machine. The first run of each asks for permission; approve it permanently if you like. Both scripts only read.

## Files

```
go-code-review/
  SKILL.md                         workflow, rules, gates
  scripts/review-context.sh        read-only git facts (target, merge base, diff, repo tooling)
  references/go-risk-checklist.md  Go failure patterns, and what makes each one a finding
  references/validation-tiers.md   how checks are proposed, run, logged and labelled
  references/review-report-format.md  shared report format (schema v1) + matching rules
prod-deployment-planner/
  SKILL.md
  scripts/release-inventory.sh     read-only inventory of the release range by category
  references/deploy-discovery.md   how deployment, migrations and dependencies are established
  references/migration-analysis.md classification, locking, coexistence, rollback
  references/rollback-and-payments.md  rollback questions and payment invariants
  references/plan-template.md      the 11-section plan and the action-row fields
```

Both scripts need only git, awk and sed, and work with macOS `/bin/bash` 3.2.

## License

MIT. See [LICENSE](LICENSE).
