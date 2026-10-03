# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`config/` holds local gitignored operating choices, including explicit extension bindings under `config/extensions.d/`, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.

`bin/fm-spawn.sh` owns local-agent task metadata, `bin/fm-remote-agent-lib.sh` owns the native remote-agent metadata shape and normalized iDA task state, and `bin/fm-aime-cloud-lib.sh` preserves AIME's proven task-state schema plus the legacy cloud-worker metadata path.
The runtime-backend section below owns local backend-specific fields and selector interpretation.
The producing PR and Relay helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-task-state.sh` owns provider-aware current-state reconciliation while delegating local tasks unchanged to `bin/fm-crew-state.sh`.
Wake, watcher, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/fm-startup-network.sh`'s header owns the deferred startup stage that keeps every external-network call and the potentially slow inactive-outcome scan off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.

## Headless short tasks

`FM_SHORT_AGENT_ENABLED=1` enables the Pi-primary short-task tools; [the current-use guide](short-agents.md) owns setup, examples, provider-limit distinctions, and recovery.
`state/short-agents/` holds their runner-owned records, whose lifecycle format is owned by `bin/fm-short-agent.mjs` and operation grants/receipts by `bin/fm-short-operations.mjs`.

## Feishu current-Pi channel

The optional `config/feishu.env` file is local, gitignored, and parsed strictly as data by [`bin/fm-feishu-config.mjs`](../bin/fm-feishu-config.mjs).
It is absent by default.
The only accepted fields are `FM_FEISHU_ENABLED`, `FM_FEISHU_APP_ID`, `FM_FEISHU_APP_SECRET`, `FM_FEISHU_CAPTAIN_OPEN_ID`, and `FM_FEISHU_P2P_CHAT_ID`.
Each non-comment line is one unquoted `KEY=value` with no whitespace, duplicate key, expansion, command, continuation, or unsupported field.
Comments start with `#` in column one, and blank lines are accepted.
`FM_FEISHU_ENABLED` is exactly `true` or `false`.
When enabled, all four identity and credential fields are required.
When disabled, those four fields are optional but any present value is still validated.
The App ID must be a `cli_` identifier, the captain identity must be an `ou_` open ID, and the chat identity must be an `oc_` chat ID.
The file must be one current-user-owned, single-linked regular file with exact mode `0600` beneath a current-user-owned, non-symlinked config directory that is not writable by group or others.
Missing or disabled configuration starts no transport and creates no Feishu state in a fresh home.
An explicit disable converges any previously active local channel to stopped and disabled state.
Malformed content, unsafe ownership, unsafe permissions, another file type, a symlink, a hardlink, an unsupported field, or a missing required value refuses activation before credential use or binding mutation.

[`docs/feishu-channel.md`](feishu-channel.md) is the single operator owner for app setup, activation, local controls, supported limits, transport operation, safety, health, and recovery.
[`bin/fm-feishu-state.mjs`](../bin/fm-feishu-state.mjs) owns the exact private child schemas and mutation mechanics.

## Remote research agents

Firstmate supports exactly two native remote research providers: AIME and iDA.
New work must select `remote-agent/aime` or `remote-agent/ida` explicitly through `bin/fm-task-dispatch.sh`; no config, capability probe, or heuristic silently chooses one.
Both providers are optional, disabled by default, and operate above local harness and runtime-backend semantics.
They create no local worker endpoint or worktree and retain the ordinary task, backlog, report, decision, supervision, and notification lifecycle.

New native metadata records `kind=scout`, `executor=remote-agent`, `provider=aime|ida`, and `task_type=research|document` without local endpoint fields.
iDA records `remote_state=...`; `bin/fm-remote-agent-lib.sh` owns that metadata/state shape and the `fm-remote-agent-task-state.v1` normalized phases.
New AIME records retain `cloud_state=...` and the proven `fm-aime-task-state.v1` lifecycle while recording `executor=remote-agent`.
Provider adapters own provider commands and normalized observations.
Existing AIME records with `executor=cloud-worker`, `provider=aime`, `cloud_state=...`, and `fm-aime-task-state.v1` are a permanent read-compatibility path.
They are not migrated or rewritten and remain readable, adoptable, cancellable, reportable, and retireable through their original lifecycle.
The [`cloud-research-worker` skill](../.agents/skills/cloud-research-worker/SKILL.md) owns the conditional operator procedure for both providers, including the semantic-acceptance check that keeps provider-terminal state distinct from completion of the research goal.

<a id="aime-cloud-research-worker-configaime-cloud-worker"></a>

### AIME (config/aime-cloud-worker)

The AIME cloud research executor is optional and disabled by default.
An absent, malformed, unsafe, version-mismatched, or explicitly disabled `config/aime-cloud-worker` leaves ordinary local task routing unchanged and refuses new AIME dispatch before any cloud write.
It is a native remote task executor, not a harness or backend.

`bin/fm-cloud-research-aime.sh sandbox-verify` is the only supported config writer.
Its `--help` output owns the exact authorization flag, site and space arguments, config fields, and current schema.
The command is intentionally mutating and must be run only after an operator explicitly authorizes one disposable AIME session.
It performs the read-only site and space checks first, creates one disposable empty session, reads that same session back, and records the exact installed `bytedcli` version with `enabled=false`.
Ordinary tests, lint, documentation checks, native review, and CI must never run this mutating verification.

Enabling is a separate local operator action after the disposable-session verification succeeds.
Change only the generated `enabled=false` line to `enabled=true`, retain mode `0600`, and do not edit the verified site, space, identity, version, timestamp, or verification fields by hand.
The dispatch path repeats read-only authentication and capability checks and refuses if the current `bytedcli` version differs from the sandbox-verified version.
The config contains no token or credential.
Authentication remains in bytedcli-managed user identity state for the explicit configured site, and Firstmate never reads or prints its value.

Before dispatch, create the ordinary private task directory and `brief.md`, then place the exact instruction in a non-symlinked `0600` or `0400` file beneath `data/<id>/`.
The instruction file is passed through `bytedcli --content-file`; prompt bytes never enter argv, task metadata, status events, tracked files, or reports.
The maximum instruction size defaults to 262144 bytes and is controlled by `FM_AIME_MAX_INSTRUCTION_BYTES`.
The [`cloud-research-worker` skill](../.agents/skills/cloud-research-worker/SKILL.md) owns the intake, document-result, wake, adoption, cancellation, and retirement procedure.

A new AIME task records the native discriminator in `state/<id>.meta`: `kind=scout`, `executor=remote-agent`, `provider=aime`, the research or document task type, and the private AIME state directory.
The legacy `cloud-worker/aime` selector remains available only for read-compatible operation and fixtures that require the old discriminator.
It never fakes `window`, `worktree`, `harness`, `backend`, or local endpoint fields.
Private AIME state and provider artifacts live beneath mode-restricted `state/cloud-tasks/<id>/`.
`bin/fm-aime-cloud-lib.sh` owns their exact schemas, phases, atomic transition rules, file modes, and allowed error classifications.
`bin/fm-procevent-aime.sh` owns authoritative event replay, session and output readback, durable cursor advancement, duplicate handling, report generation, and re-arming through the existing process-event runner.
Replay, session, and output readback failures remain adoptable and re-armed unless one identity-bound observation proves provider status `stopped`, authoritative terminal replay, and unavailable bounded output readback.
That exact combination becomes the explicit `provider-stopped-output-unavailable` terminal failure without claiming recovered output, successful research, a computed result, or provider cancellation.
The adapter establishes or preserves the private failure report, stops the canonical source, then uses a bounded task/source generation scan to quarantine each selected captured result before exact acknowledgement and queued-wake removal.
Identity, adapter, file-safety, size, contradictory-result, and scan-bound mismatches refuse that seal.

Restart adoption uses the recorded session identity and never creates or sends again after submission.
Create or send acceptance that cannot be proven remains an explicit blocker and is never retried automatically.
Disabling or removing the config blocks new dispatch but does not erase an already-recorded cloud task.
Existing submitted work remains adoptable and readable from its durable state even while new dispatch is disabled.

