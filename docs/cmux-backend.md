# cmux runtime backend (experimental)

This document records the empirical verification behind `bin/backends/cmux.sh`, the cmux session-provider adapter.
It is the cmux equivalent of the tmux facts recorded in the `harness-adapters` skill and of `docs/herdr-backend.md`'s/`docs/zellij-backend.md`'s/`docs/orca-backend.md`'s facts for those backends.

cmux is [a Ghostty-based macOS terminal](https://cmux.com) built for AI coding agents, with vertical tabs, notifications, and a CLI/socket JSON-RPC control API (`cmux <verb> ...`).
Verified against the real installed app: cmux 0.64.17 (build 97), macOS aarch64.
The feasibility investigation that preceded this build (`data/cmux-backend-feasibility-c7/report.md`) verified the app's CLI surface from source only, flagging a live install-and-poke pass as the remaining gate; that pass is what this document and `tests/fm-backend-cmux-smoke.test.sh` record.
All real-cmux verification here and in the smoke test creates only `fm-test-`-prefixed workspaces, touches and closes only what it created, never enumerates-and-closes, and never quits or relaunches the app - the same discipline `tests/herdr-test-safety.sh`/`tests/zellij-test-safety.sh` established for their backends, adapted in `tests/cmux-test-safety.sh` to cmux's shape (there is no isolated, throwaway session to spin up - cmux is one shared, GUI-first app instance, the same posture as Orca).

## Setup

Pick cmux if you already run it as your terminal and want firstmate crew tabs to live there instead of tmux.
cmux is **macOS-only** and **GUI-first** - selecting this backend means a real GUI window exists and is running, exactly like Orca's posture.

Prerequisites:

- The cmux app itself, installed from [cmux.com](https://cmux.com) or `brew install --cask cmux`, version 0.64.17 or newer.
- `jq`, required to parse cmux's JSON output: `brew install jq` (or your platform's package manager).
- The same universal requirements as tmux (a verified crew harness, git with GitHub auth, node, treehouse, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi 0.1.1 or newer, and quota-axi); treehouse still provides the worktree, cmux only provides the session.
- The cmux CLI binary is not guaranteed to be on `PATH` after a plain app install (see "CLI is not on PATH by default" below) - the adapter falls back to the well-known bundle path automatically, so this is not a blocker, just something to be aware of if you want to run `cmux` yourself from a shell.

**One-time socket access setup (required, not optional):** cmux's control socket defaults to `automation.socketControlMode: "cmuxOnly"`, which rejects any CLI process not spawned inside cmux itself - firstmate always drives cmux from an external shell, so this must be changed before `backend=cmux` can work at all.
Settings > Automation offers five Socket Control Mode values; their exact semantics were verified from cmux source (see "Socket control modes: the full matrix" below for the enforcement points and evidence):

| Settings label | JSON value | Works for firstmate? | What gates an external client |
|---|---|---|---|
| Off | `off` | no | The socket listener is never started at all. |
| cmux processes only | `cmuxOnly` (the default) | no | A connect-time check that the peer process is a descendant of the cmux app - an external shell never is. |
| Automation mode | `automation` | **yes - recommended** | Only the socket file's owner-only (0600) permissions: any process of YOUR macOS user connects, with no password and no ancestry check. |
| Password mode | `password` | yes, with a password | An `auth <password>` handshake required before any command; socket file owner-only (0600). |
| Full open access | `allowAll` | yes, **not recommended** | Nothing: no auth, and the socket file is world-writable (0666), so EVERY local user can drive cmux. |

**Recommendation: Automation mode.**
It is the least-friction viable mode, and on a single-user machine it is not materially weaker than Password mode: both expose the socket only to processes of your own macOS user (0600 socket file), and the password's one extra defense - same-user processes that do not know the secret - is largely illusory, because the password itself must sit in a same-user-readable file (`config/cmux-socket-password`, or cmux's own state-dir password file that its CLI auto-reads) for automation to use it at all.
Password mode buys real friction (a secret to set, distribute to firstmate, and rotate) for that marginal defense; pick it if your threat model includes untrusted same-user processes that cannot read your config files.
Full open access hands the socket - which can open workspaces and run arbitrary commands in them - to every local user on a multi-user machine; cmux's own settings UI calls it unsafe, and it buys firstmate nothing over Automation mode (firstmate always runs as your own user), so choose it only as a deliberate, understood trade-off, never as a default.

To set it up:

1. Open cmux's Settings > Automation.
2. Set **Socket Control Mode** to **Automation mode** (recommended).
3. There is no step 3 - no password to configure or distribute.

If you prefer **Password mode** instead: set the mode and a password in Settings > Automation, then make that same password available to firstmate - either as the first line of a local, gitignored `config/cmux-socket-password` file under the effective config directory, or exported as `CMUX_SOCKET_PASSWORD` in the environment firstmate runs in.
`config/cmux-socket-password` is the durable choice; the adapter reads it fresh on every call from `${FM_CONFIG_OVERRIDE:-$FM_HOME/config}` and passes it through without ever overriding an operator's own ambient `CMUX_SOCKET_PASSWORD` when the file is absent.
A configured password is harmless if you later switch to Automation mode: cmux's CLI sends the `auth` handshake preemptively and tolerates the server's "Unknown command 'auth'" reply in non-password modes (verified from source, `cli/cmux.swift` `authenticateSocketClientIfNeeded`).
Do not edit `~/.config/cmux/cmux.json` by hand for any of this: the mode change cannot be applied over the socket that is itself still rejecting connections, and the app's config writer drops a hand-added `socketPassword` key entirely (see "Socket control modes" below for that finding).

