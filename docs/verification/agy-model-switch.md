# agy in-session model switch - verification record

Evidence backing the live ladder descent in `bin/fm-agy-descent-lib.sh`, which
moves an ALREADY RUNNING agy worker down a rung by driving agy's own `/model`
command into its pane.

Everything below is a VENDOR fact: the shape of a command agy owns and a picker
agy draws. None of it is inferable from firstmate's own code, and all of it can
change in an agy release, so it is pinned here with the exact output rather than
assumed. `tests/fm-agy-model-switch-live-e2e.test.sh` is the command that
refreshes this record; run it after every agy upgrade.

Captured 2026-08-20 against agy 1.1.16 on macOS (`darwin-arm64`), in a
disposable Herdr lab session.

## The load-bearing claim: the switch preserves the conversation

This is the entire reason the descent drives `/model` instead of relaunching the
worker through `bin/fm-control.sh relaunch --model`. Relaunch is proven and
keeps the worktree, branch and commits, but it costs the conversation. The
in-session switch costs nothing.

A worker was started on `Gemini 3.1 Pro (High)`, given something only its
conversation could recall, switched, and asked for it again:

```
Gemini 3.1 Pro (High) | ctx: 2.1% | quota: 87% (3h 35m)

> Remember this codeword: BANANA-SEVEN. Reply with only the word ACK.

  ACK

> /model
  ⎿  Model set to Gemini 3.7 Flash (High)

> What was the codeword I gave you? Reply with only the codeword.

  BANANA-SEVEN

Gemini 3.7 Flash (High) | ctx: 2.1% | quota: 100% (4h 59m)
```

The context reading is unchanged at 2.1% across the switch, so the context
window is carried over rather than rebuilt. agy's own transcript records the
change as a settings event inside the same conversation:

```
{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT", ... "content":"<USER_REQUEST>\nWhat was the codeword I gave you? ... <USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Gemi
```

## `/model` takes no argument, and offers no filter

Both were tested, because either would have removed the need to walk a rendered
list at all.

Submitting `/model gemini-3.7-flash-high` opens the same picker and discards the
argument. Typing `3.7` while the picker is open filters nothing; the list is
unchanged and the selection does not move.

So a keyboard walk is the only way in, which is why every step of it in
`bin/fm-agy-descent-lib.sh` is guarded and refuses rather than guesses.

## The picker

```
Switch Model

  Gemini 3.7 Flash
  Gemini 3.6 Flash
  Gemini 3.5 Flash
> Gemini 3.1 Pro               (current)
  Claude Sonnet 4.6 (Thinking)
  Claude Opus 4.6 (Thinking)
  GPT-OSS 120B (Medium)

  Effort  ◂            ●━━━━━━━━━━━━━━━━━━━━━━◉            ▸
                      low                   high
            Deepest reasoning for complex problems — slower but strongest

Keyboard: ↑/↓ Navigate  ←/→ Effort  enter Select  esc Go Back
```

Three properties of this render are relied on, and each is asserted separately
in `tests/fm-agy-live-descent.test.sh` so none can go quietly vacuous:

- The title, the keyboard legend, exactly one `>` selection marker, and a
  `(current)` row together identify the picker. No navigation key is sent until
  all four are present.
- A row names a model FAMILY when the effort is a separate axis (`Gemini 3.1
  Pro`) and carries its qualifier inline when it is not (`Claude Opus 4.6
  (Thinking)`, `GPT-OSS 120B (Medium)`). The ladder's display names are resolved
  against these rows rather than split by a rule.
- The row list comes from the account's own catalogue, so its membership and
  order are not fixed. The move count is parsed from the render every time.

### The effort slider resets, and saturates

Moving the selection to a different model family resets the slider to that
family's low end:

```
> Gemini 3.7 Flash
  ...
  Effort  ◂        ◉──────────────○──────────────○        ▸
                  low          medium          high
            Faster responses, lighter reasoning — great for simpler tasks
```

Eight right-arrow presses from there land on `high` and stay there; the slider
clamps at its end rather than wrapping. The stop count also varies by family
(two stops for `Gemini 3.1 Pro`, three for `Gemini 3.7 Flash`), which is why the
descent saturates the slider instead of counting stops - and why it refuses a
target whose name asks for any effort other than `(High)`.

