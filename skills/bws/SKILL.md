---
name: bws
description: >-
  Safe work with Bitwarden Secrets Manager CLI (`bws`, not password-manager `bw`).
  Use before authentication checks, listing projects or secrets, reading secret values, creating, updating, rotating, or deleting Secrets Manager secrets.
---

<!-- maintainers: public installer-facing skill. Procedure owner for both firstmate and project workers. Firstmate loads `.agents/skills/bws/SKILL.md`, a stub that points here. -->

# bws

Bitwarden Secrets Manager CLI is `bws`.
The password-manager CLI is `bw` and is a different product.
Regular vault logins and personal passwords belong to `bw` or the Bitwarden application, not `bws`.

## Current-source discovery

Never memorize flags or claim subcommands this install does not support.
Before operations, consult the installed CLI:

```sh
bws --version
bws --help
bws secret --help
bws project --help
bws run --help
```

Subcommand help is authoritative for the current version.

## Installation

Copy or link this directory into a project worker's skill discovery path:

- `.agents/skills/bws/` (recommended)
- `.claude/skills/bws/` (Claude Code)

From the firstmate repository, the source path is `skills/bws/`.
Installers such as [skills.sh](https://skills.sh) can add the same directory from the published firstmate repo.

The bundled helper is `scripts/bws-safe.sh` relative to this skill directory.

## Project AGENTS.md trigger

Add this exact line to the project's always-loaded agent instructions (for example `AGENTS.md`):

```md
- `bws` - load before any work with Bitwarden Secrets Manager CLI (`bws`, not `bw`): authentication checks, listing projects or secrets, reading secret values, creating, updating, rotating, or deleting secrets.
```

## Bundled helper

Use `scripts/bws-safe.sh` for probes, metadata listing, duplicate-safe ID resolution, and JSON redaction.
It never prints access tokens or secret values.

```sh
HELPER="<skill-dir>/scripts/bws-safe.sh"
"$HELPER" probe
"$HELPER" list-metadata <PROJECT_ID>
"$HELPER" resolve-id <PROJECT_ID> <KEY>
bws secret get <SECRET_ID> -o json | "$HELPER" redact-json
```

`probe` prints `status=`, `version=`, and `token_present=` only.
Treat `token_present=yes` as "a token or profile may exist", never as proof the token is valid.
Only `status=authenticated` means read access succeeded.
`status=no_token`, `invalid_token`, `forbidden`, `unavailable`, and `indeterminate` are not success.

## Authentication without exposure

Detect install and authentication without exposing the access token.

1. Run `"$HELPER" probe` or `command -v bws` plus `bws --version`.
2. Never print `BWS_ACCESS_TOKEN`, `--access-token`, config file contents, or token-shaped strings.
3. Never ask the captain or user to paste a token or secret into chat.
4. Never commit tokens, secret values, rendered credentials, or CLI output that contains values.

If `probe` reports `no_token` or `invalid_token`, stop and ask the operator to configure `BWS_ACCESS_TOKEN` or a `bws` profile outside chat.
Do not troubleshoot by echoing token material.

## Distinguish failures

| Evidence | Meaning |
| --- | --- |
| `command -v bws` fails | CLI absent |
| `status=no_token` | No usable access token |
| `status=invalid_token` | Token present but rejected |
| `status=authenticated` and read commands succeed | Read access OK for at least one project |
| `status=forbidden` on list | Token valid but lacks project access or is read-only beyond list |
| `resolve-id` exit 1 | Secret key absent in that project |
| `resolve-id` exit 2 | Duplicate secret names; do not mutate by name alone |
| Write command non-zero after explicit authority | Write denied, wrong project, or target mismatch; never report success |

Read-only service accounts succeed at `project list` and `secret list` but fail create, edit, or delete.
Verify writes by exit code and post-change metadata, never by echoing values.

## Safe listing and inspection

List projects and inspect secret metadata without printing values.

```sh
bws project list -o table
"$HELPER" list-metadata <PROJECT_ID>
bws project get <PROJECT_ID> -o json
```

Prefer `-o table` or `list-metadata` for human review.
Default JSON includes values; pipe through `redact-json` before logging or chat.

Preserve identities separately:

- `PROJECT_ID` identifies a project.
- `SECRET_ID` identifies a secret.
- `key` is a human label and may duplicate within a project.

Resolve targets with `"$HELPER" resolve-id <PROJECT_ID> <KEY>` before create, edit, or delete when the key name is known.
When duplicates exist, stop and ask for the exact `SECRET_ID`.

## Reading secret values

Read a secret value only when the task genuinely requires it.

1. Resolve `SECRET_ID` when starting from a key name.
2. Prefer `bws run --project-id <PROJECT_ID> -- <trusted-command>` so the value stays in the child process environment instead of chat or files.
3. If you must call `bws secret get`, never paste the value into chat, logs, command arguments visible to tools, or tracked files.
4. Verify success with redacted metadata (`revisionDate`, `id`, `key`) rather than re-printing the value.

## Creating and updating secrets

Create or update only with current explicit authority naming the project and secret.

1. Confirm `probe` shows `authenticated`.
2. Confirm the service account can write to the named `PROJECT_ID`.
3. Resolve duplicates before create; prefer `secret edit <SECRET_ID>` over ambiguous name-only updates.
4. Create: `bws secret create <KEY> <VALUE> <PROJECT_ID> [--note <NOTE>]`
5. Update: `bws secret edit <SECRET_ID> [--key <KEY>] [--value <VALUE>] [--note <NOTE>] [--project-id <PROJECT_ID>]`
6. Pass values through env vars or stdin wrappers, never through chat or committed files.
7. Verify with `"$HELPER" list-metadata <PROJECT_ID>` or `bws secret get <SECRET_ID> -o json | "$HELPER" redact-json`.
8. A non-zero exit code is failure even when partial output appeared; never report success without verification.

Rotation is an edit of `SECRET_ID` with a new value, then the same redacted verification.

## Deleting secrets

Delete only with explicit, concrete captain or operator authority that names the exact `SECRET_ID` (and project context).

1. Refuse delete requests that name only a key when duplicates may exist.
2. Re-verify identity with `bws secret get <SECRET_ID> -o json | "$HELPER" redact-json` and `projectId`.
3. Run `bws secret delete <SECRET_ID>`.
4. Confirm absence with `resolve-id` exit 1 or metadata listing without that `id`.
5. Never delete to "clean up" without named authority.

## Write-access and scope failures

Handle service-account scope and write-access failures safely.

- Stop on non-zero exit codes from create, edit, or delete.
- Report the concrete failure (forbidden, not found, duplicate) without secret values.
- Do not retry writes with guessed project IDs or names.
- Do not fall back to storing secrets in repo files, `.env` commits, or chat.

## Never commit secrets

Never commit tokens, secret values, rendered credentials, or captured CLI output that contains values.
Redact before saving command transcripts or diagnostics.
