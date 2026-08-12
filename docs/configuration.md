# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Local directory boundary

The repository-root `/config/`, `/reports/`, and `/backups/` directories are gitignored local fleet material.
The ignore rules are root-anchored, so same-named directories nested under tracked shared surfaces such as `docs/examples/` and `tests/` remain trackable.
Keep reusable configuration examples under [`docs/examples/`](examples/) and copy them into the local `config/` directory when needed.
Parent-owned secondmate reply expectations are private runtime state under `state/pending-replies/`; resolved and explicitly retired records move to `state/pending-reply-history/`. Do not edit either directory by hand: `bin/fm-pending-reply-lib.sh` owns their exact schema, recovery, escalation, teardown handoff, and retention rules.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer.
If the default backend is selected but `tasks-axi` is missing or incompatible, bootstrap suggests `npm install -g tasks-axi` through the normal consent flow and falls back to manual editing until it is installed.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the install suggestion.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` task sections.
Homes may also carry a `## Secondmate Backlogs` inventory section with `- <secondmate-id> ...` lines for persistent secondmates; `fm-backlog-audit.sh` treats those ids, plus ids in `data/secondmates.md`, as registered secondmate inventory rather than ordinary In flight work.

## Runtime backend (`config/backend` / `FM_BACKEND`)

The runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend; `herdr` is the experimental backend (see [`docs/herdr-backend.md`](herdr-backend.md)).
Treehouse remains the worktree provider for both backends because Herdr, like tmux, is only a session provider.
New spawns choose the backend in this order: an explicit `--backend` flag firstmate passes when it spawns a task, then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX` or `HERDR_ENV=1`, then default `tmux`.
If both runtime markers are present, `$TMUX` wins because it is the innermost provider.
Auto-detected Herdr prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Any value other than `tmux` or `herdr` is rejected.
The session-start secondmate liveness sweep uses a deeper `fm_backend_agent_alive` probe where verified.
That probe can classify tmux and Herdr secondmate endpoints as `alive`, `dead`, or `unknown`.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A backend spawn refusal from a missing dependency or version gate is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded `window=` backend target, and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and uses the same recorded backend target fields after loading `state/<id>.meta`.
By default, Herdr workspaces are derived from `FM_HOME`: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
The default-container spawn, list-live, and recovery paths read that label from the active home, so a secondmate's own crewmates stay inside that secondmate home's herdr space.
The optional local `config/herdr-presentation-spaces` presence flag instead enables Herdr's default-off disposable single-task visual projection; [Optional presentation spaces](herdr-backend.md#optional-presentation-spaces) owns its behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The flag is default-off and inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
The `config/backend` file is not inherited by secondmate homes.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend refuses at daemon startup instead of trying the wrong injection primitives.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
This section is the channel reference; `config/wedge-alarm` is a plain local file containing the listed directives.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
That evidence policy is specific to the firstmate repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but firstmate keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
Local no-mistakes Test stays intent-targeted; [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) owns the broad portable and required real-Herdr lane composition.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for local test entry points and [herdr-backend.md](herdr-backend.md) for the real-Herdr lane's verification and isolation rationale.
The Phase 2 concurrent isolation proof for the portable parallel candidate set is owned by `bin/fm-test-isolation-proof.sh`; it does not enable production CI sharding.

## Captain preferences (data/captain.md)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` and optional `data/secondmates.md` during bootstrap.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and read right after `data/captain.md` during bootstrap.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: rewrite or prune stale entries instead of appending forever.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
`fm-backlog-audit.sh` also uses these ids as registered persistent inventory, so a live `kind=secondmate` meta record does not have to appear under the main `## In flight` section.
Use `fm-home-seed.sh <id> - <project>...` to lease a fresh firstmate worktree for the secondmate home.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown retries a `treehouse return` error only when Git reports an existing `index.lock`, then fails closed if the lease still cannot be released; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent, moves each selected item's indented continuation context with it, and refuses in-flight items or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents.
When it is absent or contains `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, preserving the previous behavior.
`config/secondmate-profile.json` is the separate local, gitignored model/effort profile for those primary-to-secondmate launches, for example `{"model":"gpt-5.6-sol","effort":"high"}`.
It never chooses the harness; `config/secondmate-harness` keeps that job.
Missing file, omitted keys, and explicit `"default"` values preserve `model=default` and `effort=default`.
Explicit `--model` or `--effort` on `fm-spawn.sh --secondmate` overrides the file for that one launch.
An explicit harness argument to `fm-spawn.sh` still overrides either harness config file for that spawn only.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
`config/secondmate-profile.json` is not inherited either; use inherited `config/crew-dispatch.json` for a secondmate home's own future crewmate and scout defaults.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best profile with judgment and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness`, then apply any primary-local `config/secondmate-profile.json` model or effort defaults.
Each rule has `when`, `use.harness`, optional `use.model`, optional `use.effort`, and optional `why`; an optional `default` profile uses the same `use` shape without `when`.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
The recommended Codex family policy is: keep MiniMax for very simple token-saving work, use `gpt-5.6-luna` for small Codex-shaped tasks, use `gpt-5.6-terra` as the everyday default, and use `gpt-5.6-sol` for high-risk or critical work.
When the file exists, bootstrap validates it with `jq`.
Valid files produce a `CREW_DISPATCH: active config/crew-dispatch.json` block that lists each rule as `rule: <when> -> <harness[/model[/effort]]>` and prints `default:` when present.
Malformed JSON, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
If no dispatch rule fits, firstmate uses the dispatch profile `default` when present, then falls back to `config/crew-harness`.
Because the spawn backstop is gated by file presence, any fallback path after a missing match, validation error, or missing `jq` still passes a resolved harness explicitly until the file is fixed or removed.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Toolchain

