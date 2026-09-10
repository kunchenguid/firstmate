---
name: revocall-e2e-provision
description: >-
  Provision an isolated local docker stack for one named end-to-end test scenario across the RevoCall-family repos (RevoCall, RevoCall-AI-Handler, Conversational-AI-Framework/RevCAF), seeded with only the data that scenario needs.
  Use before running any local end-to-end test, integration test, or live driving session that needs a database, Redis, NATS, Qdrant, MinIO, or one of the services, and whenever a test skips because DATABASE_URL or TEST_DATABASE_URL is unset.
  Names every container after the task that owns it, so `docker ps` alone answers who provisioned it, and records what it started so `revocall-e2e-teardown` can reverse exactly that.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone: it must work with no firstmate home present, deriving its identity from --task when FM_TASK_ID is absent and treating bin/fm-e2e-stack.sh as an optional durable mirror. The firstmate-coupled half is bin/fm-e2e-stack.sh plus Fix 4 in bin/fm-teardown.sh. -->

# revocall-e2e-provision

Bring up the smallest local stack one named test scenario needs, seed only that scenario's data, and leave a record precise enough that cleanup never has to guess what you started.

Its companion is `revocall-e2e-teardown`.
Provision and cleanup are one pair: never provision without knowing how the stack will come down.

## Why the identity discipline matters

Three defects in the RevoCall-family compose files make an unmanaged local stack anonymous and unrepeatable.

- Most compose files declare no top-level `name:`, so the compose project name falls back to the directory basename.
  `admin/backend/docker-compose.yml` becomes project `backend` and yields containers called `backend-postgres-1`; `outbound/service/docker-compose.yml` becomes project `service`.
  Nothing in those names says which task, repo, or test owns them.
- `Conversational-AI-Framework/docker-compose.yaml` and `RevoCall-AI-Handler/services/ai-handler/docker-compose.yaml` hardcode `container_name:` (`revcaf-db`, `revocall-ai-handler-db`, and so on).
  A hardcoded container name survives `docker compose -p`, so two stacks of the same repo cannot run at once and the project name never reaches `docker ps`.
- Host ports are literals in every per-service compose file.
  `admin/backend`, `chat`, and `forwarder` all bind 5432; `outbound/service` and `mcp-gateway` both bind 5433; `warehouse`'s ClickHouse binds 9000, which is MinIO's port in the shared deploy stack.
  `deploy/README.md` manages this with a comment telling you not to run them together.

This skill fixes all three from outside the repos, so no project file is ever modified.

## Inputs

| Input | Required | Meaning |
|---|---|---|
| `--repo <name>` | yes | `RevoCall`, `RevoCall-AI-Handler`, or `Conversational-AI-Framework`. |
| `--scenario <name>` | yes | The test scenario being provisioned for. Keys the seed step and labels the containers. |
| `--profile <name>` | yes | A row of `references/profiles.md`. Decides which services come up and which schema and seed steps run. |
| `--task <id>` | when `FM_TASK_ID` is unset | The owning task id. Refuse rather than invent one: the whole identity chain hangs off it. |
| `--checkout <path>` | for cross-repo profiles | Root whose children are the three repos. Only `revocall-full` needs it. |
| `--port-base <n>` | no | Overrides the derived port offset. Escape hatch for a collision the probe cannot resolve. |

## Identity scheme

Derive everything from the task id, once, and use it consistently.

```
TASK      = $FM_TASK_ID, or --task
STACK     = the profile's short name (revcaf, aih, revocall)
PROJECT   = fm-<TASK>-<STACK>
CONTAINER = <PROJECT>-<service>
NETWORK   = <PROJECT>_default, or NET_NAME=<PROJECT> for the RevoCall deploy stack
VOLUMES   = <PROJECT>_<volume>, or revocall-infra_<volume>-data-<TASK> for the deploy stack's external volumes
```

The `fm-` prefix is load-bearing, not cosmetic.
Cleanup will only remove a project whose name starts with it, which is what makes it impossible to remove a stack a person or another tool started.

Attach all six labels to every service:

| Label | Value |
|---|---|
| `ai.revolab.fm.task` | the task id |
| `ai.revolab.fm.stack` | the profile's short name |
| `ai.revolab.fm.repo` | the repo name |
| `ai.revolab.fm.scenario` | the scenario name |
| `ai.revolab.fm.created` | RFC-3339 UTC timestamp |
| `ai.revolab.fm.worktree` | absolute path of the checkout this ran from |

The project name is what makes ownership readable from a bare `docker ps`.
The labels are what make cleanup a precise filter and give a later reader the age and purpose without reading container logs.
Carry both; neither replaces the other.

## Steps

1. **Preflight.**
   Confirm `docker info` answers and `docker compose version` is 2.20 or newer, because the override file below needs the `!override` tag.
   Resolve the task id, and stop if neither `FM_TASK_ID` nor `--task` supplies one.
   Read the profile row from `references/profiles.md` and confirm every file it names exists in the checkout.

