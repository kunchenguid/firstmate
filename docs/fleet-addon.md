# FirstMate Fleet add-on — federated multi-operator + multi-account

Two general, reusable optional capabilities in FirstMate:

1. **Federated / multi-operator mode** — several OS operators (each their own
   first mate, own accounts), coordinating through a shared, cross-uid-safe,
   data-only KB with atomic claim/lock, scope routing, cross-operator handoff,
   TTL reap, and a realtime `fleet view`.
2. **Per-spawn multi-account** — a `--account` axis that launches a crewmate under
   a chosen account with isolated auth, plus quota-aware account selection.

The main owner surfaces are `bin/fm-fleet*.sh`, `bin/fm-account*.sh`,
`bin/fm-accounts*.sh`, `bin/quota-*`, `scripts/fleet-root-prereq.sh`,
`.agents/skills/{federation,multi-account}/`, and `tests/federation/*.sh`.
Existing spawn, backend, bootstrap, and configuration paths carry the narrow integration points that make the feature usable from the normal FirstMate flow.

---

## Part A — Federated multi-operator

### Why a new model
FirstMate today propagates prefs by **filesystem copy from main into secondmate
homes**. That breaks across uids (it would require writing another user's home).
The add-on uses a **shared-dir + read/claim** model instead: operators share only
a group-writable, data-only KB and **never write each other's private homes**.

### Shared KB (`$FM_FLEET_DIR`, default `/opt/agents/fleet`)
- `operators.md` — `| operator | scope | home | accounts | status | seen | quota |`
- `projects.md`  — `| project | owner | path |`
- `backlog.md`   — `## Queued / ## Claimed / ## In-flight / ## Done`; item line:
  `- [id:<ID>] scope:<S> | <desc> | [claimed-by:<op>@<ISO8601>] status:<st>`.
  `<ID>` is the KB's primary key — `claim`, `handoff` and `reap` each address one
  item by it — so `queue` refuses (non-zero) an id already in the backlog instead
  of writing a second line under the same key
- `events.log`   — append-only TSV `<ISO8601>\t<op>\t<event>\t<id>\t<detail>`
- `locks/backlog.lock` — the `flock` target for atomic claims

Fleet dir resolves from: `FM_FLEET_DIR` → `$FM_HOME/config/fleet-dir` →
`/opt/agents/fleet`. During development it points at a local dir so every code
path is exercised single-uid; `flock` semantics are identical across uids.

### CLI (`bin/fm-fleet.sh`, libs `bin/fm-fleet-lib.sh` + `bin/fm-fleet-quota-lib.sh`)
`preflight | admiral | init | register | heartbeat | leave | queue | claim |
handoff | drain | reap | route | budget | quota | models | pick | status |
view`, plus `bin/fm-fleet-join.sh` (operator onboarding) and
`bin/fm-fleet-wait.sh` (token-free wait-for-work).
`bin/fm-fleet-quota-lib.sh` is a leaf library sourced by `bin/fm-fleet-lib.sh`
that owns `budget | quota | models | pick`; every consumer keeps sourcing only
`bin/fm-fleet-lib.sh`.

- **Atomic claim** — under `flock`, verify item is `queued`, stamp
  `claimed-by:<op>@<ts> status:claimed`, move to `## Claimed`, log the event. Two
  operators can never grab the same item (proven by a concurrent race test).
- **Routing** — `route <scope>`: scope-primary (the online operator whose scope
  contains it), then the `overflow`-scoped operator, then any eligible operator
  with headroom when neither of those can take the task.
- **Reap** — requeue stale `status:claimed` items older than a TTL (offline
  operators' never-started work); `status:in-flight` is left alone.
- **Drain** — reassign a claimed item away from a drained holder when another
  eligible operator has headroom, capped by `FM_FLEET_HANDOFF_CAP`, otherwise
  mark the item `status:drained` with a "fleet out of tokens" event.
- **Visibility** — `status` (per-operator counts) + `view [--follow]` (the live
  cross-operator event stream).

### Per-surface pace (quota-axi >= 0.1.15, `schemaVersion` 3)
`fm-fleet.sh quota` shows two extra columns, `PACE` and `RESERVE`, alongside the
existing `HEADROOM`: `SURFACE HEADROOM PACE RESERVE STATUS SOURCE NOTE`. Pace
answers the question raw headroom hides — "how much of the window's clock is
left" — via `reservePercentPoints = percentRemaining − timeRemainingPercent`.
`RESERVE` is always **signed** (`-15`, `+20`); negative means usage is running
**ahead** of reset pace (conservation pressure), positive means **behind**
(sustainable).

Three states stay distinguishable everywhere pace is reported — never conflate
them, and never render `unknown` as `on_pace`:

| Rendered | Meaning |
|---|---|
| `behind` / `on_pace` / `ahead` / `mixed` | Producer stated a pace class |
| `unknown` | Producer **explicitly** stated uncertainty |
| `—` | Pace is **unavailable** (older quota-axi, or a bare-int custom source) |

`fm-fleet.sh budget` additionally refuses on conservation pressure, not just raw
headroom: when the operator's headroom clears `FM_FLEET_QUOTA_MIN` but a fresh
surface is pressured with a worst reserve below `FM_FLEET_RESERVE_MIN` (default
`-25`, points; set to `-100` to disable the pace floor), it reports "below pace
floor" instead of "ok" — always naming the headroom/pace/reserve facts that
drove the answer, never a bare verdict. Only **fresh** surfaces feed this floor;
a stale/cached window's pace is visible in `quota` but never drives a refusal.

**Degradation guarantee**: against an older `schemaVersion` 2 payload, or any
provider record missing pace, `quota`/`models`/`pick`/`budget` behave exactly as
they did before pace existed — `PACE`/`RESERVE` render `—`, `budget` skips the
pace floor, `pick` ignores pace ordering. Nothing crashes, nothing fabricates a
pace class.

These fleet verbs are **operator-facing diagnostics**. They never select a
harness, model, or effort for dispatch, and `fm-fleet.sh pick` must never be
wired into `fm-spawn` or any other dispatch path — that is exactly the routing
wrapper / producer-side route recommendation the dispatch owner forbids.
Dispatch selection from these same signals is owned by
[`AGENTS.md`](../AGENTS.md) section 4 and the `quota-array-dispatch` skill it
names; this add-on only reads and renders what `quota-axi` reports.

### Cross-uid safety (non-negotiable)
Every mutating fleet function calls `fm_fleet_assert_shared`, which refuses any path resolving into a foreign `/home/<other>` or `/Users/<other>`.
Credentials stay `0700`, read only by their owner's own processes.
See `.agents/skills/federation/SKILL.md`.

### One privileged step (root, once)
Run the reviewable, idempotent `scripts/fleet-root-prereq.sh` (walkthrough:
[fleet-quickstart.md](fleet-quickstart.md), Tier C). It creates the shared
group, enrols the operators, and creates the setgid fleet dir; each operator
then sets `umask 002`. Nothing else needs root.

---

## Part B — Per-spawn multi-account

### Three isolation methods (verified per CLI — never guessed)
The matrix below records how each CLI isolates auth, probed from its own
`--help` (claude confirmed empirically); `bin/fm-accounts-lib.sh` validates
every registered account against it:

| harness | method | env / flag |
|---|---|---|
| claude | `config-dir-env` | `CLAUDE_CONFIG_DIR` |
| codex  | `config-dir-env` | `CODEX_HOME` |
| pi     | `config-dir-env` | `PI_CODING_AGENT_DIR` |
| cline  | `config-dir-flag` | `--config <dir>` |
| grok   | `api-key-env` | `GROK_API_KEY` |
| cursor-agent | `api-key-env` | `CURSOR_API_KEY` (OAuth mode not per-spawn isolatable) |

### Account registry (`config/accounts.json`, gitignored)
```json
{
  "<name>": {
    "provider": "...", "harness": "...", "isolation": "config-dir-env|config-dir-flag|api-key-env",
    "env": "<ENV>", "flag": "<flag>", "config_dir": "<path>", "key_file": "<path>",
    "scopes": ["..."]
  }
}
```
`bin/fm-accounts-lib.sh` resolves + **validates** each account against the matrix (harness known, isolation matches the harness's method + env/flag, required fields present, and paths never in a foreign private home).
Copy `docs/examples/accounts.json` to start.

**Secrets never live in the registry.** api-key accounts store a `key_file` path
(a `0600` file in the operator's own home); the key is read at launch into the
child's environment — never onto argv, never into a log.

### The `--account` axis (`bin/fm-spawn-acct.sh`)
Adds `--account <name>` through a wrapper that resolves the account's verified harness and lets `fm-spawn` build the canonical launch template:

- `config-dir-env`  → prefixes the generated pane command, e.g. `CLAUDE_CONFIG_DIR=/path claude ...`.
- `config-dir-flag` → inserts the flag before the generated brief argument, e.g. `cline --config /path ... "<brief>"`.

The env prefix / flag rides **in the generated pane command**, so isolation survives the Herdr/tmux pane boundary while preserving the brief, autonomy flags, and turn-end wiring from the canonical template.
Config-dir isolation puts **no secret on argv**.

api-key accounts are **refused** here (a key on argv would leak) → use
`bin/fm-account-exec.sh <account> <cli> [args]` for a direct, non-supervised
isolated launch (reads the key_file into the child's env). Live-verified: a claude
crewmate launched under an isolated account writes to its own config dir and sees
a different MCP set than the default account.

### Quota-aware selection (`fm_account_pick <harness>`)
`quota-axi` reports headroom **per provider for the currently-authed account**, so
per-account headroom is obtained by running `quota-axi` **under each account's
isolation**; the binding constraint is `min(percentRemaining)` across windows.
Pick the account with the most headroom; ties → first registered. Guards:
unsupported provider (pi/cline) or `quota-axi` absent → first registered.

### Prereq installer (`bin/fm-accounts-prereq.sh`)
On-demand, **user-scoped, no sudo**. `detect` (default) shows installed / MISSING
+ the install command; `install [--yes] [harness…]` installs missing CLIs
(`npm i -g @anthropic-ai/claude-code|@openai/codex|@vibe-kit/grok-cli|cline`,
`curl https://cursor.com/install`). `pi` is system-managed → detect-only. Run this
first on a box that is missing, e.g., cursor.

---

## Integrated use and overlay packaging

In this repository, no overlay install step is needed.
For a standalone overlay onto an older FirstMate clone, carry the owner surfaces named at the top of this document plus the integration edits to spawn, backend, bootstrap, and configuration paths; copying only the new-file set is not enough.

1. `bin/fm-accounts-prereq.sh` — install any missing CLIs; then log in per account.
2. `cp docs/examples/accounts.json config/accounts.json` and edit; gitignore it.
3. Federation only: run the root prereq, then `bin/fm-fleet.sh init`.

## Custom-source retirement path (documented, NOT executed)
`bin/quota-sources/{copilot,cursor}.sh` exist because quota-axi's NATIVE `copilot`
provider only probes the old IDE-plugin credential path
(`~/.config/github-copilot/apps.json`) and its native `cursor` provider only
probes the editor's SQLite store (`~/.config/Cursor/User/globalStorage/state.vscdb`) —
a CLI-only login (`copilot`, `cursor-agent`) is invisible to both, so those native
rows sit at `auth_required` forever without the custom sources. Once upstream
quota-axi PR #50 (`feat(providers): read Copilot and Cursor credentials from
their CLI config files`) merges and ships, quota-axi covers both surfaces
natively — **with pace** — and the bare-int custom sources become a regression:
superseding a richer native row with a bare integer destroys `pace`, `boundedBy`,
and `worstReservePercentPoints` information (R7). `fm-fleet.sh quota` already
flags this today with a `custom int masks native pace` advisory NOTE (Phase A);
precedence itself is unchanged in this work item.

**Phase A — now (pre-#50).** Keep everything. Custom sources still supersede
their same-named quota-axi row; the only change is the advisory NOTE.

**Phase B — gates. All four must hold before deleting anything:**

| Gate | Check |
|---|---|
| G1 | quota-axi PR #50 is merged and installed: `quota-axi update && quota-axi --version` |
| G2 | Native rows are `fresh` for both CLI-only logins: `quota-axi --json \| jq -r '.providers[] \| select(.provider=="copilot" or .provider=="cursor") \| [.provider,.state.status,.source] \| @tsv'` |
| G3 | Those native rows are richer than the bare int: non-null `quotaSemantics.effectiveAvailability` and/or window `pace` for both |
| G4 | Two fresh reads **at least one hour apart** agree (G2 is not a single cached hit) |

**Phase B — deletion list (only after all four gates pass):**
`bin/quota-sources/copilot.sh`, `bin/quota-sources/cursor.sh`,
`bin/quota-copilot-usage.sh`, `bin/quota-cursor-usage.sh`. Plus: the operator
removes the `.copilot`/`.cursor` keys from their gitignored
`config/quota-overrides.json` (an operator action, not a repo change), and
`docs/examples/quota-overrides.json` drops copilot/cursor as worked examples
while keeping the mechanism documented.

**Phase B — what must survive, explicitly:** the override hatch itself —
`config/quota-overrides.json` plus the `bin/quota-sources/*.sh` loader loop in
`fm_fleet_quota_report`, `fm_fleet_models_report`, and `fm_fleet_pick_surface`
(all three now defined in `bin/fm-fleet-quota-lib.sh`).
It exists for genuinely unreadable vendors (`cline` today; any future surface
quota-axi doesn't cover). Retiring two *users* of the hatch must not retire the
hatch — the loader must keep tolerating an empty `bin/quota-sources/` directory
(regression-tested, `tests/federation/test_quota_surfaces.sh`).

Zero files are deleted by this work item.

## Tests
```
bash tests/federation/test_fleet.sh          # federation: claim race, reap, route, handoff, view, safety
bash tests/federation/test_fleet_ops.sh      # operator lifecycle: register/heartbeat/leave, TTL, quota routing
bash tests/federation/test_fleet_guards.sh   # init/ownership guards on every fleet-consuming entry point
bash tests/federation/test_quota_surfaces.sh # per-surface quota report, models table, picker, pace columns, budget pace floor, schemaVersion 2 degradation
bash tests/federation/test_accounts.sh       # registry resolve/validate (+ cross-uid path guard)
bash tests/federation/test_spawn_account.sh  # --account compose + wrapper + api-key refusal + apply_env
bash tests/federation/test_account_quota.sh  # quota pick (isolate-then-query; tie/absent/no-provider)
```

## Known limitations (honest)
- **cursor-agent OAuth is not per-spawn isolatable** (creds in `~/.cursor`, no
  relocation env). Multi-account for cursor uses API-key mode only.
- **grok** is API-key isolatable but stays out of the Herdr crew rotation (no
  `GROK_AGENT` autonomy marker + no Herdr integration).
- **quota-axi is per-provider, not per-account** — on this box both claude config
  dirs reported identical headroom because `quota-axi --provider claude` reads a
  shared credential source regardless of `CLAUDE_CONFIG_DIR`. Genuine two-account
  discrimination requires each account separately authed with creds quota-axi
  reads (verify on a real second account); codex quota (in `$CODEX_HOME/auth.json`)
  is expected to discriminate. `pi`/`cline` have no quota-axi coverage.
- Supervised account spawns keep `fm-spawn`'s per-harness model/effort mapping.

## Packaging options
1. **Integrated FirstMate feature.** Keep the owner surfaces above together so the
   normal spawn, backend, bootstrap, and documentation contracts stay aligned.
2. **Standalone add-on repo** overlaid onto a FirstMate clone (same files and
   integration points).
3. **axi-style tool** — possible but *not* simpler: the bash scripts would need
   npm-bin repackaging + a SessionStart hook, and federation needs a shared
   group-writable dir that doesn't fit the per-user axi model. Recommend #1/#2.
