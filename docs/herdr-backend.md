# Herdr runtime backend (experimental)

This document records the empirical verification behind `bin/backends/herdr.sh`, the herdr session-provider adapter added in P2 of the runtime-backend abstraction.
It is the herdr equivalent of the tmux facts recorded in the `harness-adapters` skill and `docs/architecture.md`'s "Runtime session backends" section.

Herdr is [an agent-native terminal multiplexer](https://herdr.dev) with a socket API, CLI wrappers, and native per-pane agent-state detection.
Verified against the real installed binary: herdr 0.7.1, protocol 14, macOS aarch64.
Current real-herdr verification uses isolated `HERDR_SESSION` names plus the guarded teardown helper in `tests/herdr-test-safety.sh`.
A 2026-07-02 cleanup bug proved that `HERDR_SESSION` alone is not a safe way to target destructive session cleanup; see "Session targeting: the `--session` flag, not `HERDR_SESSION` alone" below.
All real-herdr verification in this document uses isolated sessions and guarded cleanup; the captain's default herdr session and live tmux fleet were never intended targets.

## Status: experimental

Herdr is experimental, exactly like every non-tmux backend in this design.
Select it explicitly with `--backend herdr`, `FM_BACKEND=herdr`, or `config/backend` containing `herdr`.
It can also be selected by runtime auto-detection when firstmate itself is running inside herdr and no explicit backend setting exists.
Absent those three explicit settings, firstmate falls through to runtime auto-detection.
When nothing is explicitly configured, `bin/fm-backend.sh`'s `fm_backend_detect` checks the runtime firstmate itself is executing inside: `HERDR_ENV=1` (injected into every process herdr manages a pane for) selects herdr; `$TMUX` (set inside every tmux pane, including a tmux pane nested inside a herdr pane) selects tmux and always wins when both markers are present, since that is the surface firstmate is actually running on.
An auto-detected herdr spawn prints one loud stderr notice (set `config/backend` or pass `--backend tmux` to opt out).
Auto-detecting tmux stays silent, since that reproduces today's unconfigured default byte-for-byte.
Only when none of that resolves anything does firstmate fall back to the hard default, tmux.
Absent `backend=` in a task's meta always means `tmux`; only a herdr task ever carries an explicit `backend=herdr` line.
A herdr spawn refuses loudly if `herdr` or `jq` is missing, or if the installed herdr's protocol is older than the verified minimum (`fm_backend_herdr_version_check`).

## Worktree provider stays treehouse

Herdr is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux.
Herdr's own `worktree.*` operations (branch-based, pooling/lease-free) are never used by this adapter.

## Task container shape: tab-per-task in one workspace PER FIRSTMATE HOME

Firstmate creates one herdr workspace PER FIRSTMATE HOME - the primary gets `firstmate`, each secondmate gets its own `2ndmate-<secondmate-id>` - and one TAB per task inside that home's own workspace.
This is the same "one container, one endpoint per task" shape tmux uses (one session, one window per task), refined one level: the container is now scoped per home, not shared machine-wide.

This refines, but does not reverse, P2's original decision (AGENTS.md task herdr-sm-spaces-k4).
P2 established workspace-per-TASK vs. tab-per-task-in-one-shared-workspace and picked tab-per-task on the human-watching axis (below); that axis is untouched here and workspace-per-task stays rejected.
What changed is the container's OWNER: P2 assumed a single firstmate instance per herdr session, so one shared `firstmate` workspace was enough.
With secondmates now spawning their own herdr tasks, jamming every home's tabs into that one shared workspace made a captain's tab bar an unlabeled mix of primary and secondmate work with no visual way to tell them apart.
Workspace-per-HOME fixes that while keeping tab-per-task's original human-watching win intact **within** each home: attaching to a home's own workspace (`herdr`, then switching to its space) still shows every one of *that home's* tasks as a tab in one tab bar, switchable with `ctrl+b <n>`; the ADDITIONAL win is that a captain juggling several homes on one herdr session now sees them as clearly labeled, separate spaces in herdr's spaces sidebar instead of one undifferentiated pile.

### Label derivation (stable, derived from the home itself)

`fm_backend_herdr_workspace_label` (`bin/backends/herdr.sh`) resolves the label from `$FM_HOME`, read fresh on every call rather than cached or threaded through env plumbing:

- The PRIMARY home (no `.fm-secondmate-home` marker at its root) resolves to the constant `firstmate` - byte-identical to every pre-P3 task's recorded label.
- A SECONDMATE home (carrying `.fm-secondmate-home`, written by `bin/fm-home-seed.sh` at seed time and containing exactly that secondmate's id) resolves to `2ndmate-<secondmate-id>`, e.g. `2ndmate-sshhip-h7`.

Because the label is derived from the home's own durable identity - the marker file lives at the home's root, not in an environment variable passed down a call chain - it is automatically stable across every respawn, recovery, and firstmate restart for the life of that home, with no extra bookkeeping required.
Two different secondmate homes always get two different, non-colliding labels because their marker ids are unique (verified: `tests/fm-backend-herdr.test.sh`'s `test_workspace_label_different_secondmates_get_different_labels`).

Every workspace-scoped adapter path reads this SAME resolution: find/ensure (`fm_backend_herdr_workspace_find`/`_ensure`), tab create and its duplicate-label check (`fm_backend_herdr_create_task`), list-live recovery (`fm_backend_herdr_list_live`), and pane-for-tab (`fm_backend_herdr_pane_for_tab`, via the workspace id these resolve).
So a secondmate's own recovery/duplicate-check calls are automatically scoped to its own space and never see (or collide with) the primary's or a sibling secondmate's tabs.

### The one wrinkle: a `--secondmate` spawn is launched BY the primary

For every other spawn kind, `$FM_HOME` at spawn time already names the right home: the primary spawning its own crewmate/scout, or a secondmate spawning a crewmate/scout FROM ITS OWN `fm-spawn.sh` process (its own `$FM_HOME` already IS that secondmate's home).
The one exception is `bin/fm-spawn.sh <id> <secondmate-home> --secondmate`: this command runs IN THE PRIMARY's own process, so the primary's OWN `$FM_HOME` is what the label-resolution helpers would see by default, even though the tab being created belongs to the SECONDMATE.
`fm-spawn.sh`'s herdr case arm handles this with a narrow, targeted shadow: it computes `HERDR_LABEL_HOME` (the secondmate's own home, `PROJ_ABS`, for `KIND = secondmate`; the process's own `$FM_HOME` otherwise) and passes it as a bash temporary-assignment prefix - `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure ...` and `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task ...` - which scopes the override to exactly those two calls and is automatically restored afterward (verified: bash's temporary-assignment-before-a-simple-command form applies for the duration of a shell FUNCTION call too, not only external commands).
Nothing else in `fm-spawn.sh` reads `$FM_HOME` again after this point, so no explicit restore is needed.

Every other backend-scoped call site needs no such glue: it already runs inside a process whose own `$FM_HOME` correctly names the home doing the work.
This includes the previously-unexercised path of a crewmate spawned FROM a secondmate's own `fm-spawn.sh` - proven end to end in `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`, not merely by code inspection (see "End-to-end verification" below).

### Focus behavior: never steals the captain's attention

Verified empirically against the real binary, in an isolated session:

- `herdr workspace create` and `herdr tab create` do NOT focus by default once at least one workspace already exists in the session - matching (and no worse than) the pre-P3 adapter's already-flagless calls.
- The ONE exception: the very first workspace ever created in a brand-new, empty herdr session focuses regardless, because herdr always needs something focused to attach a client to - there is nothing to "not steal focus from" at that point.
- `--focus` reliably DOES focus (both the workspace and, for a tab, the pane within it) - confirming the flag has real effect and isn't a no-op, so its absence is meaningful.

Both `fm_backend_herdr_workspace_ensure`'s workspace create and `fm_backend_herdr_create_task`'s tab create now pass `--no-focus` unconditionally.
This is defense in depth rather than a behavior change in the already-safe steady state: it guards workspace and tab creation after the session already has a focused workspace, but it cannot prevent herdr's unavoidable first-workspace focus in a brand-new empty session.
Once a workspace exists, spawning - primary or secondmate, workspace or tab - should not switch whatever space the captain is actively watching.

### Label collisions: adopt-don't-duplicate, unchanged in spirit

Herdr enforces NO label uniqueness at all for either workspaces or tabs (re-verified for workspaces specifically in this pass: creating a second workspace with an already-used label succeeds and produces two workspaces sharing that label).
`fm_backend_herdr_workspace_find` therefore adopts the FIRST matching workspace `jq` returns for a home's own label - in practice list order, normally creation order / the oldest - rather than attempting to disambiguate; this mirrors the pre-existing tab duplicate-label check in `fm_backend_herdr_create_task` (which still refuses an exact duplicate TAB label within the adopted workspace).
Practical consequence: if a user manually creates their own herdr workspace that happens to share a firstmate home's label (`firstmate`, or `2ndmate-<some-id>`), firstmate's next spawn silently ADOPTS that pre-existing workspace as if it were its own, rather than creating a second one or refusing.
This is a pre-existing characteristic of the adapter's find-before-create pattern, not a new risk introduced by the per-home refinement; avoid naming a personal herdr workspace `firstmate` or `2ndmate-<secondmate-id>` if you want to keep it separate from firstmate's own space.

### No forced migration

Existing live tasks are unaffected by this change: a task's meta already records its own `window=`/`herdr_pane_id=` target, which every backend-scoped operation (send/capture/kill/busy-state) resolves directly and never re-derives from a workspace label.
So a task spawned before this pass keeps working exactly as before, from whatever workspace it already lives in (the old shared `firstmate` workspace, or a pre-rename `firstmate-<secondmate-id>` workspace if that is where its home's tasks previously landed).
New workspace lookup does not adopt old secondmate labels: for new spawns, recovery, and list-live, the adapter exact-matches the current label derived from `FM_HOME` (`2ndmate-<secondmate-id>`).
If an older live workspace is still labeled `firstmate-<secondmate-id>`, rename it with `herdr workspace rename <workspace_id> 2ndmate-<secondmate-id>` before expecting new tasks or recovery/list-live to use that workspace.

Tab-per-task (within each home's own workspace) still wins on the human-watching axis for the reason P2 originally found: attaching once shows every one of that home's tasks as a tab in one tab bar, switchable with `ctrl+b <n>`, matching how a captain already watches a tmux-backed fleet.
Workspace-per-task - tried against the real binary in P2 and again considered here - would still only show one task's workspace at a time by default, requiring a separate top-level "space" switch to see the rest of even a single home's fleet; that tradeoff is unchanged by the per-home refinement and workspace-per-task remains rejected.

## Target string and meta fields

A herdr task's `window=` meta field holds `<herdr-session>:<pane-id>`, for example `default:w1:p2`.
The pane id itself contains a colon, so the adapter splits on the FIRST colon only, never on every colon.
This mirrors tmux's `session:window` target shape closely enough that `fm_backend_resolve_selector` (in `bin/fm-backend.sh`) needed no backend-specific logic at all - it already just returns a task's recorded `window=` value verbatim.
Operational commands should prefer the bare `fm-<id>` form, which resolves through this home's metadata.
An explicit herdr target also works when it exactly matches recorded metadata, but ad hoc non-`fm-` bare-name lookup remains the legacy tmux live-window fallback.

Herdr tasks additionally record:

- `herdr_session=` - the named herdr session this task's server lives in.
- `herdr_workspace_id=` - the id of the workspace belonging to the home that spawned this task (the primary's `firstmate` workspace, or a secondmate's own `2ndmate-<id>` workspace; for reference - not needed for day-to-day operations, which re-derive it from the target string).
- `herdr_tab_id=` - the task's tab id.
- `herdr_pane_id=` - the task's pane id, the fast-path operational target.

## Verified CLI facts

| Operation | Verified herdr call | What was verified |
|---|---|---|
| Version/protocol gate | `herdr status --json` -> `.client.protocol` | Session-independent; `.server.*` fields ARE session-dependent. |
| Headless server start | `HERDR_SESSION=<name> herdr server --session <name>` (backgrounded) | A bare socket call does NOT auto-start the server; the adapter always starts-then-polls before any workspace/tab/pane call. This fact is for start only, not cleanup, and the explicit `--session` flag is intentional because `HERDR_SESSION` alone is not safe session targeting. |
| Duplicate task check | `herdr tab list --workspace <id>`, match by `.label` | Herdr does NOT enforce tab-label uniqueness itself; two tabs can share a label. The adapter's own duplicate check is required. |
| Send literal (unsubmitted) | `herdr pane send-text <pane> <text>` | Does NOT auto-submit, contrary to the original design addendum's guess. Verified directly: a unique marker sent this way sits unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send + submit atomically | `herdr pane run <pane> <command>` | Runs and submits a command in one call; used for the two fixed spawn-time commands (`treehouse get`, the `GOTMPDIR` export) exactly where tmux used one `send-keys ... Enter` call. |
| Send key | `herdr pane send-keys <pane> <key>` | Verified names: `enter`, `escape` (alias `esc`), `ctrl+c` (aliases `C-c`, `c-c`). `ctrl+c` verified to interrupt a running foreground process immediately. |
| Bounded capture | `herdr pane read <pane> --source recent --lines N` | See "Verified bug" below - N is never passed through directly. |
| Busy state | `herdr agent get <pane>` -> `.result.agent.agent_status` | Verified live against an interactive `claude` session: reports `working` while generating, `done` once idle. Mapped: `working` -> busy; `idle`/`done` -> idle; `blocked` -> idle (surfaced like a stale pane, not suppressed as busy - a blocked agent is stuck waiting on the human, not grinding); anything else -> unknown (the cue for the shared tail-regex fallback). |
| Kill | `herdr pane close <pane>` | Closing a tab's only (root) pane also closes the tab - no separate tab-close call needed for this adapter's one-pane-per-tab shape. Best-effort: closing an already-closed pane exits non-zero, matching tmux's `kill-window \|\| true` contract. |
| Recovery / list-live | `herdr tab list --workspace <id>`, filter labels starting with `fm-` | Label-based, never trusts a stored id blindly - see "ID stability" below. `<id>` is always THIS home's own workspace (`fm_backend_herdr_workspace_find`), so recovery never sees a sibling home's tabs. |
| Workspace create / tab create (focus) | `herdr workspace create --no-focus`, `herdr tab create --no-focus` | Verified: neither focuses by default once a workspace already exists in the session, matching pre-P3 (flagless) behavior; `--no-focus` is passed anyway for defense in depth, since the very first workspace ever created in a brand-new session focuses regardless of the flag. `--focus` was separately verified to reliably focus, confirming the flag has real effect. |
| Session targeting for DESTRUCTIVE calls | `herdr session stop <name> --session <name> --json`, then `herdr session delete <name> --session <name> --json`; never `herdr server stop` | Used only through `tests/herdr-test-safety.sh`, which re-queries `herdr session list --json` before every destructive call. See "Session targeting" below - `HERDR_SESSION` alone is not reliably honored once another herdr server is already running on the machine. |

## Verified bug: `pane read --lines N` returns empty for small N

This was the most significant finding of this verification pass.

`herdr pane read <pane> --source recent --lines N` returns **completely empty output** when `N` is smaller than the pane's current viewport height, instead of clamping to the last `N` lines.
Reproduced deterministically by binary search against a 23-row pane: `--lines 5/6/8/15` all returned zero bytes; `--lines 20` returned a partial read; `--lines 24` and above returned the full expected content, correctly clamping down even at `--lines 1000`.

This silently broke exactly the small bounded reads the adapter needs most - a 6-line composer-verification read inside the send-and-verify path, and would have affected any small `fm-peek.sh` line count too.
Before the workaround, an early version of the real-herdr smoke test flaked intermittently for exactly this reason.

**Workaround:** `fm_backend_herdr_capture` never passes a caller's small requested line count straight through to herdr's own `--lines` flag.
It always requests a generous floor (>= 200 lines, comfortably above any realistic pane viewport) from herdr, then trims to the caller's actual requested bound locally with `tail -n N`.
Verified this eliminates the flake across repeated full smoke-test runs.

## Verified gap: `agent.get` reads idle during a long foreground tool call

`herdr agent get <pane>` -> `.result.agent.agent_status` was verified against a short interactive `claude` exchange (see "Busy state" above): `working` while the model streams a turn, `done` once it stops.
That verification did not cover a crew blocked on its OWN long-running foreground tool call - e.g. `no-mistakes axi run` without `--yes`, which blocks synchronously for the whole pipeline (minutes to tens of minutes) until a gate or outcome, per `AGENTS.md` section 11.
For that entire span the model is not generating - it already finished the turn that invoked the tool and is waiting on the tool's result - so `agent_status` reads `idle` (or `blocked`, which the adapter also maps to `idle`), even though the pane's own rendered text keeps showing the harness's busy banner (`BUSY_REGEX`, e.g. `esc to interrupt`) the whole time, exactly as it would in a plain tmux pane.

This surfaced as a real fleet incident (2026-07-02): `bin/fm-watch.sh`'s absorb-only-when-provably-working stale path (`AGENTS.md` section 8) treats a herdr `idle` verdict from `crew_pane_is_busy` as final, so it skipped the shared tail-regex corroboration that `unknown` already gets.
Combined with a no-mistakes run-step lookup that can also miss attribution (the CLI's own `axi`/`no-mistakes runs` recent-runs listing has a hard cap - 10 entries, no flag to raise it - so a long-running validation can fall outside that window on a repo with heavy run history), this let a genuinely still-working herdr crew read as not provably working, triggering an immediate (non-wedge) stale wake instead of the intended absorb-then-escalate behavior.

**Fix:** `bin/fm-crew-state.sh`'s `crew_pane_is_busy` now corroborates BOTH `idle` and unknown/unparseable native verdicts with the shared tail-regex before concluding "not busy" - only a bare `busy` verdict is trusted outright.
This does not mask a genuinely human-blocked agent (a permission dialog, not mid-tool-call): that pane does not render the busy banner, so the corroboration still correctly reports not-busy for it.

## Slash/`$` autocomplete popup hazard (confirmed, same mitigation as tmux)

Typing `/mem` into a live `claude` composer inside a herdr pane and reading the pane back within 0.1 seconds already shows the full autocomplete popup.
This confirms the same hazard tmux already mitigates: submitting immediately after a `/`- or `$`-prefixed send risks Enter landing on a popup selection instead of the literal typed command.
`fm_backend_herdr_send_text_submit` takes the same settle-before-first-Enter parameter tmux's submit core does; the settle-duration DECISION itself lives in `fm-send.sh` (harness-aware, backend-independent), so neither adapter needs its own settle policy.

`escape` was verified to dismiss the popup while leaving the typed text in the composer, not a full clear.
The adapter's own verify-and-retry logic does not depend on this; it is delta/content-based (see below), not popup-state-based.

## Composer verification: delta-based, not ANSI-cursor-row-based

Tmux's submit-verification reads the cursor row with ANSI styling to strip ghost/placeholder text and classify the composer as empty or pending.
Herdr's CLI exposes no equivalent ANSI/cursor-row-only capture primitive, so the herdr adapter verifies differently: capture the pane right after typing (the "typed" baseline, unsubmitted), then after each Enter attempt capture again.
Unchanged means the Enter did nothing and the adapter retries (bounded).
Changed means something happened - submitted, output appeared, or a popup resolved.
A dedicated composer-state or cursor-row read primitive is a candidate upstream Herdr feature request; it would let this backend eventually match tmux's stronger submit-verification guarantee.

Both backends expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching at all.

## Session targeting: the `--session` flag, not `HERDR_SESSION` alone

`HERDR_SESSION=<name>` is the adapter's normal way to select a named herdr session for NON-destructive operations: start, workspace, tab, pane, capture, send, and busy-state calls all still use it (via `fm_backend_herdr_cli`, below).

Destructive session cleanup is different, and this distinction was learned the hard way.
Verified empirically: on the installed herdr 0.7.1 client, neither an exported `HERDR_SESSION` nor an inline `HERDR_SESSION="$name"` prefix reliably targets a CLI subcommand once ANOTHER herdr server (e.g. the captain's live default session) is already bound on the machine - the client silently falls back to whatever server IS running instead of the requested one.
This is not a hypothetical: it killed the captain's live default herdr server, twice, from real-herdr test cleanup that relied on exactly this assumption (2026-07-02; see `tests/herdr-test-safety.sh`'s header for the full account).
`herdr server stop` is the sharpest edge of this, because it takes NO target argument at all - it always acts on "whatever server is running," resolved ambiently, with no positional name to catch a misroute.

The fix, verified against the real binary in an isolated session (both a genuinely separate isolated session and the default session's untouched state confirmed before and after):

- The `--session <name>` GLOBAL FLAG reliably routes every herdr subcommand tried (`status`, `workspace *`, `tab *`, `pane *`, `agent *`, `server`, `session stop`/`delete`) to the named session, in either leading (`herdr --session <name> <subcommand>`) or trailing (`herdr <subcommand> ... --session <name>`) position - both verified to work identically.
- `bin/backends/herdr.sh`'s `fm_backend_herdr_cli` helper wraps every herdr invocation in the adapter: it sets `HERDR_SESSION` (kept for cosmetic/forward-compat reasons - harmless, and it is what the client's own JSON echoes back) AND appends a trailing `--session <name>`, so every adapter call is correctly scoped regardless of what else is running on the machine.
- For destructive test cleanup specifically, use `herdr session stop <name>` / `herdr session delete <name>` (the explicit-by-name forms - `<name>` is a REQUIRED positional argument, so herdr cannot resolve it ambiguously; herdr's own help text requires literally typing `default` to affect the default session), never the ambient `herdr server stop`. `tests/herdr-test-safety.sh`'s `herdr_safe_stop_and_delete` does this, plus a read-only hard guard (`herdr_refuse_if_default`, re-querying `herdr session list --json` immediately before EVERY stop/delete call, refusing on a literal `default` name, a not-found name, or `default:true`) as a second, independent layer - fails closed on any ambiguity.

## ID stability across a server restart

The original design addendum flagged this as an open risk to verify.
It turned out better than feared.

`herdr session stop <name>` followed by a fresh `herdr server --session <name>` - the realistic "firstmate restarted, herdr server needs reattaching" recovery scenario - preserves workspace id, tab id, pane id, and every label exactly.
Herdr persists this metadata to disk per named session, independent of the live server process.
What does NOT survive is the underlying shell/agent process inside each pane (a fresh shell starts in its place) and each pane's live `agent_status` (resets to unknown).

P2 verified this in the single-workspace shape only.
Re-verified here in the MULTI-workspace shape (P3, workspace-per-home): with two coexisting workspaces (a `firstmate` and a `2ndmate-<secondmate-id>`, each with its own tab/pane) in one isolated session, a `session stop` + fresh server restart preserved BOTH workspaces' ids and labels, and BOTH tasks' pane ids, exactly - automated in `tests/fm-backend-herdr-smoke.test.sh`'s restart-stability section.

Practical consequence: a stored `herdr_pane_id=` remains a valid, fast-path operational target across an ordinary server restart within the same named session, regardless of how many other homes' workspaces coexist in that session.
The adapter still implements label-based recovery (`fm_backend_herdr_list_live`), both for a differently-configured or freshly-created session where old ids would not exist at all, and as the more defensive default in general.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`) and the real-CLI smoke tests (`tests/fm-backend-herdr-smoke.test.sh` and `tests/fm-backend-autodetect-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `HERDR_SESSION`:

1. `FM_HOME=<scratch> FM_BACKEND=herdr HERDR_SESSION=<isolated> bin/fm-spawn.sh herdr-e2e-t1 projects/scratch-e2e-project claude` - spawned successfully, printing `backend=herdr` in the summary and writing `herdr_session=`/`herdr_workspace_id=`/`herdr_tab_id=`/`herdr_pane_id=` to the task's meta.
2. `bin/fm-peek.sh fm-herdr-e2e-t1` - showed the live claude trust dialog.
3. `bin/fm-send.sh fm-herdr-e2e-t1 --key Enter` - accepted the trust dialog.
4. `bin/fm-peek.sh fm-herdr-e2e-t1` again - showed claude actively working through the brief (creating the branch, writing the file).
5. `bin/fm-send.sh fm-herdr-e2e-t1 "captain says: proceed as planned"` - a plain-text steer, exercising the delta-based send-and-verify path; the text appeared correctly in the pane.
6. The crewmate appended `done: hello.txt committed on fm/herdr-e2e-t1` to its status file, and its commit (`add hello.txt` on branch `fm/herdr-e2e-t1`) was confirmed present in the project's git history.
7. `bin/fm-teardown.sh herdr-e2e-t1` **REFUSED**, exactly as required: `REFUSED: local-only worktree ... has work not yet merged into main and not on any remote.`
8. `bin/fm-merge-local.sh herdr-e2e-t1` - fast-forwarded local `main` to the crewmate's commit.
9. `bin/fm-teardown.sh herdr-e2e-t1` now succeeded: returned the treehouse worktree, closed the herdr pane (verified gone via `herdr pane get`), and removed all of the task's `state/` files.

Two real, non-obvious bugs were caught and fixed by this pass alone, both already reflected above and in `bin/backends/herdr.sh`:

- The `pane read --lines N` small-N bug (see above) - without the fix, this E2E run flaked intermittently on the very first `send_text_line` call.
- `pane get`'s `.result.pane.cwd` field is frozen at pane-creation time and never updates; `fm_backend_herdr_current_path` originally read it and would have made `fm-spawn.sh`'s worktree-discovery poll misresolve the acquired treehouse worktree path (it would see the pane's ORIGINAL directory, not where `treehouse get`'s subshell actually landed) - fixed by reading `.result.pane.foreground_cwd` instead, which tracks the live running process.

The isolated herdr session, the treehouse pool worktree, and the scratch `FM_HOME` were all stopped/deleted/removed after this run, using the guarded teardown described in "Session targeting" above; the captain's default herdr session and the live tmux fleet were never touched at any point.

## End-to-end verification: workspace-per-home (P3)

`tests/fm-backend-herdr-workspace-per-home-e2e.test.sh` drives `bin/fm-spawn.sh` and `bin/fm-teardown.sh` for real, in a scratch `TMP_ROOT` holding two scratch firstmate homes (a primary-shaped one with no marker, and a secondmate-shaped one carrying `.fm-secondmate-home`) and two scratch local-only projects, on one isolated `HERDR_SESSION` (never the captain's default), with the same `herdr_safe_stop_and_delete` guarded cleanup.
This exercises the fm-spawn.sh-level behavior the adapter-primitive smoke test cannot reach: the label-resolution home-shadowing for a `--secondmate` spawn, and - the one path that had never run before this test - a crewmate spawned FROM a secondmate's own `fm-spawn.sh` process.

1. A primary-shaped home spawns an ordinary crewmate (`cm1`) on the herdr backend: its tab lands in a workspace herdr itself labels `firstmate`.
2. The PRIMARY spawns a `--secondmate` task (`e2esm1`, home = the secondmate-shaped scratch home): its tab lands in a DIFFERENT workspace than `cm1`'s, labeled `2ndmate-e2esm1` by herdr - proving the `fm-spawn.sh` FM_HOME-shadow glue for this one launched-by-the-primary case.
3. A crewmate (`cm2`) is spawned by running `bin/fm-spawn.sh` again, this time with `FM_HOME` set to the SECONDMATE's own home (simulating the secondmate running its own spawn, exactly as it would live) - no special-casing needed. Its tab lands in the SAME workspace as `e2esm1`'s (`2ndmate-e2esm1`), never the primary's - confirming per-home resolution "falls out" naturally for this path, as the design predicted, now proven rather than merely inspected.
4. `fm_backend_herdr_list_live`, called with `FM_HOME` set to each home in turn, sees only that home's own tab(s): the primary's list shows only `cm1`; the secondmate's list shows both `e2esm1` and `cm2`, and neither list leaks into the other.
5. `bin/fm-teardown.sh cm1` closes only `cm1`'s pane - the secondmate's own pane and `cm2`'s pane, both confirmed still open via `herdr pane get`, survive untouched. `bin/fm-teardown.sh cm2` (run with the secondmate's own `FM_HOME`) then closes only `cm2`'s pane, leaving the secondmate's own pane (same workspace) open.

All ten assertions passed on the real binary on the first run.
As with every other real-herdr test in this document, the default session's own workspace state (label, tab count) was confirmed byte-identical immediately before and immediately after the run.

## Known gaps left for a follow-up

- **No `events.subscribe` native push.** The busy-state semantic read (`agent.get`) is consumed through the EXISTING `fm-watch.sh` poll loop (same 15-second cadence as every other window), not a persistent async subscriber pushing events directly into the wake queue.
  This satisfies the adopted design's "polling remains as the reconciliation backstop" language without a separate watcher rewrite; herdr tasks already get materially better busy-state accuracy than tmux's regex guessing from this alone.
  A genuine `events.subscribe`-driven push is a reasonable follow-up, not implemented here.
- **`bin/fm-bootstrap.sh`'s required-tools list is unchanged.** It still unconditionally requires `tmux`, and does not yet conditionally add `herdr` and `jq` when a backend selection resolves to herdr.
  The version/tool gate happens at spawn time instead and refuses loudly, so this is bootstrap-detection polish, not a functional gap.
- **Worktree-discovery isolation guard is symlink-fragile for a project path under a symlinked prefix (e.g. macOS's `/tmp` -> `/private/tmp`).** Discovered while building the runtime-backend-auto-detection real smoke test (`tests/fm-backend-autodetect-smoke.test.sh`), which needed a scratch project. `fm-spawn.sh`'s `PROJ_ABS` is a LOGICAL `cd && pwd` (symlink components kept), while herdr's `foreground_cwd` (and real tmux's `pane_current_path`, on the same OS-level cwd primitive) report the PHYSICALLY resolved path.
  When the project itself lives under a symlinked directory, the very first worktree-discovery poll sees two different strings for the identical starting directory and the isolation guard false-refuses the spawn as "not isolated" before `treehouse get` ever moves the pane - backend-agnostic, not specific to herdr. Worked around in the test by resolving its scratch `TMP_ROOT` through `pwd -P` before use; the underlying `fm-spawn.sh` path-comparison gap (worth resolving `PROJ_ABS` physically, or comparing physically-resolved forms in the isolation guard) is unfixed and worth a dedicated follow-up.
