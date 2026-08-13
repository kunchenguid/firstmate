# agy composer shape - verification record

Byte-level capture backing agy's entry in `bin/fm-composer-lib.sh`'s shape
catalogue. Captured from agy 1.1.12 in a 120x30 pty, launched exactly as
`bin/fm-spawn.sh` launches it (`agy --dangerously-skip-permissions`), with the
raw escape sequences preserved.

## Shape: `separated`

agy draws a full-pane-width rule pair bracketing a single content row, then a
status footer OUTSIDE the pair:

```
ESC[38;2;65;72;104m  ──── x120 (U+2500)  ESC[m     <- top rule
ESC[38;2;122;162;247m > ESC[m                      <- content row, `>` glyph
ESC[38;2;65;72;104m  ──── x120 (U+2500)  ESC[m     <- bottom rule
Claude Opus 4.6 (Thinking) | ctx: 0.0% | quota: 100% (4h 59m)
```

| Fact | Value |
| --- | --- |
| Family | `separated` (same rule-pair family as pi) |
| Rule glyph / width | U+2500 `─`, full pane width (120 of 120) |
| Rule foreground | truecolor RGB(65,72,104), luma ~74 |
| Prompt glyph | ASCII `>` (U+003E), a SHELL glyph |
| Glyph foreground | truecolor RGB(122,162,247), luma ~160 |
| Glyph/content separator | one ASCII space; cursor rests at column 2 |
| Empty state | glyph alone - agy renders NO idle placeholder or ghost text |
| Pending state | default-foreground, normal-intensity text inline after `> ` |
| Footer | one row BELOW the bottom rule; outside the composer |

## Why the container matters

agy's `>` is in `FM_COMPOSER_SHELL_PROMPT_GLYPHS`, so THE SAFETY RULE forbids
reading it as an empty composer on a bare row - that is what a pane shows once
its agent has exited to a login shell. agy is provable only because the rule
pair contains the glyph, and a bare `>` with no rule pair still reads
`unknown`.

That containment is the WHOLE proof, so agy needs no agent-identity capability:
`_fm_composer_separated_glyph_row` finds the shell glyph inside a validated
rule pair and `_fm_composer_classify_separated_glyph` hands those rows to the
shared `_fm_composer_classify_rows` container classifier, where a contained
shell glyph is legitimately empty - the same rule that already licenses a `>`
inside a bordered box.

pi is the case that genuinely needs identity, and still has it: pi leaves its
content region BLANK, which is exactly the strict rule's unidentifiable blank
row, so `_fm_composer_pi_verdict` keeps its identity-plus-structure
conjunction unchanged.

Requiring identity for agy as well was implemented first and then reverted on
evidence: `identity=1` is supplied only by herdr's `agent get` and tmux's
pi-specific foreground-process probe, so an identity-gated agy read `unknown`
on tmux - the reference backend and the only one CI exercises - and on cmux,
orca, and zellij. The structural read is correct on every backend.

## Independent re-measurement (2026-08-13, agy 1.1.12)

Captured a second time from a live pty at 200x50, launched as
`bin/fm-spawn.sh` launches it (`--dangerously-skip-permissions --add-dir
<worktree> --model 'Gemini 3.1 Pro (High)' -i <brief>`), rendered through a
terminal emulator so the SGR attributes are the ones a styled backend capture
would carry. Every value above reproduced exactly:

| Measured | Value |
| --- | --- |
| Rule foreground | `38;2;65;72;104` (luma ~73.6, BELOW the 128 ghost threshold, so the shared ghost stripper drops it - structural detection reads the UNSTRIPPED row) |
| Prompt glyph foreground | `38;2;122;162;247` (luma ~159.8, ABOVE the threshold, so the glyph survives ghost stripping) |
| Typed text | terminal default foreground, no SGR |
| Idle placeholder | none in any observed state, including a pristine never-typed composer |
| Cursor | rests on the composer content row, column 2 when empty |
| Mid-turn | the composer stays present and EMPTY while the agent works, with a `Generating...`/`Working...` spinner row ABOVE the top rule; the verb varies between turns, which is why no spinner string is a state source |

## Verified verdicts

Against the captured bytes, through `fm_composer_classify_screen` with
`styled=1 identity=1`:

| Screen | Identity | Verdict |
| --- | --- | --- |
| rule / `>` / rule | `agy idle` | `empty` |
| rule / `>` / rule | `agy busy` | `unknown` |
| rule / `> hello firstmate` / rule | `agy idle` | `pending` |
| rule / `> hello firstmate` / rule | `agy busy` | `pending` |
| `>` with no rule pair (dead shell) | `agy idle` | `unknown` |
| rule / `>` / rule | `grok idle` | `unknown` |

`tests/fm-composer-lib.test.sh` (28 assertions) and
`tests/fm-composer-ghost.test.sh` (33) pass unchanged alongside these.

## Capture note

No trust dialog gates the composer for a firstmate dispatch.
`--dangerously-skip-permissions` suppresses it, re-measured 2026-08-13 on a
worktree path agy had never seen: the pane painted its banner and composer
directly with no prompt, and agy's own `trustedWorkspaces` list in
`~/.gemini/antigravity-cli/settings.json` was byte-identical afterwards.
`bin/fm-spawn.sh` therefore injects nothing into that list and never writes to
the operator's agy trust store.
