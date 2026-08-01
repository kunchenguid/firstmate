# agy adapter — empirical verification evidence

**Harness:** Antigravity CLI `agy` **1.1.9** · **Date:** 2026-08-01 · **Method:** live
tmux panes (`capture-pane -p`/`-e`) and non-interactive print probes driven from
scratch directories under `/tmp/fm-agy-fresh.*` and `/tmp/fm-agy-verify.*`.

This is the "confirm every fact empirically" record the `harness-adapters` skill
requires before an adapter is wired. Every value below is a capture, not a guess;
anything not directly observed is marked NOT VERIFIED.

## Binary and identity

| Fact | Value |
|---|---|
| Binary | `~/.local/bin/agy` (Mach-O arm64), version `1.1.9` via `agy --version` |
| Product name | Antigravity CLI (banner and dialogs) |
| Config home | `~/.gemini/antigravity-cli/` (settings, conversations, oauth); no `~/.agy` |
| Auth | Working on this machine; print and interactive both returned model output |

## Model and effort (critical interaction)

`agy models` lists effort-baked model ids such as `gemini-3.6-flash-low`,
`gemini-3.6-flash-medium`, `gemini-3.6-flash-high`, plus other families
(`gemini-3.5-flash-*`, `gemini-3.1-pro-*`, `claude-sonnet-4-6`, …).

`--help` also documents a separate `--effort low|medium|high` flag.

Live probes (print mode, 2026-08-01):

| Probe | Command shape | Result |
|---|---|---|
| P1 | `--model gemini-3.6-flash-low` (no `--effort`) | Success (`LOWPROBE`) |
| P2 | `--model gemini-3.6-flash-high` (no `--effort`) | Success (`HIGHPROBE`) |
| P3 | `--model gemini-3.6-flash` (no `--effort`) | **Error:** `--model gemini-3.6-flash requires --effort (available: low, medium, high)` |
| P4 | `--model gemini-3.6-flash-low --effort high` | **Error:** conflicts with `--effort=high` |
| P5 | `--model gemini-3.6-flash-low --effort low` | Success (`MATCHOK`) |
| P6 | `--model gemini-3.6-flash --effort medium` | Success (`BASEMED`) |
| P7 | `--model gemini-3.6-flash-medium --effort low` | **Error:** conflicts with `--effort=low` |

**Governing rule:** both the model-id suffix and `--effort` are real.
A bare base model requires `--effort`.
A baked suffix alone is enough.
Matching baked + `--effort` is accepted.
Conflicting baked + `--effort` fails closed with a clear error.

**firstmate policy:** pass `--model` and `--effort` when set; preferred captain form is base model + effort (e.g. `gemini-3.6-flash` + `low`); full baked ids also work when effort is omitted or matches; ceiling is `high` (omit `xhigh`/`max`). firstmate does not rewrite model ids when both axes are supplied.

## Trust / permission gate

A blocking dialog appears on first launch into an untrusted directory:

```
Accessing workspace:

/tmp/fm-agy-fresh.TO2lcN

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit

  ↑/↓ Navigate · enter Confirm
```

- Default focus is "Yes, I trust this folder". Plain `Enter` accepts it.
- `--dangerously-skip-permissions` was already in argv and did **not** bypass the dialog.
- Accepting "Yes" **persisted** the path into
  `~/.gemini/antigravity-cli/settings.json` → `trustedWorkspaces` (observed
  array growth including `/tmp/fm-agy-fresh.TO2lcN`).
- That settings file also holds permission allow-lists; firstmate therefore uses
  a keystroke-only readiness gate (like copilot), not a pre-seed write.

Past-trust anchors (must not match the dialog itself):

- mid-turn: `esc to cancel`
- idle: `? for shortcuts`

Deliberately **not** the substring `Antigravity CLI` — it appears inside the dialog body.

