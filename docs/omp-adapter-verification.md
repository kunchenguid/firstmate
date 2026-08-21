# OMP adapter — testing and verification plan

Branch: `feat/omp-adapter` (worktree `.claude/worktrees/omp-port`)
Target: omp v17.3.3 (global `~/.bun/bin/omp`), bun runtime.
Scope: detection fix, `fm-primary-omp-watch.ts`, `fm-primary-omp-turnend-guard.ts`,
`fm-spawn.sh` omp branch, `docs/supervision-protocols/omp.md`, README adapter list.

## Success criteria

A real crew task run under an omp primary completes with the same supervision
contract Claude and Pi get: watcher armed, wake delivered, turn-end guard never
lets the session settle blind, digest reaches the captain, and every harness
detection regression stays green.

## 0. Environment

- All live-omp runs use scratch dirs, `--session-dir` temp, `FM_STATE_OVERRIDE`
  temp, `--auto-approve`, smol model, `-p` print mode unless a case needs TUI.
- Extensions loaded explicitly with repeatable `-e` (never rely on auto-discovery
  in tests).
- Test-only probe extension: `tests/fixtures/omp-event-probe.ts` — logs every
  event (`session_start`, `session_switch`, `session_branch`, `session_shutdown`,
  `session_compact`, `session_stop`, `tool_call`, `agent_start`, `agent_end`) and
  ctx facts (`isIdle()`, `stop_hook_active`, switch `reason`) to a probe log.

## 1. Static gates (fast, run on every change)

- `bin/fm-lint.sh` — pinned shellcheck over changed bin scripts; must pass.
- `while IFS= read -r s; do bash -n "$s" || exit; done < <(bin/fm-lint.sh --list-files)`
- Type-check both new extensions against `@oh-my-pi/pi-coding-agent` types;
  mirror `tests/fm-pi-primary-types.test.sh` mechanics. Zero errors.
- Markers: link `docs/supervision-protocols/omp.md` from AGENTS.md index;
  README adapter list includes omp.

## 2. Harness detection — new `tests/fm-omp-harness.test.sh`

Mirror `tests/fm-cursor-harness.test.sh` / `fm-grok-harness.test.sh`.

Matrix (env marker, then ancestry):

| Env | Expected |
|---|---|
| `OMPCODE=1 CLAUDECODE=1` (real omp child) | `omp` |
| `CLAUDECODE=1` alone | `claude` |
| `PI_CODING_AGENT=true` | `pi` |
| `OMPCODE=1 PI_CODING_AGENT=true` | `omp` (omp tested first) |
| `CURSOR_AGENT=1` + any | `cursor` (unchanged precedence) |
| `GROK_AGENT=1` | `grok` |
| none (markerless, ancestry) | process-name walk incl. `*omp*` |
| `OMPCODE=1` inherited by a codex child | documented precedence hazard; verdict matches cursor note (foreign marker can override ancestry — record in comment) |

Crew/secondmate resolution: `crew-harness=default` under omp → `omp`;
explicit `omp`; secondmate chain unchanged. Usage header lists omp.

## 3. Shared script contracts (existing tests stay green)

- `fm-turnend-guard.test.sh`, `fm-watch-arm.test.sh`, `fm-arm-pretool-check.test.sh`,
  `fm-cd-pretool-check.test.sh`, `fm-subagent-pretool-check.test.sh`,
  `fm-watcher-lock.test.sh`, `fm-watch-triage.test.sh` — full pass.
- NEW: guard invoked bare (no `--claude` flag) — the exact invocation the omp
  extension uses. Assert parity with `--claude` on: clean settle (exit 0),
  queued digest (exit 2), no state (exit 0).
- Re-arm smoke from CONTRIBUTING against the worktree:
  `FM_STATE_OVERRIDE=$(mktemp -d) FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh`
  → prints exactly one of `watcher: started pid=<N> (beacon fresh)` /
  `watcher: attached pid=<N>` / FAILED, then an actionable signal.
- Wake round trip: encode a watcher wake (operational input), run
  `bin/fm-wake-drain.sh`, assert the queued wake surfaces.

## 4. Live omp extension behavior (real omp, `-p`, scratch dirs)

### A. Load and arm
`omp -p -e tests/fixtures/omp-event-probe.ts -e .pi/extensions/fm-primary-omp-watch.ts -e .pi/extensions/fm-primary-omp-turnend-guard.ts --session-dir <tmp> --auto-approve "call the fm_watch_arm_omp tool and report its exact output"`

