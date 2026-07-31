---
name: infisical-secrets
description: Agent-only reference for operating this fleet's self-hosted Infisical instance (secrets for service access like the Coolify token, and per-project environment variables). Use before creating, reading, rotating, or syncing any secret, and before wiring a project's CI/deploy pipeline to pull secrets.
user-invocable: false
metadata:
  internal: true
---

# infisical-secrets

Infisical is this fleet's secrets manager: service-access credentials (for example the Coolify API token) and per-project environment variables both live here, not in any repo or `config/` file.
The instance is self-hosted via Coolify at `http://keys.dev.hic2h.com`, verified reachable and healthy (`curl http://keys.dev.hic2h.com/api/status` returns 200).
The `infisical` CLI (v0.43.114 at last check) is already installed and already logged in as the captain's account; `~/.infisical/infisical-config.json` records the domain and vault backend.
Never hand-edit that config file or the keyring.

## Core model

`Organization -> Project -> Environment -> Secret`, with secrets additionally organized into folder paths (`--path=/apps/foo`) within an environment.
A directory is linked to one project via `infisical init`, which writes `.infisical.json`.
That file records project/environment identity only, never secret values, so it is safe to commit to the project's repo.

## Reading secrets

Prefer `infisical run` over anything that writes secrets to disk.
It injects secrets as environment variables directly into a child process and nothing else touches them:

```sh
infisical run --env=dev --path=/apps/firefly -- npm run dev
infisical run --env=prod --path=/apps/backend -- ./scripts/deploy.sh "$PROD_APP_UUID"
```

`infisical export --format=dotenv-export > .env` or `--format=yaml` writes secrets to a real file - only use this when the consumer genuinely requires a file (for example seeding Coolify's own env store, see below), and treat that file exactly like any other secret material: never commit it, delete it once consumed.
`infisical secrets get <name> --env=<env> --path=<path>` reads one secret by name.

## Writing and managing secrets

`infisical secrets set <name>=<value> --env=<env> --path=<path>` creates or updates one secret.
`infisical secrets delete <name> --env=<env> --path=<path>` removes one.
`infisical secrets folders` manages the folder structure within an environment.

## Non-interactive auth (CI, deploy scripts, anything not an interactive captain session)

The logged-in interactive session is a human identity, not something a script should rely on.
For any automation, use a machine identity with universal auth instead:

```sh
export INFISICAL_TOKEN=$(infisical login --method=universal-auth \
  --client-id=<id> --client-secret=<secret> --silent --plain)
```

Then every subsequent `infisical` command in that process picks up `INFISICAL_TOKEN` automatically.
Service tokens (`export INFISICAL_TOKEN=<service-token>`) are the older, project-scoped alternative; prefer machine identities for anything new.
Scope each machine identity to the narrowest project/environment it needs, the same least-privilege discipline the deploy-pipeline plan applies to Coolify's own `deploy`-ability tokens (`data/deploy-pipeline/deploy-pipeline-plan/report.md` section 8.3).

## Coolify integration: no native path exists, two candidate patterns

Checked 2026-07-31: there is no native Infisical-to-Coolify sync (Infisical's own secret-sync integrations cover GitHub, Vercel, AWS, Terraform, and others, but not Coolify; tracked as open requests on both projects' issue trackers, e.g. `Infisical/infisical#1350`, `coollabsio/coolify#7956`).
This is a fact about the ecosystem right now, not a permanent gap - re-check before assuming it still holds.

Two viable patterns until a native integration lands, neither implemented yet:

1. **Runtime pull inside the container.**
   Bake the `infisical` CLI into the image and wrap the container's start command with `infisical run -- <real start command>`, authenticated via a machine identity whose credentials Coolify itself injects as plain env vars.
   Secrets never sit in Coolify's own env store at all.
2. **Push-sync into Coolify's env store.**
   `infisical export --format=dotenv-export` (or targeted `secrets get` calls) feeds `coolify app env sync` (see `data/deploy-pipeline/deploy-pipeline-plan/report.md` section 8.2), run at bootstrap/deploy time from an operator or CI context.
   Coolify's own env delivery stays the runtime mechanism; Infisical is the authoring and audit layer above it.

Which pattern this fleet actually adopts is an open decision for the planned Infisical-plus-Coolify test, not something this skill prescribes.
Pattern 2 fits the existing deploy-pipeline design most naturally (Coolify env vars already the documented runtime-config home), but pattern 1 gives tighter secret scoping per container.
Record the decision and the concrete wiring here once the test settles it.
