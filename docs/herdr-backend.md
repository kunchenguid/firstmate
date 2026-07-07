# Herdr runtime backend (experimental)

This document records the empirical verification behind `bin/backends/herdr.sh`, the herdr session-provider adapter added in P2 of the runtime-backend abstraction.
It is the herdr equivalent of the tmux facts recorded in the `harness-adapters` skill and `docs/architecture.md`'s "Runtime session backends" section.

Herdr is [an agent-native terminal multiplexer](https://herdr.dev) with a socket API, CLI wrappers, and native per-pane agent-state detection.
Verified against the real installed binary: herdr 0.7.1, protocol 14, macOS aarch64.
Current real-herdr verification uses isolated `HERDR_SESSION` names plus the guarded teardown helper in `tests/herdr-test-safety.sh`.
A 2026-07-02 cleanup bug proved that `HERDR_SESSION` alone is not a safe way to target destructive session cleanup; see "Session targeting: the `--session` flag, not `HERDR_SESSION` alone" below.
All real-herdr verification in this document uses isolated sessions and guarded cleanup; the captain's default herdr session and live tmux fleet were never intended targets.

## Setup

Pick herdr when you want native per-pane agent-state detection (busy/idle/blocked) instead of tmux's regex-based guessing, and you are comfortable running an experimental backend.

Herdr is dual-licensed AGPL-3.0-or-later / commercial - see its LICENSE file (github.com/ogulcancelik/herdr) or https://herdr.dev.
Firstmate only drives the `herdr` CLI as a separate process, which carries no AGPL obligations for firstmate users.

Prerequisites:

- `herdr` itself, protocol 14 or newer (installed 0.7.1 verified) - see [herdr.dev](https://herdr.dev) for install instructions.
- `jq`, required to parse herdr's JSON output: `brew install jq` (or your platform's package manager).
- The same universal requirements as tmux (a verified crew harness, git with GitHub auth, node, treehouse, no-mistakes, gh-axi, chrome-devtools-axi, and lavish-axi); treehouse still provides the worktree, herdr only provides the session.

Select herdr by putting `herdr` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=herdr` when you launch your harness for a one-off session; telling the first mate in chat to use herdr also works.
It can also be auto-detected: when firstmate itself is running natively inside herdr (`HERDR_ENV=1`) and no explicit backend is set, firstmate auto-selects herdr and prints a one-time opt-out notice; running inside tmux nested in herdr always resolves to tmux instead.
A herdr spawn refuses loudly before creating a session container or acquiring a ship/scout worktree if `herdr` or `jq` is missing or the installed herdr's protocol is older than verified.
For `--secondmate` launches, secondmate home sync and inherited-config propagation happen before this spawn-time backend gate.

No first-run provisioning is needed beyond having `herdr` and `jq` on `PATH`; firstmate creates the workspace and tab it needs on first spawn.

Watching and attaching: each firstmate home gets its own herdr workspace (the primary uses `firstmate`; each secondmate uses `2ndmate-<secondmate-id>`), with one tab per task inside it, named `fm-<id>`.
Attach to the selected `HERDR_SESSION` and switch to the workspace for the home you want to watch to see every one of that home's tasks as tabs in one tab bar.
You do not need to attach for routine supervision: `bin/fm-peek.sh fm-<id>` reads a task's pane without attaching, and `bin/fm-send.sh fm-<id> "<text>"` steers it.

Verify it works by spawning a trivial task with `--backend herdr` and confirming the task's meta records `backend=herdr` plus `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`; the workspace for your home should show the new `fm-<id>` tab.

Limitations: herdr is experimental, not yet used for `bin/fm-bootstrap.sh`'s required-tools list (the version/tool gate happens at spawn time instead), and still carries the open gaps documented below.
Resolved backend evidence, including the 2026-07-06 symlinked-project-prefix isolation fix, is kept in the same follow-up log for auditability.

## Status: experimental

Herdr is experimental, exactly like every non-tmux backend in this design.
Select it by putting `herdr` in a local `config/backend` file, by exporting `FM_BACKEND=herdr`, or by telling the first mate in chat to use herdr.
It can also be selected by runtime auto-detection when firstmate itself is running inside herdr and no explicit backend setting exists.
Absent those three explicit settings, firstmate falls through to runtime auto-detection.
When nothing is explicitly configured, `bin/fm-backend.sh`'s `fm_backend_detect` checks the runtime firstmate itself is executing inside: `$TMUX` (set inside every tmux pane, including a tmux pane nested inside a herdr pane) selects tmux and wins when present, `HERDR_ENV=1` (injected into every process herdr manages a pane for) selects herdr when `$TMUX` is absent, and cmux runtime signals select cmux only after those multiplexer markers are absent.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-auto-detection) for cmux's primary `CMUX_WORKSPACE_ID` marker and macOS-only fallback signals.
An auto-detected herdr spawn prints one loud stderr notice (set `config/backend` or pass `--backend tmux` to opt out).
Auto-detecting tmux stays silent, since that reproduces today's unconfigured default byte-for-byte.
Only when none of that resolves anything does firstmate fall back to the hard default, tmux.
Absent `backend=` in a task's meta always means `tmux`; a herdr task carries an explicit `backend=herdr` line, while other experimental adapters carry their own backend values.
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

## Workspace lifecycle: one persistent per-home workspace, reused

Each home's own workspace (`firstmate` for the primary, `2ndmate-<secondmate-id>` for a secondmate - see "Label derivation" above) is created once per session and reused by every subsequent spawn from that home: `fm_backend_herdr_workspace_ensure` calls `fm_backend_herdr_workspace_find` first and creates a workspace only when none labelled for that home exists yet.
Teardown (`fm_backend_herdr_kill`) closes only the task's pane/tab, never the workspace.

Reserved-keyword guard: never name a `jq --arg`/`--argjson` after a `jq` keyword (`label`, `and`, `or`, `not`, `if`, `then`, `else`, `end`, `reduce`, `foreach`, `import`, `def`, `as`, `__loc__`).
jq <= 1.6 rejects a keyword-named `$`-variable as a compile error, and this adapter pipes `jq`'s stderr to `/dev/null`, so on jq <= 1.6 the error silently becomes an empty result rather than a visible failure.
Use a distinct name such as `$want` instead; `tests/fm-backend-herdr.test.sh` greps `bin/` for this pattern so a new violation fails loudly rather than silently.

### Default-tab prune

`herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`) that firstmate never uses.
`fm_backend_herdr_create_task` prunes it (best-effort, via `fm_backend_herdr_workspace_prune_seeded_default_tab`) right after creating the first real task tab in a freshly created workspace, never earlier: closing a workspace's LAST tab deletes the whole workspace on real herdr, and immediately after creation the default tab is the only one present.

**The prune target is identified structurally (created-vs-adopted), never by label pattern.**
`fm_backend_herdr_workspace_ensure` captures the seeded default tab's `tab_id` straight from its OWN `workspace create` response (`.result.tab.tab_id`, verified empirically to be present on the same response as `.result.workspace.workspace_id` - no follow-up `tab list` call is needed) ONLY when that call itself just created the workspace.
`fm_backend_herdr_container_ensure` threads that id through to its caller as a second field: it echoes `"<session>:<workspace_id>\t<seeded_default_tab_id>"`, the second field empty whenever the workspace was ADOPTED (`fm_backend_herdr_workspace_find` matched a pre-existing workspace by label) rather than created fresh.
`fm_backend_herdr_create_task` accepts that value as an explicit 4th argument and is the ONLY place allowed to act on it; it never re-derives "prunable" from a tab's label or the workspace's tab count.
An adopted workspace's caller always passes an empty 4th argument, so create_task never even looks for a prune candidate in that case - it is structurally impossible for an adopted workspace's tabs to be pruned, regardless of how they are labeled.

Defense in depth on top of that gate (not the primary safety mechanism): before closing the seeded tab, `fm_backend_herdr_workspace_prune_seeded_default_tab` re-verifies the tab is still present, re-checks it is still labeled `1`, and refuses if its pane's `agent get` reports `agent_status: working` (herdr's own native agent-state detection) - belt-and-suspenders against a live agent having landed there through some other path.

#### Incident: the 2026-07-02 self-kill

The previous implementation derived "prunable" at `create_task` time from a pure label heuristic run against whatever workspace `workspace_find` had just resolved: exactly one tab, labeled `1`.
Herdr enforces no label uniqueness (see "Label collisions" above) and derives an unlabeled workspace's DISPLAYED label from its pane cwd's basename.
A captain who launches herdr directly inside a directory named `firstmate` therefore gets a workspace whose label is `firstmate` - byte-identical, by coincidence, to the primary firstmate home's own derived label - with a single auto-created tab, also labeled `1`.
`fm_backend_herdr_workspace_find` adopted that pre-existing, captain-owned, LIVE workspace by the label match (a label match can never distinguish an explicitly `--label`-created workspace from one whose label only coincidentally matches); the old heuristic matched too, since it looked only at the adopted workspace's own tab shape, not at whether THIS spawn had actually created it.
The very next crewmate spawn's `create_task` call closed the captain's own live pane roughly 27ms after creating its own task tab, killing the primary firstmate agent and its watcher mid-turn.
Log evidence: `~/.config/herdr/herdr-server.log` showed `cli:tab:create` (the new task tab) immediately followed by `cli:pane:close` on the captain's pane (pid 36335, launched ~8 minutes earlier); `~/.config/herdr/session.json` showed the adopted workspace's `custom_name: null` with `identity_cwd` pointing at the firstmate repo.

The fix is structural, not another heuristic, and is unit- and E2E-tested: see `tests/fm-backend-herdr.test.sh`'s `test_adopted_workspace_never_prunes_default_tab` and `test_label_collision_startup_workspace_leaves_live_tab_alone`, and `tests/fm-backend-herdr-prune-safety-e2e.test.sh`'s isolated real-herdr reproduction of the exact incident shape.

Because closing a workspace's last tab deletes it, a home's workspace does not outlive a fully idle fleet (zero live tasks for that home) - the next spawn's `workspace_find` simply finds nothing and recreates it. Reuse holds across concurrent and sequential tasks; it is not a guarantee that the workspace itself survives the whole session unconditionally.

A workspace whose label this adapter did not derive (see "Label derivation" above) is never adopted, reused, or torn down by firstmate - `fm_backend_herdr_workspace_find` and `fm_backend_herdr_list_live` only ever match a home's own derived label.

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
| Kill | `herdr pane close <pane>` | Closing a tab's only (root) pane also closes the tab - no separate tab-close call needed for this adapter's one-pane-per-tab shape. Best-effort: closing an already-closed pane exits non-zero, matching tmux's `kill-window \|\| true` contract. Teardown itself only ever closes the task's own pane/tab, never the workspace - but closing a workspace's LAST tab (verified real-herdr behavior) deletes the workspace as a side effect, so a home's own workspace persists only while at least one task tab remains; see "Workspace lifecycle" above. |
| Default-tab prune (create_task, first task in a fresh workspace only) | `herdr workspace create`'s own response (`.result.tab.tab_id`) identifies the seeded tab; `herdr tab list` + `herdr agent get <pane>` re-verify it; `herdr pane close <pane>` closes exactly that tab id | `herdr workspace create` seeds the new workspace with one auto-created default tab (label `1`, id captured straight from the create response) firstmate never uses. `fm_backend_herdr_create_task` closes EXACTLY that captured tab id right after creating the first real task tab in a freshly created workspace - never right after `workspace create` itself (see Kill row), and never re-derived from a tab's label or the workspace's tab count at create_task time (see "Default-tab prune" above for the created-vs-adopted safety gate and the 2026-07-02 incident it fixes). Best-effort; an ADOPTED workspace (not freshly created by this same call) is never a prune candidate at all. |
| Recovery / list-live | `herdr tab list --workspace <id>`, filter labels starting with `fm-` | Label-based, never trusts a stored id blindly - see "ID stability" below. `<id>` is always THIS home's own workspace (`fm_backend_herdr_workspace_find`), so recovery never sees a sibling home's tabs. |
| Workspace create / tab create (focus) | `herdr workspace create --no-focus`, `herdr tab create --no-focus` | Verified: neither focuses by default once a workspace already exists in the session, matching pre-P3 (flagless) behavior; `--no-focus` is passed anyway for defense in depth, since the very first workspace ever created in a brand-new session focuses regardless of the flag. `--focus` was separately verified to reliably focus, confirming the flag has real effect. |
| Session targeting for DESTRUCTIVE calls | `herdr session stop <name> --session <name> --json`, then `herdr session delete <name> --session <name> --json`; never `herdr server stop` | Used only through `tests/herdr-test-safety.sh`, which re-queries `herdr session list --json` before every destructive call. See "Session targeting" below - `HERDR_SESSION` alone is not reliably honored once another herdr server is already running on the machine. |

## Verified bug: `pane read --lines N` returns empty for small N

This was the most significant finding of this verification pass.

`herdr pane read <pane> --source recent --lines N` returns **completely empty output** when `N` is smaller than the pane's current viewport height, instead of clamping to the last `N` lines.
Reproduced deterministically by binary search against a 23-row pane: `--lines 5/6/8/15` all returned zero bytes; `--lines 20` returned a partial read; `--lines 24` and above returned the full expected content, correctly clamping down even at `--lines 1000`.

This silently broke exactly the small bounded reads the adapter needs most - the composer-state verification read inside the send-and-verify path, and would have affected any small `fm-peek.sh` line count too.
Before the workaround, an early version of the real-herdr smoke test flaked intermittently for exactly this reason.

**Workaround:** `fm_backend_herdr_capture` never passes a caller's small requested line count straight through to herdr's own `--lines` flag.
It always requests a generous floor (>= 200 lines, comfortably above any realistic pane viewport) from herdr, then trims to the caller's actual requested bound locally with `tail -n N`.
Verified this eliminates the flake across repeated full smoke-test runs.

## Verified gap: `agent.get` reads idle during a long foreground tool call

`herdr agent get <pane>` -> `.result.agent.agent_status` was verified against a short interactive `claude` exchange (see "Busy state" above): `working` while the model streams a turn, `done` once it stops.
That verification did not cover a crew blocked on its OWN long-running foreground tool call - e.g. `no-mistakes axi run` without `--yes`, which blocks synchronously for the whole pipeline (minutes to tens of minutes) until a gate or outcome, per `AGENTS.md` section 11.
For that entire span the model is not generating - it already finished the turn that invoked the tool and is waiting on the tool's result - so `agent_status` reads `idle` (or `blocked`, which the adapter also maps to `idle`), even though the pane's own rendered text keeps showing the harness's busy banner (`BUSY_REGEX`, e.g. `esc to interrupt`) the whole time, exactly as it would in a plain tmux pane.

This surfaced as a real fleet incident (2026-07-02): `bin/fm-watch.sh`'s absorb-only-when-provably-working stale path (`AGENTS.md` section 8) treated a herdr `idle` verdict from `crew_pane_is_busy` as final, so it skipped the shared tail-regex corroboration that `unknown` already got.
At the same time, an independent no-mistakes run-step attribution fallback could miss this crew's branch when `axi status` reported another branch; current `bin/fm-crew-state.sh` falls back to top-level `no-mistakes runs --limit ${FM_CREW_STATE_RUNS_LIMIT:-200}` for that coarse cross-branch verdict.
Together, those gaps let a genuinely still-working herdr crew read as not provably working, triggering an immediate stale wake instead of the intended absorb-then-escalate behavior.

**Fix:** `bin/fm-crew-state.sh`'s `crew_pane_is_busy` now corroborates BOTH `idle` and unknown/unparseable native verdicts with the shared tail-regex before concluding "not busy" - only a bare `busy` verdict is trusted outright.
The cross-branch attribution fallback now uses the real `no-mistakes runs` command, and the watcher checks provably-working evidence before a stale status-log verb can make a stale pane terminal.
This does not mask a genuinely human-blocked agent (a permission dialog, not mid-tool-call): that pane does not render the busy banner, so the corroboration still correctly reports not-busy for it.

## Slash/`$` autocomplete popup hazard (confirmed, same mitigation as tmux)

Typing `/mem` into a live `claude` composer inside a herdr pane and reading the pane back within 0.1 seconds already shows the full autocomplete popup.
This confirms the same hazard tmux already mitigates: submitting immediately after a `/`- or `$`-prefixed send risks Enter landing on a popup selection instead of the literal typed command.
`fm_backend_herdr_send_text_submit` takes the same settle-before-first-Enter parameter tmux's submit core does; the settle-duration DECISION itself lives in `fm-send.sh` (harness-aware, backend-independent), so neither adapter needs its own settle policy.

`escape` was verified to dismiss the popup while leaving the typed text in the composer, not a full clear.

## Incident (2026-07-03): a slash command left fully typed but unsubmitted, silently

Two grok/herdr crewmates were each sent `/no-mistakes` via `fm-send.sh`.
In both panes the command sat fully typed in the composer, unsubmitted (footer still read `Enter:send`), for minutes, until a manual `fm-send.sh <target> --key Enter` landed it instantly.
`fm-send.sh` had exited 0 both times - no failure surfaced to the caller.

Root cause, reproduced live against real grok 0.2.82 on an isolated herdr session: the send-text-submit verification at the time used the old delta-based strategy and declared success whenever the captured pane content changed AT ALL between before and after an Enter.
For an argument-taking slash command, the FIRST Enter does not submit - it closes the completion popup and, for a command like `/compact [context]`, EXPANDS the composer text into an argument-hint placeholder (`/compact` -> `/compact compaction instructions`).
The popup disappearing and the composer text changing is a real, visible content change, so the old delta check declared "submitted" after exactly one Enter, even though the composer still held real, unsubmitted text and the footer still read `Enter:send`.
A genuine second Enter was required to actually submit - exactly the manual recovery that worked both times in the incident.
Plain (non-argument) commands like `/new` did submit on the first Enter in the same live test, so the false-positive was specific to commands whose popup selection fills an argument placeholder rather than submitting outright - `/no-mistakes` (optional task-first argument) is exactly that shape.

The tmux backend was NOT affected by this incident: `fm_tmux_composer_state` reads the actual cursor row and classifies it as pending whenever real text remains, so its retry loop correctly issued the second Enter and landed the same live repro; this was confirmed side-by-side against the same real grok pane.

**Fix:** `fm_backend_herdr_composer_state` replaces the delta-based check with a structural read of the composer's OWN row, mirroring what the cursor-row read gives tmux.
Herdr's CLI exposes no cursor-row primitive, so the composer row is located by shape instead of position.
For bordered composers, the row is the only line in a generous tail capture whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, or a plain `|`) - the box's own top/bottom rows use rounded corners and never match, popup item rows and separator rows carry no border glyph at all, and the footer help line uses `│` only as an interior separator (never as the first/last character), so none of those can be mistaken for the composer.
For unbordered live composers, added after the 2026-07-07 incident below, the row is a bottom-most trimmed line starting with a verified agent prompt glyph (`❯` for claude or `›` for codex); decorative bordered boxes above it lose to that bottom-most match.
A popup-close-with-placeholder-fill still reads as real content on that row, so it correctly classifies as pending and the retry loop sends the required second Enter, instead of stopping early.
Known ghost/placeholder composer text (`Type a message...`, verified grok 0.2.82's empty-composer hint) is recognized and still reads as empty.
`FM_BACKEND_HERDR_IDLE_RE` extends that placeholder match, `FM_BACKEND_HERDR_BARE_PROMPT_RE` controls the recognized unbordered prompt glyphs, and `FM_BACKEND_HERDR_COMPOSER_LINES` controls the tail-window scan depth; all three are documented in [`docs/configuration.md`](configuration.md).
See `fm_backend_herdr_composer_state` and `fm_backend_herdr_send_text_submit` in `bin/backends/herdr.sh` for the implementation, and `tests/fm-backend-herdr.test.sh`'s composer-state and send-text-submit sections (including the bordered slash-submit retry and unbordered real claude/codex prompt fixtures) for the fake-harness coverage.

## Composer verification: structural composer-row read, not delta-based

The herdr adapter's submit-verification no longer diffs raw pane content before/after Enter (see the incident above for why that was unsafe).
It instead classifies the composer's own row - located structurally as the bottom-most bordered composer row or verified bare prompt row described above - as empty or pending after each Enter attempt, retried (Enter only, never retyped) until it reads empty or retries are exhausted.
This mirrors tmux's cursor-row classification in spirit, without needing an equivalent cursor-row read primitive from herdr's CLI.
A dedicated composer-state or cursor-row read primitive is still a candidate upstream Herdr feature request; it would let this backend eventually verify with the same precision as tmux's native cursor-row read, rather than a structural approximation over a plain-text capture.

All implemented backends expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching at all.

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

## Respawn idempotency: a restored task tab is a husk, not a duplicate

A restart's other consequence (the previous section's "what does NOT survive") used to make every fleet respawn after it a manual chore: a restored `fm-<id>` tab comes back alive but with a fresh shell process and no registered agent (`agent_status` reset to unknown, `agent get` reporting `agent_not_found`) - or, if the pane's own process failed to restart at all, structurally gone (`pane get` reporting `pane_not_found`).
Before this fix, `fm_backend_herdr_create_task`'s duplicate-label guard treated either shape identically to a genuinely live duplicate and refused unconditionally, so recovering a fleet after a real herdr server restart (or, worse, a full reboot) meant closing every husk pane by hand before firstmate could spawn into it again - this reproduced in production on 2026-07-03.

The guard is now husk-aware.
`fm_backend_herdr_pane_agent_state` classifies an existing same-labeled tab's pane as one of `dead` (`pane get` -> `pane_not_found`), `no-agent` (the pane exists but `agent get` -> `agent_not_found` - the restored-plain-shell shape, and also what a future `resume_agents_on_restore = false` herdr config would produce unconditionally), `live` (a real registered `agent_status`, including idle/blocked - never just "working"), or `unknown` (anything unparseable or unexpected).
Only `dead` and `no-agent` are treated as a husk; `live` and `unknown` both refuse exactly as before, fail-safe toward refusal whenever the state cannot be classified with confidence.
A confirmed husk is closed and replaced instead of refused: `fm_backend_herdr_create_task` always creates the REPLACEMENT tab first, closes the preexisting husk tab by id only after that succeeds, and verifies no same-labeled tab except the replacement remains before returning success.
It never closes the husk first, because closing a workspace's last remaining tab deletes the whole workspace on real herdr (see "Workspace lifecycle" above) and a session-restore husk can legitimately be that workspace's only tab.
This is the identical create-before-close safety argument `fm_backend_herdr_workspace_prune_seeded_default_tab` already established for the seeded default tab.

Verified against the real binary (`tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, an isolated non-default session): a real `session stop` + fresh `herdr server` restart, followed by a same-labeled `fm_backend_herdr_create_task` call, closes and replaces the restored no-agent husk for both a crewmate/scout-shaped and a `--secondmate`-shaped task (the same function serves both spawn paths), while a pane carrying a genuinely registered agent (via herdr's own `pane report-agent`) still refuses.
The `dead` (`pane_not_found`) classification is covered at the unit level (`tests/fm-backend-herdr.test.sh`, canned-response fake) but not end-to-end against the real binary: killing a pane's underlying process on a live server was observed to make herdr immediately reap both the pane AND its tab together (so the tab never lingers in `tab list` for the duplicate check to even find), and a session restart was never observed to produce a structurally-dead-but-still-listed pane either - only a live, agent-less one.
The `dead` branch remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) that has not been reproduced against the real binary.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`) and the real-CLI smoke tests (`tests/fm-backend-herdr-smoke.test.sh` and `tests/fm-backend-autodetect-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `HERDR_SESSION`:

