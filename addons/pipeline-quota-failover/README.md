# pi-quota-failover

Drop-in pi wrapper for the no-mistakes pipeline agent. It runs the real pi and moves to the next chain model when a call hits a quota error or goes silent.

## Pipeline route

Without an account pool the default chain is one route, `claude-bridge/claude-haiku-5-5`: Claude Haiku through claude-bridge. A call pinned to a model outside the chain does not run that model, it runs the chain. `PI_QUOTA_FAILOVER_CHAIN` overrides the chain, and `PI_QUOTA_FAILOVER_PRINT_CHAIN=1` prints it: the chain is the fleet's one route list, and `route-change` reads it from here.

With an account pool (`PI_QUOTA_FAILOVER_ACCOUNT_POOL`, default `~/firstmate/config/account-pool` when it exists), the route comes from `fm-model-pool` pick/next (see `account-pool/README.md`): the eligible Claude account with the greatest runway above the 15% eligibility floor runs as `claude-bridge/claude-haiku-5-5` on that account's folder (credential variables shed). A limit calls `next`, which rests that account when the pool allows and advances; when every Claude account is under the floor the helper order is Codex Sol, then DeepSeek Goat, then Cursor auto. An account limit never marks the whole Claude route dead. When the helper refuses, the call ends with the terminal `quota exhausted` line and never falls back to the default login.

An `openrouter/*` route takes the deepseek idle limit (`PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS`, default 300), not the generic one (default 120), because the floor route answers on the same clock as direct DeepSeek.

## Quota pre-check

Before each route is called, `quota-axi --provider <prefix> --json` is asked about that route's provider. A route whose
`effectiveAvailability` has `runway.status` `exhausted_now` for `all_models` or its own `model:<id>` scope is skipped
without a pi call and gets a quota marker.

Fail-open cases (the route is tried as before, one log line says so):

- `quota-axi` is missing, exits non-zero (for example `error: unsupported provider: <name>` for a pi provider name it does not know) or takes longer than 10s. The wrapper maps the pi provider `openai-codex` to quota-axi's `codex`; other names pass unchanged.
- `jq` is not installed; the pre-check is off for every route.

An answer that is not parseable JSON is treated as not exhausted, without a log line.

## Moving the pipeline agent and route

`switch.sh` moves the no-mistakes pipeline agent, and every pipeline step with it, to one accepted agent and one model. It edits only two keys by name (`agent`, `agent_config.<agent>.model`), leaves every other key, value and comment alone, writes a timestamped backup first and keeps the backup's version when the model does not answer PONG. With neither `--agent` nor `--model`, it asks `fm-model-pool` pick for the route (same floors and Sol/Goat/Cursor order) and maps the harness onto an accepted agent; explicit flags keep a pin. `--dry-run` prints the planned edit and writes nothing; `--restore-latest` puts the last backup back. Never hand-edit the live config except through this script.

## Idle watchdog

A pi call that writes no stdout and no stderr for `PI_QUOTA_FAILOVER_IDLE_SECS` (default 120; `PI_QUOTA_FAILOVER_BRIDGE_IDLE_SECS`, default 300, for `claude-bridge/*` models; `PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS`, default 300, for `deepseek/*` models) is ended with TERM to pi
and its descendants, then KILL of the same set after a 5 s grace. A stall is not a quota error: the chain moves on to the next model for that
call only and writes no quota marker, so the stalled route is tried again on the next call. A stall on the last route is retried up to `PI_QUOTA_FAILOVER_STALL_RETRIES` times (default 3, four calls total) before the call fails. Only a real quota error
(or quota-axi `exhausted_now`) writes a marker. Quota errors are matched by `QUOTA_RE`: pi's own terminal phrasings plus the balance and rate-limit texts that Z.AI (`Insufficient balance or no resource package`, `Rate limit reached for requests`) DeepSeek (`Insufficient Balance`) and OpenRouter (`402 ... requires more credits ... can only afford`) return, so those move on to the next hop instead of ending the run. pi stays in the wrapper's process group, so a group kill of the wrapper
reaches it.

The watch starts at the call's first byte, with no separate start limit. Before the extension change below, the silence
between pi's session header and `agent_start` was 5 s to 134 s on this host (pi-hermes-memory's sync: 91.5 s with no
prompt, 5.0 s with five other pi processes alive), so the 120 s watch killed those starts. Now it is about 1 s (session
header 1.0 s after pi starts, `agent_start` 82 ms later; measured 2026-10-18).

## Extensions

Every call runs `pi -ne` plus `-e <path>` for each extension pi would load here, except `pi-hermes-memory` (dropped by its
package source, `npm:pi-hermes-memory`, because its `session_start` sync ran before `agent_start`). The set is read at
call time from `pi list` (user packages and their manifests), the user extensions dir (`fm-rm-guard` and
`fm-literal-delete` load there), the settings `extensions` array and pi's built-ins, minus any `-builtin:<name>` in the
settings. If the list cannot be read, pi runs as before and one log line says why.

Not included: project-level `.pi/extensions/`. pi loads those only for a trusted project, and `pi list` reports user
packages only, so a pipeline call run from a trusted checkout that has them loses them under `-ne`. The firstmate
checkout does (`fm-calm`, `fm-branch-supervision`).

## Route failures and credit probe

A pi exit that is non-zero and whose error surface names a Go `WaitDelay` / `parse events` failure or an extension
warning or failure is a route failure: the chain moves to the next route for that call, with no quota marker (like a
stall). Before the first route is run, a 1-request probe (the real pi, one `ok` prompt, `PI_QUOTA_FAILOVER_PROBE_SECS`
cap, default 60) skips a route whose answer is a balance error, marks it dead and logs a `pulse:` line.
`PI_QUOTA_FAILOVER_PROBE=0` turns the probe off.

## Daemon environment caveat

The OpenRouter key that route needs lives only in the systemd user manager environment: it was imported with
`systemctl --user import-environment` and is not copied into any file. It survives a daemon restart, but not a reboot
or a systemd manager restart. After either, re-import it from `~/.config/openrouter/api_key` before starting the
daemon, or install a start-time reader that does not copy the key into a file. Never print the key and never copy it
into a file.
