# agy in-session model switch - verification record

Evidence backing live ladder movement in `bin/fm-agy-descent-lib.sh`, which
moves an ALREADY RUNNING agy worker between rungs - down when its own rung
crosses its floor, and back up when a rung above it has reset - by driving agy's
own `/model` command into its pane.

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

## Climbing back up, against a real worker

Captured 2026-08-20 against agy 1.1.16 in a disposable Herdr lab session, with a
real worker, a real conversation, and the real picker walk. Only two things were
supplied: the pane transport, routed through `bin/fm-herdr-lab.sh` so the live
default session could not be reached, and the quota READINGS - no real account
can be made to hover at 25%, so the boundary has to be driven.

The run refuses to start unless the live account puts rung 1 clear of the
captain's quarter by the whole margin, so the evidence below can never have been
produced by spending the reserve. It was at 38.9% remaining.

Rung 1 at or below its floor never moves the worker:

```
=== (b) rung 1 at or below its 25% floor must NOT climb a running worker ===
rung 1 held at 25.0% for 4 evaluations (300s apart): no output, worker untouched
rung 1 held at 24.9% for 4 evaluations (300s apart): no output, worker untouched
rung 1 held at 10.0% for 4 evaluations (300s apart): no output, worker untouched
ok - (b) a worker on rung 2 does NOT climb while rung 1 is at or below its 25% floor (footer still: Gemini 3.1 Pro (High))
```

A rung driven across the boundary never flaps the worker. This is the case that
kept the climb out of the descent's own change, so it is driven twelve times
across an hour of evaluated time rather than argued:

```
=== (c) a rung driven across the boundary repeatedly must NOT flap the worker ===
crossing 0: rung 1 at 40.0% (climb line is 35.0%) -> no move
crossing 1: rung 1 at 30.0% (climb line is 35.0%) -> no move
...
crossing 11: rung 1 at 30.0% (climb line is 35.0%) -> no move
ok - (c) 12 boundary crossings over 3600s of driven time moved the worker nowhere (footer still: Gemini 3.1 Pro (High))
```

And a rung held clear of its floor climbs the worker back, with its conversation
and context window intact:

```
=== (a) rung 1 held clear of its floor climbs the worker back, conversation intact ===
first steady evaluation at rung 1 = 41.0%: silent, the dwell has not run
tick output: climbed live Gemini 3.1 Pro (High) -> Claude Opus 4.6 (Thinking)
ok - the evaluation climbed the worker from rung 2 to rung 1
ok - the live worker is now running on rung 1
ok - the durable record followed the worker up to rung 1
ok - the worker returned 46656-BMILC-MF - the codeword FM-CLIMB-65664 reversed, a string never rendered before it answered - so its conversation survived the climb
ok - the worker answered on rung 1 and stayed there

context window BEFORE the climb: Gemini 3.1 Pro (High) | ctx: 0.0% | quota: 97.9% (4h 4m)
context window AFTER  the climb: Claude Opus 4.6 (Thinking) | ctx: 8.7% | quota: 38.8% (4h 27m)
```

The recall asks for the codeword REVERSED rather than repeated, on purpose. The
codeword itself is still in the pane's own scrollback from when it was given, so
a "repeat it" match could be satisfied by that echo; `46656-BMILC-MF` had never
been rendered anywhere before the worker produced it. The context window moving
from 0.0% to 8.7% is the second, independent signal - a rebuilt conversation
would read empty.

Nothing in this section needs its own live refresh on an agy upgrade. The only
VENDOR facts a climb depends on are the picker, the walk, and the two
confirmation signals, and those are identical in both directions and already
guarded below. Everything the climb adds on top - the floor, the dead band, the
dwell, and the refusals - is firstmate's own logic with no agy in it, and is
pinned in `tests/fm-agy-live-descent.test.sh`, which runs everywhere.

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
reserved quarter of Opus 4.6 is what the descent protects, and a routine test
must not be the thing that spends it. The climb evidence above did reach rung 1,
because a climb INTO rung 1 is the behaviour the captain ruled on and there is
no way to demonstrate it elsewhere - and it refused to run at all until the live
account put rung 1 clear of the floor by the whole margin, so it drew on the
free three quarters and never on the reserve.
