# Herdr runtime backend (experimental)

This document records the empirical verification behind `bin/backends/herdr.sh`, the herdr session-provider adapter added in P2 of the runtime-backend abstraction.
It is the herdr equivalent of the tmux facts recorded in the `harness-adapters` skill and `docs/architecture.md`'s "Runtime session backends" section.

Herdr is [an agent-native terminal multiplexer](https://herdr.dev) with a socket API, CLI wrappers, and native per-pane agent-state detection.
Verified against the real installed binary: herdr 0.7.1, protocol 14, macOS aarch64.
All verification testing used isolated `HERDR_SESSION` names, stopped and deleted afterward; the captain's own default herdr session was never touched.

## Status: experimental

Herdr is opt-in and experimental, exactly like every non-tmux backend in this design.
Select it with `--backend herdr`, `FM_BACKEND=herdr`, or `config/backend` containing `herdr`.
Absent `backend=` in a task's meta always means `tmux`; only a herdr task ever carries an explicit `backend=herdr` line.
A herdr spawn refuses loudly if `herdr` or `jq` is missing, or if the installed herdr's protocol is older than the verified minimum (`fm_backend_herdr_version_check`).

## Worktree provider stays treehouse

Herdr is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux.
Herdr's own `worktree.*` operations (branch-based, pooling/lease-free) are never used by this adapter.

## Task container shape: tab-per-task in one `firstmate` workspace

Firstmate creates ONE herdr workspace labeled `firstmate` per session, and one TAB per task inside it - the same "one container, one endpoint per task" shape tmux uses (one session, one window per task).

This was an explicit, empirically-decided design choice, not an assumption.
The alternative, workspace-per-task, was tried against the real binary too.
Both shapes expose an identical per-item `agent_status` rollup field on their respective list calls (`herdr workspace list` and `herdr tab list --workspace <id>`), so neither has an API-ergonomics edge for firstmate's own supervision calls.
Tab-per-task wins on the human-watching axis: attaching once (`herdr`) shows every firstmate task as a tab in one tab bar, switchable with `ctrl+b <n>`, matching how a captain already watches a tmux-backed fleet.
Workspace-per-task would only show one task's workspace at a time by default, requiring a separate top-level "space" switch to see the rest of the fleet.

## Target string and meta fields

A herdr task's `window=` meta field holds `<herdr-session>:<pane-id>`, for example `default:w1:p2`.
The pane id itself contains a colon, so the adapter splits on the FIRST colon only, never on every colon.
This mirrors tmux's `session:window` target shape closely enough that `fm_backend_resolve_selector` (in `bin/fm-backend.sh`) needed no backend-specific logic at all - it already just returns a task's recorded `window=` value verbatim.
Operational commands should prefer the bare `fm-<id>` form, which resolves through this home's metadata.
An explicit herdr target also works when it exactly matches recorded metadata, but ad hoc non-`fm-` bare-name lookup remains the legacy tmux live-window fallback.

Herdr tasks additionally record:

- `herdr_session=` - the named herdr session this task's server lives in.
- `herdr_workspace_id=` - the `firstmate` workspace's id (for reference; not needed for day-to-day operations, which re-derive it from the target string).
- `herdr_tab_id=` - the task's tab id.
- `herdr_pane_id=` - the task's pane id, the fast-path operational target.

## Verified CLI facts

| Operation | Verified herdr call | What was verified |
|---|---|---|
| Version/protocol gate | `herdr status --json` -> `.client.protocol` | Session-independent; `.server.*` fields ARE session-dependent. |
| Headless server start | `HERDR_SESSION=<name> herdr server` (backgrounded) | A bare socket call does NOT auto-start the server; the adapter always starts-then-polls before any workspace/tab/pane call. |
| Duplicate task check | `herdr tab list --workspace <id>`, match by `.label` | Herdr does NOT enforce tab-label uniqueness itself; two tabs can share a label. The adapter's own duplicate check is required. |
| Send literal (unsubmitted) | `herdr pane send-text <pane> <text>` | Does NOT auto-submit, contrary to the original design addendum's guess. Verified directly: a unique marker sent this way sits unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send + submit atomically | `herdr pane run <pane> <command>` | Runs and submits a command in one call; used for the two fixed spawn-time commands (`treehouse get`, the `GOTMPDIR` export) exactly where tmux used one `send-keys ... Enter` call. |
| Send key | `herdr pane send-keys <pane> <key>` | Verified names: `enter`, `escape` (alias `esc`), `ctrl+c` (aliases `C-c`, `c-c`). `ctrl+c` verified to interrupt a running foreground process immediately. |
| Bounded capture | `herdr pane read <pane> --source recent --lines N` | See "Verified bug" below - N is never passed through directly. |
| Busy state | `herdr agent get <pane>` -> `.result.agent.agent_status` | Verified live against an interactive `claude` session: reports `working` while generating, `done` once idle. Mapped: `working` -> busy; `idle`/`done` -> idle; `blocked` -> idle (surfaced like a stale pane, not suppressed as busy - a blocked agent is stuck waiting on the human, not grinding); anything else -> unknown (the cue for the shared tail-regex fallback). |
| Kill | `herdr pane close <pane>` | Closing a tab's only (root) pane also closes the tab - no separate tab-close call needed for this adapter's one-pane-per-tab shape. Best-effort: closing an already-closed pane exits non-zero, matching tmux's `kill-window \|\| true` contract. |
| Recovery / list-live | `herdr tab list --workspace <id>`, filter labels starting with `fm-` | Label-based, never trusts a stored id blindly - see "ID stability" below. |

## Verified bug: `pane read --lines N` returns empty for small N

This was the most significant finding of this verification pass.

`herdr pane read <pane> --source recent --lines N` returns **completely empty output** when `N` is smaller than the pane's current viewport height, instead of clamping to the last `N` lines.
Reproduced deterministically by binary search against a 23-row pane: `--lines 5/6/8/15` all returned zero bytes; `--lines 20` returned a partial read; `--lines 24` and above returned the full expected content, correctly clamping down even at `--lines 1000`.

This silently broke exactly the small bounded reads the adapter needs most - a 6-line composer-verification read inside the send-and-verify path, and would have affected any small `fm-peek.sh` line count too.
Before the workaround, an early version of the real-herdr smoke test flaked intermittently for exactly this reason.

**Workaround:** `fm_backend_herdr_capture` never passes a caller's small requested line count straight through to herdr's own `--lines` flag.
It always requests a generous floor (>= 200 lines, comfortably above any realistic pane viewport) from herdr, then trims to the caller's actual requested bound locally with `tail -n N`.
Verified this eliminates the flake across repeated full smoke-test runs.

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

## ID stability across a server restart

The original design addendum flagged this as an open risk to verify.
It turned out better than feared.

`herdr session stop <name>` followed by a fresh `HERDR_SESSION=<name> herdr server` - the realistic "firstmate restarted, herdr server needs reattaching" recovery scenario - preserves workspace id, tab id, pane id, and every label exactly.
Herdr persists this metadata to disk per named session, independent of the live server process.
What does NOT survive is the underlying shell/agent process inside each pane (a fresh shell starts in its place) and each pane's live `agent_status` (resets to unknown).

Practical consequence: a stored `herdr_pane_id=` remains a valid, fast-path operational target across an ordinary server restart within the same named session.
The adapter still implements label-based recovery (`fm_backend_herdr_list_live`), both for a differently-configured or freshly-created session where old ids would not exist at all, and as the more defensive default in general.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-herdr.test.sh`) and the real-CLI smoke test (`tests/fm-backend-herdr-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `HERDR_SESSION` (never the default session):

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

The isolated herdr session, the treehouse pool worktree, and the scratch `FM_HOME` were all stopped/deleted/removed after this run; the captain's default herdr session and the live tmux fleet were never touched at any point.

## Known gaps left for a follow-up

- **No `events.subscribe` native push.** The busy-state semantic read (`agent.get`) is consumed through the EXISTING `fm-watch.sh` poll loop (same 15-second cadence as every other window), not a persistent async subscriber pushing events directly into the wake queue.
  This satisfies the adopted design's "polling remains as the reconciliation backstop" language without a separate watcher rewrite; herdr tasks already get materially better busy-state accuracy than tmux's regex guessing from this alone.
  A genuine `events.subscribe`-driven push is a reasonable follow-up, not implemented here.
- **`bin/fm-bootstrap.sh`'s required-tools list is unchanged.** It still unconditionally requires `tmux`, and does not yet conditionally add `herdr` and `jq` when a backend selection resolves to herdr.
  The version/tool gate happens at spawn time instead and refuses loudly, so this is bootstrap-detection polish, not a functional gap.