2. **Derive ports.**
   Take `k` as `1 + (crc32(<task id>) mod 20)` and use `k * 300` as the offset, which is the multiples-of-300 convention `RevoCall/deploy/SLOTS.md` records as verified safe.
   For the RevoCall deploy stack, do not compute the ports yourself: run `deploy/gen-slot-env.sh --slot <short-slug> --offset <k*300>` and use its output verbatim.
   That generator already emits every `PORT_*`, `LK_UDP_RANGE`, `VOL_SUFFIX`, `NET_NAME`, `IMG_SUFFIX`, and `COMPOSE_PROJECT_NAME`, and it already refuses an unsafe offset before bring-up.
   Its `--slot` argument must match `^[a-z0-9]+$`, so pass a sanitized short slug rather than a hyphenated task id.
   For the two AI repos, whose compose files carry no `PORT_*` variables, compute `default + k*300` per published port.

3. **Probe the ports, and do not trust a free one blindly.**
   Check each derived port with `lsof -nP -iTCP:<port> -sTCP:LISTEN` and shift the offset by one stride on a collision, up to a few attempts, then stop and name the busy ports.
   A port with no listener is still not always safe: an orphaned application process from an earlier test can be dialing that exact port on a retry loop and will attach the instant something binds it.
   Prefer a stride far from both the documented defaults and the known live-test offsets, and see step 8 for the check that catches an unexpected client.

4. **Generate the override compose file.**
   Write it under the task's own temporary root, never into the checkout.
   `/tmp/fm-<task>/e2e/override.<stack>.yml` is the location when a firstmate task tmp root exists; otherwise any private scratch directory outside the repo works.

   ```yaml
   services:
     db:
       container_name: fm-<task>-<stack>-db
       ports: !override
         - "<derived>:5432"
       labels:
         ai.revolab.fm.task: <task>
         ai.revolab.fm.stack: <stack>
         ai.revolab.fm.repo: <repo>
         ai.revolab.fm.scenario: <scenario>
         ai.revolab.fm.created: "<rfc3339>"
         ai.revolab.fm.worktree: <abs path>
       environment:
         POSTGRES_DB: revcaf_test
   ```

   **The `!override` tag on `ports:` is load-bearing.**
   Without it compose MERGES the two port lists and still publishes the original literal, so the remap looks right in the file and the bring-up still fails to bind when the default port is taken.
   The same tag applies to `volumes:` when the override must drop a mount the base declares.

   **Write every path in the override absolute.**
   A relative path in an override resolves against the compose PROJECT DIRECTORY, which defaults to the directory of the FIRST `-f` file, not the directory the override itself lives in.
   An override written to a scratch directory therefore silently picks up files from the repo instead, or fails to find them.

5. **Pre-create external resources, for the RevoCall deploy stack only.**
   Its six infra volumes are declared `external: true`, so compose does not create them:
   `docker volume create revocall-infra_<v>-data-<TASK>` for `postgres`, `nats`, `valkey`, `redis-stack`, `qdrant`, and `minio`.
   The task suffix is mandatory, because an unsuffixed name is the shared local development data and cleanup refuses to remove one.

   The NETWORK is different, and pre-creating it unconditionally breaks the bring-up.
   `docker-compose.infra.yml` DECLARES the network, while `ai.yml` and `admin.yml` consume it as `external: true`.
   So create it by hand only when infra is absent from the `-f` chain; with infra present, compose creates it and a hand-made one is refused with `network <name> was found but has incorrect label com.docker.compose.network`.

6. **Record what you are about to start, before you start it.**
   An interrupted bring-up must still be cleanable.
   With firstmate present:

   ```bash
   bin/fm-e2e-stack.sh record <task> \
     --project fm-<task>-<stack> --stack <profile> --repo <repo> \
     --scenario <scenario> --worktree "$PWD" \
     --compose-file <base compose>... --compose-file <override> \
     --service <name>... --port PORT_POSTGRES=<n>... \
     [--external-volume <name>...] [--network <name> --created-network]
   ```

   Standalone, write the same fields to a file beside the override and hand its path to cleanup.
   Either way the record must name every compose file, because cleanup tears down with the recorded list rather than re-deriving it: a repo file edited after provisioning must not change what comes down.

7. **Bring up only the services the scenario needs.**

   ```bash
   docker compose -p fm-<task>-<stack> \
     -f <base compose> [-f <more base compose>] -f <override> \
     up -d <service>...
   ```

   Wait on healthchecks, or poll `pg_isready`, with a bounded timeout.
   Report the ports actually published, not the ones requested.

