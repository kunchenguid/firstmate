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

**firstmate policy:** pass `--model` and `--effort` when set; preferred captain form is base model + effort (e.g. `gemini-3.6-flash` + `low`); full baked ids also work when effort is omitted or matches; ceiling is `high`, and firstmate's shared `xhigh`/`max` tiers resolve against the model id: against a BASE id they CLAMP down to `--effort high`, because P3 shows a base id without `--effort` refuses to launch; against an id that already bakes a `-low`/`-medium`/`-high` suffix the flag is WITHHELD, because P1 shows a baked id launches alone and P4 shows a non-matching `--effort` fails closed. In-range `low`/`medium`/`high` always pass through unchanged. firstmate does not rewrite model ids when both axes are supplied.

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
- That settings file also holds permission allow-lists, is operator-global, and
  has no delegated writer; firstmate therefore uses a keystroke-only readiness
  gate, not a pre-seed write.

Past-trust anchors (must not match the dialog itself):

- mid-turn: `esc to cancel`
- idle: `? for shortcuts`

Deliberately **not** the substring `Antigravity CLI` — it appears inside the dialog body.

The readiness gate tests the past-trust anchors **before** the dialog literal.
Whether the accepted frame is scrubbed from the 120-line capture window was not
pinned down empirically, and an Ink-style TUI is under no obligation to clear an
accepted dialog from the terminal scrollback. Dialog-first ordering would
therefore risk never reaching the success branch, exhausting the poll budget, and
reporting a false spawn failure while a trusted agent works unsupervised.
Because the anchors above provably do not match the dialog body, past-trust-first
is correct under either scrollback behavior.

`agy_wait_for_trust_clear()` sends the default-focus `Enter` at most once (the
`answered` flag, so a repeat Enter after trust clears cannot land as stray
composer text) and polls up to `FM_AGY_TRUST_POLLS` (default 60) at
`FM_AGY_POLL_INTERVAL` (default 0.5s). On exhaustion `agy_spawn_fail()` appends
`failed: ...` to `$STATE/$ID.status`, prints `error: ...; inspect window $T` to
stderr, and `bin/fm-spawn.sh` exits 1 — the same shape as `kimi_spawn_fail`.

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
No firstmate-owned semantic busy writer is wired yet for this adapter: delivery
busy comes from `fm-tmux-lib.sh`, and task-state classification remains
`unknown missing` until a lifecycle source is credited. Hooks exist (`Stop`,
`PreInvocation`, …) under `.agents/hooks.json` / plugin paths — a future primary
or semantic busy path, not required for crewmate dispatch.

`esc to cancel` is agy's own token, held in its own constant
(`FM_TMUX_AGY_BUSY_REGEX_DEFAULT`) and matched only from the harness-scoped
`agy` case, so it can never be borrowed as another harness's identity.

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
| Process ancestry | exact command name `agy`, or an anchored argv match (whole ` agy ` token, `/agy ` path token, or trailing `/agy`). A bare `agy` substring is deliberately not accepted, because it also occurs inside ordinary words such as "legacy". |

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

## Blast radius and regression entry point

The adapter is self-contained on firstmate's existing wiring shape: launch
template, keystroke trust gate, delivery busy regex, harness detection, and the
secondmate refusal. It adds no new script and no new runtime-backend surface.

```sh
tests/fm-agy-harness.test.sh
```

That test pins the launch template, the model/effort resolution matrix
(including the `xhigh`/`max` clamp-versus-withhold split), the trust-gate
ordering and single-Enter budget, the harness-scoped busy token, detection
precedence ahead of `CLAUDECODE`, and the secondmate refusal on all three
harness-resolution paths.