Assert: extensions load without errors; tool registered and callable;
`watcher: started pid=<N> (beacon fresh)` output; beacon
`state/.last-watcher-beat` fresh; marker `state/.omp-watch-extension-loaded`
written; watch-cycle ledger `state/.watch-cycle-exits.log` has one arm record.

### B. Session lifecycle / generations
New session → generation active. Resume (`-r`) → `session_switch` → new
generation arms. Branch → new generation. Quit → `session_shutdown`, final
generation stops. Assert: exactly one live watcher at all times (lock invariant);
stale generation callbacks are no-ops (no second arm, no rearm after shutdown).

### C. Seatbelt (PreToolUse equivalent)
Prompt issues a bash command the arm-pretool policy denies, and a cd the
cd-pretool policy denies. With `--mode=json`: assert the denied `bash`/`cd`
tool call is BLOCKED (no result, model receives `block` reason), allowed
commands unaffected. Same verdict as `fm-arm-pretool-check.test.sh` +
`fm-cd-pretool-check.test.sh` but through the omp `tool_call` path.

### D. Turn-end guard on `session_stop`
- Digest queued in state → guard exits 2 → continuation turn requested
  (probe log: `session_stop` → guard code 2; transcript shows the followUp).
- No digest / nothing actionable → guard exits 0, no continuation, no wake.
- `stop_hook_active` field observed and passed through unchanged.

### E. Compaction digest
Force compaction (config overlay with tiny context threshold):
`session_compact` fires → digest hidden message injected
(`sendMessage` customType+content, display:false) → probe log confirms.

### F. Auto-retry interlock
Prompt that errors and triggers `auto_retry_*` → assert NO premature
settle/guard wake; the guard fires only on the true final settle.

## 5. Spawn mechanics (omp crewmate)

- `fm-spawn.sh` omp branch launches the crewmate as
  `omp -p -e fm-primary-omp-watch.ts -e fm-primary-omp-turnend-guard.ts -e .omp-ext.ts --session-dir <task> <task text>`.
- Assert per-task lifecycle markers (`state/<id>.ready/started/turn-ended`)
  as in the pi path; worktree isolation assertion mirrors
  `fm-spawn-worktree-settle.test.sh`.
- Protocol name check: AGENTS.md's first-cycle line ("make the one required
  fm_watch_arm_omp call") matches the registered tool name exactly.
- `fm-supervision-events.test.sh` / `fm-supervision-instructions.test.sh` stay green.

## 6. E2E crew run under omp (real proof)

Scratch project; `FM_ROOT_OVERRIDE` = worktree; primary omp interactive (or
scripted `-p` + probe). Spawn a real 2-task crew (e.g. "write a module + test").
Assert the full loop:

1. spawn launches omp crewmate with extensions
2. crewmate arms the watcher (tool call)
3. task produces status → wake queued
4. primary receives wake, drains it
5. turn-end guard delivers digest; no blind settle
6. captain-visible supervision message; task artifacts and receipts exist

Capture primary + crewmate session transcripts and probe logs as evidence.

## 7. Regression

- `bin/fm-test-run.sh --changed` after each change; `--all` before PR.
- Harness-wide: claude, codex, opencode, pi, pi-signed, grok, cursor, kimi,
  muse detection tests all pass unchanged.
- `bin/fm-lint.sh` clean; CI yml untouched unless the new test files need a lane.

## 8. Evidence and docs

- Test evidence to temp dir (repo policy, `.no-mistakes.yaml`); no
  `.no-mistakes/evidence/` commits.
- `docs/supervision-protocols/omp.md` mirrors `pi.md` (session_switch vs
  shutdown semantics, omp tool name, guard on session_stop).
- PR: plain-English title, no-mistakes signature.

## Order and exit criteria

Phases run in order; each phase must pass before the next starts.
Exit: static gate green, layer 4 A–F fully green, one E2E crew task with digest
surfaced, regression suite green, evidence attached.

## Test files to create

- `tests/fm-omp-harness.test.sh` — detection matrix
- `tests/fm-omp-primary-types.test.sh` — extension typecheck (mirror pi)
- `tests/fm-omp-watch-extension.test.sh` — load/arm/generation/lifecycle
- `tests/fm-omp-turnend-guard.test.sh` — guard bare-arg + live stop/compact
- `tests/fm-omp-primary-live-e2e.test.sh` — crew E2E
- `tests/fixtures/omp-event-probe.ts` — event/facts probe (test-only)