8. **Apply the schema through the repo's own migration tool.**
   The profile row names it.
   Never hand-write DDL and never substitute a metadata `create_all`: RevCAF's own integration fixture records that `create_all` reproduces every table but not the `assistant_config` trigger that lives only in a migration, which makes real code fail against a fake schema.
   Then confirm the only clients on the scenario database are your own:

   ```bash
   docker exec -i fm-<task>-<stack>-db psql -U <user> -d postgres \
     -tAc "select pid, datname, client_addr, backend_start from pg_stat_activity where backend_type='client backend'"
   ```

   An unexpected client is an orphaned process from an earlier test; stop and report it rather than seeding into a database something else is reading.

9. **Seed the scenario, and only the scenario.**
   See "Seeding" below.

10. **Hand back the environment and the cleanup command.**
    Emit an exportable block with `DATABASE_URL`, `TEST_DATABASE_URL`, `REDIS_ADK`, `QDRANT_URL`, `NATS_URL`, and any `E2E_BASE_URL`, `E2E_EMAIL`, `E2E_PASSWORD` the scenario needs.
    Then print the cleanup command as the final line, because a worker that copies one line cleans up far more reliably than one that reconstructs a compose invocation.

## Seeding

Seed in three layers, and apply only as many as the scenario needs.

1. **Schema.**
   Always the repo's own tool: `golang-migrate` per database for RevoCall, `alembic upgrade head` for RevCAF and AI-Handler.
2. **Baseline reference data.**
   Only RevoCall has any: `cmd/seed_user_management`, `cmd/seed_tiers`, and `cmd/seed_superadmin <email> <password>`, all built on the transactional `internal/seed` runner.
   RevCAF and AI-Handler have no baseline seeder, and none should be invented for them.
3. **Scenario delta.**
   A single SQL file under `scenarios/<repo>/<scenario>.sql`, applied through the running container:

   ```bash
   docker exec -i fm-<task>-<stack>-db psql -U <user> -d <db> -v ON_ERROR_STOP=1 -q \
     < scenarios/<repo>/<scenario>.sql
   ```

   `-v ON_ERROR_STOP=1` is required.
   Without it psql continues past a failed statement and still exits 0, so a broken fixture reports success.

Four rules keep the delta layer fitting the repos rather than fighting them.

- **Use the `ZZ-<SCENARIO>-<Entity>` naming namespace for every row a RevoCall scenario inserts.**
  That is this repo's own established convention across dozens of `*_db_test.go` files, and it makes a scenario's rows recognizable, deletable by prefix, and safe if the database is ever shared.
  Pair it with `ON CONFLICT` so re-provisioning is idempotent.
- **Reference the fixed role UUIDs rather than looking them up by name.**
  `admin/backend/internal/seed/roles/roles.go` pins them: ORGADMIN `019400a0-0000-7000-8000-000000000001`, ADMIN `...002`, SUPERADMIN `...003`, LIVEAGENTMANAGER `...004`, LIVEAGENT `...005`, MAKER `...006`, CHECKER `...007`.
- **Where a repo already expresses the scenario as a test fixture, satisfy that fixture's contract instead of duplicating it.**
  For RevCAF's `tests/integration`, the whole seed is: create a database whose NAME differs from the application's, hand it over as `TEST_DATABASE_URL`, and let the repo's own `pg_schema` and `seeded` fixtures do the rest.
  A SQL twin of an in-repo fixture drifts from it.
- **Every scenario file declares its own preconditions in a header comment**: which layers it assumes, which services must be up, and which database it targets.
  Validate those before applying rather than failing halfway through.

## Refusals

Stop and report rather than proceeding when any of these holds.

- No task id from either `FM_TASK_ID` or `--task`.
- `docker info` does not answer, or compose is older than 2.20.
- A derived port stays busy after the retry stride.
- A cross-repo profile whose sibling checkouts are absent.
- A `*-full` profile whose required `config.development.ini` or `config.toml` is missing, since those files are gitignored and a fresh checkout has none.
  Starting the container anyway produces a boot loop that reads as a code failure.
- An unexpected client already connected to the scenario database.
- A scenario naming a database that matches the application's own database name, for RevCAF specifically.
  Its integration fixture drops the `public` schema and refuses a same-name URL, because that exact mistake once destroyed a developer's `revcaf_db`.

## One dimension this cannot isolate

LiveKit.
Two stacks sharing one LiveKit Cloud project cross-route calls, because the agent names are hardcoded in AI-Handler and workers register to a project rather than to a key.
The credentials are also read from a mounted `config.development.ini` or `chat/config.toml`, not from an environment variable, so the override file cannot inject them.
A LiveKit-touching scenario is therefore not concurrency-safe: serialize it, or require an explicitly named distinct LiveKit project, and say plainly in the report which was done.

## Reference

`references/profiles.md` owns the per-profile service, schema, and seed table plus the per-repo differences the profiles encode.
`bin/fm-e2e-stack.sh --help` in a firstmate checkout owns the record format and the ownership gates.
