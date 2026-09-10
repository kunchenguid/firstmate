# RevoCall-family local end-to-end stack profiles

Data for `revocall-e2e-provision`.
Every path is relative to its repo's checkout root.

## Profiles

| Profile | Short name | Repo | Base compose files | Services | Schema step | Baseline seed |
|---|---|---|---|---|---|---|
| `revcaf-db` | `revcaf` | Conversational-AI-Framework | `docker-compose.yaml` | `db` | `alembic upgrade head`, or let `tests/integration` build it | none |
| `revcaf-full` | `revcaf` | Conversational-AI-Framework | `docker-compose.yaml` | `db`, `redis-stack`, `qdrant`, `nats`, `app` | `alembic upgrade head` | none |
| `aih-db` | `aih` | RevoCall-AI-Handler | `services/ai-handler/docker-compose.yaml` | `db` | `alembic upgrade head` | none |
| `aih-full` | `aih` | RevoCall-AI-Handler | `services/ai-handler/docker-compose.yaml` | `db`, `redis`, `nats`, `app` | `alembic upgrade head` | none |
| `revocall-admin-db` | `revocall` | RevoCall | `deploy/docker-compose.infra.yml` | `postgres` | `golang-migrate` on `admin`, `chat`, `outbound` | `seed_user_management`, `seed_tiers`, `seed_superadmin` |
| `revocall-admin` | `revocall` | RevoCall | `deploy/docker-compose.infra.yml`, `deploy/docker-compose.admin.yml` | infra plus the Go backends and their init containers | the `*-migrate` init containers | the `admin-seed` init container |
| `revocall-full` | `revocall` | RevoCall | `deploy/docker-compose.infra.yml`, `deploy/docker-compose.ai.yml`, `deploy/docker-compose.admin.yml` | all 26 | every init container | the `admin-seed` init container |

Pick the cheapest profile that answers the question.
`revcaf-db` alone satisfies every test in RevCAF's `tests/integration`, and `revocall-admin-db` satisfies RevoCall's `*_db_test.go` suites.

## Ports

Default published ports, before the offset.

| Service | RevoCall deploy | Conversational-AI-Framework | RevoCall-AI-Handler |
|---|---|---|---|
| Postgres | 5432 | 5433 | 5434 |
| NATS client / monitor | 4222 / 8222 | 4223 / 8223 | 4222 / 8222 |
| Valkey | 6379 | not present | not present |
| Redis | 6380 (redis-stack) | 6379 (redis-stack) | 6380 (plain redis) |
| Qdrant | 6333 / 6334 | 6333 | not present |
| OTLP receiver | 4317 / 4318 (jaeger) | 4317 / 4318 | 4333 / 4334 |
| MinIO | 9000 / 9001 | not present | not present |
| RevCAF | 9090 / 9093 | 9090 / 9093 | reached over `host.docker.internal` |
| AI Handler | 9091 / 9092 / 9998 | not present | 9091 / 9092 / 9998 |

`RevoCall/deploy/SLOTS.md` holds the full table of about 31 `PORT_*` variables that `deploy/gen-slot-env.sh` shifts.

## Per-repo differences the profiles encode

Each of these is a real divergence to accommodate, not an inconsistency to normalize away.

1. **Only RevoCall's `deploy/` stack is parameterized.**
   Its three files take `${PORT_*}`, `NET_NAME`, `VOL_SUFFIX`, and `IMG_SUFFIX`, and `deploy/gen-slot-env.sh` generates a safe set with its own collision self-check.
   The two AI repos' own compose files hardcode every port and container name, so their overrides must be fully generated.

2. **`deploy/docker-compose.ai.yml` builds from sibling checkouts.**
   Its build contexts are `../Conversational-AI-Framework`, `../RevoCall-AI-Handler/services/ai-handler`, and `../RevoCall-AI-Handler/services/post-call`.
   `revocall-full` therefore needs a `--checkout` root whose children are all three repos, and must refuse rather than silently build the wrong tree when a sibling is absent.

3. **Three seeding conventions, one per repo.**
   RevoCall: `golang-migrate` plus Go seeders plus a `ZZ-<TICKET>-<Entity>` row namespace with `t.Cleanup` deletion, gated on `DATABASE_URL` and skipping when unset.
   Conversational-AI-Framework: alembic plus `TEST_DATABASE_URL`-gated pytest fixtures that rebuild the schema per test.
   RevoCall-AI-Handler: in-memory SQLite with `Base.metadata.create_all` and no real-Postgres convention at all.
   A single fixture format would fit exactly one of the three.

