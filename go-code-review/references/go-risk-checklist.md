# Go risk checklist

Use this list to know where to look, not as a list of things to report. Report an item only after you have traced it in this branch's code and can describe a realistic failure. Each section ends with what it takes to become a finding.

## 1. Panics and crashes

- Dereferencing something that can be nil: a `*T` used after its error was ignored or non-nil; pointer values from map lookups; optional proto or JSON fields (`msg.GetX()` is nil-safe, `msg.X.Y` is not).
- Writing to a nil map. Type assertions without `, ok` on values from interfaces, `any` or decoded JSON. Indexing slices with external or computed indexes (`strings.Split(s, ":")[1]`).
- Integer division or modulo by a value that can be zero.
- Sending on or closing a closed channel. Closing from the receiver side, or from several senders.
- A `sync.WaitGroup` counter going negative, or `Add` called inside the goroutine it counts.
- `panic`, `log.Fatal*` or `os.Exit` in library or request-path code. `log.Fatal` skips deferred cleanup.
- Panics in goroutines: `net/http` recovers panics only in the handler's own goroutine. A panic in a goroutine the handler starts crashes the whole process.

**Finding when:** you can name the input or state that reaches the panic, and the path to it from an entry point (handler, consumer, job, main).

## 2. Error handling

- Ignored errors: `_ =`, a call used as a bare statement, or `defer f.Close()` / `defer tx.Commit()` where the error matters (written files, commits).
- `err` shadowed in an inner scope (`x, err := ...` inside `if` or `for`), so the outer check sees nil.
- A failure path that returns a nil error or a success response, or leaves partial work behind.
- `rows.Err()` not checked after iterating. `sql.ErrNoRows` compared with `==` after wrapping (use `errors.Is`). `%v` instead of `%w` where callers use `errors.Is`/`errors.As`.
- Error messages that expose internals or secrets to clients.

**Finding when:** the lost or misrouted error leads to a wrong result, lost data, or a false success.

## 3. Concurrency

- Maps, slices or struct fields shared between goroutines without a mutex or atomics. Handlers share their server struct.
- A loop variable captured by a goroutine or closure. This is only a bug when the module's `go` directive is below 1.22.
- Goroutines with no way to exit. A common case is a blocked send on an unbuffered channel after the receiver gave up (the `select` returned on `ctx.Done()`, so the worker blocks on `ch <- result` forever). Another is a loop with no `ctx.Done()` check.
- `time.After` in a hot loop, which allocates and, before Go 1.23, leaks timers. A `time.Ticker` that is never stopped.
- A struct containing `sync.Mutex` copied by value (`go vet` copylocks).
- A lock held during I/O or while calling out to other code. Inconsistent lock ordering (deadlock).
- Unbounded goroutine fan-out per request or message (missing `errgroup.SetLimit` or a semaphore).
- `errgroup.WithContext`: its context is cancelled when the first goroutine fails and when `Wait` returns, so using it after `Wait` is a bug.

**Finding when:** you can describe the interleaving or load pattern that triggers it.

## 4. Context, cancellation and timeouts

- `context.Background()` or `context.TODO()` in a request or message path instead of the incoming context.
- Work that must outlive the request using the request's context, which is cancelled when the handler returns.
- Outbound calls with no deadline: `http.Client{}` without `Timeout`, `http.DefaultClient`, gRPC calls without a deadline, database calls without the `...Context` variants.
- `context.WithTimeout` or `WithCancel` without calling `cancel` (`go vet` lostcancel).
- Long loops or batches that never check `ctx.Err()`.

**Finding when:** a slow or failing dependency leads to hung goroutines, exhausted pools, or work that continues after the caller gave up.

## 5. Resource lifecycle

- `resp.Body` not closed on every path, including non-2xx responses. `rows` not closed. A `sql.Tx` not rolled back on error paths; the idiom is `defer tx.Rollback()` right after `BeginTx` (rollback after commit is a no-op).
- `defer` inside a loop, which holds resources until the function returns.
- Files, tickers, timers, subscriptions or consumers not closed on shutdown. Servers without graceful shutdown.

**Finding when:** the leak is on a path that runs repeatedly (per request or message), or it blocks shutdown.

## 6. Database and transactions