On first launch the first mate detects what its required toolchain is missing or too old (tmux for the default backend, node, gh with `gh pr checks --json` support, treehouse with durable lease support, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, and lavish-axi), lists it with the exact install commands, and installs only after you say go. When Herdr resolves, bootstrap also requires the Herdr 0.7.x CLI and `jq`.
Bootstrap, spawn, teardown, and read-only supervision normalize existing `$HOME/.nvm/versions/node/*/bin` and `$HOME/.local/bin` directories before looking up Axi tools. This covers clean non-interactive SSH shells without overriding an explicit caller PATH.
Set `FM_TOOL_PATH_HOME` only when those shared lookups must use a home directory other than `HOME`, such as in a specialized shell or test fixture.
When `config/crew-dispatch.json` or `config/secondmate-profile.json` exists, bootstrap also requires `jq` for JSON validation.
Malformed `config/secondmate-profile.json`, a non-object top level, non-string axes, an empty model, or an effort outside `default|low|medium|high|xhigh|max` is reported as `SECONDMATE_PROFILE: invalid config/secondmate-profile.json - ...`.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
Unless `config/backlog-backend=manual`, bootstrap treats `tasks-axi` as the default backlog backend.
If compatible `tasks-axi` is already on `PATH`, bootstrap records it as `TASKS_AXI: available` and firstmate uses its verbs for routine backlog mutations.
When it is absent or incompatible, bootstrap reports `MISSING: tasks-axi (install: npm install -g tasks-axi)` and firstmate keeps hand-editing `data/backlog.md` until installation is approved and completed.
When `config/backlog-backend=manual`, bootstrap hand-edits and does not suggest installing `tasks-axi`.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inherited local material into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a live secondmate endpoint is skipped or respawn fails; already-live and successfully respawned endpoints are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `herdr-presentation-spaces`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
The locked bootstrap inheritance pass uses the same per-home changed-set and reread path for already-running homes; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