4. **RevCAF's destructive-guard contract is unique and must be honored, not worked around.**
   Its `tests/integration/conftest.py` drops the `public` schema, and refuses a `TEST_DATABASE_URL` that resolves to the application's database OR merely shares its NAME on any host or port.
   The recorded reason is that `config.example.ini` says `:5432/revcaf_db` while the real dev database is `:5433/revcaf_db`, the name matched, the guard stood aside, and a developer's database was dropped.
   Provision `revcaf_test` or `revcaf_test_<slug>`, never `revcaf_db`.

5. **RevoCall-AI-Handler's suite is not green on its own default branch.**
   Its `AGENTS.md` records a specific failing count and instructs comparing against a clean-tree run before blaming a change.
   Provisioning success therefore means "the stack is up, migrated, and seeded", never "the tests pass".

6. **Redis is three different things.**
   RevCAF needs `redis/redis-stack-server` with `--notify-keyspace-events KEA` for its JSON and Search modules plus keyspace events.
   AI-Handler needs plain `redis:latest`.
   RevoCall's admin needs `valkey/valkey:8` for login throttling AND redis-stack for RevCAF, on separate ports.

7. **NATS is a three-node cluster in both AI repos' own compose files but a single node in RevoCall's infra.**
   The cluster publishes three times the ports and is unnecessary for most scenarios; default to the single node and let a scenario opt into the cluster.

8. **RevoCall's infra volumes are `external: true`; the AI repos' are plain.**
   External volumes must be pre-created before the first `up`, and compose removes them on no code path, `down -v` included.
   Plain volumes auto-prefix with the project name and are removed by `down -v`.
   That difference is why cleanup removes external volumes by name and refuses any whose name carries no task suffix.

9. **LiveKit cannot be isolated by port or network.**
   Agent names are hardcoded in AI-Handler and workers register to a LiveKit project, so two stacks sharing a project cross-route calls.
   The credentials come from a mounted `config.development.ini` or `chat/config.toml`, not from an environment variable, so no override can inject them.

10. **`config.development.ini` and the Go `config.toml` files are gitignored.**
    A fresh checkout has none, and the `*-full` profiles bind-mount them.
    Check before bring-up: a missing config produces a boot loop that reads as a code failure.

11. **Two machine tokens are boot-fatal for the admin stack.**
    `adminv2_machineauth_chat_token` and `adminv2_machineauth_outbound_token` must equal the `chat` and `outbound` entries in `admin/backend/config.toml`'s `[adminAPI.machineKeys]`, or `chat-backend` and `outbound-service` refuse to boot rather than failing at first call.
    They are injected as environment variables because the config files are gitignored.

12. **The composed project name comes from the LAST `-f` file's own `name:` unless `-p` is given.**
    Stacking infra, ai, and admin yields project `revocall-admin`.
    Always pass `-p`.

13. **`services/post-call` has no compose file of its own.**
    It exists only inside `deploy/docker-compose.ai.yml`, so an AI-Handler-only profile cannot bring it up.

14. **`scripts/` is absent from AI-Handler's container image.**
    Its `Dockerfile` copies `src/`, `tests/`, and `assets/` only, so a script-based seed runs on the host with `CONFIG=` and `PYTHONPATH=.`, or through psql.

15. **`warehouse`'s ClickHouse binds 9000, which is MinIO's port in the deploy infra stack.**
    Never provision both in one scenario without an offset.

## Named scenario targets

Real suites a profile has to satisfy.

| Suite | Profile | Gate | Extra requirement |
|---|---|---|---|
| `Conversational-AI-Framework/tests/integration` | `revcaf-db` | `TEST_DATABASE_URL`, skips when unset | database name must differ from the application's |
| `Conversational-AI-Framework` tests marked `local_only` | `revcaf-full` | the `local_only` marker | Redis, Qdrant, NATS, or a live model |
| `RevoCall` `admin/backend/**/*_db_test.go` | `revocall-admin-db` | `DATABASE_URL`, skips when unset | `ZZ-` prefixed rows only |
| `RevoCall/admin/frontend` Playwright specs | `revocall-full` | `E2E_BASE_URL`, `E2E_EMAIL`, `E2E_PASSWORD` | a user WITH an organization, see below |

The Playwright suite's `e2e/auth.setup.ts` asserts a selected organization after sign-in, and the committed seed chain cannot produce one: `cmd/seed_superadmin` inserts `user_role_organization` with `organization_id = NULL`.
`SLOTS.md` records the same gap from the other side, noting that the superadmin organization and its `ORGADMIN` binding are applied by a staging manifest and do not carry over per slot.
`scenarios/revocall/admin-portal-login.sql` fills that gap.
