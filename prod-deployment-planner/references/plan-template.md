# Deployment plan template

Write the plan in this order. It must be usable during a live release: tables and short sentences, with one line of reasoning per step.

## Action row contract

Every action in sections 7 to 11 is a table row with all of these fields:

| # | Component | Prerequisite | Action | Success criterion | Failure signal | If it fails |
|---|---|---|---|---|---|---|

- **Component:** the service, database, job or flag the action applies to.
- **Prerequisite:** the step numbers or conditions that must be true first.
- **Action:** a verified repository command (cite the file and line where it is defined) or a `<<OPERATOR: ...>>` placeholder.
- **Success criterion:** observable and concrete (a value, a count or a state), not "looks fine".
- **Failure signal:** what you would see if it went wrong.
- **If it fails:** the decision or recovery step, referring to section 10 where relevant.

## Layout

```
# Deployment plan: <repo_slug> to <env>

**Status:** BLOCKED | NOT READY: missing evidence | READY FOR HUMAN GO/NO-GO DECISION
Generated <UTC time>. Advisory: no commands were run against any environment.

## 1. Release identity and scope
| Field | Value | Source |
Candidate (SHA, describe, date), deployed version (SHA, describe), environment, release
branch, commits in scope, commits deployed but missing from the candidate (if above 0,
deploying removes them, so call that out), review reports used.

## 2. Review status and unresolved findings
Entry-check table (check, result, evidence).
Findings: | ID | Severity | Title | Status: open / accepted (by, date, verbatim words) |
Validation from the review: anything not `pass` is a risk carried into section 3.
Unreviewed commits accepted by the user, if any.

## 3. Assumptions and missing evidence
| # | Item | Why it matters | Where it might be found | Blocks GO? |

## 4. Changed services and dependencies
Service map (from deploy-discovery.md).
Dependency edges: | From | To | Contract | Evidence | What it means for order |

## 5. Migration inventory and risks
One record per migration (from migration-analysis.md), or "No migrations in scope (verified: <how>)".

## 6. Configuration checklist
| Item | Type (env / secret / flag / default change) | Service | Needed before step | Evidence | How to verify |
Secrets by name only.

## 7. Ordered deployment steps
Phase P1, pre-deployment readiness: freeze window, on-call, backups or snapshots, baseline
metrics, flags in their default state, required evidence filled in.
Phase P2, migration and schema preparation: run separately or with the deploy, per section 5.
Phase P3, configuration and secret readiness: everything in section 6 that is needed
before deployment.
Phase P4, deployment sequence: services in explicit order. Every step says
"because <dependency>"; steps that can run in parallel say so.

## 8. Smoke tests and business verification (P5)
Action rows: technical checks (health, readiness, key endpoints) and business checks
(a real flow end to end; for payments, a low-value transaction in the provider's
test mode or on an allowed account, per the operator's procedure).

## 9. Monitoring and stop conditions (P6)
| Signal | Where | Baseline | Stop if | Watch for |
Error rate, latency, saturation, consumer lag, dead-letter queues, business metrics
(orders completed, payment success rate), and logs for the new code paths.

## 10. Rollback or forward recovery (P7)
Per service: rollback possible on its own? compatible with the schema? data concerns?
Decision rules (from rollback-and-payments.md), with who decides.
Payments section when applicable.
Invariants to check after any recovery.

## 11. Final operator checklist and go/no-go (P8 closure)
GO requires all of:
- [ ] Review report matches the candidate and covers every commit in scope
- [ ] No open Critical or High findings (or each accepted, recorded in section 2)
- [ ] Every "Blocks GO" item in section 3 is resolved
- [ ] Migration plan agreed, with backup or recovery point confirmed
- [ ] Config and secrets in section 6 confirmed present in <env>
- [ ] Rollback or forward-recovery path agreed, with a decision owner named
- [ ] Monitoring dashboards and stop conditions ready; on-call aware
NO-GO if any of the above is unmet, or <release-specific triggers>.
Closure: smoke and business checks passed; observation window completed with no stop
condition; reconciliation done (payments); follow-ups filed (contract-phase migrations,
flag cleanup); release recorded.

This plan is advisory. No commands were run against any environment. The go/no-go
decision belongs to the release owner.
```

## Keep it concise

- Leave out sections' boilerplate when there is nothing to say, but keep every heading, writing "None (verified: <how>)" or "Unknown (see section 3)".
- Put long evidence lists in a short appendix at the end, not inside the step tables.