1. `FM_HOME=<scratch> FM_BACKEND=herdr HERDR_SESSION=<isolated> bin/fm-spawn.sh herdr-e2e-t1 projects/scratch-e2e-project claude` - spawned successfully, printing `backend=herdr` in the summary and writing `herdr_session=`/`herdr_workspace_id=`/`herdr_tab_id=`/`herdr_pane_id=` to the task's meta.
2. `bin/fm-peek.sh fm-herdr-e2e-t1` - showed the live claude trust dialog.
3. `bin/fm-send.sh fm-herdr-e2e-t1 --key Enter` - accepted the trust dialog.
4. `bin/fm-peek.sh fm-herdr-e2e-t1` again - showed claude actively working through the brief (creating the branch, writing the file).
5. `bin/fm-send.sh fm-herdr-e2e-t1 "captain says: proceed as planned"` - a plain-text steer, exercising the send-and-verify path; the text appeared correctly in the pane.
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

## Away-mode daemon: herdr supervisor-pane support

`bin/fm-supervise-daemon.sh` (the `/afk` sub-supervisor) was tmux-only through 2026-07-03: it discovered its own injection target from `$TMUX_PANE`, and injected via raw `tmux display-message`/`tmux capture-pane`/`tmux send-keys` calls with no backend indirection.
On a herdr-based fleet (firstmate itself running with `HERDR_ENV=1`, no `$TMUX_PANE`), this failed outright at startup: `TMUX_PANE` is unset, so discovery fell through to the legacy `firstmate:0` fallback, which then failed the tmux pane-exists probe and refused to start.

