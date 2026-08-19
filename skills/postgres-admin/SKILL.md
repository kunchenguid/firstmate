---
name: postgres-admin
description: >-
  Safe PostgreSQL administration with psql, pg_dump, and pg_restore: role separation,
  least-privilege grants, default privileges, administrative dumps, isolated restore tests,
  and backup verification.
  Use before any PostgreSQL administration, backup, or restore operation.
---

<!-- maintainers: public installer-facing skill. Procedure owner for both firstmate and project workers. Firstmate loads `.agents/skills/postgres-admin/SKILL.md`, a stub that points here. -->

# postgres-admin

This skill covers safe PostgreSQL administration for application databases.
It enforces role separation, least privilege, isolated restore testing, and credential boundaries.
Project-specific role names, database names, stage names, and Job names belong in the project repository, not in this skill.

## Current-source discovery

Never memorize flags or claim subcommands this install does not support.
Before operations, consult the installed tools:

```sh
psql --version
pg_dump --version
pg_restore --version
pg_dump --help
pg_restore --help
```

Tool help is authoritative for the current version.

## Installation

Copy or link this directory into a project worker's skill discovery path:

- `.agents/skills/postgres-admin/` (recommended)
- `.claude/skills/postgres-admin/` (Claude Code)

From the firstmate repository, the source path is `skills/postgres-admin/`.
Installers such as [skills.sh](https://skills.sh) can add the same directory from the published firstmate repo.

The bundled helper is `scripts/pg-safe.sh` relative to this skill directory.

## Project AGENTS.md trigger

Add this exact line to the project's always-loaded agent instructions (for example `AGENTS.md`):

```md
- `postgres-admin` - load before any PostgreSQL administration: creating or altering roles, schema ownership, grants and default privileges, `pg_dump`/`pg_restore`, backup or restore Jobs, or any psql statement that changes database state.
```

## Bundled helper

Use `scripts/pg-safe.sh` for role-attribute checks, dump verification, restore-target guards, and grant inspection.
It never prints passwords, connection strings, or secret material.

```sh
HELPER="<skill-dir>/scripts/pg-safe.sh"
"$HELPER" role-attrs <ROLE>
"$HELPER" dump-verify <DUMP_FILE>
"$HELPER" restore-guard <ALLOWED_TEST_DB> <TARGET_DB>
"$HELPER" grant-check <ROLE> <SCHEMA>
```

`role-attrs` reports `rolsuper`, `rolcreatedb`, `rolcreaterole`, and related flags without secrets.
`dump-verify` requires a non-empty file, recognizes plain SQL or custom-format dumps, and prints `size=` and `sha256=` only.
`restore-guard` allows restore only into the declared test database unless live restore was explicitly authorized outside chat.
`grant-check` lists effective table grants for a role and schema, redacting any credential-shaped output.

## Role separation

Keep three roles distinct in every environment:

- **Application role** runs the workload.
  It receives DML through grants and default privileges.
  It must not own schemas, create objects, or hold superuser privileges.
- **Migration role** owns the application schema.
  It holds `CREATE` on that schema and runs DDL during migrations.
  It must be `NOSUPERUSER`, `NOCREATEROLE`, and `NOCREATEDB`.
- **Administrative role** performs backups and isolated restore tests.
  It can connect, dump, and restore into the dedicated test database.
  It must not own or drop the live application database.

Before creating or altering roles, run `"$HELPER" role-attrs <ROLE>` and record the attributes.
Refuse to proceed when a role has unexpected superuser, createdb, or createrole privileges.

Role or schema mutation requires current explicit task authority naming the role, schema, and intended privilege change.
Never broaden privileges "for convenience".

## Schema ownership and default privileges

The migration role owns the application schema.
Ownership means it can create and alter objects in that schema.
The application role receives only the privileges it needs to run the workload.

After creating objects as the migration role, set default privileges so future tables and sequences grant the application role the required DML without repeating grants manually.
Verify effective grants with `"$HELPER" grant-check <APP_ROLE> <SCHEMA>` after changes.

Schema ownership transfer, default-privilege changes, and grant changes are mutating operations.
They require explicit task authority naming the schema and roles involved.

## Credential boundary

Connection credentials come from Kubernetes Secrets, a secret manager, or another trusted channel configured outside chat.
Prefer environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`) and a `.pgpass` file or secret-manager injection the child process reads directly.
When Bitwarden Secrets Manager is in use, load the `bws` skill and inject credentials through `bws run --project-id <id> -- <trusted-command>` so values never enter chat or tool arguments.

Never print passwords, `PGPASSWORD`, connection URIs, or `kubectl get secret` values.
Never ask the captain or operator to paste credentials into chat.
Never commit credentials, rendered connection strings, or CLI output that contains secrets.
Mount administrative credentials only into backup or restore Jobs, never into application pods.

## Safe psql

Use read-only inspection before any mutating statement.

Read-only examples:

```sh
psql -v ON_ERROR_STOP=1 -c '\du+'
psql -v ON_ERROR_STOP=1 -c '\dn+'
psql -v ON_ERROR_STOP=1 -c "SELECT * FROM information_schema.role_table_grants WHERE grantee = '<ROLE>';"
```

Mutating statements include `CREATE`, `ALTER`, `DROP`, `GRANT`, `REVOKE`, `TRUNCATE`, and `DELETE` without a narrow, authorized predicate.
They require explicit task authority naming the database object and the intended change.
Run `"$HELPER" role-attrs` and `"$HELPER" grant-check` before and after privilege changes when verification is possible.

Prefer `-v ON_ERROR_STOP=1` so a failed statement aborts the session instead of leaving a half-applied change.
Never run ad hoc DDL against production without named authority.

## Administrative dumps

Administrative dumps use `pg_dump` with `--no-owner` and `--no-acl` so restores do not replay ownership or privilege metadata from the source cluster.

```sh
pg_dump --no-owner --no-acl -Fc -f backup.dump <DATABASE>
pg_dump --no-owner --no-acl -f backup.sql <DATABASE>
```

Verify every dump before treating it as valid backup evidence:

```sh
"$HELPER" dump-verify backup.dump
```

Success is a zero exit code with non-zero `size=` and a `sha256=` checksum.
Never verify a dump by printing or searching its data contents in chat.
Store checksums in task notes or backup metadata without secret material.

## Isolated restore tests

Routine restore testing targets only a purpose-built test database, never the live application database.
Choose a dedicated test database name in project-local policy and pass it to `restore-guard` before every restore.

```sh
"$HELPER" restore-guard <ALLOWED_TEST_DB> <TARGET_DB>
pg_restore --no-owner --no-acl -d <TARGET_DB> backup.dump
```

`restore-guard` exits 0 only when `<TARGET_DB>` matches `<ALLOWED_TEST_DB>`.
Any other target is refused unless an operator sets `PG_SAFE_LIVE_RESTORE_AUTH=yes` outside chat after explicit captain or operator authority for live restore.

After restore, run application-level smoke checks or schema counts against the test database only.
Drop the test database contents or recreate the test database when the test finishes if project policy requires it.

## Backup verification

A backup is verified when all of the following hold:

1. `pg_dump` exited zero with `--no-owner` and `--no-acl`.
2. `"$HELPER" dump-verify` reports `status=ok` with non-zero `size=` and a recorded `sha256=`.
3. An isolated restore into the test database completes with exit code zero.
4. Post-restore checks appropriate to the workload pass on the test database only.

Record verification outcomes as metadata (timestamp, checksum, test database name, pass or fail) without dump contents or credentials.
A failed verification is a blocker; do not treat the backup as restorable until the failure is resolved.

## Destructive authorization

The following actions require current explicit captain or operator authority naming the exact target:

- Dropping a database or role.
- Live restore into the application database or any database outside the declared test database.
- Bulk data removal (`TRUNCATE`, unqualified `DELETE`, or table drops) in production.
- Transferring schema ownership away from the migration role without a documented rollback plan.

Refuse when authority is missing, ambiguous, or broader than the named target.
Never drop the live application database as part of routine restore testing.

## Never commit secrets

Never commit passwords, connection strings, `.pgpass` files, rendered Secrets, or captured CLI output that contains credentials.
Redact before saving command transcripts or diagnostics.