- External calls (payment provider, HTTP, broker publish) inside a database transaction. Locks are held during the network call, and if the commit then fails, the external side effect has already happened.
- Writes that must be atomic split across transactions. A database write plus a message publish with no outbox.
- Check-then-act races: `SELECT count(*)` followed by `INSERT`. This needs a unique constraint plus `ON CONFLICT`, or locking. Read-modify-write without `SELECT ... FOR UPDATE` or a version column.
- An `UPDATE` without checking `RowsAffected` where the row must exist or must be in a particular state.
- SQL built with string concatenation or `fmt.Sprintf` from input (injection). `IN` lists built from possibly empty slices.
- New queries on large tables with no supporting index. Report only when the schema in the repository shows the index is missing.
- Assuming stronger isolation than the database provides (for example, expecting serializable behavior under read committed).

**Finding when:** you can describe concurrent requests, or a failure between two steps, that leaves inconsistent data.

## 7. Retries, idempotency and duplicate processing

- Retrying operations that aren't idempotent (charges, transfers, emails) without passing an idempotency key to the provider.
- Idempotency keys that can be empty, are generated per attempt rather than per logical operation, aren't enforced by a unique constraint, or are checked outside the transaction that writes the result.
- Message consumers: at-least-once delivery without deduplication. Offsets or acks committed before processing (messages lost on a crash) or after it (duplicates, so handling must be idempotent). Poison messages retried forever.
- Webhooks: replays and out-of-order delivery. Missing signature verification.
- Retry loops without backoff, jitter, a maximum number of attempts, or a context check.

**Finding when:** a timeout, crash or redelivery causes a second side effect, or loses one.

## 8. State machines and invariants

- Status transitions not enforced by the write itself (`UPDATE ... SET status = 'captured' WHERE id = $1 AND status = 'authorized'`), which allows illegal transitions or reopening final states.
- A status changed in memory but never saved, or saved before the side effect succeeded.
- New enum or status values that old code (still running during the rollout) or other consumers don't handle.
- Invariants such as "ledger entries sum to zero" or "one active subscription per user" that nothing enforces.

**Finding when:** a concrete sequence of events produces an illegal state.

## 9. Money and numbers

- `float32`/`float64` for money. Converting to minor units with `int64(x * 100)` truncates: 12.34 becomes 1233.
- Integer overflow in multiplication. Negative or zero amounts not checked. Mixing currencies. No stated rounding rule. Fee splits that drop the remainder.

**Finding when:** a specific amount produces a wrong value.

## 10. Validation and security

- New endpoints without authentication or authorization. Object access without an ownership check (IDOR).
- Untrusted input reaching SQL, shell commands (`exec.Command`), file paths (`..` through `filepath.Join`), templates (`text/template` rendering HTML), redirects, or outbound URLs (SSRF).
- Secrets: hardcoded credentials; tokens, secrets or personal data in logs, errors, metric labels or traces.
- `InsecureSkipVerify: true`. `math/rand` for tokens or IDs. Comparing secrets or signatures in non-constant time.
- No request body size limit (`http.MaxBytesReader`) on new endpoints that accept bodies.

**Finding when:** you can describe who can send what input to achieve what.

## 11. Compatibility during rolling deploys and for clients

- **Proto:** fields removed or renumbered without `reserved`; changed field types; renamed packages, services or methods; previously optional fields now required by validation.
- **JSON:** renamed tags, changed types, new required request fields, changed error or status codes.
- **Database:** dropping or renaming columns or tables that the currently deployed version still uses; new `NOT NULL` columns without a default that old code doesn't write.
- **Events:** payload changes that consumers can't parse; renamed topics; key changes that affect partitioning or ordering.
- **Config:** renamed environment variables with no fallback; changed defaults; new required settings that make startup fail when missing.

**Finding when:** old and new versions, or old clients, running side by side produce errors or wrong data.

## 12. Tests

- New behavior or failure paths with no test. Tests that don't assert the important outcome. Table tests missing edge cases (zero, empty, duplicate, concurrent).
- Synchronization with `time.Sleep` (flaky). Tests that depend on map iteration order or wall-clock time.
- New concurrency with no test that runs under `-race`.
- Mocks that accept anything and so hide the bug.

Report these under "Test gaps", unless the missing test hides a confirmed defect; then the defect is the finding.
