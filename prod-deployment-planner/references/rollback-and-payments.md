# Rollback and recovery

Rollback is a decision, not a default. For each changed service, decide between rolling back the application, switching off a feature flag, or fixing forward.

## Questions for every changed service

1. **Can it be rolled back on its own?** Not if a service already deployed in this release depends on its new contract (a new RPC, field or topic).
2. **Can the old version run on the post-migration schema?** Use the answer from migration-analysis.md, section 4, question 1.
3. **Has data been transformed, or written in a shape old code can't read?** Examples: new enum or status values, required new JSON fields, rows in new tables that old code ignores.
4. **What about messages in flight?** Did the new version publish events or jobs that old consumers can't parse? Will retries or redelivery repeat operations after a rollback (duplicate side effects)?
5. **Is there a feature flag or kill switch** that disables the risky path without a deploy? Prefer it.
6. **Scheduled jobs:** while two versions overlap, can both run the same job (double execution)? Is there leader election or a lock?
7. **Is fixing forward safer?** Usually yes when an irreversible migration has run, data already exists in the new format, or state at an external provider has changed.

## Decision rules (fill in per release)

- **Roll back the application if** `<stop condition>` and the old version is compatible with the current schema and data.
- **Switch off the flag if** the problem is confined to the flagged path.
- **Fix forward if** rollback is incompatible, or data has already been transformed.
- **Who decides:** a role or name. `UNVERIFIED` if unknown.

## After any recovery, check the invariants

List the business invariants the release touches (taken from the code), each with how to check it (`<<OPERATOR: query>>`). For example:

- no orders stuck in an intermediate state for longer than X minutes;
- ledger balances reconcile;
- no duplicate records per idempotency key;
- consumer lag is back to baseline;
- dead-letter queue size is back to baseline.

## Payments

Apply this section when the release touches payment, charge, refund, payout, ledger, wallet, billing, webhook or payment-provider code, and you've confirmed that by reading the code.

### Duplicate charges

- Every provider call that moves money must carry an idempotency key tied to the logical operation (not the attempt), and retries must reuse that key.
- Timeouts are ambiguous: the provider may have succeeded. Code must check the outcome (look it up by key or reference) before retrying with a new key.
- At-least-once consumers and webhook handlers must deduplicate.
- During the rollout overlap, old and new versions may process the same queue. Check whether either version retries differently.

### Order and payment status consistency

- Is the internal status written in the same transaction that records the provider's result? If the provider call happens inside, or before, a transaction that later fails, money moves with no record.
- Can webhooks arrive before the internal record exists, or carry statuses old code doesn't know?
- Are status transitions enforced in the write (`WHERE status = <expected>`)?

### State at the provider

- Rolling back code does not undo authorizations, captures, refunds or payouts at the provider. Recovery means compensating actions (void, refund), not a revert.
- Authorizations expire, so captures delayed by an incident may fail.
- Provider configuration changes (webhook URLs, API versions, keys) are not undone by redeploying.

### Idempotency

Check the key's scope (merchant, customer, operation), where it is stored, the unique constraint that enforces it, and its lifetime compared with the retry window. Check what happens when the key is missing: the request must be rejected, not silently treated as a duplicate or as new.

### Reconciliation

- Plan a reconciliation for the release window: compare internal records with the provider's reports (count and sum by status and currency). `<<OPERATOR: reconciliation query or report>>`
- Name who reviews mismatches, and the threshold that turns a mismatch into an incident.

### Money arithmetic

Amounts in integer minor units, currency carried alongside every amount, and explicit rounding rules.
