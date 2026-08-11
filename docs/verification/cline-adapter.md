# cline adapter — empirical verification evidence

**Harness:** Cline CLI `3.0.46` · **Date:** 2026-07-27 · **Method:** live `cline -i --tui`
panes driven through `tmux` (`capture-pane -p`/`-e`), the same rendered text the
`fm-tmux-lib.sh` / herdr composer classifier consumes.

This is the "confirm every fact empirically" record the `harness-adapters` skill
requires before an adapter is wired. Every value below is a capture, not a guess.

## Ready / idle composer

```
                 What can I do for you?
   Use / for slash commands, @ for file mentions, Ctrl+P for menu
───────────────────────────────────────────
❯ What can I do for you?
───────────────────────────────────────────
 ClinePass: Kimi K3 (medium)      ○ Plan ● Act (Tab)
 ⏵⏵ Auto-approve all enabled (Shift+Tab)
```

- Agent glyph `❯` (U+276F) — already a verified empty-composer glyph in
  `fm-composer-lib.sh`; no new glyph needed.
- Idle placeholder: `What can I do for you?` (first ready), `Ask anything...`
  (after the first turn).
- **Ghost-stripper gap:** in `capture-pane -e` the placeholder is truecolor
  `\e[38;2;131;137;140m` (grey, luma ≈ 136 > the 128 dark-fg cutoff) AND has a
  bold `\e[1m` copy. Neither is dim/faint (SGR 2), so the shared ghost stripper
  keeps it → it would misread as pending. Fix: the shared idle-placeholder
  default `FM_COMPOSER_IDLE_RE_DEFAULT` (`bin/fm-composer-lib.sh`) lists both
  placeholders and is consumed by the tmux classifier and the herdr/cmux/orca
  backends alike. The composer row has no side borders, so cmux/orca reach it
  via the shared bare agent-glyph promotion (`❯`).

## Busy signature

```
 ⠦ Thinking... (esc to cancel)
 ▶ Thinking: ...ctly single word. Ensure no extra.
 * PONG
───────────────────────────────────────────
❯ Ask anything...
───────────────────────────────────────────
 ClinePass: Kimi K3 (medium)      ██████ (10,062)
```

- Braille spinner (`⠦`/`⠇`/…) + `Thinking... (esc to cancel)`; the token
  **`esc to cancel`** is stable and clears the instant the turn ends → the busy
  anchor (`FM_TMUX_CLINE_BUSY_REGEX_DEFAULT='esc to cancel'`).
- Distinct from claude/codex `esc to interrupt` — no cross-harness borrow.
- Context counter rises during a turn (`(0)` → `(10,062)`), freezes at turn end.

## Interrupt vs exit (they differ — important)

- **Interrupt = `Esc`** ("esc to cancel" cancels the current turn).
- **Exit = single `Ctrl+C`** — exits the TUI cleanly (`CLINE_EXITED_RC=0`),
  returning to the shell. So Ctrl+C must NEVER be used to interrupt a cline turn.

## Launch (mechanics half)

`cline -i --tui "<prompt>"` **seeds and auto-runs** the positional prompt — at
t+8s the pane was already `⠇ Thinking...` on the seeded task. So cline uses the
argv-seed pattern (claude/codex/grok), not kimi's bare-launch+inject.

The full launch line was verified live:
`cline -i --tui --auto-approve true --thinking high "<prompt>"` started cleanly and
the status bar changed to `ClinePass: Kimi K3 (high)`, confirming `--thinking`
takes effect and `--auto-approve true` is accepted. Final template:

```
cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"
```

## Recorded in (the six adapter owners)

| Owner | Change |
|---|---|
| `bin/fm-spawn.sh` | `launch_template` cline case; `--model`/`--thinking` mapping; known-adapter allowlists |
| `bin/fm-harness.sh` | `detect_own` ancestry match `*cline*` (comm + args) |
| `bin/fm-tmux-lib.sh` | `FM_TMUX_CLINE_BUSY_REGEX_DEFAULT` + `case` arm |
| `bin/fm-composer-lib.sh` + `bin/backends/{herdr,cmux,orca}.sh` | shared `FM_COMPOSER_IDLE_RE_DEFAULT` covers cline placeholders (tmux + all backends); cmux/orca bare agent-glyph promotion reaches the borderless `❯` row |
| `.agents/skills/harness-adapters/SKILL.md` | cline knowledge section |
| `tests/fm-cline-harness.test.sh` | 12 behavior checks (all green) |

## Remaining acceptance (live end-to-end)

The facts above are verified in isolation and unit-covered. The closing acceptance —
like Phase 1 / federation — is a **full live crewmate dispatch through the herdr
backend**: `config/crew-harness=cline` (or a `--harness cline` dispatch), observing
the supervisor drive ready-gate → brief-inject → busy → turn-end on a real cline
pane, plus interrupt(`Esc`)/exit(`Ctrl+C`) under supervision. Not yet run here
(needs a full firstmate home + a real project). The optional `--hooks-dir` turn-end
Stop-hook (only for cline-as-PRIMARY) is a separate future item.
