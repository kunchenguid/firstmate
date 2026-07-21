# Zellij runtime backend (experimental)

This document records the empirical verification behind `bin/backends/zellij.sh`, the zellij session-provider adapter added in P3 of the runtime-backend abstraction.
It is the zellij equivalent of the tmux facts recorded in the `harness-adapters` skill and of `docs/herdr-backend.md`'s herdr facts.

Zellij is [a terminal multiplexer](https://zellij.dev) with a CLI action interface (`zellij action <subcommand>`) for scripted control of sessions, tabs, and panes.
Verified against the real installed binary: zellij 0.44.0, macOS aarch64.
All real-zellij verification in this document and in `tests/fm-backend-zellij-smoke.test.sh` uses isolated, uniquely-named sessions (via `FM_ZELLIJ_SESSION`) plus the guarded teardown helper in `tests/zellij-test-safety.sh` - never the real `firstmate` session name a live fleet would use, and never `kill-all-sessions`/`delete-all-sessions`.

## Setup

Pick zellij if you already use it as your terminal multiplexer and want firstmate crew windows there instead of tmux; it has no per-home container split, so it is simpler than herdr for a single-home fleet.

Prerequisites:

- `zellij` itself, version 0.44 or newer (installed 0.44.0 verified) - see [zellij.dev](https://zellij.dev) for install instructions.
- `jq`, required to parse zellij's JSON output: `brew install jq` (or your platform's package manager).
- The universal firstmate prerequisites - a verified crew harness plus the required toolchain, owned by [`docs/configuration.md`](configuration.md) ("Harness support", "Toolchain"); treehouse still provides the worktree, zellij only provides the session.

Select zellij by putting `zellij` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=zellij` when you launch your harness for a one-off session; telling the first mate in chat to use zellij also works.
Unlike tmux and herdr, zellij is **never** auto-detected - it always requires an explicit choice.
A zellij spawn refuses loudly before creating a session container or acquiring a ship/scout worktree if `zellij` or `jq` is missing or the installed zellij is older than 0.44.
For `--secondmate` launches, secondmate home sync and inherited local-material propagation happen before this spawn-time backend gate.

No first-run provisioning is needed beyond having `zellij` and `jq` on `PATH`; firstmate creates the session and tab it needs on first spawn.

Watching and attaching: firstmate uses one shared session (default name `firstmate`, overridable with `FM_ZELLIJ_SESSION`) with one tab per task.
The tab's caller-facing label is always `fm-<id>`, but its actual visible title is home-scoped - `fm-<home-label>-<id>`, e.g. `fm-firstmate-a1b2c3d4-fix-login-k3` - so that two firstmate homes sharing this one session (a primary plus a secondmate, two secondmates, or two independent primary installations on the same machine) never collide on the tab bar even if their task ids happen to match; see "Home-scoped tab titles" below.
Attach to the selected `FM_ZELLIJ_SESSION` (or the default `firstmate` session) with `zellij attach <name>` to see every task, primary or secondmate, as a tab in that one tab bar.
You do not need to attach for routine supervision: from an active firstmate session, `bin/fm-peek.sh fm-<id>` reads a task's pane without attaching, and `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` steers it unless `FM_HOME` is already set to the active firstmate home.

Verify it works by spawning a trivial task with `--backend zellij` and confirming the task's meta records `backend=zellij` plus `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`; attaching to the session should show the new home-scoped tab title, such as `fm-firstmate-<8hex>-<id>`.

Limitations: zellij is experimental, has no per-home workspace split (all tasks share one tab bar, unlike herdr), has no verified agent-process liveness classifier for the session-start secondmate sweep, and still carries the known gaps documented below (no native busy-state signal and a narrow focus-steal race on tab creation) - see "Known gaps left for a follow-up" at the end of this document.

## Status: experimental

Zellij is experimental, exactly like every non-tmux backend in this design.
Select it by putting `zellij` in a local `config/backend` file, by exporting `FM_BACKEND=zellij`, or by telling the first mate in chat to use zellij.
Unlike tmux and herdr, zellij is **never** selected by runtime auto-detection: the design report's Open Question #2 recommends starting with a dedicated background session for predictability rather than reusing whatever zellij session firstmate itself might be running inside, and empirical verification below (see "Focus-steal on new-tab") confirms that recommendation was correct - reusing an ambient session a human might be attached to would risk yanking their view on every spawn.
Absent `backend=` in a task's meta always means `tmux`; only a zellij task ever carries an explicit `backend=zellij` line.
A zellij spawn refuses loudly if `zellij` or `jq` is missing, or if the installed zellij's version is older than the verified minimum, 0.44 (`fm_backend_zellij_version_check`).

## Worktree provider stays treehouse

Zellij is a session provider only (D3, `data/fm-backend-design-d7/herdr-addendum.md`, restated for zellij in the same task).
Treehouse remains the worktree provider, exactly as it is for tmux and herdr.

## Task container shape: one session, one tab per task

Per the design report's "Zellij implementation choices" #1, unchanged by empirical verification: firstmate uses **one** zellij session (default name `firstmate`, overridable via `FM_ZELLIJ_SESSION` for test isolation - mirrors herdr's `HERDR_SESSION`) and **one tab per task**, whose caller-facing label is `fm-<id>` (its actual, home-scoped tab title is described in "Home-scoped tab titles" below).
This is deliberately simpler than herdr's later workspace-per-firstmate-home refinement (`docs/herdr-backend.md` "Task container shape"): zellij has no workspace concept at all, only sessions/tabs/panes, so there is no analogous per-home container to split - primary and secondmate tasks share the one `firstmate` session's tab bar, distinguished only by their tab titles, exactly as the original P1/P2 tmux-parity shape worked before herdr's per-home split existed.
No empirical evidence surfaced during verification that forces a different container shape; the report's original choice stands - only the tab TITLE gained a per-home discriminator, not the container.

## Home-scoped tab titles (cross-home collision fix)

Because every task in every firstmate home - primary or secondmate - shares this ONE session's tab bar with no per-home container split, and zellij enforces no tab-name uniqueness at all (verified: two tabs can share a name), two firstmate homes whose task ids happen to collide could send/peek/close each other's tabs.
This is the exact gap a captain-directed no-mistakes review gate caught for the cmux backend (`docs/cmux-backend.md` "Task container shape") - cmux's fix was ported here for the identical reason, sharing its tag-derivation code (`bin/fm-backend-hometag-lib.sh`).

The caller-facing task label stays `fm-<id>` in meta and briefs; task-selector resolution is the shared contract owned by [`docs/configuration.md`](configuration.md) ("Runtime backend").
The actual zellij tab title a NEW task's tab is created with is home-scoped: `fm-<home-label>-<id>`.
`<home-label>` is `firstmate` for the primary home, or `2ndmate-<id>` when `$FM_HOME/.fm-secondmate-home` contains a secondmate id, plus a short stable hash of the resolved `FM_ROOT` path - the same identity scheme as cmux's home label (`docs/cmux-backend.md` "Task container shape"), so e.g. `fm-firstmate-a1b2c3d4-fix-login-k3` or `fm-2ndmate-sm1-9f8e7d6c-fix-login-k3`.
The path hash means even two independent PRIMARY installations on one machine (each with no `.fm-secondmate-home` marker, so both would otherwise resolve to the same `firstmate` prefix) still get distinct tags.
`fm_backend_zellij_create_task` creates every new tab with this scoped title and checks for a duplicate against the scoped title, never the bare label.
Every list/find/recover/kill path (`fm_backend_zellij_target_ready`'s and `fm_backend_zellij_kill`'s expected-label verification, `fm_backend_zellij_list_live`'s recovery sweep, `fm_backend_zellij_resolve_bare_selector`'s ad hoc lookup) is scoped the same way: it checks the home-scoped title first and never trusts a bare, unscoped title match against another home's tab.

**Migration posture for tasks spawned before this change.** A tab created before this home-scoping shipped still carries its old, untagged bare title (`fm-<id>`, no home tag).
Rather than silently orphaning every already-running zellij task, the adapter's label-verification path (`fm_backend_zellij_tab_matches_label`, used by both `target_ready` and `kill`) falls back to an exact untagged bare-title match - but ONLY when that bare title is unambiguous: exactly one live tab in the whole session carries it.
If 2+ live tabs share the same untagged bare title (this home's own pre-migration tab plus, say, a same-named tab from a different firstmate home sharing this session), the match refuses loudly rather than guessing which one is "ours".
A task already reachable through its recorded `window=` meta therefore keeps working unmodified after an upgrade to this fix, with no manual re-tagging step, as long as its title is not itself ambiguous; a genuinely ambiguous legacy collision (rare - it requires two homes to have independently generated the exact same task id before this fix shipped) surfaces as a loud refusal rather than a silent misdirect, and is resolved the same way any other stuck task is: tear down and respawn, which always gets the new home-scoped title.
`fm_backend_zellij_list_live`'s bulk recovery sweep deliberately does NOT attempt this legacy bare-title fallback (telling apart "our own pre-migration tab" from "another home's same-shaped bare title" in a sweep with no numeric id already in hand is not something this adapter can do safely); a pre-migration task stays reachable through its meta's `window=` field instead.

**Moving/relocating a firstmate installation** changes its resolved `FM_ROOT` path and therefore its tag; tabs titled under the old tag simply stop matching new lookups.
This is accepted, exactly as it is for cmux: a task's own recorded worktree path in `state/<id>.meta` does not survive a repo relocation either, so this is consistent with an existing, already-accepted limitation, not a new one.

## Target string and meta fields

A zellij task's `window=` meta field holds `<zellij-session>:<pane-id>`, for example `firstmate:7`.
The pane id is a bare non-negative integer with no embedded colon (simpler than herdr's own pane-id shape, which itself contains a colon), so splitting on the first colon is trivially correct.
This mirrors tmux's `session:window` and herdr's `session:pane` target shapes closely enough that `fm_backend_resolve_selector` (`bin/fm-backend.sh`) needed no zellij-specific logic at all.
When the shared selector contract routes a zellij caller through firstmate metadata, it also supplies the expected caller-facing tab label `fm-<id>` to the zellij adapter, which internally checks it against the home-scoped title (falling back to the unambiguous-untagged legacy match described above).
That label check prevents a stale numeric pane id from being trusted after an external session deletion/recreation, or from being trusted for a different firstmate home's same-named tab; explicit raw `session:pane` targets remain a pane-existence-only escape hatch because there is no metadata label to verify.

Zellij tasks additionally record:

- `zellij_session=` - the named zellij session this task's tab lives in.
- `zellij_tab_id=` - the task's tab id.
- `zellij_pane_id=` - the task's terminal pane id, the fast-path operational target (same value as the `window=` field's second component).

## Verified CLI facts

| Operation | Verified zellij call | What was verified |
|---|---|---|
| Version gate | `zellij --version` -> `"zellij 0.44.0"` | Session-independent; no server needs to be running. |
| Headless session start | `zellij attach -b <name>` with stdin redirected from `/dev/null` and no controlling TTY | Creates the session and returns promptly (cannot actually attach without a TTY, so it exits after creating). The session persists with zero attached clients - `dump-screen`, `list-panes`, etc. all work against it. Running it again against an EXISTING session prints `"Session already exists"` and exits 1 - harmless, since existence is checked first via `list-sessions` and the launch call's own exit status is never inspected. |
| Session existence check | `zellij list-sessions --short --no-formatting` | Plain one-name-per-line output, safe to `grep -qxF`. Passive - never starts a session (unlike herdr's `target_ready`, which DOES auto-start: a herdr server restart is non-destructive and recovers persisted state, but zellij's `kill-session` is destructive, so auto-recreating under an unexpected name would silently orphan whatever the caller meant to reach). |
| Duplicate task check | `zellij action list-tabs --json`, match by home-scoped `.name` | Zellij does NOT enforce tab-name uniqueness itself (verified: two tabs can share a name, same as herdr's tabs). The adapter's own duplicate check is required, and it checks the home-scoped title such as `fm-firstmate-a1b2c3d4-<id>` (see "Home-scoped tab titles" above), never the bare `fm-<id>` label. |
| Create task tab | `zellij action new-tab --cwd <dir> --name <scoped-title>` | Returns the created tab's bare integer id on stdout, exactly as documented (resolves report gap #3). No `--no-focus`-equivalent flag exists at all - see "Focus-steal on new-tab" below. The caller passes `fm-<id>`, but the adapter creates `fm-<home-label>-<id>`. |
| Pane discovery | `zellij action list-panes --json`, filter `.tab_id == <id> and .is_plugin == false` | `tab_id`, `id` (the pane's own bare integer id), `is_plugin`, and `pane_cwd` are ALL present in the default `--json` output with no extra flags (`--tab`/`--geometry`/`--state`/`--command` add more fields but are not needed here). Terminal (non-plugin) pane ids are globally unique across a session's whole tab set - a SEPARATE incrementing namespace from plugin panes, which is why a plugin pane and a terminal pane can share the same bare `id` (the CLI's own `--pane-id` contract, `"3 (equivalent to terminal_3)"`, already documents this split). |
| Worktree-path discovery | marked active cwd probe + capture-scrape (`fm_backend_zellij_current_path`), NOT `.pane_cwd` | `.pane_cwd` reflects a `cd` run directly in the pane's own top-level shell, but does NOT follow a NESTED SUBSHELL's own `cd` (exactly what `treehouse get` does) - see "Worktree-path discovery: pane_cwd does not track a subshell" below. This directly contradicts the design report's assumption that passive `pane_cwd` polling would be "acceptable for tmux and zellij" (report gap #4 is NOT cleanly resolved as originally framed; the adapter works around it instead). |
| Send literal (unsubmitted) | `zellij action paste --pane-id <id> -- <text>` | Uses bracketed paste mode, does NOT auto-submit. Verified directly: a marker sent this way sits unexecuted at the prompt until a separate Enter. Behaves like tmux's `send-keys -l` / herdr's `pane send-text`. Chosen over `write-chars` per the design report's recommendation for popup-safety parity with the other backends. The `--` separator keeps option-shaped text such as `--help` literal. |
| Send key | `zellij action send-keys --pane-id <id> <key>` | Verified names: `"Enter"` (also `"enter"`) works; `"Esc"`/`"esc"` work but `"Escape"`/`"escape"` are REJECTED with "Invalid key"; Ctrl-C must be the SINGLE shell argument `"Ctrl c"` (a two-word key expression as ONE argv entry) - `"C-c"`, `"Ctrl+c"`, and passing `Ctrl`/`c` as two SEPARATE argv words all fail. Resolves report gap #2. |
| Send + submit, composed | `paste` then `send-keys --pane-id <id> Enter` | Zellij has no single-call atomic "type and submit" primitive (unlike tmux's `send-keys ... Enter` or herdr's `pane run`); `fm_backend_zellij_send_text_line` composes the two calls, which is the only form this adapter has for that operation. |
| Bounded capture | `zellij action dump-screen --pane-id <id>` for 40 lines or fewer; `zellij action dump-screen --pane-id <id> --full` above that threshold | Works for a background session with NO attached client (resolves report gap #1). No `--lines`-style bound flag exists at all (unlike herdr's buggy small-N `--lines`, there is simply no flag). Routine watcher-sized reads use zellij's viewport-only dump to avoid unbounded scrollback reads; larger explicit peeks request `--full` and trim to the caller's requested line count locally with `tail`. The tradeoff: on a very short terminal viewport, a 40-line routine read can see fewer than 40 lines and miss content above the visible screen. |
| Busy state | *(no native primitive)* | D5 (`herdr-addendum.md`): zellij has no agent-state API. `fm_backend_busy_state`'s dispatcher (`bin/fm-backend.sh`) falls through to `unknown` for zellij via its wildcard case, exactly like tmux - the watcher's existing pane-hash + regex path is the only busy-state source for this backend. |
| Agent liveness | *(no verified primitive)* | `fm_backend_agent_alive` reports `unknown` for zellij, so `bin/fm-bootstrap.sh`'s session-start secondmate liveness sweep never auto-respawns a zellij secondmate endpoint, conservatively avoiding a false-dead reading that would create a duplicate secondmate supervisor in one home. |
| Kill | `zellij action close-tab-by-id <id>` (tab id resolved fresh from the pane id when possible; teardown can pass recorded `zellij_tab_id` plus the expected caller-facing `fm-<id>` label when the pane is already gone) | Unlike herdr (where closing a tab's only pane also closes the tab), closing a zellij pane with `close-pane` does NOT close the now-empty tab - it survives as an empty "ghost" entry in `list-tabs`. `close-tab-by-id` on a LIVE tab (with its pane still running) verified to cleanly remove both pane and tab in one call. Kill resolves the owning tab and closes by tab id; if teardown supplies an expected label, the tab id must still match it through the home-scoped-title or unambiguous legacy-title check before it is closed, including the recorded `zellij_tab_id` ghost-tab fallback. Best-effort (`\|\| true`), matching tmux's `kill-window` and herdr's `pane close` contract. |
| Recovery / list-live | `zellij action list-tabs --json`, filter names starting with this home's own `fm-<home-label>-` prefix | Name-based, never trusts a stored pane id blindly - the same posture herdr's `list_live` takes. Scoped to this installation's own home-scoped prefix (see "Home-scoped tab titles" above), so it never lists another firstmate home's tabs; the adapter strips the tag back off and reports the plain `fm-<id>` label. Does not attempt the legacy untagged-title fallback (that fallback is for a single already-known tab, not a bulk sweep). |
| Session cleanup (test-only) | `zellij delete-session <name> --force` | The single-call kill-and-delete form, gated behind `tests/zellij-test-safety.sh`'s guard (refuses an empty name, the literal `"firstmate"` default name, or a name not currently listed). Never `kill-all-sessions`/`delete-all-sessions` - see "Session safety" below. |

## Worktree-path discovery: `pane_cwd` does not track a subshell (report gap #4, contradicted)

The design report assumed passive `pane_cwd` polling would be "acceptable for tmux and zellij" (mirroring tmux's proven `pane_current_path`).
This was verified WRONG for the exact case that matters most: `treehouse get`, which opens a nested interactive subshell inside the pane.

Verified against the real binary, step by step:

1. A plain `cd /tmp` typed directly into a pane's own top-level shell updates `list-panes --json`'s `pane_cwd` within one sub-second poll - this is what an earlier, narrower verification pass mistakenly generalized from.
2. Running `treehouse get` in the same pane, waiting for its "Entered worktree at ..." banner, and even typing `pwd` INSIDE the now-interactive treehouse subshell (confirming on-screen that the shell truly is in the acquired worktree) - `pane_cwd` stays **frozen** at the ORIGINAL project directory the whole time. It never updates once a subshell has taken over as the pane's foreground process.
3. `list-panes --json --all` was checked for any pid or alternate live-cwd field (mirroring herdr's `foreground_cwd`) - none exists. Zellij's CLI exposes `pane_command` (the last-invoked command string, e.g. `"treehouse get"`) and `pane_cwd` (frozen at that command's invocation time), but no per-pane process id and no live-tracking cwd field at all.

This is a genuinely worse gap than herdr's frozen-cwd trap: herdr at least exposes `foreground_cwd` as the fix (`docs/herdr-backend.md`); zellij's CLI has no equivalent primitive to reach for.

**Workaround, `fm_backend_zellij_current_path`:** actively probe instead of passively reading JSON.
Submit a short begin marker, `pwd`, and a short end marker into the pane via the same `send_text_line` primitive used for `treehouse get` itself, briefly settle, capture the pane, and concatenate only the visual lines between the two markers.
This works because `pwd` reads from the current foreground shell no matter how many subshells deep the pane is, sidestepping the need for any structured field at all.
The begin/end markers avoid false matches from absolute-path prompts, previous scrollback, and treehouse's own `~`-prefixed "Entered worktree at ..." banner (`tests/fm-backend-zellij.test.sh` pins prompt-path, banner, and wrapped-path cases).
Concatenating the marked block also handles a long worktree path that zellij's visual screen dump soft-wraps across multiple terminal rows.
Verified against the real binary in both shapes: a direct `cd` in the pane's own shell, AND a nested subshell's own `cd` (`bash -c` spawned and cd'd inside it) - the load-bearing case matching `treehouse get`'s actual shape (`tests/fm-backend-zellij-smoke.test.sh`'s two `current_path` assertions).

This op is scoped to `fm-spawn.sh`'s own worktree-discovery poll loop, the only caller - injecting a harmless extra cwd probe into the pane's scrollback before the harness ever launches is an acceptable trade for a reliable answer, and does not affect the interactive session the crewmate later runs in.

## Focus-steal on new-tab (report gap #5, confirmed - and mitigated)

Verified against the real binary with a genuinely attached pty client (`script -q /dev/null zellij attach <session>`): `zellij action new-tab` unconditionally focuses the newly created tab for every attached client, and **there is no flag to suppress this** - `new-tab --help` lists no `--no-focus` equivalent at all (unlike herdr's `--no-focus`, verified in `docs/herdr-backend.md`, or tmux's `new-window -d`).
Before the client attached, the freshly created tab showed `"active": false` in `list-tabs --json`; after attaching a real pty client and creating another tab, that new tab immediately showed `"active": true` and the client's live view moved to it.

**Mitigation**, implemented in `fm_backend_zellij_create_task`: capture the session's previously-active tab id (`list-tabs --json`, `.active == true`) *before* calling `new-tab`, then call `go-to-tab-by-id <that-id>` afterward to restore it.
Verified empirically: this correctly moves an attached client's view back to where it was, and is a safe, silent no-op (`go-to-tab-by-id` against a session with zero attached clients returns exit 0 doing nothing observable) for the common unattended-spawn case where no client is attached at all.
This is the one place this adapter deviates from a flag-based solution the other backends have, because zellij genuinely does not expose one; the mitigation is a best-effort second call, not a suppression flag, so there is a narrow window between tab creation and the restore call during which an attached client's view is briefly on the new tab.

## Unconditional exit code 0 (un-anticipated, load-bearing finding)

Not called out in the original design report, and the single most important operational caveat for this adapter: **every `zellij action <subcommand>` call exits 0 unconditionally**, regardless of whether the target actually exists.

Verified three ways against the real binary:

- Against a **nonexistent session**: every action subcommand tried (`list-panes`, `paste`, `new-tab`) printed the live session list to stdout and an error (`"Session '<name>' not found..."`) to stderr, but exited **0**.
- Against a **live session but a nonexistent pane id**: `send-keys --pane-id 999 Enter` produced **no output on either stream** and exited **0**.
- `dump-screen --pane-id 999 --full` against a live session but dead pane returned **empty output** (a single newline) with exit **0** - a soft, not hard, signal (a genuinely blank pane could also read this way).

This means the exit code can **never** be trusted to detect a bad target on this backend - a meaningful difference from tmux, which does return a nonzero exit and a clear error for a truly nonexistent target.

**Mitigation, in two layers:**

1. Send, capture, and cwd operations call `fm_backend_zellij_target_ready` first, which verifies session existence via the passive `list-sessions` check and verifies the specific terminal pane via `list-panes --json` filtered to `.id == <pane>` and `.is_plugin == false`.
   When the caller reached the pane through a recorded firstmate task, `target_ready` also resolves the pane's owning tab and checks it against the expected caller-facing `fm-<id>` label through the home-scoped-title or unambiguous legacy-title check before sending, capturing, or reading cwd.
   This catches a whole session gone (killed externally, or a stale meta from a prior run), the normal stale-pane case, and stale numeric pane ids reused by an unrelated recreated session.
   Explicit raw `session:pane` targets keep the pane-only check because they intentionally have no recorded `fm-<id>` ownership context.
   Kill checks the session, resolves the tab from the pane when possible, and uses teardown's recorded `zellij_tab_id` fallback when the pane is already gone only after `list-tabs --json` proves the tab still matches the expected caller-facing `fm-<id>` label through that same title check.
2. Output-**shape** validation rejects the "session not found" text fallback structurally: `fm_backend_zellij_create_task` requires `new-tab`'s stdout to parse as a bare integer (the colored session-list text does not), and every `list-panes`/`list-tabs` consumer pipes through `jq`, which fails to parse the plain-text fallback as JSON.

**Accepted residual gaps**: a pane can still die in the brief window between `fm_backend_zellij_target_ready`'s ownership check and the operation's own `zellij action` call.
That remaining race degrades to "the operation quietly did nothing" - the same class of gap firstmate already tolerates for an unverified send on any backend, caught downstream by `fm-spawn.sh`'s worktree-discovery poll timing out after 60s, `fm_backend_zellij_send_text_submit`'s preflight or content-diff retry loop (which reports `send-failed`, `pending`, or `unknown` rather than a false "sent" for these cases), or the watcher's stale-pane detection eventually noticing a pane that never changes.
An explicit raw `session:pane` target can also still address a reused pane id if an operator deliberately bypasses firstmate metadata; that path is kept as an escape hatch, not as the normal task routing path.

## Every pane op needs an EXPLICIT `--pane-id` (un-anticipated finding)

A fresh zellij session auto-opens a floating "About Zellij"/release-notes **plugin** pane in tab 0 that starts **focused** and visually on top of the real terminal pane.
A pane-targeting call made WITHOUT an explicit `--pane-id` (relying on the "focused pane" default) silently goes to this plugin pane instead of the terminal - verified directly: `write-chars 'echo hello'` with no `--pane-id` produced no visible effect in the terminal pane at all.
Every op in this adapter passes an explicit `--pane-id` (a bare integer is confirmed equivalent to `terminal_<n>`, never ambiguous with a plugin pane of the same bare number) for exactly this reason; there is no default-target code path anywhere in `bin/backends/zellij.sh`.

## Tab-name duplication is not enforced (un-anticipated, but expected finding)

Same as herdr's tabs and unlike tmux's own window-name uniqueness: `zellij action new-tab --name <label>` happily creates a second tab sharing an existing name.
`fm_backend_zellij_create_task`'s own `list-tabs`-based duplicate check is therefore required, mirroring both prior adapters - and, because this session's tab bar is shared by every firstmate home with no per-home container split, that check is against the home-scoped title (see "Home-scoped tab titles" above), not the bare `fm-<id>` label, so it cannot be fooled into refusing (or worse, silently reusing) another home's same-id tab.

## Closing a pane does not close its tab (un-anticipated finding)

Unlike herdr (where closing a tab's only root pane also closes the tab), zellij's `close-pane --pane-id <id>` leaves an empty "ghost" tab behind in `list-tabs --json` - verified: the tab entry persists with zero panes until explicitly closed.
`close-tab-by-id <id>` on a still-LIVE tab (pane running normally) was separately verified to cleanly remove both the pane and the tab in one call, needing no `close-pane` first.
This is why `fm_backend_zellij_kill` resolves the owning tab id from the pane when possible, accepts teardown's recorded `zellij_tab_id` as a fallback when the pane has already gone, verifies the expected caller-facing `fm-<id>` label through the home-scoped-title or unambiguous legacy-title check when teardown provides it, and calls `close-tab-by-id`, rather than mirroring herdr's simpler "close the pane, the tab follows" contract.

## Composer verification: delta-based

Zellij's CLI exposes no cursor-row/ANSI-only capture primitive (like tmux's), so `fm_backend_zellij_send_text_submit` still uses a content-diff strategy: capture the pane right after typing (the unsubmitted "typed" baseline), then after each Enter attempt capture again - unchanged means retry, changed means submitted.
This is now zellij-specific; the herdr adapter moved away from content-diff after the 2026-07-03 grok slash-submit incident and now confirms normal idle-baseline submits through native agent-state, retaining structural composer-state for the affirmative-empty injection guard and submit fallback.
All implemented submit-verifying backends expose the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching.

## Session safety

`zellij kill-session <name>` and `zellij delete-session <name>` both take an explicit, required name - there is no ambient "whatever session is running" command shape like herdr's `server stop` that caused two live-fleet kills (`docs/herdr-backend.md` "Session targeting").
The realistic risk for this backend is instead a test accidentally reusing (and then deleting) the real `firstmate` session name, or reaching for the fleet-wide `kill-all-sessions`/`delete-all-sessions` commands.
`tests/zellij-test-safety.sh`'s `zellij_refuse_if_unsafe` guards against both: it refuses an empty name, the literal `"firstmate"` default, or a name not currently listed as active, before `zellij_safe_delete` is allowed to run `delete-session --force`.
Every real-zellij test in this document and its accompanying test files uses a uniquely-named session (`fm-backend-smoke-$$`, or similar) and this guarded cleanup path exclusively.

## End-to-end verification (spawn -> steer -> peek -> done -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-zellij.test.sh`) and the real-CLI smoke tests (`tests/fm-backend-zellij-smoke.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and an isolated `FM_ZELLIJ_SESSION` (never the real `firstmate` session name):

1. `FM_HOME=<scratch> FM_BACKEND=zellij FM_ZELLIJ_SESSION=<isolated> bin/fm-spawn.sh zellij-e2e-t1 projects/scratch-e2e-project claude` - spawned successfully, printing `window=<session>:<pane>` in the summary and writing `backend=zellij`, `zellij_session=`, `zellij_tab_id=`, `zellij_pane_id=` to the task's meta. The worktree-discovery poll correctly resolved the real treehouse worktree path using the active `pwd`-probe workaround.
2. `FM_HOME=<scratch> FM_ZELLIJ_SESSION=<isolated> bin/fm-peek.sh fm-zellij-e2e-t1` - showed the live claude trust dialog ("Quick safety check: Is this a project you created or one you trust?").
3. `FM_HOME=<scratch> FM_ZELLIJ_SESSION=<isolated> bin/fm-send.sh fm-zellij-e2e-t1 --key Enter` - accepted the trust dialog.
4. `FM_HOME=<scratch> FM_ZELLIJ_SESSION=<isolated> bin/fm-peek.sh fm-zellij-e2e-t1` again - showed claude actively working through the brief (verifying isolation, then implementing).
5. `FM_HOME=<scratch> FM_ZELLIJ_SESSION=<isolated> bin/fm-send.sh fm-zellij-e2e-t1 "captain says: proceed as planned, this is a trivial verification task"` - a plain-text steer while claude was mid-turn, exercising the delta-based send-and-verify path; the send completed without a `pending`/`send-failed` error.
6. The crewmate appended `done: ready in branch fm/zellij-e2e-t1` to its status file, and its commit (`add hello.txt`, message `add hello.txt`) was confirmed present on branch `fm/zellij-e2e-t1` in the project's git history, with `hello.txt` containing exactly the expected line.
7. `bin/fm-teardown.sh zellij-e2e-t1` **REFUSED**, exactly as required: `REFUSED: local-only worktree ... has work not yet merged into main and not on any remote.`
8. `bin/fm-merge-local.sh zellij-e2e-t1` - fast-forwarded local `main` to the crewmate's commit (`02c9dd2 -> ba41f90`).
9. `bin/fm-teardown.sh zellij-e2e-t1` now succeeded: terminated the lingering worktree processes, returned the treehouse worktree, closed the zellij tab (confirmed gone via `list-tabs --json` - only the default `Tab #1` remained), and removed all of the task's `state/` files.

The one real bug this pass caught - the `pane_cwd`-does-not-track-a-subshell gap (see "Worktree-path discovery" above) - was found and fixed during this E2E run itself: the FIRST attempt refused to launch with "did not yield an isolated worktree" because `current_path`'s original (JSON-only) implementation never saw `treehouse get`'s subshell move away from the project directory, so the 60-second poll's own comparison collapsed to "same path" and the isolation guard correctly (if confusingly) refused. After the `pwd`-probe fix, the identical flow spawned cleanly on the very next attempt.

The isolated zellij session and the scratch `FM_HOME`/project were fully torn down after this run (`zellij delete-session <isolated> --force`, `rm -rf` on the scratch root); the real `firstmate` session name and the live tmux/herdr fleet were never touched at any point.

## Known gaps left for a follow-up

- **No event push at all**, not even herdr's semantic busy-state (D5): zellij has no analogue to herdr's `agent.get`, so `fm-watch.sh`'s existing pane-hash + `FM_BUSY_REGEX` poll loop is the ONLY event source for this backend, identical to the tmux path. This is the expected, designed-for outcome (D5 explicitly calls for "the poll-based capture/hash/busy-regex path, same vocabulary as tmux"), not a shortfall relative to the report.
- **No verified agent-process liveness classifier.** The session-start secondmate liveness sweep therefore receives `unknown` from `fm_backend_agent_alive` for zellij and reports `SECONDMATE_LIVENESS: ... skipped: liveness probe inconclusive` instead of killing or respawning the endpoint.
  This leaves a dead zellij secondmate for manual recovery, but avoids the worse failure mode of duplicating a live supervisor.
- **The focus-steal mitigation has a narrow race window.** Between `new-tab` (which steals focus immediately) and the follow-up `go-to-tab-by-id` restore call, an attached client's view is briefly on the new tab. No flag-based suppression exists to close this window entirely (see "Focus-steal on new-tab" above); a future zellij release may add one.
- **A pane can still die after `target_ready` succeeds and before the operation runs.** Metadata-routed operations now verify the expected caller-facing `fm-<id>` label through the home-scoped-title or unambiguous legacy-title check, as well as the pane id up front, but zellij's unconditional exit 0 still leaves this narrow time-of-check/time-of-use race for one-shot operations (see "Unconditional exit code 0" above).
- **The `pwd`-probe workaround for worktree-path discovery is scoped to `fm-spawn.sh`'s own poll loop only** (see "Worktree-path discovery" above). It is not a general-purpose live-cwd primitive; a future caller needing a live cwd read for a zellij pane outside that narrow spawn-time context would need the same active-probe approach, not a passive JSON field.
- **No per-home container split**, unlike herdr's later P3 refinement (`docs/herdr-backend.md` "Default task container shape"). This is a deliberate simplicity choice per the locked captain decision (D2: "zellij, content unchanged from the report"), not an oversight; if a captain later runs many concurrent secondmates on the zellij backend and wants per-home visual separation in the tab bar, that would be a natural follow-up mirroring herdr's workspace-per-home pass. Note this is a CONTAINER-level (visual tab-bar grouping) gap only - the cross-home NAME-collision gap this shared container shape used to carry (two homes' same-id tabs sending/peeking/closing each other) is closed by home-scoped tab titles, "Home-scoped tab titles" above.
- **The untagged-legacy migration fallback has one residual ambiguity gap.** `fm_backend_zellij_tab_matches_label`'s bare-title fallback (for a tab spawned before home-scoping shipped) refuses rather than guesses when 2+ live tabs share the exact same untagged bare title - but a genuinely ambiguous case then requires manual intervention (tear down and respawn to get a new home-scoped title) rather than an automatic resolution. This is accepted as the honest trade for not needing a one-time re-tagging migration step; see "Home-scoped tab titles" above.
