# Effort cue

The effort cue shows the reasoning effort level Claude Code's own requests are going out with as a color above the prompt, and steps that level with one key.
It is part of the `firstmate-calm` mod described in [`calm.md`](calm.md#claude-code) and shares that mod's opt-in exactly: it does nothing at all unless `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` is exactly `1`.
It is independent of the Calm toggle: it draws the same with Calm on and with Calm off, it never turns Calm on or off, and `/calm` never turns it on or off.
There is no Pi equivalent, because Pi already shows its reasoning level in the input area itself.

Claude Code calls this setting the effort level.
It is the `think:high` badge in the footer, the thing `/effort` changes, and the ramp runs `low`, `medium`, `high`, `xhigh`, `max`, `ultracode`.
The footer abbreviates `medium` as `med`.

## What it draws

While the mod is active, one row sits directly above the composer: the level's glyph, the level's name, and a rule filling the rest of the row.
The rule is painted in one of Claude Code's own theme colors, one per level, so the level reads as a color at a glance:

| Level | Glyph | Theme color |
| --- | --- | --- |
| `low` | `○` | `inactive` |
| `medium` | `◔` | `permission` |
| `high` | `◑` | `claude` |
| `xhigh` | `◕` | `warning` |
| `max` | `●` | `fastMode` |

These are the levels a request can carry, which is why they are the levels the cue can name; `ultracode` is covered below.
These are theme color keys, not fixed ANSI or RGB values, so Claude Code resolves each one against the live theme.
The cue therefore follows every built-in theme, its daltonized and ANSI-only variants, and a custom theme, without the mod knowing what any of them look like.

Until a request of the main loop has carried a level, the cue draws `◌ effort ?` in the prompt's own border color rather than guessing one.
That is the honest state, not a failure: the request the engine is about to send is the one thing that says what effort actually goes out, so the cue names a level from the first request of a turn onwards and never from anything weaker.
It returns to `◌ effort ?` whenever a request carries no level at all, which is what a model without an effort parameter does.
A survey drawn in the band owns that row, and the cue yields it for as long as the survey holds it.

## What the cue can know

This is the one rule behind every case on this page, so nothing below repeats it.

The cue is updated by what the plugin can see: the cycle itself, `/effort`, `/model`, and the level each request of a turn reports.
It does not see everything: a command another plugin refuses looks to it like one that ran, and every other way the level can change, the effort slider, the model picker, or anything else that raises no event, is invisible to it.
Until the next request confirms a level, the cue goes on showing the last level it knew, which may by then be the wrong one.
`ultracode` cannot be told apart from `xhigh` in what a request reports, so any path that reaches `ultracode` without the plugin seeing it can leave the cue naming `xhigh` while the footer says `think:ultracode`.
The cue never claims a level it has not been told or shown: where it cannot know, it draws `◌ effort ?`.

## Changing the level

Three paths change it, and all three move Claude Code's real setting:

- `/effort-cycle` steps up one level and wraps from the top back to `low`.
- `ctrl+x tab` focuses the band above the prompt and `enter` presses the cue, which steps the level the same way.
  These are Claude Code's own default bindings (`abovePrompt:focus` and `abovePrompt:press`) and need no configuration.
- `/effort <level>`, the effort slider, and the model picker keep working unchanged.

A command the plugin sees leaves the cue at `◌ effort ?` until the next request of a turn carries whatever level took effect.
Running `/effort` is not proof that it took: Claude Code can decline a level your plan or your model does not offer, or set the highest level allowed instead, and it says so in its own output rather than by failing.
So the cue never names the level that was asked for, only a level a request carried.
Before the conversation holds any reply, nothing can turn a step down, so a step taken then that left the session where it already was asked for a level the model in use cannot have, and the cycle passes over that level from then on.
Which levels exist is the model's business, so those declines are forgotten as soon as a request runs another model.
After the first reply a step can be turned down at Claude Code's own confirmation, described below, and that looks exactly like a level the model does not offer, so no step after it is read as a decline: a level that stays where it was is still on the ramp, and the next lap asks for it again.
For every other way the level moves, see [What the cue can know](#what-the-cue-can-know).

The cycle visits `low`, `medium`, `high`, `xhigh`, and `max`, minus any the model in use has declined.
It deliberately skips `ultracode`, because Claude Code's own slider describes that level as `xhigh + workflows`: stepping into it would turn multi-agent orchestration on as a side effect of a keystroke.
It also skips `auto`, which is a choice to let Claude Code pick per turn rather than a point on the ramp.
Both stay available through `/effort`.
Under `auto` the cue names the level each request resolves to.
One cycle step leaves `ultracode` by wrapping to `low`, the same wrap the top of the ramp has, and that `low` then becomes your saved default for the model, so the step off `ultracode` is a step to the bottom rather than a step up.

The first step of a session has no request to start from, so it steps up from the level Claude Code has saved for the session's model, and from your saved default only when that model has no level of its own.
That is the level a new session starts at, so the step lands one above where the session is, and a model saved at `ultracode` wraps to `low` as above.
When nothing is saved, or the model's own saved level is something the ramp cannot express such as `auto`, the keystroke changes nothing and says so, rather than guessing a level and moving your setting to it.

If Claude Code refuses to run `/effort` at all, a transient notice says so, and the cue keeps naming the level the last request carried.

Claude Code 2.1.280 asks you to confirm the first change of effort after each reply, because the conversation is cached at the level in force, so a step taken after a reply is one press and then `enter` on `Yes`.
A new session asks nothing until its first reply, while a resumed one can ask from its first change.
Choosing `No, go back` keeps the level you had, and it is not read as the model declining the level you turned down: the next press offers that level again.

### Binding it to one key

Claude Code's mods API has no way for a mod to claim a chord of its own, so the single keystroke is one line in your own `~/.claude/keybindings.json`.
A binding whose action is `command:<name>` runs that slash command, so any chord can drive the cycle:

```json
{
  "bindings": [
    {
      "context": "Chat",
      "bindings": { "ctrl+tab": "command:effort-cycle" }
    }
  ]
}
```

Firstmate never writes that file, and adding the line above is the one step you do by hand.

Whether a given chord reaches Claude Code at all is up to whatever sits in front of it.
A terminal or a multiplexer that maps `ctrl+tab` for itself consumes the chord first, so Claude Code never sees it and the binding above never fires.
Retire or redirect any such mapping before adding the binding: in Ghostty that is the `keybind` line for `ctrl+tab` in its config, and in tmux the `bind-key` for it.
Some terminals keep `ctrl+tab` for their own tab switching with no way to release it; there, bind a chord they do pass through instead.

## Bounds

Each of these is recorded with its evidence in [`calm-mode-feasibility.md`](calm-mode-feasibility.md#2026-09-17-claude-code-21274-effort-cue-feasibility-and-the-shipped-cue), and the 2.1.280 confirmation in its [2026-10-05 record](calm-mode-feasibility.md#2026-10-05-claude-code-21280-effort-change-confirmation).

- The function-hooks surface is early access and default-off, and Claude Code states its API may change between releases without notice; the cue was designed against Claude Code 2.1.274 and its guards last ran against 2.1.280.
- Models without an effort parameter have no level to show, and no footer badge either; on those the cue stays at `◌ effort ?`.
- `/effort low`, `medium`, `high`, and `xhigh` save the level as your default for new sessions on that model, so cycling changes what your next session starts at, exactly as typing `/effort` yourself does.
  `max` applies to this session only, and a level above the cap for the model is set to that cap instead; neither saves anything.
- The request a turn sends is the only thing that tells a mod what level is in force, so no change can reach the cue before the next turn starts, and a session that has run no turn yet shows no level.
  What follows from that is [What the cue can know](#what-the-cue-can-know).
- Claude Code checks the effort of its own request against `low`, `medium`, `high`, `xhigh`, and `max`, which is why `ultracode` is a level the cue can never name.
- The level Claude Code saves in your settings is what a new session starts at, not what this session is running, so the cue never shows it; a session started with `--effort`, or changed for this session only, would make it wrong.
  The cycle reads it for one thing only, which is where a first keystroke climbs from.
  Every session on the machine shares it, and it never records `max` or a capped level, so it never decides whether a step took.

## Regression entry points

```sh
tests/fm-calm-claude-mod.test.sh
tests/fm-calm-claude-mod-plugin.test.sh
FM_CLAUDE_CALM_LIVE_E2E=1 tests/fm-calm-claude-mod-live-e2e.test.sh
```