Rollback is therefore two steps.
First set `enabled=false`, or remove `config/aime-cloud-worker`, to stop new cloud dispatch immediately while leaving local routing unchanged.
Then reconcile every existing cloud task to a terminal report, or interrupt only its local waiter while recording that the AIME session may still continue.
Do not delete a nonterminal cloud record, claim cancellation, or create a replacement session.
Terminal tasks retire through `bin/fm-task-retire.sh` only after task state binds a private single-link report and the ordinary captain-hold completion gate passes.
A previously recorded `result-unavailable` task can cross that boundary only through the adapter's idempotent stopped terminal-unavailable preparation using its preserved authoritative observation or one bounded fresh readback and an already existing safe report.
Retirement preserves the report and private quarantined capture evidence while removing volatile cloud state.
The shared retirement procedure in [`cloud-research-worker`](../.agents/skills/cloud-research-worker/SKILL.md#retirement) owns backlog consistency and retry handling for that removal.

Document mode does not activate the local Feishu document integration.
AIME creates the requested document and returns its canonical URL, identity, and revision.
Firstmate validates and records that artifact but performs no local create, copy, rewrite, permission, or sharing operation.

Current active evidence, including the pinned CLI version and the non-mutating verification commands, is in [`verification/aime-cloud-worker.md`](verification/aime-cloud-worker.md).

### iDA (config/ida-remote-agent)

iDA uses the official SG-capable iDA Deep Research and session lifecycle exposed by installed `bytedcli`.
An absent, malformed, or explicitly disabled config refuses new iDA dispatch before any provider write and leaves local-agent and AIME routing unchanged.
The config is a current-user-owned, single-link regular file at mode `0600` with this schema:

```text
schema=fm-ida-remote-agent-config.v1
enabled=false
region=sg
identity=user
agent_id=default
```

Use `default` to let iDA select its established Deep Research agent.
An existing config may retain one legacy `model=default|<name>` field, but that field is validated only for compatibility and never selects the model for a new dispatch.
Select a model only for one new iDA task with `bin/fm-task-dispatch.sh remote-agent/ida <id> --instructions <private-file> --model <name>`, where `<name>` exactly matches the current SG `bytedcli --json --as user ida --region sg model list` output.
For example, `bin/fm-task-dispatch.sh remote-agent/ida market-review --instructions data/market-review/instructions.txt --model usecase-frontend-deepseek-v4-pro` keeps the private instruction body out of argv while selecting that model for this task only.
Omitting `--model` performs no model-catalog lookup, adds no model to the official create request, and leaves selection to the current iDA provider default.
Empty, malformed, duplicate, unsupported-position, unavailable-catalog, unsupported, or provider-incompatible model selections fail before task-state publication or provider creation, and the option is rejected on AIME selectors.
The private normalized iDA task record retains the explicit selection across submission, adoption, recovery, inspection, and result readback; legacy records with no model field remain readable.
The adapter preserves the recorded agent and explicit model identity when the official response provides no stronger identity.
An existing config may retain one legacy `bytedcli_version` field, but it is informational only: absence, staleness, or mismatch never blocks probe, dispatch, adoption, reconciliation, process-event handling, cancellation, or retirement.
New setup must omit it and does not pin or refresh a bytedcli version.
The config contains no credential, token, OECID, or prompt; authentication remains in bytedcli-managed `user` identity state.
Set `enabled=true` only after a read-only `bin/fm-remote-agent-ida.sh probe` succeeds against the config.
The probe verifies the executable, SG Deep Research agent and raw-session-list reads with `identity=user`, and the domain-restricted MCP command listing for the required create, model-selection, raw-list, get, and close commands and options; it creates no session.

Before dispatch, create the ordinary private task directory and `brief.md`, then put the instruction in a non-symlinked `0600` or `0400` file below `data/<id>/`.
The default instruction bound is 262144 bytes (`FM_REMOTE_MAX_INSTRUCTION_BYTES`).
Submission uses the official domain-restricted `bytedcli --as user mcp --allow-domains ida` server and its `run_command` tool to invoke `ida --region sg deep-research create`.
`bin/fm-bytedcli-mcp-call.sh` constructs that command inside a mode-`0600` stdin request so prompt bytes do not enter operating-system argv.
Raw session list, session get, and cancellation use official `bytedcli --json --as user ida --region sg ...` commands.
Every iDA-owned bytedcli child resolves the executable from the current `PATH` or the standard user-global npm launcher at `$HOME/.npm-global/bin/bytedcli`, then unsets conventional upper- and lower-case proxy variables because ambient proxies can divert the SG identity endpoint through an incompatible route; this lookup and sanitation are child-local and preserve all unrelated operator environment.
Firstmate stores only normalized bounded observations, not the MCP exchange, raw messages, SSE/event bodies, credentials, or private request payload.

Before the sole allowed create, the adapter records a unique marker derived from the Firstmate task id and instruction digest.
It places that marker in the private first message because SG may automatically rename a session despite the create command's `--name`, then exact-matches either the legacy session name or that bounded first-message marker through raw session list plus session get.
It repeats that reconciliation after a timeout or ambiguous submission before deciding state.
A unique match is adopted; multiple matches, a truncated listing, provider unavailability, or unresolved identity becomes a preserved unavailable or ambiguous state and never authorizes a silent duplicate create.
Restart adoption and startup recovery use the durable marker and session id and re-arm the existing process-event source without pretending a local endpoint exists.
An incomplete task after an iDA terminal report continues from the original task's compact gap through the provider adapter's same-session followup described in [goal-directed continuation](task-continuation.md); `bin/fm-remote-agent-ida.sh --help` owns the exact invocation.
That path never authorizes a fresh research session or provider switch, and unavailable or uncorrelatable provider support remains an explicit goal gap.

`bin/fm-procevent-ida.sh` owns first submission, session readback, normalized state transitions, report creation, acknowledgement, and re-arming.
Provider-running or idle-but-processing state is healthy.
After the first nonterminal transient read failure is durably captured, published, and applied, the iDA source keeps only semantically identical retries inside the same waiter and polls with bounded exponential backoff.
Recognized provider rate limits, timeouts, and unavailability remain on that transient retry path.
Local CLI execution failures, empty or malformed JSON, invalid response structure, and session-identity mismatch instead stop only the current waiter, expose `state: blocked` plus an `ida-readback-local` blocker, preserve the exact remote task binding and nonterminal outcome, and retain no raw stdout or stderr.
After repairing local execution or response validation, run `bin/fm-remote-agent-ida.sh adopt <id>` to read the same task again; the first healthy task-bound observation clears the blocker, while another provider-transient response or a response missing the bound task does not.
The comparison binds task and provider identity, normalized local phase and provider status, result availability, and error class to the state-linked prior observation; a successful or materially changed observation leaves the retry loop immediately and resets the next source to its initial delay.
Terminal results, available answers, cancellation, ambiguous identity, submission uncertainty, authorization or unsupported-operation failures, materially different errors, state transitions, and the first actionable failure are never coalesced.
Suppressed attempts create no new captured generation, task artifact, notification, or event log, while every generation captured before the suppression boundary and every already queued notification remains intact and generation-keyed.
Terminal success, failure, and provider-confirmed cancellation produce a mode-`0600` `data/<id>/report.md` bound by task state.
The report preserves `available`, exact `zero`, `unavailable`, and `error` distinctions and includes normalized session, remote-task, agent, model, outcome, result kind, and error-class fields when available.
Legacy visible type-8 text remains a `text` result.
Textual `deep_research_content.finalAnswer` content - a non-empty string or an array carrying answer-bearing text - is redacted and recovered as a `text` result for the recorded task before its structured artifact classification is consulted.
When a successful recorded task has no `finalAnswer`, the last non-empty completed step content in its task-bound visible type-8 message is also a `text` result.
A supported non-empty `deep_research_content.finalAnswer` artifact becomes an `artifact` result whose private mode-`0600` boundary retains only a safe session-readback reference with artifact and supported-part counts.
When artifact selection is actually needed, `bin/fm-remote-agent-ida.sh artifacts <task-id>` performs the official artifact-list read against the exact session and remote-task IDs already recorded for that Firstmate task.
Before stdout, it projects the response to task/session identity, state revision, availability/truncation, artifact ID/name/type, table/text presence, and file name/MIME/URI/size.
It rejects mismatched or malformed identity and never emits descriptions, tables, rows, text, scripts, embedded bodies, or raw provider errors; selected content remains an explicit later fetch.
Malformed or unsupported structured results remain explicit errors, and artifact identifiers, names, file URIs, inline data, provider messages, and raw session JSON never enter the normalized result, report, status, log, or metadata boundary.
If an existing durable iDA task contains `bytedcli_version`, a report may label it as legacy informational metadata; the value never participates in state validity or a lifecycle decision.
It never embeds the prompt, credentials, raw provider streams, or private payloads.
iDA document mode does not imply AIME's Feishu creation contract; the durable return remains the self-contained report or its authoritative provider identity.

`interrupt-wait` stops only local waiting and may leave the provider session running.
Provider cancellation uses official `chat completion close`, requires current destructive-action authority plus `--authorize-provider-cancel`, and does not become terminal until session readback confirms a cancelled/closed state.
After that confirmation, the command retires only the older local waiter before routing a fresh normalized terminal observation through durable capture, publication, and automatic application.
An ambiguous or submission-unknown task whose marker yields an authoritative complete non-truncated zero-match session list can leave its permanent blocked state only through the explicit `abandon` command with `--authorize-abandon`; abandonment fail-terminals the durable record, performs no provider write, never retries or recreates, and any future execution requires a separate explicit dispatch.
Retirement requires normalized terminal state, a safe bound report, retired process-event supervision, and the ordinary captain-hold completion gate.
Disabling the config blocks new submission but does not erase, cancel, or make an existing record unreadable.
Current behavioral evidence is in [`verification/remote-agents.md`](verification/remote-agents.md).

## Pi Calm preference (config/calm)

The Pi Calm extension stores the captain's home-local presentation choice in gitignored `config/calm` under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
`max` is the legacy value written by a removed third presentation level whose behavior is now ordinary Calm, and it is still read as `on`, so a home upgraded from it keeps Calm on rather than dropping to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.

## Pi supervision branch

On a Pi primary, an in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews while keeping main-only rows on the captain-facing path; [docs/pi-supervision-branch.md](pi-supervision-branch.md) owns its conversation lifecycle, row eligibility, mixed-queue dispatch, heartbeat routing, and pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.
A genuinely no-op heartbeat is absorbed in bash and never reaches Pi, and every watcher-failure alarm stays on the captain-facing main path.
A broken branch falls back to today's wake-to-main path.
The branch's role stays bounded exactly as the captain-approved architecture set it: it cannot merge a PR, land local work, or freshly spawn, and every existing captain gate remains unchanged.
Homes on any other primary harness never load this feature and are entirely unaffected.
`AGENTS.md`'s `state/` inventory routes the branch's runtime files to their format and lifecycle owners.
The [Pi supervision branch contract](pi-supervision-branch.md#two-stage-noise-filter) owns captain-outcome persistence, identity-only processing retries, exact durable-store loading, and the acknowledgement prerequisite.
The branch prompt's "Verdict: routine or captain" section owns the distinction between captain-facing, unsolicited routine, and unchanged-review outcomes.
The generated [Pi supervision protocol](supervision-protocols/pi.md) owns main's event ownership, acknowledgement duty, and conversational treatment for merged outcomes, while the persisted entry itself owns captain visibility.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome still appends a rendered, sailboat-prefixed note.

### Historical routine continuation policy (config/task-continuation-policy.json)

Current ordinary continuation does not require or consult `config/task-continuation-policy.json`.
MAIN records material progress in the existing backlog task, while the branch remains unable to author that progress or final acceptance.
An old policy file and rich `data/<task>/lifecycle.json` records may remain on disk unchanged, but neither is an active progress source and neither enrolls old work.
Only the merge or cleanup operation owner may narrowly read an immutable historical receipt or terminal/archive fact needed for an already attempted or uncertain effect.
Existing wake, lease, inbox, handoff, provider, merge and cleanup owners continue to enforce their own authority and receipts.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

Supervision is an easier job than the captain's own conversation, so the branch can run on a cheaper model than main.
It is also an easier job than the captain's own conversation needs reasoning for, so the branch can run at a shallower effort than main as well.
The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.
The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.
Both picks change the supervision branch alone and never the captain's own conversation model or effort.
It persists the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`, both under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
Firstmate keeps no model catalog of its own; the list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.
A provider that exists only because an extension registered it inside the captain's session, such as pi-devin-auth's `devin`, is offered and can be pinned or followed like any other; [pi-supervision-branch.md](pi-supervision-branch.md#cost-model-and-the-byte-stable-prefix) owns how that registration reaches the isolated branch runtime.
Stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.
The file holds one `<provider>/<model-id>` line followed by one newline, split at the first `/` so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin, and the branch then follows main's own current model, applied explicitly and live whenever main changes models mid-session.
When main uses `codex-native`, following main explicitly selects the same model through ordinary Pi's `openai-codex` provider, so the background branch owns an independent Pi conversation.
If that ordinary Pi model is unavailable, the branch refuses to build and returns the notification to main; it never inherits the main native thread or silently selects a different model.
Picking "Follow main" under a `codex-native` main reports that same `openai-codex` model, or that same refusal, because the command and the branch build share one follow rule.
A `codex-native` branch pin is refused and excluded from the picker.
A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.
The file's current state decides the branch model on every branch build - the new conversation each main session start opens and the reopen after a model or effort change inside one session - and it overrides Pi's restore of whatever model a reopened branch session recorded, so the choice survives all of them.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.
For ordinary Pi providers, only when main's own model is unknown, or this home's stored credentials cannot run it in the isolated branch runtime, does an unpinned build fall back to passing no override at all, which is the behavior from before this file existed; the wake is never lost over model choice, and the command says plainly when main's model could not be applied instead of reporting a change that did not take effect.
A pin naming a model Pi cannot hand back, because the model is unknown or has no configured credentials, is never silently downgraded onto main's model: the branch refuses to build and rejects the accepted wake to the watcher's captain-facing main path, exactly as any other unreachable branch does.
Picking also releases the live branch so the next wake reopens this session's own branch conversation under the new model without waiting for a session replacement.

The effort file holds one Pi thinking level followed by one newline, and the two pins are independent: a captain may pin a model, an effort, both, or neither.
The effort step runs after the model step because the effective branch model decides which levels exist: its menu is Pi's own supported-level list, so a model that maps no extended levels simply does not offer them and a non-reasoning model offers only `off`.
The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the most recent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.
An absent, unreadable, or unrecognized file means no effort pin, and the branch then follows main's own current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.
Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.
Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.
Pi owns the clamp, so a pinned level the branch's model cannot run becomes that model's nearest supported level rather than a refusal; the branch is never refused over effort, the captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will really run at rather than the raw pin.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick made in the same run, and the command's one closing message reports both choices as they will actually take effect.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
A home may instead select another tasks-axi adapter such as Beads through its own `.tasks.toml` or `TASKS_AXI_BACKEND`; firstmate still uses only tasks-axi verbs for routine backlog reads and mutations, and the adapter maps `start` and evidence-bearing `done` transitions to its native statuses and evidence fields.
When the automatic transition gate applies, dispatch and completion are not separate operator actions: each moves its work item inside the same run that creates or removes the task's record, so the ordinary successful path cannot leave the backlog and live task set out of sync ([`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh)).
Under that gate, dispatch accepts only an unheld, unblocked Queued or In flight item in this home; a missing, Done, held, or dependency-blocked item is refused before any endpoint or local copy is created.
Completion refuses to report success until the item is closed, and session start reconciles this home's own books after an interrupted run.
A semantically accepted or explicitly archived task may retain cleanup-only metadata after its backlog row closes; [goal-directed continuation](task-continuation.md#acceptance-archive-and-cleanup) keeps that resource obligation separate from execution supervision.
Because tasks-axi reserves its structured pull-request field for GitHub-style `/pull/<number>` URLs, automatic completion preserves an exact `https://code.byted.org/<namespace>/<repo>/merge_requests/<n>` URL as a `Codebase MR ...` completion note; interrupted cleanup replays the conversion, while a row no longer addressable after archival leaves its close receipt pending rather than discarding the URL.
When a spawn is interrupted after launch delivery began, its exit path re-reads the paired task record and the backlog row under the same per-task lock as the commit, repairs a row the commit believed it had moved, and reports only what was verified or honestly attempted, never intent phrased as outcome ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh); [`tests/fm-backlog-atomicity.test.sh`](../tests/fm-backlog-atomicity.test.sh)).
Automatic transitions run from the configured data directory's parent, letting that home's effective tasks-axi configuration address its selected adapter while keeping relative scout-report links rooted there.
A markdown backlog is additionally addressed by an explicit `--file` at `<data>/backlog.md`, so the change lands in the home that owns the task regardless of the caller's working directory.
Any other configured adapter is addressed by that root alone, because `--file` would override the adapter's own workspace path.
Migrated-hold resolution on a beads home reads its graph path, binary, and prefix from the root `.tasks.toml` `[beads]` section only, and refuses (rc=2) when the beads backend is selected elsewhere (a `TASKS_AXI_BACKEND` override or user-level config) with no root-level `[beads]` section.
On an automatic-backend home, missing or incompatible `tasks-axi`, an unresolvable configured data directory, or one containing a control byte fails lifecycle work before mutation.
An unreadable backend configuration can refuse lifecycle work before the no-backlog exemption applies; repair the configuration named in the diagnostic ([backend resolution contract](../bin/fm-tasks-axi-lib.sh)).
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared capability probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
A `manual` home owns its backlog file outright: the lifecycle transitions above are skipped there, dispatch and completion never fail over the file's contents, and a completed teardown prints the hand edit that is owed instead.
Absent or `tasks-axi` selects the tasks-axi path.
On the default markdown adapter, tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

