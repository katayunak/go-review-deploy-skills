# Migration analysis

Fill one record per migration in the release. Read each migration file in full; the inventory script only lists candidates.

## 1. Identify the tool and file convention

| Signal | Tool or convention |
|---|---|
| `NNN_name.up.sql` + `.down.sql`, imports `github.com/golang-migrate/migrate` | golang-migrate |
| `-- +goose Up` / `-- +goose Down`, imports `github.com/pressly/goose` | goose |
| `atlas.hcl`, `atlas.sum` | Atlas |
| `-- +migrate Up` | sql-migrate |
| `-- migrate:up` | dbmate |
| `db.AutoMigrate(&Model{})` (gorm) | Implicit: the schema follows struct changes, so changed struct fields **are** migrations |
| `ent/migrate`, `client.Schema.Create` | ent auto-migration |
| `//go:embed` plus a custom runner (for example numbered folders containing `up.sql`) | Custom: read the runner |

Also establish, from code or documentation:

- **Does the tool wrap each migration in a transaction?** This matters for `CREATE INDEX CONCURRENTLY`, which cannot run inside one.
- **Does it take a lock when several replicas start at once?** golang-migrate's PostgreSQL driver takes an advisory lock. For other tools, verify in code or docs.

If you can't establish either, say so.

## 2. Classify the change

- **Additive:** new table, new nullable column, new index, new enum value, new constraint created `NOT VALID`.
- **Destructive:** dropping or renaming a table or column, narrowing a type, adding `NOT NULL` to an existing column, dropping a constraint or index that code or queries rely on.
- **Data-transforming:** `UPDATE`/`DELETE`/`INSERT ... SELECT` backfills, type conversions with `USING`, splitting or merging columns.

## 3. Locking and table-rewrite risk (PostgreSQL)

State these only once the engine is established. Behavior depends on version. If the production version is unknown, write "assuming PostgreSQL 11 or later; production version UNVERIFIED".

| Statement | Typical behavior |
|---|---|
| Any `ALTER TABLE` | Needs an `ACCESS EXCLUSIVE` lock, even if only briefly. While waiting for it, it queues behind long-running transactions and blocks every later query on the table. Recommend `SET lock_timeout` in the migration, with a retry. |
| `ADD COLUMN`, nullable, no default | Metadata only. |
| `ADD COLUMN ... DEFAULT <non-volatile>` | Metadata only on PostgreSQL 11 and later. A full table rewrite on older versions, or with volatile defaults such as `gen_random_uuid()` or `clock_timestamp()`. |
| `ALTER COLUMN ... TYPE` | Usually a full rewrite under `ACCESS EXCLUSIVE`. Exceptions include increasing a varchar length and varchar to text. |
| `SET NOT NULL` | A full scan under `ACCESS EXCLUSIVE`. PostgreSQL 12 and later can skip it if a validated `CHECK (col IS NOT NULL)` already exists. |
| `ADD FOREIGN KEY` / `ADD CHECK` | A full validation scan. Safer: add it `NOT VALID`, then `VALIDATE CONSTRAINT` (weaker lock). |
| `CREATE INDEX` | Blocks writes while the index builds. `CONCURRENTLY` avoids that, but can't run in a transaction and leaves an `INVALID` index if it fails. |
| `ADD UNIQUE` / `ADD PRIMARY KEY` | Builds an index under the stronger lock. Alternative: build a unique index concurrently, then `ADD CONSTRAINT ... USING INDEX`. |
| `DROP COLUMN` / `DROP TABLE` / `RENAME` | Fast, but breaks any running code that still uses the old name. |
| Large `UPDATE` / `DELETE` | A long transaction, row locks, WAL growth, bloat and replication lag. Batch it, outside the schema migration. |

**MySQL:** online DDL depends on the version and algorithm (`INSTANT`, `INPLACE`, `COPY`). Without the production version, don't claim a statement runs online; list it as a question.

**Unknown engine:** make no locking claims; list the engine as missing evidence.

**Table size** is almost never in the repository. Ask for it, or mark the impact as uncertain, before describing a rewrite as low risk.

## 4. Can old and new versions coexist?

Answer both questions for the actual deploy mechanism:

1. **Old app with new schema.** This happens during a rolling deploy when the migration runs first. It breaks on dropped or renamed columns that old code uses, new `NOT NULL` columns old code doesn't fill, new constraints old code violates, or changed types old code scans into incompatible Go types.
2. **New app with old schema.** This happens if the app rolls out before the migration finishes, or the migration fails. It breaks if new code reads or writes columns or tables that don't exist yet.

If either breaks, the release needs an ordering constraint or an expand-migrate-contract split.

## 5. Expand-migrate-contract

1. **Expand:** additive schema changes only, compatible with old and new code.
2. Deploy code that writes the new shape (or both shapes) and reads with a fallback.
3. **Migrate:** backfill in batches, then verify.
4. Switch reads to the new shape.
5. **Contract** (in a later release): drop the old columns or tables once no running version uses them.

Recommend this when a destructive or renaming change ships in the same release as the code that needs it, under rolling deploys.

## 6. Rollback

- **A down script is not proof that rollback is safe.** Down scripts are often untested. Dropping a column added by the up script deletes whatever was written to it since. Data transformations usually can't be reversed exactly.
- First ask: if only the application is rolled back, does the old code run on the new schema? For additive migrations this is usually the preferred path.
- If the schema itself must be reverted: what data is lost? Is restoring from a backup or point-in-time recovery the real fallback, and what does that lose?
- For irreversible changes, recovery is forward-only. Say so plainly.

## 7. Run it separately from the deploy?

Recommend a separate, operator-controlled step when the migration may hold locks for a long time, rewrites a large table, is destructive, transforms data, or must finish before any new instance starts. Running it automatically at startup with several replicas needs a lock; verify that one exists.

## 8. Per-migration record (goes into plan section 5)

| Field | Value |
|---|---|
| File(s) | |
| Change | |
| Class | additive / destructive / data-transforming |
| Lock and rewrite risk | established / assumed (why) / unknown |
| Expected impact | duration, blocking, uncertainty |
| Old app + new schema | works / breaks (why) |
| New app + old schema | works / breaks (why) |
| Rollback | app-only rollback works? schema revert possible? data lost? |
| Run separately? | yes or no, and why |
| Backfill / batching | |
| Post-migration validation | `<<OPERATOR: query that confirms ...>>` |
