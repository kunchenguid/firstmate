---
name: federation
description: >-
  Procedure for federated multi-operator coordination. Use when more than one OS
  operator (each their own first mate, own accounts) shares work through the fleet
  KB. Owns fleet init, routing, claim/lock, handoff, TTL reap, and cross-uid safety.
metadata:
  internal: true
---

# federation

Multiple operators (e.g. `alice`/`bob`/`carol` — any OS users on the host), each
running their **own** first mate as themselves, whose firstmate homes may be named
and located differently, coordinate through one **shared, group-writable,
data-only KB** so
work is routed by domain, never overlaps, and is visible in realtime. This skill
owns that procedure. The CLI is `bin/fm-fleet.sh` (lib: `bin/fm-fleet-lib.sh`).

## Cross-uid safety (non-negotiable)

Operators share **only** the fleet dir. **Never** read or write another operator's
private home (`~/.claude`, credentials, their own firstmate home). Every
mutating fleet function calls `fm_fleet_assert_shared`, which refuses any path resolving into a foreign `/home/<other>` or `/Users/<other>`.
Credentials stay `0700`, read only by their owner's own processes.
This replaces FirstMate's single-uid filesystem-copy propagation, which cannot work across uids.

## Fleet dir resolution

`FM_FLEET_DIR` → `$FM_HOME/config/fleet-dir` → `/opt/agents/fleet`.
The real shared dir needs the one-time root prereq (`scripts/fleet-root-prereq.sh`): an
`agents` group + `/opt/agents/fleet` mode `2775` (setgid) + each operator's
`umask 002`. Until then it runs against a local dev dir (single-uid), which
exercises every code path.

## KB files (at `$FLEET`)

- `operators.md` — `| operator | scope | home | accounts | status | seen | quota |`;
  `scope` is a comma list; `status` is `online`/`offline`; `seen` is an ISO8601 UTC
  heartbeat; `quota` is that operator's self-published `quota-axi` min headroom %
  (or `-`). An operator counts as available for routing only when `status:online`
  **and** `seen` is within `FM_FLEET_HEARTBEAT_TTL` (90s) **and** `quota` ≥
  `FM_FLEET_QUOTA_MIN` (5). Legacy 5-column rows still route (freshness/quota skipped).
- `backlog.md` — `## Queued / ## Claimed / ## In-flight / ## Done`; item line:
  `- [id:<ID>] scope:<S> | <desc> | [claimed-by:<op>@<ISO8601>] status:<st>`.
- `events.log` — append-only TSV `<ISO8601>\t<op>\t<event>\t<id>\t<detail>`.
- `locks/backlog.lock` — the `flock` target for atomic claims.

## Procedure

0. **Onboard (once per operator, run AS YOURSELF):** `fm-fleet-join.sh <you> <scopes>
   [accounts]` — verifies shared-dir access, points `config/fleet-dir` at the shared
   KB, and registers you (`register` upserts your row: `status:online`, `seen:now`,
   `quota:now`). Idempotent. Refuses a home outside your own `$HOME`.
1. **Session start:** `fm-fleet.sh reap [ttl]` to requeue stale never-started
   claims from offline operators (default ttl 86400s; only `status:claimed`,
   never `status:in-flight`).
2. **Intake a task:** resolve owner by domain — `fm-fleet.sh route <scope>`
   (scope-primary: the online operator whose `scope` contains it; on
   miss/offline/quota-saturation → the `overflow` operator; a human `--operator`
   override always wins).
3. **Take work meant for you:** `fm-fleet.sh claim <id> <you>` — atomic under
   `flock`; returns non-zero if already claimed, so two operators can never grab
   the same item.
4. **Give work to its owner:** `fm-fleet.sh handoff <id> <owner>` — reassigns and
   leaves the item `status:claimed` under the new owner (a queued item is moved to
   `## Claimed` exactly as `claim` would), so the owner's `fm-fleet-wait.sh` wakes
   on it directly; no second `claim` is needed.
5. **Dispatch:** run the crewmate (fm-spawn) in your own Treehouse worktree under
   your own account; mark the item in-flight (integration point) and `done` on land.
6. **Visibility:** `fm-fleet.sh status` (per-operator counts) and
   `fm-fleet.sh view [--follow]` (the live cross-operator event stream).
7. **Stay cheap (token economy):** do NOT poll for work with the LLM. Block on
   `fm-fleet-wait.sh <you>` — bash, 0 tokens — which also heartbeats while waiting
   and returns only when you have a fresh `status:claimed` item, so the LLM primary
   wakes only for real work. Details: `docs/fleet-token-economy.md`.

## Notes

- Every KB mutation appends a line to `events.log` in the shared dir, the durable "who did what when" audit.
  The data-only KB contract is owned by the `bin/fm-fleet-lib.sh` header.
  Heartbeats are the one exception - a transient file write, never logged, so liveness does not bloat the log.