The tracked `.tasks.toml` paths resolve against the directory tasks-axi runs in, not `FM_HOME`, so a bare `tasks-axi` run from the code root addresses the code root's `data/` whenever the home lives elsewhere.
tasks-axi writes by renaming a temp file over its target, which replaces a symlink with a regular file, so linking the code-root copy into the home forks the queue on the first such write rather than keeping the two in step.
Every routine firstmate backlog command therefore runs through [`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh), which addresses this home's backlog and archive from any working directory exactly as lifecycle transitions do, and bootstrap reports a code-root `data/backlog.md` or `data/done-archive.md` that is not this home's own file as a `BACKLOG_RECONCILE: code-root ...` line even in a read-only session.

## Runtime backend (config/backend / FM_BACKEND)

Herdr is the sole supported terminal backend; Pi, Codex and TraeX remain the worker tools with their existing role limits.
Treehouse remains the task worktree provider.
New spawns choose an explicitly authorized `--backend` value, then `FM_BACKEND`, then the first non-empty line of `config/backend`, then `herdr`.
Every explicit value except `herdr` refuses; an obsolete setting is never silently coerced.
A missing or incompatible Herdr installation is a dispatch blocker, with no fallback to another terminal.

New task records always include `backend=herdr`, `endpoint_task_id=`, `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=` and `herdr_pane_id=`.
Historical records without `backend=` still mean tmux; explicit tmux, cmux, Zellij and Orca records retain their original identity.
Their state is unsupported, and peek, control, relaunch and teardown refuse without endpoint operations or deletion of their recorded copies.
No update automatically migrates these records, converts an Orca-owned copy to Treehouse, or changes an active home's configuration.
Preserve private history and obtain a specific migration decision if an old unfinished obligation needs action.

Task selectors resolve an exact task id before the historical `fm-<id>` label alias, then an exact recorded endpoint.
Recorded targets retain the recorded backend, including retired identities.
An explicit unrecorded Herdr target must name its session and pane; a bare legacy window name is not searched in a live terminal inventory.
`bin/fm-backend.sh` owns endpoint identity validation, and cleanup refuses missing, duplicate, inconsistent or task-mismatched records.

[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional local, gitignored `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it present, every referenced task must independently show positive work evidence, and an eligible bare turn-ended task that lacks authoritative proof may satisfy that requirement when its pane content changed since the previous poll.
It stays opt-in because the other two proofs read a verdict the harness itself vouches for while this one infers execution from rendered bytes; with the flag absent triage behaves exactly as it did before.
`FM_TURNEND_CHURN_ABSORB_SECS` is a positive integer number of seconds, defaults to `900`, and bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway.
An invalid value fails closed and surfaces the wake.
The bound is required rather than cosmetic because churn and pane staleness read the same pane.
[`architecture.md`](architecture.md) owns the triage contract and `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed boundaries.

## Captain Preferences (data/captain.md)

Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.
There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
The file must contain one positive base-10 integer in a regular, single-linked file beneath a non-symlinked `config/` directory.
Surrounding ASCII whitespace, CRLF line endings, a missing final newline, and leading zeros are normalized on read without rewriting the file; multiple values and embedded control bytes are rejected.
Symlinked, hardlinked, special, or otherwise unsafe files are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
The helper's header owns exact parsing, publication, and report output mechanics.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.
With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.
The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Heartbeat maintenance (config/periodic-stow.json)

`config/periodic-stow.json` retains its compatible filename and is an optional per-home opt-in for heartbeat maintenance in the Pi main-session coordinator in `.pi/extensions/fm-periodic-stow.ts`; absence means disabled.
The complete version 1 object has exactly `version`, `enabled`, `interval_seconds`, and `min_interval_seconds`, with integer intervals of at least 3600 seconds and `interval_seconds >= min_interval_seconds`.
The recommended initial values are an 86400-second check interval and a 14400-second minimum between successful automatic full passes, but tracked code installs no enabled configuration and choosing the home and frequency remains an explicit operator action.
The first due point is the enable-file modification time plus the configured interval; a successful full pass schedules from its completion, a verified no-op schedules from that check, and offline time produces at most one request rather than catch-up runs.
Unknown fields or versions, malformed JSON, symlinks, unsafe interval values, clock rollback, legacy or pass-horizon conflicts, and corrupt coordinator state disable automatic progress with a concrete diagnostic instead of falling back.
Setting `enabled` to false stops new automatic maintenance requests and withdraws an unconsumed automatic-only request, while manual, partial, blocked, plan, and receipt evidence remains available for recovery.
Automatic passes now account for task archival, unfinished-task continuation, and knowledge curation in one heartbeat run, replacing periodic stow while leaving manual `/stow` and pre-compaction invocation intact.
The existing coordinator timer also emits bounded live-task continuation checks while full maintenance is disabled; it creates no second timer or daemon.
Busy tools, queued input, compaction, and editor input defer the maintenance offer; unchanged duties remain silent and repeated ticks share the same run id.
After three offers without a verified finish, the coordinator retains the run and starts main-session recovery with persistent pacing and delivery deduplication owned by `bin/fm-stow-run.sh`.
A handling turn that performs no operation leaves the obligation pending for a later safe tick; original offer counts never reset, and delivery alone cannot complete a duty.
The heartbeat receipt requires separately bound evidence for all three duties, as specified by `bin/fm-heartbeat-receipt.py`; an incomplete duty retains the run.
`state/stow/state.json` is the single coordinator-state owner and `data/stow-runs/<run_id>/` holds non-injected plans and receipts; `bin/fm-stow-run.sh --help` owns their mutation interface, and the internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns all knowledge, decay, budget, open-record, and cascade semantics.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh` or `fm-spawn.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves accepted absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
`fm-spawn.sh` additionally rejects control bytes in those raw directory inputs before shell or filesystem normalization can change which path the backlog gate checks.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured data or state root, and a final-component symlink is refused even when its target remains within that root.
Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.

## Harness support

Firstmate supports exactly `pi`, `codex`, and `traex` as harness selections.
Unsupported configuration refuses launch with a diagnostic naming the supported choices; it never silently substitutes a harness.
Historical task records remain readable, while recovery and teardown refuse removed harness identities to preserve their work.
`pi-signed` is a retired selection; authentication wrappers underneath the installed `pi` executable remain shared Pi functionality.
Model providers, runtime backends, and remote executors are separate from this harness boundary.

The [harness-adapters skill](../.agents/skills/harness-adapters/SKILL.md) routes operating facts and role restrictions.
[`fm-spawn.sh`](../bin/fm-spawn.sh) owns launch validation, and [`agent control`](agent-control.md) owns lifecycle semantics.
Pi's tracked extensions and Codex's foreground checkpoints follow their respective [supervision protocols](supervision-protocols/).

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.

## Worker launch environment (config/launch-env-allowlist)

With no file, launch behavior is unchanged: selected harness markers are cleared, while the provider, long-lived terminal daemon, and shell initialization determine which other variables reach the worker.
Do not assume every worker inherits the invoking Firstmate process's current environment.
Changes apply to subsequent launches; existing processes keep their environment.

Create the file with one environment variable **name** per line, never credential values, assignments, wildcards, or shell commands.
Blank lines and lines beginning with `#` are allowed.
Invalid names, an unreadable or nonregular file, or a path inspection error (including an inaccessible configuration directory) stop the launch.
An empty file enables filtering with only Firstmate's operational floor.
For example, a provider using `OPENAI_API_KEY` and Git using an SSH agent could use:

```text
# Provider credential already available in the destination pane
OPENAI_API_KEY
# Git over SSH using an existing agent
SSH_AUTH_SOCK
```

Firstmate retains basic home, executable search, terminal, locale, temporary-directory, and backend routing variables, plus its explicit launch assignments, its ship and scout task marker, and enabled task trace.
[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact retained names and parsing mechanics.
Other ambient names must be listed explicitly, including custom credential-store locations, proxy settings, and certificate overrides when required by the selected tools.
The command shell and worker may still create their own variables.
Allowed values come from the destination pane at execution time; they are neither copied from the invoking Firstmate process nor written into the launch command.
Listing a name does not provision it in a daemon's environment or transfer credentials to another machine.

Choose the minimum additions for the authentication method actually in use:

| Provider or Git transport | Additional names needed |
| --- | --- |
| Provider login stored under the normal home directory | None for the environment contract; the same user still has access to that provider's stored login. |
| Provider configured through environment variables | The exact credential and endpoint names required by that provider, for example `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`; a multi-provider tool needs each provider it will actually use. |
| Custom provider store | Its configured location variables, such as `CODEX_HOME`, `PI_CODING_AGENT_DIR`, or `XDG_CONFIG_HOME`. |
| Git over SSH with an agent | `SSH_AUTH_SOCK`; add `GIT_SSH_COMMAND` only if the chosen transport requires that override. |
| Git over SSH with a key file | No credential variable when normal SSH configuration selects the key; file permissions and any passphrase handling still apply. |
| Git over HTTPS with a credential helper | Whatever the configured helper requires; a GitHub CLI helper using an environment token needs its selected `GH_TOKEN` or `GITHUB_TOKEN`. |

Verify the selected provider login and Git transport after opting in; Firstmate does not infer credentials from model names or install a secret manager.
Raw launch commands run under noninteractive POSIX `sh` with this option and must use compatible syntax.
The filter runs at the worker command boundary, after the terminal daemon and pane shell have started; it does not scrub either of those processes.
This is not a sandbox: it cannot revoke same-user access to credential files, prevent tools or later shells from loading credentials again, or isolate processes from the same user's other processes.
Regression coverage executes emitted launch commands with synthetic nonsecret values in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).


## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `profile-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `profile-array-dispatch` owns task-fit filtering, configured-order selection, and candidate verification.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" },
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max|ultra, optional>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
`ultra` is native-only: the model-aware validation contract and launch mapping are owned by `bin/fm-harness.sh validate-native-effort` and `bin/fm-spawn.sh` respectively.
Codex `max` is valid when the profile selects `gpt-5.6-luna`, whose installed catalog entry supports that reasoning level.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an ordered preference list resolved through `profile-array-dispatch`.
Firstmate first filters by required task fit and reasoning class, verifies model support, provider authentication, effort compatibility, and runtime compatibility, then selects the first eligible profile in written order.
Missing evidence is never treated as capacity, and a provider refusal after selection is reported instead of silently switching to another profile.
The removed `preferWhileLoadBelowPercent` field and `select: "quota-balanced"` mode are invalid; order profiles by preference and use `select: "ordered"` only when an explicit selector label is desired.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
Except for `ultra`, which refuses unsupported profiles under the native-effort contract above, an effort value the chosen harness does not accept is recorded as `effort=` in task meta for traceability but omitted from the launch flags.
Bootstrap reports unsupported harness/model/effort combinations as a `CREW_DISPATCH` diagnostic when they are visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, an effort value unsupported by that harness, or a removed selection field is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The essential universal toolchain is node, git, gh with GitHub auth via `gh auth login`, gh-axi, chrome-devtools-axi, compatible tasks-axi per "Backlog backend" above, Python 3.9 or newer, and jq.
Python and jq validate compact task progress and bounded operation receipts; no additional Python packages are required.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) checks gh-axi presence and genuine API prerequisites; each gh-axi operation follows its installed help and verifies its result, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) owns the backlog capability probe.
The gh-axi and tasks-axi release labels do not gate compatibility.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, gh-axi and chrome-devtools-axi cover GitHub and browser operations, and tasks-axi backs backlog mutations.
The Herdr terminal requires `herdr`, `jq` and the `treehouse` worktree provider in addition to the universal toolchain.
`fm_backend_required_tools` in `bin/fm-backend.sh` owns that dependency list.
A retired or unknown configured backend emits `BACKEND_INVALID` and blocks dispatch.
Bootstrap never installs or switches a terminal automatically.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.
The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs, updates, fetches, or changes `PATH`, a version manager, or any installed tool.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

