# Orchestrator dashboard layout

A terminal dashboard for the captain: keep the command pane in view while watching
several workers at once. One command arranges the current firstmate tmux window
into:

```
┌─────────────┬───────────────────────────────┐
│             │           watch 1             │
│ orchestrator│  (live mirror of a worker)    │
│   (command) ├───────────────────────────────┤
│   top 2/3   │           watch 2             │
│             │                               │
├─────────────┼───────────────────────────────┤
│  workers    │           watch 3             │
│ summary 1/3 │                               │
└─────────────┴───────────────────────────────┘
   left 1/3              right 2/3
```

- **Left 1/3, top 2/3 - orchestrator.** Your existing firstmate chat/command pane,
  kept focused and fully usable. Arrange never replaces, moves, or obscures it.
- **Left 1/3, bottom 1/3 - worker summary.** Terse `• repo - label` bullets for
  every active worker, truncated to fit the small panel (no long wrapping).
- **Right 2/3 - three stacked watch slots.** Each slot is a **read-only mirror** of
  a live worker's pane (a `capture-pane` loop). Workers keep running in their own
  windows, untouched; nothing here ever sends keys, moves, or kills a worker.

## Requirements

The dashboard needs **tmux >= 3.1**. `arrange` sizes its panes with the
`split-window -l <pct>%` percentage form, which tmux only understands from 3.1
onward (older tmux used `-p <pct>`); on tmux < 3.1 `arrange` fails.

## Commands

All live in `bin/`. Run them from your firstmate terminal.

| Command | What it does |
| --- | --- |
| `fm-layout.sh` (or `fm-layout.sh arrange`) | Build/refresh the dashboard in the current window. |
| `fm-layout.sh pick [1\|2\|3]` | Open the keyboard picker to assign a worker to a slot. |
| `fm-layout.sh workers` | List the live workers (`idx`, window, repo, label). |
| `fm-layout.sh slots` | Show the three current slot assignments. |
| `fm-layout.sh assign <1\|2\|3> <window\|->` | Assign a worker to a slot (`-` clears it). |
| `fm-layout.sh ref` | Open the worker-reference picker and type the chosen worker's reference into the composer (see [Worker references](#worker-references-the--shortcut)). |
| `fm-layout.sh bind [--mouse]` | Install opt-in tmux keybindings (see below). |
| `fm-layout.sh unbind` | Remove those keybindings. |

`arrange` is **safe to re-run**. It rebuilds only its own viewer panes (the summary
and the three watch slots), never the orchestrator pane, never a worker, and never
a pane it does not recognize. If the window holds unexpected panes it refuses and
leaves everything intact (pass `--force` only if you want those extra panes
removed). It also refuses to restructure a worker window (one named `fm-*`).

## Worker discovery

Workers are discovered from this home's `state/*.meta` files - any task whose tmux
window is currently live. The window's `project=` gives the repo; the task id gives
a terse feature label (the random suffix is dropped and words are spaced, e.g.
`scrub-pajamas-refactor-y8` → `scrub pajamas refactor`, truncated to
`FM_LAYOUT_LABEL_MAX`, default 30). Persistent secondmate homes are skipped (set
`FM_LAYOUT_INCLUDE_SECONDMATES=1` to include them).

When more than three workers are active, the three slots start on the first three
and you swap any worker into any slot with the picker - the layout never spawns new
work to fill a slot, and an empty slot just stays empty.

## Reassigning a slot

### Keyboard picker (reliable baseline)

`fm-layout.sh pick` opens a small popup that lists the live workers numbered; type
the slot, then the worker number (or `0` to clear). This is the dependable path and
works on any tmux/terminal. Reassignment is just a file rewrite
(`state/.layout-slot-<n>`); the watch pane re-reads it on its next refresh, so no
panes are created or destroyed.

### Keybindings (opt-in)

`fm-layout.sh bind` installs two **runtime** prefix bindings (it edits the live tmux
server with `bind-key`, never your `~/.tmux.conf`):