## The retried Enter, which selects a model nobody chose

This one cost a live worker and is the reason the descent does not use the
shared submit helper's retry.

`fm_backend_send_text_submit` types once and then presses Enter up to its retry
count, re-pressing when it cannot confirm a submission. That is correct for a
prompt and wrong for `/model`, because `/model` opens a modal: the first Enter
opens the picker, the composer then reads as absent rather than as submitted,
and the retry lands INSIDE the picker and commits the highlighted row.

Observed with a retry count of 2, against a worker sitting on an exhausted
rung 1 - the retry re-selected the very rung the descent was trying to leave:

```
> /model
  ⎿  Model set to Claude Opus 4.6 (Thinking)

Claude Opus 4.6 (Thinking) | ctx: 8.7% | quota: 0.2% (14m)
```

The command is now submitted with a retry count of 1, which is one attempt and
no retry, and the picker guard is the confirmation instead of the helper's
verdict. `pending` is that helper's ordinary answer for a perfectly delivered
`/model`, because no turn was started.

## The condition itself, reproduced end to end

A real agy worker on rung 1 while the live account reading put rung 1 below the
25% floor reserved for the captain. The worker hit the production failure
verbatim, and the automatic evaluation moved it:

```
Claude Opus 4.6 (Thinking)      0
Gemini 3.1 Pro (High)           0.7709090709686279

> Remember this codeword: MAINSAIL-9. Reply with only the word ACK.

⚠ You have exhausted your capacity on this model. Your quota will reset after 9m9s.

$ fm_agy_descent_tick "$STATE"
descended agy-repro Claude Opus 4.6 (Thinking) -> Gemini 3.1 Pro (High)

> /model
  ⎿  Model set to Gemini 3.1 Pro (High)

> What codeword did I ask you to remember? Reply with only the codeword.

  MAINSAIL-9

Gemini 3.1 Pro (High) | ctx: 2.1% | quota: 77% (17m)
```

The codeword is the proof that matters: the worker recovered it from a message
it had never been able to answer while wedged, so the conversation survived the
switch rather than being rebuilt after it.

## The refusals, against real workers

Both were driven against live panes, and neither touched the worker.

A durable record that does not describe the running worker:

```
--- the worker is really running: ---
Gemini 3.1 Pro (High) | ctx: 0.0% | quota: 76.8% (16m)
--- recorded model: model=Claude Opus 4.6 (Thinking) ---
refused caseA is recorded on Claude Opus 4.6 (Thinking) but its worker reports Gemini 3.1 Pro (High); nothing was changed while the two disagree
```

A pane where `/model` opens no picker - the case where a renamed or removed
command would otherwise take arrow keys and an Enter into whatever is actually
there:

```
refused caseB could not be moved from Claude Opus 4.6 (Thinking) to Gemini 3.1 Pro (High): the model picker did not open within 20s (delivery reported empty), so no keys were sent
--- what actually reached that pane (no navigation keys, composer cleared): ---
❯ /model
zsh: no such file or directory: /model
❯
```

Only the command itself reached the pane. No navigation key followed it, and the
composer was returned to a clean prompt.

## Refreshing this record

```
FM_AGY_MODEL_SWITCH_LIVE_E2E=1 bash tests/fm-agy-model-switch-live-e2e.test.sh
```

Output on the version recorded here:

```
# agy 1.1.16
ok - a live agy worker is running on Gemini 3.1 Pro (High)
ok - the worker holds a conversation this guard can check afterwards
ok - driving /model into a running pane opens the picker the classifier recognises
# live plan: Up 3 high
ok - the walk computed from the live picker lands on Gemini 3.7 Flash (High)
ok - the switch is confirmed by agy's own acknowledgement and by the footer
ok - the worker keeps its conversation across the switch and answers on the new model
# evidence captured against agy 1.1.16
```

The guard deliberately moves between rungs 2 and 3 and never onto rung 1: the
reserved quarter of Opus 4.6 is what the descent protects, and a test must not
be the thing that spends it.
