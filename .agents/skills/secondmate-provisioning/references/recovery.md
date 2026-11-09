# Recovery

For local `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent home.
For a remote route, the same command probes and relaunches only on the configured host.
An SSH transport failure or unreadable remote endpoint remains unknown and must be reconciled on that host; never launch a local replacement.
`stuck-crewmate-recovery`'s remote-secondmate note owns why the endpoint-dead and send-failed verdicts that seem to justify this are themselves unreliable.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inherited local material, so recovered secondmates converge inherited config items and shared captain preferences whenever their home validates; tracked-file sync remains guarded separately.
If the secondmate is already running and only inherited local material changed, prefer `bin/fm-config-push.sh` over respawning.
Before moving a live LOCAL secondmate onto a newly pinned harness, model, or effort, check replacement support in [`docs/agent-control.md`](../../../../docs/agent-control.md#fail-closed-boundaries).
On a supported backend, set `config/secondmate-harness` and relaunch it with `bin/fm-control.sh <id> relaunch`, which re-resolves that pin, stops the agent, and launches the replacement in the same home.
The same relaunch and recovery paths honor the durable [per-secondmate account pin](../../../../docs/configuration.md#per-secondmate-account-pins).
That plane refuses a remotely placed secondmate by name, because its agent runs on another host where none of the plane's postconditions can be read.
Move a REMOTE one with `bin/fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->`, which runs that same control-plane relaunch on its host and then republishes this primary's own route metadata from the identity the host confirmed; pass the profile explicitly and use `default` for an absent pin, because `config/secondmate-harness` is not inherited and the copy on that host belongs to a different home ([`docs/remote-secondmates.md`](../../../../docs/remote-secondmates.md)).
Never call `fm-remote-secondmate-control.sh relaunch` through `fm-on.sh` directly for this: it leaves this primary's own record naming the runtime the mate used to run.
A successful update restarts every live mate of both placements on its own, including one already on the target commit; the `/updatefirstmate` skill owns that pass, and `bin/fm-secondmate-restart.sh` owns its persist gate and failure vocabulary.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.