Each entry needs a `name` and at least one of `command` or `git`; an entry may carry both.
A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reports the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
A tool does not always announce a new release on the command that prints its version.
`announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.
Both probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
See [`docs/examples/watched-tools.json`](examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.
That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
Registering the check is itself a reason to watch, so the home keeps a watcher for it after the last task is torn down, and `disarm` is what ends that need.
`bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.
The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
A changed or returning condition is reported again.
Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.

`FM_TOOL_UPDATE_INTERVAL` (default 900 seconds, `0` to probe on every run) sets how often probes actually run, `FM_TOOL_UPDATE_PROBE_SECS` (default 5) bounds one probe, and `FM_TOOL_UPDATE_BUDGET_SECS` (default 20) bounds a whole sweep.
A sweep that runs out of budget says which tool it did not reach rather than reporting the rest as current.
The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills prints nothing and records nothing and would then repeat that silence on every poll.
So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
A budget that is not a whole number from 1 to 120 is still refused outright.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.
Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.
3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay instance polls every 30 seconds instead of the default 300, only a Relay instance speeds up because a non-Relay home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
Preserved legacy mode records do not alter Relay cadence or start another watcher; the ordinary supervision path remains authoritative.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first transcript of the surrounding conversation: entries shaped `{author_handle, text, unavailable, images, attachments}` plus an optional `kind` of `reply` (a reply ancestor), `thread_starter` (the message a thread grew from), or `history` (a recent nearby message), where an absent `kind` means a legacy reply-ancestor or thread-starter entry.
The chain is untrusted third-party public input and is often absent today (the relay currently sends it only for Discord reply chains and thread starters), so consumers treat it as strictly optional, tolerate unknown or missing fields, and read an entry with `unavailable: true` as a gap rather than content; the `fmx-respond` skill owns how firstmate reads it for referent resolution.
The mention and its chain entries may also carry attached media as image or file URLs, in fields such as `images` and `attachments`, either as bare URL strings or as objects with a `url`; a mention whose own media is empty can still have screenshots on its `thread_starter` entry.
The poll preserves those URLs in the stashed object and never downloads them, so nothing is fetched on the polling path: the responding agent retrieves and views the media with its own tools when it handles the mention.
The `fmx-respond` skill owns which hosts that fetch is restricted to and the untrusted-content handling that applies to whatever comes back.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work. When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned entirely by `tasks-axi public-followup`, while the full private conversation context stays only in `state/x-context/`.
Firstmate's bounded registration retains the obligation's public-safe request binding so a delivered loop can be rechained without the original inbox.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop.
Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this home's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded private binding of each open public loop (the record survives delivery, stamped `state=delivered`, and is removed only by `retire`), `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, `retired/` for the mode-0600 reason-and-time receipt written before removal, and `surfaced` for the poll's last-surfaced signature.
The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Bound local work reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; the emitter refuses a home with no registration for the named obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

