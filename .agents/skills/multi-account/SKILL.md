---
name: multi-account
description: >-
  Procedure for launching crewmates under a chosen provider account with isolated
  auth, and for rotating across an operator's accounts by quota. Use when one
  operator holds several accounts of a provider and work must be spread across
  them without auth bleed.
metadata:
  internal: true
---

# multi-account

One operator, several accounts per provider (each its own auth), selected per
spawn so quota is spread and credentials never bleed. Registry:
`config/accounts.json` (gitignored). Libs: `bin/fm-accounts-lib.sh` (registry) +
`bin/fm-account-env.sh` (isolation). Full reference: `docs/fleet-addon.md`.

## Isolation is verified, never guessed
Each account declares an `isolation` method that MUST match its harness per
the matrix in `docs/fleet-addon.md` (enforced by `bin/fm-accounts-lib.sh`):
- `config-dir-env` — `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `PI_CODING_AGENT_DIR`
- `config-dir-flag` — cline `--config <dir>`
- `api-key-env` — grok `GROK_API_KEY` / cursor `CURSOR_API_KEY`

## Secrets never touch argv or the registry
api-key accounts store a `key_file` path (a `0600` file in the operator's OWN
home). The key is read into the child's environment at launch — never onto the
command line, never into a log, never into git. `config_dir`/`key_file` must live
under the operator's own home (a foreign `/home/<other>` or `/Users/<other>` is refused).

## Procedure
1. **Prereq (once, on-demand):** `bin/fm-accounts-prereq.sh` to check the CLIs are
   installed (user-scoped; `install` to add missing ones). Then the operator logs
   in each account into its own config dir / key_file (auth is user-only).
2. **Register:** copy `docs/examples/accounts.json` → `config/accounts.json`;
   one entry per account. Validate: `fm_account_validate <name>`.
3. **Pick by quota (optional):** `fm_account_pick <harness>` returns the account
   with the most `quota-axi` headroom (runs quota-axi under each account's
   isolation; ties → first registered; no quota data → first registered).
4. **Supervised spawn (config-dir accounts):**
   `bin/fm-spawn-acct.sh <id> <dir> --account <name> [--model M] [--effort E]`.
   It passes the account's verified harness to `fm-spawn` and exports nonsecret isolation for the canonical launch template.
5. **Direct isolated launch (api-key accounts, or non-supervised):**
   `bin/fm-account-exec.sh <name> <cli> [args]` — reads the key into the child's
   env, then execs.

## Limits (see docs/fleet-addon.md)
- cursor OAuth mode is not per-spawn isolatable → use API-key mode.
- api-key accounts can't go through the supervised `--account` path (would put the
  key on argv) → use `fm-account-exec.sh`.
- `quota-axi` is per-provider (current auth); real two-account quota
  discrimination needs each account separately authed with creds quota-axi reads.
