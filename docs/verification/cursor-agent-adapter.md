# cursor-agent adapter — empirical verification evidence

**Harness:** Cursor CLI `2026.07.16` / `2026.07.23` (auto-updated mid-session) ·
**Date:** 2026-07-27 · **Method:** live `cursor-agent --force` panes driven through
`tmux` (`capture-pane -p`/`-e`), the rendered text the composer classifier consumes.

The "confirm every fact empirically" record required before wiring the adapter.
Every value below is a capture, not a guess.

## Workspace-trust gate (the load-bearing quirk)

Interactive mode shows a BLOCKING trust dialog on an untrusted directory:

```
  ╭───────────────────────────────────────────────╮
  │  ⚠ Workspace Trust Required                     │
  │  Cursor Agent can execute code and access files │
  │  Do you trust the contents of this directory?   │
  │    <abs path>                                   │
  │  ▶ [a] Trust this workspace                      │
  │    [q] Quit                                      │
  ╰───────────────────────────────────────────────╯
```

- `--force` did NOT skip it; the dialog persisted past t+25s until answered.
- Per `--help`, `--trust` "only works with --print/headless mode" — so it does NOT
  bypass the interactive dialog.
- **Two verified bypasses:**
  1. Sending `a` → `⏳ Trusting workspace...` → composer (verified).
  2. Pre-seeding `~/.cursor/projects/<path-slug>/.workspace-trusted`. A second launch
     with that marker already present went STRAIGHT to the composer, no dialog
     (verified). Marker contents:
     `{"trustedAt":"2026-07-27T06:52:22.901Z","workspacePath":"<abs path>"}`.
     The slug is the abspath with the leading `/` dropped and every `/`→`-`; long
     paths get a length-capped variant with a hash suffix.
- On the trust dialog, `Esc` = Quit (exits, rc 0).

## Ready / idle composer

```
  Cursor Agent
  v2026.07.23-e383d2b
  → Plan, search, build anything
  Auto                                            Run Everything
  <cwd>
```

- Bare agent glyph `→` (U+2192) + idle placeholder `Plan, search, build anything`
  (first ready) / `Add a follow-up` (after a turn).
- `→` is a verified AGENT prompt glyph in the shared classifier and bare-row
  promotion set (`bin/fm-composer-lib.sh`: `FM_COMPOSER_BARE_PROMPT_RE_DEFAULT`),
  so the unbordered composer row is structurally recognized on every backend; the
  idle placeholders read empty via the shared `FM_COMPOSER_IDLE_RE_DEFAULT` (the
  glyph-prefixed alternates). Shell glyphs (`>` `$` `%` `#`) still never promote a
  bare row, so the dead-shell safety rule is unchanged.
- Status bar shows `Run Everything` (= `--force` autonomy).

## Busy signature

```
 ⠠⠛ Working
  → Add a follow-up                                ctrl+c to stop
  Auto · 10.4%                                     Run Everything
```

- Braille spinner + `Working` + composer hint `ctrl+c to stop` (present only
  mid-turn; absent when idle) → `ctrl+c to stop` is the busy anchor.
- Bare `Working` is deliberately NOT the anchor because pi owns `Working...`.
- Context % rises during the turn (`Auto` → `Auto · 10.4%`).

## Interrupt vs exit

- **Interrupt = `Ctrl-C`** mid-turn ("ctrl+c to stop").
- **Exit = `/quit`** (slash popup + Enter; verified rc 0). From an idle session,
  Esc and repeated Ctrl-C did NOT exit (the composer survived).

## Launch (mechanics half)

`cursor-agent --force "<prompt>"` seeds and auto-runs the prompt once trust is
cleared (verified: pane reached `⠠⠛ Working` on the seeded PONG task, produced
`PONG`). Effort is a `--model` bracket param (`claude-opus-4-8[effort=high]`), not a
flag. Final template:

```
cursor-agent --force __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"
```

## Recorded in

| Owner | Change |
|---|---|
| `bin/fm-spawn.sh` | `launch_template` cursor-agent case; `--model` allowlist; known-adapter allowlists; workspace-trust readiness (pre-seed `.workspace-trusted` + `a`-answering poll gate that fails loudly) |
| `bin/fm-harness.sh` | `detect_own` ancestry match `*cursor*` → `cursor-agent` (comm + args) |
| `bin/fm-tmux-lib.sh` | `FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT='ctrl\+c to stop'` + case arm |
| `bin/fm-composer-lib.sh` + `bin/backends/{herdr,cmux,orca}.sh` | `→` added to the shared agent-glyph classifier and bare-row promotion; shared `FM_COMPOSER_IDLE_RE_DEFAULT` covers the cursor placeholders (tmux + all backends) |
| `.agents/skills/harness-adapters/SKILL.md` | cursor-agent knowledge section |
| `tests/fm-cursor-agent-harness.test.sh` | 12 behavior checks (all green) |

## Remaining acceptance (live end-to-end)

Registry facts above are verified in isolation and unit-covered. The
trust-clearing readiness step is implemented in `fm-spawn`: it pre-seeds
`.workspace-trusted` before launch and its post-launch gate answers a residual
dialog with `a` (once — covering cursor's undocumented length-capped slug
variant for long paths), failing the spawn loudly when the pane never reaches a
ready/working signal. The closing acceptance is a full live crewmate dispatch
through the herdr backend observing trust-clear → brief auto-run → busy →
turn-end and interrupt(`Ctrl-C`)/exit(`/quit`) under supervision; it needs a
full firstmate home + a real project and is not run in this environment.