Ask the firstmate crew to select cmux by putting `cmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=cmux` for a one-off session; telling the first mate in chat to use cmux also works.
cmux is also selected by **runtime auto-detection**: a firstmate process itself running inside a cmux-spawned terminal (`CMUX_WORKSPACE_ID` set - or, when cmux's bundled claude wrapper stripped that marker, the bundle-id/ancestry fallback signals - checked after `$TMUX`/`HERDR_ENV=1` since cmux is the outermost terminal application, not a nestable multiplexer) spawns new tasks into cmux by default, with no config needed, exactly like herdr's own auto-detection - see "Runtime auto-detection" below.
Auto-detection only ever picks a SESSION provider; it never touches the one-time socket-access setup above, which stays required regardless of how cmux was selected.
A cmux spawn refuses loudly, with an actionable message pointing back to this document, if the app is unreachable, the socket rejects the connection (`cmuxOnly` mode still active), or a password is required but not configured or was rejected; the refusal names every viable mode with Automation mode as the recommendation, plus the `config/backend`/`--backend tmux` opt-out for a caller who ended up on cmux only because auto-detection picked it.

No first-run provisioning beyond the socket-access setup above and having `jq` installed; firstmate creates the workspace it needs on first spawn, launching the app itself (`open -a cmux`) if it is not already running.

Watching and attaching: firstmate uses one workspace per task in whatever cmux window is currently open.
Callers still use firstmate's universal `fm-<id>` selector vocabulary, while the actual cmux workspace title is home-scoped as `fm-<home-label>-<id>`, for example `fm-firstmate-<8hex>-cmux-e2e-t1` in the primary home or `fm-2ndmate-<secondmate-id>-<8hex>-cmux-e2e-t1` in a secondmate home.
You do not need to bring the window forward for routine supervision: `bin/fm-peek.sh fm-<id>` reads a task's surface without focusing it, and `bin/fm-send.sh fm-<id> "<text>"` steers it - workspace/surface/pane creation all default `focus` to `false`, so an unattended spawn never steals your view.

Verify it works by spawning a trivial task with `--backend cmux` and confirming the task's meta records `backend=cmux` plus `cmux_workspace_id=` and `cmux_surface_id=`.
The cmux sidebar should show a new `fm-firstmate-<8hex>-<id>` workspace in the primary home.

Limitations: cmux is experimental, macOS-only, GUI-first (never viable for a headless/CI/SSH-only firstmate instance), has no native busy-state signal, and `--secondmate` spawns are refused until a per-home design exists - see "Known gaps left for a follow-up" at the end of this document.

## Status: experimental

cmux is experimental, exactly like every non-tmux backend in this design.
Select it by putting `cmux` in a local `config/backend` file, by exporting `FM_BACKEND=cmux`, by telling the first mate in chat to use cmux, or implicitly by runtime auto-detection when firstmate itself is already running inside a cmux-spawned terminal - see "Runtime auto-detection" below.
GUI-first and macOS-only stay unchanged by that: cmux is never a candidate for a headless/CI/SSH-only instance, because auto-detection can only fire from inside a live cmux terminal in the first place, which such an instance never is.
Absent `backend=` in a task's meta always means `tmux`; only a cmux task ever carries an explicit `backend=cmux` line.
A cmux spawn refuses loudly if the `cmux` CLI cannot be found, the installed version is older than the verified minimum (0.64), or the control socket is unreachable/unauthenticated (`fm_backend_cmux_version_check`, `fm_backend_cmux_ensure_running`).

## Runtime auto-detection

Verified from the shipped app source (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Spawn/TerminalSurface+StartupEnvironment.swift`'s `applyManagedCmuxContextEnvironment`, cloned read-only from `github.com/manaflow-ai/cmux` at the commit current on 2026-07-04): every terminal surface cmux spawns gets `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, and `CMUX_SOCKET_PATH` (plus the legacy `CMUX_TAB_ID`/`CMUX_PANEL_ID` aliases) injected into its environment, and all five keys are marked `protectedKeys` - non-overridable by anything the spawned shell or its own env config does afterward.
cmux's own CLI corroborates this is a legitimate ambient-identity marker, not incidental: `cmux_open.swift` reads `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` from the environment as its own fallback target when a caller does not pass `--workspace`/`--surface`, exactly how `$TMUX` and `HERDR_ENV`/`HERDR_PANE_ID` work for their own backends.

`fm_backend_detect` (`bin/fm-backend.sh`) checks `CMUX_WORKSPACE_ID` (non-empty) as the PRIMARY cmux marker, not `CMUX_SOCKET_PATH`: the latter is separately documented as a user-settable override for pointing the CLI at a non-default socket path, so its mere presence would not reliably mean "running inside a cmux-spawned terminal" the way `CMUX_WORKSPACE_ID` does.
Nesting still resolves innermost-first, exactly as it does for herdr: `$TMUX` is checked first, then `HERDR_ENV=1`, then the cmux checks last.
cmux is checked last deliberately, not because it is a "lesser" backend, but because it is a terminal application - the outermost layer, like iTerm2/Terminal.app - not a session multiplexer.
Both tmux and herdr can run nested inside a cmux-provided shell (someone starts a tmux or herdr session from within a cmux terminal), but cmux itself cannot run nested inside either of them, so whenever a multiplexer marker is present alongside a cmux signal, that multiplexer really is the innermost, currently-executing layer and must win.
An auto-detected cmux spawn prints the same loud stderr `NOTICE` herdr's auto-detection prints, naming the winning signal and the `config/backend`/`--backend tmux` opt-out; a fallback-signal detection (below) says so explicitly in that notice, so it is visibly distinct from the primary-marker case.

Auto-detection selects the SESSION provider only.
It has no bearing on the one-time socket-access setup ("Setup" above): a viable `automation.socketControlMode` is still required for the very first cmux-backed spawn to succeed, auto-detected or explicit, and the existing loud spawn refusal (`fm_backend_cmux_ensure_running`) still fires when it is missing.
That refusal message names the viable modes and the `config/backend`/`--backend tmux` opt-out, so a captain who never explicitly chose cmux - and only landed on it because firstmate happened to be launched from inside a cmux terminal - gets a self-contained answer either way: finish the socket setup to actually use cmux, or opt out back to tmux.

The original build's env-injection finding rested on the source read above alone; it has since been corroborated live (2026-07-04, cmux 0.64.17 build 97): the inherited environment of a tmux server started from a cmux tab on the reference machine carries `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`, `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `__CFBundleIdentifier=com.cmuxterm.app` into every pane, and firstmate separately confirmed the full injected set on a live tab shell via `ps eww`.

### The bundled claude wrapper strips `CMUX_*` (unanticipated, load-bearing finding)

Verified live 2026-07-04 against the installed cmux 0.64.17 (build 97), macOS aarch64; the captain's app was not modified, relaunched, or reconfigured for any of this.

`claude` typed in a cmux tab does not run the real binary: cmux prepends a per-surface shim directory (`$CMUX_CLAUDE_WRAPPER_SHIM_ROOT`) to `PATH`, resolving `claude` to `/Applications/cmux.app/Contents/Resources/bin/cmux-claude-wrapper`, a readable bash script.
Read from that shipped script, the wrapper has three exec paths:

1. The hooks-injecting main path (in cmux, socket reachable): KEEPS every `CMUX_*` var and adds more (`CMUX_CLAUDE_PID`, launch metadata).
2. The hooks-disabled path (`CMUX_CLAUDE_HOOKS_DISABLED=1`): KEEPS `CMUX_*`, unsets only `CLAUDECODE`.
3. The passthrough path (not in cmux, OR the socket probe fails): when in cmux, runs `for cmux_key in "${!CMUX_@}"; do unset "$cmux_key"; done` plus `unset TERMINFO` (and `CLAUDECODE`) before `exec`'ing the real claude.

The wrapper's socket probe is `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=0.75 cmux --socket "$CMUX_SOCKET_PATH" ping`, with NO password.
Reproduced verbatim on this machine's live password-mode socket: `Error: ERROR: Authentication required - send auth <password> first`, exit 1.
So under Password mode - exactly the setup this document used to require - the probe always fails and the wrapper always takes the stripping passthrough path.

The strip itself was reproduced end to end with a fake `claude` on `PATH` that dumps its environment, invoking the real wrapper with `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH` (the live socket), `__CFBundleIdentifier=com.cmuxterm.app`, `TERMINFO`, and `CLAUDECODE` set: the fake claude saw ONLY `__CFBundleIdentifier=com.cmuxterm.app` - every `CMUX_*` var, `TERMINFO`, and `CLAUDECODE` were gone.
The counterfactual run with `CMUX_CLAUDE_HOOKS_DISABLED=1` added preserved every `CMUX_*` var (only `CLAUDECODE` was unset), confirming the strip is specific to the passthrough path.

Consequence: a claude-harness firstmate launched inside a cmux tab can have zero `CMUX_*` env, so `CMUX_WORKSPACE_ID` alone cannot be the whole detection contract.
Other harnesses launched from a cmux tab are unaffected (cmux ships no wrapper shims for them).

### Fallback signals: bundle id first, then process ancestry

When (and only when) `CMUX_WORKSPACE_ID` is absent - and `$TMUX`/`HERDR_ENV` did not already win - `fm_backend_detect` consults two macOS-only fallback signals, in order (`fm_backend_detect_cmux_fallback`, guarded on `uname` = `Darwin` since cmux itself is macOS-only):

1. **Bundle id:** `__CFBundleIdentifier` equal to `com.cmuxterm.app`.
   LaunchServices sets this app-identity variable for every process an app bundle launches, it is inherited down the process tree, and the wrapper does not strip it (verified in the fake-claude repro above).
2. **Process ancestry:** the parent chain from the current process reaches the running cmux app (`fm_backend_detect_cmux_app_is_ancestor`).
   The app is resolved by bundle id, never a hardcoded install path: `lsappinfo info -only pid -app com.cmuxterm.app` printed `"pid"=44127` for the live app (and prints nothing, exit 0, for a non-running bundle id), with a bundle-shaped `ps` comm match (`*/cmux.app/Contents/MacOS/cmux`, any install location) as the fallback when lsappinfo cannot resolve a pid.
   Live process-table facts recorded 2026-07-04: the cmux app runs as `/Applications/cmux.app/Contents/MacOS/cmux` (pid 44127, ppid 1), and its tab shells are parented through `/usr/bin/login` (e.g. `44204 44127 /usr/bin/login`), so a claude-under-cmux's chain is claude <- tab shell <- login <- cmux app.

Which signal is authoritative when:

- **Wrapper-stripped claude directly in a cmux tab** (the common case): both signals are present; the bundle id is checked first because it is a pure env read, and it is authoritative.
- **Environment-scrubbed launch under cmux** (an `env -i`-style invocation with no inherited `__CFBundleIdentifier`): ancestry is the only signal left, and it is authoritative.
- **Inside a tmux server that was started from a cmux tab**: ancestry is structurally UNUSABLE - the tmux server reparents to launchd (verified live: the reference machine's own cmux-started tmux server has ppid 1), so the walk can never reach cmux - while the bundle id IS inherited into every pane and WOULD false-positive.
  `$TMUX` winning first is what keeps that correct; the fallbacks are never consulted when a multiplexer marker is present.
  `tests/fm-backend.test.sh` pins this exact case (`test_backend_detect_cmux_fallback_tmux_nested_false_positive`), alongside the bundle-id, ancestry (pid and comm), non-Darwin-guard, and launchd-stop paths.
- **SSH sessions, cron, launchd agents**: neither signal fires - sshd/cron reset the environment (no bundle id) and their ancestry ends at launchd.

The positive ancestry walk itself is exercised by fake `ps`/`lsappinfo` unit tests rather than live (running a probe process genuinely parented under the captain's live cmux tabs was judged too intrusive, the same posture as this document's screenshot note); every negative live fact above - the strip, the wrapper ping failure, the tmux reparenting, the bundle-id inheritance, the lsappinfo resolution shapes - was verified against the real machine on 2026-07-04.

## Worktree provider stays treehouse

cmux is a session provider only, exactly like herdr and zellij (unlike Orca, which also owns the task worktree).
Treehouse remains the worktree provider.
The feasibility report searched cmux's source for a shipped git-worktree-owning feature and found only a prototype (`Sources/ExtensionWorktreePrototype.swift`) that is not wired into any CLI verb - `workspace.create --cwd <path>` just opens a terminal at an existing directory with no opinion about how that directory came to exist.

## Task container shape: one workspace per task, one surface

cmux's hierarchy is macOS window -> workspace (a vertical-tab entry, cmux's rough analogue of a herdr/zellij tab) -> surface (a pane/split within that workspace).
There is no "session" concept to multiplex the way tmux/herdr/zellij have - there is just "the app" (one running GUI instance, optionally split across native macOS windows).
firstmate uses **one cmux workspace per task**, keyed by the caller-facing `fm-<id>` label, with exactly one surface inside it - mirroring tmux's one-window-per-task and zellij's one-tab-per-task shape.
The caller-facing task label stays `fm-<id>`, but the visible cmux workspace title is `fm-<home-label>-<id>`.
The home label keeps the same readable identity as herdr's workspace split - `firstmate` for the primary home, or `2ndmate-<id>` when `$FM_HOME/.fm-secondmate-home` contains a secondmate id - and appends a short stable hash of the resolved `FM_ROOT` path.
That yields labels like `firstmate-<8hex>` or `2ndmate-<id>-<8hex>`, making the visible workspace title `fm-firstmate-<8hex>-<id>` or `fm-2ndmate-<id>-<8hex>-<task>`.
This was hardened in two captain-directed no-mistakes review gate follow-ups: first by adding the home tag for primary-vs-secondmate collisions, then by adding the `FM_ROOT` hash so two distinct primary installations cannot collide either.
Physically moving or relocating a firstmate installation changes its tag, so workspaces titled under the old tag stop matching after a move.
That is acceptable because a task's own recorded worktree path in `state/<id>.meta` does not survive a repo relocation either, so this is consistent with an existing, already accepted limitation, not a new one.
There is still no per-home cmux container split (unlike herdr's later refinement); the home tag is a title discriminator only.

## Target string and meta fields

A cmux task's `window=` meta field holds `<workspace_uuid>:<surface_uuid>`, for example `F28BB910-E42C-40F6-AC5C-D92635581EED:A3E9D3A8-BE1D-4055-A567-3525320D2ABF`.
Both are bare UUIDs with no embedded colon, so splitting on the first colon is trivially correct (mirrors herdr's/zellij's target-string convention).
The meta target is still the UUID pair, not the human title.
The human title is reconstructed internally from the caller-facing `fm-<id>` label as `fm-<home-label>-<id>` whenever cmux needs to create, recover, or list a workspace.
`<home-label>` includes the readable home prefix and the short `FM_ROOT` path hash described above.
cmux tasks additionally record:

- `cmux_workspace_id=` - the task's workspace UUID (same value as the `window=` field's first component).
- `cmux_surface_id=` - the task's surface UUID (same value as the `window=` field's second component).

No session field is needed - unlike herdr/zellij there is no session layer to record.

## Verified CLI facts

| Operation | Verified cmux call | What was verified |
|---|---|---|
| Version gate | `cmux version` -> `"cmux 0.64.17 (97) [9ed29d81a]"` | Works with NO socket connection at all - a pure client-version check, verified even while the socket was still rejecting connections. |
| Reachability/auth gate | `cmux ping` -> `"PONG"` or a typed error | Classified into `ok`\|`denied`\|`unauth`\|`down`\|`error` from the error text (`fm_backend_cmux_ping_state`); `fm_backend_cmux_ensure_running` launches the app (`open -a cmux`) only for `down`, and fails fast with an actionable message for `denied`/`unauth` since relaunching cannot fix a configuration problem. |
| Duplicate task check | `cmux workspace list --json --id-format uuids`, match by home-scoped `.title` | cmux enforces NO title uniqueness for workspaces OR surfaces/tabs - verified live: two workspaces, and two surfaces within one workspace, all created successfully sharing one title. The adapter's own duplicate check is required, mirroring herdr/zellij, and it checks the scoped title such as `fm-firstmate-<8hex>-<id>`. |
| Create task workspace | `cmux new-workspace --name <scoped-title> --cwd <dir> --focus false --id-format uuids` | Creates a workspace with exactly one default surface. `--focus` verified to already default to `false` for workspace/surface/pane creation - no focus-restore dance needed, unlike zellij. The caller passes `fm-<id>`, but the adapter creates `fm-<home-label>-<id>`. |
| Workspace/surface id resolution | `cmux workspace list --json --id-format uuids` (find by home-scoped title), then `cmux list-panes --workspace <id> --json --id-format uuids` (`.panes[0].selected_surface_id`) | A freshly created workspace already has exactly one surface, so no separate `new-surface` call is needed. `--id-format uuids` (or `both`) is required to get a bare `id` field in JSON; the default JSON shape returns only short `ref` strings like `"workspace:2"`. |
| Liveness / target readiness | `cmux list-panes --workspace <id> --json --id-format uuids`, checking the surface id appears in `.panes[].surface_ids` | Structural existence check, NOT a content read - see "read-screen fails on a genuinely fresh surface" below for why `read-screen` cannot be used here. Verified reliable on a completely untouched fresh surface, unlike `read-screen`. |
| Send literal (unsubmitted) | `cmux send --workspace <id> --surface <id> -- <text>` | Verified live: does NOT auto-submit - text sits at the prompt, unexecuted, until a separate Enter. Matches every other backend's "literal-then-separate-Enter" contract. The `--` separator keeps option-shaped text such as `--help` literal. |
| Send key | `cmux send-key --workspace <id> --surface <id> <key>` | Verified names: `enter`, `escape`, `ctrl-c` all work directly (lowercase, hyphenated). Escape is natively supported (unlike Orca); Ctrl-C correctly interrupted a running `sleep 100` in a live test. cmux's own key vocabulary is richer still (`ctrl-d`/`ctrl-z`/`ctrl-\\`, semantic aliases `sigint`/`sigtstp`/`sigquit`), but firstmate's shared vocabulary only needs these three today. |
| Send + submit, composed | `send` then `send-key enter` | cmux has no single-call atomic "type and submit" primitive (unlike tmux's `send-keys ... Enter` or herdr's `pane run`); `fm_backend_cmux_send_text_line` composes the two calls, mirroring zellij's equivalent composition. |
| Bounded capture | `cmux read-screen --workspace <id> --surface <id> --scrollback --lines <N> --json`, trimmed locally with `tail` | No herdr-style small-N empty-result bug: N=1..10 all verified to return correctly-clamped, non-empty content on an already-interacted-with surface. A single call is still bounded by the surface's actual current viewport height regardless of the requested `--lines` value (verified: capped at 16 rows in a headless/no-attached-window test run), so "fetch generous, trim locally" is kept for consistency even though the specific herdr bug does not reproduce. |
| Worktree-path discovery | marked active cwd probe + capture-scrape (`fm_backend_cmux_current_path`), NOT `current_directory` | `current_directory` DOES reflect a `cd` run directly in the surface's own top-level shell, but stays FROZEN at wherever that shell was when it launched a foreground subshell (exactly what `treehouse get` does) - zellij-shape, not herdr-shape. See "Worktree-path discovery: current_directory does not track a subshell" below. |
| Busy state | *(no native primitive)* | cmux has agent-awareness elsewhere (Claude Code hooks integration, session-resume tokens) but exposes nothing over the socket API for generic busy/idle classification; `surface.health`/`surface-health` is render health, not agent status. `fm_backend_busy_state`'s dispatcher (`bin/fm-backend.sh`) falls through to `unknown` for cmux via its wildcard case, exactly like tmux/zellij/Orca - the watcher's existing pane-hash + regex path is the only busy-state source for this backend. |
| Kill | `cmux close-workspace --workspace <id>` | See "Closing the last surface: a third shape" below. The backend owns the whole task workspace, so kill closes the whole workspace directly, best-effort (`\|\| true`), matching every other backend's `kill` contract. |
| Recovery / list-live | `cmux workspace list --json --id-format uuids`, filter titles starting with this home's `fm-<home-label>-`, then `list-panes` per match for the surface id | Title-based, never trusts a stored workspace uuid blindly - ids do NOT survive an app relaunch (see "Workspace ids do not survive a relaunch" below), so this is the only safe recovery posture. The adapter prints the plain `fm-<id>` label back to callers after stripping the readable home tag and `FM_ROOT` hash. |

## Socket control modes: the full matrix (default `cmuxOnly` rejects external CLIs)

Not anticipated by the feasibility report (which verified the CLI surface from source only, without a live socket connection): cmux's control socket, by default, **rejects any client process that was not itself spawned inside cmux**.
Verified live (2026-07-03 pass): running any socket-backed CLI command (`cmux ping`, `cmux workspace list`, etc.) from an ordinary external shell - exactly how firstmate always drives cmux - returned `Error: ERROR: Access denied - only processes started inside cmux can connect`.

The setting is `automation.socketControlMode` in cmux's settings (`~/.config/cmux/cmux.json` or Settings > Automation), with values `off`, `cmuxOnly` (the default), `automation`, `password`, and `allowAll` (three more legacy aliases - `openAccess`, `fullOpenAccess`, `full` - normalize onto `allowAll`; `notifications` normalizes onto `automation`).

The per-mode enforcement was traced through the shipped source on 2026-07-04 (`github.com/manaflow-ai/cmux` at commit `9c91710e3f58`, cloned read-only as scratch; verified from source, not live, except where noted - the reference machine's live app is the captain's own, in Password mode, and was not reconfigured to exercise the other modes).
There are exactly four enforcement points, and NO per-command/verb restrictions by mode - a mode either admits a client fully or not at all:

- **Listener start** (`Sources/AppDelegate.swift`, `socketListenerConfigurationIfEnabled`): `off` means the listener is never started; every other mode starts it.
- **Socket file permissions** (`SocketControlMode+SocketControl.swift`, `socketFilePermissions`): `allowAll` chmods the socket 0666 (every local user); all other modes 0600 (owner only).
- **Connect-time ancestry check** (`Sources/TerminalController.swift`, `handleClient`): applied ONLY when the mode is `cmuxOnly` - the peer pid must be a process-tree descendant of the cmux app, which an external shell never is (the live 2026-07-03 rejection above is this check firing).
- **Password handshake** (`Sources/TerminalController.swift`, `authResponseIfNeeded`, gated on `requiresPasswordAuth`, true ONLY for `password`): every command line before a successful `auth <password>` gets an auth error; the three auth-failure texts are "Authentication required - send auth <password> first" (no password presented; also reproduced live on this machine's password-mode socket, 2026-07-04), "Password mode is enabled but no socket password is configured in Settings." (app side has no password), and "Invalid password" (wrong password presented).

So for an external, same-user CLI client like firstmate: `automation` admits it with no credential (its only gate is the 0600 socket file), `password` admits it after the handshake, `allowAll` admits it and every other local user too, and `off`/`cmuxOnly` never admit it.
`automation` is the recommended mode for firstmate, with `password` and `allowAll` as supported alternatives - the "Setup" section above carries the decision rationale.
This build's earlier pass (2026-07-03) chose `password` as "the minimum change that unblocks external CLI access"; the matrix trace above superseded that with `automation`, which reaches the same same-user boundary without the shared-secret friction.

A real wrinkle found during the 2026-07-03 password-mode setup, still true and worth keeping: **`automation.socketPassword` cannot be set durably through `cmux.json`** - the app's own config writer normalizes the file on reload/restart and drops the `socketPassword` key entirely (it is kept only in a dedicated password store/Settings, not the plaintext JSON), so editing the file to include a password has no lasting effect and cmux's own `cmux reload-config` cannot apply the `socketControlMode` change either, because reload-config is itself a socket call, and the socket is what needs the mode change to accept it in the first place.
The practical path (and what "Setup" above describes) is: set the mode (and password, if choosing Password mode) once through Settings > Automation (a GUI action - the socket-access chicken-and-egg problem does not exist there), then, for Password mode, supply that same password to firstmate via `config/cmux-socket-password` or `CMUX_SOCKET_PASSWORD`.
`CMUX_SOCKET_PASSWORD` in the CLI **client's** own environment is confirmed sufficient (per cmux's own CLI contract, it is the documented fallback when `--password` is absent) - `fm_backend_cmux_cli` exports it only when a value is actually configured, so an operator's own ambient `CMUX_SOCKET_PASSWORD` is never clobbered with an empty value.
cmux's CLI also auto-reads the app's own password file (`socket-control-password` in the cmux state directory) when neither `--password` nor the env var is set, but do not rely on that for firstmate: on the reference machine the app's password lives only in the password store (no state-dir file exists), so the explicit `config/cmux-socket-password`/`CMUX_SOCKET_PASSWORD` supply is the dependable path.

`fm_backend_cmux_ping_state` classifies the resulting failure text into `denied` (`cmuxOnly` still active) or `unauth` (password mode active but no/wrong password presented, covering all three auth-failure texts above), and `fm_backend_cmux_ensure_running`/`fm_backend_cmux_version_check`'s callers surface an actionable message naming the viable modes and pointing back to this document for either state - never a generic "is cmux installed?" message, and never a retry-via-relaunch (relaunching the app cannot fix a socket-mode/password configuration problem).
`off` is indistinguishable on the wire from "app not running" (`Socket not found`, classified `down`), so the launch-and-wait path's timeout message names the possibility that the app is running with its socket off.

## `read-screen` fails on a genuinely fresh surface (unanticipated, load-bearing finding)

Not anticipated by the feasibility report or by the original design sketch (which proposed using `read-screen` as the liveness probe, mirroring Orca's `fm_backend_orca_capture` doubling as its own liveness check).
Verified live: `cmux read-screen --workspace <id> --surface <id>` against a surface that was JUST created and has never been written to yet fails outright with `Error: internal_error: Failed to read terminal text` - for every `--lines` value tried (including no `--lines` flag at all), and regardless of how long you wait (retried up to several seconds later, still failing).
The moment a single `send` actually writes to that same surface, `read-screen` becomes reliably readable forever after.

This ruled out `read-screen` as the liveness/readiness probe: the very first `send_literal` call on a freshly created task's surface would fail its own pre-flight readiness check before ever getting to write anything, making every task un-spawnable.
`cmux list-panes --workspace <id> --json --id-format uuids`, checking the target surface id appears in `.panes[].surface_ids`, has no such gap - verified correct and immediate on a completely untouched fresh surface - so `fm_backend_cmux_target_ready` uses that instead, mirroring zellij's own structural `pane_exists` check rather than Orca's read-based liveness pattern.

## Worktree-path discovery: `current_directory` does not track a subshell (zellij-shape, not herdr-shape)

Verified live, step by step, mirroring the exact test that caught this for zellij:

1. A plain `cd /var` typed directly into a surface's own top-level shell updates `cmux workspace list --json`'s `current_directory` field immediately.
2. Running a nested subshell as a foreground command (`bash -c 'cd /Users && exec bash'`, standing in for `treehouse get`'s own nested interactive subshell) and confirming on-screen (via `pwd` typed inside the now-interactive nested shell) that it truly is in the new directory - `current_directory` stays **frozen** at `/var`, the directory the TOP-LEVEL shell was in when it launched the subshell. It never updates once a subshell has taken over as the surface's foreground process.

This is the same shape zellij's `pane_cwd` has, not herdr's live-tracking `foreground_cwd`.
**Workaround, `fm_backend_cmux_current_path`:** reuses zellij's own active pwd-marker-probe technique verbatim in spirit - submit a begin marker, `pwd`, and an end marker via `send_text_line`, briefly settle, capture, and read only the lines between the markers.
Verified against the real binary in both shapes: a direct `cd` in the surface's own shell, and a nested subshell's own `cd` (the load-bearing case matching `treehouse get`'s actual shape) - both confirmed correct in `tests/fm-backend-cmux-smoke.test.sh`.

## Closing the last surface: a third shape (unanticipated finding)

The design sketch anticipated two possibilities for closing a workspace's last surface - herdr-shape (auto-closes the whole workspace) or zellij-shape (leaves an empty "ghost" workspace) - and planned to verify which one live.
Neither turned out to be correct: cmux implements a **third** shape.
Verified live: `cmux close-surface --workspace <id> --surface <id>` against a workspace's LAST remaining surface **refuses outright** with a typed error, `Error: invalid_state: Cannot close the last surface`, leaving both the surface and the workspace completely untouched - no partial state, no ghost.
`cmux close-workspace --workspace <id>` against that same workspace succeeds cleanly, removing the whole workspace (surface included) in one call, verified with no ghost left behind afterward.

Since every firstmate cmux task uses exactly one owned workspace, `close-workspace` is the correct teardown primitive.
The no-mistakes review gate follow-up was captain-directed here too: `fm_backend_cmux_kill` now calls `close-workspace` directly and best-effort, reclaiming the whole task workspace and any surfaces inside it.
That matches the backend ownership invariant more closely than preserving user-added surfaces in a task workspace that firstmate is about to forget.

## Workspace ids do not survive a relaunch (verified from source, not a live restart)

Per this task's explicit instruction NOT to relaunch the captain's app just to test this, this was verified by reading the actual shipped Swift source instead (`Sources/Workspace.swift`, cloned read-only from `github.com/manaflow-ai/cmux` at the commit current on 2026-07-04):
`Workspace`'s only initializer unconditionally sets `self.id = UUID()`, with no restored-id parameter at all.
This differs from surfaces, whose analogous initializer DOES accept `restoredSurfaceId: UUID? = nil` and use `restoredSurfaceId ?? UUID()` - but tracing every call site of that parameter showed it is used only for same-run object-identity reuse (e.g. moving/splitting an already-live surface within the current app session), never threaded through any session-restore/relaunch code path.
No `Workspace(...)` construction anywhere in the source passes a persisted id back in.

Conclusion: workspace ids should be treated as NOT surviving an app relaunch or session restore, the same posture as herdr's/zellij's own id-instability caveats (for different underlying reasons in each case).
`fm_backend_cmux_list_live` therefore does recovery/orphan discovery strictly by **title**, never by trusting a stored uuid, mirroring both prior adapters' recovery posture.
Because cmux has one shared app namespace, the title lookup is scoped to this firstmate installation's `fm-<home-label>-` prefix and reported back to firstmate as the plain `fm-<id>` label.
No live app restart was performed to empirically confirm this beyond the source read - the two live app restarts that did occur during this build (documented in the "Socket control modes" section above) were solely to apply the one-time `socketControlMode`/password configuration change, not to test id persistence, and the app held no captain-owned workspaces at either restart (verified: it had just been freshly launched moments before, with only the default auto-created workspace present).

## CLI is not on PATH by default (unanticipated finding)

Unlike a typical Homebrew-installed CLI tool, the `cmux` binary is not symlinked onto `PATH` after a plain app install - `command -v cmux` returns nothing on a fresh install.
The app source (`Sources/App/CmuxCLIPathInstaller.swift`) reveals cmux ships an OPTIONAL "install CLI" action (symlinking `/usr/local/bin/cmux` to the bundled `Contents/Resources/bin/cmux`), analogous to VS Code's "Install 'code' command in PATH" - it is opt-in, not automatic.
`fm_backend_cmux_bin` handles this without requiring that step: it prefers `command -v cmux` (respecting an operator's own PATH setup, including after running that install action) and falls back to the well-known bundle path `/Applications/cmux.app/Contents/Resources/bin/cmux` otherwise.

## Duplicate-title behavior (verified, expected finding)

Same as herdr's tabs and zellij's tabs, unlike tmux's own window-name uniqueness: cmux enforces no title uniqueness at all for workspaces or for surfaces/tabs within a workspace.
Verified live: two workspaces created with the identical title `fm-test-dup` both succeeded and listed simultaneously with distinct ids; two surfaces within one workspace both renamed to the identical tab title also succeeded.
`fm_backend_cmux_create_task`'s own title-based duplicate check is therefore required, mirroring both prior adapters' posture exactly.

## Composer verification: structural border-row classification (adapted from herdr)

cmux's `read-screen` gives plain-text capture with no cursor-row/ANSI-only primitive, the same shape herdr's `pane read` has (unlike tmux's `#{cursor_y}`).
Per this build task's explicit direction, `fm_backend_cmux_composer_state` is adapted directly from herdr's post-incident structural border-row classifier (`fm_backend_herdr_composer_state`, `docs/herdr-backend.md`) rather than zellij's content-diff approach: it locates the composer's own row as the only captured line whose trimmed content both starts and ends with the same border glyph (`│`, `┃`, or a plain ASCII `|`), scanning forward and keeping the LAST match so an earlier border-shaped line can never outrank the real bottom-anchored composer row.
This directly defends against the same class of incident herdr hit on 2026-07-03: a slash-command popup's first Enter can close the popup and fill an argument-hint placeholder into the composer rather than submitting, which a raw pane-content-diff check (zellij's approach) would misread as "submitted".
`tests/fm-backend-cmux.test.sh` pins this exact regression shape (`test_send_text_submit_popup_autocomplete_requires_second_enter`), verifying the adapter retries a genuine second Enter rather than declaring victory after the first one closes a popup.
All four backends (tmux, herdr, zellij, cmux) expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no cmux-specific branching.

## Test safety

Unlike herdr/zellij, cmux has no isolated, throwaway SESSION a test can spin up and tear down on its own - there is just "the app", the same real running instance a captain uses day to day.
`tests/cmux-test-safety.sh`'s guard is adapted to this shape: `cmux_refuse_if_unsafe` requires a non-empty workspace id, a caller-facing label carrying the `fm-test-` prefix, and that the workspace is CURRENTLY LISTED with the scoped title derived from that label, before `cmux_safe_close_workspace` is allowed to close it.
Every real-cmux test in this document and its accompanying test files creates only `fm-test-`-prefixed task labels, never enumerates-and-closes, and never quits or relaunches the app.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-cmux.test.sh`) and the real-CLI smoke test (`tests/fm-backend-cmux-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and the same captain-owned real cmux app instance (there is no isolated session to spin up for cmux, unlike herdr/zellij; only firstmate-created `fm-` task workspaces were ever touched):

1. `FM_HOME=<scratch> bin/fm-spawn.sh cmux-e2e-t1 projects/scratch-e2e-project --backend cmux claude` - spawned successfully, printing `window=<workspace_uuid>:<surface_uuid>` in the summary and writing `backend=cmux`, `cmux_workspace_id=`, `cmux_surface_id=` to the task's meta. The worktree-discovery poll correctly resolved the real treehouse worktree path using the active `pwd`-marker-probe workaround (finding #2), exactly as designed.
2. `bin/fm-peek.sh fm-cmux-e2e-t1` - showed the live claude trust dialog ("Quick safety check: Is this a project you created or one you trust?").
3. `bin/fm-send.sh fm-cmux-e2e-t1 --key Enter` - accepted the trust dialog; `send_key`'s Escape/Enter path confirmed live against the real claude TUI, not just a plain shell.
4. `bin/fm-peek.sh fm-cmux-e2e-t1` again - showed claude actively working through the brief (confirming worktree isolation, writing `hello.txt`, committing).
5. `bin/fm-send.sh fm-cmux-e2e-t1 "captain says: proceed as planned, this is a trivial verification task"` - a plain-text steer sent after the crewmate had already finished and stopped; `fm-send` reported no `pending`/`send-failed` error, and the message was confirmed landed and acknowledged in the next peek. This is the first live proof of `fm_backend_cmux_composer_state`'s structural border-row classifier against a REAL claude TUI composer box (every Phase 1 empirical test used a plain shell prompt, which has no bordered composer at all).
6. `bin/fm-send.sh fm-cmux-e2e-t1 "/compact"` - the popup-placeholder/second-Enter regression class, tested live: `fm-send` reported success with no error, and the next peek confirmed `/compact` had genuinely EXECUTED ("Compacting conversation... 25%", later "Compacted"), not merely sat typed-but-unsubmitted in the composer. This directly confirms `fm_backend_cmux_send_text_submit` correctly retries past a popup-closing first Enter and lands a genuine second Enter against the real app, the same incident class herdr hit on 2026-07-03.
7. The crewmate's commit (`add hello.txt`, message `add hello.txt`) was confirmed present on branch `fm/cmux-e2e-t1` in the scratch project's git history, with `hello.txt` containing exactly the expected line, and the status file ending in `done: ready in branch fm/cmux-e2e-t1`.
8. `bin/fm-teardown.sh cmux-e2e-t1` **REFUSED**, exactly as required: `REFUSED: local-only worktree ... has work not yet merged into main and not on any remote.`
9. `bin/fm-merge-local.sh cmux-e2e-t1` - fast-forwarded the scratch project's local `main` to the crewmate's commit (`e99f00a -> f064d41`).
10. `bin/fm-teardown.sh cmux-e2e-t1` now succeeded: terminated the lingering worktree processes, returned the treehouse worktree, closed the cmux workspace (confirmed gone via `workspace list` - only the pre-existing default workspace remained), and removed all of the task's `state/` files.
11. Two additional trivial crewmate tasks (`cmux-e2e-t2`, `cmux-e2e-t3`) were spawned concurrently into the same scratch project via `fm-spawn.sh`'s batch dispatch form, to exercise multiple simultaneous cmux workspaces; both reached their trust-accepted, standing-by state cleanly, were peeked successfully, and were torn down (clean worktrees, no unlanded work) with the same `fm-teardown.sh` path.

All three tasks' cmux workspaces and worktrees were confirmed fully cleaned up afterward (`workspace list` showing only the pre-existing default workspace; `treehouse destroy --all --yes` freeing the scratch project's pool); the scratch `FM_HOME` and project were removed entirely.

**Screenshot request (best-effort, explicitly skippable):** the captain separately asked for a screenshot of the cmux window while multiple concurrent tasks were running, to be kept only if it showed a genuinely healthy fleet with no visible errors. One `screencapture -x` (full-screen) attempt was made while all three tasks above were live. It did NOT capture cmux at all: because every firstmate cmux workspace is created with `--focus false` (finding: focus verified to default off), cmux is never the frontmost/active application, so a full-screen capture on this shared machine captured a completely different, unrelated live terminal session's frontmost window instead - one that turned out to show real, sensitive operational content (a different active firstmate/herdr fleet with real secondmate names and conversation). That file was deleted immediately without being viewed further or retained anywhere. No second attempt was made: bringing cmux to the foreground to make it capturable would mean actively focusing/raising its window, which would yank focus away from whatever the captain or another live session currently has in the foreground - the exact disruption `--focus false` exists to avoid - and enumerating other windows to target a background-window capture of just cmux risks the same kind of unrelated-content exposure. Per the captain's explicit allowance, this request was skipped rather than risk either disruption or another accidental capture.

## Known gaps left for a follow-up

- **No event push at all**, not even herdr's semantic busy-state: cmux has agent-awareness elsewhere (Claude Code hooks, session-resume) but nothing exposed over the socket API for generic busy/idle classification, so `fm-watch.sh`'s existing pane-hash + `FM_BUSY_REGEX` poll loop is the ONLY event source for this backend, identical to the tmux/zellij/Orca path.
- **GUI-first, macOS-only, requires the app running** - identical posture to Orca.
  Never a candidate for a headless/CI firstmate instance, because runtime auto-detection (cmux runtime signals; see "Runtime auto-detection" above) can only fire from inside a live cmux terminal in the first place.
  The one-time socket-access setup remains an unavoidable manual step regardless of how the backend was selected.
- **`--secondmate` spawns are refused** (mirrors Orca's refusal) - no per-home container design (a herdr-style workspace-per-home split, or similar) has been designed or verified for cmux yet.
- **The one-time socket-access setup is a real, undocumented-by-upstream onboarding step.** A captain who selects `backend=cmux` without first switching `automation.socketControlMode` away from its `cmuxOnly` default to a viable mode (Automation mode recommended; see "Setup") will see every spawn fail with an actionable error naming the viable modes and pointing back to this document, but there is no way for firstmate to complete that GUI-only setup step on the captain's behalf.
- **Backend-specific bootstrap detection is absent** - `bin/fm-bootstrap.sh` does not conditionally add `cmux` and `jq` when a backend selection resolves to cmux, mirroring the same accepted gap already documented for herdr/zellij; the version/tool/reachability gate happens at spawn time instead and refuses loudly.
- **A surface can still die in the brief window between `target_ready` succeeding and the operation's own call running.** That remaining race degrades to "the operation quietly did nothing" - the same class of gap firstmate already tolerates for an unverified send on any backend, caught downstream by `fm-spawn.sh`'s worktree-discovery poll timing out, `fm_backend_cmux_send_text_submit`'s retry loop (which reports `send-failed`/`pending`/`unknown` rather than a false "sent"), or the watcher's stale-pane detection.