The fix is transport-layer only - discovery, injection, and the busy/composer guards now dispatch through the SAME `bin/fm-backend.sh` primitives every other backend-aware script already uses (`fm_backend_target_exists`, `fm_backend_busy_state`, `fm_backend_capture`, `fm_backend_send_text_submit`, and the new `fm_backend_composer_state` dispatcher added alongside this work).
Classification policy, batching, the max-defer escape, the `FM_INJECT_MARK` sentinel contract, locks, and wake-queue handling are all unchanged.

**Discovery.** `FM_SUPERVISOR_TARGET` remains the explicit override, now accepting either a tmux target or a herdr `"<session>:<pane-id>"` target.
A new `FM_SUPERVISOR_BACKEND` override (`tmux`|`herdr`) resolves independently, mirroring `bin/fm-backend.sh`'s own `fm_backend_detect`: `$TMUX_PANE` set selects tmux (even nested inside herdr, matching the innermost-first rule); `$HERDR_ENV=1` with `$HERDR_PANE_ID` present selects herdr, composing the target as `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"`; absent both, the daemon falls back to tmux/`firstmate:0`, byte-identical to its pre-herdr-support behavior.
Other runtime backends, including zellij, orca, and cmux, are not yet supported as supervisor backends - the daemon refuses loudly at startup (`FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"`) rather than misapplying tmux primitives to a pane that isn't a tmux pane.

