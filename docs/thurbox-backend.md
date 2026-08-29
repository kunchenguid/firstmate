# thurbox runtime backend

[thurbox](https://github.com/Thurbeen/thurbox) is a session manager for coding agents: a ratatui TUI plus a `thurbox-cli`, over a SQLite session database whose sessions are real **tmux windows on a tmux server of its own**. `backend=thurbox` is an EXPERIMENTAL, spawn-capable session provider. Treehouse remains the worktree provider, exactly as for tmux, herdr, zellij, and cmux.

Everything below was verified against the real **thurbox 2.10.1** (schema 40, Linux x86_64, 2026-08-29).
thurbox **2.10 is the floor**, and the adapter refuses an older build rather than degrading on it. `bin/backends/thurbox.sh` is the adapter; [`verification/runtime-backends.md`](verification/runtime-backends.md#thurbox) owns the source-and-evidence index.

## Why this backend is shaped differently

Every operation goes through `thurbox-cli`, and the adapter runs **no tmux command at all**.
That is worth stating because it was not always true, and because a tmux-backed session manager invites the opposite assumption.

firstmate's contract needs four things thurbox 2.9 did not expose: unsubmitted input, named keys, an ANSI-preserving capture, and a cursor row.
An earlier revision of this adapter therefore drove `tmux -L <thurbox-socket>` directly for those, addressing the very window thurbox had created.
thurbox 2.10 supplies all four itself - `session send --no-enter`, `session key`, `session capture --ansi`, and the pane-state fields on that same capture - so the adapter now stays entirely on thurbox's own supported surface, and `tmux` is not among its required tools.

The one tmux fact still read is the socket **name**, and only so runtime detection can tell a thurbox pane from a nested tmux running inside one.
Reading a name needs no tmux client.

`session capture --json` returns the pane's live state beside the screen:

| Field | What the adapter uses it for |
| --- | --- |
| `cursor_row` | the composer's cursor anchor (`cursor=1`) |
| `foreground_process` / `foreground_command` | Cursor-pane identity; the **full argv** is what tells `node …/cursor-agent/cli.js` from a bare `node` |
| `foreground_cwd` | worktree discovery, following the foreground process rather than the launch directory |

`fm_backend_thurbox_composer_state` reads all of that in **one** call.
That is not only cheaper than the three it replaced: the screen, the cursor row that anchors it, and the process that may disqualify that anchor now describe a single instant, where separate reads could let the pane move between them.

thurbox is the **only non-tmux backend at the default backend's composer fidelity** - `styled=1` *and* `cursor=1`, where zellij manages styled-only and cmux and Orca have neither - and the second backend after herdr **wired to a native busy primitive** rather than a pane regex.
That wiring is real but currently unfed: nothing in a default firstmate-spawned session writes `hook_state`, so the verdict is `unknown` until an operator supplies the signal.
See "Active limits".

`cursor=1` also inherits the **Cursor Agent CLI hazard**, so the adapter takes the same mitigation the default backend uses.
Cursor parks its terminal cursor *outside* its composer, below the footer, so on a Cursor pane the cursor row is not a composer locator and the cursor-anchored read can only ever answer `unknown` - which would make every steer to a Cursor task read unverified, permanently.
`fm_backend_thurbox_composer_state` therefore reclassifies a Cursor pane cursorlessly, letting the bottom-most shape win, exactly as `bin/fm-tmux-lib.sh` does.
Identity comes from the `foreground_process`/`foreground_command` pair in the capture the verdict was computed from, and `bin/fm-cursor-lib.sh` remains the single owner of what counts as Cursor.
The reclassification is gated on that structural identity rather than on the verdict, so the strict blank-row posture that owns `unknown` for every other harness is untouched.

## Setup

1. **Install thurbox 2.10 or newer** so `thurbox-cli` is on `PATH` (it self-updates with `thurbox-cli update`). `jq` is required too; `bin/fm-bootstrap.sh` checks both when thurbox is the resolved backend. `tmux` is **not** required - the adapter runs no tmux command - though thurbox itself of course needs it. An older thurbox is refused at spawn rather than degraded on, because 2.9 has neither the pane-state fields every composer read depends on nor the `--no-enter`/`key` surface every steer uses.

2. **Add an interactive-shell agent to thurbox's `agents.toml`.** This is the one piece of thurbox-side configuration firstmate needs, and it exists because the two tools' default jobs are opposites: thurbox normally launches a coding agent for you, while firstmate needs a *bare interactive shell* so it can run `treehouse get` itself and then launch the selected harness with its own model, effort, and yolo flags.

   ```toml
   [[agents]]
   name = "shell"
   command = "bash"
   args = ["-i"]
   ```

   `args = ["-i"]` is load-bearing. A plain `command = "bash"` produces a pane that silently executes what you send but renders **no prompt and no echo** (verified), which starves every composer read.

3. **Select the backend**, either explicitly (`config/backend`, `FM_BACKEND`, `--backend thurbox`) or by letting auto-detection do it (below).

   `config/thurbox-agent` names a different agents.toml entry when `shell` is taken; the default is `shell`. A missing entry is refused at `container_ensure` with the exact TOML to paste, rather than surfacing as a mystifying agent launch.

   `config/thurbox-agent` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md), alongside `config/backend`. Both travel together deliberately: a secondmate that inherited `backend=thurbox` but not the agent name would fall back to the `shell` default, and on a home that already binds `shell` to a real coding agent that fallback launches the wrong program with no error.

4. **Optionally wire an agent-state signal.** This step is what makes thurbox's native busy verdict produce anything, and firstmate does not do it for you. Because the agent entry above is a bare shell, thurbox launches no agent of its own and therefore wires none of the lifecycle hooks that normally write `hook_state`; firstmate never calls `session signal` either. So `hook_state` stays null for a firstmate task's whole life unless your harness's own hooks call:

   ```sh
   thurbox-cli session signal --state working   # and done/idle/blocked
   ```

   No session argument is needed: thurbox injects `THURBOX_SESSION` into the pane and child processes inherit it, so the command resolves the right session from inside the pane (verified live on a pane whose foreground process was `claude`). Without this the backend is fully functional - every read simply reports `unknown` rather than a wrong answer.

## Runtime detection

thurbox is checked **before** `$TMUX` - the one deliberate exception to the innermost-first rule the other backends follow.

The reason is that thurbox is not a layer running *inside* tmux; it **is** a tmux server plus a session database. Every thurbox pane therefore sets `$TMUX` as a matter of thurbox's own implementation, and letting `$TMUX` win would address the task through the raw tmux adapter, losing the session identity, the native `hook_state`, and the lifecycle this adapter exists to use.

The rule stays exact because the marker is paired with a **socket match**: `THURBOX_SESSION` selects thurbox only when `$TMUX`'s socket path names the socket thurbox itself reports from `version --json`. A nested tmux started *inside* a thurbox pane inherits `THURBOX_SESSION` but runs on a different socket, so the match fails and `$TMUX` correctly wins as the genuinely innermost layer. The socket name is never hardcoded.

An auto-detected thurbox spawn prints a one-time opt-out notice, mirroring herdr and cmux.

## Task shape and metadata

One thurbox **session** per task, named `fm-<hometag>-<id>`, where `<hometag>` is the shared per-installation tag from `bin/fm-backend-hometag-lib.sh`. thurbox's session-name namespace is global to one database and shared by every firstmate home pointed at it, so the tag is what stops two homes with colliding task ids from steering each other's sessions. Unlike zellij and cmux there is **no legacy untagged form** to migrate: this adapter has been home-scoped since its first commit, so every matcher is an exact match with no ambiguity fallback.

Target string: `<session-uuid>:<tmux-pane-id>` (e.g. `0b797791-...:%20`). A UUID contains no colon, so the first-colon split is unambiguous.

Task metadata carries `backend=thurbox`, `thurbox_session_id`, and `thurbox_pane_id`.

### The identity model: the UUID is durable, the pane id is a cache

This is the single most load-bearing finding, and it shapes every function in the adapter.

`thurbox-cli session restart <uuid>` kills the window and re-spawns it. Verified: the session's `backend_id` moved **`%23` → `%24`** while the UUID stayed identical.

So every operation re-resolves the pane id from the UUID through `session get` before acting. `thurbox_pane_id` in task meta is a debugging breadcrumb and a fast path, never the authority. This is strictly better than cmux's situation, where ids do not survive an app relaunch and the only durable handle is a *title* that cmux does not enforce unique: thurbox's UUID is a real SQLite primary key, so recovery is exact rather than best-effort.

## Current operation and safety

**Verified findings** the adapter is built on:

1. **`session create --json` does not return `backend_id`** - only id/name/cwd/agent/agent_session_id. The pane id needs a second `session get`, so create polls for it.
2. **No name uniqueness.** Creating a second session named `fm-verify-1` succeeded and returned a different UUID, leaving two live windows with the same tmux window name. The duplicate refusal is *ours*, mirroring herdr, zellij, and cmux.
3. **The tmux window name is not the session name.** thurbox prefixes it: session `fm-verify-1` → window `tb-fm-verify-1`. Nothing matches on window names; the database name is the label authority.
4. **Exit codes are honest**, unlike zellij's always-0 `action` surface: `session get`, `session capture`, and `session send` all return 1 for a missing *or* malformed UUID. `session get` is therefore a sound liveness primitive with no output-shape defence needed.
5. **`session delete --force` really reclaims the window** (`"killed_window": true`), and also removes worktrees and cancels pending scheduled commands. The non-forced delete only soft-deletes the row and defers cleanup to the TUI's next sync - useless headlessly, so kill always passes `--force`.
6. **`session signal --state <working|blocked|done|idle>`** writes `hook_state`, and `session get --json` reads it back (verified round-trip). thurbox's agents call this from their own harness hooks. The vocabulary is word-for-word herdr's `agent_status` vocabulary, so `busy_state` reuses herdr's exact mapping, including `blocked` → idle (blocked means waiting on a human, not a turn in flight). `hook_state` is **null until an agent first signals**, which classifies as `unknown`, never `idle`.

**Teardown owns the row, not the window.** A thurbox database row *outlives* its tmux window - an operator exiting the shell, thurbox's tmux server restarting, and the non-forced delete's soft-delete all leave one behind - and the row's name stays reserved until something deletes it. `kill` therefore verifies identity from the session row and issues `session delete --force` regardless of pane liveness; gating on the pane would strand the name and make the next spawn of the same task id fail permanently on the duplicate refusal below.

**Refusals.** A session whose `backend_type` is not `local-tmux` - a remote session from `session create --host`, whose window lives on another machine over SSH - is refused outright, because every pane primitive would silently address nothing. A session name that does not match the expected task's scoped title is refused, so a recycled UUID can never be sent to or deleted by mistake. A scoped name over thurbox's documented 64-character limit is refused loudly at spawn rather than silently truncated. Because thurbox enforces no name uniqueness of its own, that duplicate refusal is the only thing keeping two sessions off one scoped title, so a `session list` that *fails* - a locked database, a mid-upgrade daemon - is refused too: an empty answer from a listing that never ran is absence of evidence, not evidence that the name is free.

**Create rolls itself back.** `session create` is synchronous but does not report the pane id, so the adapter polls `session get` for `backend_id` afterwards. If that poll times out, the session is deleted with `--force` before the failure is returned. The row already holds the scoped title, and the duplicate refusal above is exact-match on it, so a session left behind would fail *every* later spawn of that task id until an operator deleted it by hand. If the rollback itself fails, the warning names the exact `thurbox-cli session delete` to run.

### Isolation and its limit

`THURBOX_CONFIG_DIR` and `THURBOX_DATA_DIR` relocate a thurbox instance's config and its SQLite database - which is how the live verification pass ran without touching the operator's own sessions.

They do **not** relocate the tmux socket. Even a perfectly isolated database creates its windows on the *same* tmux server that holds real sessions. Worse, creating the first session in an instance also spawns thurbox's own `automation-heartbeat` window there - a background `while true; do thurbox-cli automation tick; sleep 60; done` loop that no `session delete --force` reclaims, because it is not a session.

Both were observed during verification and cleaned up by hand. This is why `tests/fm-backend-thurbox.test.sh` drives a **stubbed** `thurbox-cli` and a stubbed `tmux`, why `tests/thurbox-test-safety.sh` fails closed unless the CLI in use lives inside the test's own fixture, and why - unlike cmux and zellij - this backend ships **no real-binary smoke test**.

## Active limits

- **No recovery-grade agent-state classifier.** `fm_backend_agent_state` reports `unverified`, so the control plane refuses `exit` and `relaunch`, as it does for zellij, Orca, and cmux. This is want of an empirical pass, not a structural gap: `session capture`'s `foreground_process`/`foreground_command` pair now answers the process-attribution question the tmux classifier asks, so the port has a primitive waiting for it.
- **No composer identity probe.** Caps declare `identity=0`, so a `need-identity` verdict degrades to `unknown` rather than asserting an unproven probe. The pi identity probe additionally depends on pi's busy-footer semantics, which have had no thurbox pass. Cursor detection is deliberately *not* in this bucket: it is pure foreground-process identity, which `session capture` now answers directly.
- **No native event push.** `fm_backend_has_push` is false, so the watcher uses its poll loop. thurbox's `hook_state` is a genuine push *source* (agents write it from their hooks), but no streaming reader has been verified, so it is consumed by polling for now.
- **The away-mode supervisor daemon refuses thurbox**, alongside zellij, Orca, and cmux. thurbox is the near-miss: its panes *are* tmux panes, but on thurbox's own socket, so the daemon's bare `tmux` calls would address the wrong server entirely - the one hazard the adapter itself no longer has, since it runs no tmux command. A refusal, not a silent misread, is still correct until that daemon routes through the adapter. Making that refusal *reachable* is why `discover_supervisor_backend` (`bin/fm-supervisor-target-lib.sh`) carries a thurbox arm ahead of its `$TMUX_PANE` arm, for the same reason detection does: without it a thurbox-hosted captain answers `tmux`, and the daemon's supervisor injections go to whatever pane that id happens to name on the *default* server.
- **Nothing writes `hook_state` for a default firstmate session, so the native busy verdict is inert.** `hook_state` is written only by `thurbox-cli session signal`, invoked from lifecycle hooks thurbox wires when *it* launches an agent. firstmate's agent entry is a bare interactive shell (that is the whole point of it), so thurbox wires no hooks, and firstmate does not signal either. `fm_backend_thurbox_busy_state` therefore returns `unknown`, `bin/fm-busy-lib.sh`'s widened native-busy gate never fires for thurbox, and the queued-Enter conversion below never converts. All three fail safe - `unknown` is never mistaken for idle or for delivery - and all three go live unchanged the moment a signal source exists. Step 4 of "Setup" is how an operator supplies one today. The intended direction is upstream rather than local: work is in flight on the thurbox side to handle agent state generally, including for agents thurbox did not launch, so firstmate deliberately does not harden against today's shape by emitting signals itself.
- **The queued-Enter conversion is reasoned, not observed.** thurbox is the only backend on the shared `fm_composer_submit_retry_core` loop that supplies a delivery-busy primitive, so a steer typed into a mid-turn harness converts a proven `pending` composer plus an affirmative native busy to a delivered verdict instead of exiting nonzero on a steer that will land when the turn ends. Only `hook_state: working` converts - a null `hook_state` reads `unknown` and idle/done/blocked read `idle`, and neither is accepted as proof of a queue. This has **never been observed against a real mid-turn thurbox steer**: it is an extension of the same native signal `bin/fm-busy-lib.sh` already trusts for thurbox, and the stubbed suite covers the conversion's inputs, not a live queue.
- **thurbox is not the worktree provider.** See below.

## Why not the worktree provider

thurbox can own worktrees natively (`session create --worktree-branch/--base-branch`, and `session get` reports each worktree's path, branch, and repo). Adopting that would make thurbox a worktree provider like Orca rather than a session provider like everything else, and it is deliberately out of scope for this adapter: it would replace treehouse's pooling on the one backend, split the worktree contract across two owners, and it is not needed for anything thurbox does well here. Treehouse stays the worktree provider; thurbox creates its session in the worktree treehouse hands over.

## Regression entry points

- `tests/fm-backend-thurbox.test.sh` - the stubbed-CLI unit suite, covering the version and socket gates, naming and length limits, the shell-agent requirement and its `[[agents]]`-scoped literal name match (including ordinary trailing comments, TOML whitespace, and a `#` inside a quoted name), create and its duplicate refusal, the full target-resolution model (pane re-resolution after restart, name-mismatch and remote refusals, recovery by label, fail-closed cases), the `send_literal`-never-auto-submits rule, capture and composer routing including the Cursor reclassification and its process-identity gate, the `hook_state` mapping and the queued-Enter conversion it gates (converting only on an affirmative busy), forced teardown of a row whose window is already gone and of a secondmate's child session under the child home tag, discovery scoping, endpoint-metadata validation, both halves of the detection rule, and both halves of the same rule in away-mode captain-pane discovery.
- `tests/thurbox-test-safety.sh` - the fail-closed guard that keeps any thurbox test away from a real thurbox, over **both** CLIs the adapter drives: the `thurbox-cli` in `FM_THURBOX_BIN` and the `tmux` that would be resolved from `PATH`.
- `tests/fm-backend.test.sh` - shared dispatcher and detection contract; every case neutralizes `THURBOX_SESSION` so the suite stays deterministic when run from inside a thurbox session.