The readiness gate tests the past-trust anchors **before** the dialog literal.
Whether the accepted frame is scrubbed from the 120-line capture window was not
pinned down empirically, and cursor-agent's Ink TUI demonstrably leaves its own
trust frame in the scrollback forever. Dialog-first ordering would therefore
risk never reaching the success branch, exhausting the poll budget, and
reporting a false spawn failure while a trusted agent works unsupervised.
Because the anchors above provably do not match the dialog body, past-trust-first
is correct under either scrollback behavior.

## Launch and brief delivery

```
agy --dangerously-skip-permissions --model gemini-3.6-flash --effort low -i '<brief>'
```

After trust clears, the `-i` prompt is shown as the first user message and the
agent auto-runs the first turn. Verified capture: seeded brief
`Reply with exactly one line: BRIEF-SEEDED-OK...` produced the response
`BRIEF-SEEDED-OK.` with no second Enter.

## Busy / idle (delivery signature)

| State | Observed footer / body |
|---|---|
| Busy (generating) | braille spinner + `Generating...`; footer `esc to cancel` |
| Busy (tool) | braille spinner + `Running...`; footer `esc to cancel`; tool lines like `● Bash(...)` |
| Idle | footer `? for shortcuts`; status `Gemini 3.6 Flash · low` |

`esc to cancel` is the stable mid-turn token and clears the instant the turn ends.
No firstmate-owned semantic busy writer is wired yet for this adapter (same
crewmate posture as cline/cursor-agent/copilot: delivery busy via
`fm-tmux-lib.sh`, task-state classification remains `unknown missing` until a
lifecycle source is credited). Hooks exist (`Stop`, `PreInvocation`, …) under
`.agents/hooks.json` / plugin paths — a future primary or semantic busy path,
not required for crewmate dispatch.

The busy token string matches cline's `esc to cancel` exactly.
Each harness owns its own constant and harness-scoped matcher case so neither
borrows the other's identity.

## Interrupt and exit

| Action | Key / command | Observed |
|---|---|---|
| Interrupt mid-turn | single `Esc` | Session survives; body shows `Interrupted · What should Antigravity CLI do instead?`; footer returns to `? for shortcuts` |
| Exit | `/exit` then Enter | Clean exit (`EXIT_RC=0`); prints `Resume with -c (or command below):` and `agy --conversation=<uuid>` |

## Resume

| Form | Observed |
|---|---|
| `agy --conversation <id>` | Restores prior conversation content in the TUI |
| `agy -c` / `--continue` | Restores the most recent conversation for the cwd |

## Composer

| Fact | Value |
|---|---|
| Shape | Bordered box with bare `>` prompt glyph |
| Idle placeholder | None observed (first-ready and post-turn: glyph only) |
| Classifier | Bordered `>` already reads empty in `fm-composer-lib.sh`; shell-glyph bare rows stay dead-shell-unsafe. No `FM_COMPOSER_IDLE_RE_DEFAULT` addition required. |

## Detection

| Layer | Value |
|---|---|
| Env marker | `ANTIGRAVITY_AGENT=1` on tool children (verified with `env -i` clean launch writing env to a file). Checked **before** `CLAUDECODE` in `fm-harness.sh`. |
| Process ancestry | command name `agy` (and argv substring `*agy*`) |

## Autonomy

`--dangerously-skip-permissions` auto-approves tool permission prompts.
Live tool execution under that flag wrote files and ran shell without a
permission dialog (after project trust).

## End-to-end proof (2026-08-01)

In a disposable tmux session on a fresh `/tmp` worktree:

1. Launch with `-i` brief + autonomy + model/effort → trust dialog.
2. Enter clears trust → brief auto-runs → idle with `? for shortcuts`.
3. Follow-up tool turn: busy shows `esc to cancel` / `Running...`, then idle.
4. Esc mid-turn cancels with `Interrupted · ...` and leaves the session alive.
5. `/exit` prints resume id and exits 0; `--conversation` / `-c` restore history.

## Upstream note

Captain sequencing mentioned reconciling with upstream after PR #1461.
This adapter is self-contained on firstmate's current wiring shape
(launch template, keystroke trust gate, delivery busy regex, harness detection).
Upstream may prefer a different trust-persistence or busy-source design once
#1461 lands; call that out in the PR body rather than blocking this option.