**Injection dispatch.** `inject_msg`'s pane-exists probe, busy-guard (`pane_is_busy`), composer-guard (`pane_input_pending`), and verified submit all take an optional `<backend>` argument (defaulting to `tmux` when omitted, so every pre-existing caller/test is unaffected) and route through the generic dispatchers instead of calling `tmux` directly.
For `backend=tmux` every dispatch resolves to the exact same underlying call as before (`fm_backend_capture`'s tmux arm runs the identical `tmux capture-pane -p -t <target> -S -40`; `fm_backend_tmux_send_text_submit` re-exports `fm_tmux_submit_core` verbatim), so tmux behavior is unchanged byte-for-byte.
For `backend=herdr`, busy detection tries the native `agent.get`-backed `fm_backend_herdr_busy_state` first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the shared regex-over-capture reader before treating the supervisor pane as not busy.
This mirrors the per-task stale-pane busy check `bin/fm-supervise-daemon.sh`'s `stale_window_is_busy` already used; composer/pending detection and the verified submit reuse `fm_backend_herdr_composer_state`/`fm_backend_herdr_send_text_submit` unchanged.
The wedge alarm's supervisor-client status-line flash (`tmux display-message ...`) is tmux-only cosmetic UI with no herdr equivalent; it is skipped for non-tmux backends, while the ERROR log line and the durable `state/.subsuper-inject-wedged` marker (the actual signal) are backend-independent and unaffected.

**A pre-existing bug this surfaced: `fm_backend_target_exists`'s herdr arm.** Before this task, that function's herdr case called `HERDR_SESSION="$session" herdr pane get "$pane"` directly, WITHOUT the `--session` flag.
Per "Session targeting" above, `HERDR_SESSION` alone is not reliably honored once another herdr server is already bound on the machine - it silently falls back to whatever server IS running.
This function happened to look correct in every prior test because those tests only ever had ONE herdr server running at a time.
Verifying the away-mode daemon end to end against a real, isolated `HERDR_SESSION` - while the ambient default herdr session was also running (the normal shape of an actual firstmate fleet) - reproduced it directly: the daemon's own startup target-exists check spuriously refused a genuinely live pane in the isolated session because the ambient default session's socket answered instead.
Fixed by routing through `fm_backend_herdr_cli` (which appends `--session` on top of the env var) instead of the raw ad hoc call.
This fix is backend-plumbing, not daemon-specific: it also corrects the same liveness check other callers use (`bin/fm-session-start.sh`'s per-task endpoint-liveness digest read).

**Empirical verification (real herdr, isolated session only).** `tests/fm-afk-inject-herdr-e2e.test.sh` mirrors `tests/fm-afk-inject-e2e.test.sh`'s three scenarios (human-partial-input deferral, swallowed-Enter retry, a normal single digest) plus a fourth (a persistently pending composer that never clears must alarm via `state/.subsuper-inject-wedged`, preserve the buffer, and never crash the daemon) against a real, throwaway, NEVER-default `HERDR_SESSION`, torn down with `herdr_safe_stop_and_delete` exactly like `tests/fm-backend-herdr-smoke.test.sh`.
The "supervisor pane" is a tiny deterministic bash loop drawing a bordered composer row (not a real harness), exercising the bordered branch of `fm_backend_herdr_composer_state`; a thin `herdr` PATH shim swallows exactly one `pane send-keys <pane> enter` call to simulate the swallowed-Enter scenario, since herdr's real CLI has no built-in way to drop a keystroke.
Real claude/codex unbordered prompt coverage lives in `tests/fm-backend-herdr.test.sh`'s captured-fixture regression tests described in the 2026-07-07 incident below.

Building that test surfaced one more real finding worth recording for anyone writing a similar herdr-driven composer script: `tput cols`, called from WITHIN a script launched into a herdr pane via `pane run`/`send-text`, reported a stale/default `80` regardless of the pane's actual width, while an interactively-typed one-off `tput cols` in the same pane correctly reported its real width (54, in the environment this was verified in).
A composer redraw that trusts `tput cols` for its own line-wrapping math can therefore silently overflow the pane's real width and wrap across two terminal rows - breaking the structural single-row border classifier's assumption (the digest looked "concatenated with itself" because the guard never fired: the composer read `unknown` instead of `pending`, so the busy/composer guard did not defer a second attempt).
The test's composer script works around this with a hardcoded conservative width rather than trusting `tput cols` in this execution context.
This `tput` issue is a test-harness-only concern: once the test's own composer script stayed within the pane's real width, `fm_backend_herdr_composer_state` and `fm_backend_herdr_send_text_submit` behaved as expected, but it remains a sharp edge for any future herdr-launched interactive script that computes its own layout from `tput`.

## Incident (2026-07-07): away-mode escalation redelivery loop on herdr

While `state/.afk` was set on a herdr-backed fleet, `bin/fm-supervise-daemon.sh` re-injected the SAME buffered escalation digest into the primary's own supervisor pane every housekeeping cycle instead of clearing `state/.subsuper-escalations` once delivery landed.
Observed twice: 2026-07-06 (three byte-identical digests in a row) and 2026-07-07 (two byte-identical catch-all-scan digests), each redelivery waking the primary's LLM turn for an escalation it had already handled - defeating away-mode's whole point.

Reproduced live against a real, isolated `HERDR_SESSION`, a real `claude` process (the primary's own harness) as the supervisor pane, and the real `fm-supervise-daemon.sh` (not a synthetic composer script): with one buffered `stale persisted 241s` escalation and `FM_HOUSEKEEPING_TICK=1`, the daemon delivered the identical digest to the live pane at least 5 times in 40 seconds, and the agent itself eventually replied "The message is identical again and my position hasn't changed... I'll treat further identical escalations as noise" - an exact live match for the reported symptom.

Root cause: `fm_backend_herdr_composer_state`'s structural composer-row read (added for the 2026-07-03 incident above) recognizes only BORDERED composer rows - a line whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, `|`).
Real `claude`'s live input row is a BARE, unbordered `❯ …` - no border glyph anywhere around it - flanked by plain horizontal-rule separator lines, not a box.
Claude's own startup welcome banner IS bordered, so immediately after launch the classifier's "last bordered row wins" scan locks onto the banner's own blank interior spacer row and misreads it as the composer (a coincidental, and wrong, "empty").
Once ordinary conversation scrolls that banner out of the 20-line capture window - true of any real supervisor pane with any history at all, which is every production case - NO bordered row exists anywhere in view, so the classifier reports `unknown` for a genuinely empty composer, forever.
`fm_backend_herdr_send_text_submit` treats only `empty` as a confirmed submit; `unknown` counts as failure, so `escalate_flush` never clears the buffer even though the real Enter genuinely submitted the digest to the real pane.
Because `pane_input_pending`'s pre-type guard only defers on `pending` (never `unknown`), the next housekeeping tick's flush attempt retypes and resubmits the SAME unmodified buffer content - the redelivery loop.

Also discovered while reproducing: real `codex` (0.142.x) has the identical unbordered-live-row shape, using `›` instead of claude's `❯`, confirming this is not claude-specific.
Codex additionally shows dynamic tip/hint text in its idle composer (e.g. "Use /skills to list available skills") rather than a fixed placeholder string or a blank row, so no static regex can safely tell a genuinely idle codex composer apart from real pending text.
This narrower gap is NOT fixed here: an idle real-codex supervisor pane under herdr now classifies as `pending` rather than `unknown`, which makes injection defer indefinitely instead of redelivering - a strictly safer failure mode (the buffer is preserved, never silently dropped, and the existing max-defer wedge alarm still fires) but still not a correct read of the composer.
A real fix needs either an upstream herdr cursor-row/style primitive or a codex-specific signal; neither exists today.

**Fix:** `fm_backend_herdr_composer_state` now recognizes TWO composer-row shapes in one scan - the existing bordered shape, and a new bare (unbordered) shape: a trimmed line that STARTS with a verified agent-specific prompt glyph (`❯` claude or `›` codex) with no closing border required at all.
The bare-row default is deliberately limited to `❯` and `›`, while generic shell-style glyphs (`>`, `$`, `%`, `#`) stay recognized only after the bordered shape has already identified a composer row, so a no-agent shell fallback cannot be misread as a delivered escalation.
Both shapes are checked in the SAME forward scan, keeping whichever match comes LAST (bottom-most on screen), rather than trying bordered-only first and falling back to bare-only when nothing bordered is found: a bordered decorative box (a welcome banner, an update notice) is always rendered ABOVE the live composer, never below it, in every harness observed, so "last match of either shape wins" always resolves to the genuinely live, bottom-most row instead of a stale decorative box still sitting in the capture window.
See `fm_backend_herdr_composer_state` in `bin/backends/herdr.sh` for the implementation, and `tests/fm-backend-herdr.test.sh`'s "unbordered (bare) composer rows" section (fixtures captured verbatim from real `claude`/`codex` panes) for the regression coverage - each of those tests read `unknown` before this fix and reads the correct verdict after.

## Known gaps and follow-up notes

- **No `events.subscribe` native push.** The busy-state semantic read (`agent.get`) is consumed through the EXISTING `fm-watch.sh` poll loop (same 15-second cadence as every other window), not a persistent async subscriber pushing events directly into the wake queue.
  This satisfies the adopted design's "polling remains as the reconciliation backstop" language without a separate watcher rewrite; herdr tasks already get materially better busy-state accuracy than tmux's regex guessing from this alone.
  A genuine `events.subscribe`-driven push is a reasonable follow-up, not implemented here.
- **`bin/fm-bootstrap.sh`'s required-tools list is unchanged.** It still unconditionally requires `tmux`, and does not yet conditionally add `herdr` and `jq` when a backend selection resolves to herdr.
  The version/tool gate happens at spawn time instead and refuses loudly, so this is bootstrap-detection polish, not a functional gap.
- **RESOLVED: worktree-discovery isolation guard's symlinked-project-prefix false refusal.** Originally discovered while building the runtime-backend-auto-detection real smoke test (`tests/fm-backend-autodetect-smoke.test.sh`), which needed a scratch project.
  `fm-spawn.sh`'s `PROJ_ABS` was a LOGICAL `cd && pwd` (symlink components kept), while herdr's `foreground_cwd` (and real tmux's `pane_current_path`, on the same OS-level cwd primitive) report the PHYSICALLY resolved path.
  When the project itself lived under a symlinked directory (e.g. macOS's `/tmp` -> `/private/tmp`), the very first worktree-discovery poll saw two different strings for the identical starting directory and the isolation guard false-refused the spawn as "not isolated" before `treehouse get` ever moved the pane - backend-agnostic, not specific to herdr.
  Fixed 2026-07-06 (backlog `fm-spawn-symlink-guard-s8`): `bin/fm-spawn.sh` now canonicalizes once into `PROJ_ABS_REAL` (`cd "$PROJ_ABS" && pwd -P`) right after `PROJ_ABS` is resolved, canonicalizes each observed pane cwd for the worktree-discovery comparison, and uses `PROJ_ABS_REAL` in `validate_spawn_worktree`'s own primary-vs-worktree comparison instead of recomputing from the still-symlinked `PROJ_ABS`.
  This removes both failure directions: a symlinked prefix can no longer false-refuse an isolated spawn, and, since both sides are physically resolved for comparison, a genuinely tangled spawn (worktree resolves to the same physical directory as the project) still correctly refuses.
  Verified with GNU bash 5.3.9(1)-release (aarch64-apple-darwin25.3.0) and git 2.53.0 on macOS (Darwin 25.5.0): added `tests/fm-backend.test.sh:test_spawn_symlinked_project_prefix_avoids_false_refusal`, which drives the real `bin/fm-spawn.sh` against fake-tmux panes whose first `pane_current_path` poll returns both the project's `pwd -P`-resolved physical path and its logical symlink-preserving path while `PROJ_ABS` is reached through a synthetic symlinked prefix (`ln -s <real> <link>`, project passed as `<link>/proj`).
  Confirmed the test reproduces the original bug against the pre-fix script (`git stash` the `bin/fm-spawn.sh` change and rerun: `not ok - fm-spawn.sh should succeed for a project reached through a symlinked prefix` / `error: treehouse get did not yield an isolated worktree ...`), and passes against the fix (`bash tests/fm-backend.test.sh` reports `ok - fm-spawn.sh: a project reached through a symlinked prefix (e.g. macOS /tmp -> /private/tmp) does not trip the isolation guard's false refusal`, with the rest of that suite's assertions unaffected).
  `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` passes clean on the changed scripts.
- **RESOLVED: a restart's restored-layout husk no longer needs a manual pane close before respawn.** See "Respawn idempotency: a restored task tab is a husk, not a duplicate" above for the fix (`fm_backend_herdr_pane_agent_state`, `fm_backend_herdr_create_task`'s close-and-replace).
  Left over from that fix: the `dead` (`pane_not_found`) husk classification is exercised only at the unit level, never against the real binary - killing a pane's process on a live server was observed to make herdr reap the whole tab immediately (never leaving a dead-but-still-listed pane for the duplicate check to find), and a real session restart was never observed to produce one either.
  It remains a conservative, defensively-coded path for a herdr failure mode (e.g. a restored process that fails to start) nobody has reproduced against the real binary yet.
- **Codex's dynamic idle-composer tip text still misreads as `pending`.** See "Incident (2026-07-07)" above.
  A real, genuinely idle codex composer under herdr shows rotating hint text instead of a blank row or a fixed placeholder, so `fm_backend_herdr_composer_state` cannot tell it apart from real unsubmitted input by pattern matching.
  The practical effect is a safe-but-wrong deferral (the max-defer wedge alarm still fires, the buffer is never lost), not a redelivery loop, so it was left as a follow-up rather than folded into that fix.
  A real fix needs either an upstream herdr cursor-row/style primitive or a codex-specific idle signal.
- **Not implemented: a "paused / awaiting-external" crew state for the stale-wedge escalation.** Raised alongside the 2026-07-07 incident: an in-flight crew intentionally idling on a known external wait (a vendor rate limit, say) still trips `bin/fm-supervise-daemon.sh`'s "stale persisted ... (possible wedge)" escalation exactly like a genuinely wedged crew, with no way to mark the wait as expected.
  Deferred as a separate item - it changes the stale-classification/status vocabulary shared with `bin/fm-watch.sh` and `bin/fm-classify-lib.sh`, which is a bigger surface than this redelivery-loop fix should carry.
