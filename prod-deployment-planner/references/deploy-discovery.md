# Establishing how the repository is deployed

Goal: a service map where every row cites evidence. Discovery only reads files.

## How strong is the evidence? (strongest first)

1. **Deployment docs and runbooks that explicitly describe production:** `docs/deploy*`, `RUNBOOK*`, `docs/ops/`, a "Deploy" section in README, AGENTS.md or CLAUDE.md.
2. **CD configuration that targets production:** workflow jobs with `environment: production`, deploy steps triggered by tags or `main`, ArgoCD or Flux Application manifests for prod, `values-prod.yaml`, Terraform or Pulumi stacks named for prod.
3. **Infrastructure as code and manifests:** Kubernetes, Helm, Kustomize, Terraform, Pulumi, Nomad, serverless, `fly.toml`, `app.yaml`.
4. **Build configuration only:** Dockerfiles, `.goreleaser.yml`, `ko` config. These show how artifacts are built, not where or how they are deployed.
5. **Local development setups:** docker-compose, Tiltfile, skaffold dev profiles, Makefile `run` targets. These are **not** production evidence unless documentation says production uses them.

If the strongest evidence you have is level 4 or 5, the deployment mechanism is `UNVERIFIED`.

## Evidence that lives outside the repository

Reusable workflows (`uses: org/repo/.github/workflows/x.yml@ref`), actions from other repositories, GitOps deploy repositories, Helm charts kept elsewhere, platform pipelines. Record the reference (file and line) and list it as missing evidence. Don't guess what it does.

## Identifying services

- Each entry in the inventory's `main_packages` block is a candidate binary. `cmd/<name>` is usually a service, worker or CLI. Confirm it with a Dockerfile `ENTRYPOINT`/`CMD`, goreleaser `builds`, manifest `command`/`args`, or documentation.
- One binary can run as several deployments (for example, `server` and `worker` modes via subcommands or flags). Check manifest args and cobra subcommands.
- Tools and one-off commands (`tools/`, `cmd/migrate`, `cmd/seed`) aren't services, but they may be steps in the release.
- Ownership comes from CODEOWNERS or documentation. Otherwise it is unknown.

## Does a service need a new build or deploy?

| Change | Consequence |
|---|---|
| Its main package, or any package it imports, changed | New build and deploy. Transitive imports need `go list -deps` (approval required). Without it, list direct importers with `git grep` and mark the rest `UNVERIFIED`. |
| go.mod or go.sum dependency change | Every binary importing the changed module. Without `go list`, assume all of them and say so. |
| Dockerfile or build configuration | The affected images. |
| Manifest or config only | Rollout of the config, possibly without a new build. |
| Docs or tests only | No deploy. |

## How migrations run: find out, don't assume

Look for:

- **At application startup:** calls in `main`/`cmd` or init code (`migrate.New(...).Up()`, `goose.Up`, gorm `AutoMigrate`, ent `Schema.Create`, a custom runner over an embedded migrations folder). With several replicas, check whether the runner takes a lock.
- **A separate command:** `cmd/migrate`, or a `migrate` subcommand.
- **Orchestration:** Helm hooks (`helm.sh/hook: pre-install,pre-upgrade`), a Kubernetes Job or init container, Argo sync waves or hooks.
- **A CI/CD step** that runs a migration tool.
- **A manual runbook.**
- **Task-runner targets** (`migrate-up`). These show which tool is used, not the production procedure.

Record the mechanism, when it runs relative to the application rollout, who runs it, and the evidence. If you can't find it, mark it `UNVERIFIED` and raise it at Gate C.

## Database engine and version

Driver imports establish the engine: `pgx` or `lib/pq` means PostgreSQL, `go-sql-driver/mysql` means MySQL. The production **version** comes only from documentation or infrastructure code (for example `engine_version` in Terraform). docker-compose image tags are development evidence only.

## Dependencies between services

Evidence that one service depends on another:

- a gRPC client for another service's proto, plus address configuration;
- HTTP base URLs from configuration (`*_URL`, `*_ADDR`, `*_HOST`);
- topic or queue names used by a producer and by a consumer;
- database tables written by one service and read by another;
- manifest environment variables that point at another service's DNS name;
- documentation.

When both ends are in this repository, cite both. When one end is in another repository, cite the end you can see and mark the other `UNVERIFIED`.

## Output: service map

| Service | Entry point | Artifact | Deploy mechanism | Changed in release? | Needs deploy? | Evidence |
|---|---|---|---|---|---|---|
