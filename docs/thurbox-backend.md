# thurbox runtime backend

[thurbox](https://github.com/Thurbeen/thurbox) is a session manager for coding agents: a ratatui TUI plus a `thurbox-cli`, over a SQLite session database whose sessions are real **tmux windows on a tmux server of its own**. `backend=thurbox` is an EXPERIMENTAL, spawn-capable session provider. Treehouse remains the worktree provider, exactly as for tmux, herdr, zellij, and cmux.

Everything below was verified against the real **thurbox 2.9.2** (schema 40, Linux x86_64, 2026-08-28). `bin/backends/thurbox.sh` is the adapter; [`verification/runtime-backends.md`](verification/runtime-backends.md#thurbox) owns the source-and-evidence index.

## Why this backend is shaped differently

Every thurbox session is addressable two ways, and the adapter deliberately uses both:

| Layer | Owns | Used for |
| --- | --- | --- |
| `thurbox-cli session ...` | session identity and lifecycle, keyed by a **UUID** | create, get, delete, plain capture, native `hook_state` |
| `tmux -L <thurbox-socket> ...` | the pane of that same window | literal unsubmitted input, named keys, **styled** capture, cursor row, live cwd |

The thurbox CLI alone cannot satisfy firstmate's contract. `session send` **always appends Enter** (its own help: "Type text into a session's terminal, followed by Enter"), so it can never implement `send_literal`'s unsubmitted-input requirement, and the CLI exposes no named-key, ANSI-preserving-capture, or cursor primitive at all. Reaching for thurbox's own tmux socket is not a layering violation: it addresses the window thurbox itself created, with the primitives thurbox is itself built on.

The payoff is real. thurbox is the **first non-tmux backend to reach the default backend's composer fidelity** - `styled=1` *and* `cursor=1`, where zellij manages styled-only and cmux and Orca have neither - and the **second backend after herdr with a native busy primitive** rather than a pane regex.

`cursor=1` also inherits tmux's **Cursor Agent CLI hazard**, so the adapter takes tmux's mitigation with it. Cursor parks its terminal cursor *outside* its composer, below the footer, so on a Cursor pane the cursor row is not a composer locator and the cursor-anchored read can only ever answer `unknown` - which would make every steer to a Cursor task read unverified, permanently. `fm_backend_thurbox_composer_state` therefore reclassifies a Cursor pane cursorlessly, letting the bottom-most shape win, exactly as `bin/fm-tmux-lib.sh` does. The only socket-specific part is reading `#{pane_tty}` through thurbox's own socket; Cursor's process identity stays owned by `bin/fm-cursor-lib.sh`, and the reclassification is gated on that structural identity rather than on the verdict, so the strict blank-row posture that owns `unknown` for every other harness is untouched.

## Setup

1. **Install thurbox** so `thurbox-cli` is on `PATH` (it self-updates with `thurbox-cli update`). `tmux` and `jq` are required too; `bin/fm-bootstrap.sh` checks all three when thurbox is the resolved backend.

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

**Refusals.** A session whose `backend_type` is not `local-tmux` - a remote session from `session create --host`, whose window lives on another machine over SSH - is refused outright, because every pane primitive would silently address nothing. A session name that does not match the expected task's scoped title is refused, so a recycled UUID can never be sent to or deleted by mistake. A scoped name over thurbox's documented 64-character limit is refused loudly at spawn rather than silently truncated.

### Isolation and its limit

`THURBOX_CONFIG_DIR` and `THURBOX_DATA_DIR` relocate a thurbox instance's config and its SQLite database - which is how the live verification pass ran without touching the operator's own sessions.

They do **not** relocate the tmux socket. Even a perfectly isolated database creates its windows on the *same* tmux server that holds real sessions. Worse, creating the first session in an instance also spawns thurbox's own `automation-heartbeat` window there - a background `while true; do thurbox-cli automation tick; sleep 60; done` loop that no `session delete --force` reclaims, because it is not a session.

Both were observed during verification and cleaned up by hand. This is why `tests/fm-backend-thurbox.test.sh` drives a **stubbed** `thurbox-cli` and a stubbed `tmux`, why `tests/thurbox-test-safety.sh` fails closed unless the CLI in use lives inside the test's own fixture, and why - unlike cmux and zellij - this backend ships **no real-binary smoke test**.

## Active limits

- **No recovery-grade agent-state classifier.** `fm_backend_agent_state` reports `unverified`, so the control plane refuses `exit` and `relaunch`, as it does for zellij, Orca, and cmux. This is want of an empirical pass, not a structural gap: thurbox panes are tmux panes, so the tmux classifier's process-attribution approach should port directly once run against thurbox's own socket.
- **No composer identity probe.** Caps declare `identity=0`, so a `need-identity` verdict degrades to `unknown` rather than asserting an unproven probe. The pi identity probe additionally depends on pi's busy-footer semantics, which have had no thurbox pass. The Cursor probe below is deliberately *not* in this bucket: it is pure foreground-process identity, so the only socket-dependent part is the tmux call itself.
- **No native event push.** `fm_backend_has_push` is false, so the watcher uses its poll loop. thurbox's `hook_state` is a genuine push *source* (agents write it from their hooks), but no streaming reader has been verified, so it is consumed by polling for now.
- **The away-mode supervisor daemon refuses thurbox**, alongside zellij, Orca, and cmux. thurbox is the near-miss: its panes *are* tmux panes, but on thurbox's own socket, so the daemon's bare `tmux` calls would address the wrong server entirely. A refusal, not a silent misread, is still correct until that daemon routes through the adapter. Making that refusal *reachable* is why `discover_supervisor_backend` (`bin/fm-supervisor-target-lib.sh`) carries a thurbox arm ahead of its `$TMUX_PANE` arm, for the same reason detection does: without it a thurbox-hosted captain answers `tmux`, and the daemon's supervisor injections go to whatever pane that id happens to name on the *default* server.
- **thurbox is not the worktree provider.** See below.

## Why not the worktree provider

thurbox can own worktrees natively (`session create --worktree-branch/--base-branch`, and `session get` reports each worktree's path, branch, and repo). Adopting that would make thurbox a worktree provider like Orca rather than a session provider like everything else, and it is deliberately out of scope for this adapter: it would replace treehouse's pooling on the one backend, split the worktree contract across two owners, and it is not needed for anything thurbox does well here. Treehouse stays the worktree provider; thurbox creates its session in the worktree treehouse hands over.

## Regression entry points

- `tests/fm-backend-thurbox.test.sh` - 47 stubbed-CLI unit tests covering the version and socket gates, naming and length limits, the shell-agent requirement and its `[[agents]]`-scoped literal name match, create and its duplicate refusal, the full target-resolution model (pane re-resolution after restart, name-mismatch and remote refusals, recovery by label, fail-closed cases), the `send_literal`-never-auto-submits rule, capture and composer routing including the Cursor reclassification and its process-identity gate, the `hook_state` mapping, forced teardown of a row whose window is already gone, discovery scoping, endpoint-metadata validation, both halves of the detection rule, and both halves of the same rule in away-mode captain-pane discovery.
- `tests/thurbox-test-safety.sh` - the fail-closed guard that keeps any thurbox test away from a real thurbox, over **both** CLIs the adapter drives: the `thurbox-cli` in `FM_THURBOX_BIN` and the `tmux` that would be resolved from `PATH`.
- `tests/fm-backend.test.sh` - shared dispatcher and detection contract; every case neutralizes `THURBOX_SESSION` so the suite stays deterministic when run from inside a thurbox session.
