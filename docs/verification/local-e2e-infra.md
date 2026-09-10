# Local end-to-end infrastructure verification

Audience: maintainer verification.

This record supports the active guarantees behind [`bin/fm-e2e-stack.sh`](../../bin/fm-e2e-stack.sh) and the crew-facing [`revocall-e2e-provision`](../../skills/revocall-e2e-provision/SKILL.md) and [`revocall-e2e-teardown`](../../skills/revocall-e2e-teardown/SKILL.md) pair.
Those files own the record format, the ownership gates, and the procedure; this record holds only the empirical container-runtime facts they depend on, each of which a runtime release could change.
Refresh it with the commands below, and refresh the ownership-gate and removal coverage with `bash tests/fm-e2e-stack.test.sh` plus the three Fix 4 cases in `tests/fm-teardown.test.sh`.

Checked on 2026-09-10 with Docker 29.4.0 (build 9d7ad9f) and Docker Compose v5.1.2 on macOS 24.6.0, arm64, OrbStack.

## `-p` overrides a compose file's own `name:`, but never its `container_name:`

The identity scheme depends on the first half and works around the second.

```
$ cat base.yml
name: myproject
services:
  db: { image: postgres:17-alpine, container_name: fixed-db-name, ports: ["5432:5432"] }

$ docker compose -f base.yml config | head -1
name: myproject
$ docker compose -p rvtest -f base.yml config --format json | jq -r .name
rvtest
$ docker compose -p rvtest -f base.yml config --format json | jq -r '.services.db.container_name'
fixed-db-name
```

The surviving `container_name` is why the override file must set one explicitly: two stacks of `Conversational-AI-Framework` or `RevoCall-AI-Handler` cannot otherwise coexist, and the project name never reaches `docker ps`.

## `ports:` without `!override` MERGES, leaving the original port published

This is the single most costly detail to get wrong, because the resulting file looks correct.

```
$ cat override-without-the-tag.yml
services:
  db:
    ports:
      - "55432:5432"

$ docker compose -p rvtest -f base.yml -f override-without-the-tag.yml config | grep -A 8 'ports:'
    ports:
      - {target: 5432, published: "5432"}
      - {target: 5432, published: "55432"}
```

With `ports: !override`, only `55432` is published.
The same tag applies to `volumes:` when an override must drop a mount the base declares.

## A relative path in an override resolves against the project directory

An override generated into a scratch directory therefore does not resolve paths relative to itself.

```
$ grep -A 2 'volumes' /tmp/.../override.yml
    volumes: !override
      - ./init-databases.sh:/docker-entrypoint-initdb.d/init-databases.sh:ro

$ docker compose -p fm-rvfam-verify-revocall \
    -f deploy/docker-compose.infra.yml -f /tmp/.../override.yml config postgres | grep -A 3 'volumes:'
    volumes:
      - type: bind
        source: /Users/hng/Worksplace/firstmate/projects/RevoCall/deploy/init-databases.sh
```

The project directory defaults to the directory of the first `-f` file, so the path resolved under `deploy/` rather than under `/tmp`.
Generated overrides must write absolute paths.

## `down -v` does NOT remove an `external: true` volume

This is why the record carries external volume names and why cleanup removes them itself.

```
$ docker volume create fmprobe_ext_vol
$ docker compose -p fmprobe-ext -f ext.yml up -d          # volumes: ext: {external: true, name: fmprobe_ext_vol}
$ docker compose -p fmprobe-ext -f ext.yml down -v
 Container fmprobe-ext-db-1 Removed
 Network fmprobe-ext_default Removed
$ docker volume ls -q --filter name=fmprobe_ext_vol
fmprobe_ext_vol
```

All six of `RevoCall/deploy/docker-compose.infra.yml`'s volumes are declared that way, which is also why gate 4 refuses any whose name carries no task suffix: an unsuffixed name is the shared local development data.

## Compose labels volumes and networks with the project, so the residue check is exact

```
$ docker compose -p fm-<task>-revcaf -f <base> -f <override> up -d db
$ docker volume ls  -q --filter "label=com.docker.compose.project=fm-<task>-revcaf"
fm-<task>-revcaf_db_data
$ docker network ls -q --filter "label=com.docker.compose.project=fm-<task>-revcaf"
fm-<task>-revcaf_default
$ docker compose -p fm-<task>-revcaf -f <base> -f <override> down -v --remove-orphans
$ # containers 0  volumes 0  networks 0
```

`docker volume rm --` and `docker network rm --` both accept the end-of-options separator, which is what lets the removal pass names through safely.

## The network is created by infra, so pre-creating it breaks the bring-up

`docker-compose.infra.yml` declares the network while `ai.yml` and `admin.yml` consume it as `external: true`.

```
$ docker network create fm-rvfam-verify-revocall
$ NET_NAME=fm-rvfam-verify-revocall docker compose -p fm-rvfam-verify-revocall \
    -f deploy/docker-compose.infra.yml -f /tmp/.../override.yml up -d postgres
network fm-rvfam-verify-revocall was found but has incorrect label com.docker.compose.network set to "" (expected: "revocall")
```

Pre-create the network only when infra is absent from the `-f` chain.
The six external volumes still need pre-creation in every case.

## The scenario fixture applies against the real migrated schema and refuses loudly

`skills/revocall-e2e-provision/scenarios/revocall/admin-portal-login.sql` was applied to `RevoCall/admin/backend/db/migrations` at head, brought up through the identity scheme above and migrated with the same `migrate/migrate:latest` image `deploy/docker-compose.admin.yml` uses.

```
$ docker run --rm --network fm-rvfam-verify-revocall \
    -v "$PWD/admin/backend/db/migrations:/migrations:ro" migrate/migrate:latest \
    -path /migrations -database "postgresql://postgres:postgres@fm-rvfam-verify-revocall-postgres:5432/admin?sslmode=disable" up
...
101/u inbound_call_queue (118.160706ms)

$ docker exec -i <container> psql -U postgres -d admin -q < admin-portal-login.sql            # no -v email
exit=3
$ docker exec -i <container> psql -U postgres -d admin -v email="nobody@example.com" -q < admin-portal-login.sql
ERROR:  admin-portal-login: no user with email nobody@example.com; run seed_superadmin first
exit=3
$ docker exec -i <container> psql -U postgres -d admin -tAc \
    "select count(*) from organization where name like 'ZZ-AdminPortalLogin-%'"
0
$ docker exec -i <container> psql -U postgres -d admin -v email="admin@revolab.local" -q < admin-portal-login.sql
exit=0
$ docker exec -i <container> psql -U postgres -d admin -tAc "select u.email, o.name, r.name from ..."
admin@revolab.local|ZZ-AdminPortalLogin-Org|ORGADMIN
$ # re-applied: exit=0, binding rows = 1
```

Three properties this run establishes.
A missing psql variable and an unknown email each abort with a non-zero exit rather than reporting success, which matters because psql's own `\quit` takes no exit code and its default is to continue past a failed statement and still exit 0.
The refused run creates nothing, because the user check runs before the first insert.
Re-application is idempotent, so re-provisioning a scenario is a no-op.