`bin/fm-public-followup.sh brief` prints the exact local emit command for the bound worker. Cross-machine work-home routing is no longer a public-followup transport; unsupported route or staging arguments refuse rather than inventing a compatibility path.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.
A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.
The session-start digest separately prints a "Public commitments" subsection from disk when, and only when, this home is relay-active and still holds an open public loop (a reply still owed, or a delivered loop with nothing owed), so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind restart recovery, retained-loop disposition, and the relay-disabled zero-overhead guarantee.

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.
[`extension-bindings.md`](extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own exact command mechanics.

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, environment payloads, and Pi packages are never searched for extensions.
When the directory is absent, ordinary process-event commands perform only a bounded absence check, create no package or extension state, and preserve every built-in adapter path.

Binding separates the package's own manifest from this home's explicit enablement.
`bind` validates the source package, computes every digest, copies the complete tree into the read-only content-addressed `data/extensions/packages/` store, performs the live handshake, and atomically publishes the enabled adapter-name subset.
The operator supplies trust and required consent facts, not hashes.
`state/extensions/<extension-id>/` is created when binding performs its initial handshake and is that package's home-local working namespace for later verification and invocation.
`state/extension-invocations/` contains private host-owned exact process-group cleanup records only while an enabled package invocation is starting or running; retirement and reconciliation retain their existing owners until those records prove the group extinct.
This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

Use an absent destination for the copy so the source identity remains inspectable and reproducible.
Use `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>` after the same process-event retirement and handling steps.
Retirement preserves the retired identity reversibly and leaves unrelated bindings and content-addressed installed packages unchanged.

Register one file completion source with a path-safe source id and an explicit non-secret source configuration reference.
Credential values never belong in that reference, command argv, or a process-event result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the new registration's owner token and exact owner-matched retirement command.
The source waits outside the conversational turn, and its completed result arrives through the existing process-event `check` path.
Classify the captured result through its immutable package identity with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with the existing `handled` command only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.
Never run the registered blocking source command directly in a conversational turn.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; built-in adapters retain their tracked `bin/fm-procevent-<adapter>.sh` commands, while an explicitly bound external adapter routes through the trusted host contract above.
`bin/fm-procevent-lavish.sh` is a compatibility-only parser and retirement helper for homes that still contain old Lavish registrations or captures.
It cannot arm or poll a source and does not require `lavish-axi`.
During mutable local bootstrap, `retire-registered` removes each old registration by exact identity so watcher reconciliation cannot repeatedly launch an unavailable command.
Already captured result and adapter records remain intact and eligible for ordinary re-announcement; a pending result's decision binding is retained until `handled` acknowledges the final generation, after which the generic runner removes that obsolete binding.

The `when` adapter (`bin/fm-procevent-when.sh`) turns this channel into a condition->action primitive: it registers a deterministic condition and a deterministic action once, its blocking child polls the condition without waking firstmate, and a stable true fires the action at most once before one terminal outcome is durably captured and published as a wake that remains eligible for re-announcement until handled.
The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs, and that binding is reloaded from disk immediately before each fire rather than trusted from when polling started.
A repo update that fast-forwards an in-repo action's bytes in place would otherwise desync every already-armed watch's trust binding with no tampering involved; `bin/fm-procevent-when.sh rebind-all` re-hashes and republishes the binding for every registered watch whose action lives under `FM_ROOT`, including one already polling, so it keeps firing across such an update instead of being refused on its next fire.
Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.
`bin/fm-procevent.sh` owns the generic contract.

This section is the single owner of the runner's operating contract.
Process-event commands resolve the state root to its physical directory before validating it and deriving paths, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target directory remains refused.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The self-announcing adapter exception and its fail-safe ordering are defined below.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.
Before publishing, the runner asks the immutable captured owner through the built-in `silent` command or external `result.silent` operation and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
For built-ins, silence remains independent of the keyed-answer feed below: suppressing an announcement never suppresses the captain's own answer.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture - and after initial `check` publication for the default ordering - the runner asks the immutable captured owner through the built-in `terminal` command or external `result.terminal` operation and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
Any registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending; replacement becomes eligible only after that generation is proved gone or its terminal retirement completes.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.

Applying a captured result through code is a built-in adapter seam, and some built-in results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the built-in adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
Announcement ordering is adapter-declared through `bin/fm-procevent-<adapter>.sh self-announcing`: an adapter that answers exit 0 declares that every result its autohandle fully applies is announced through a durable downstream channel of its own, so the runner applies first and publishes a `check` wake only for what remains unhandled afterwards; every other adapter keeps the strict publish-before-apply order, and its autohandle runs only when this capture's own wake was successfully appended to the durable queue.

Keyed captain answers from built-in adapters use one more seam of the same kind, and the runner still decides nothing about them.
Some built-in sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.
A built-in source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
The built-in adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future built-in answer source needs nothing here beyond an `answers` command and a binding.
The reserved Reconcile selection uses the parallel optional `reconciles` adapter command and binding-verified `reconcile-requests` intake rather than entering keyed answers; [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md#reconcile-re-check-reality-never-a-blind-close) owns those semantics.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer or request is transcription while acting on it is firstmate's judgement.
An unbound built-in source, a built-in adapter without the corresponding command, and a failure on either side all leave the capture untouched and still announced.
External binding responses never enter either authority-bearing intake.
The AIME adapter also implements it, so each captured observation advances or preserves the provider-aware task state, writes a verified terminal report or re-arms readback, then acknowledges the exact generation; handling the wake through the adapter again is idempotent.
The iDA adapter implements the same applying boundary for normalized observations: it advances the shared remote state, records a safe report or explicit blocker, re-arms only when provider state permits, and acknowledges the exact generation idempotently.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its caller-reported home and runner PID to a process identity, unique claim generation, exact registration-file generation, and resolved state-root identity.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Every stop proves ownership before its first signal: the live runner's recorded process identity must match and it must still lead its process group.
Once that stop has proved ownership and sent TERM, its own escalation to KILL checks only whether the proved group still has members; it does not re-read the leader's identity or group membership, which can change or become unreadable as TERM ends the leader.
This proof belongs only to that stop's own escalation and cannot authorize another caller that encounters an unproved group.
A stale claim whose process group still has members is one `reconcile` never displaces, and the two shapes it comes in recover differently.
`reconcile` preserves such a claim without signalling the ambiguous group or starting a replacement: the group check probes the runner's own process group, which contains its polling source child, so surviving members can mean that child is still attached to the session the source collects from, and a replacement would put a second destructive poller on it.
`list` reports both shapes as `orphaned`.
When the recorded pid is alive under a different identity while the group still has members, the claim boundary itself does not consult the process group, so `bin/fm-procevent.sh start <source-id>` reclaims that claim provided the dead generation's reservation records can still be tidied, and otherwise refuses with `cannot claim source`; that tidy-up is waived only for a generation proven gone, which this one is not.
That hand-run command is the recovery path, taken by someone who has checked that nothing is still polling the source.
That asymmetry between the automatic path and the deliberate one is the design rather than an inconsistency, and it is not a claim-level invariant: nothing below `reconcile` enforces it.
When the leader itself is gone and its group still has members - the leader died to anything other than the stop's own signal - `start` does not reclaim the claim either: it reports `already owned` and changes nothing, and `retire`, `reconcile`, `sweep-home`, and the guard all refuse the surviving group permanently, so the source stops listening.
Recovery there is a human verifying whether the dead runner's polling child is still attached to the source; once that process group is empty the generation reads as gone and the next `reconcile` reclaims the source on its own.
Nothing automatic signals that group, and whether it may ever be signalled remains an open decision; the repaired guard does not close this gap.
Neither shape stops listening quietly: the first `reconcile` that strands a claim generation publishes a durable `check` wake naming the source and what clears it - the `start` command for the reused pid, the check to make for the leaderless group - and later cycles stay silent for that same generation while a genuinely new stranded claim announces again.
Reclaiming a generation that IS gone is not gated on tidying anything that generation left behind: its capture-reservation records, its staging file, or the registry directory a claim recorded for them.
Every one of those is keyed by claim token and every replacement claims a fresh one, so a leftover that can no longer be located or removed - a state-root identity a claim recorded before its home was re-created, or a recorded registry directory that no longer resolves to a directory - is stale bytes rather than an ownership hazard.
Making any of them a precondition is what leaves a provably dead runner owning its source permanently, because none of those conditions clears on its own.
Ordinary release and reclamation still attempt reservation cleanup and require it unless both owner staleness and whole-group absence prove the generation gone.
The narrow live-owner terminal-self-retirement path also attempts cleanup but tolerates its own still-in-flight reservation, which the runner removes on the normal end-of-capture path; exact home, PID, and claim-token ownership remains mandatory before the claim is released.
If identity cannot be established before the first signal, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is refused before the first signal.
Identity and process-group verification cannot be made atomic with signalling in portable shell: the reaper signals only a target it has verified as the recorded generation, but PID and group reuse remain possible in the narrow interval between verification and the signal.
Launch pacing is the primary host-wedge protection; watchdog cleanup is a backstop.

If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims whose recorded state-root identity matches that home's resolved state root through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.
The owning-home lease below bounds how long such an orphan can run, but it is a backstop, not a substitute for the supported path.

A runner is bound to the HOME that owns it, not to the one session that armed it.
That granularity is deliberate: a persistent source is meant to outlive the turn and the session that armed it, so binding a runner to its arming session would stop exactly the sources this mechanism exists to keep running.
Any activity in the same home refreshes the lease, so a replacement session, another watcher, or an ordinary inspection command keeps a runner of that home alive; a runner whose SOURCE is no longer wanted in a live home is stopped by reconcile when that source is retired, independently of the lease.
The lease is therefore the backstop for a home that is GONE - the torn-down test sandbox this change exists to bound - and not a per-session ownership check.
KNOWN LIMIT: while any activity continues in a home whose original owning session has ended, that activity refreshes the lease and a runner of that home keeps running until its source is retired or the home goes away.
Detaching a runner into its own process group is what lets a persistent source outlive the turn that armed it, and on its own it is also what lets a runner outlive its whole home: reparented to init, it keeps its blocking child - and every process that child spawns - running with nothing left to reap it.
So a home's process-event state carries a lease that registration, attached start, reconciliation, acknowledgement, and listing refresh, and the watcher's reconcile cycle is what keeps it fresh in a live home.
An attached public `start` continues refreshing the lease while its caller remains attached.
Each runner fails closed unless a small guard starts successfully beside it in a separate process group.
That guard accepts the lease only while the state root retains the device/inode identity recorded by the runner's claim, and initiates the verified stop after two consecutive reads cannot prove that identity and lease freshness, so one unreadable read cannot kill a live runner.
Those two reads are spaced half a check interval apart, so the pair the debounce requires completes inside one check interval instead of costing two of them.
For a runner whose ownership can still be proved, the nominal detection bound is therefore the lease plus one check interval, after which the verified stop runs within its own grace period; the lease age is compared in whole seconds, so a configured lease is honoured until that age reads one second past it, and scheduling delays or failed inspection and signalling can extend the whole bound.
That grace is a ceiling rather than a delay every stop pays: two seconds for the ordinary signal and two more for the forced one, spent only by a group that outlives the signal it was sent, which is why a healthy runner's stop completes in a fraction of a second.
The group signal reaches the blocking child and everything under it exactly as retirement does.
A runner exports the inherited `FM_PROCEVENT_IN_RUNNER` marker and every lease refresh is skipped under it, so a runner and its ordinary children do not certify their own owner, and the next reconcile in a live home simply starts a replacement runner.
That no-self-refresh rule is CONFUSED-AGENT-GRADE, the same deliberate captain-decided grade `bin/fm-lease-lib.sh` documents: it stops the accidental case this boundary exists for, an orphaned or test-scaffolding source tree that would otherwise keep its own owner alive.
A source that DELIBERATELY strips the marker from its environment can still refresh the lease, so adversarial-grade unforgeability is explicitly out of scope here and tracked as separate follow-up design work.
Scope is the owning state root and one runner generation, never a script or process name, so a live source in another home is untouched: that home refreshes its own lease.
`FM_PROCEVENT_OWNER_LEASE_SECONDS` (default 600, range 1..86400) is how long a runner keeps going with no sign of activity in its owning home, and `FM_PROCEVENT_OWNER_CHECK_SECONDS` (default 15, range 1..3600) is the guard's detection interval: it re-reads the lease and the recorded state-root identity twice within each interval, half an interval apart, so the two reads its debounce needs fit inside one interval rather than costing two.
`FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` (default 1, range 1..3600) is the minimum time between consecutive launches of one registration generation's stored command, bounding the launch rate of an immediately returning source during that lease window.
The generation's first launch is immediate, later launches share its monotonic pacing timestamp, a timestamp from before a reboot is treated as expired, and replacing the registration starts a fresh pacing generation.

`FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` (default 3, range 1..600) bounds how long `reconcile` waits for the runners it just started to prove they are running: never less than the configured value, and at most one second more, because the wait is measured on a whole-second clock.
Starting a runner is detached and its errors are not visible to the caller, so `reconcile` reports a start only after the source is observed owned or its launch-pacing stamp has advanced or appeared, and reports every unconfirmed launch as `failed=` and a non-zero exit instead.
Both signals are durable evidence a runner claimed: ownership is the only evidence a runner still blocked on its source ever shows, and the stamp - written after the claim and before the source command runs, and removed only by registration replacement - covers a runner that claimed, ran and exited between two polls.
A healthy launch therefore confirms on the first poll and the window only bounds a launch that has not yet proved itself - one that died before claiming, or one merely too slow to claim inside the window; confirmation cannot tell those apart, and a launch that proves itself on a later cycle closes its failure episode without a retraction wake.
All of a cycle's launches share one window, so a home full of sources that cannot start costs the same bounded wait as one.

Keep this window well below `FM_POLL`.
`bin/fm-watch.sh` runs `reconcile` once per supervision cycle, so a source that cannot start makes every cycle wait up to the confirm window before the rest of that cycle runs.
Raising the confirm window lengthens every supervision cycle and delays wake delivery by up to that much.

A source that can never start is reported as `failed=` with a non-zero exit on every `reconcile`, rather than counted as `started` and retried silently as though it were healthy, so a wedged source stays visible instead of presenting as armed.
That count reaches only whoever runs the command, because `bin/fm-watch.sh` discards `reconcile`'s output and exit status, so an unconfirmed launch is also announced through the wake queue: `reconcile` publishes a durable `check` wake (`procevent:<id>:launch-failed:<registration-identity>-<episode-nonce>`) once per failure episode, and later cycles stay silent for that episode until a launch of that source confirms, after which a fresh failure announces again under a fresh key, because the watcher never re-surfaces a key it has already surfaced.
The announcement changes nothing about the launch: `reconcile` keeps relaunching the source every cycle exactly as before, and nothing is retried differently, throttled, or recovered from that signal.
The wake says only what was observed for that shape - the launch did not prove it took the claim within the window - and, if it stays that way, names the source command and adapter binary the registration names as what to check and the attached `bin/fm-procevent.sh start <source-id>` as what reproduces a refusal on stderr, where the detached launch discards it; a later cycle that finds the source owned ends the episode on its own, so a runner that was merely slow to claim needs nothing from the operator.
A source stranded on a claim nothing may automatically displace is announced the same way, once per stranded claim generation, as described above.
`bin/fm-watch.sh` surfaces both under their own headlines - `process-event source stranded` and `process-event source failed to start` - rather than as a captured result.

A value this command cannot use is refused by name before anything is launched, the same way `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` and `FM_PROCEVENT_MAX_OUTPUT_BYTES` are refused, so a mistyped window can never present as a fleet of sources that cannot start.
`bin/fm-watch.sh` validates the same value when it arms and refuses to arm on an unusable one, naming the variable and the range: under a running watcher that refusal would otherwise repeat on every cycle into a discarded stdout and leave the whole home disarmed while presenting as supervised, whereas a watcher that will not arm is loud through the liveness guard.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Captain inbox

`bin/fm-inbox.sh` preserves ordinary text capture, status, list, drain and explicit acknowledgement without credentials or a model call.
Each note has one durable record and one wake; a read leaves it pending until explicit acknowledgement moves it to handled evidence.
The script's header and help own command mechanics and the optional `ask` configuration.
The model-backed side-question helper stays disabled until configured and sends only the requested question to Bedrock.
Voice input and Firstmate's IMAP/SMTP mail plane are no longer provided.
Existing private mail or voice records are not deleted or automatically migrated.
Global mail skills and other installed tools are independent of these removed Firstmate integrations.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional new-task selection; only herdr is accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
FM_TASK_ID=             # internal task-worker marker fm-spawn.sh exports into ship and scout panes, never set by hand; bin/fm-test-run.sh refuses to execute in the repository primary checkout while it is set
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_SESSION_START_TASK_CONCURRENCY=8   # concurrent per-task metadata, local endpoint, durable remote-state, and latest-status reads in the session-start inventory; invalid or zero uses 8, values above 32 use 32
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
FM_SESSION_START_TIMING_FILE=   # optional existing regular non-symlink file receiving per-stage duration rows; bin/fm-session-start.sh's header owns the format and failure semantics
FM_BACKLOG_ROW_TIMEOUT_SECS=10   # seconds bounding each backlog row read (bin/fm-backlog-transition-lib.sh); nonpositive or invalid values fall back to 10; the first bound hit latches the sweep so later reads return immediately, each still naming its own item
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the deferred inactive-outcome scan plus network checks; hitting it prints an actionable NETWORK_CHECKS line
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10   # seconds bounding each local per-task current-state read inside bin/fm-fleet-snapshot.sh; remote endpoint liveness is not probed on the snapshot path
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # maximum local tasks whose current-state and endpoint observations are collected concurrently during snapshot composition
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=14  # floored elapsed-day threshold at which an undated captain hold (no hold-until; age from its UTC hold-set timestamp, falling back to since for legacy unstamped holds) is projected as a Charted Next gate instead of a live Captain's Call; 0 applies once the computed age is non-negative
FM_RECONCILE_REQUEST_MAX_BYTES=1048576   # maximum captured Bearings or fleet snapshot accepted for durable reconcile-notify request publication
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also requests an immediate scan in the deferred worker
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery when the worker is not classified busy; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_PROCEVENT_OWNER_LEASE_SECONDS=600    # how long a source runner keeps going with no activity in its owning home; 1..86400
FM_PROCEVENT_OWNER_CHECK_SECONDS=15     # a runner guard's detection interval, read twice per interval; 1..3600
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1     # minimum interval between launches of one registration generation's source command; 1..3600
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=3   # how long reconcile waits for the runners it started to prove they are running; 1..600, keep well below FM_POLL
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_AIME_MAX_INSTRUCTION_BYTES=262144   # maximum private AIME instruction-file size
FM_AIME_PROBE_TIMEOUT=20               # seconds allowed for each read-only bytedcli version/space probe
FM_AIME_WRITE_TIMEOUT=30               # seconds allowed for create or send before acceptance becomes unknown
FM_AIME_STATE_TIMEOUT=15               # seconds allowed for provider readback in fm-task-state
FM_AIME_REPLAY_TIMEOUT_MS=5000         # per-stream AIME event replay hard limit
FM_AIME_REPLAY_MAX_STREAMS=200         # maximum replay streams before the adapter returns unavailable
FM_AIME_READBACK_TIMEOUT=20            # seconds allowed for each AIME replay/session/output CLI call
FM_AIME_RETIRE_MAX_GENERATIONS=256       # maximum queued AIME generations scanned and sealed for stopped terminal-unavailable retirement
FM_AIME_RETIRE_MAX_CAPTURE_BYTES=1048576 # maximum bytes of one quarantined captured AIME generation during that retirement seal
FM_REMOTE_MAX_INSTRUCTION_BYTES=262144    # maximum private instruction-file size for native remote-agent providers
FM_REMOTE_RESULT_MAX_CHARS=131072         # maximum redacted iDA final-answer characters captured into normalized state/report artifacts
FM_IDA_SESSION_PAGE_SIZE=100             # bounded SG raw session list used for exact marker reconciliation
FM_IDA_DEEP_RESEARCH_TIMEOUT_MS=900000   # official iDA Deep Research MCP timeout passed to the provider tool
FM_IDA_TRANSIENT_BACKOFF_INITIAL_MS=5000 # initial retry delay for an identical nonterminal transient iDA observation
FM_IDA_TRANSIENT_BACKOFF_MAX_MS=60000    # maximum retry delay after bounded exponential increase
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # legacy no-mistakes task only: seconds allowed per recovery query inside fm-crew-state.sh
FM_TEARDOWN_NM_TIMEOUT=10    # legacy no-mistakes task only: seconds allowed per recovery query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # legacy no-mistakes task only: recent run rows scanned when direct attribution is insufficient
FM_TEARDOWN_NM_RUNS_LIMIT=200  # legacy no-mistakes task only: recent run rows scanned to prove an unresolved-head parked run belongs to teardown's task
FM_CREW_STATE_BIN=bin/fm-task-state.sh   # test override for the provider-aware current-state reader used by working/paused watcher triage
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # grace seconds for missing or nonnumeric lock-owner PIDs (minimum 2s); dead numeric PIDs have no age grace
FM_GUARD_GRACE=300      # beacon freshness threshold for guard verdicts, arm health checks, and the primary turn-end guard; see docs/turnend-guard.md for model-aware exceptions
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE if set, else the poll-derived grace (docs/turnend-guard.md "Guard grace and the poll cadence"); seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_TURNEND_CHURN_ABSORB_SECS=900   # longest one endpoint's bare turn-ends may be deferred on pane-churn evidence alone; only consulted when config/turnend-churn-absorb is present
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless admitted directly to the declared-wait cadence, while a live idle declared wait still surfaces once before that cadence bounds repeats
FM_BUSY_TURN_MAX_SECS=3600         # maximum age without a completed turn or explicit native-harness progress (bin/fm-watch.sh owns marker selection), before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait or attended verified captain-held transfer takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_PAUSE_RESURFACE_SECS=14400      # four hours between bounded rechecks of a declared external wait or verified captain-held transfer, and between repeated new-hash stale alarms for an ordinary crew task with an open backlog captain call; a structured until time can make an external-wait recheck occur sooner but cannot extend this bound; this includes a live idle pane after its first inconclusive stale wake and a live busy pane past FM_BUSY_TURN_MAX_SECS
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for the rendered supervisor busy guard; semantic worker state and native prompt submission ignore it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; stale scrollback banners stay out of the candidate set
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled Herdr reads)
FM_SEND_SETTLE=1        # seconds fm-send waits after native prompt submission is accepted; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# optional model-backed inbox helper; see "Captain inbox" above
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh ask
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`fm-teardown.sh` recovers a Treehouse path-spelling mismatch only when exactly one current managed path has the same filesystem directory identity as the already-inspected recorded path; every missing, changed, non-equivalent, or ambiguous match preserves task state.
The script header owns the exact alias-resolution procedure.
The configurable lock-retry loop applies only to Git's `Unable to create '...index.lock': File exists` return failure and runs up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