Bootstrap turns the token into local generated state.
It writes `state/x-watch.check.sh`, a check shim that runs `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher arms in that home.
When the token is removed or empty, the next bootstrap removes those artifacts.
Steady-state off is silent and writes nothing.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate with `x-mention <request_id>`.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts one completion follow-up when the task reaches a terminal state.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-tweet replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
The client rejects image files larger than `FMX_IMAGE_MAX_BYTES` before base64 encoding; the default is 5242880 bytes.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`.
Add `--image <path>` there too when the completion follow-up should carry an image.
The follow-up helper clears the link after a successful post or after the 24h window has elapsed; a failed post leaves the link in place so it can be retried.
If the reply exceeds `FMX_X_REPLY_MAX_CHARS`, the client splits it into a numbered thread on word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener tweet and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_X_THREAD_MAX` defaults to 25 and caps oversized replies, marking the last retained tweet with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 86400 and controls the local completion follow-up window.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Cognee trial memory

Cognee is trial-only memory context for Firstmate.
It is not a source of truth, durable archive, proof system, or action authority; [cognee-policy.md](cognee-policy.md) owns the operating policy.

Manual lookup is configured with `FM_COGNEE_LOOKUP_CMD`, `FM_COGNEE_MANIFEST`, and the already-exported Cognee read-only credentials.
`fm-memory-lookup.sh` runs the backend only when invoked by hand, treats output as a hint, and attaches only local source paths it can reopen.
Without `FM_COGNEE_LOOKUP_CMD`, it exits 0 with a memory-unavailable note so dispatch continues without Cognee.

Live lookup through `fm-cognee-lookup.sh` requires `COGNEE_BASE_URL`, `COGNEE_API_KEY`, a dataset selector (`COGNEE_DATASET_ID` or `FM_COGNEE_DATASET_ALIAS`), and a manifest path (`FM_COGNEE_MANIFEST` or `--manifest`).
`FM_COGNEE_ENV_FILE` may load only the allowlisted Cognee names from an env-style file; malformed or unreadable files fail closed without shell-sourcing the file.
The live wrapper calls only `POST /api/v1/search`, records secret-safe telemetry, and still delegates proof to local manifest/source verification.

Automatic lookup remains disabled unless `FM_COGNEE_AUTO_LOOKUP=1` and the local evidence under `FM_COGNEE_EVIDENCE_ROOT` proves every gate marker, including `FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call` and `FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass`.
`session_window_only` cost evidence is accepted only as trial monitoring evidence and still blocks automatic promotion.

## Optional codebase-memory-mcp (CBM)

CBM is optional code orientation for multi-file exploration (architecture maps, call chains, "where is X?").
It is not proof, not runtime truth, and not authority for merge, deploy, refresh, purchase, or destructive action.
Missing binary, empty index, or disabled config never blocks spawn or marks a crewmate `blocked`.

### Local config (root-level `config/`, gitignored)

Copy the tracked examples when you want host-local overrides:

- [`docs/examples/cbm.env.example`](examples/cbm.env.example) → `config/cbm.env`
- [`docs/examples/cbm-projects.example`](examples/cbm-projects.example) → `config/cbm-projects`

`config/cbm.env` accepts only simple `FM_CBM_*=value` lines (no shell execution). Supported keys: `FM_CBM_ENABLED`, `FM_CBM_CACHE_DIR`, `FM_CBM_MEM_BUDGET_MB`, `FM_CBM_WORKERS`, `FM_CBM_BIN`.

`config/cbm-projects` is an allowlist of project basenames or absolute paths that receive the CBM brief block.
When the file is absent, First Mate defaults to `.openclaw`, `jt-control-room` / `JT-Control-Room`, and `firstmate`.
When the file exists, only listed entries match (defaults are not merged).

### Defaults and spawn behavior

- `FM_CBM_ENABLED=auto` (default): CBM is on only when the `codebase-memory-mcp` binary is found on `PATH` or under common install paths.
- `0` / `off` force off; `1` / `on` require a binary.
- Cache defaults to `/root/var/cbm-cache` when that directory exists, otherwise `$HOME/.cache/codebase-memory-mcp`.
- Resource caps default to `CBM_MEM_BUDGET_MB=1024` and `CBM_WORKERS=2`; values outside `1–4096` MB or `1–8` workers fall back to those defaults.

On **ship/scout** spawn for an eligible project, `fm-spawn.sh`:

1. Appends an idempotent CBM orientation block to the brief (after JT PR Intake Governor / route blocks when present).
2. Exports `CBM_CACHE_DIR`, `CBM_MEM_BUDGET_MB`, `CBM_WORKERS`, and prepends the binary directory to `PATH` in the pane.
3. Prefixes the same env onto the harness launch command so the agent process inherits CBM even if a later export is missed.

Secondmate launches never get the CBM brief block or env injection (charters stay clean; CBM remains a crewmate orientation aid).

First Mate does **not** run `codebase-memory-mcp install` or rewrite multi-agent MCP configs.
Host MCP registration (for example Codex `~/.codex/config.toml`) stays a captain-side setup step.
Index data lives under the cache directory and is not committed to the firstmate repo.

Use `bin/fm-cbm-index.sh status|list|index [jt|firstmate|all|<abs-path>]` for ops hygiene on this host. `jt` resolves to the JT Control Room app path; the `.openclaw` monorepo root is never an index target, even though it remains eligible for spawn orientation.

### Durable usage log (not Codex logs)

CLI and index metering do not depend on Codex session logs that get wiped for disk:

- Log file: `$FM_HOME/data/cbm/usage.jsonl` (under gitignored `data/`)
- Logged CLI: `bin/fm-cbm-cli.sh <tool> [json]` (used by `fm-cbm-index.sh`; recommended in crewmate briefs)
- Optional MCP session counter: set host MCP `command` to `bin/fm-cbm-mcp.sh` (one `mcp-session` line per process start, not per tool)
- Inspect: `bin/fm-cbm-usage.sh summary`, `path`, or `tail [N]`

Ship/scout panes export `FM_CBM_TASK_ID` and `FM_CBM_CLI` when CBM env injection runs so wrapper lines can tag the task.

## Codex session lock lifecycle

Codex primaries use the tracked `SessionStart` hook to claim their home's
session lock before the first model turn. The structured owner combines the
stable `CODEX_THREAD_ID` with a verified harness PID when one is visible.
Later PID-isolated calls from the same thread preserve that owner; a different
thread remains excluded.

The tracked `SessionEnd` hook releases only a regular, non-symlink lock in the
same home whose structured thread marker exactly matches the ending session.
It leaves numeric legacy locks and malformed, unreadable, differently owned,
or concurrently busy locks untouched. Numeric lock files remain supported for
other harnesses and older homes. `GROK_AGENT=1` takes precedence over an
inherited `CODEX_THREAD_ID`, so a Grok primary is never treated as Codex.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home; unset means this repo root
FM_ROOT_OVERRIDE=        # override firstmate repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_BACKEND=tmux          # runtime session-provider override for new spawns; herdr is experimental and opt-in
FM_TOOL_PATH_HOME=       # optional HOME override for shared NVM and user-local tool discovery
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3   # additional `treehouse return` retries after a matching transient git index.lock error; invalid values use 3
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1   # whole seconds between those retries; 0 disables waiting and invalid values warn then use 1
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merge polls or the X-mode poll shim)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-tweet split budget; values below 50 clamp to 50
FMX_X_THREAD_MAX=25     # maximum tweets in one auto-split X reply thread
FMX_IMAGE_MAX_BYTES=5242880 # maximum outbound image attachment size before base64 encoding
FMX_FOLLOWUP_MAX_AGE_SECS=86400   # local window for posting one X completion follow-up
FMX_NOW_OVERRIDE=       # test-only epoch override for X task-link and follow-up window checks
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid or mismatched-identity lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_LOCK_LEGACY_IDENTITY_MAX_AGE=300 # seconds to keep an unmigratable pre-v1 locale-dependent PID identity before it is reclaimable
FM_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_ARM_FOLLOWER_CLAIM_TIMEOUT=10 # seconds a re-arm waits for a stale follower lock to become reclaimable
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_WATCH_SESSION_REARM_DELAY=1   # seconds watch-session waits after failed arms or quiet healthy no-op arms; wake output re-arms immediately
FM_WATCH_SESSION_RETRY_DELAY=    # legacy alias for FM_WATCH_SESSION_REARM_DELAY
FM_WATCH_SESSION_AFK_DELAY=15    # seconds watch-session sleeps while the AFK daemon owns supervision
FM_WATCH_SESSION_TMUX_SESSION=firstmate-watch   # tmux session name for durable watch-session runner windows
FM_WATCH_SESSION_TMUX_WINDOW=   # optional tmux window name; default is fm-watch-<home/state hash>
FM_ALLOW_WATCH_SESSION_WITH_GROK=    # set exactly 1 only for the emergency tmux fallback; Grok otherwise reserves the follower wait for its tracked background arm
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE=             # optional extra captain-relevant status regex; built-in terminal and legacy matches remain active, while nonterminal progress verbs stay excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3          # additional waits before stale-lock proof; invalid values use 3
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1  # seconds between signature-matched retries; invalid values use 1
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30        # minimum lock age before removal can be considered
FM_ISOLATION_VERBOSE=0   # also emit BOOTSTRAP_INFO for non-actionable worker-isolation sweep results
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by watcher and tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
# read-only supervision view (bin/fm-supervise.sh)
FM_SUPERVISE_TREEHOUSE_TIMEOUT=5   # seconds allowed per treehouse status read
FM_SUPERVISE_GH_TIMEOUT=5          # seconds allowed per gh-axi GitHub read
FM_SUPERVISION_CONVERGENCE_OBSERVE_SECS=5   # total seconds per collection for read-only no-mistakes convergence reads
FM_SUPERVISION_CONVERGENCE_ROUND_CEILING=3  # correction round that creates a captain decision; invalid or zero values use 3
# bootstrap, spawn, teardown, and fm-supervise append existing HOME-local NVM and .local/bin entries when absent
# Optional codebase-memory-mcp (CBM) orientation; also loadable from config/cbm.env
FM_CBM_ENABLED=auto        # auto | 1 | 0 — auto enables only when the binary is present
FM_CBM_CACHE_DIR=          # SQLite graph store; default /root/var/cbm-cache or $HOME/.cache/codebase-memory-mcp
FM_CBM_MEM_BUDGET_MB=1024  # memory budget exported as CBM_MEM_BUDGET_MB at spawn
FM_CBM_WORKERS=2           # worker cap exported as CBM_WORKERS at spawn
FM_CBM_BIN=                # optional absolute path to codebase-memory-mcp when not on PATH
# Cognee trial memory and local verification
FM_COGNEE_LOOKUP_CMD=      # executable backend path for manual memory lookup, usually bin/fm-cognee-lookup.sh
FM_MEMORY_LOOKUP_MAX_HINT_LINES=40   # maximum hint lines printed from a manual memory lookup
COGNEE_BASE_URL=           # Cognee Cloud/API base URL for explicit live lookup
COGNEE_API_KEY=            # Cognee API key for explicit live lookup
COGNEE_DATASET_ID=         # UUID dataset selector; logged only as a sha256 hash
FM_COGNEE_DATASET_ALIAS=   # alternate dataset selector when COGNEE_DATASET_ID is absent
FM_COGNEE_MANIFEST=        # local manifest used for Cognee answer/source verification
FM_COGNEE_ENV_FILE=        # optional env-style file; only allowlisted Cognee names are loaded
FM_COGNEE_SEARCH_TYPE=RAG_COMPLETION   # searchType sent to POST /api/v1/search
FM_COGNEE_TOP_K=8          # topK sent to POST /api/v1/search
FM_COGNEE_MAX_ATTEMPTS=3   # live lookup attempts before fail-closed exit
FM_COGNEE_TIMEOUT_MS=30000 # connect and request timeout budget for live lookup
FM_COGNEE_TELEMETRY_FILE=  # default: $FM_HOME/data/cognee/telemetry.jsonl
FM_COGNEE_EVIDENCE_ROOT=/root/firstmate/data   # local evidence root for fm-cognee-lookup-gate.sh
FM_COGNEE_AUTO_LOOKUP=0    # must be 1 plus all evidence markers before automatic lookup is allowed
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=tmux         # AFK supervisor injection backend; tmux default, herdr experimental opt-in
FM_SUPERVISOR_TARGET=firstmate:0   # supervisor target (override; auto-discovers tmux or HERDR_SESSION:HERDR_PANE_ID)
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

If a batched away-mode escalation remains undelivered past `FM_MAX_DEFER_SECS`, the daemon preserves the escalation buffer and writes `state/.subsuper-inject-wedged`. The read-only `bin/fm-supervise.sh` checklist and `--json` model surface that non-empty marker as the high-severity `supervision:inject-wedged` finding owned by firstmate; reading it does not clear the marker or retry injection.

The AFK daemon supports `FM_SUPERVISOR_BACKEND=tmux|herdr`. When `herdr` is
selected, `FM_SUPERVISOR_TARGET` is a Herdr `<session>:<pane-id>` target and
injection uses Herdr's pane send primitives. Unsupported supervisor backends
are refused at daemon startup; tmux remains the default.
