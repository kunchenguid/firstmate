# cursor-agent crew oneshot

Status: partial crew adapter only.
Verified oneshot launch on 2026-07-20.
Not a verified primary harness.

## Scope

Firstmate may dispatch a crewmate or scout on `cursor-agent` through the normal `fm-spawn` launch template:

```text
cursor-agent -p --force --trust --workspace "$(pwd)" "$(cat <brief>)"
```

That path is oneshot print mode (`-p`): the process runs the brief, prints the result, and exits.
Busy and done are process lifetime, not a pane busy signature or turn-end hook.

## Out of scope

- Primary firstmate session (no turn-end guard, no session-start nudge, no watcher protocol).
- Interactive / multiturn panes (Herdr `agent start … -- cursor-agent` was tried; `agent_status` stayed unknown and name lookup flaked — do not claim interactive verified).
- Bare harness name `cursor` (the IDE). Canonical name is `cursor-agent`.
- `config/crew-dispatch.json` verified-harness allowlist (still the five full primaries until this adapter graduates).

## Detection

`bin/fm-harness.sh` recognizes `CURSOR_AGENT=1` and process names/args matching `*cursor-agent*`.
Set `config/crew-harness` to `cursor-agent` to force crew resolution without depending on own-harness detection.

## Knowledge owner

Operational facts for spawn and supervision live in `.agents/skills/harness-adapters/SKILL.md` under the `cursor-agent` section.
