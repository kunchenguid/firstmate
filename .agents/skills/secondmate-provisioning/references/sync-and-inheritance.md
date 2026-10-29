# Secondmate sync and inherited local material

Load this with the `secondmate-provisioning` skill before launching, recovering, or syncing a secondmate home, pushing inherited local material into one, or changing an inherited item or `data/captain-shared.md`.

This reference is the single owner of the secondmate sync and inherited-local-material propagation contract; `AGENTS.md` sections 3 and 4 point here through the `secondmate-provisioning` skill.
Before a local launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe, or reconciles a clean divergence whose complete local result is already present there (e.g. after a squash merge) with `reset --keep`; dirty, uniquely diverged, or in-flight homes launch unchanged with a warning, and a genuine divergence gets the same durable reconciliation record `bin/fm-ff-lib.sh` writes for `/updatefirstmate`.
The locked session-start deferred network stage runs the same bootstrap sweep for every live local secondmate home, discovered from `state/<id>.meta` records with `kind=secondmate` (`data/secondmates.md` only backfills `home=` for older records).
That no-fetch path is a purely local fast-forward or redundant-divergence reconcile of tracked files, never an origin fetch, and it never touches the gitignored operational dirs, so a secondmate's backlog, projects, and in-flight work are never disturbed; a linked worktree advances immediately, while a standalone clone that lacks the target receives firstmate updates through `/updatefirstmate`'s origin refresh.
A remote launch and the deferred bootstrap sweep hand the configured host the primary's own default-branch commit and ask it to fast-forward, or reconcile a redundant divergence, the persistent home to exactly that commit, under the same clean, ancestry, and branch guards a local home gets.
A remote home is a standalone clone on another machine, so that host imports the one commit it was given - already present, else from that host's own Firstmate copy without moving it, else from the home's origin - and skips with an actionable reason when none of them holds it, which is what an unpushed primary commit looks like from there.
Neither path moves the host's Firstmate copy, and the host-local launch never re-targets that copy after the parent has already synced the home.
`/updatefirstmate` is the one path that still follows that copy: it first updates the remote code root from its own origin, then syncs the home to that refreshed code-root commit.
SSH exit 255 preserves the route and reports unknown completion; it never triggers local respawn or failover.
The same placement-specific launch and deferred bootstrap sweep also propagate the primary's inherited local material declared by [`fm_config_inherit_items`](../../../../bin/fm-config-inherit-lib.sh), whose owner also defines which items are session-scoped.
Because these paths are gitignored, that propagation is a separate, primary-authoritative copy independent of the tracked-files fast-forward: it re-converges every live home whether or not its tracked files advanced, and it touches only the declared items.
Propagation failures warn without blocking a local secondmate launch or session-start continuation; a remote prelaunch transfer failure refuses that launch.
The destination keeps whatever safely validated state the helper left behind.
For inherited config files, local propagation and the remote sender preserve the destination item on source inspection errors and mirror only proven absence; [`fm-config-inherit-lib.sh`](../../../../bin/fm-config-inherit-lib.sh) owns this boundary.
Inheritance copies the literal `config/crew-harness` file, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter such as `codex`; an unset or `default` value has nothing concrete to inherit, and the secondmate's own crewmates fall back to the secondmate's own or detected harness instead.
Inherited `config/backend` becomes that secondmate home's local runtime-backend default for future spawns only; it never retargets, rewrites, migrates, stops, or restarts an already-live worker endpoint.
A present primary `config/backend` value always converges byte-exact into validated secondmate homes, and primary absence removes that backend setting so those homes keep runtime auto-detection.
Explicit per-spawn `--backend` and `FM_BACKEND` remain stronger than every home's local `config/backend`, including an inherited default.
The declared `config/supervision-host-off` opt-out follows the same primary-authoritative propagation: its presence opts secondmate homes out even if they have their own engine setting, and its absence removes their copy at convergence.
`config/supervision-host` itself is not inherited; each home selects its own engine.
`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
`config/firstmate-role` is inherited under the additional [resolved-role and receipt policy](../../../../docs/configuration.md#firstmate-role-configfirstmate-role), not as a raw copy of the primary file.
Account pins are not inherited.
[`Worker account pin`](../../../../docs/configuration.md#worker-account-pin-configclaude-account-configpi-account) owns `config/claude-account` and `config/pi-account` inheritance and backend limits; [`T3 provider instances`](../../../../docs/t3code-backend.md#provider-instances-and-models) owns T3 account selection.
[`docs/configuration.md` "Per-secondmate account pins"](../../../../docs/configuration.md#per-secondmate-account-pins) owns the explicit `config/secondmate-accounts/<id>/` override and the independent worker pins inside each mate's home.
`data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes.
Its primary file header must state that the file is main-authoritative, read-only in secondmate homes, must not be edited there, and that new captain-preference discoveries are routed to the main firstmate through marked status or a document pointer.
Every propagation point converges the secondmate copy to the primary bytes; when the primary file is absent, any existing secondmate copy is quarantined and removed so absence converges too.
Both the local helper and the remote receiver compare the destination against the generation each last published there, so an untouched inherited copy is replaced quietly instead of being reported as drift.
A destination matching neither the primary bytes nor that recorded generation is quarantined to a collision-safe private dated sibling file before replacement, with a `SECONDMATE_SYNC:` diagnostic naming the home and quarantine artifact on the local route, so genuine local edits and interrupted publication keep a recovery copy.
The helper rejects unsafe directories, symlinked or nonordinary source or destination artifacts, and hardlinked destination files.
Between propagation runs, the secondmate copy is filesystem read-only; the helper may make its owned destination writable only around a guarded update and restores read-only mode on success, unchanged bytes, and recoverable failure paths.
Never copy any secondmate `data/captain-shared.md` back into the primary.
Keep each home's `data/captain.md` domain-local.
After first propagation to an existing home, trim that home's local `data/captain.md` by hand to domain-specific content plus pointers to `data/captain-shared.md`; do not automate or silently delete private content.
Keep every `data/learnings.md` fully local by captain decision; route fleet-general machinery facts into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation.
No AGENTS.md reread nudge is needed at spawn or respawn because the agent reads instructions fresh on launch; only the bootstrap sweep's running-home instruction-surface advance needs that AGENTS.md re-read.
Bootstrap reports successful AGENTS.md re-read sends as `BOOTSTRAP_INFO:` and only emits `NUDGE_SECONDMATES:` when that send fails and needs retry.
A separate, literal-content config reread is required whenever inherited `config/*` material changes under an already-running secondmate.
For a local home, after each successful allowlisted config write, both the locked bootstrap convergence path and mid-session `bin/fm-config-push.sh` use the shared propagation report to build one per-home generation-specific private instruction file from the validated destination post-write bytes for only the declared config items that actually changed for that home, in declaration order.
Each changed path is printed with clear begin/end delimiters and the destination file's full exact new bytes unparsed, or the explicit token `ABSENT` when propagation removed the destination copy.
The instruction uses only minimal framing that these are defaults/rules and do not remove judgment; it never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation.
`data/captain-shared.md` is not a config file and is never inlined into this instruction file or message.
Homes whose allowlisted config files were all unchanged receive no config-reread message when no retry is pending.
Different homes may receive different changed-file sets based on their pre-push destination bytes.
Delivery uses the existing routed secondmate path (`fm-send`) with only a single-line `CONFIG_REREAD: <absolute generation-specific instruction path>` pointer; a failed instruction publication retains the generated exact bytes in a bounded private retry queue when possible, legacy retry reports remain recoverable, a failed publication or retry-marker write retains the exact generation until it can be delivered, a failed send records a per-generation durable retry marker when possible, and all failures surface a concrete `CONFIG_REREAD:` diagnostic without claiming the live agent already re-read the values.
The propagation, generation publication, and pointer-delivery sequence holds one per-home inheritance lock, so concurrent mid-session pushes cannot deliver an older generation after a newer one.
A newly launched or relaunched secondmate already reads its files at launch, so its pending config-reread generations are discarded or quarantined after cleanup failure and it needs no redundant live-agent config nudge unless propagation changes files after launch.
Quarantined pre-relaunch generations are retained in bounded private history, and cleanup skips creating an empty quarantine generation.
Successfully delivered generations are retained only within a bounded per-home state history, while pending generations remain until delivery succeeds or a launch supersedes them.
A remote home receives the same allowlisted bytes through `fm-remote-inherit.sh` and gets one marked re-read instruction after successful convergence when a transfer or tracked instruction-surface change requires it, or an earlier re-read remains owed.
An unchanged transfer or a tracked advance outside `AGENTS.md`, `bin/`, and `.agents/skills/` creates no new re-read obligation.
The parent records that nudge before delivery, retains it after a failed send, a partial apply, unknown completion, or an attempt killed before it reported, and retries the exact same route during locked bootstrap convergence.
[`fm-secondmate-nudge-lib.sh`](../../../../bin/fm-secondmate-nudge-lib.sh) owns the durable obligation record and compatibility behavior.
It does not receive a pointer to a primary-local generation path that cannot exist on that host.
Inherited harness and runtime-backend defaults must not harden `fm-spawn` to reject a deliberate runtime choice that differs from those defaults.
The [worker launch environment contract](../../../../docs/configuration.md#worker-launch-environment-configlaunch-env-allowlist) separately governs explicit environment grants.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited local-material change without running the tracked-file fast-forward.
It uses the same live-home discovery and propagation helper as bootstrap, reports each item as `pushed`, `unchanged`, `skipped`, or `error`, and follows the config-reread contract above for changed or pending generations.
