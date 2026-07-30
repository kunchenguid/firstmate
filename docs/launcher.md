# Fleet launcher

`bin/fm-launch.sh` is the captain's front door.
It renders a short harness menu, starts one firstmate primary session in this home, and attaches to it.

```sh
bin/fm-launch.sh
```

```
  Firstmate
  Sessions start without permission prompts.

  1  Claude             high                   ← last
  2  ChatGPT Sol        gpt-5.6-sol · high     via pi
  3  Grok               grok-4 · high          via pi - sign in: pi /login
  4  Codex              high                   not installed - install codex
  5  OpenCode           -                      not installed - install opencode

  ⏎ Claude   1-5 select   q quit
```

Press `1`-`5` to select and launch in one keypress, `Enter` to take the marked entry, or `q` to quit.
Quitting creates nothing.
A mistyped key redraws the prompt and waits rather than abandoning the launch.

The launcher starts a PRIMARY session only.
Crewmates, scouts, and secondmates continue to come from `bin/fm-spawn.sh`; both compose their commands from the single owner in `bin/fm-launch-lib.sh`.

## Sessions start without permission prompts

Every harness the menu can start runs its session without permission prompts, four through an explicit bypass flag and one because that harness has no permission system at all.
The launcher states this on every render, before you choose, because you are entitled to know the posture of the session your front door starts.
`bin/fm-launch-lib.sh` records that obligation and which flag each adapter uses.

## Availability is probed, not declared

An entry is shown as available only when it could actually start right now.
Unavailable entries stay visible and dimmed, each carrying the one thing that would fix it, so the menu never changes shape and the numbering stays stable.

Two local checks decide it, and neither touches the network:

- A native entry is available when its harness binary resolves on `PATH`.
- A Pi-routed entry - one whose harness is in the pi family, `pi` or `pi-signed` - is available when its own executable resolves on `PATH` and the provider named in its model (the part before `/`) appears in `~/.pi/agent/auth.json`.
  Both family members share that one auth record, but not an executable: a `pi-signed` entry stays unavailable when only `pi` is installed, because `pi-signed` is a distinct identity that never falls back to `pi`.

Because both checks are local file reads, the menu paints in well under a tenth of a second.
The one thing that slows it is a `PATH` whose misses cross a slow filesystem, such as the Windows mounts a WSL shell inherits; `bin/fm-launch.sh` records the measured numbers.

## Menu presets

The built-in menu needs no configuration.
To change it, create `config/launch-presets.json` in your firstmate home; it is local and gitignored like every other `config/` entry, and it replaces the built-in menu entirely.

```json
{
  "entries": [
    { "id": "claude", "label": "Claude", "harness": "claude", "model": "claude-opus-5", "effort": "high" },
    { "id": "chatgpt-sol", "label": "ChatGPT Sol", "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "effort": "high" }
  ]
}
```

An entry carries no command.
It names a verified harness plus an optional model and effort, and the launcher resolves the actual command through `bin/fm-launch-lib.sh` at launch time.
That is deliberate: a hand-written launch string has already drifted once in a downstream tool, dropping a flag firstmate depends on.

`id` is what the launcher remembers as your last choice, `label` is what the menu shows, and `harness` must be one of the verified adapters that supports a primary session.
Omit `model` or `effort`, or set either to `"default"`, to let the harness choose.
A malformed file refuses at the door rather than silently falling back to the built-in menu.

To reach a harness you have not installed, route it through Pi: set `"harness": "pi"` and a provider-qualified model such as `"xai/grok-4"`, then sign in once with `/login` inside Pi.

Your last successful choice is remembered in `state/.launch-last` and becomes the `Enter` default.
If that entry later stops being available, `Enter` falls back to the first available one instead of offering a choice that cannot start.

## Herdr is required

The launcher creates the session as a tab in this home's Herdr workspace, so Herdr must be installed and recent enough.
It refuses with one actionable line if Herdr is missing or its protocol is older than firstmate's verified minimum, and it never falls back to a bare shell.
The Herdr check runs after you choose, not before the menu, so choosing stays instant.

The launcher also enforces that requirement against the home's own backend setting.
If `FM_BACKEND` or `config/backend` explicitly selects anything other than `herdr`, it refuses before the menu is drawn, naming the configured value - otherwise the primary would start in Herdr while `fm-send`, `fm-watch`, and `fm-spawn` resolve the configured backend, and the one-primary-per-home guard could never see it.
That check is a local read of the same setting the rest of firstmate honors; it contacts no Herdr server, so the menu still paints instantly.

See [docs/herdr-backend.md](herdr-backend.md) for Herdr setup.

## One primary per home

Before creating anything, the launcher takes a short-lived launch lock in `state/` and, while holding it, looks for a primary already running in this home.
If it finds one, it offers to reattach instead of starting a second.
The lock is held from that check until the new session's launch command has been sent, so two concurrent runs of this launcher cannot both pass the check: the second refuses with one line while the first is still starting, and a launcher that dies mid-launch leaves a lock the next run reclaims on its own.
A leftover tab whose agent is gone is not a running session and is replaced normally.
The guarantee is scoped to launches made through this launcher: it does not police a primary started by other means, though once such a session's agent is registered, the reattach check sees it like any other.

## When something goes wrong

Every refusal is one or two lines: what happened, and the one thing that fixes it.
Run with `--verbose` for the underlying mechanics, and `--print-menu` to render the menu without launching anything.

## Maintaining this file

This file is the operator-facing owner of launcher setup and behavior.
Keep it to current behavior, supported limits, and the files an operator sets.
Exact flags, mechanics, and rationale belong in `bin/fm-launch.sh`'s own header and `--help`; the launch commands themselves belong to `bin/fm-launch-lib.sh`; the preset and state file locations are listed in [docs/configuration.md](configuration.md).
