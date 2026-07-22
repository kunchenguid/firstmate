# cursor-agent crew oneshot

Status: this is a partial crew-oneshot adapter only.
The oneshot launch was verified on 2026-07-20.
It is not a verified primary harness.

## Scope

Firstmate may dispatch a crewmate or scout on `cursor-agent` through `fm-spawn`'s cursor-agent launch template.
The exact launch flags live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
That path is print-and-exit mode, not a verified interactive pane.
It has no pane busy signature, turn-end hook, primary watcher protocol, resume path, or skill-invocation form.

## Out of scope

- A primary firstmate session is out of scope because there is no turn-end guard, session-start nudge, or watcher protocol.
- Secondmate launches are out of scope.
- Interactive or multiturn panes are out of scope.
- The bare harness name `cursor` is out of scope because it names the IDE; the canonical name is `cursor-agent`.
- `config/crew-dispatch.json` profiles are out of scope; [`docs/configuration.md`](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns that schema.

## Detection

`bin/fm-harness.sh` owns cursor-agent detection.
Set `config/crew-harness` to `cursor-agent` or pass an explicit `--harness cursor-agent` to use this adapter for a crewmate or scout.

## Knowledge owner

Operational facts for spawn and supervision live in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