- `prefix O` - arrange/refresh the dashboard.
- `prefix P` - open the slot picker popup.
- `prefix #` - open the worker-reference picker (types a worker reference into the composer; see [Worker references](#worker-references-the--shortcut)).

The arrange/pick keys are capitals to avoid clobbering tmux defaults; override them
with `FM_LAYOUT_KEY_ARRANGE` / `FM_LAYOUT_KEY_PICK` / `FM_LAYOUT_KEY_REF`. Remove
them all with `fm-layout.sh unbind`.

### Mouse / right-click (best-effort, fragile - opt-in)

`fm-layout.sh bind --mouse` additionally lets you right-click a watch pane to open
its picker. This is **best-effort and intentionally not on by default**, because of
tmux limitations:

- tmux key tables (including mouse bindings) are **server-global**, not
  per-session/per-window. There is no way to scope a right-click binding to only the
  dashboard panes, so enabling it rebinds `MouseDown3Pane` for the whole server.
  Right-clicking outside a watch pane becomes a harmless no-op rather than your
  terminal's usual paste/context-menu behavior.
- It also turns on tmux `mouse` mode server-wide, which changes selection/scroll
  behavior in every pane.

Because of that global reach, the keyboard picker is the supported path; the mouse
binding is offered for captains who knowingly accept the trade-off. `unbind` removes
the right-click binding; it leaves `mouse` mode as-is (run `tmux set -g mouse off`
yourself if you want it off).

## Worker references (the `#` shortcut)

When you message the orchestrator about a specific worker, you often need that
worker's terminal target ("which one is worker 3?"). The reference shortcut lets
you pick a worker from a menu and have its reference **typed straight into your
composer**, so you stop hand-copying terminal targets:

```
Captain types:  <prefix> #   ->  picks "portals-cx - close issues"
Composer becomes:  firstmate:fm-close-portals-resolved-issues-h6 ▮
                   ...then continue typing: "refactor is done, now add X"
```

`fm-layout.sh bind` wires this to **`prefix #`**. Pressing it opens a tmux
`display-menu` of the live workers (keyboard-navigable with `1`-`9`/arrows, and
mouse-clickable - the same feel as an `@`/`/` picker); choosing one types that
worker's reference into the pane you were in, plus a trailing space.

### Why a prefix chord and not a bare `#`

The ask was for a bare `#` (typed in the composer) to open the picker, mirroring
`@`/`/`. **That is not feasible to intercept reliably**, and here is why for each
layer:

- **Agent composers (Claude, OpenCode, Codex, pi):** their `@`/`/` pickers are
  built into each program. There is no public hook to register a new trigger
  character from the outside; intercepting `#` would mean patching every harness.
- **cmux:** its control CLI can `send` text to a surface and enumerate workspaces,
  and it has configurable shortcuts - but those shortcuts only rebind cmux's own
  built-in actions, there is no "bind `#` to run a script" facility, and no
  `#`/`@` mention-trigger in its text box. Its control socket is also
  password-gated, so an agent cannot drive it without the captain's credential.
- **tmux:** binding a literal `#` in the root key table would hijack **every** `#`
  you type (code, Markdown headings, shell comments), which is unacceptable.

So the closest robust, harness-agnostic workflow is a tmux **prefix chord**
(`prefix #`) that types the reference into whatever composer is focused. It works
the same under any agent harness and needs no credentials.

### Reference format

`FM_LAYOUT_REF_FORMAT` chooses what gets typed:

| Value | Inserts | Use |
| --- | --- | --- |
| `target` (default) | `firstmate:fm-<id>` | the literal tmux target - usable with `tmux`, and resolved by `fm-send`/`fm-peek`. |
| `window` | `fm-<id>` | the bare window name firstmate's tools resolve. |
| `select` | `tmux select-window -t firstmate:fm-<id>` | a ready-to-run command to jump to that worker. |

The same reference is shown in each watch pane's header `(…)`, so the dashboard and
the typed token always agree. `fm-layout.sh ref --print` lists the menu's targets
(used by tests and scripting).

### Optional: cmux delivery

On cmux, `cmux send <surface> <text>` can deliver a reference to a surface's text
box instead of typing locally. firstmate does not depend on this (the cmux control
socket is password-gated and environment-specific), but if you have the socket
password set (`CMUX_SOCKET_PASSWORD` or cmux Settings), `cmux workspace list` /
`cmux tree` enumerate workers and `cmux send` routes text - the same reference
strings `fm-layout.sh ref --print` produces apply.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `FM_LAYOUT_REFRESH` | `2` | Seconds between watch/summary refreshes. |
| `FM_LAYOUT_LABEL_MAX` | `30` | Max feature-label width before truncation. |
| `FM_LAYOUT_KEY_ARRANGE` | `O` | Prefix key bound to arrange by `bind`. |
| `FM_LAYOUT_KEY_PICK` | `P` | Prefix key bound to the slot picker by `bind`. |
| `FM_LAYOUT_KEY_REF` | `#` | Prefix key bound to the worker-reference picker by `bind`. |
| `FM_LAYOUT_REF_FORMAT` | `target` | What the reference picker types: `target`, `window`, or `select`. |
| `FM_LAYOUT_INCLUDE_SECONDMATES` | unset | Set to `1` to watch secondmate homes too. |

## Implementation

- `bin/fm-layout.sh` - arrange/assign/pick/ref/bind CLI.
- `bin/fm-layout-lib.sh` - shared worker discovery, slot, and reference helpers.
- `bin/fm-watch-pane.sh` - the per-pane mirror/summary refresh loop.
- `bin/fm-layout-pick.sh` - the interactive slot-picker popup.

Slot assignments live in `state/.layout-slot-<n>` (gitignored runtime state, in the
`.layout-*` namespace the watcher never touches). The watch panes only
`capture-pane` their target, so they are read-only by construction.

### Manual verification

The behavior is covered by `tests/fm-layout.test.sh` (real tmux on a private
socket): discovery/exclusion, label truncation, assign/clear/reject, arrange
geometry, idempotent re-run, the worker-window and unexpected-pane refusals, the
rendered summary/mirror content, and the worker-reference resolver/insertion. To
watch it by hand:

```sh
# from a firstmate window with a few workers in flight:
bin/fm-layout.sh arrange      # builds the dashboard
bin/fm-layout.sh workers      # see who is live
bin/fm-layout.sh pick 3       # assign a 4th worker into slot 3
bin/fm-layout.sh arrange      # safe to re-run; geometry unchanged
bin/fm-layout.sh bind         # then press: prefix #  -> pick a worker, ref is typed in
```
