# Claude composer capture: a title embedded in the composer's opening rule

`titled-composer-border.ansi` owns the recorded pane input for the `test_captured_claude_titled_composer_border` case in `../../fm-composer-lib.test.sh`.
It was captured on 2026-09-29 from a live claude 2.1.259 pane running under Herdr 0.8.0 on macOS 25.6.0, with `herdr pane read <pane> --source visible --format ansi` - the exact capture primitive `fm_backend_herdr_composer_state` uses.

## What the capture shows

The pane's agent had ended its turn and its composer was visibly empty, yet `fm_composer_classify_screen` answered `pending` on it.
Claude 2.1.x writes the session title INTO the composer's opening rule rather than beside it, so that rule is not nothing-but-`─`:

```
──────────────────────────────────────── readme typo correction ─
❯<U+00A0>
─────────────────────────────────────────────────────────────────
  → firstmate git:(main) | Opus 5 (1M context) | ctx [█░░░░░░] 27% | …
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
```

The separated pair therefore went unfound, the composer lost its only container proof, and the cursorless bottom-most-shape rule selected the user's statusLine row - which opens with `→`, Cursor's own prompt glyph - as a bare composer, swallowing the permission-mode hint below it as wrapped input.
The extracted "unsubmitted text" was the statusLine plus that hint row.
Every caller that requires a proven-empty composer refuses on `pending`, so the doorbell skipped its ring and `fm-control` refused to type an exit command, leaving a worker that had fallen over with no supported recovery path.

## Capture provenance and transformations

Row 1 is a synthetic placeholder.
The capture's own transcript rows were captain-facing chat from a supervision pane and are not part of the classifier's input contract, so they are not carried into this shared repository; one neutral row stands in for them so the composer is not the screen's first row.
Rows 2 to 8 are unchanged bytes from the live viewport, CR line endings and SGR sequences included: the turn-completion line, claude's version banner, the title-bearing opening rule, the `❯` + U+00A0 composer row, the closing rule, the user's statusLine, and the permission-mode hint.

The rule colour (`38;2;136;136;136`) and the title share one SGR run, so the title survives ghost stripping exactly as the rule glyphs do; the defect is structural, not a styling miss.

## Limits

This is one recorded pane, not a matrix.
It pins the verdict for this harness/backend pair and this border geometry.
The bounds of the geometry itself - a title wider than the rule's floor, a missing closing rule glyph, extra padding - are asserted as counterfactuals in the same test rather than captured live.
The live per-harness guard in the `live-harness-optin` family remains what catches a future claude release that draws its composer differently.
