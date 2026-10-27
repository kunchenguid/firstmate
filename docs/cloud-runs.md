# Cloud runs

`bin/fm-cloud.sh` is the default command for Claude Code cloud sessions: it launches one from the command line, records it, and polls for its result.
Run `bin/fm-cloud.sh doctor` first; it checks that the installed `claude` CLI supports `--cloud` and lists what still needs the web UI.

## Commands

- `launch` runs `claude --cloud` with a prompt argument or `--file`, optionally targeting `--environment <id>` and a `--repo`, and writes one record per run under `state/cloud-runs/`.
- `status` and `list` show the recorded runs; `status` also polls the run's remote for `claude/*` branches that are new since launch, which is where cloud work lands.
- `cleanup <run-id>` retires the record and prints the remaining web-only steps without performing them.

## What stays manual

The cloud environment's network allowlist and environment variables, and Tailscale key minting, have no CLI.
Drive them in the browser per runbook `runbooks-e8k`, then run `cleanup` and remove the key, revoke it, and restore network access when the run is over.

## Secrets

The tool never prints, logs, or stores a key, token, or environment value, and it stores only the prompt's length and hash.
`bin/fm-cloud.sh`'s header owns the record fields and exact flags.