- Quota-secondary routing is implemented: each operator self-publishes its
  `quota-axi` min headroom into its `operators.md` `quota` column on heartbeat, and
  `route` skips any operator below `FM_FLEET_QUOTA_MIN` (no cross-user auth needed).
  `fm-fleet.sh budget` / `fm_fleet_budget_ok` gates a claim on local headroom and,
  where pace is reported, on conservation pressure too (see the `budget` bullet below).
  Missing `quota-axi` is fail-open (`quota:-`), so routing falls back to scope alone.

## Per-surface token visibility & model→surface picker

Each CLI/app subscription is its OWN token pool, and one model can be reachable from
several pools (grok via the `grok` CLI AND via Cursor; kimi3/open models via `cline`).
Four read-only, 0-token verbs expose this:

- `fm-fleet.sh quota` — every surface's headroom + observability status, plus (quota-axi
  ≥ 0.1.15, `schemaVersion` 3) a `PACE` and signed `RESERVE` column. Reserve is
  `percentRemaining − timeRemainingPercent`: negative = ahead of reset pace
  (conservation pressure), positive = behind (sustainable). Three states stay
  distinct: a pace class (`behind`/`on_pace`/`ahead`/`mixed`), explicit `unknown`
  (producer-stated uncertainty), and `—` (unavailable — older schema, or a
  bare-int custom source, which never carries pace). Base rows come from
  `quota-axi` (claude/codex/cursor/copilot/grok/kimi); pluggable scripts in
  `bin/quota-sources/<surface>.sh` add surfaces quota-axi can't see or attach an authed
  reader (e.g. `cursor`), each emitting a normalized `{surface,status,headroom,unit,models,note}` object —
  these never carry pace, so a custom row masking a paced native row gets an advisory NOTE.
- `fm-fleet.sh models` — for each model family in the model map (gitignored
  `config/model-surfaces.json` if present, else the shipped default
  `docs/examples/model-surfaces.json`), the
  ordered surfaces that can serve it, each with live status + headroom.
- `fm-fleet.sh pick <family>` — the picker (`fm_fleet_pick_surface`): among
  surfaces with observable headroom ≥ floor, prefers known-sustainable pace, then
  unknown/absent pace, then the least-pressured (least-negative reserve) surface, each
  tier taking the first in the map's operator-ordered surface list; else a
  configured-but-unobservable surface (fail-open) → else the first listed. Only fresh
  surfaces' pace is trusted (a stale surface's pace falls to the unknown/absent tier).
  This answers which quota pool currently has tokens for a family such as `grok`.
- `fm-fleet.sh budget` — also refuses on conservation pressure now, not just raw
  headroom: a fresh, pressured surface with worst reserve below
  `FM_FLEET_RESERVE_MIN` (default `-25` points; `-100` disables the pace floor)
  reports "below pace floor", always naming the headroom/pace/reserve facts.

These fleet verbs are **operator-facing diagnostics**: they never select a
harness, model, or effort for dispatch, and `fm-fleet.sh pick` must never be
wired into `fm-spawn` or any other dispatch path. Pace-aware dispatch selection
stays with `quota-array-dispatch` under `AGENTS.md` section 4 (rationale:
`docs/fleet-addon.md` "Per-surface pace").

Authed readers (server-side usage): some surfaces don't report through quota-axi. The
mechanism is an **operator-supplied escape hatch**: `config/quota-overrides.json` maps
`<surface> → a shell command that prints one int 0-100` (percent headroom); the
`bin/quota-sources/*.sh` scripts run it and emit that as the surface's headroom, which
**supersedes** the quota-axi / blind row. The command owns all secret handling (read the
token from a 0600 file, never argv). Empty/missing = blind fail-open (default). Template:
`docs/examples/quota-overrides.json` (real file gitignored).

- **cursor** — SOLVED with a shipped reader `bin/quota-cursor-usage.sh`: Cursor's native
  Connect RPC `POST api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
  (Content-Type: application/json, Connect-Protocol-Version: 1, x-cursor-client-* headers)
  accepts the CLI's OWN access token from `~/.config/cursor/auth.json` — no browser cookie.
  headroom = 100 − `planUsage.totalPercentUsed`. Wire: `"cursor": "<repo>/bin/quota-cursor-usage.sh"`.
- **cline** — intentionally NOT monitored. Its balance is served via an internal local
  WS Hub (`ws://127.0.0.1:25463/hub`) using a server-derived credential, not the stored
  WorkOS token (every REST/header variant returns 401). cline stays a usable crewmate
  harness but is out of quota picking; let it hit its wall and choose another LLM for open work.

**Retirement trigger for `bin/quota-sources/{copilot,cursor}.sh`** (full detail:
`docs/fleet-addon.md` "Custom-source retirement path"): once quota-axi PR #50 merges
and ships, and `quota-axi --json` shows BOTH `copilot` and `cursor` as `fresh` with
`pace`/`quotaSemantics` on two reads an hour apart, those two custom sources (plus
`bin/quota-{copilot,cursor}-usage.sh`) become deletable — a bare-int custom source
would otherwise mask a richer native pace row (R7). The `config/quota-overrides.json`
override hatch itself must survive any such deletion; it stays the mechanism for
genuinely unreadable vendors (`cline`, future surfaces). Not executed by this work
item — zero files deleted.

Tests: `tests/federation/test_quota_surfaces.sh`.
