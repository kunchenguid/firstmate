#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, a reader
# scout in checkout-free scratch, or a secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--backlog-title <title>] [--allow-no-mistakes-without-reviewer-quota] [--harness <name>|harness|launch-command] [--dispatch-resolved|--dispatch-override-reason <why>] [--dispatch-provider <name>] [--dispatch-model-family <name>] [--model <name>] [--effort <level>] [--account-profile <name>] [--task-class <class>] [--exploration] [--backend <name>] [--routing-source <captain|profile|fallback|secondmate-config>] [--matched-rule <default|rule-<n>>] [--quota-decision <selected|stopped|not-applicable|unknown>] [--quota-headroom <sufficient|tight|exhausted|unmeasurable|unknown>] [--quota-runway <sufficient|tight|exhausted|unmeasurable|unknown>] [--telemetry-task-root <mrt_uuid> --telemetry-parent <mra_uuid>]
#        fm-spawn.sh <task-id> <project-dir> --scout [--access <reader|writer>] [--backlog-title <title>] [--harness <name>|harness|launch-command] [--dispatch-resolved|--dispatch-override-reason <why>] [--dispatch-provider <name>] [--dispatch-model-family <name>] [--model <name>] [--effort <level>] [--account-profile <name>] [--task-class <class>] [--backend <name>] [--routing-source <captain|profile|fallback|secondmate-config>] [--matched-rule <default|rule-<n>>] [--quota-decision <selected|stopped|not-applicable|unknown>] [--quota-headroom <sufficient|tight|exhausted|unmeasurable|unknown>] [--quota-runway <sufficient|tight|exhausted|unmeasurable|unknown>] [--telemetry-task-root <mrt_uuid> --telemetry-parent <mra_uuid>]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--routing-source <captain|profile|fallback|secondmate-config>] [--telemetry-task-root <mrt_uuid> --telemetry-parent <mra_uuid>] --secondmate
#   --mode and --yolo are this task's delivery contract, REQUIRED for every ship
#   spawn and refused on --scout and --secondmate spawns. --backlog-title creates
#   a queued ship/scout backlog item through tasks-axi before launch, or validates
#   the title of an existing item, and is refused on relaunches and secondmates.
#   Firstmate resolves both
#   per task at intake (AGENTS.md section 7); data/projects.md holds the captain's
#   standing posture as context, not as this task's answer, so a spawn never looks
#   the mode up. A ship spawn additionally reads the brief's recorded
#   "Delivery contract: mode=<mode>" line and REFUSES a mismatch, so the worker's
#   instructions and the recorded task delivery cannot drift apart; a brief
#   scaffolded before that line existed warns once and launches on the flag. A
#   ship or scout spawn also refuses leftover `{TASK}` / `{FIRSTMATE_SPEC}`
#   placeholders, an empty Task, or an incomplete pair of Task subsections.
#   Every ship or scout spawn renders `launch-brief.md`; for a no-mistakes ship
#   it also carries the current `--intent` contract and the extracted captain
#   intent. A legacy mixed Task is accepted there only under bin/fm-dod-lib.sh's
#   provenance-marking rules; unmarked legacy Tasks stop for migration rather
#   than becoming intent. That library owns the parsing and intent rules. When
#   the explicit mode carries less rigor than the project's standing posture, a
#   loud one-line deviation notice is printed and the spawn continues.
#   no-mistakes-prod-only is a registry policy rather than a task mode and is
#   refused as a flag value.
#   A no-mistakes ship reads the reviewer chain from
#   ~/.no-mistakes/config.yaml and one quota-axi snapshot before any fleet
#   mutation. Exact zero effective availability blocks a reviewer; missing or
#   unmeasurable quota stays eligible with a warning. The spawn is refused only
#   when every configured reviewer is blocked. The explicit
#   --allow-no-mistakes-without-reviewer-quota flag records a captain-authorized
#   exception in the invocation and is valid only for a no-mistakes ship.
#   direct-PR and local-only launches prepend a task-scoped PATH shim that logs
#   and refuses no-mistakes instead of relying on the worker brief alone.
#        fm-spawn.sh <task-id> --relaunch [--resume-session <codex-session-id>] [--harness <name>] [--model <name>] [--effort <level>]
#   --relaunch launches a replacement agent for an EXISTING task into that
#   task's own recorded endpoint and worktree instead of creating either. It is
#   the launch half of the control plane (bin/fm-control.sh relaunch), which
#   owns the checkpoint, the progress note, stopping the previous agent, and the
#   transaction; call fm-control rather than this flag directly unless you are
#   deliberately re-launching an already-stopped task. Every identity axis -
#   backend, kind, project or home, worktree, endpoint - comes from the task's
#   validated state/<id>.meta, so --backend, --scout, --secondmate, a project
#   positional, and batch pairs are all refused alongside it; only harness,
#   model, and effort may change, which is what makes a harness switch one
#   ordinary relaunch. It refuses unless the recorded endpoint is positively
#   agent-free on a backend with a recovery-grade agent-state classifier (tmux
#   or herdr), refuses unless the endpoint's shell is sitting in the recorded
#   worktree, and clears the previous harness's per-task wiring before arming
#   the new incarnation.
#   --resume-session <codex-session-id> is Codex-only and valid only with
#   --relaunch. It resumes that vendor session through this same lifecycle
#   owner while preserving the task's recorded model and effort unless either
#   is explicitly overridden; autonomy, notification, prompt, co-author
#   sanitation, routing, worktree, and endpoint handling remain unchanged.
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max|ultra> are concrete profile
#   axes chosen by firstmate at intake. Explicit axes must have a verified flag
#   mapping and a matching launch-template slot, or spawn refuses before intake
#   and provisioning; it never records a requested axis while silently omitting it.
#   Metadata records the requested setting, not a claim of observed runtime effort.
#   Both axes also accept the
#   literal "default", the task meta's spelling for an unset axis, and treat it
#   as exactly that, so a recorded tuple - the escalation ladder's relaunch
#   verdict (bin/fm-harness.sh escalate) - can be re-passed verbatim.
#   --account-profile <name> selects one home-local native Claude subscription
#   from config/claude-account-profiles. The verified claude template is the only
#   consumer; non-Claude and raw launch commands refuse the axis. Spawn validates
#   the complete mapping and exact native paid-account auth status before endpoint
#   creation, records only account_profile=<name> in private task metadata and the
#   selected model-attempt tuple, and binds the canonical directory as one quoted
#   CLAUDE_CONFIG_DIR value. An absent axis leaves all prior launch bytes unchanged.
#   A secondmate parent launch refuses this axis; run the same portable mechanism
#   inside that home rather than transferring home-local paths.
#   --routing-source <captain|profile|fallback|secondmate-config> records how this
#   task's routing tuple was authorized at intake: an explicit per-task captain
#   instruction, a configured dispatch profile, the generic fallback, or the
#   persistent secondmate tuple owner. The value lands in task metadata as
#   routing_source= and is the escalation ladder's precedence guard
#   (bin/fm-harness.sh escalate acts only on fallback); absent provenance leaves
#   routing untouched there. A ladder-driven relaunch re-passes fallback.
#   A --secondmate recovery records secondmate-config automatically only when a
#   complete config/secondmate-harness tuple owns harness, model, and effort and
#   no explicit or positional tuple override was supplied. Bootstrap recovery
#   therefore preserves truthful provenance without relying on caller flags.
#   --dispatch-tachikoma is an alternative attestation for fresh ordinary tasks.
#   It requires --task-class and an explicitly enabled config/tachikoma/policy.json,
#   asks fm-tachikoma before launch, and owns all model/quota/provenance axes.
#   It cannot accompany other routing flags or positional harnesses. Batch tasks
#   route independently; relaunches and persistent supervisors retain their
#   existing explicit routing paths. No service is auto-started.
#   --task-class records the intake classification in model telemetry; absent stays
#   unresolved for compatibility, and a fresh ship or scout spawn prints one stderr
#   warning naming that default without changing the recorded value.
#   --exploration records firstmate's deliberate
#   model/effort rotation, requires both axes explicitly, and is accepted only
#   for a ship classified as bounded-implementation-proven-root-fix behind the
#   no-mistakes delivery path.
#   Spawn records the machine's one-minute load average and logical CPU count with
#   every new intake so exploration results retain their observed load condition.
#   An explicit model selector is retained as modelVersion. When no selector is
#   supplied, model stays default while modelVersion is honestly unreported.
#   A writer's resolved harness executable contributes its first `--version` line
#   as cliVersion. A reader never executes its harness before confinement, so its
#   CLI version is unreported and cannot satisfy a routing candidate comparison.
#   --telemetry-task-root links a retry or escalation to an existing opaque task
#   root, and --telemetry-parent names that root's immediately prior attempt.
#   They are per-attempt values, so a batch dispatch refuses them.
#   --backend <name> is the explicit runtime session-provider backend for this
#   exact task only (docs/configuration.md "Runtime backend" owns when that flag
#   is authorized). Without it, the script resolves FM_BACKEND, then
#   config/backend, then runtime auto-detection from the runtime firstmate's
#   environment: $TMUX, HERDR_ENV=1, or cmux runtime signals (via
#   bin/fm-backend.sh's fm_backend_detect, with cmux fallback details in
#   docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/writer-scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   A herdr crewmate or scout is placed in the exact workspace of the firstmate
#   or secondmate process launching it, resolved from that process's own herdr
#   pane rather than from a workspace label (herdr enforces no label uniqueness,
#   so a label cannot tell two "firstmate" workspaces apart). A claimed parent
#   identity that is unreadable, contradictory, stale, or from another herdr
#   session stops the spawn before any worker endpoint exists. A launcher
#   outside herdr has no workspace to inherit and uses this home's own labeled
#   workspace, which must then match exactly one. --secondmate is the deliberate
#   exception: it stands up that secondmate home's own workspace.
#   Herdr additionally uses a presentation-only layout by default when the
#   selected client and running server meet the Herdr 0.8.0 floor. The local
#   config/herdr-presentation-spaces file can say off to disable it or on to
#   opt in below that floor; an empty file remains the historical opt-in form.
#   A clean fresh task first writes state/<id>.herdr-presentation atomically,
#   then creates a disposable
#   workspace containing only the ordinary task pane. A successful clean create
#   upgrades its attempt journal with exact home, session, workspace, tab, pane,
#   parent, and label bindings. On a same-identity restart, that complete binding
#   plus authoritative metadata may replace one exact agent-free husk in place.
#   The journal, visible token, and labels alone are never endpoint or ownership
#   authority, and every ambiguous recovery stays on the flat fallback after
#   duplicate-agent risk is independently absent. Treehouse allocation and task
#   metadata are unchanged.
#   A clean projected create or exact resume makes one bounded attempt to hold
#   the one session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through creation, ordering and
#   restart-binding publication, releasing before worktree allocation or launch. Lock
#   contention warns and falls back to the ordinary flat layout before any
#   projection mutation. The exact response-derived new workspace is inserted
#   immediately after its owning parent (firstmate or 2ndmate-<id>) contiguous
#   child block. Ordering never authorizes lifecycle cleanup, and any
#   unavailable, ambiguous, or failed move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends. A fresh spawn first takes the
#   per-home task-set lock and refuses rather than waits when forced teardown owns
#   it; relaunch is exempt because the existing task's control lock covers it.
#   A fresh Treehouse-backed spawn also takes the project-identity lock in the local
#   root Firstmate home's state directory before slot allocation and holds it through
#   task metadata publication. Teardown holds that same lock while proving and
#   returning a slot, so allocation cannot reuse a slot before its owner record
#   is published. The local root is whatever bin/fm-wake-lib.sh's
#   fm_firstmate_root_home resolves, so a home seeded from another machine anchors
#   that lock itself rather than failing to resolve one;
#   contention refuses rather than waits.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation, AND that explicit harness must carry a dispatch
#   attestation: --dispatch-resolved (the profiles were consulted and produced
#   this harness) or --dispatch-override-reason "<why>" (a deliberate departure
#   from the matched profile, recorded in state/<id>.meta as dispatch=override and
#   dispatch_override_reason=<why>, so the reason must be a single line - meta is
#   one key=value per line and every reader takes the LAST match, so an embedded
#   newline would forge a later worktree=, backend=, or kind= line). A bare
#   explicit harness is refused, because that is the silent hand-pick the guard
#   exists to catch; the guard checks that resolution HAPPENED, not what it
#   produced, and never reads crew-dispatch.json
#   to verify the harness matches (that would be a second resolver).
#   Passing both attestations is refused as ambiguous.
#   --dispatch-provider and --dispatch-model-family carry the provider relation
#   and family established during that consultation. fm-spawn never derives either
#   from a model string. While data/quota-cooldowns.json exists, this spawn passes
#   those axes, and any --dispatch-override-reason as the captain authorization,
#   to bin/fm-quota-cooldown.sh authorize before any endpoint or task metadata
#   exists, and relays its refusal status verbatim. That script owns which
#   candidate is refused, which axes it demands, and how an override is recorded.
#   --matched-rule, --quota-decision, --quota-headroom, and --quota-runway carry
#   the routing-decision facts firstmate already has (the rule id and the
#   quota-axi reading that informed the choice) into the intake row, so the
#   telemetry join can report per-subscription quota utilization. fm-spawn
#   writes only what is passed and omits the rest, so a no-profile or legacy
#   spawn stays byte-identical to before. Those routing facts are recorded in
#   state/<id>.meta as the keys matched_rule=, quota_decision=, quota_headroom=,
#   quota_runway=, dispatch_provider=, dispatch_model_family=, routing_source=,
#   dispatch= (resolved|override), and dispatch_override_reason=, each written
#   only when set so a no-profile spawn stays byte-identical.
#   A --secondmate spawn on a REMOTE route records remote_host=, remote_root=,
#   remote_backend=, remote_herdr_session=, and remote_target= in state/<id>.meta
#   so the route is reconciled from task metadata rather than a shared namespace.
#   A --secondmate spawn is exempt and resolves the SECONDMATE harness
#   (config/secondmate-harness -> config/crew-harness
#   -> own), so the secondmate-vs-crewmate split is DURABLE across every respawn
#   (recovery, /updatefirstmate, restart). A bare ordinary-worker adapter name
#   (claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|cursor-agent)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters. That command skips the launch-scoped Git co-author sanitizer
#   used by ordinary worker templates, but delivery-mode safety wrappers remain.
#   For pi and pi-signed, fm-spawn resolves the selected executable
#   name from PATH once, probes that concrete path with --help, and launches the
#   same path. It adds --tui-mode regular only when that help advertises the flag;
#   a failed or inconclusive probe omits it so older Pi versions remain launchable.
#   A missing selected executable refuses before endpoint creation, and pi-signed
#   never falls back to pi. Writer launches pre-register the exact worktree
#   in Pi's trust store before any task state is created; the launch
#   carries the same PI_CODING_AGENT_DIR so Pi reads that store.
#   For omp (Oh My Pi), fm-spawn resolves the `omp` executable from PATH once and
#   refuses when it is absent. Every omp launch clears the foreign harness
#   markers (omp publishes none of its own), sets the Firstmate-owned
#   FM_OMP_HARNESS=omp detection marker, suppresses the first-run provider
#   wizard with OMP_SKIP_SETUP=1, forces --auto-approve, pins the working
#   directory with --cwd, and passes the tracked worker posture overlay
#   .omp/fm-worker-overlay.yml through --config. That overlay pins composer
#   shape, plan mode off, prewalk off, and the non-interactive usage-reserve
#   policy for the one session only (--auto-approve alone owns approval); the
#   captain's own ~/.omp/agent/config.yml (model roles, providers, theme) is
#   never written.
#   A model written as <provider>/<id> is validated against `omp models --json`
#   only when that provider appears in the listing; a provider absent from the
#   listing (an extension-registered provider such as claude-bridge, which omp
#   never lists) passes through unvalidated with a stderr notice, and a bare
#   fuzzy pattern is left to omp's own matcher. A crewmate or scout loads its
#   per-task busy-state extension with -e from state/ (outside the worktree, so
#   auto-discovery cannot load it a second time); a secondmate passes no -e at
#   all and relies on omp auto-discovering the home's tracked .omp/extensions/
#   (verified, omp 18.1.11: a file named both ways loads twice, and discovery is
#   cwd-only with no trust dialog).
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, disposable
#   task environment; see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   --access <reader|writer> is the scout reader/writer axis, classified by
#   firstmate at intake exactly like --task-class, and refused on ship and
#   secondmate spawns (a ship delivers a project change through an isolated
#   worktree by definition). writer, the default, keeps today's scout contract
#   and metadata byte-identical. A same-task writer relaunch reuses the recorded
#   Treehouse lease, holder, slot, and path under the acquisition lock and never
#   calls generic `treehouse get`. reader dispatches the scout SLOT-FREE: no
#   `treehouse get`, no pool worktree. The task pane starts in a disposable
#   scratch directory at a home-scoped <tasktmp>/scratch, spawn creates a bare shared-object
#   read handle at scratch/repo.git (git clone --bare --shared of the project;
#   the handle is disposable and per-launch - every launch replaces whatever
#   sits at that path with a fresh clone of the current project, and a same-boundary
#   relaunch pins its HEAD to the task's preserved base commit), records
#   access=reader plus worktree=<scratch> in the meta, records base_commit=
#   from the initial handle's HEAD (the immutable task baseline), and appends
#   " access=reader" to the success
#   line. The reader isolation boundary refuses unless validate_reader_scratch
#   proves the scratch is outside tracked territory and the OS-specific launch
#   sandbox can deny project writes inherited by the harness and its children;
#   a reader brief must carry fm-brief.sh's
#   "Access contract: access=reader" line and the spawn refuses reader/writer
#   drift between the brief and the flag in both directions. backend=orca is
#   refused for readers because orca allocates a managed worktree per task,
#   which is exactly the allocation a reader avoids. fm-teardown.sh owns the
#   reader cleanup contract (no pool return, fail-loud on a grown checkout),
#   and fm-promote.sh refuses to promote a reader in place.
#   Before a secondmate launch, the home is fast-forwarded to the primary's
#   default-branch commit when safe: directly for a local home, or through the
#   configured host for a remote home. Skipped syncs warn and launch unchanged.
#   Ship spawns and writer scout spawns refuse to launch unless the resolved
#   task path is a real git worktree root distinct from the primary project
#   checkout. Reader scout isolation is owned by the path and launch gates below.
#   Before a fresh ship or scout worker starts, its clean task worktree fetches
#   origin, resolves the current remote default branch, and resets to its tip.
#   An unreachable origin, unresolved default branch, or non-clean worktree
#   refuses the spawn rather than risking a PR based on stale history.
#   A slot whose only deviation is a stale submodule gitlink is refused by that
#   same clean check, but is reported as a stale checkout naming each submodule
#   and both pins; nothing is converged or removed, and no remedy is suggested.
#   That report is only reached when each submodule's checked-out commit is
#   already contained in one of its remotes, so a submodule carrying an unpushed
#   commit keeps the conservative uncommitted-work refusal instead. That
#   containment test reads local refs only and never fetches, so this gate stays
#   usable offline; a stale remote-tracking ref can therefore make an unpushed
#   commit look contained, which is exactly why no remedy command is printed.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--access/--harness/--model/--effort/--task-class/
#   --exploration/--backend/--mode/--yolo applies to every pair. A ship batch
#   therefore carries one delivery contract, and each
#   pair still checks it against its own brief; a batch spanning modes is two invocations.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches, and the shared dispatch attestation (--dispatch-resolved or
#   --dispatch-override-reason) is forwarded to every pair. The loop lives here, in
#   bash, so callers never hand-write a multi-task shell loop (the tool shell is
#   zsh, which does not word-split unquoted $vars and silently breaks ad-hoc
#   `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __PIBIN__    quoted concrete Pi-family executable path resolved from PATH
#     __PITUIMODE__ optional --tui-mode regular when that executable advertises it
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the task root to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __PIWORKERCONTEXT__ optional Firstmate-repository worker context flags for Pi
#     __PISESSIONFLAG__ optional durable Pi session flag for one ordinary model attempt
#     __CLAUDESESSIONFLAG__ optional durable Claude session flag for one ordinary model attempt
#     __OMPBIN__   quoted concrete omp executable path resolved from PATH
#     __OMPEXT__   absolute path to state/<task-id>.omp-ext.ts (omp busy-state and
#                  turn-end extension, written by this script; outside the worktree so
#                  omp's cwd-only auto-discovery cannot load it a second time)
#     __OMPWORKERCFG__ absolute path to the tracked .omp/fm-worker-overlay.yml posture overlay
#     __OPINPUT__   absolute path to the canonical operational-input encoder
#     __RESUME__    empty for an initial launch or `resume ` for Codex resume
#     __SESSION__   the shell-quoted supplied Codex session identity
#     __WORKTREE__  absolute path to the task worktree
#     __CURSORBIN__ resolved, cursor-verified executable for cursor launches
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the task root.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a task-root pointer excluded from Git for writer worktrees.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a task-root .fm-grok-turnend pointer, excluded from Git for writer worktrees, and a state token.
# muse installs no hook at all - its plugin engine is off in the default build - so
# it writes state/<id>.muse-session to bind the pane to muse's own session event
# log; muse and gemini are crewmate/scout only and are refused for --secondmate.
# rovo installs no hook either - its eventHooks fire at tool granularity only,
# never turn-end - so it carries no busy-source wiring at all and no turn-end
# hook. A positional brief is dead-on-arrival (rovo loads, never works, and drops
# to an idle shell), so rovo launches BARE and receives an absolute brief pointer
# only after a TUI readiness gate, then a delivery-confirmation gate - the same
# launch-then-send shape as kimi. Its busy state is a screen-scrape fallback like
# grok. rovo is crewmate/scout only and is refused for --secondmate, like muse.
# cursor installs no per-task hook either: it writes state/<id>.cursor-session to
# bind the pane to cursor's own conversation transcript (projects root, the exact
# workspace path cursor records in .workspace-trusted, and the conversations that
# already existed for that workspace). It is launched through the verified binary
# resolver because `cursor` is not the CLI name. A cursor SECONDMATE instead runs
# the tracked project-scope .cursor/hooks.json in its own home, whose stop-hook
# park owns that home's supervision (docs/supervision-protocols/cursor.md).
# Cursor Agent uses task-root-local .cursor/hooks.json, excluded through Git
# info/exclude for writer worktrees so Firstmate machinery never enters project diffs.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> [access=reader] [mode=<mode> yolo=<on|off>] window=<backend-target> worktree=<path>
# Every fresh local spawn's state/<id>.meta opens with the same base inventory:
# window=, endpoint_task_id=, worktree=, project=, harness=, kind=, code=, tasktmp=,
# model=, and effort= (model= and effort= record the literal default when the
# axis is unset); busy_gen= is recorded when the busy-state contract was armed
# for the harness. The conditional code_parent=, parent=, child_seq=, access=,
# dispatch, quota, remote-route, backend, telemetry, and traceparent fields are owned by their own entries in
# this header, and backend-specific fields resolve through bin/fm-backend.sh.
# Publishing the record and moving this home's backlog item to In flight are one
# step, not two: bin/fm-backlog-transition-lib.sh owns that invariant, and this
# script performs the transition under the task's own meta lock before it reports
# success. A ship or scout dispatch therefore REFUSES up front, before any
# endpoint, worktree, or record exists, unless the home's backlog has an
# unheld, unblocked Queued or In flight item for the id; a transition that fails
# after publication removes the record it just wrote rather than leaving a
# worker the backlog does not own. A relaunch re-reads the row instead of
# re-running the transition, so an eligible In-flight item is left untouched.
# The transition is
# skipped entirely for --secondmate spawns (persistent agents are not work
# items), on a config/backlog-backend=manual home, and in a home that keeps no
# data/backlog.md. An automatic-backend home with a backlog but no compatible
# tasks-axi refuses before creating any lifecycle state.
# A ship task records the explicit mode/yolo it was passed; a secondmate spawn records
# mode=secondmate, yolo=off, home=, and projects=; a scout records neither, and both the
# success line and state/<id>.meta omit them.
# Every fresh spawn or relaunch records a new spawn_gen= incarnation token so durable
# consumers can distinguish a replacement worker that reuses the same task id.
# Before publishing the meta, every spawn records one privacy-safe model-attempt
# intake in the private ledger owned by bin/fm-model-telemetry.sh, then writes that
# attempt's opaque telemetry_attempt= and telemetry_task_root= identifiers into the
# meta; the meta carries those identifiers only, never ledger payload content, and
# teardown seals the attempt against them. A refused intake exits without submitting
# the launch command, so no model attempt runs unrecorded; that owner's header owns
# the refusal reasons and their repair route.
# Ship and writer scout metadata record base_commit= from the exact worktree HEAD
# before launch; reader scout metadata records it from the initial bare read handle's HEAD.
# A writer relaunch in the same worktree preserves the original value; a reader relaunch pins
# the fresh per-launch handle to it and refuses when it no longer names a commit
# readable through that handle. This
# task-scoped fact, not the recycled lane's retained reflog, bounds local-only
# delivery to work produced after this task started.
# When the home session's frozen trace-context decision is enabled (see
# docs/configuration.md and bin/fm-trace-context-lib.sh), the meta also records
# one W3C traceparent= carrier, the same value injected into the pane as
# TRACEPARENT; the default-off path writes neither, leaving the generated meta
# and launch environment unchanged.
#   --traceparent <carrier> delivers a carrier that a REMOTE parent already
#   resolved and will record, instead of resolving one from this home's frozen
#   decision. It is accepted only for --secondmate spawns, only as a strictly
#   validated W3C traceparent, and exists because a remote secondmate's task
#   identity is owned by the parent home that holds its task metadata, while the
#   pane export happens on the remote host (bin/fm-remote-secondmate-control.sh).
#   Local spawns never pass it and resolve their own carrier exactly as before.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  *$'\n'*|*$'\r'*)
    echo "error: FM_HOME must be a single line" >&2
    exit 1
    ;;
esac

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_HOME=$(resolve_directory_input FM_HOME "$FM_HOME") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  FM_STATE_OVERRIDE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_DATA_OVERRIDE=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
if ! LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-allowlist"); then
  exit 1
fi
LAUNCH_ENV_NAMES=
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  if [ ! -f "$CONFIG/launch-env-allowlist" ] || [ ! -r "$CONFIG/launch-env-allowlist" ]; then
    echo "error: config/launch-env-allowlist must be a readable regular file" >&2
    exit 1
  fi
  if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
    split("\n") | map(select(. != "" and (startswith("#") | not))) |
    if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
    else error("expected environment names only") end
  ' "$CONFIG/launch-env-allowlist" 2>/dev/null); then
    echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
    exit 1
  fi
fi
SUB_HOME_MARKER=".fm-secondmate-home"
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
fi
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-launch-axis-lib.sh
. "$SCRIPT_DIR/fm-launch-axis-lib.sh"
# shellcheck source=bin/fm-claude-account-profile-lib.sh
. "$SCRIPT_DIR/fm-claude-account-profile-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"

SPAWN_TIMING_STARTED=$(fm_timing_now_ms)
SPAWN_TIMING_READY=0
SPAWN_TIMING_EMITTED=0
SPAWN_TIMING_DISPATCH_START=$SPAWN_TIMING_STARTED
SPAWN_TIMING_DISPATCH_MS=0
SPAWN_TIMING_BRIEF_MS=0
SPAWN_TIMING_LEASE_MS=0
SPAWN_TIMING_HERDR_MS=0
SPAWN_TIMING_LAUNCH_MS=0
SPAWN_TIMING_TRUST_MS=0
SPAWN_TIMING_BUSY_MS=0
SPAWN_TIMING_LOCK_WAIT_MS=0
SPAWN_TIMING_LEASE_START=
SPAWN_TIMING_LEASE_ACTIVE=0
SPAWN_TIMING_BRIEF_START=
SPAWN_TIMING_HERDR_START=
SPAWN_TIMING_LAUNCH_START=
SPAWN_TIMING_TRUST_START=
SPAWN_TIMING_BUSY_START=

spawn_timing_enable() {
  local log
  [ "$SPAWN_TIMING_READY" = 0 ] || return 0
  log=${FM_SPAWN_TIMING_LOG:-${FM_TIMING_LOG:-$STATE/.spawn.timings}}
  [ -n "$log" ] || return 0
  : >> "$log" 2>/dev/null || return 0
  FM_TIMING_LOG=$log
  FM_TIMING_EPOCH_MS=$SPAWN_TIMING_STARTED
  export FM_TIMING_LOG FM_TIMING_EPOCH_MS
  SPAWN_TIMING_READY=1
}

spawn_timing_finish() {
  local phase=$1 start=${2:-} now elapsed
  case "$start" in ''|*[!0-9]*) return 0 ;; esac
  now=$(fm_timing_now_ms)
  elapsed=$((now - start))
  [ "$elapsed" -ge 0 ] || elapsed=0
  fm_timing_record phase "$phase" "$start" "${ID:-unknown}"
  case "$phase" in
    dispatch) SPAWN_TIMING_DISPATCH_MS=$elapsed ;;
    brief) SPAWN_TIMING_BRIEF_MS=$elapsed ;;
    lease) SPAWN_TIMING_LEASE_MS=$elapsed ;;
    herdr) SPAWN_TIMING_HERDR_MS=$elapsed ;;
    launch) SPAWN_TIMING_LAUNCH_MS=$elapsed ;;
    trust) SPAWN_TIMING_TRUST_MS=$elapsed ;;
    busy) SPAWN_TIMING_BUSY_MS=$elapsed ;;
  esac
}

spawn_timing_seconds() {
  local milliseconds=$1
  printf '%d.%03d' "$((milliseconds / 1000))" "$((milliseconds % 1000))"
}

spawn_timing_emit() {
  local status=${1:-0} total op=spawn
  [ "$SPAWN_TIMING_READY" = 1 ] || return 0
  [ "$SPAWN_TIMING_EMITTED" = 0 ] || return 0
  SPAWN_TIMING_EMITTED=1
  total=$(( $(fm_timing_now_ms) - SPAWN_TIMING_STARTED ))
  [ "$total" -ge 0 ] || total=0
  fm_timing_record spawn summary "$SPAWN_TIMING_STARTED" "${ID:-unknown}"
  [ "${RELAUNCH:-0}" -ne 1 ] || op=relaunch
  fm_telemetry_record lifecycle "{\"op\":\"$op\",\"elapsedMs\":$total,\"dispatchMs\":$SPAWN_TIMING_DISPATCH_MS,\"briefMs\":$SPAWN_TIMING_BRIEF_MS,\"leaseMs\":$SPAWN_TIMING_LEASE_MS,\"herdrMs\":$SPAWN_TIMING_HERDR_MS,\"launchMs\":$SPAWN_TIMING_LAUNCH_MS,\"trustMs\":$SPAWN_TIMING_TRUST_MS,\"busyMs\":$SPAWN_TIMING_BUSY_MS,\"lockWaitMs\":$SPAWN_TIMING_LOCK_WAIT_MS,\"status\":$status}"
  printf 'spawn timing: total=%ss dispatch=%ss brief=%ss lease=%ss herdr=%ss launch=%ss trust=%ss busy=%ss lockwait=%ss status=%s\n' \
    "$(spawn_timing_seconds "$total")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_DISPATCH_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_BRIEF_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_LEASE_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_HERDR_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_LAUNCH_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_TRUST_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_BUSY_MS")" \
    "$(spawn_timing_seconds "$SPAWN_TIMING_LOCK_WAIT_MS")" "$status" >&2
}

# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

# Record a pre-launch spawn refusal into the routing telemetry ledger so login
# or credential rot is visible per pool/model/task-type with the exact cause.
# Best-effort: a telemetry failure never changes the spawn's own exit code or
# blocks delivery. Called only at refusal points that already decided to exit;
# the caller still owns the exit code and message.
fm_record_spawn_failure() {
  local kind=$1 cause=$2 capability=${3:-unknown} quota_reader=${4:-not-applicable} payload task_id harness
  local effort_axis task_class account_profile routing_axis
  [ -n "${FM_HOME:-}" ] || return 0
  [ -n "${STATE:-}" ] || return 0
  # Parse-time refusals happen before ID is resolved, so fall back to the first
  # positional; a batch positional is "<id>=<repo>".
  task_id=${ID:-}
  if [ -z "$task_id" ]; then
    task_id=${POS[0]:-}
    task_id=${task_id%%=*}
  fi
  fm_task_id_creation_valid "$task_id" || return 0
  [ -n "$kind" ] || [ -n "$cause" ] || return 0
  # HARNESS is resolved long after the parse-time refusals, so fall back to the
  # declared --harness. A raw launch command carries spaces and would fail the
  # ledger's harness whitelist, dropping the whole row, so keep those "unknown".
  harness=${HARNESS:-}
  if [ -z "$harness" ]; then
    case "${HARNESS_ARG:-}" in
      ''|*[!A-Za-z0-9._:-]*) ;;
      *) if [ "${#HARNESS_ARG}" -le 96 ]; then harness=$HARNESS_ARG; fi ;;
    esac
  fi
  case "$capability" in supported|unsupported|unknown) ;; *) capability=unknown ;; esac
  case "$quota_reader" in available|credential-expired|not-applicable|unknown) ;; *) quota_reader=not-applicable ;; esac
  # A parse-time refusal can fire before --effort, --task-class, --model, and
  # --account-profile have been validated, and the ledger refuses the whole row
  # on any one of them. Name the axes we cannot vouch for rather than lose the
  # refusal the ledger exists to make visible.
  effort_axis=${EFFORT:-}
  case "$effort_axis" in ''|low|medium|high|xhigh|max|default) ;; *) effort_axis=default ;; esac
  task_class=${TASK_CLASS:-unresolved}
  case "$task_class" in
    ''|rote-reversible-edit|bounded-implementation-proven-root-fix|unknown-root-diagnosis) ;;
    adversarial-review-security-review|evidence-heavy-research|long-horizon-repository-work) ;;
    visual-browser-sensitive-work|documentation-specification-decision-extraction) ;;
    external-wait-integration-work|unresolved) ;;
    *) task_class=unresolved ;;
  esac
  account_profile=${ACCOUNT_PROFILE:-}
  if [ "$harness" != claude ] || ! fm_claude_account_profile_name_valid "$account_profile"; then
    account_profile=
  fi
  routing_axis=${ROUTING_SOURCE:-}
  case "$routing_axis" in ''|captain|profile|fallback|secondmate-config) ;; *) routing_axis= ;; esac
  payload=$(jq -cn \
    --arg attemptedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg harness "$harness" \
    --arg provider "${DISPATCH_PROVIDER:-}" \
    --arg model "${MODEL:-}" \
    --arg effort "$effort_axis" \
    --arg modelVersion "${TELEMETRY_MODEL_VERSION:-}" \
    --arg cliVersion "${TELEMETRY_CLI_VERSION:-}" \
    --arg accountProfile "$account_profile" \
    --arg taskClass "$task_class" \
    --arg kind "${kind:-other}" \
    --arg cause "${cause:-unknown}" \
    --arg routingSource "$routing_axis" \
    --arg modelFamily "${DISPATCH_MODEL_FAMILY:-}" \
    --argjson dispatchResolved "${DISPATCH_RESOLVED:-0}" \
    --arg overrideReason "${DISPATCH_OVERRIDE_REASON:-}" \
    --argjson overrideReasonSet "${DISPATCH_OVERRIDE_REASON_SET:-0}" \
    --arg capability "$capability" \
    --arg quotaReader "$quota_reader" \
    'def tuple: {harness:(if $harness=="" then "unknown" else $harness end),provider:(if $provider=="" then null else $provider[0:96] end),model:(if $model=="" then null else $model[0:160] end),effort:(if $effort=="" then "default" else $effort end),modelVersion:(if $modelVersion=="" then null else $modelVersion[0:160] end),cliVersion:(if $cliVersion=="" then null else $cliVersion[0:160] end)} + (if $accountProfile=="" then {} else {accountProfile:$accountProfile} end);
     def dispatchAttestation: (if $dispatchResolved==1 then {kind:"resolved"} elif $overrideReasonSet==1 and $overrideReason!="" then {kind:"override",reason:$overrideReason[0:160]} else null end);
     {attemptedAt:$attemptedAt,tuple:tuple,taskClass:(if $taskClass=="" then "unresolved" else $taskClass end),failureKind:$kind,cause:(if ($cause|length)>512 then (($cause[0:509])+"...") else $cause end),routingSource:(if $routingSource=="" then null else $routingSource end),dispatchAttestation:dispatchAttestation,dispatchModelFamily:(if $modelFamily=="" then null else $modelFamily[0:96] end),capability:$capability,quotaReader:$quotaReader}') || return 0
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-model-telemetry.sh" spawn-failure --state "$STATE" --task "$task_id" --payload "$payload" >/dev/null 2>&1; then
    :
  else
    echo "warn: spawn-failure telemetry could not be recorded (kind=$kind); the spawn refusal still stands" >&2
  fi
  if [ "$kind" = quota ]; then
    fm_telemetry_record_wait "$task_id" "$(fm_telemetry_task_attempt "$task_id")" provider \
      "quota-${DISPATCH_PROVIDER:-$harness}" open
  fi
}

spawn_lease_cause() {
  local detail=${1:-}
  detail=$(printf '%s' "$detail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | LC_ALL=C cut -c1-300)
  if [ -n "$detail" ]; then
    printf 'treehouse could not acquire a durable task lease: %s' "$detail"
  else
    printf '%s' 'treehouse could not acquire a durable task lease'
  fi
}

spawn_lease_refusal() {
  local message=$1
  echo "error: $message" >&2
  fm_telemetry_record_wait "$ID" "$(fm_telemetry_task_attempt "$ID")" lock treehouse-slot open
  fm_record_spawn_failure other "treehouse lease: $message" unknown not-applicable
}

if [ "${FM_SPAWN_SOURCE_ONLY:-0}" = 1 ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Classify a quota-cooldown refusal so a quota-READ credential gap is recorded
# as failureKind=quota-reader (pool still dispatchable, just can't read its
# quota) and never as failureKind=quota (real exhaustion) or failureKind=
# credential (which would falsely mark the pool undispatchable). The cooldown
# authorize output carries the stored evidence quote; a credential-expiry
# marker in that quote is the quota-reader gap signal. capability stays
# "unknown" because fm-spawn does not read config/model-catalog.json (absent
# in this home), so it never asserts the pool unsupported on a reader gap.
fm_classify_cooldown_refusal() {
  local output=$1
  if printf '%s' "$output" | grep -Eqi 'credential[_ -]?expir|credential_expired|login required|not authenticated'; then
    printf 'quota-reader|credential-expired|unknown'
  else
    printf 'quota|available|unknown'
  fi
}

# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
ACCESS=writer
ACCESS_SET=0
KIND_SET=0
HARNESS_ARG=
MODEL=
RESUME_SESSION=
EFFORT=
ACCOUNT_PROFILE=
TASK_CLASS=unresolved
EXPLORATION=none
BACKEND_ARG=
MODE=
YOLO=
TRACEPARENT_ARG=
ROUTING_SOURCE=
TELEMETRY_TASK_ROOT=
TELEMETRY_PARENT=
ALLOW_NO_MISTAKES_WITHOUT_REVIEWER_QUOTA=0
BACKLOG_TITLE=
BACKLOG_TITLE_SET=0
DISPATCH_RESOLVED=0
DISPATCH_TACHIKOMA=0
TACHIKOMA_DECISION=
DISPATCH_OVERRIDE_REASON=
DISPATCH_OVERRIDE_REASON_SET=0
DISPATCH_PROVIDER=
DISPATCH_MODEL_FAMILY=
DISPATCH_PROVIDER_SET=0
DISPATCH_MODEL_FAMILY_SET=0
MATCHED_RULE=
MATCHED_RULE_SET=0
QUOTA_DECISION=
QUOTA_HEADROOM=
QUOTA_RUNWAY=
QUOTA_DECISION_SET=0
QUOTA_HEADROOM_SET=0
QUOTA_RUNWAY_SET=0
HARNESS_SET=0
MODEL_SET=0
RESUME_SESSION_SET=0
EFFORT_SET=0
ACCOUNT_PROFILE_SET=0
TASK_CLASS_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
TRACEPARENT_SET=0
ROUTING_SOURCE_SET=0
RELAUNCH=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      access) ACCESS=$a; ACCESS_SET=1 ;;
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      resume-session) RESUME_SESSION=$a; RESUME_SESSION_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      account-profile) ACCOUNT_PROFILE=$a; ACCOUNT_PROFILE_SET=1 ;;
      task-class) TASK_CLASS=$a; TASK_CLASS_SET=1 ;;
      backlog-title) BACKLOG_TITLE=$a; BACKLOG_TITLE_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      traceparent) TRACEPARENT_ARG=$a; TRACEPARENT_SET=1 ;;
      routing-source) ROUTING_SOURCE=$a; ROUTING_SOURCE_SET=1 ;;
      telemetry-task-root) TELEMETRY_TASK_ROOT=$a ;;
      telemetry-parent) TELEMETRY_PARENT=$a ;;
      dispatch-override-reason) DISPATCH_OVERRIDE_REASON=$a; DISPATCH_OVERRIDE_REASON_SET=1 ;;
      dispatch-provider) DISPATCH_PROVIDER=$a; DISPATCH_PROVIDER_SET=1 ;;
      dispatch-model-family) DISPATCH_MODEL_FAMILY=$a; DISPATCH_MODEL_FAMILY_SET=1 ;;
      matched-rule) MATCHED_RULE=$a; MATCHED_RULE_SET=1 ;;
      quota-decision) QUOTA_DECISION=$a; QUOTA_DECISION_SET=1 ;;
      quota-headroom) QUOTA_HEADROOM=$a; QUOTA_HEADROOM_SET=1 ;;
      quota-runway) QUOTA_RUNWAY=$a; QUOTA_RUNWAY_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout; KIND_SET=1 ;;
    --secondmate) KIND=secondmate; KIND_SET=1 ;;
    --relaunch) RELAUNCH=1 ;;
    --access) want_value=access ;;
    --access=*) ACCESS=${a#--access=}; ACCESS_SET=1 ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --resume-session) want_value=resume-session ;;
    --resume-session=*) RESUME_SESSION=${a#--resume-session=}; RESUME_SESSION_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --account-profile) want_value=account-profile ;;
    --account-profile=*) ACCOUNT_PROFILE=${a#--account-profile=}; ACCOUNT_PROFILE_SET=1 ;;
    --task-class) want_value='task-class' ;;
    --task-class=*) TASK_CLASS=${a#--task-class=}; TASK_CLASS_SET=1 ;;
    --backlog-title) want_value=backlog-title ;;
    --backlog-title=*) BACKLOG_TITLE=${a#--backlog-title=}; BACKLOG_TITLE_SET=1 ;;
    --exploration) EXPLORATION=deliberate ;;
    --allow-no-mistakes-without-reviewer-quota) ALLOW_NO_MISTAKES_WITHOUT_REVIEWER_QUOTA=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --traceparent) want_value=traceparent ;;
    --traceparent=*) TRACEPARENT_ARG=${a#--traceparent=}; TRACEPARENT_SET=1 ;;
    --routing-source) want_value=routing-source ;;
    --routing-source=*) ROUTING_SOURCE=${a#--routing-source=}; ROUTING_SOURCE_SET=1 ;;
    --telemetry-task-root) want_value=telemetry-task-root ;;
    --telemetry-task-root=*) TELEMETRY_TASK_ROOT=${a#--telemetry-task-root=} ;;
    --telemetry-parent) want_value=telemetry-parent ;;
    --telemetry-parent=*) TELEMETRY_PARENT=${a#--telemetry-parent=} ;;
    --dispatch-resolved) DISPATCH_RESOLVED=1 ;;
    --dispatch-tachikoma) DISPATCH_TACHIKOMA=1 ;;
    --dispatch-override-reason) want_value=dispatch-override-reason ;;
    --dispatch-override-reason=*) DISPATCH_OVERRIDE_REASON=${a#--dispatch-override-reason=}; DISPATCH_OVERRIDE_REASON_SET=1 ;;
    --dispatch-provider) want_value=dispatch-provider ;;
    --dispatch-provider=*) DISPATCH_PROVIDER=${a#--dispatch-provider=}; DISPATCH_PROVIDER_SET=1 ;;
    --dispatch-model-family) want_value=dispatch-model-family ;;
    --dispatch-model-family=*) DISPATCH_MODEL_FAMILY=${a#--dispatch-model-family=}; DISPATCH_MODEL_FAMILY_SET=1 ;;
    --matched-rule) want_value='matched-rule' ;;
    --matched-rule=*) MATCHED_RULE=${a#--matched-rule=}; MATCHED_RULE_SET=1 ;;
    --quota-decision) want_value=quota-decision ;;
    --quota-decision=*) QUOTA_DECISION=${a#--quota-decision=}; QUOTA_DECISION_SET=1 ;;
    --quota-headroom) want_value=quota-headroom ;;
    --quota-headroom=*) QUOTA_HEADROOM=${a#--quota-headroom=}; QUOTA_HEADROOM_SET=1 ;;
    --quota-runway) want_value=quota-runway ;;
    --quota-runway=*) QUOTA_RUNWAY=${a#--quota-runway=}; QUOTA_RUNWAY_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
# The opt-in router owns the complete tuple and its provenance, never a subset.
if [ "$DISPATCH_TACHIKOMA" -eq 1 ]; then
  if [ "$DISPATCH_RESOLVED" -eq 1 ] || [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 1 ] \
    || [ "$HARNESS_SET" -eq 1 ] || [ "$MODEL_SET" -eq 1 ] || [ "$EFFORT_SET" -eq 1 ] \
    || [ "$ACCOUNT_PROFILE_SET" -eq 1 ] || [ "$DISPATCH_PROVIDER_SET" -eq 1 ] \
    || [ "$DISPATCH_MODEL_FAMILY_SET" -eq 1 ] || [ "$ROUTING_SOURCE_SET" -eq 1 ] \
    || [ "$MATCHED_RULE_SET" -eq 1 ] || [ "$QUOTA_DECISION_SET" -eq 1 ] \
    || [ "$QUOTA_HEADROOM_SET" -eq 1 ] || [ "$QUOTA_RUNWAY_SET" -eq 1 ]; then
    echo "error: --dispatch-tachikoma cannot be combined with explicit routing axes or another attestation" >&2
    exit 1
  fi
  if [ "$KIND" = secondmate ] || [ "$RELAUNCH" -eq 1 ] || [ "$TASK_CLASS_SET" -eq 0 ]; then
    echo "error: --dispatch-tachikoma requires a fresh ordinary task and an explicit --task-class" >&2
    exit 1
  fi
fi
[ "$ACCESS_SET" -eq 0 ] || [ -n "$ACCESS" ] || { echo "error: --access requires a non-empty value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$RESUME_SESSION_SET" -eq 0 ] || [ -n "$RESUME_SESSION" ] || { echo "error: --resume-session requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$ACCOUNT_PROFILE_SET" -eq 0 ] || [ -n "$ACCOUNT_PROFILE" ] || { echo "error: --account-profile requires a non-empty value" >&2; exit 1; }
if [ "$ACCOUNT_PROFILE_SET" -eq 1 ] && ! fm_claude_account_profile_name_valid "$ACCOUNT_PROFILE"; then
  echo "error: --account-profile requires a safe profile name" >&2
  exit 1
fi
if [ "$ACCOUNT_PROFILE_SET" -eq 1 ] && [ "$KIND" = secondmate ]; then
  echo "error: --account-profile is home-local; run the account-profile mechanism inside that home" >&2
  exit 1
fi
[ "$TASK_CLASS_SET" -eq 0 ] || [ -n "$TASK_CLASS" ] || { echo "error: --task-class requires a non-empty value" >&2; exit 1; }
if [ "$BACKLOG_TITLE_SET" -eq 1 ]; then
  [ -n "$BACKLOG_TITLE" ] || { echo "error: --backlog-title requires a non-empty value" >&2; exit 1; }
  BACKLOG_TITLE_BYTES=$(fm_backlog_bytes_of_string "$BACKLOG_TITLE") || exit 1
  fm_backlog_control_bytes_valid 0 "$BACKLOG_TITLE_BYTES" || {
    echo "error: --backlog-title must not contain control bytes or newlines" >&2
    exit 1
  }
  [ -n "$(printf '%s' "$BACKLOG_TITLE" | tr -d '[:space:]')" ] || {
    echo "error: --backlog-title must contain a non-whitespace character" >&2
    exit 1
  }
fi
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
[ "$MODE_SET" -eq 0 ] || [ -n "$MODE" ] || { echo "error: --mode requires a non-empty value" >&2; exit 1; }
[ "$YOLO_SET" -eq 0 ] || [ -n "$YOLO" ] || { echo "error: --yolo requires a non-empty value" >&2; exit 1; }
[ "$TRACEPARENT_SET" -eq 0 ] || [ -n "$TRACEPARENT_ARG" ] || { echo "error: --traceparent requires a non-empty value" >&2; exit 1; }
[ "$ROUTING_SOURCE_SET" -eq 0 ] || [ -n "$ROUTING_SOURCE" ] || { echo "error: --routing-source requires a non-empty value" >&2; exit 1; }
case "$ROUTING_SOURCE" in
  ''|captain|profile|fallback|secondmate-config) ;;
  *) echo "error: --routing-source must be one of captain, profile, fallback, secondmate-config" >&2; fm_record_spawn_failure validation "--routing-source must be one of captain, profile, fallback, secondmate-config"; exit 1 ;;
esac
if [ "$ROUTING_SOURCE" = secondmate-config ] && [ "$KIND" != secondmate ]; then
  echo "error: --routing-source secondmate-config is valid only for --secondmate" >&2
  fm_record_spawn_failure validation "--routing-source secondmate-config is valid only for --secondmate"
  exit 1
fi
[ -z "$TELEMETRY_TASK_ROOT" ] || printf '%s' "$TELEMETRY_TASK_ROOT" | grep -Eq '^mrt_[0-9a-f-]{36}$' || { echo "error: --telemetry-task-root requires an opaque mrt UUID" >&2; exit 1; }
[ -z "$TELEMETRY_PARENT" ] || printf '%s' "$TELEMETRY_PARENT" | grep -Eq '^mra_[0-9a-f-]{36}$' || { echo "error: --telemetry-parent requires an opaque mra UUID" >&2; exit 1; }
[ -z "$TELEMETRY_PARENT" ] || [ -n "$TELEMETRY_TASK_ROOT" ] || { echo "error: --telemetry-parent requires --telemetry-task-root" >&2; exit 1; }
[ "$DISPATCH_OVERRIDE_REASON_SET" -eq 0 ] || [ -n "$DISPATCH_OVERRIDE_REASON" ] || { echo "error: --dispatch-override-reason requires a non-empty value" >&2; exit 1; }
[ "$DISPATCH_PROVIDER_SET" -eq 0 ] || [ -n "$DISPATCH_PROVIDER" ] || { echo "error: --dispatch-provider requires a non-empty value" >&2; exit 1; }
[ "$DISPATCH_MODEL_FAMILY_SET" -eq 0 ] || [ -n "$DISPATCH_MODEL_FAMILY" ] || { echo "error: --dispatch-model-family requires a non-empty value" >&2; exit 1; }
[ "$MATCHED_RULE_SET" -eq 0 ] || [ -n "$MATCHED_RULE" ] || { echo "error: --matched-rule requires a non-empty value" >&2; fm_record_spawn_failure validation "--matched-rule requires a non-empty value"; exit 1; }
if [ -n "$MATCHED_RULE" ] && [[ ! $MATCHED_RULE =~ ^(default|rule-[0-9]+)$ ]]; then
  echo "error: --matched-rule must be 'default' or 'rule-<n>'" >&2
  fm_record_spawn_failure validation "--matched-rule must be 'default' or 'rule-<n>'"
  exit 1
fi
[ "$QUOTA_DECISION_SET" -eq 0 ] || [ -n "$QUOTA_DECISION" ] || { echo "error: --quota-decision requires a non-empty value" >&2; fm_record_spawn_failure validation "--quota-decision requires a non-empty value"; exit 1; }
case "$QUOTA_DECISION" in
  ''|selected|stopped|not-applicable|unknown) ;;
  *) echo "error: --quota-decision must be one of selected, stopped, not-applicable, unknown" >&2; fm_record_spawn_failure validation "--quota-decision must be one of selected, stopped, not-applicable, unknown"; exit 1 ;;
esac
[ "$QUOTA_HEADROOM_SET" -eq 0 ] || [ -n "$QUOTA_HEADROOM" ] || { echo "error: --quota-headroom requires a non-empty value" >&2; fm_record_spawn_failure validation "--quota-headroom requires a non-empty value"; exit 1; }
case "$QUOTA_HEADROOM" in
  ''|sufficient|tight|exhausted|unmeasurable|unknown) ;;
  *) echo "error: --quota-headroom must be one of sufficient, tight, exhausted, unmeasurable, unknown" >&2; fm_record_spawn_failure validation "--quota-headroom must be one of sufficient, tight, exhausted, unmeasurable, unknown"; exit 1 ;;
esac
[ "$QUOTA_RUNWAY_SET" -eq 0 ] || [ -n "$QUOTA_RUNWAY" ] || { echo "error: --quota-runway requires a non-empty value" >&2; fm_record_spawn_failure validation "--quota-runway requires a non-empty value"; exit 1; }
case "$QUOTA_RUNWAY" in
  ''|sufficient|tight|exhausted|unmeasurable|unknown) ;;
  *) echo "error: --quota-runway must be one of sufficient, tight, exhausted, unmeasurable, unknown" >&2; fm_record_spawn_failure validation "--quota-runway must be one of sufficient, tight, exhausted, unmeasurable, unknown"; exit 1 ;;
esac
case "$DISPATCH_OVERRIDE_REASON" in
  *$'\n'*) echo "error: --dispatch-override-reason must be a single line - state/<id>.meta is one key=value per line and every reader takes the LAST match, so an embedded newline would forge a later worktree=, backend=, or kind= line" >&2; exit 1 ;;
esac
case "$DISPATCH_PROVIDER$DISPATCH_MODEL_FAMILY" in
  *$'\n'*) echo "error: dispatch provider and model family must each be a single line" >&2; exit 1 ;;
esac
# Dispatch attestation backstop (AGENTS.md section 4): when config/crew-dispatch.json
# is active, a crewmate/scout spawn must declare HOW its explicit harness was
# chosen. --dispatch-resolved attests the profiles were consulted; --dispatch-override-reason
# records a deliberate departure. Passing both is ambiguous. The guard checks that
# resolution HAPPENED, not what it produced, and never reads crew-dispatch.json to
# verify the harness matches (that would be a second resolver). Secondmate spawns
# are exempt: they resolve the secondmate harness, not the crew dispatch profiles.
if [ -f "$CONFIG/crew-dispatch.json" ] && [ "$KIND" != secondmate ]; then
  if [ "$DISPATCH_RESOLVED" -eq 1 ] && [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 1 ]; then
    echo "error: config/crew-dispatch.json is active - pass exactly one of --dispatch-resolved or --dispatch-override-reason, not both (a dispatch is either resolved through the profiles or a deliberate override, never both)" >&2
    exit 1
  fi
fi
# A parent-delivered carrier replaces this home's own resolution, so it is
# refused unless it is a secondmate spawn carrying a strictly valid W3C value.
# Nothing else may reach the pane's TRACEPARENT export.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  [ "$KIND" = secondmate ] || {
    echo "error: --traceparent applies only to --secondmate spawns; every other spawn resolves its own carrier from this home's frozen trace-context decision" >&2
    exit 1
  }
  fm_trace_context_valid "$TRACEPARENT_ARG" || {
    echo "error: --traceparent is not a valid W3C traceparent" >&2
    exit 1
  }
fi
case "$MODEL" in
  # Same sentinel on the model axis: leaving the literal through would record a
  # second spelling of one tuple in the routing ledger (tuple.model="default"
  # beside the null an omitted axis writes), which the rotation precondition
  # reads as two different attempts.
  default) MODEL= ;;
esac
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  # "default" is how the task meta spells an unset effort, so normalize it back
  # to unset here rather than carrying a sentinel through every downstream
  # effort check (remote secondmate validation, the per-harness flag builder).
  default) EFFORT= ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max, or default" >&2; exit 1 ;;
esac
case "$TASK_CLASS" in
  rote-reversible-edit|bounded-implementation-proven-root-fix|unknown-root-diagnosis|adversarial-review-security-review|evidence-heavy-research|long-horizon-repository-work|visual-browser-sensitive-work|documentation-specification-decision-extraction|external-wait-integration-work|unresolved) ;;
  *) echo "error: --task-class is not a recognized model telemetry class" >&2; exit 1 ;;
esac

# --relaunch reuses an existing task's endpoint, worktree, project, kind, and
# access, so every axis this block resolves for a fresh spawn instead comes from
# that task's own durable record below. Contradicting it on the command line is a
# refusal rather than a silently-ignored flag.
if [ "$RELAUNCH" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded backend; --backend cannot override it" >&2; exit 1; }
  [ "$KIND_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded kind; --scout/--secondmate cannot override it" >&2; exit 1; }
  [ "$MODE_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it" >&2; exit 1; }
  [ "$YOLO_SET" -eq 0 ] || { echo "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it" >&2; exit 1; }
else
  # Delivery contract (AGENTS.md section 7). A ship task's mode and yolo are
  # firstmate's per-task decision, so they are required and closed-set validated
  # here rather than resolved from the project registry. Scouts deliver a report
  # and record no delivery posture; secondmate spawns hardcode theirs.
  if [ "$KIND" = ship ]; then
    [ "$MODE_SET" -eq 1 ] || {
      echo "error: ship spawns require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 1 ] || {
      echo "error: ship spawns require --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
      exit 1
    }
    case "$MODE" in
      no-mistakes|direct-PR|local-only) ;;
      no-mistakes-prod-only)
        echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
        exit 1 ;;
      *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
    esac
    case "$YOLO" in
      on|off) ;;
      *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
    esac
  else
    [ "$MODE_SET" -eq 0 ] || {
      echo "error: --mode applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 0 ] || {
      echo "error: --yolo applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
  fi
fi
if [ "$BACKLOG_TITLE_SET" -eq 1 ]; then
  [ "$RELAUNCH" -eq 0 ] || {
    echo "error: --backlog-title applies only to fresh ship or scout spawns; relaunch reuses its existing backlog item" >&2
    exit 1
  }
  [ "$KIND" = ship ] || [ "$KIND" = scout ] || {
    echo "error: --backlog-title applies only to ship or scout spawns" >&2
    exit 1
  }
fi
[ "$RESUME_SESSION_SET" -eq 0 ] || [ "$RELAUNCH" -eq 1 ] || {
  echo "error: --resume-session requires --relaunch for an existing task" >&2
  exit 1
}
# Reader/writer access axis (scouts only): closed-set validated here so an
# unknown value or a misapplied kind refuses before any fleet mutation.
# A --relaunch does not yet know the recorded kind, so the scout-only check
# waits until that record is adopted below rather than testing the default
# KIND=ship.
case "$ACCESS" in
  reader|writer) ;;
  *) echo "error: --access must be reader or writer (got '$ACCESS')" >&2; exit 1 ;;
esac
if [ "$RELAUNCH" -eq 0 ] && [ "$ACCESS_SET" -eq 1 ] && [ "$KIND" != scout ]; then
  echo "error: --access applies only to scout spawns; a ship delivers a project change through an isolated worktree and a secondmate operates its own home" >&2
  exit 1
fi
if [ "$ALLOW_NO_MISTAKES_WITHOUT_REVIEWER_QUOTA" -eq 1 ] && { [ "$KIND" != ship ] || [ "$MODE" != no-mistakes ]; }; then
  echo "error: --allow-no-mistakes-without-reviewer-quota applies only to a no-mistakes ship" >&2
  exit 1
fi

if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  # Resolve once at intake and export the same instance to the launched worker.
  # An explicit operator NM_HOME remains authoritative; otherwise this home owns
  # its private root, including the reviewer preflight below.
  case "${NM_HOME:-}" in
    *$'\n'*|*$'\r'*)
      echo "error: NM_HOME must be a single line for state/<id>.meta" >&2
      exit 1
      ;;
  esac
  RESOLVED_NM_HOME=$(fm_nm_home) || exit 1
  case "$RESOLVED_NM_HOME" in
    *$'\n'*|*$'\r'*)
      echo "error: NM_HOME must be a single line for state/<id>.meta" >&2
      exit 1
      ;;
  esac
  fm_nm_prepare_home || exit 1
  NM_HOME=$RESOLVED_NM_HOME
  export NM_HOME
  # Bind the resolved root durably per task so crew-state and teardown observe
  # the exact root this worker uses, never the legacy shared root (finding 2).
  NM_HOME_BOUND=1
fi

no_mistakes_configured_reviewers() {
  local config
  config="$NM_HOME/config.yaml"
  if [ ! -r "$config" ]; then
    printf 'auto\n'
    return 0
  fi
  awk '
    function emit(value, count, i, item, parts) {
      sub(/^[[:space:]]*\[/, "", value)
      sub(/\][[:space:]]*$/, "", value)
      count = split(value, parts, ",")
      for (i = 1; i <= count; i++) {
        item = parts[i]
        sub(/^[[:space:]]+/, "", item)
        sub(/[[:space:]]+$/, "", item)
        quote = substr(item, 1, 1)
        if ((quote == "\"" || quote == sprintf("%c", 39)) \
            && substr(item, length(item), 1) == quote) {
          item = substr(item, 2, length(item) - 2)
        }
        if (item != "") print item
      }
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*agent[[:space:]]*:/ {
      value = $0
      sub(/^[[:space:]]*agent[[:space:]]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      if (value != "") {
        emit(value)
        found = 1
        exit
      }
      in_agent = 1
      next
    }
    in_agent && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      emit(value)
      found = 1
      next
    }
    in_agent && /^[^[:space:]]/ { exit }
    END { if (!found) print "auto" }
  ' "$config"
}

no_mistakes_reviewer_quota_preflight() {
  local reviewer provider result quota_json details_text detail
  local eligible=0 uncertain=0
  local -a reviewers details
  while IFS= read -r reviewer; do
    [ -n "$reviewer" ] && reviewers+=("$reviewer")
  done < <(no_mistakes_configured_reviewers)

  quota_json=
  if command -v quota-axi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    quota_json=$(quota-axi --json 2>/dev/null) || quota_json=
  fi

  for reviewer in "${reviewers[@]}"; do
    case "$reviewer" in
      claude|codex|cursor|copilot|grok|kimi) provider=$reviewer ;;
      *) provider= ;;
    esac
    if [ -z "$provider" ] || [ -z "$quota_json" ]; then
      result=unmeasurable
    else
      result=$(printf '%s\n' "$quota_json" | jq -r --arg provider "$provider" '
        ((.providers // []) | map(select(.provider == $provider)) | first) as $provider_row |
        if $provider_row == null then
          "unmeasurable"
        else
          (($provider_row.quotaSemantics.effectiveAvailability // []) |
            map(select(.scope == "all_models" and .status == "known")) | first) as $availability |
          if $availability == null or ($availability.effectivePercentRemaining | type) != "number" then
            "unmeasurable"
          elif $availability.effectivePercentRemaining == 0 then
            "exhausted"
          else
            "usable"
          end
        end
      ' 2>/dev/null) || result=unmeasurable
    fi
    details+=("$reviewer=$result")
    case "$result" in
      usable) eligible=1 ;;
      unmeasurable) eligible=1; uncertain=1 ;;
    esac
  done

  details_text=
  for detail in "${details[@]}"; do
    [ -z "$details_text" ] || details_text="$details_text, "
    details_text="$details_text$detail"
  done
  if [ "$eligible" -eq 1 ]; then
    if [ "$uncertain" -eq 1 ]; then
      echo "warn: no-mistakes reviewer quota preflight checked $details_text; unmeasurable quota remains eligible" >&2
    fi
    return 0
  fi
  if [ "$ALLOW_NO_MISTAKES_WITHOUT_REVIEWER_QUOTA" -eq 1 ]; then
    echo "warn: captain-authorized reviewer-quota override allows no-mistakes ship after checking $details_text" >&2
    return 0
  fi
  echo "error: refusing no-mistakes ship because no configured reviewer has usable quota; checked $details_text; pass --allow-no-mistakes-without-reviewer-quota only with captain authorization" >&2
  return 1
}

if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  case "${POS[0]:-}" in
    *=*) : ;;
    *) no_mistakes_reviewer_quota_preflight || exit 1 ;;
  esac
fi
if [ "$EXPLORATION" = deliberate ]; then
  [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ] && [ "$TASK_CLASS" = bounded-implementation-proven-root-fix ] || {
    echo "error: --exploration requires a no-mistakes ship classified as bounded-implementation-proven-root-fix" >&2
    exit 1
  }
  [ "$MODEL_SET" -eq 1 ] && [ -n "$MODEL" ] && [ "$EFFORT_SET" -eq 1 ] && [ -n "$EFFORT" ] || {
    echo "error: --exploration requires explicit --model and --effort values" >&2
    exit 1
  }
fi

spawn_remote_secondmate() {
  local id=$1 remote host root home harness positional model effort backend out rc meta tmp
  local remote_backend remote_target remote_harness remote_herdr_session registry_lock remote_lock remote_generation
  local remote_traceparent remote_recorded_traceparent sm_primary_head sync_out sync_rc
  local -a launch_args
  id=${POS[0]:-}
  fm_task_id_creation_valid "$id" || { echo "error: invalid task id" >&2; return 2; }
  mkdir -p "$STATE" || { echo "error: could not create parent state directory" >&2; return 1; }
  SPAWN_TASK_LOCK="$STATE/.spawn-$id.lock"
  if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    echo "error: another spawn is already creating task $id" >&2
    return 1
  fi
  registry_lock=$(secondmate_registry_lock_path "$STATE")
  if ! fm_lock_acquire_wait "$registry_lock"; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: secondmate registry could not be locked for remote spawn" >&2
    return 1
  fi
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  if [ "$remote" != 1 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 3
  fi
  host=$(secondmate_registry_field "$DATA/secondmates.md" "$id" host)
  root=$(secondmate_registry_field "$DATA/secondmates.md" "$id" root)
  home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home)
  positional=${POS[1]:-}
  if [ "${#POS[@]}" -gt 2 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate spawn accepts no local home positional argument" >&2
    return 2
  fi
  if [ -n "$HARNESS_ARG" ]; then
    harness=$HARNESS_ARG
  elif [ -n "$positional" ]; then
    harness=$positional
  else
    harness=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
  fi
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor-agent) ;;
    *)
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: remote secondmate spawn requires a verified harness adapter, not a raw launch command: $harness" >&2
      return 1
      ;;
  esac
  if ! "$FM_ROOT/bin/fm-harness.sh" validate "$harness"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  fi
  model=${MODEL:--}
  effort=${EFFORT:--}
  if [ -z "$HARNESS_ARG" ] && [ -z "$positional" ]; then
    if [ "$MODEL_SET" -eq 0 ]; then
      model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
      [ -n "$model" ] || model=-
    fi
    if [ "$EFFORT_SET" -eq 0 ]; then
      effort=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
      [ -n "$effort" ] || effort=-
    fi
  fi
  # A remote second mate always runs on Herdr: its server belongs to the host's
  # own GUI login session, so the endpoint outlives every SSH connection that
  # supervises it. bin/fm-remote-doctor.sh gates that host on the same
  # requirement, and the remote home's config/backend never overrides it.
  case "${BACKEND_ARG:--}" in
    -|herdr) backend=herdr ;;
    *)
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: a remote secondmate runs only on the herdr backend, not '$BACKEND_ARG'" >&2
      return 1
      ;;
  esac
  case "$effort" in
    -|low|medium|high|xhigh|max|ultra) ;;
    *)
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: invalid configured remote secondmate effort: $effort" >&2
      return 1
      ;;
  esac
  if [ "$effort" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  fi
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! fm_backlog_record_present "$meta" "task record" "$STATE" \
      || [ "$(fm_meta_get "$meta" kind)" != secondmate ] \
      || [ "$(fm_meta_get "$meta" remote_host)" != "$host" ] \
      || [ "$(fm_meta_get "$meta" remote_root)" != "$root" ] \
      || [ "$(fm_meta_get "$meta" home)" != "$home" ]; then
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: existing metadata for $id does not identify this remote secondmate route" >&2
      return 1
    fi
  fi
  # Gate the host before anything is published or transferred, so a host that
  # cannot hold a durable Herdr endpoint refuses here rather than half-way
  # through a launch. This is also the readiness gate every liveness relaunch
  # passes through, because recovery respawns through this same route.
  rc=0
  fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    # Summary first, then the doctor's own text: a caller that reports only the
    # first line, such as the startup liveness sweep, must still say something
    # actionable.
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id readiness could not be confirmed; preserved route $host:$home" >&2
    else
      echo "error: remote secondmate $id host $host is not ready for a remote second mate; launch refused" >&2
    fi
    [ -z "$FM_REMOTE_READINESS_OUT" ] || printf '%s\n' "$FM_REMOTE_READINESS_OUT" >&2
    [ "$rc" -ne 255 ] || return 255
    return 1
  fi
  # Pre-launch sync, the remote twin of the local-HEAD sync below: this home
  # follows THIS primary's default-branch commit, not the Firstmate copy on that
  # host, so the commit is resolved here and handed over for the host to import
  # and fast-forward to. A skipped sync warns and launches the home unchanged.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    if sync_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sync "$id" \
      "$sm_primary_head" < /dev/null 2>&1); then
      :
    else
      sync_rc=$?
      echo "warning: remote secondmate $id sync skipped before launch: $(remote_sync_failure_reason "$sync_rc" "$sync_out")" >&2
    fi
  else
    echo "warning: remote secondmate $id sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id")
  if ! fm_lock_acquire_wait "$remote_lock"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance transaction could not be locked" >&2
    return 1
  fi
  remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
  if [ -z "$remote_generation" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance generation could not be published" >&2
    return 1
  fi
  if "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" >/dev/null; then
    :
  else
    rc=$?
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id inheritance completion is unknown; launch refused and route preserved for reconciliation" >&2
    else
      echo "error: remote secondmate $id inheritance failed; launch refused" >&2
    fi
    return "$rc"
  fi
  # This parent home owns the remote secondmate's task identity because it holds
  # the task metadata an observer reads, exactly as for a local spawn: the
  # carrier is resolved against THIS task's own meta (reused verbatim on
  # relaunch, freshly rooted otherwise, never adopting this process's ambient
  # TRACEPARENT) under this home's frozen decision, then handed to the remote
  # host to export into the agent's pane. Disabled resolves to empty and the
  # remote launch call stays byte-identical to the untraced one.
  remote_traceparent=
  if [ "$(fm_trace_context_session_effective "$STATE/.trace-context-effective")" = on ]; then
    remote_traceparent=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$meta" || true)
  fi
  launch_args=("$id" "$harness" "$model" "$effort" "$backend")
  [ -z "$remote_traceparent" ] || launch_args+=("$remote_traceparent")
  if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh launch \
    "${launch_args[@]}" < /dev/null 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id is unavailable or launch completion is unknown; preserved route $host:$home" >&2
    fi
    return "$rc"
  fi
  remote_backend=$(printf '%s\n' "$out" | sed -n 's/^backend=//p' | tail -1)
  remote_target=$(printf '%s\n' "$out" | sed -n 's/^target=//p' | tail -1)
  remote_harness=$(printf '%s\n' "$out" | sed -n 's/^harness=//p' | tail -1)
  remote_herdr_session=$(printf '%s\n' "$out" | sed -n 's/^herdr_session=//p' | tail -1)
  if [ "$remote_backend" != herdr ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned backend '${remote_backend:-missing}', expected herdr; preserving the remote route for reconciliation" >&2
    return 1
  fi
  [ -n "$remote_target" ] && [ "$remote_harness" = "$harness" ] || {
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned malformed route metadata; preserving the remote route for reconciliation" >&2
    return 1
  }
  if [ "$remote_herdr_session" != fm-remote ] || [ "${remote_target%%:*}" != "$remote_herdr_session" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned Herdr session '${remote_herdr_session:-missing}', expected 'fm-remote'; preserving the remote route for reconciliation" >&2
    return 1
  fi
  # Record what the remote endpoint ACTUALLY carries, read back from its own
  # launch, rather than what this side hoped to deliver. That keeps the #995
  # guarantee that the recorded carrier is the identity the child received even
  # when the remote host already had a live agent and reused its endpoint. An
  # off decision delivers no carrier, but an endpoint already holding one still
  # reports it here so the parent does not deny the agent's actual identity.
  remote_recorded_traceparent=$(printf '%s\n' "$out" | sed -n 's/^traceparent=//p' | tail -1)
  fm_trace_context_valid "$remote_recorded_traceparent" || remote_recorded_traceparent=
  tmp="$meta.tmp.$$"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$home"
    echo "project=$root"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "tasktmp="
    echo "model=${model#-}"
    echo "effort=${effort#-}"
    echo "home=$home"
    echo "projects=$(secondmate_registry_field "$DATA/secondmates.md" "$id" projects)"
    echo "remote_host=$host"
    echo "remote_root=$root"
    echo "remote_backend=$remote_backend"
    echo "remote_herdr_session=$remote_herdr_session"
    echo "remote_target=$remote_target"
    [ -z "$remote_recorded_traceparent" ] || echo "traceparent=$remote_recorded_traceparent"
  } > "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
      SPAWN_TASK_SET_LOCK_HELD=0
      fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
    fi
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id launched, but its task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    return 1
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK"
  fi
  fm_lock_release "$remote_lock" || true
  fm_lock_release "$registry_lock" || true
  fm_lock_release "$SPAWN_TASK_LOCK" || true
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null; then
    echo "error: remote secondmate $id launched, but its reply source could not be armed; endpoint metadata is preserved" >&2
    return 1
  fi
  echo "spawned $id harness=$harness kind=secondmate mode=secondmate yolo=off window=remote:$id worktree=$home remote=$host backend=$remote_backend"
  return 0
}

BACKEND=
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
TREEHOUSE_ABORT_CLEANUP=0
TREEHOUSE_ACQUIRED_PATH=
TREEHOUSE_NEW_ALLOCATION=0
TREEHOUSE_LEASE=
TREEHOUSE_SLOT=
SPAWN_TREEHOUSE_LEASE_ERROR_FILE=
TREEHOUSE_ACQUISITION_LOCK="$STATE/.treehouse-acquisition.lock"
TREEHOUSE_ACQUISITION_LOCK_HELD=0
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_CONTROL_LOCK=
SPAWN_CONTROL_LOCK_HELD=0
SPAWN_CONTROL_PARENT=0
SPAWN_META_TMP=
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_FRESH_COMMIT_PENDING=0
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
SPAWN_TREEHOUSE_PROJECT_LOCK=
SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0

spawn_fresh_commit_rollback() {
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
      "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

spawn_abort_cleanup() {
  local status=$?
  [ -z "${SPAWN_TREEHOUSE_LEASE_ERROR_FILE:-}" ] || {
    rm -f -- "$SPAWN_TREEHOUSE_LEASE_ERROR_FILE" 2>/dev/null || true
    SPAWN_TREEHOUSE_LEASE_ERROR_FILE=
  }
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] \
     && [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] \
     && [ -n "$SPAWN_META_TMP" ] \
     && [ ! -e "$SPAWN_META_TMP" ] \
     && [ ! -L "$SPAWN_META_TMP" ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
        "$RELAUNCH_REPLACEMENT_HARNESS" \
        "$RELAUNCH_REPLACEMENT_WT" \
        "$RELAUNCH_REPLACEMENT_STATE" \
        "$ID"; then
      echo "warning: could not remove replacement wiring after aborted relaunch of $ID" >&2
    fi
    if [ -n "$RELAUNCH_REPLACEMENT_BUSY_GEN" ]; then
      if ! "$FM_ROOT/bin/fm-busy-event.sh" retire \
          "$RELAUNCH_REPLACEMENT_STATE" "$ID" \
          --gen "$RELAUNCH_REPLACEMENT_BUSY_GEN"; then
        echo "warning: could not retire replacement busy generation after aborted relaunch of $ID" >&2
      fi
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire \
      "${HERDR_PROJECTION_ABORT_SESSION:-}" "${FM_BACKEND_HERDR_ABORT_LOCK_ATTEMPTS:-50}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
          if ! spawn_fresh_commit_rollback; then
            status=1
          fi
          SPAWN_FRESH_COMMIT_PENDING=0
        fi
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          SPAWN_META_TMP="$STATE/.$ID.meta.orca-recovery.${BASHPID:-$$}"
          {
            echo "window=$W"
            echo "endpoint_task_id=$ID"
            echo "cleanup_recovery=orca"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            [ -z "${MODE:-}" ] || echo "mode=$MODE"
            [ -z "${YOLO:-}" ] || echo "yolo=$YOLO"
            echo "tasktmp=${OWNED_TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
          } > "$SPAWN_META_TMP" 2>/dev/null \
            && fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE" \
            || true
        fi
      fi
    fi
  fi
  if [ "$TREEHOUSE_ABORT_CLEANUP" = 1 ]; then
    TREEHOUSE_ABORT_CLEANUP=0
    if [ -n "$TREEHOUSE_ACQUIRED_PATH" ] \
       && [ -n "${TREEHOUSE_LEASE:-}" ] \
       && [ -n "${TREEHOUSE_HOLDER:-}" ]; then
      treehouse return --if-lease-id "$TREEHOUSE_LEASE" \
        --if-lease-holder "$TREEHOUSE_HOLDER" \
        "$TREEHOUSE_ACQUIRED_PATH" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$TREEHOUSE_ACQUISITION_LOCK_HELD" = 1 ]; then
    TREEHOUSE_ACQUISITION_LOCK_HELD=0
    fm_lock_release "$TREEHOUSE_ACQUISITION_LOCK" || true
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    if ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
  fi
  if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
    fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
  fi
  if [ "$SPAWN_CONTROL_LOCK_HELD" = 1 ]; then
    SPAWN_CONTROL_LOCK_HELD=0
    fm_lock_release "$SPAWN_CONTROL_LOCK" || true
  fi
  [ -z "$SPAWN_META_TMP" ] || rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
  fi
  spawn_timing_emit "$status"
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One bounded lock per live Herdr session/socket, shared across all homes.
# <session> is required so secondmate and primary spawns serialize against the
# same session without writing any other home's state directory.
spawn_herdr_presentation_order_lock_acquire() {  # [session] [max_attempts]
  local session=${1:-} max_attempts=${2:-50} lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  fm_backend_herdr_presentation_lock_acquire "$lock_path" "$max_attempts" || return 1
  HERDR_PRESENTATION_ORDER_LOCK_HELD=1
}

clear_relaunch_harness_wiring() {
  local harness=$1 wt=$2 state=$3 id=$4 token_path token auth_path path
  # The wiring arms above match on harness PREFIXES, because a task launched
  # from a raw command records that command's basename rather than the exact
  # adapter name. The retirement tables are keyed by the exact adapter, so the
  # recorded value is resolved to its adapter first; otherwise a task recorded
  # as, say, `grok-2` would have wiring armed and never retired. An
  # unrecognized value resolves to no adapter, which is also the case in which
  # no wiring was armed to begin with.
  harness=$(fm_control_harness_family "$harness") || harness=
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state" "$id") || return 1
  token=
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  auth_path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  if [ -n "$auth_path" ]; then
    rm -f -- "$auth_path" || return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_paths "$harness" "$wt" "$state" "$id")
EOF
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "$RELAUNCH" -eq 1 ] && [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ]; then
  echo "error: --relaunch is single-task only; relaunch each task explicitly" >&2
  exit 1
fi
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  [ "$RESUME_SESSION_SET" -eq 0 ] || { echo "error: --resume-session is single-task only" >&2; exit 1; }
  if [ "$KIND" != secondmate ] && [ "$DISPATCH_TACHIKOMA" -eq 0 ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    fm_record_spawn_failure validation "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)."
    exit 1
  fi
  # Attestation backstop: an explicit harness with no declaration of how it was
  # chosen is the silent hand-pick the explicit-harness guard exists to catch.
  # Require exactly one attestation; the mutual-exclusion check already ran above.
  if [ "$KIND" != secondmate ] && [ -n "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ] && [ "$DISPATCH_RESOLVED" -eq 0 ] && [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 0 ]; then
    echo "error: config/crew-dispatch.json is active - pass --dispatch-resolved (you consulted the profiles) or --dispatch-override-reason '<why>' (you departed deliberately); the rules cannot be silently skipped." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ "$ACCESS_SET" -eq 0 ] || shared_args+=(--access "$ACCESS")
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ "$TASK_CLASS_SET" -eq 0 ] || shared_args+=(--task-class "$TASK_CLASS")
  [ "$BACKLOG_TITLE_SET" -eq 0 ] || shared_args+=(--backlog-title "$BACKLOG_TITLE")
  [ "$EXPLORATION" = none ] || shared_args+=(--exploration)
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  [ "$ROUTING_SOURCE_SET" -eq 0 ] || shared_args+=(--routing-source "$ROUTING_SOURCE")
  # One delivery contract applies to every pair in a batch, exactly like the shared
  # harness. Each pair still re-validates it against its own brief, so a batch
  # spanning several modes is two invocations rather than a silent mixed dispatch.
  [ "$MODE_SET" -eq 0 ] || shared_args+=(--mode "$MODE")
  [ "$YOLO_SET" -eq 0 ] || shared_args+=(--yolo "$YOLO")
  [ "$ALLOW_NO_MISTAKES_WITHOUT_REVIEWER_QUOTA" -eq 0 ] || shared_args+=(--allow-no-mistakes-without-reviewer-quota)
  [ "$DISPATCH_RESOLVED" -eq 0 ] || shared_args+=(--dispatch-resolved)
  [ "$DISPATCH_TACHIKOMA" -eq 0 ] || shared_args+=(--dispatch-tachikoma)
  [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 0 ] || shared_args+=(--dispatch-override-reason "$DISPATCH_OVERRIDE_REASON")
  [ "$ACCOUNT_PROFILE_SET" -eq 0 ] || shared_args+=(--account-profile "$ACCOUNT_PROFILE")
  [ "$DISPATCH_PROVIDER_SET" -eq 0 ] || shared_args+=(--dispatch-provider "$DISPATCH_PROVIDER")
  [ "$DISPATCH_MODEL_FAMILY_SET" -eq 0 ] || shared_args+=(--dispatch-model-family "$DISPATCH_MODEL_FAMILY")
  [ "$MATCHED_RULE_SET" -eq 0 ] || shared_args+=(--matched-rule "$MATCHED_RULE")
  [ "$QUOTA_DECISION_SET" -eq 0 ] || shared_args+=(--quota-decision "$QUOTA_DECISION")
  [ "$QUOTA_HEADROOM_SET" -eq 0 ] || shared_args+=(--quota-headroom "$QUOTA_HEADROOM")
  [ "$QUOTA_RUNWAY_SET" -eq 0 ] || shared_args+=(--quota-runway "$QUOTA_RUNWAY")
  if [ -n "$TELEMETRY_TASK_ROOT" ] || [ -n "$TELEMETRY_PARENT" ]; then
    echo "error: linked telemetry identifiers are per-attempt and are not supported by batch dispatch" >&2
    exit 1
  fi
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
if [ "$RELAUNCH" -eq 0 ] && [ "$TASK_CLASS_SET" -eq 0 ] && { [ "$KIND" = ship ] || [ "$KIND" = scout ]; }; then
  echo "warning: --task-class absent; model telemetry records taskClass=unresolved" >&2
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
elif [ "$RELAUNCH" -eq 1 ]; then
  echo "error: spawn refused: state directory does not exist at $STATE" >&2
  exit 1
fi
spawn_timing_enable
# Role partition: spawning NEW work is MAIN-owned. A relaunch of an existing
# task is legitimate branch recovery (fm-control drives it through this same
# entrypoint), so only a fresh spawn refuses the branch actor (contract:
# bin/fm-lease-lib.sh; no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$RELAUNCH" -ne 1 ]; then
  fm_lease_forbid_branch "new-task spawn (fm-spawn)"
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_CONTROL_LOCK="$STATE/.control-$ID.lock"
  control_owner=$(cat "$SPAWN_CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
    SPAWN_CONTROL_PARENT=1
  elif [ "$(fm_lease_actor)" = branch ]; then
    # Role partition refinement: branch recovery relaunches only through the
    # fm-control transaction that owns the control lock, never by invoking
    # this entrypoint directly (contract: bin/fm-lease-lib.sh).
    echo "error: relaunch (fm-spawn) refused - the supervision branch must relaunch through fm-control" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  elif fm_lock_try_acquire "$SPAWN_CONTROL_LOCK"; then
    SPAWN_CONTROL_LOCK_HELD=1
  else
    fm_telemetry_record_wait "$ID" "$(fm_telemetry_task_attempt "$ID")" lock lifecycle-control open
    echo "error: another lifecycle action is already running for task $ID" >&2
    exit 1
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  mkdir -p "$STATE" || {
    echo "error: could not create parent state directory" >&2
    exit 1
  }
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  # A FRESH spawn changes which tasks this home has, so it must not interleave
  # with a forced teardown that has already enumerated that set: a record
  # published inside the enumerate-then-remove window is invisible to the
  # teardown's per-task preflight but visible to its cleanup, and gets mutated
  # while never lifecycle-locked (bin/fm-wake-lib.sh's fm_task_set_lock_path
  # owns the evidence; bin/fm-teardown.sh holds the same lock from enumeration
  # through cleanup). Taken before this task's own locks, matching the
  # acquisition order documented there, and held through publication.
  #
  # A relaunch is exempt: it republishes a task that already exists, so it is
  # already covered by that task's control lock, which the teardown preflight
  # tests.
  #
  # Refusing rather than waiting is the fail-closed direction: the home may be
  # moments from removal, so there is nothing worth waiting for.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
    echo "error: could not resolve the task-set lock for $STATE" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK"; then
    fm_telemetry_record_wait "$ID" "$(fm_telemetry_task_attempt "$ID")" lock task-set open
    echo "error: this home's task set is locked by another operation (a forced teardown is enumerating or removing its tasks); refusing to create task $ID rather than racing it" >&2
    exit 1
  fi
  SPAWN_TASK_SET_LOCK_HELD=1
fi
if [ "$KIND" = secondmate ]; then
  if spawn_remote_secondmate "$ID"; then
    exit 0
  else
    remote_spawn_rc=$?
  fi
  [ "$remote_spawn_rc" -eq 3 ] || exit "$remote_spawn_rc"
fi
# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown,
# disabled, or non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$RELAUNCH" -eq 0 ]; then
  if [ "$BACKEND_SET" -eq 1 ]; then
    BACKEND=$BACKEND_ARG
  else
    BACKEND=$(fm_backend_name) || exit 1
  fi
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=orca does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=cmux does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = orca ] && [ "$ACCESS" = reader ]; then
    echo "error: backend=orca does not support --access reader yet; orca allocates a managed worktree per task, which is exactly the allocation a reader avoids" >&2
    exit 1
  fi
  if [ "$BACKEND" = orca ]; then
    fm_backend_orca_runtime_check || exit 1
  fi
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
PROJ=
PROJECT_REPO=
ARG3=
FIRSTMATE_HOME=
RAW_LAUNCH=0

# --relaunch adoption: every identity axis comes from the task's own validated
# durable record, never from the command line, so a relaunch can only ever
# re-launch the task it names. The endpoint identity check is the same shared
# validation teardown uses, so a malformed, ambiguous, or foreign record
# refuses here exactly as it refuses there.
RELAUNCH_PRIOR_HARNESS=
if [ "$RELAUNCH" -eq 1 ]; then
  [ "${#POS[@]}" -eq 1 ] || {
    echo "error: --relaunch takes the task id only; its project or home comes from the task's own record" >&2
    exit 1
  }
  RELAUNCH_META="$STATE/$ID.meta"
  if [ ! -e "$RELAUNCH_META" ] && [ ! -L "$RELAUNCH_META" ]; then
    echo "error: --relaunch needs an existing task record; no $RELAUNCH_META" >&2
    exit 1
  fi
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  SPAWN_META_LOCK=$(fm_meta_lock_path "$RELAUNCH_META") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  fm_backend_validate_task_endpoint "$RELAUNCH_META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  RELAUNCH_TARGET=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  # A relaunch must PROVE the previous agent is gone before it launches another
  # one into the same endpoint, and only tmux and herdr have a recovery-grade
  # classifier that can (bin/fm-control-lib.sh owns that capability table).
  fm_control_backend_state_verified "$BACKEND" || {
    echo "error: backend '$BACKEND' has no recovery-grade agent-state classifier, so a relaunch cannot prove the previous agent exited; refusing rather than risking two agents in one endpoint" >&2
    exit 1
  }
  RELAUNCH_STATE=$(fm_backend_agent_state "$BACKEND" "$RELAUNCH_TARGET")
  [ "$RELAUNCH_STATE" = dead ] || {
    echo "error: task $ID's endpoint reads '$RELAUNCH_STATE'; a relaunch requires a positively agent-free endpoint (stop the agent first with bin/fm-control.sh $ID exit)" >&2
    exit 1
  }
  RELAUNCH_PRIOR_HARNESS=$(fm_meta_get "$RELAUNCH_META" harness)
  KIND=$(fm_meta_get "$RELAUNCH_META" kind)
  [ -n "$KIND" ] || KIND=ship
  MODE=$(fm_meta_get "$RELAUNCH_META" mode)
  YOLO=$(fm_meta_get "$RELAUNCH_META" yolo)
  if ! RELAUNCH_ACCESS=$(fm_meta_optional_exact_value "$RELAUNCH_META" access); then
    echo "error: existing task $ID records ambiguous access metadata; expected exactly zero or one non-empty access= value - repair $RELAUNCH_META before relaunching so a duplicate axis cannot launder a writer pool lease into a reader scratch record" >&2
    exit 1
  fi
  if [ "$ACCESS_SET" -eq 0 ]; then
    case "$RELAUNCH_ACCESS" in
      ''|writer) ACCESS=writer ;;
      reader) ACCESS=reader ;;
      *)
        echo "error: existing task $ID records unknown access '$RELAUNCH_ACCESS'; this is record damage - repair $RELAUNCH_META before relaunching so the damaged axis cannot be laundered into a clean writer or reader record" >&2
        exit 1
        ;;
    esac
  fi
  if [ "$ACCESS_SET" -eq 1 ] && [ "$KIND" != scout ]; then
    echo "error: --access applies only to scout spawns; a ship delivers a project change through an isolated worktree and a secondmate operates its own home" >&2
    exit 1
  fi
  if [ "$RESUME_SESSION_SET" -eq 1 ]; then
    [ "$MODEL_SET" -eq 1 ] || MODEL=$(fm_meta_get "$RELAUNCH_META" model)
    [ "$EFFORT_SET" -eq 1 ] || EFFORT=$(fm_meta_get "$RELAUNCH_META" effort)
  fi
  RELAUNCH_WT=$(fm_meta_get "$RELAUNCH_META" worktree)
  [ -n "$RELAUNCH_WT" ] && [ -d "$RELAUNCH_WT" ] || {
    echo "error: task $ID's recorded worktree '${RELAUNCH_WT:-none}' is missing; refusing to relaunch without the local copy its work lives in" >&2
    exit 1
  }
  if [ "$KIND" = secondmate ]; then
    FIRSTMATE_HOME=$(fm_meta_get "$RELAUNCH_META" home)
    [ -n "$FIRSTMATE_HOME" ] || FIRSTMATE_HOME=$RELAUNCH_WT
  else
    PROJ=$(fm_meta_get "$RELAUNCH_META" project)
    [ -n "$PROJ" ] || {
      echo "error: task $ID has no recorded project; refusing to relaunch" >&2
      exit 1
    }
  fi
  if [ "$BACKEND" = herdr ]; then
    HERDR_SES=$(fm_meta_get "$RELAUNCH_META" herdr_session)
    HERDR_WORKSPACE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_workspace_id)
    HERDR_TAB_ID=$(fm_meta_get "$RELAUNCH_META" herdr_tab_id)
    HERDR_PANE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_pane_id)
  fi
  # With no explicit harness, a relaunch reuses the harness already recorded
  # for this task. It must NOT fall through to the fresh-spawn config
  # resolution, which would silently move an existing task onto whatever the
  # crew or secondmate default currently says. Choosing a different harness is
  # the caller's explicit decision, made with --harness (bin/fm-control.sh
  # resolves that decision, including a secondmate's durable pin).
  ARG3=${HARNESS_ARG:-$RELAUNCH_PRIOR_HARNESS}
  [ -n "$ARG3" ] || {
    echo "error: task $ID has no recorded harness; pass --harness to relaunch it" >&2
    exit 1
  }
elif [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|cursor-agent)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG
if [ "$DISPATCH_TACHIKOMA" -eq 1 ]; then
  [ -z "$ARG3" ] || { echo "error: --dispatch-tachikoma cannot override a positional harness" >&2; exit 1; }
  TACHIKOMA_ROUTE=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tachikoma.sh" route \
    --task "$ID" --class "$TASK_CLASS" --repo "$(basename "$PROJ")" --brief "$DATA/$ID/brief.md" --require-enabled) || exit "$?"
  ARG3=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.harness')
  MODEL=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.model')
  EFFORT=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -r '.effort // empty')
  MODEL_SET=1
  [ -z "$EFFORT" ] || EFFORT_SET=1
  ACCOUNT_PROFILE=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -r '.accountProfile // empty')
  [ -z "$ACCOUNT_PROFILE" ] || ACCOUNT_PROFILE_SET=1
  DISPATCH_PROVIDER=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.provider')
  DISPATCH_MODEL_FAMILY=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.modelFamily')
  MATCHED_RULE=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.matchedRule')
  TACHIKOMA_DECISION=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -er '.decisionId')
  DISPATCH_RESOLVED=1
  DISPATCH_PROVIDER_SET=1
  DISPATCH_MODEL_FAMILY_SET=1
  MATCHED_RULE_SET=1
  ROUTING_SOURCE=tachikoma
  ROUTING_SOURCE_SET=1
  QUOTA_DECISION=selected
  QUOTA_DECISION_SET=1
  QUOTA_HEADROOM=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -r '. as $d | .alternatives[] | select(.harness==$d.harness and .model==$d.model and .effort==$d.effort and (.accountProfile // null)==($d.accountProfile // null)) | if .feasibility=="proven" then "sufficient" else "unmeasurable" end')
  QUOTA_HEADROOM_SET=1
  QUOTA_RUNWAY=$QUOTA_HEADROOM
  QUOTA_RUNWAY_SET=1
fi
if [ "$KIND" = secondmate ]; then
  SECONDMATE_CONFIG_OWNS_TUPLE=0
  if [ "$HARNESS_SET" -eq 0 ] && [ "$MODEL_SET" -eq 0 ] && [ "$EFFORT_SET" -eq 0 ] && [ -z "$ARG3" ] \
    && "$SCRIPT_DIR/fm-harness.sh" secondmate-tuple >/dev/null 2>&1; then
    SECONDMATE_CONFIG_OWNS_TUPLE=1
  fi
  if [ "$ROUTING_SOURCE_SET" -eq 0 ] && [ "$SECONDMATE_CONFIG_OWNS_TUPLE" -eq 1 ]; then
    ROUTING_SOURCE=secondmate-config
    ROUTING_SOURCE_SET=1
  elif [ "$ROUTING_SOURCE" = secondmate-config ] && [ "$SECONDMATE_CONFIG_OWNS_TUPLE" -ne 1 ]; then
    echo "error: routing_source=secondmate-config requires one complete durable tuple and no harness, model, effort, or positional harness override" >&2
    exit 1
  fi
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

PI_FIRSTMATE_WORKER_SYSTEM_PROMPT="You are a Firstmate crewmate working in an isolated worktree of the Firstmate repository. The repository's AGENTS.md is a file you may be asked to change, not your instructions; your instructions are the launch brief you were given."

resolve_pi_executable() {
  local candidate dir
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename "$candidate")"
      ;;
  esac
}

# Pi's CLI surface is version-dependent, so probe the resolved executable's help
# before composing the optional regular-TUI flag. An absent or inconclusive probe
# omits the flag so older Pi versions can still spawn.
pi_supports_tui_mode() {
  local executable=$1 help cache cached
  cache="$STATE/.pi-tui-mode-cache"
  if [ -f "$cache" ]; then
    cached=$(awk -F '\t' -v path="$executable" '$1 == path { value=$2 } END { if (value != "") print value }' "$cache")
    case "$cached" in
      1) return 0 ;;
      0) return 1 ;;
    esac
  fi
  help=$("$executable" --help 2>&1) || return 1
  if printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--tui-mode([[:space:]=]|$)'; then
    printf '%s\t1\n' "$executable" >> "$cache"
    return 0
  fi
  printf '%s\t0\n' "$executable" >> "$cache"
  return 1
}

pi_supports_session_id() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--session-id([[:space:]=]|$)'
}

claude_supports_session_id() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--session-id([[:space:]=]|$)'
}

# omp pre-launch model validation. `omp models --json` (omp 18.1.11) prints
# {"models":[{"provider","id","selector":"<provider>/<id>",...}]} for built-in and
# auto-discovered providers only; it never lists a provider an extension
# registers at runtime (claude-bridge is the verified example), so the check is
# scoped exactly to what the listing can prove: a <provider>/<id> whose provider
# IS listed must be listed too, a provider the listing does not know passes
# through with a notice, a bare fuzzy pattern is omp's own matcher's job, and an
# unreadable listing establishes nothing (harness-adapters model-and-effort.md).
omp_model_validate() {  # <omp-bin> <model>
  local bin=$1 model=$2 provider listing providers
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$model" in */*) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  listing=$(OMP_SKIP_SETUP=1 "$bin" models --json 2>/dev/null) || return 0
  providers=$(printf '%s' "$listing" | jq -r '.models[]?.provider // empty' 2>/dev/null | sort -u) || return 0
  [ -n "$providers" ] || return 0
  provider=${model%%/*}
  if ! printf '%s\n' "$providers" | grep -qxF -- "$provider"; then
    echo "notice: omp provider '$provider' is not in 'omp models --json' (extension-registered providers are never listed); launching '$model' unvalidated" >&2
    return 0
  fi
  if printf '%s' "$listing" | jq -e --arg m "$model" '.models[]? | select(.selector == $m)' >/dev/null 2>&1; then
    return 0
  fi
  echo "error: omp model '$model' is not listed by 'omp models --json' although provider '$provider' is; choose a listed <provider>/<id> or omit --model" >&2
  return 1
}

# The verified launch command per adapter. The knowledge half of each adapter
# (busy-state source, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship} access=${3:-writer}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    # Two independent controls disable claude's `/bug`/`/feedback` model-drafted
    # feedback flow (the SendFeedback tool), deliberately layered so a fleet-launched
    # agent never queues or submits a bug-report draft on the captain's behalf even
    # under a managed Claude settings policy: CLAUDE_CODE_SEND_FEEDBACK=0 is read
    # directly and is not subject to managed-settings precedence, while --settings
    # '{"feedbackDrafts":"off"}' sets the documented settings key (Claude Code
    # changelog 2.1.247) that a managed policy CAN override back on. Either control
    # alone disables the feature; keep both so a managed override of one still
    # leaves the other in force. Both are per-launch, scoped to this invocation only,
    # and never touch the captain's global ~/.claude/settings.json.
    # The same inline --settings JSON also carries the attribution policy
    # ("attribution": {"commit": "", "pr": "", "sessionUrl": false}), which
    # suppresses Claude Code's Co-Authored-By trailer, Claude-Session link, and
    # generated-with line in commits and PR bodies. The captain sets that
    # policy in the `user` settings scope, but a launched worker's settings
    # sources are not guaranteed to load that scope, so a worker would
    # otherwise run with attribution back on; carrying it per launch keeps the
    # policy in force regardless of which settings scopes end up loaded.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}'\'' __MODELFLAG____EFFORTFLAG____CLAUDESESSIONFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __RESUME____MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox __SESSION__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __RESUME____MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" __SESSION__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi|pi-signed)
      printf '%s' '__PIBIN____PITUIMODE__'
      if [ "$kind" = secondmate ]; then
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' ' __MODELFLAG____EFFORTFLAG____PIWORKERCONTEXT____PISESSIONFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # omp (Oh My Pi), a Pi fork. Same one-positional-brief, --model, --thinking,
    # and -e shape as Pi, verified on omp 18.1.11. The differences are all at
    # the launch boundary and documented in the header above: foreign markers
    # cleared (omp has none of its own, so an inherited CLAUDECODE would win),
    # FM_OMP_HARNESS=omp established for bin/fm-harness.sh, OMP_SKIP_SETUP=1
    # against the fresh-profile provider wizard, --auto-approve so no approval
    # prompt can park an unattended worker, the tracked posture overlay so a
    # captain-level plan, prewalk, or usage dialog cannot either, and --cwd
    # pinned to the worktree because omp's extension discovery is cwd-only. A
    # secondmate loads its two primary extensions by that discovery alone:
    # naming them with -e as well loads each twice (verified), doubling every
    # session_stop continuation.
    omp)
      printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 __OMPBIN__ --config __OMPWORKERCFG__ --auto-approve --cwd __WORKTREE__'
      if [ "$kind" = secondmate ]; then
        printf '%s' ' __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __OMPEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Cursor Agent CLI. --trust suppresses the workspace-trust prompt, which
    # --yolo does NOT cover and which would otherwise block every spawn, since
    # each task gets a fresh worktree path cursor has never seen. --yolo is the
    # --force alias whose TUI label is "Run Everything". --workspace pins the
    # exact worktree. -w/--worktree is deliberately never passed: it allocates a
    # SECOND worktree under ~/.cursor/worktrees and would break firstmate's
    # isolation contract. The binary is resolved rather than named because
    # `cursor` is not the CLI (the installed names are cursor-agent and the
    # legacy alias agent), and the foreign primary markers are cleared so an
    # inherited CLAUDECODE cannot outrank cursor's own marker in a process that
    # only reads the environment. Cursor exposes no effort flag; an explicit
    # effort request is rejected by the launch-axis preflight.
    cursor) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS __CURSORBIN__ --trust --yolo __MODELFLAG__--workspace __WORKTREE__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # gemini (Google Gemini CLI): a positional query starts the supervised
    # interactive session and auto-submits it, so the brief rides the launch
    # command exactly as it does for claude and grok (verified: a multi-line
    # brief submitted itself with no extra Enter, gemini-cli 0.58.0).
    # -y (--yolo) auto-approves every tool call, which an unattended crewmate
    # needs; the footer renders ` YOLO Ctrl+Y` while it is on and a WriteFile
    # was verified to land with no approval gate.
    # Every task worktree is a fresh path, so gemini refuses to start at all
    # without a trust control. GEMINI_CLI_TRUST_WORKSPACE=true - NOT
    # --skip-trust - is the one used, and the difference is load-bearing
    # rather than cosmetic: the CLI's refusal message offers the two as
    # equivalents, but a controlled A/B on one worktree (same config home,
    # same prompt) showed --skip-trust runs the turn while leaving PROJECT
    # configuration unloaded, so the project's own .agents/skills are never
    # discovered. A firstmate-repo task needs exactly those, so the workspace
    # is trusted.
    # GEMINI_CLI_SYSTEM_SETTINGS_PATH points gemini at the firstmate-owned
    # per-task settings file written below. It is deliberately NOT the
    # worktree's .gemini/settings.json: unlike claude's settings.local.json,
    # that path is the PROJECT's own committed settings file, so writing it
    # would clobber a project's configuration and removing it at teardown
    # would delete a tracked file. The system layer also makes the busy
    # contract independent of the trust decision above (its hooks were
    # verified firing under --skip-trust in an untrusted folder), and hook
    # arrays MERGE across settings layers rather than overriding, so a
    # project's own hooks still run alongside firstmate's.
    # The foreign primary markers are cleared for the same reason cursor
    # clears them: gemini does not clear an inherited CLAUDECODE, and
    # bin/fm-harness.sh must not read a gemini worker as its launcher.
    # Gemini exposes no reasoning-effort flag (checked against 0.58.0
    # --help), so the launch-axis preflight rejects explicit effort requests.
    # Its turn-end and busy-state signals do NOT ride the launch command:
    # they are project hooks written into the worktree below.
    gemini) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_CLI_SYSTEM_SETTINGS_PATH=__GEMINISETTINGS__ gemini -y __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # only an absolute brief pointer after the TUI readiness gate below.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task-root token, so no launch placeholder belongs here.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    # muse (Muse Code): a positional prompt starts the supervised interactive
    # session. --yolo is the single flag that makes a crewmate pane viable: muse
    # ships approval prompts AND a filesystem/network sandbox ON by default
    # (--sandbox-network defaults to proxy-only, which refuses outright without a
    # managed proxy), and it gates a fresh workspace behind a trust dialog. One
    # --yolo disables approval, disables the sandbox so git and network work, and
    # trusts the workspace for the run, so no dialog appears on the fresh
    # per-task worktree (verified, muse 0.1.0-R708.1).
    # MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on is the privacy control:
    # muse otherwise loads the OPERATOR's foreign personal rules from ~/.claude
    # into every run and ships them to Meta-hosted inference, even under an
    # isolated XDG_CONFIG_HOME. exec mode's --no-foreign-personal-context flag is
    # NOT accepted by the interactive TUI (it exits with "unexpected argument"),
    # so this env var is the only control that reaches a pane worker. Verified to
    # drop the foreign rules_file context block while KEEPING the project's own
    # AGENTS.md rules, which the crewmate contract depends on.
    # muse's turn-end signal rides neither the launch command nor a hook: its
    # plugin engine is off in the default build, so firstmate folds muse's own
    # session event log instead (bin/fm-busy-lib.sh), bound by the sidecar
    # written below. Nothing to place in the template for it.
    # codex, opencode, and kimi are also markerless and share this inherited-marker hazard; changing their verified launch boundaries belongs in follow-up work.
    muse) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS XDG_CONFIG_HOME=__MUSECONFIG__ XDG_DATA_HOME=__MUSEDATA__ MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on __MUSEBIN__ --yolo __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Cursor Agent's positional prompt silently drops a large launch brief while
    # leaving an empty interactive composer. Non-reader tasks therefore start the
    # persistent TUI bare and deliver an encoded brief pointer only after the
    # shared composer classifier proves it ready below. Reader scout transport
    # remains outside this persistent-worker change.
    cursor-agent)
      # Readers use documented one-shot print mode. Persistent workers start
      # bare and receive a brief pointer after composer readiness below.
      if [ "$access" = reader ]; then
        printf '%s' '__CURSORBIN__ --trust --force __MODELFLAG__--print "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__CURSORBIN__ --trust --force __MODELFLAG__'
      fi
      ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    RAW_LAUNCH=1
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    RAW_LAUNCH=0
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        fm_record_spawn_failure validation "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)."
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND" "$ACCESS") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    RAW_LAUNCH=0
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND" "$ACCESS") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

if [ -n "$HARNESS" ]; then
  "$FM_ROOT/bin/fm-harness.sh" validate "$HARNESS" || exit 1
fi

# Dispatch attestation backstop (AGENTS.md section 4): when the dispatch profiles
# are active and this is not a secondmate spawn, an explicit harness must carry a
# declaration of how it was chosen. --dispatch-resolved attests the profiles were
# consulted; --dispatch-override-reason records a deliberate departure. A bare
# explicit harness is the silent hand-pick the explicit-harness guard exists to
# catch, so it is refused. The guard checks that resolution HAPPENED, not what it
# produced, and never reads crew-dispatch.json to verify the harness matches. The
# mutual-exclusion of both flags was already enforced above the batch path.
if [ "$KIND" != secondmate ] && [ -n "$ARG3" ] && [ -f "$CONFIG/crew-dispatch.json" ] && [ "$DISPATCH_RESOLVED" -eq 0 ] && [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 0 ]; then
  echo "error: config/crew-dispatch.json is active - pass --dispatch-resolved (you consulted the profiles) or --dispatch-override-reason '<why>' (you departed deliberately); the rules cannot be silently skipped." >&2
  exit 1
fi

# Muse has a verified ordinary-worker adapter but no primary supervision
# protocol, so a persistent supervisor cannot run safely under it.
if [ "$KIND" = secondmate ] && [ "$HARNESS" = muse ]; then
  echo "error: muse is a verified ordinary task adapter only and cannot run a persistent supervisor; it has no primary supervision protocol. Select a harness verified for persistent supervision." >&2
  exit 1
fi

case "$HARNESS" in
  claude)
    CLAUDE_BIN=$(command -v claude 2>/dev/null) || {
      echo "error: claude executable not found on PATH; install it or select a different verified harness" >&2
      exit 1
    }
    CLAUDE_SESSION_ID_SUPPORTED=0
    if claude_supports_session_id "$CLAUDE_BIN"; then
      CLAUDE_SESSION_ID_SUPPORTED=1
    fi
    ;;
  pi|pi-signed)
    PI_BIN=$(resolve_pi_executable "$HARNESS") || {
      echo "error: $HARNESS executable not found on PATH; install it or select a different verified harness" >&2
      exit 1
    }
    PI_TUI_MODE=
    PI_SESSION_ID_SUPPORTED=0
    if pi_supports_tui_mode "$PI_BIN"; then
      PI_TUI_MODE=' --tui-mode regular'
    fi
    if pi_supports_session_id "$PI_BIN"; then
      PI_SESSION_ID_SUPPORTED=1
    fi
    LAUNCH=${LAUNCH//__PITUIMODE__/$PI_TUI_MODE}
    LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH"
    ;;
  cursor)
    # `cursor` is not the CLI name, and the legacy alias `agent` is far too
    # generic to launch on its name alone, so resolution runs through the
    # verified owner rather than a bare command lookup. Refusing here keeps a
    # missing install a loud spawn refusal instead of a pane that dies with a
    # command-not-found the supervisor would read as a wedged worker.
    CURSOR_BIN=$(fm_cursor_resolve_binary) || exit 1
    if [ -n "$MODEL" ] && [ "$MODEL" != default ]; then
      if CURSOR_MODELS=$(fm_cursor_list_models "$CURSOR_BIN"); then
        if ! printf '%s\n' "$CURSOR_MODELS" | fm_cursor_catalog_has_model "$MODEL"; then
          echo "error: Cursor model '$MODEL' is not available from '$CURSOR_BIN --list-models'; choose an id listed by that command or omit --model" >&2
          exit 1
        fi
      fi
    fi
    ;;
  cursor-agent)
    CURSOR_BIN=$(fm_cursor_resolve_binary) || exit 1
    ;;
esac

if [ "$RESUME_SESSION_SET" -eq 1 ] && { [ "$RAW_LAUNCH" -eq 1 ] || [ "$HARNESS" != codex ]; }; then
  echo "error: --resume-session is supported only by the Codex lifecycle owner" >&2
  exit 1
fi

# Durable routing cooldown backstop. The owner script compares only explicit
# catalog-established axes, ignores expired records, refuses an automatic exact
# match, and records a captain override on the matching record. This runs before
# endpoint creation or task metadata publication. It also protects the static
# crew-harness path when a durable record exists, not only profile arrays.
if [ "$KIND" != secondmate ] && [ -f "$DATA/quota-cooldowns.json" ]; then
  cooldown_args=(authorize --harness "$HARNESS")
  [ "$DISPATCH_PROVIDER_SET" -eq 0 ] || cooldown_args+=(--provider "$DISPATCH_PROVIDER")
  [ "$DISPATCH_MODEL_FAMILY_SET" -eq 0 ] || cooldown_args+=(--model-family "$DISPATCH_MODEL_FAMILY")
  if [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 1 ]; then
    cooldown_args+=(--task-id "$ID" --override-reason "$DISPATCH_OVERRIDE_REASON")
  fi
  if cooldown_output=$(FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-quota-cooldown.sh" "${cooldown_args[@]}" 2>&1); then
    [ -z "$cooldown_output" ] || printf '%s\n' "$cooldown_output"
  else
    cooldown_status=$?
    [ -z "$cooldown_output" ] || printf '%s\n' "$cooldown_output" >&2
    IFS='|' read -r cd_kind cd_quota_reader cd_capability <<EOF
$(fm_classify_cooldown_refusal "${cooldown_output:-}")
EOF
    fm_record_spawn_failure "$cd_kind" "${cooldown_output:-quota cooldown authorize refused}" "$cd_capability" "$cd_quota_reader"
    exit "$cooldown_status"
  fi
fi

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max|ultra) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2 ;;
      esac
    fi
  fi
fi
# Ultra is an explicit native capability, never a Pi thinking-level alias.
# Validate the fully resolved profile before worktree or endpoint provisioning.
if [ "$EFFORT" = ultra ]; then
  "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$HARNESS" "$MODEL" "$EFFORT" || exit 1
  [ "$RAW_LAUNCH" = 0 ] || {
    echo "error: --effort ultra requires the canonical --harness pi or pi-signed launch so its native flag cannot be omitted" >&2
    exit 1
  }
fi
if [ "$HARNESS" = omp ]; then
  omp_model_validate "$OMP_BIN" "$MODEL" || exit 1
fi

CLAUDE_ACCOUNT_CONFIG_DIR=
if [ "$ACCOUNT_PROFILE_SET" -eq 1 ]; then
  if [ "$HARNESS" != claude ] || [ "$RAW_LAUNCH" -eq 1 ]; then
    echo "error: --account-profile is accepted only by the verified native claude adapter" >&2
    exit 1
  fi
  if ! fm_claude_account_profile_resolve "$CONFIG" "$ACCOUNT_PROFILE"; then
    echo "error: $FM_CLAUDE_ACCOUNT_PROFILE_ERROR" >&2
    exit 1
  fi
  CLAUDE_ACCOUNT_CONFIG_DIR=$FM_CLAUDE_ACCOUNT_PROFILE_DIR
  if ! fm_claude_account_profile_preflight "$ACCOUNT_PROFILE" "$CLAUDE_ACCOUNT_CONFIG_DIR"; then
    echo "error: $FM_CLAUDE_ACCOUNT_PROFILE_ERROR" >&2
    exit 1
  fi
fi
spawn_timing_finish dispatch "$SPAWN_TIMING_DISPATCH_START"

secondmate_registry_value() {
  secondmate_registry_field "$DATA/secondmates.md" "$1" "$2"
}

resolve_kimi_binary() {
  local candidate dir fallback
  candidate=$(command -v kimi 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s\n' "$candidate"; return 0 ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        if [ -n "$dir" ]; then
          printf '%s/%s\n' "$dir" "$(basename "$candidate")"
          return 0
        fi
        ;;
    esac
  fi
  fallback="${HOME:-}/.kimi-code/bin/kimi"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'" >&2
  return 1
}

resolve_muse_binary() {
  local candidate dir
  candidate=$(command -v muse 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s\n' "$candidate"; return 0 ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        if [ -n "$dir" ]; then
          printf '%s/%s\n' "$dir" "$(basename "$candidate")"
          return 0
        fi
        ;;
    esac
  fi
  echo "error: muse executable not found on PATH; install Muse Code or select a different verified harness" >&2
  return 1
}

resolve_rovo_binary() {
  local candidate dir fallback
  candidate=$(command -v rovo 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s\n' "$candidate"; return 0 ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        if [ -n "$dir" ]; then
          printf '%s/%s\n' "$dir" "$(basename "$candidate")"
          return 0
        fi
        ;;
    esac
  fi
  fallback="${HOME:-}/.local/bin/rovo"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: rovo executable not found; searched PATH for 'rovo' and fallback '$fallback'" >&2
  return 1
}

# muse_credential_present: 0 when a launched muse pane can reach its provider
# without an interactive login. muse offers exactly two credential paths
# (verified, muse 0.1.0-R708.1): the META_API_KEY environment variable, which
# always takes priority, and a stored credential written by `muse auth set` or
# `muse login` into <config>/muse/auth.json. This is a PREFLIGHT rather than a
# rendered-screen check because an unauthenticated pane does not exit - it sits
# on an OAuth device-code prompt ("Sign in at this page ... Waiting for
# approval...") waiting for a human who is not there, which would look to
# supervision like a wedged worker rather than a missing credential.
muse_worker_meta_api_key_present() {
  local session worker_env
  if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
    case $'\n'"$LAUNCH_ENV_NAMES"$'\n' in
      *$'\nMETA_API_KEY\n'*) ;;
      *) return 1 ;;
    esac
  fi
  [ "$BACKEND" = tmux ] || return 1
  if [ -n "${TMUX:-}" ]; then
    session=$(tmux display-message -p '#S' 2>/dev/null) || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || return 1
    session=firstmate
  fi
  worker_env=$(tmux show-environment -t "$session" META_API_KEY 2>/dev/null) || return 1
  case "$worker_env" in
    META_API_KEY=?*) return 0 ;;
  esac
  return 1
}

muse_credential_present() {
  local auth=$1
  [ -s "$auth" ] || muse_worker_meta_api_key_present
}

# Kimi's workspace id embeds a real sha256, so a wrong or absent digest keys the
# record to a path Kimi never reads. There is no usable weaker fallback here:
# refuse rather than emit a plausible-looking wrong identity.
kimi_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Kimi Code keys workspace trust by the same stable workdir id it uses for
# sessions: wd_<basename-slug>_<first-12-sha256-of-normalized-root>.
kimi_workspace_id() {  # <absolute-worktree-root>
  local root=$1 base slug digest
  root=$(cd "$root" && pwd -P) || return 1
  base=${root##*/}
  slug=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//' | cut -c1-40 | sed 's/^-*//; s/-*$//')
  [ -n "$slug" ] && [ "$slug" != . ] && [ "$slug" != .. ] || slug=workspace
  digest=$(printf '%s' "$root" | kimi_sha256_stdin) || return 1
  [ "${#digest}" -eq 64 ] || return 1
  case $digest in
    *[!0-9a-f]*) return 1 ;;
  esac
  printf 'wd_%s_%s\n' "$slug" "${digest:0:12}"
}

kimi_workspace_trust_path() {  # <absolute-worktree-root>
  local id
  id=$(kimi_workspace_id "$1") || return 1
  printf '%s/.kimi-code/workspace-trust/%s\n' "$HOME" "$id"
}

# Forwards the predicate owner's three-valued contract unchanged: 0 valid,
# 1 rejected, 2 the predicate could not be evaluated at all (jq missing).
# Collapsing 2 into 1 would report a missing dependency as a trust rejection.
kimi_workspace_trust_is_valid() {  # <absolute-task-root> <trust-file>
  "$SCRIPT_DIR/fm-kimi-trust-check.sh" "$1" "$2" >/dev/null 2>&1
}

kimi_trust_now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable; `date +%s%N` is GNU-only.
    echo $(($(date +%s) * 1000))
  fi
}

# Returns 0 when the task root is trusted, 2 when trust could not be EVALUATED
# (the predicate owner is unusable, so nothing is written), and 1 for every
# other failure to establish trust.
kimi_prest_trust_workspace() {  # <absolute-task-root>
  local root=$1 trust_dir trust_file tmp trusted_at status
  root=$(cd "$root" && pwd -P) || return 1
  trust_file=$(kimi_workspace_trust_path "$root") || return 1
  trust_dir=${trust_file%/*}
  status=0
  kimi_workspace_trust_is_valid "$root" "$trust_file" || status=$?
  case $status in
    0) return 0 ;;
    2) return 2 ;;
  esac
  trusted_at=$(kimi_trust_now_ms) || return 1
  case $trusted_at in
    ''|*[!0-9]*) return 1 ;;
  esac
  mkdir -p "$trust_dir" || return 1
  chmod 700 "$trust_dir" 2>/dev/null || true
  tmp=$(mktemp "$trust_dir/.fm-trust.XXXXXX") || return 1
  if ! printf '{"root":"%s","trustedAt":%s}\n' \
    "$(json_escape "$root")" "$trusted_at" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$trust_file" || { rm -f "$tmp"; return 1; }
  # Re-read what actually landed: the write path must prove the same predicate
  # the pre-existing record had to satisfy, so a malformed emission refuses the
  # spawn instead of passing as established trust.
  status=0
  kimi_workspace_trust_is_valid "$root" "$trust_file" || status=$?
  return "$status"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|cursor-agent|omp|gemini)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
    *) echo "error: unsupported model axis for harness '$harness'; omit it or use a verified launch adapter" >&2; return 1 ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2 model=${3:-}
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max)
      printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
    codex:low|codex:medium|codex:high|codex:xhigh)
      printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
    grok:low|grok:medium|grok:high|muse:low|muse:medium|muse:high|muse:xhigh)
      printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
    muse:max)
      # The verified adapter maps the explicitly requested max class to ultra.
      printf -- '--reasoning-effort %s ' "$(shell_quote ultra)" ;;
    pi:ultra|pi-signed:ultra)
      "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
      printf -- '--codex-effort %s ' "$(shell_quote ultra)" ;;
    pi:low|pi:medium|pi:high|pi:xhigh|pi:max|pi-signed:low|pi-signed:medium|pi-signed:high|pi-signed:xhigh|pi-signed:max|omp:low|omp:medium|omp:high|omp:xhigh|omp:max)
      printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
    rovo:low|rovo:medium|rovo:high|rovo:max)
      # Merged with the path grant by rovo_config_override_flag below.
      return 0 ;;
    *)
      echo "error: unsupported effort '$effort' for harness '$harness'; choose a supported setting or explicitly omit the axis" >&2
      return 1 ;;
  esac
}

# Validate once before provisioning or intake, then use these exact flags at
# launch. A requested axis must not survive only as misleading metadata.
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL") || exit 1
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT" "$MODEL") || exit 1
if [ -n "$MODELFLAG" ]; then
  case "$LAUNCH" in
    *__MODELFLAG__*) ;;
    *) echo "error: launch command cannot apply the requested model axis" >&2; exit 1 ;;
  esac
fi
if [ -n "$EFFORTFLAG" ]; then
  case "$LAUNCH" in
    *__EFFORTFLAG__*) ;;
    *) echo "error: launch command cannot apply the requested effort axis" >&2; exit 1 ;;
  esac
elif [ "$HARNESS" = rovo ] && [ -n "$EFFORT" ] && [ "$EFFORT" != default ]; then
  case "$LAUNCH" in
    *__ROVOCONFIGOVERRIDE__*) ;;
    *) echo "error: launch command cannot apply the requested effort axis" >&2; exit 1 ;;
  esac
fi

case "$LAUNCH" in
  *__MUSEBIN__*)
    MUSE_BIN=$(resolve_muse_binary) || exit 1
    MUSE_CONFIG_HOME=$(resolve_directory_input XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-${HOME:-}/.config}") || exit 1
    MUSE_DATA_HOME=$(resolve_directory_input XDG_DATA_HOME "${XDG_DATA_HOME:-${HOME:-}/.local/share}") || exit 1
    MUSE_AUTH_FILE="$MUSE_CONFIG_HOME/muse/auth.json"
    if ! muse_credential_present "$MUSE_AUTH_FILE"; then
      if [ -n "${META_API_KEY:-}" ]; then
        echo "error: muse has no worker-reachable credential; META_API_KEY is set for fm-spawn but cannot be proven present in the $BACKEND worker environment. Store the fleet credential at '$MUSE_AUTH_FILE' with 'muse login' or 'muse auth set --api-key-stdin'. The secret will not be copied into the launch command." >&2
      else
        echo "error: muse has no worker-reachable credential; META_API_KEY cannot be proven present in the $BACKEND worker environment and '$MUSE_AUTH_FILE' is absent or empty. Store the fleet credential with 'muse login' or 'muse auth set --api-key-stdin'." >&2
      fi
      exit 1
    fi
    LAUNCH=${LAUNCH//__MUSEBIN__/$(shell_quote "$MUSE_BIN")}
    LAUNCH=${LAUNCH//__MUSECONFIG__/$(shell_quote "$MUSE_CONFIG_HOME")}
    LAUNCH=${LAUNCH//__MUSEDATA__/$(shell_quote "$MUSE_DATA_HOME")}
    ;;
esac

case "$LAUNCH" in
  *__KIMIBIN__*)
    KIMI_BIN=$(resolve_kimi_binary) || exit 1
    LAUNCH=${LAUNCH//__KIMIBIN__/$(shell_quote "$KIMI_BIN")}
    if [ "$KIND" != secondmate ]; then
      "$FM_ROOT/bin/fm-kimi-turnend-hook.sh" install || {
        echo "error: refusing Kimi spawn because the global turn-end hook could not be installed safely" >&2
        exit 1
      }
    fi
    ;;
esac

case "$LAUNCH" in
  *__ROVOBIN__*)
    ROVO_BIN=$(resolve_rovo_binary) || exit 1
    LAUNCH=${LAUNCH//__ROVOBIN__/$(shell_quote "$ROVO_BIN")}
    ;;
esac

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# rovo confines every file-tool operation (open_files, create_file, grep, ...)
# to its worktree by default; toolPermissions.allowedExternalPaths
# (~/.rovo/config.yml) is the only lift, and it must be granted at launch
# through --config-override since there is no per-session escalation once
# the process is running. rovo's bash tool is NOT covered by this grant and
# stays confined to the worktree regardless (confirmed live) - the standard
# crewmate flow's literal `echo ... >> status file` bash line therefore still
# fails under rovo, but the worker recovers by falling back to its own file
# tools for the same append (confirmed live), which the grant below does cover.
# --config-override itself is single-value (a second occurrence silently
# discards the first, confirmed live), so this is the ONE place that must
# also fold in agent.efficiencyLevel when a supported effort was requested.
# Granted paths are real (symlink-resolved) directories/files under this
# task's home, matching BRIEF_REAL's own resolution: the brief dir (covers
# brief.md/launch-brief.md/report.md), the steering inbox directory (covers
# every steer and its handled/ acknowledgement), and the status file itself.
rovo_config_override_flag() {
  local effort=$1 data_dir=$2 state_dir=$3 id=$4
  local data_real state_real agent_json paths_json config_json
  data_real=$(cd "$data_dir" && pwd -P) || return 1
  state_real=$(cd "$state_dir" && pwd -P) || return 1
  agent_json=
  case "$effort" in
    low|medium|high|max) agent_json="\"agent\":{\"efficiencyLevel\":\"$(json_escape "$effort")\"}," ;;
  esac
  paths_json=$(printf '"%s","%s","%s"' \
    "$(json_escape "$data_real/$id")" \
    "$(json_escape "$state_real/$id.inbox")" \
    "$(json_escape "$state_real/$id.status")")
  config_json="{${agent_json}\"toolPermissions\":{\"allowedExternalPaths\":[$paths_json]}}"
  printf -- '--config-override %s ' "$(shell_quote "$config_json")"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

project_is_firstmate_repo() {
  local project=$1 project_top root_top project_common root_common project_origin root_origin
  project_top=$(git -C "$project" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  root_top=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  [ "$project_top" = "$root_top" ] && return 0
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  root_common=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$project_common" = "$root_common" ] && return 0
  project_origin=$(git -C "$project" remote get-url origin 2>/dev/null || true)
  root_origin=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null || true)
  [ -n "$project_origin" ] && [ "$project_origin" = "$root_origin" ]
}

pi_worker_module_context_flags() {
  local worktree=$1 brief=$2 module agents entry mode module_tree
  local -a modules=()
  while IFS= read -r module; do
    module=${module#modules/}
    module=${module%/}
    case " ${modules[*]} " in
      *" $module "*) continue ;;
    esac
    modules+=("$module")
  done < <(grep -Eo 'modules/[A-Za-z0-9][A-Za-z0-9._-]*/?' "$brief" 2>/dev/null | sort -u)
  for module in "${modules[@]}"; do
    if [ "$ACCESS" = reader ]; then
      module_tree=$(git --git-dir="$worktree/repo.git" ls-tree -d --name-only HEAD -- "modules/$module" 2>/dev/null || true)
      [ "$module_tree" = "modules/$module" ] || {
        echo "error: reader module context '$module' is missing from the read handle" >&2
        return 1
      }
      entry=$(git --git-dir="$worktree/repo.git" ls-tree HEAD -- "modules/$module/AGENTS.md" 2>/dev/null || true)
      mode=${entry%% *}
      case "$mode" in
        100644|100755) ;;
        *)
          echo "error: reader module context '$module' has no regular AGENTS.md in the read handle" >&2
          return 1
          ;;
      esac
      agents="$worktree/.fm-module-context/$module/AGENTS.md"
      mkdir -p "${agents%/*}" || return 1
      git --git-dir="$worktree/repo.git" show "HEAD:modules/$module/AGENTS.md" > "$agents" || return 1
    else
      agents="$worktree/modules/$module/AGENTS.md"
      [ -d "$worktree/modules/$module" ] && [ ! -L "$worktree/modules/$module" ] || {
        echo "error: worker module context '$module' is missing from the worktree" >&2
        return 1
      }
      [ -f "$agents" ] && [ ! -L "$agents" ] || {
        echo "error: worker module context '$module' has no regular AGENTS.md" >&2
        return 1
      }
    fi
    printf -- '--append-system-prompt %s ' "$(shell_quote "$agents")"
  done
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && { [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; }; then
    fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE" || {
      echo "error: secondmate task record is unsafe: $FM_BACKLOG_TRANSITION_ERROR" >&2
      exit 1
    }
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  if [ -e "$DATA/secondmates.md" ] || [ -L "$DATA/secondmates.md" ]; then
    if ! secondmate_registry_validate_bindings "$DATA/secondmates.md" resolve_path "$ID" "$FIRSTMATE_HOME"; then
      echo "error: $SECONDMATE_REGISTRY_ERROR" >&2
      exit 1
    fi
    SECONDMATE_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
  fi
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  # On a remote host this spawn is the host-local leg of a launch whose parent has
  # already synced the home to ITS primary commit, and $FM_ROOT here is only that
  # host's own Firstmate copy; syncing again would target the wrong checkout, so
  # the caller turns this step off (bin/fm-remote-secondmate-control.sh).
  if [ "${FM_SKIP_SECONDMATE_SYNC:-0}" = 1 ]; then
    :
  elif sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
    CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
      echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    }
    if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
      echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    fi
    CONFIG_INHERIT_LOCK_HELD=1
    # Inheritance propagation: push the primary-authoritative live-safe local inheritance
    # surface into this secondmate home (fm-config-inherit-lib.sh).
    FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
      || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  fi
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  PROJECT_REPO=$(basename "$PROJ_ABS")
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi

# Mint one durable human-facing code before any local backend presentation uses it.
# FM_TASK_ID remains helper-report authority. Code ancestry is stored separately
# so a seeded controller can name a child without restricting ordinary reports.
# Remote parent ancestry is deferred; those homes mint local roots.
TASK_PARENT_ID=
TASK_CODE_PARENT_ID=
TASK_CHILD_SEQ=
if [ "$RELAUNCH" -eq 1 ]; then
  TASK_PARENT_ID=$(fm_meta_get "$STATE/$ID.meta" parent)
  TASK_CODE_PARENT_ID=$(fm_meta_get "$STATE/$ID.meta" code_parent)
  TASK_CHILD_SEQ=$(fm_meta_get "$STATE/$ID.meta" child_seq)
  TASK_CODE_COUNT=$(grep -c '^code=' "$STATE/$ID.meta" 2>/dev/null || true)
  case "$TASK_CODE_COUNT" in
    0) TASK_CODE= ;;
    1)
      TASK_CODE=$(fm_task_code_of_meta "$STATE/$ID.meta" 2>/dev/null) || {
        echo "error: task $ID stored task code is malformed or duplicated; refusing relaunch" >&2
        exit 1
      }
      ;;
    *)
      echo "error: task $ID stored task code is malformed or duplicated; refusing relaunch" >&2
      exit 1
      ;;
  esac
else
  TASK_PARENT_ID=${FM_TASK_ID:-}
  TASK_CODE_PARENT_ID=$TASK_PARENT_ID
  if [ -z "$TASK_CODE_PARENT_ID" ]; then
    parent_rc=0
    TASK_CODE_PARENT_ID=$(fm_parent_channel_home_id "$FM_HOME") || parent_rc=$?
    case "${parent_rc:-0}" in
      0)
        fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || {
          echo "error: this home's persistent controller binding is malformed; refusing to mint an unparented task code" >&2
          exit 1
        }
        [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || TASK_CODE_PARENT_ID=
        ;;
      1) TASK_CODE_PARENT_ID= ;;
      *)
        echo "error: this home's persistent controller identity is malformed; refusing to mint an unparented task code" >&2
        exit 1
        ;;
    esac
  fi
  [ "$TASK_CODE_PARENT_ID" != "$ID" ] || {
    echo "error: task $ID cannot be its own code parent" >&2
    exit 1
  }
  if [ -n "$TASK_CODE_PARENT_ID" ]; then
    TASK_CODE_PARENT_META=$(fm_task_code_parent_meta "$FM_HOME" "$TASK_CODE_PARENT_ID" "$STATE") || {
      echo "error: parent task $TASK_CODE_PARENT_ID has missing or ambiguous stored code/sequence identity" >&2
      exit 1
    }
    TASK_CODE_PARENT_COUNT=$(grep -c '^code=' "$TASK_CODE_PARENT_META" 2>/dev/null || true)
    if [ "$TASK_CODE_PARENT_COUNT" -eq 0 ]; then
      if [ ! -r "$TASK_CODE_PARENT_META" ] \
        || ! fm_backend_validate_task_endpoint "$TASK_CODE_PARENT_META" "$TASK_CODE_PARENT_ID" >/dev/null; then
        echo "error: uncoded parent task $TASK_CODE_PARENT_ID does not have valid local identity" >&2
        exit 1
      fi
      TASK_CODE_PARENT_ID=
    else
      TASK_CHILD_SEQ=$(fm_task_code_child_seq_next "$FM_HOME" "$TASK_CODE_PARENT_ID" "$STATE") || {
        echo "error: parent task $TASK_CODE_PARENT_ID has missing or ambiguous stored code/sequence identity" >&2
        exit 1
      }
    fi
  fi
  TASK_CODE=$(fm_task_code_mint "$FM_HOME" "$PROJ_ABS" "$KIND" "$ID" "$TASK_CODE_PARENT_ID" "$TASK_CHILD_SEQ" "$STATE") || {
    echo "error: task $ID code could not be minted uniquely from its stored identity inputs" >&2
    exit 1
  }
fi

if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve the shared Treehouse project lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
    fm_telemetry_record_wait "$ID" "$(fm_telemetry_task_attempt "$ID")" lock treehouse-project open
    echo "error: another Treehouse slot allocation or return is in progress for $PROJ_ABS; refusing to race it" >&2
    exit 1
  fi
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
fi
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  SPAWN_TIMING_BRIEF_START=$(fm_timing_now_ms)
fi
[ -f "$BRIEF" ] || { echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2; exit 1; }
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  if fm_brief_task_placeholders_present "$BRIEF"; then
    echo "error: $ID brief failed the load-bearing bookend check: $BRIEF still contains {TASK} or {FIRSTMATE_SPEC}; fill ## Captain's intent and ## Firstmate spec in both structured copies (bin/fm-brief.sh <task-id> --fill <intent-file> [spec-file]) before spawn" >&2
    exit 1
  fi
  if ! fm_brief_task_content_valid "$BRIEF"; then
    echo "error: $BRIEF must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before spawn" >&2
    exit 1
  fi
  # Validate the scaffolded source before a no-mistakes launch adds its current
  # intent overlay to launch-brief.md; the overlay is delivery material, not a
  # third copy of the opening/closing load-bearing task contract.
  VB_ERR=$("$FM_ROOT/bin/fm-brief.sh" --validate-bookends "$BRIEF" 2>&1) || {
    printf '%s\n' "$VB_ERR" >&2
    echo "error: $ID brief failed the load-bearing bookend check; fill both structured copies from one input per subsection (bin/fm-brief.sh <task-id> --fill <intent-file> [spec-file]) before launch" >&2
    exit 1
  }
  if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
    if fm_brief_task_heading_present "$BRIEF" "## Captain's intent"; then
      CAPTAIN_INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
    else
      LEGACY_TASK_BODY=$(fm_brief_heading_body "$BRIEF" "# Task")
      CAPTAIN_INTENT=$(fm_brief_marked_captain_words "$LEGACY_TASK_BODY")
      if [ -z "$(printf '%s' "$CAPTAIN_INTENT" | tr -d '[:space:]')" ]; then
        echo "error: legacy mixed # Task brief has no provenance-marked captain words for no-mistakes --intent; add Captain: lines or migrate to ## Captain's intent and ## Firstmate spec" >&2
        exit 1
      fi
    fi
  fi
  # Use the existing launch-brief overlay for every worker kind, including
  # pre-scope briefs and relaunches. Charters never enter this worker path.
  SOURCE_BRIEF=$BRIEF
  BRIEF="$DATA/$ID/launch-brief.md"
  BRIEF_TMP="$DATA/$ID/.launch-brief.md.${BASHPID:-$$}"
  {
    cat "$SOURCE_BRIEF" &&
      printf '\n' &&
      fm_brief_worker_role &&
      if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
        fm_brief_intent_overlay "$CAPTAIN_INTENT"
      fi
  } > "$BRIEF_TMP" || { rm -f -- "$BRIEF_TMP"; echo "error: could not render current launch contract for $SOURCE_BRIEF" >&2; exit 1; }
  if ! mv "$BRIEF_TMP" "$BRIEF"; then
    rm -f -- "$BRIEF_TMP"
    echo "error: could not publish current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  fi
  spawn_timing_finish brief "$SPAWN_TIMING_BRIEF_START"
fi

delivery_rigor_rank() {  # <mode> -> 3 (most rigor) .. 1 (least); 0 = not a task mode
  case "$1" in
    no-mistakes) echo 3 ;;
    direct-PR) echo 2 ;;
    local-only) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Brief/spawn delivery agreement, checked before any endpoint exists.
# fm-brief.sh records a ship brief's mode as a fixed "Delivery contract: mode=<mode>"
# line. A spawn that disagrees would launch a worker whose instructions and whose
# recorded task delivery differ, which is the exact drift this contract prevents.
if [ "$KIND" = ship ]; then
  PROJ_NAME=$PROJECT_REPO
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  if [ -z "$BRIEF_MODE" ]; then
    echo "warning: $BRIEF records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode $MODE - confirm its definition of done matches" >&2
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    echo "error: delivery mismatch for $ID: the brief says mode=$BRIEF_MODE but this spawn passed --mode $MODE; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree" >&2
    exit 1
  fi
  # The registry holds the captain's standing posture, so dropping below it is
  # allowed (a current explicit captain instruction wins) but never silent. An
  # unregistered project resolves to the same no-mistakes standing default, which
  # is why the notice names the standing posture rather than the registry line. A
  # conditional policy is excluded: both of its legs are legitimate classifications.
  STANDING_MODE=$("$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJ_NAME" 2>/dev/null | cut -d' ' -f1) || STANDING_MODE=
  if [ -n "$STANDING_MODE" ] && [ "$STANDING_MODE" != no-mistakes-prod-only ] \
     && [ "$(delivery_rigor_rank "$MODE")" -lt "$(delivery_rigor_rank "$STANDING_MODE")" ]; then
    echo "notice: $ID ships mode=$MODE while the standing posture for $PROJ_NAME is $STANDING_MODE - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
fi

# Brief/spawn access agreement, checked before any endpoint exists (the exact
# analog of the ship delivery-contract check above). fm-brief.sh records a
# reader scout brief's axis as exactly one fixed "Access contract:
# access=reader" line before the scaffold-owned "# Task" boundary.
# Drift in either direction launches a worker whose instructions describe the
# wrong environment: a writer brief in a checkout-free scratch dir tells the
# worker to branch and commit in a worktree it does not have, and a reader
# brief in a pool worktree hands a no-checkout contract to a worker that holds
# one. A brief scaffolded before this axis existed carries no line and remains
# a valid writer brief, so the default writer path launches it unchanged.
if [ "$KIND" = scout ]; then
  BRIEF_ACCESS=$(awk '
    /^# Task$/ { task_boundary = 1; exit }
    /^Access contract: access=[^ ]+$/ {
      count++
      value = $0
      sub(/^Access contract: access=/, "", value)
    }
    END {
      if (count > 1 || (count > 0 && !task_boundary)) print "invalid"
      else if (count == 1) print value
    }
  ' "$BRIEF")
  if [ "$BRIEF_ACCESS" = invalid ]; then
    echo "error: access mismatch for $ID: the brief's machine-owned access contract must appear exactly once before its # Task section; re-scaffold the brief" >&2
    exit 1
  fi
  if [ "$ACCESS" = reader ] && [ "$BRIEF_ACCESS" != reader ]; then
    echo "error: access mismatch for $ID: this spawn passed --access reader but the brief records no reader access contract; re-scaffold with fm-brief.sh --scout --access reader so the worker's instructions match its checkout-free environment" >&2
    exit 1
  fi
  if [ "$ACCESS" != reader ] && [ "$BRIEF_ACCESS" = reader ]; then
    echo "error: access mismatch for $ID: the brief records a reader access contract but this spawn would grant a writer worktree; pass --access reader or re-scaffold the brief" >&2
    exit 1
  fi
fi

BRIEF_DIR_REAL=$(cd "$(dirname "$BRIEF")" && pwd -P)
BRIEF_REAL="$BRIEF_DIR_REAL/$(basename "$BRIEF")"

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# READER ISOLATION ENFORCEMENT PREDICATE (--access reader). The scratch path
# checks below keep the launch root outside tracked territory; the reader-only
# process sandbox applied to the final launch command denies absolute-path
# writes back into the project while preserving the task's scratch and
# firstmate-owned report/status surfaces. Both gates must pass before launch.
reader_validate_descendant_symlinks() {  # <canonical-scratch-dir>
  local scratch=$1 links link raw_target target_real
  links=$(find "$scratch" -type l -print 2>/dev/null) || {
    echo "error: reader scratch directory $scratch could not be inspected for descendant symlinks; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  }
  while IFS= read -r link || [ -n "$link" ]; do
    [ -n "$link" ] || continue
    raw_target=$(readlink "$link" 2>/dev/null) || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be read; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    case "$raw_target" in
      /*)
        echo "error: reader scratch directory $scratch contains an unsafe symlink at $link that uses an absolute target; refusing to launch - a reader must never be able to write a tracked file" >&2
        return 1
        ;;
    esac
    target_real=$(realpath "$link" 2>/dev/null) || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be resolved; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    [ -e "$target_real" ] || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be resolved; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    case "$target_real" in
      "$scratch"|"$scratch"/*) ;;
      *)
        echo "error: reader scratch directory $scratch contains an unsafe symlink at $link that resolves outside its canonical root; refusing to launch - a reader must never be able to write a tracked file" >&2
        return 1
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$links" | LC_ALL=C sort)
EOF
}

validate_reader_scratch() {  # <scratch-dir>
  local scratch=$1 scratch_real inside_work_tree inside_git_dir descendant_git
  scratch_real=$(cd "$scratch" 2>/dev/null && pwd -P) || {
    echo "error: reader scratch directory cannot be resolved: $scratch; refusing to launch" >&2
    return 1
  }
  case "$scratch_real" in
    "$PROJ_ABS_REAL"|"$PROJ_ABS_REAL"/*)
      echo "error: reader scratch directory $scratch_real resolves into the primary checkout $PROJ_ABS_REAL; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
      ;;
  esac
  inside_work_tree=$(git -C "$scratch_real" rev-parse --is-inside-work-tree 2>/dev/null) || inside_work_tree=false
  inside_git_dir=$(git -C "$scratch_real" rev-parse --is-inside-git-dir 2>/dev/null) || inside_git_dir=false
  if [ "$inside_work_tree" = true ] || [ "$inside_git_dir" = true ]; then
    echo "error: reader scratch directory $scratch_real is inside a git checkout or git dir; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  fi
  reader_validate_descendant_symlinks "$scratch_real" || return 1
  descendant_git=$(find "$scratch_real" -name .git -print -quit 2>/dev/null) || {
    echo "error: reader scratch directory $scratch_real could not be inspected for descendant git metadata; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  }
  if [ -n "$descendant_git" ]; then
    echo "error: reader scratch directory $scratch_real contains a git checkout at $descendant_git; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  fi
}

reader_sandbox_preflight() {
  local platform sandbox_bin report_dir state_dir profile
  platform=$(uname -s)
  report_dir=$(cd "$DATA/$ID" 2>/dev/null && pwd -P) || return 1
  state_dir=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  case "$report_dir" in
    "$PROJ_ABS_REAL")
      echo "error: reader report directory cannot be the project root; refusing to launch without process-level write confinement" >&2
      return 1
      ;;
  esac
  case "$state_dir" in
    "$PROJ_ABS_REAL")
      echo "error: reader state directory cannot be the project root; refusing to launch without process-level write confinement" >&2
      return 1
      ;;
  esac
  case "$platform" in
    Darwin)
      sandbox_bin=$(command -v sandbox-exec 2>/dev/null || true)
      [ -n "$sandbox_bin" ] || {
        echo "error: sandbox-exec is required for reader process confinement on macOS; refusing to launch" >&2
        return 1
      }
      profile='(version 1)(allow default)(deny file-write* (subpath (param "PROJECT")))(allow file-write* (subpath (param "SCRATCH")))(allow file-write* (subpath (param "REPORT")))(allow file-write* (subpath (param "STATE")))'
      "$sandbox_bin" -D "PROJECT=$PROJ_ABS_REAL" -D "SCRATCH=$READER_SCRATCH" \
        -D "REPORT=$report_dir" -D "STATE=$state_dir" -p "$profile" /usr/bin/true >/dev/null 2>&1 || {
        echo "error: sandbox-exec could not establish reader process confinement; refusing to launch" >&2
        return 1
      }
      READER_SANDBOX_PROFILE=$profile
      ;;
    Linux)
      sandbox_bin=$(command -v bwrap 2>/dev/null || true)
      [ -n "$sandbox_bin" ] || {
        echo "error: bwrap is required for reader process confinement on Linux; refusing to launch" >&2
        return 1
      }
      "$sandbox_bin" --die-with-parent --cap-drop ALL --bind / / --dev-bind /dev /dev \
        --ro-bind "$PROJ_ABS_REAL" "$PROJ_ABS_REAL" -- /bin/true >/dev/null 2>&1 || {
        echo "error: bwrap could not establish reader process confinement; refusing to launch" >&2
        return 1
      }
      ;;
    *)
      echo "error: reader process confinement is unsupported on $platform; refusing to launch" >&2
      return 1
      ;;
  esac
  READER_SANDBOX_PLATFORM=$platform
  READER_SANDBOX_BIN=$sandbox_bin
  READER_REPORT_DIR=$report_dir
  READER_STATE_DIR=$state_dir
}

reader_confine_launch() {  # <launch-command>
  local launch=$1 confined allowed
  case "$READER_SANDBOX_PLATFORM" in
    Darwin)
      printf '%s' "$(shell_quote "$READER_SANDBOX_BIN") -D $(shell_quote "PROJECT=$PROJ_ABS_REAL") -D $(shell_quote "SCRATCH=$READER_SCRATCH") -D $(shell_quote "REPORT=$READER_REPORT_DIR") -D $(shell_quote "STATE=$READER_STATE_DIR") -p $(shell_quote "$READER_SANDBOX_PROFILE") /bin/bash -c $(shell_quote "$launch")"
      ;;
    Linux)
      confined="$(shell_quote "$READER_SANDBOX_BIN") --die-with-parent --cap-drop ALL --bind / / --dev-bind /dev /dev --ro-bind $(shell_quote "$PROJ_ABS_REAL") $(shell_quote "$PROJ_ABS_REAL")"
      for allowed in "$READER_REPORT_DIR" "$READER_STATE_DIR"; do
        case "$allowed" in
          "$PROJ_ABS_REAL"/*)
            confined="$confined --bind $(shell_quote "$allowed") $(shell_quote "$allowed")"
            ;;
        esac
      done
      printf '%s' "$confined -- /bin/bash -c $(shell_quote "$launch")"
      ;;
    *)
      return 1
      ;;
  esac
}

# The reader's read access: a bare shared-object clone at scratch/repo.git.
# It has no working tree, so `git --git-dir=repo.git show/grep/log/archive`
# read any commit from the object store without materializing tracked files in
# scratch, while the launch sandbox keeps existing project paths read-only.
# --shared borrows the project's objects
# through an objects/info/alternates pointer instead of copying them, which is
# what makes a reader spawn cheap; the alternates target is the project's own
# object store, so the handle stays readable only while that project retains
# those objects (a project-side gc or prune can drop borrowed objects), and its
# lifetime is exactly this task's launch-to-teardown window - never archive a
# handle or point anything durable at it. The handle is DISPOSABLE AND
# PER-LAUNCH: whatever occupies scratch/repo.git (a stale handle from an
# earlier launch, or anything squatting on the path inside the already
# validated scratch) is removed unfollowed and replaced with a fresh clone of
# the CURRENT project, so one home/task/project launch reads exactly the
# project it was passed by construction; a same-boundary relaunch pins HEAD to
# its immutable task baseline instead of adopting a newer project HEAD.
reader_ensure_read_handle() {  # <canonical-scratch-dir> [task-base-commit]
  local handle="$1/repo.git" task_base_commit=${2:-}
  rm -rf "$handle" || {
    echo "error: could not remove the stale reader read handle at $handle" >&2
    return 1
  }
  git clone --quiet --bare --shared "$PROJ_ABS" "$handle" || {
    echo "error: could not create the reader read handle at $handle from $PROJ_ABS" >&2
    return 1
  }
  # The clone records origin=<project>, a configured ref-write path back into
  # the repository a reader may only read: `push origin --delete <branch>` from
  # the handle deletes any branch that is not the project's checked-out one -
  # on this repo, another task's unlanded fm/<id> work. Nothing in the reader
  # path uses origin (a bare clone materializes every ref locally, and
  # --shared's alternates pointer is independent of the remote), so removing it
  # keeps the boundary enforced instead of promised.
  git --git-dir="$handle" remote remove origin || {
    echo "error: could not remove the origin remote from the reader read handle at $handle; refusing to launch - a reader must never hold a ref-write path into the project" >&2
    return 1
  }
  if [ -n "$task_base_commit" ]; then
    if ! [[ "$task_base_commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
      || ! git --git-dir="$handle" cat-file -e "$task_base_commit^{commit}" 2>/dev/null; then
      echo "error: existing task base commit is invalid; refusing to replace its launch boundary" >&2
      return 1
    fi
    git --git-dir="$handle" update-ref --no-deref HEAD "$task_base_commit" || {
      echo "error: could not pin the reader read handle to the immutable task base commit" >&2
      return 1
    }
  fi
}

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).

# True when <path> is an isolated worktree of the spawning project: a real
# directory that is its own worktree root, is not the spawning project itself,
# and does not share the project repository's common git dir. SPAWN_WT_TOP is
# left holding the worktree root the check read, and SPAWN_WT_REASON a short
# phrase naming why a rejected path failed, both for the refusal messages.
#
# The worktree-discovery poll below reads this same predicate, so it can never
# adopt a path the guard would then refuse. That matters because a pane's cwd
# read is a snapshot of whatever process is in the foreground: while `treehouse
# get` is still fetching and checking a slot out, it reports the REPOSITORY's
# primary checkout as its own cwd. That path differs from a linked spawning
# project, so a poll comparing only against the project accepted it, and the
# guard then refused a launch whose slot treehouse went on to create normally.
# A read like that is a transient, not a destination: the poll keeps waiting.
SPAWN_WT_TOP=
SPAWN_WT_REASON=
spawn_worktree_isolated() {  # <path>
  local path=$1 wt_real wt_top_real wt_git_dir proj_common
  SPAWN_WT_TOP=
  SPAWN_WT_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    SPAWN_WT_REASON="it is not a readable directory"
    return 1
  fi
  SPAWN_WT_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to fm-spawn's OWN cwd and report the path as a subdirectory
  # of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$SPAWN_WT_TOP" ] && ! wt_top_real=$(cd "$SPAWN_WT_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  if [ "$wt_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_REASON="it is the spawning project itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked spawning home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) \
    && wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$PROJ_ABS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    SPAWN_WT_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    SPAWN_WT_REASON="it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
    return 1
  fi
  return 0
}

validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2
  if ! spawn_worktree_isolated "$WT"; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${SPAWN_WT_TOP:-none}'; spawning project '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# A pooled slot whose only deviation is a submodule gitlink is stale, not dirty:
# an earlier refresh moved the superproject and left the submodule checkout on
# the pin the previous base recorded. The refusal still stands and this gate
# never touches the slot; it only names the cause, because "is not clean" while
# the operator's own `git status` reads clean gives neither a cause nor a remedy.
# A pin is only reported as stale when the commit the slot holds is already
# contained in one of the submodule's remotes. Anything that cannot be proven
# contained - an unpushed commit, a submodule with no remote, a git error - falls
# through to the conservative uncommitted-work refusal, as does any entry that is
# not exactly a clean submodule sitting on a different pin. The diagnosis is
# buffered and only emitted once every entry qualifies, so it can never
# contradict the verdict.
#
# No remedy command is printed, deliberately. That containment check reads local
# refs only and never fetches, because this gate has to stay usable offline. A
# remote-tracking ref that has gone stale - its upstream branch deleted or
# force-pushed, and never pruned - therefore still reads as containment, so a
# commit that is really unpushed can look contained. Naming the submodule and both
# pins is what the operator actually needs; printing a checkout command on a
# judgement that can be fooled could cost them that commit, so the remedy is left
# to the operator, who can see the whole picture.
describe_stale_submodule_pins() {  # <worktree> <status>
  local worktree=$1 status=$2 line path want have unpushed lines=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in ' M '*) path=${line#' M '} ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" ls-files --stage -- "$path" 2>/dev/null | cut -c1-6)" = 160000 ] || return 1
    [ -z "$(git -C "$worktree/$path" status --porcelain 2>/dev/null)" ] || return 1
    want=$(git -C "$worktree" rev-parse --verify --quiet "HEAD:$path" 2>/dev/null) || return 1
    have=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ "$want" != "$have" ] || return 1
    unpushed=$(git -C "$worktree/$path" log --format=%H --max-count=1 "$have" --not --remotes -- 2>/dev/null) || return 1
    [ -z "$unpushed" ] || return 1
    lines+="error: submodule '$path' is checked out at $have, but this base records $want"$'\n'
  done <<EOF
$status
EOF
  [ -n "$lines" ] || return 1
  printf '%s' "$lines" >&2
}

spawn_worktree_has_origin_config() {  # <worktree>
  # Resolved remote.origin.* variables cover Git's effective include/includeIf chain; raw headers are also detected in the worktree config and any included file Git names through another variable. Git cannot enumerate a variable-less included file, so an empty origin section that is its only content remains indistinguishable from absence and intentionally proceeds rather than reimplementing Git's config parser.
  local worktree=$1 config origin key seen=$'\n'
  git -C "$worktree" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r origin key; do
    case $origin in file:*) config=${origin#file:} ;; *) continue ;; esac
    [ -f "$config" ] || continue
    case $seen in *$'\n'"$config"$'\n'*) continue ;; esac
    seen+="$config"$'\n'
    awk '/^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"[[:space:]]*\][[:space:]]*([#;].*)?$/ || /^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee]\.origin[[:space:]]*\][[:space:]]*([#;].*)?$/ { found=1 } END { exit !found }' "$config" && return 0
  done < <(git -C "$worktree" config --list --show-origin 2>/dev/null || true)
  return 1
}

freshen_spawn_worktree_base() {  # <worktree>
  local worktree=$1 default target expected actual status
  # A named branch is already task-owned history, not an idle detached pool
  # base. Preserve it exactly; only detached allocations are safe to refresh.
  git -C "$worktree" symbolic-ref --quiet HEAD >/dev/null 2>&1 && return 0
  # A local-only repository has no upstream base to refresh. Treehouse created
  # the lease from that repository's current local default branch already.
  git -C "$worktree" remote get-url origin >/dev/null 2>&1 || return 0
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
    echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  default=$(default_branch "$worktree") || {
    echo "error: could not determine origin's default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  target="origin/$default"
  if ! git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    echo "error: could not fetch '$target' for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  expected=$(git -C "$worktree" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    echo "error: '$target' is not a commit for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  if ! git -C "$worktree" reset --hard "$target" >/dev/null; then
    echo "error: could not reset pooled worktree '$worktree' to '$target'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree '$worktree' is at '${actual:-unknown}', not current '$target' ('$expected'); refusing to launch" >&2
    return 1
  fi
}

herdr_projection_meta_field_exact() {  # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower version 2 reclaim path.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  HERDR_RECOVERY_BACKEND=$old_backend
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    target_session=$FM_BACKEND_HERDR_SESSION
    target_pane=$FM_BACKEND_HERDR_PANE
    old_session=$(herdr_projection_meta_field_exact "$meta" herdr_session) || {
      echo "error: existing herdr metadata for $ID has an ambiguous session; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_WORKSPACE_ID=$(herdr_projection_meta_field_exact "$meta" herdr_workspace_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous workspace; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_TAB_ID=$(herdr_projection_meta_field_exact "$meta" herdr_tab_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous tab; refusing duplicate launch" >&2
      return 1
    }
    old_pane=$(herdr_projection_meta_field_exact "$meta" herdr_pane_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous pane; refusing duplicate launch" >&2
      return 1
    }
    [ "$target_session" = "$old_session" ] && [ "$target_pane" = "$old_pane" ] || {
      echo "error: existing herdr metadata for $ID has inconsistent endpoint identities; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_PANE_ID=$old_pane
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
      dead|no-agent) return 0 ;;
      live|unknown)
        echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
        return 1
        ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
    dead) return 0 ;;
    alive|unknown)
      echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
}

# Per-task temp root. Writers retain /tmp/fm-<id>/; readers take the home-scoped
# root from fm_reader_task_tmp, the one owner fm-teardown recomputes its
# destruction anchor from, so equal task ids in different homes cannot share
# custody and the two scripts can never disagree about the spelling.
TASK_TMP="/tmp/fm-$ID"
if [ "$ACCESS" = reader ]; then
  if ! fm_reader_task_tmp "$ID"; then
    echo "error: reader home identity '$FM_READER_TASK_TMP_HOMETAG' is not safe for a task temp root; refusing to launch" >&2
    exit 1
  fi
  TASK_TMP=$FM_READER_TASK_TMP
fi

# The access axis of an existing task id is immutable across relaunches: a
# writer record's worktree= names a pool lease that only a writer teardown
# returns, and a reader record's tasktmp= names a home-scoped scratch that only
# a reader teardown removes. Overwriting either record with the other axis
# would silently orphan that cleanup obligation (a writer flipped to reader
# leaks its pool worktree lease forever), so an axis flip refuses before any
# endpoint or metadata exists; tear the task down first, or relaunch it with
# its recorded axis.
if [ -f "$STATE/$ID.meta" ]; then
  if ! EXISTING_ACCESS=$(fm_meta_optional_exact_value "$STATE/$ID.meta" access); then
    echo "error: existing task $ID records ambiguous access metadata; expected exactly zero or one non-empty access= value - repair $STATE/$ID.meta before relaunching so a duplicate axis cannot launder a writer pool lease into a reader scratch record" >&2
    exit 1
  fi
  # The recorded axis is a closed set, exactly as teardown treats it: an
  # unknown value is record damage, and relaunching over it would launder the
  # damaged record into a clean writer or reader meta - erasing the evidence
  # while orphaning whichever cleanup obligation the original record carried.
  case "$EXISTING_ACCESS" in
    ''|writer|reader) ;;
    *)
      echo "error: existing task $ID records unknown access '$EXISTING_ACCESS'; this is record damage - repair $STATE/$ID.meta before relaunching so the damaged axis cannot be laundered into a clean writer or reader record" >&2
      exit 1
      ;;
  esac
  if [ "$ACCESS" = reader ] && [ "$EXISTING_ACCESS" != reader ]; then
    echo "error: existing task $ID is recorded as a writer task whose worktree must be returned to the pool; relaunching it with --access reader would overwrite that record and leak the pool lease - tear it down first or relaunch it as a writer" >&2
    exit 1
  fi
  if [ "$ACCESS" != reader ] && [ "$EXISTING_ACCESS" = reader ]; then
    echo "error: existing task $ID is recorded as a reader task with a scratch directory instead of a pool worktree; relaunching it without --access reader would overwrite that record and orphan its scratch cleanup - keep --access reader or tear it down first" >&2
    exit 1
  fi
fi

# The per-task metadata lock also guards automatic backlog creation and repair,
# so the row cannot change between this preflight and the later spawn commit.
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi

# Backlog preflight (bin/fm-backlog-transition-lib.sh). This spawn is about to
# become the sole owner of the row's In-flight transition, so prove the row is
# transitionable BEFORE any endpoint, worktree, or record exists: a refusal here
# costs nothing to unwind, while the same refusal after publication would strand
# a live pane. The authoritative mutation still runs under the meta lock below.
BACKLOG_TRANSITION=0
BACKLOG_ROW_STATE=
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if [ -z "$PROJECT_REPO" ]; then
    echo "error: task $ID cannot derive its backlog repo from project $PROJ_ABS" >&2
    exit 1
  fi
  if fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "$BACKLOG_TITLE_SET" -eq 1 ] && [ "$FM_BACKLOG_ROW_TITLE" != "$BACKLOG_TITLE" ]; then
      echo "error: task $ID already has backlog title '$FM_BACKLOG_ROW_TITLE', not requested title '$BACKLOG_TITLE'; refusing to reuse the id" >&2
      exit 1
    fi
    case "$FM_BACKLOG_ROW_REPO" in
      ''|-)
        if ! fm_backlog_mutate "$DATA" update "$ID" --repo "$PROJECT_REPO"; then
          echo "error: task $ID's backlog repo could not be set to $PROJECT_REPO ($FM_BACKLOG_TRANSITION_ERROR)" >&2
          exit 1
        fi
        if ! fm_backlog_row_probe "$DATA" "$ID" || [ "$FM_BACKLOG_ROW_REPO" != "$PROJECT_REPO" ]; then
          echo "error: task $ID's backlog repo did not read back as $PROJECT_REPO after update" >&2
          exit 1
        fi
        ;;
      "$PROJECT_REPO") ;;
      *)
        echo "error: task $ID's backlog repo is $FM_BACKLOG_ROW_REPO, but this spawn targets project $PROJECT_REPO" >&2
        exit 1
        ;;
    esac
    BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    if [ "$BACKLOG_TITLE_SET" -eq 0 ]; then
      echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; pass --backlog-title '<title>' to create it or add it first and re-run" >&2
      exit 1
    fi
    if ! fm_backlog_add "$DATA" "$ID" "$BACKLOG_TITLE" "$KIND" "$PROJECT_REPO"; then
      echo "error: task $ID's backlog item could not be created by tasks-axi ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      [ -z "$FM_BACKLOG_ADD_OUTPUT" ] || printf '%s\n' "$FM_BACKLOG_ADD_OUTPUT" >&2
      exit 1
    fi
    if ! fm_backlog_row_probe "$DATA" "$ID"; then
      echo "error: task $ID's newly-created backlog item could not be read back ($FM_BACKLOG_ROW_ERROR)" >&2
      exit 1
    fi
    BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
  else
    echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
    exit 1
  fi
  if ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
    echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
    exit 1
  fi
else
  BACKLOG_GATE_STATUS=$?
  if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
    echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  if [ "$BACKLOG_TITLE_SET" -eq 1 ]; then
    echo "error: --backlog-title requires an automatic tasks-axi backlog for this home; refusing to launch without creating the paired item" >&2
    exit 1
  fi
fi

READER_BASE_COMMIT=

# A reader relaunch destructively replaces scratch/repo.git (the per-launch
# disposable handle), which under a LIVE reader would silently swap the
# revision its in-flight reads come from - past the recorded base_commit=,
# with no refusal anywhere. Prove the recorded endpoint dead BEFORE anything
# destructive happens; only a positively dead endpoint (the recovery skill's
# relaunch case) may proceed. Alive endpoints refuse as duplicates, while an
# unknown liveness result preserves the task for targeted inspection.
if [ "$ACCESS" = reader ] && [ -f "$STATE/$ID.meta" ]; then
  if ! READER_BASE_COMMIT=$(fm_meta_optional_exact_value "$STATE/$ID.meta" base_commit) \
    || [ -z "$READER_BASE_COMMIT" ]; then
    echo "error: existing reader task $ID must record exactly one non-empty base_commit before relaunch; refusing to replace its immutable launch boundary" >&2
    exit 1
  fi
  if ! [[ "$READER_BASE_COMMIT" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
    || ! git -C "$PROJ_ABS" cat-file -e "$READER_BASE_COMMIT^{commit}" 2>/dev/null; then
    echo "error: existing task base commit is invalid; refusing to replace its launch boundary" >&2
    exit 1
  fi
  READER_EXISTING_BACKEND=$(fm_backend_of_meta "$STATE/$ID.meta")
  READER_EXISTING_TARGET=$(fm_backend_target_of_meta "$STATE/$ID.meta")
  if [ -z "$READER_EXISTING_TARGET" ]; then
    echo "error: existing reader task $ID records no endpoint to prove dead; refusing a duplicate launch before its read handle would be replaced - tear it down first" >&2
    exit 1
  fi
  READER_EXISTING_STATE=$(fm_backend_agent_alive "$READER_EXISTING_BACKEND" "$READER_EXISTING_TARGET")
  case "$READER_EXISTING_STATE" in
    dead) ;;
    unknown)
      echo "error: existing $READER_EXISTING_BACKEND endpoint for reader task $ID has unknown liveness; refusing a duplicate launch and preserving its scratch and metadata for targeted inspection - only a recovery-grade dead or missing endpoint licenses relaunch" >&2
      exit 1
      ;;
    *)
      echo "error: existing $READER_EXISTING_BACKEND endpoint for reader task $ID is $READER_EXISTING_STATE; refusing a duplicate launch - replacing the per-launch read handle under a possibly live reader would silently change the revision it reads; tear the task down first" >&2
      exit 1
      ;;
  esac
fi

# Reader environment (--access reader): build and validate the slot-free
# working directory BEFORE any endpoint exists, and start the task pane
# directly in it - the ship and writer scout pool path keeps starting in the
# project and moving via `treehouse get` below.
SPAWN_TASK_CWD="$PROJ_ABS"
if [ "$ACCESS" = reader ]; then
  if [ -L "$TASK_TMP" ] || [ -L "$TASK_TMP/scratch" ]; then
    echo "error: reader scratch path $TASK_TMP/scratch sits behind a symlink; refusing to launch before creating anything through it - a reader must never be able to write a tracked file" >&2
    exit 1
  fi
  mkdir -p "$TASK_TMP/scratch" || {
    echo "error: could not create the reader scratch directory at $TASK_TMP/scratch" >&2
    exit 1
  }
  validate_reader_scratch "$TASK_TMP/scratch" || exit 1
  READER_SCRATCH=$(cd "$TASK_TMP/scratch" && pwd -P)
  reader_sandbox_preflight || exit 1
  reader_ensure_read_handle "$READER_SCRATCH" "$READER_BASE_COMMIT" || exit 1
  SPAWN_TASK_CWD="$READER_SCRATCH"
  WT="$READER_SCRATCH"
fi

if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  exit 1
fi

W="fm-$ID"
if [ "$RELAUNCH" -eq 1 ]; then
  # Adopt the recorded endpoint instead of creating one. This is what keeps a
  # relaunch a REPLACEMENT rather than a second copy of the task: no new
  # terminal, no second worktree, and every uncommitted change left exactly
  # where the previous agent left it.
  T=$RELAUNCH_TARGET
  # A secondmate's home already resolved WT above through the same validation a
  # fresh secondmate spawn uses; every other kind takes the recorded worktree.
  [ "$KIND" = secondmate ] || WT=$RELAUNCH_WT
  if [ "$ACCESS" = reader ]; then
    validate_reader_scratch "$WT" || exit 1
  fi
  WT_TARGET=$T
  SES=${T%%:*}
else
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$SPAWN_TASK_CWD") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    SPAWN_TIMING_HERDR_START=$(fm_timing_now_ms)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    #
    # Placement, separately from labeling: a crewmate/scout belongs in the
    # EXACT herdr workspace this launching process is itself running in, which
    # only its own herdr pane identity can name (a same-labeled sibling
    # workspace must never be adopted). A --secondmate launch is the exception -
    # it stands up a DIFFERENT home's own workspace by design - so it asks for
    # the per-home container instead of inheriting this launcher's.
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_LAUNCHER_RELATIONSHIP=launcher-home
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
      HERDR_LAUNCHER_RELATIONSHIP=other-home
    fi
    HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE"; then
      HERDR_SES=$(fm_backend_herdr_session)
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        fm_backend_herdr_server_ensure "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not ensure its exact named session" >&2
          exit 1
        }
        # Exact recovery has no safe flat fallback on lock contention.
        spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" >&2
          exit 1
        }
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
        if [ "${HERDR_RECOVERY_BACKEND:-}" = herdr ]; then
          set +e
          FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_reclaim_task \
            "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_LABEL_HOME" \
            "$HERDR_RECOVERY_WORKSPACE_ID" "$HERDR_RECOVERY_TAB_ID" "$HERDR_RECOVERY_PANE_ID" \
            "$HERDR_PARENT_LABEL" "$W" "$SPAWN_TASK_CWD"
          HERDR_RECLAIM_STATUS=$?
          set -e
          case "$HERDR_RECLAIM_STATUS" in
            0)
              HERDR_PROJECTED=1
              HERDR_WORKSPACE_ID=$HERDR_RECOVERY_WORKSPACE_ID
              HERDR_SEEDED_DEFAULT_TAB_ID=""
              HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
              HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
              HERDR_PROJECTION_ABORT_CLEANUP=1
              HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
              HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
              HERDR_PROJECTION_ABORT_SEEDED_PANE=""
              ;;
            2)
              spawn_herdr_presentation_order_lock_release
              ;;
            *) exit 1 ;;
          esac
        else
          spawn_herdr_presentation_order_lock_release
        fi
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        # Session lock path resolution and exact parent binding both need a
        # live named-session socket before journal publication.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif [ "${FM_BACKEND_HERDR_PRESENTATION_PREFERENCE:-default}" = default ] \
          && ! fm_backend_herdr_presentation_default_supported "$STATE" "$HERDR_SES"; then
          :
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          # The projected child is placed and bound UNDER this launcher's exact
          # parent workspace. Its own herdr pane identity names that workspace
          # directly; the label lookup is only the fallback for a launcher with
          # no herdr ancestry at all. A claimed-but-broken identity refuses here
          # rather than projecting under a guessed parent.
          set +e
          fm_backend_herdr_launcher_identity "$HERDR_SES"
          HERDR_LAUNCHER_STATUS=$?
          set -e
          case "$HERDR_LAUNCHER_STATUS" in
            0) HERDR_PARENT_WORKSPACE_ID=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID ;;
            2) HERDR_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_parent_workspace_exact \
                 "$HERDR_SES" "$HERDR_PARENT_LABEL" 2>/dev/null || true) ;;
            *) spawn_herdr_presentation_order_lock_release; exit 1 ;;
          esac
          if [ -z "$HERDR_PARENT_WORKSPACE_ID" ]; then
            echo "warning: herdr presentation parent is absent or ambiguous; using the ordinary flat layout without projection" >&2
            spawn_herdr_presentation_order_lock_release
          else
            HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
            HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
            if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
              "$SPAWN_TASK_CWD" "$HERDR_PROJECTION_LABEL" "$W"; then
              if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
                HERDR_PROJECTION_ABORT_CLEANUP=1
                HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
                HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
                HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
              fi
              exit 1
            fi
            HERDR_PROJECTED=1
            HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
            HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
            HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
            HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
            HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
            HERDR_PROJECTION_ABORT_CLEANUP=1
            HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
            HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
            HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
            if ! fm_backend_herdr_projection_workspace_bind_parent \
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_WORKSPACE_ID"; then
              echo "warning: herdr presentation could not record the exact owning workspace for visual ordering" >&2
            fi
            fm_backend_herdr_projection_order_best_effort \
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PARENT_WORKSPACE_ID"
            HERDR_HOME_ID=$(fm_backend_herdr_projection_home_identity "$HERDR_LABEL_HOME" 2>/dev/null || true)
            if [ -n "$HERDR_HOME_ID" ] \
               && fm_backend_herdr_projection_live_binding_matches \
                 "$HERDR_SES" "$HERDR_PROJECTION_ID" "$HERDR_WORKSPACE_ID" \
                 "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$HERDR_PARENT_WORKSPACE_ID" \
                 "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W" \
               && fm_backend_herdr_projection_journal_bind \
                 "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_HOME_ID" "$HERDR_SES" \
                 "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
                 "$HERDR_PARENT_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W"; then
              :
            else
              echo "warning: herdr presentation could not publish an exact restart binding; this task will use flat fallback after a restart" >&2
            fi
          fi
        else
          echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
        fi
      fi
    fi
    if [ "$HERDR_PROJECTED" -ne 1 ]; then
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS" "$HERDR_LAUNCHER_RELATIONSHIP") || exit 1
      # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
      # (the second field empty when this call ADOPTED a pre-existing workspace
      # rather than creating a fresh one). Split on the guaranteed single tab
      # character; the seeded tab id is threaded through to create_task
      # untouched, which is the only function permitted to prune it (never
      # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
      CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
      HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
      HERDR_SES=${CONTAINER%%:*}
      HERDR_WORKSPACE_ID=${CONTAINER#*:}
      HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$SPAWN_TASK_CWD" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    fi
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    # Creation/reclaim has already published the exact restart binding.
    # Keep the task lock and abort journal, not the session-wide lock, while
    # allocating the worktree and starting the harness. Abort reacquires it.
    spawn_herdr_presentation_order_lock_release
    spawn_timing_finish herdr "$SPAWN_TIMING_HERDR_START"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$SPAWN_TASK_CWD") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$SPAWN_TASK_CWD") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
fi
if [ "$BACKEND" = herdr ]; then
  # Herdr's agent list exposes these display-only fields; keep technical tab
  # and workspace labels untouched because recovery owns their exact grammar.
  if [ -z "${HERDR_PARENT_LABEL:-}" ]; then
    HERDR_PARENT_LABEL=$(FM_HOME="${HERDR_LABEL_HOME:-$FM_HOME}" fm_backend_herdr_workspace_label)
  fi
  if [ "$KIND" = secondmate ]; then
    if [ -n "$TASK_CODE" ] && ! fm_backend_herdr_report_sidebar_metadata \
      "$HERDR_SES" "$HERDR_PANE_ID" "$TASK_CODE"; then
      echo "warning: herdr could not publish the secondmate sidebar code; the technical workspace label remains available" >&2
    fi
    if [ -n "${FM_BACKEND_HERDR_LAUNCHER_PANE_ID:-}" ] \
      && ! fm_backend_herdr_report_sidebar_metadata \
        "$HERDR_SES" "$FM_BACKEND_HERDR_LAUNCHER_PANE_ID" FM1; then
      echo "warning: herdr could not refresh the main sidebar code" >&2
    fi
  else
    if [ -n "$TASK_CODE" ] && ! fm_backend_herdr_report_sidebar_metadata \
      "$HERDR_SES" "$HERDR_PANE_ID" "$TASK_CODE" \
      "${HERDR_PARENT_WORKSPACE_ID:-}" \
      "$([ -n "${HERDR_PARENT_WORKSPACE_ID:-}" ] && printf '%s' "$HERDR_WORKSPACE_ID")"; then
      echo "warning: herdr could not publish the worker sidebar code; the technical task label remains available" >&2
    fi
  fi
fi
if [ "$KIND" = secondmate ]; then
  FM_INHERITABLE_CONFIG=trace-context \
    propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" \
    || echo "warning: secondmate $ID trace-context inheritance failed for $PROJ_ABS" >&2
fi
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
    zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_literal "$1" "$2" ;;
    cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  esac
}

kimi_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

# Kimi launch-readiness and delivery route their composer-emptiness half
# through the shared classifier (bin/fm-composer-lib.sh via
# fm_backend_composer_state), the same owner every steer and injection guard
# reads. This retired a fourth, spawn-local copy of composer shape knowledge -
# a hardcoded bordered `│ > │` regex that would have silently broken kimi
# spawn readiness fleet-wide the day kimi's TUI goes borderless the way
# claude's did. The banner and brief-echo greps below are launch-progress
# signals, not composer shapes, so they stay here.
kimi_composer_is_empty() {
  [ "$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null)" = empty ]
}

kimi_wait_for_ready() {
  local pane i=0 max=${FM_KIMI_READY_POLLS:-60} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    if printf '%s\n' "$pane" | grep -Fq 'Welcome to Kimi Code!' \
       || kimi_composer_is_empty; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_delivery_is_confirmed() {  # <plain-pane-capture>
  local pane=$1
  kimi_composer_is_empty || return 1
  if { printf '%s\n' "$pane" | grep -Fq '✨' \
       && printf '%s\n' "$pane" | grep -Fq 'Read the brief at'; } \
     || printf '%s\n' "$pane" \
       | grep -qiE 'context:[[:space:]]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[[:space:]]*%'; then
    return 0
  fi
  return 1
}

kimi_wait_for_delivery() {
  local pane i=0 max=${FM_KIMI_DELIVERY_POLLS:-40} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    kimi_delivery_is_confirmed "$pane" && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

cursor_wait_for_ready() {
  local verdict i=0 max=${FM_CURSOR_READY_POLLS:-60} interval=${FM_CURSOR_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    verdict=$(fm_backend_composer_state "$BACKEND" "$T" "$W")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

cursor_spawn_fail() {  # <detail>
  printf 'failed: %s\n' "$1" >> "$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

# Reuse a recorded writer lease under the acquisition lock. A later generic
# `treehouse get` cannot return that same durable lease, so recovery must not
# allocate a second slot.
spawn_reuse_recorded_writer_lease() {
  local meta=$STATE/$ID.meta json matches count entry path lease holder slot
  local recorded_wt recorded_lease recorded_slot recorded_real entry_real status
  recorded_wt=$(fm_meta_get "$meta" worktree)
  recorded_lease=$(fm_meta_get "$meta" treehouse_lease)
  recorded_slot=$(fm_meta_get "$meta" treehouse_slot)
  if [ -z "$recorded_wt" ] || [ -z "$recorded_lease" ] || [ -z "$recorded_slot" ]; then
    spawn_lease_refusal "recorded writer recovery is missing treehouse lease identity; refusing a generic allocation that would split the task"
    return 1
  fi
  json=$(CDPATH='' cd -- "$PROJ_ABS" && treehouse status --json 2>/dev/null) || {
    spawn_lease_refusal "treehouse occupancy for recorded writer $ID is unreadable; refusing to allocate another slot"
    return 1
  }
  [ -n "$json" ] || json='[]'
  recorded_real=$(real_path_or_raw "$recorded_wt")
  matches=$(printf '%s\n' "$json" | jq -c --arg path "$recorded_real" --arg raw "$recorded_wt" \
    --arg lease "$recorded_lease" --arg holder "$ID" --arg slot "$recorded_slot" \
    '[.[] | select((.lease_id|tostring)==$lease
        and (.lease_holder|tostring)==$holder
        and ((.path|tostring)==$path or (.path|tostring)==$raw)
        and ((.name|tostring)==$slot))]') || {
    spawn_lease_refusal "treehouse occupancy for recorded writer $ID is unreadable; refusing to allocate another slot"
    return 1
  }
  count=$(printf '%s\n' "$matches" | jq -r 'length') || {
    spawn_lease_refusal "treehouse occupancy for recorded writer $ID is unreadable; refusing to allocate another slot"
    return 1
  }
  [ "$count" = 1 ] || {
    spawn_lease_refusal "recorded writer $ID does not uniquely occupy its treehouse lease; refusing to allocate another slot"
    return 1
  }
  entry=$(printf '%s\n' "$matches" | jq -c '.[0]') || {
    spawn_lease_refusal "recorded writer occupancy could not be parsed"
    return 1
  }
  path=$(printf '%s\n' "$entry" | jq -er '.path | strings | select(length>0)') || {
    spawn_lease_refusal "recorded writer occupancy omitted its worktree path"
    return 1
  }
  lease=$(printf '%s\n' "$entry" | jq -er '.lease_id | strings | select(length>0)') || {
    spawn_lease_refusal "recorded writer occupancy omitted its lease identity"
    return 1
  }
  holder=$(printf '%s\n' "$entry" | jq -er '.lease_holder | strings | select(length>0)') || {
    spawn_lease_refusal "recorded writer occupancy omitted its task holder"
    return 1
  }
  slot=$(printf '%s\n' "$entry" | jq -er '.name | strings | select(length>0)') || {
    spawn_lease_refusal "recorded writer occupancy omitted its slot identity"
    return 1
  }
  status=$(printf '%s\n' "$entry" | jq -r '.status // empty')
  case "$status" in
    leased|in-use) ;;
    *)
      spawn_lease_refusal "recorded writer $ID is not occupying its leased worktree; refusing to allocate another slot"
      return 1
      ;;
  esac
  entry_real=$(real_path_or_raw "$path")
  if [ "$holder" = "$ID" ] && [ "$lease" = "$recorded_lease" ] && [ "$slot" = "$recorded_slot" ] \
    && { [ "$entry_real" = "$recorded_real" ] || [ "$path" = "$recorded_wt" ]; }; then
    :
  else
    spawn_lease_refusal "recorded writer occupancy does not match the saved treehouse lease identity"
    return 1
  fi
  WT=$path
  TREEHOUSE_ACQUIRED_PATH=$WT
  TREEHOUSE_LEASE=$lease
  TREEHOUSE_HOLDER=$holder
  TREEHOUSE_SLOT=$slot
  TREEHOUSE_ABORT_CLEANUP=0
}

# A relaunch adopts its recorded endpoint and worktree. A fresh reader already
# sits in its validated scratch directory and skips the pool path below.
if [ "$RELAUNCH" -eq 1 ]; then
  relaunch_wt_real=$(real_path_or_raw "$WT")
  relaunch_seen=
  for _ in $(seq 1 10); do
    relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
    sleep 0.5
  done
  if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
    if [ "$BACKEND" != herdr ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}', not its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
    relaunch_cd_path=${WT//\'/\'\\\'\'}
    spawn_send_text_line "$WT_TARGET" "cd -- '$relaunch_cd_path'" || {
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and could not be told to return to its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    }
    for _ in $(seq 1 10); do
      relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
      [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
      sleep 0.5
    done
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and did not return to its recorded worktree '$WT' when told to; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
  fi
  if [ "$KIND" != secondmate ] && [ "$ACCESS" != reader ]; then
    validate_spawn_worktree "relaunch" "$T"
  fi
elif [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$ACCESS" != reader ]; then
  SPAWN_TIMING_LEASE_START=$(fm_timing_now_ms)
  SPAWN_TIMING_LEASE_ACTIVE=1
  fm_lock_acquire_wait "$TREEHOUSE_ACQUISITION_LOCK" || {
    echo "error: treehouse acquisition exclusion could not be acquired" >&2
    exit 1
  }
  TREEHOUSE_ACQUISITION_LOCK_HELD=1
  if [ -f "$STATE/$ID.meta" ]; then
    spawn_reuse_recorded_writer_lease || exit 1
  else
    lease_attempt_marker=spawn-lease-attempted
    if SPAWN_TREEHOUSE_LEASE_ERROR_FILE=$(mktemp "$TASK_TMP/.treehouse-lease-stderr.XXXXXX" 2>/dev/null) \
      || SPAWN_TREEHOUSE_LEASE_ERROR_FILE=$(mktemp "${TMPDIR:-/tmp}/.treehouse-lease-stderr.XXXXXX" 2>/dev/null); then
      if lease_output=$(
        {
          printf '%s\n' "$lease_attempt_marker"
          CDPATH='' cd -- "$PROJ_ABS" \
            && treehouse get --lease --json --lease-holder "$ID"
        } 2>"$SPAWN_TREEHOUSE_LEASE_ERROR_FILE"
      ); then
        lease_status=0
      else
        lease_status=$?
      fi
      case "$lease_output" in
        "$lease_attempt_marker"*)
          TREEHOUSE_ALLOCATION=${lease_output#"$lease_attempt_marker"}
          TREEHOUSE_ALLOCATION=${TREEHOUSE_ALLOCATION#$'\n'}
          if [ "$lease_status" -eq 0 ]; then
            rm -f -- "$SPAWN_TREEHOUSE_LEASE_ERROR_FILE" 2>/dev/null || true
            SPAWN_TREEHOUSE_LEASE_ERROR_FILE=
          elif [ -r "$SPAWN_TREEHOUSE_LEASE_ERROR_FILE" ]; then
            lease_stderr=$(cat "$SPAWN_TREEHOUSE_LEASE_ERROR_FILE") || true
            spawn_lease_refusal "$(spawn_lease_cause "$lease_stderr")"
            exit 1
          else
            spawn_lease_refusal "$(spawn_lease_cause "")"
            exit 1
          fi
          ;;
        *)
          if TREEHOUSE_ALLOCATION=$(CDPATH='' cd -- "$PROJ_ABS" \
            && treehouse get --lease --json --lease-holder "$ID" 2>/dev/null); then
            rm -f -- "$SPAWN_TREEHOUSE_LEASE_ERROR_FILE" 2>/dev/null || true
            SPAWN_TREEHOUSE_LEASE_ERROR_FILE=
          else
            spawn_lease_refusal "$(spawn_lease_cause "")"
            exit 1
          fi
          ;;
      esac
    elif TREEHOUSE_ALLOCATION=$(CDPATH='' cd -- "$PROJ_ABS" \
      && treehouse get --lease --json --lease-holder "$ID" 2>/dev/null); then
      :
    else
      spawn_lease_refusal "$(spawn_lease_cause "")"
      exit 1
    fi
    WT=$(printf '%s\n' "$TREEHOUSE_ALLOCATION" | jq -er '.path | strings | select(length>0)') || {
      spawn_lease_refusal "treehouse acquisition omitted its worktree path"
      exit 1
    }
    TREEHOUSE_ACQUIRED_PATH=$WT
    TREEHOUSE_ABORT_CLEANUP=1
    TREEHOUSE_NEW_ALLOCATION=1
    TREEHOUSE_LEASE=$(printf '%s\n' "$TREEHOUSE_ALLOCATION" | jq -er '.lease_id | strings | select(length>0)') || {
      echo "error: treehouse acquisition omitted its lease identity" >&2
      exit 1
    }
    TREEHOUSE_HOLDER=$(printf '%s\n' "$TREEHOUSE_ALLOCATION" | jq -er '.lease_holder | strings | select(length>0)') || {
      echo "error: treehouse acquisition omitted its task holder" >&2
      exit 1
    }
    [ "$TREEHOUSE_HOLDER" = "$ID" ] || {
      echo "error: treehouse acquisition returned a contradictory task holder" >&2
      exit 1
    }
    TREEHOUSE_SLOT=$(printf '%s\n' "$TREEHOUSE_ALLOCATION" | jq -er '.name | strings | select(length>0)' 2>/dev/null) || {
      # Current Treehouse releases omit the slot name from `get --json`, while
      # `status --json` exposes it. Bind that name to the same path, lease, and
      # holder before recording it; recovery refuses to guess any of them.
      TREEHOUSE_SLOT=$(CDPATH='' cd -- "$PROJ_ABS" \
        && treehouse status --json 2>/dev/null \
        | jq -er --arg path "$WT" --arg real "$(real_path_or_raw "$WT")" \
          --arg lease "$TREEHOUSE_LEASE" --arg holder "$TREEHOUSE_HOLDER" '
            [.[] | select((.lease_id|tostring) == $lease
              and (.lease_holder|tostring) == $holder
              and (((.path|tostring) == $path) or ((.path|tostring) == $real)))]
            | if length == 1 then .[0].name | strings | select(length > 0) else error("ambiguous treehouse slot") end') || {
        echo "error: treehouse acquisition returned an unreadable slot identity" >&2
        exit 1
      }
    }
  fi
  spawn_send_text_line "$WT_TARGET" "cd -- $(shell_quote "$WT")"
  TREEHOUSE_ACQUIRED_REAL=$(real_path_or_raw "$WT")
  WT=

  # Wait for the pane's cwd to move from the project to the leased worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # The project comparison is physical: spawn_worktree_isolated screens each
  # read against PROJ_ABS_REAL, not PROJ_ABS, because a symlinked project prefix
  # would otherwise make the pane's OS-level cwd read differ from PROJ_ABS on
  # the very first poll, before the pane has actually moved.
  #
  # A single read that already looks isolated is not proof the pane settled
  # there: on some tmux/WSL setups a brand-new window's pane_current_path
  # transiently reports an unrelated stale path (seen live as another real git
  # checkout entirely) before the shell catches up with treehouse get's cd. That
  # stale path passes spawn_worktree_isolated too (it resolves to a real,
  # distinct worktree top-level), so accepting it on one read alone silently
  # records the wrong worktree= in state/<id>.meta. Require two consecutive
  # reads to agree on the same isolated path before accepting it; a mismatch
  # just becomes the new candidate rather than resetting the wait, so a pane
  # that is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  #
  # Every candidate is screened with the isolation guard's own predicate, so a
  # read of the project itself or of the repository primary checkout is treated
  # as the transient it is and the wait continues, instead of being adopted and
  # then refused by the guard.
  # A candidate the screen rejects is never adopted, so a host where the pane
  # never reaches an isolated worktree spends the whole window before refusing.
  # That wait is deliberate - telling a transient apart from a terminal
  # misconfiguration would need machinery this path does not want - so the
  # refusal has to be self-explaining instead: carry the last path seen and the
  # reason it was rejected, and report both at the deadline.
  candidate=""
  last_seen=""
  last_reason="the pane reported no path"
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$p" ] || last_seen="$p"
    if [ -n "$p" ] && spawn_worktree_isolated "$p"; then
      p_real=$(real_path_or_raw "$p")
      if [ "$p_real" = "$TREEHOUSE_ACQUIRED_REAL" ]; then
        if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
          WT="$p"
          break
        fi
        candidate="$p_real"
      else
        candidate=""
      fi
      candidate="$p_real"
    else
      candidate=""
      [ -z "$p" ] || last_reason=$SPAWN_WT_REASON
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter an isolated worktree within 60s (last seen '${last_seen:-none}': $last_reason; spawning project '$PROJ_ABS'); inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"

fi
if [ "$TREEHOUSE_NEW_ALLOCATION" -eq 1 ] || { [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ]; }; then
  freshen_spawn_worktree_base "$WT" || exit 1
fi
if [ "$SPAWN_TIMING_LEASE_ACTIVE" = 1 ]; then
  spawn_timing_finish lease "$SPAWN_TIMING_LEASE_START"
  SPAWN_TIMING_LEASE_ACTIVE=0
fi

PI_TRUST_AGENT_DIR=
if [ "$KIND" != secondmate ] && [ "$ACCESS" != reader ]; then
  case "$HARNESS" in
    pi|pi-signed)
      if [ -z "${PI_CODING_AGENT_DIR:-}" ] && [ -z "${HOME:-}" ]; then
        echo "error: refusing Pi spawn because neither HOME nor PI_CODING_AGENT_DIR is available" >&2
        exit 1
      fi
      PI_TRUST_AGENT_DIR=${PI_CODING_AGENT_DIR:-${HOME:-}/.pi/agent}
      if ! PI_CODING_AGENT_DIR="$PI_TRUST_AGENT_DIR" \
        "$FM_ROOT/bin/fm-pi-trust.sh" "$WT" "$PROJ_ABS" >/dev/null; then
        echo "error: could not pre-register Pi workspace trust for $WT; refusing to launch a Pi worker that would wedge on the trust dialog; inspect window $T" >&2
        exit 1
      fi
      ;;
  esac
fi

if [ "$HARNESS" = kimi ]; then
  SPAWN_TIMING_TRUST_START=$(fm_timing_now_ms)
  KIMI_TRUST_STATUS=0
  kimi_prest_trust_workspace "$WT" || KIMI_TRUST_STATUS=$?
  if [ "$KIMI_TRUST_STATUS" = 2 ]; then
    echo "error: refusing Kimi spawn because workspace trust could not be validated for $WT: fm-kimi-trust-check.sh could not evaluate the trust record (jq is required); install jq and retry" >&2
    exit 1
  elif [ "$KIMI_TRUST_STATUS" != 0 ]; then
    echo "error: refusing Kimi spawn because workspace trust could not be established for $WT" >&2
    exit 1
  fi
  spawn_timing_finish trust "$SPAWN_TIMING_TRUST_START"
fi

TASK_BASE_COMMIT=
if [ "$KIND" != secondmate ]; then
  EXISTING_META="$STATE/$ID.meta"
  if [ -f "$EXISTING_META" ] && [ "$(fm_meta_get "$EXISTING_META" worktree)" = "$WT" ]; then
    TASK_BASE_COMMIT=$(fm_meta_get "$EXISTING_META" base_commit)
  fi
  # A reader has no checkout: its base commit is the read handle's HEAD, the
  # exact revision its evidence is drawn from.
  if [ "$ACCESS" = reader ]; then
    base_commit_git=(git --git-dir="$WT/repo.git")
  else
    base_commit_git=(git -C "$WT")
  fi
  if [ -z "$TASK_BASE_COMMIT" ]; then
    TASK_BASE_COMMIT=$("${base_commit_git[@]}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
      echo "error: could not record the task base commit before launch" >&2
      exit 1
    }
  elif ! [[ "$TASK_BASE_COMMIT" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
    || ! "${base_commit_git[@]}" cat-file -e "$TASK_BASE_COMMIT^{commit}" 2>/dev/null; then
    echo "error: existing task base commit is invalid; refusing to replace its launch boundary" >&2
    exit 1
  fi
  # Project-local primary hooks use this task marker to stand down even when a
  # trusted task worktree auto-loads them.
  spawn_send_text_line "$T" "export FM_TASK_ID=$ID"
fi

# Go's build temp nested inside the per-task temp root (TASK_TMP, named above
# where the reader scratch derives from it). Go won't create GOTMPDIR, so mkdir
# before it is used; fm-teardown removes the whole root. Nested at
# <tasktmp>/gotmp so other per-task temp - a reader's scratch included -
# lives alongside, and teardown cleans one deterministic path. GOTMPDIR (not
# TMPDIR) is the targeted knob: TMPDIR is too broad (affects every program's
# temp, not just Go's).
mkdir -p "$TASK_TMP/gotmp"
OWNED_TASK_TMP=$TASK_TMP

# Export GOTMPDIR into the endpoint shell as soon as its owned directory is
# ready. This is environment preparation, not worker launch, and doing it
# before the remaining record construction keeps lifecycle writers serialized
# without making endpoint delivery wait on unrelated bookkeeping.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"

# Every supported worker harness inherits this launch-scoped Git configuration.
# The relay lives under the task temp root, never in the project, composes every
# pre-existing executable project hook, and Git reads it only in the worker
# process tree.
# Writer workers also receive push.default=current in that same scoped config,
# so no shared repository or global Git configuration is changed.
# An invalid inherited Git config or a relay-install failure is mandatory:
# installation or runtime failure refuses a commit or protected-destination push.
install_agent_coauthor_sanitizer() {
  local hooks=$TASK_TMP/git-hooks original_hooks prior_count next_count hook prepush original relay launch=$LAUNCH
  local -a task_git
  if [ "$ACCESS" = reader ]; then
    task_git=(git --git-dir="$WT/repo.git")
  else
    task_git=(git -C "$WT")
  fi
  # The parent process may use an in-memory Git config overlay for its own
  # hooks. It must not hide the project's configured hooks while this task's
  # relay is composed, nor leak into a separately-created worker pane whose
  # long-lived backend process cannot inherit that overlay's key/value pairs.
  prior_count=0
  next_count=1
  [ "$ACCESS" = reader ] || next_count=2
  hook=$hooks/commit-msg
  prepush=$hooks/pre-push
  original_hooks=$(GIT_CONFIG_COUNT=0 "${task_git[@]}" config --path --get core.hooksPath 2>/dev/null || true)
  if [ -z "$original_hooks" ]; then
    original_hooks=$(GIT_CONFIG_COUNT=0 "${task_git[@]}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || {
      echo "error: agent co-author sanitizer installation failed; refusing worker launch" >&2
      return 1
    }
  else
    case "$original_hooks" in
      /*) ;;
      *) original_hooks=$WT/$original_hooks ;;
    esac
  fi
  if ! mkdir -p "$hooks"; then
    echo "error: agent co-author sanitizer installation failed; refusing worker launch" >&2
    return 1
  fi
  # Same-task recovery may reuse this directory. Remove only executable relay
  # residue from its validated task-owned root before publishing this launch's
  # current relays; never recurse or delete anything outside that root.
  local stale
  for stale in "$hooks"/*; do
    [ -e "$stale" ] || continue
    [ -f "$stale" ] && [ -x "$stale" ] || continue
    if ! rm -f -- "$stale"; then
      echo "error: agent co-author sanitizer installation failed; refusing worker launch" >&2
      return 1
    fi
  done
  for original in "$original_hooks"/*; do
    [ -f "$original" ] && [ -x "$original" ] || continue
    [ "${original##*/}" != commit-msg ] || continue
    [ "${original##*/}" != pre-push ] || continue
    relay=$hooks/${original##*/}
    if ! {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'exec %s "\$@"\n' "$(shell_quote "$original")"
    } > "$relay" \
      || ! chmod 700 "$relay"; then
      echo "error: agent co-author sanitizer installation failed; refusing worker launch" >&2
      return 1
    fi
  done
  if ! {
    printf '%s\n' '#!/usr/bin/env bash'
    if [ -x "$original_hooks/commit-msg" ]; then
      printf '%s\n' "$(shell_quote "$original_hooks/commit-msg") \"\$@\""
      printf '%s\n' 'hook_status=$?'
      printf '%s\n' "[ \"\$hook_status\" -eq 0 ] || exit \"\$hook_status\""
    fi
    printf '%s\n' "if ! $(shell_quote "$FM_ROOT/bin/fm-commit-msg-sanitize.sh") \"\$@\"; then"
    printf '%s\n' '  echo "error: agent co-author sanitizer runtime failed; refusing commit" >&2'
    printf '%s\n' '  exit 1' 'fi' 'exit 0'
  } > "$hook" \
    || ! chmod 700 "$hook"; then
    echo "error: agent co-author sanitizer installation failed; refusing worker launch" >&2
    return 1
  fi
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -eu'
    # shellcheck disable=SC2016
    printf 'updates=$(mktemp %s) || { echo %s >&2; exit 1; }\n' \
      "$(shell_quote "$hooks/pre-push.XXXXXXXX")" \
      "$(shell_quote 'error: worker push policy could not stage updates; refusing push')"
    # shellcheck disable=SC2016
    printf '%s\n' 'cleanup() { rm -f "$updates"; }' 'trap cleanup EXIT' 'cat > "$updates"'
    # shellcheck disable=SC2016
    printf '%s\n' 'while IFS=" " read -r local_ref local_oid remote_ref remote_oid; do' \
      '  case "$remote_ref" in' \
      '    refs/heads/main|refs/heads/master)' \
      '      echo "error: refusing worker push to protected destination $remote_ref" >&2' \
      '      exit 1' \
      '      ;;' \
      '  esac' \
      'done < "$updates"'
    if [ -x "$original_hooks/pre-push" ]; then
      # shellcheck disable=SC2016
      printf 'if ! %s "$@" < "$updates"; then\n' "$(shell_quote "$original_hooks/pre-push")"
      printf '%s\n' '  exit 1' 'fi'
    fi
    printf '%s\n' 'exit 0'
  } > "$prepush" \
    || ! chmod 700 "$prepush"; then
    echo "error: worker push policy installation failed; refusing worker launch" >&2
    return 1
  fi
  LAUNCH="GIT_CONFIG_COUNT=$(shell_quote "$next_count") GIT_CONFIG_KEY_${prior_count}=core.hooksPath GIT_CONFIG_VALUE_${prior_count}=$(shell_quote "$hooks")"
  if [ "$ACCESS" != reader ]; then
    LAUNCH="$LAUNCH GIT_CONFIG_KEY_1=push.default GIT_CONFIG_VALUE_1=current"
  fi
  LAUNCH="$LAUNCH $launch"
}

# Per-harness turn-end hook where enabled: a file that touches
# state/<id>.turn-ended when the agent finishes a turn. Task-root hooks and token
# pointers stay out of Git's view in writer worktrees so they never block
# teardown's dirty check or leak into a commit; reader scratch has no Git view.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"

install_no_mistakes_stand_down_shim() {
  local dir="$STATE_REAL/$ID.no-mistakes-shim" wrapper tmp message payload
  case "$MODE" in direct-PR|local-only) ;; *) return 0 ;; esac
  wrapper="$dir/no-mistakes"
  if [ -L "$dir" ] || ! mkdir -p -- "$dir" || [ ! -d "$dir" ] || [ -L "$dir" ] \
    || ! chmod 700 "$dir" || [ -L "$wrapper" ]; then
    echo "error: no-mistakes delivery guard installation failed; refusing worker launch" >&2
    return 1
  fi
  tmp="$dir/.no-mistakes.${BASHPID:-$$}"
  if [ -e "$tmp" ] || [ -L "$tmp" ]; then
    echo "error: no-mistakes delivery guard installation found unsafe temporary path; refusing worker launch" >&2
    return 1
  fi
  message="no-mistakes is stood down for $MODE delivery (repository owner 09-03/09-07); use the direct path"
  payload=$(jq -cn --arg mode "$MODE" '{op:"no-mistakes-refused",mode:$mode}') || return 1
  if ! {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'FM_DATA_OVERRIDE=%s\n' "$(shell_quote "$DATA")"
    printf 'ID=%s\n' "$(shell_quote "$ID")"
    printf '. %s\n' "$(shell_quote "$SCRIPT_DIR/fm-telemetry-lib.sh")"
    printf 'fm_telemetry_record checks %s\n' "$(shell_quote "$payload")"
    printf 'printf %s >&2\n' "$(shell_quote "$message")"
    printf '%s\n' 'exit 2'
  } > "$tmp" || ! chmod 700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp"
    echo "error: no-mistakes delivery guard installation failed; refusing worker launch" >&2
    return 1
  fi
  LAUNCH="PATH=$(shell_quote "$dir"):\$PATH $LAUNCH"
}

exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$RELAUNCH" -eq 1 ]; then
  # Retire the previous incarnation's per-task harness wiring before arming the
  # new one. Without this, a harness switch would leave the old adapter's hook
  # files and turn-end token registry entries behind, and even a same-harness
  # relaunch would orphan the retired busy generation's token
  # (bin/fm-control-lib.sh owns where those artifacts live).
  clear_relaunch_harness_wiring "$RELAUNCH_PRIOR_HARNESS" "$WT" "$STATE_REAL" "$ID" || {
    echo "error: could not retire $RELAUNCH_PRIOR_HARNESS wiring for task $ID; refusing to arm the replacement" >&2
    exit 1
  }
  RELAUNCH_REPLACEMENT_PENDING=1
  RELAUNCH_REPLACEMENT_HARNESS=$HARNESS
  RELAUNCH_REPLACEMENT_STATE=$STATE_REAL
  RELAUNCH_REPLACEMENT_WT=$WT
fi
if [ "$KIND" != secondmate ]; then
  # Arm the semantic busy-state contract (bin/fm-busy-lib.sh) for every
  # adapter with a verified semantic source. The launch brief sent below IS a
  # submitted turn, so the seed record is busy/fm-spawn. The minted gen is
  # embedded into each adapter's wiring so an event from a superseded
  # incarnation is rejected as stale. Grok and rovo stay on their isolated
  # rendered-tail fallbacks and standalone Kimi stays unknown until
  # fm_busy_kimi_verified opens, so none of the three is armed here. Gemini IS
  # armed: its BeforeAgent / AfterAgent / SessionEnd hooks are a verified
  # open-close pair.
  BUSY_GEN=
  case "$HARNESS" in
    codex*)
      if fm_busy_codex_semantic_source; then
        echo "error: codex semantic busy-state wiring is not implemented; extend the probe only together with verified wiring" >&2
        exit 1
      fi
      ;;
  esac
  case "$HARNESS" in
    claude*|opencode*|pi|pi-signed|cursor-agent*)
      BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
        echo "error: failed to arm the busy-state contract for $ID" >&2
        exit 1
      }
      [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
      ;;
    gemini)
      if [ "$RAW_LAUNCH" -eq 0 ]; then
        BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
          echo "error: failed to arm the busy-state contract for $ID" >&2
          exit 1
        }
        [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
      fi
      ;;
    kimi*)
      # Standalone Kimi stays unknown until fm_busy_kimi_verified opens on a
      # live-verified installed version (bin/fm-busy-lib.sh owns the gate and
      # the required evidence). Arming without wiring would seed a busy record
      # nothing can ever clear, so the arm waits for the wiring.
      if fm_busy_kimi_verified; then
        echo "error: kimi semantic busy-state wiring is not implemented; open the gate only together with verified wiring" >&2
        exit 1
      fi
      ;;
  esac
  case "$HARNESS" in
    claude*)
      # Semantic busy-state hooks (bin/fm-busy-lib.sh): UserPromptSubmit opens
      # a turn; Stop (normal completion), StopFailure (API-error turn end),
      # and SessionEnd (process shutdown) all close it, so an abnormal end can
      # never leave a stale busy record. Claude fires no hook for a manual
      # interrupt: fm-control preserves the adapter-owned state, while the
      # legacy fm-send --key Escape path records idle/fm-interrupt. Stop keeps
      # the turn-ended NOTIFICATION touch for the watcher. Every
      # hook command tolerates a refused event (|| true) so a stale-gen writer
      # can never break Claude's own lifecycle.
      mkdir -p "$WT/.claude"
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source claude-hook"
      j_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true")
      j_stop=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
      j_stopfail=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event stop-failure 2>/dev/null || true")
      j_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$j_submit"}]}],"Stop":[{"hooks":[{"type":"command","command":"$j_stop"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$j_stopfail"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$j_sessionend"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    gemini)
      if [ "$RAW_LAUNCH" -eq 0 ]; then
      # Semantic busy-state hooks (bin/fm-busy-lib.sh): BeforeAgent opens a
      # turn and AfterAgent closes it, with SessionEnd closing on process
      # shutdown so an abnormal end can never leave a stale busy record.
      # Verified live on gemini-cli 0.58.0 as a clean open/close pair:
      # mid-turn only BeforeAgent had fired, and AfterAgent followed at turn
      # end. AfterAgent ALSO fires on a manual Escape interrupt (carrying
      # prompt_response "[no response text]"), so unlike Claude a cancelled
      # gemini turn closes its own record instead of leaving it busy.
      # SessionEnd was observed firing TWICE for one /quit; the busy writer is
      # idempotent for a repeated idle event, so the duplicate is harmless and
      # deliberately not de-duplicated here.
      # These are written into a FIRSTMATE-OWNED settings file under state/,
      # reached through GEMINI_CLI_SYSTEM_SETTINGS_PATH on the launch command,
      # never into the worktree's own .gemini/settings.json - that path is the
      # PROJECT's committed settings file, so writing it would clobber a
      # project's configuration and retiring it would delete a tracked file.
      # Hook arrays MERGE across gemini's settings layers rather than
      # overriding, so a project's own hooks still run alongside these.
      # AfterAgent keeps the turn-ended NOTIFICATION touch for the watcher.
      # Every hook command tolerates a refused event (|| true) so a stale-gen
      # writer can never break gemini's own lifecycle, and each prints the
      # empty JSON object gemini's hook contract requires on stdout.
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source gemini-hook"
      g_before=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event before-agent >/dev/null 2>&1 || true; printf '{}'")
      g_after=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event after-agent >/dev/null 2>&1 || true; printf '{}'")
      g_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end >/dev/null 2>&1 || true; printf '{}'")
      cat > "$STATE_REAL/$ID.gemini-settings.json" <<EOF
{"hooks":{"BeforeAgent":[{"hooks":[{"type":"command","command":"$g_before"}]}],"AfterAgent":[{"hooks":[{"type":"command","command":"$g_after"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$g_sessionend"}]}]}}
EOF
      fi
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-busy-state.js" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID;
        const statusType = event.properties.status && event.properties.status.type;
        if (statusType === "busy" || statusType === "retry") {
          if (activeSession === null) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
          return;
        }
        if (statusType === "idle" && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-status-idle");
        }
        return;
      }
      if (event.type === "session.idle") {
        if (event.properties.sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-idle");
        }
        await new Promise((resolve) => {
          execFile("touch", ["$TURNEND"], () => resolve());
        });
      }
    },
  };
};
EOF
      exclude_path '.opencode/plugins/fm-busy-state.js'
      ;;
    pi|pi-signed)
      # Written OUTSIDE the task root: Pi's trust gate fires on an extension loaded
      # from inside the project (verified live), but an explicit -e path elsewhere
      # loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", (event: any) => {
    execFile("touch", ["$TURNEND"]);
    const msg = event && event.message;
    const providerError = msg && msg.stopReason === "error";
    const toolResults = Array.isArray(event && event.toolResults) ? event.toolResults : [];
    const nonZeroToolResult = toolResults.some((result: any) => {
      const exitCode = result && result.exitCode;
      return result && (result.isError === true || result.error != null ||
        (exitCode != null && String(exitCode) !== "0") ||
        ["error", "failed", "failure"].includes(result.status));
    });
    if (!providerError && !nonZeroToolResult) return;
    const payload = JSON.stringify({
      type: "turn_end",
      message: providerError ? msg : undefined,
      toolResults: nonZeroToolResult ? toolResults : undefined,
    });
    const child = execFile("$FM_ROOT/bin/fm-quota-refusal.sh", ["apply", "--task", "$ID"], {
      env: { ...process.env, FM_HOME: "$FM_HOME", FM_STATE_OVERRIDE: "$STATE_REAL" },
    });
    child.stdin?.end(payload);
  });
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "progress", "$STATE_REAL", "$ID", "--gen", "$BUSY_GEN",
    ]);
  });
}
EOF
      ;;
    omp)
      # Written OUTSIDE the worktree like Pi's, but for a different reason: omp
      # has no trust gate, yet its cwd-only extension auto-discovery would load a
      # worktree-resident copy a SECOND time next to the explicit -e (verified,
      # omp 18.1.11). Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.omp-ext.ts" <<EOF
// Firstmate semantic busy-state events + turn-end notification for omp (Oh My
// Pi); written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_end" -> idle only when event.willContinue is not true. omp has no
// agent_settled at all (verified, omp 18.1.2 and 18.1.11: zero occurrences in
// the binary); agent_end is its loop boundary and willContinue is the reliable
// "another loop is coming" flag, covering auto-retries, compaction retries,
// queued follow-ups, and a session_stop-forced continuation. ctx.isIdle() is
// deliberately NOT consulted: at a natural TUI agent_end it still reads false
// because session_stop is awaited before the session settles, so gating on it
// would leave every completed turn recorded busy. "turn_end" fires at every
// inner turn boundary and stays a wake NOTIFICATION touch for the watcher,
// never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_end", (event: any) => {
    if (event && event.willContinue === true) return;
    return busyEvent("idle", "agent-end");
  });
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    cursor-agent*)
      # Cursor composes task-root-local hooks with the operator's global hooks.
      # beforeSubmitPrompt opens the semantic turn; stop and sessionEnd close it.
      # Stop also preserves the watcher's turn-end notification. Only the generated
      # hooks file is excluded through git info/exclude in writer worktrees, so
      # real project-owned Cursor configuration remains visible in diffs and pull
      # requests; reader scratch has no Git view to pollute.
      mkdir -p "$WT/.cursor"
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source cursor-hook"
      j_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event before-submit-prompt 2>/dev/null || true")
      j_stop=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
      j_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
      cat > "$WT/.cursor/hooks.json" <<EOF
{"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"$j_submit"}],"stop":[{"command":"$j_stop"}],"sessionEnd":[{"command":"$j_sessionend"}]}}
EOF
      exclude_path '.cursor/hooks.json'
      ;;
    codex*)
      # Semantic busy-state source negotiation (bin/fm-busy-lib.sh owns the
      # probes and the evidence). Neither Codex path is usable on the
      # installed binary: a pane worker's turns are not observable through
      # the app-server protocol, and its lifecycle hooks did not fire for a
      # firstmate-launched worker. Codex therefore classifies unknown with
      # an explicit reason rather than falling back to idle, and no busy
      # wiring is installed. The turn-end NOTIFICATION marker still rides
      # the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<writer-worktree>/.grok/hooks/, <writer-worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the task root as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # in the task root and excludes it from Git when that root is a writer worktree.
      # Result: the hook is outside the task root, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
    muse*)
      # muse's turn lifecycle is neither a hook nor a launch flag: its plugin
      # engine (the only hook surface) is disabled in the default build, so
      # firstmate reads muse's own durable session event log instead
      # (bin/fm-busy-lib.sh owns the fold). That is a PULL
      # source with no writer, so nothing is armed and no record is seeded -
      # exactly the reason standalone Kimi is not armed either.
      # This sidecar is the whole binding: it pins the sessions root, the
      # workspace root that muse records in each log's metadata, this pane's
      # binding identity, and every matching main log that predates this pane.
      # The classifier then accepts only one new matching log, so it never
      # guesses between pane incarnations. Recording the resolved root here
      # also means a later change to XDG_DATA_HOME cannot silently re-point an
      # already-running task at a different log tree.
      MUSE_SESSIONS_ROOT="${MUSE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/muse/sessions"
      MUSE_BINDING_ID="$$.$RANDOM.$(date +%s)"
      rm -f "$STATE/$ID.muse-session-current"
      {
        printf 'sessions_root=%s\n' "$MUSE_SESSIONS_ROOT"
        printf 'workspace_root=%s\n' "$WT"
        printf 'binding_id=%s\n' "$MUSE_BINDING_ID"
        while IFS= read -r MUSE_PRIOR_LOG; do
          [ -n "$MUSE_PRIOR_LOG" ] && printf 'prior_log=%s\n' "$MUSE_PRIOR_LOG"
        done <<EOF
$(fm_busy_muse_matching_logs "$MUSE_SESSIONS_ROOT" "$WT" || true)
EOF
      } > "$STATE/$ID.muse-session"
      ;;
    cursor*)
      # Cursor's turn lifecycle is neither a hook nor a launch flag: it writes
      # its own durable per-conversation transcript and brackets every turn
      # there (bin/fm-busy-lib.sh owns the fold). Like muse that is a PULL
      # source with no writer, so nothing is armed and no record is seeded.
      # This sidecar is the whole binding. It pins the projects root and the
      # exact workspace path cursor records in each project's
      # .workspace-trusted, plus every conversation that already exists for
      # that workspace, so a relaunch into a reused worktree folds its OWN
      # conversation instead of its predecessor's. The classifier then accepts
      # only one remaining conversation and never guesses between incarnations.
      CURSOR_PROJECTS_ROOT="${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}"
      {
        printf 'projects_root=%s\n' "$CURSOR_PROJECTS_ROOT"
        printf 'workspace_root=%s\n' "$WT"
        if CURSOR_PRIOR_PROJECT=$(fm_busy_cursor_project_dir "$CURSOR_PROJECTS_ROOT" "$WT" 2>/dev/null); then
          for CURSOR_PRIOR_DIR in "$CURSOR_PRIOR_PROJECT"/agent-transcripts/*/; do
            [ -d "$CURSOR_PRIOR_DIR" ] || continue
            printf 'prior_conversation=%s\n' "$(basename -- "${CURSOR_PRIOR_DIR%/}")"
          done
        fi
      } > "$STATE/$ID.cursor-session"
      ;;
    kimi*)
      # Kimi's Stop hook is global, but it is inert unless cwd contains this
      # task's token pointer and the token resolves through Firstmate's private
      # registry. The installer above owns the format-preserving config edit and
      # the always-zero, silent hook script.
      KIMI_AUTH_DIR="$HOME/.kimi-code/fm-turn-end.d"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$KIMI_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.kimi-turnend-token"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-kimi-turnend"
      exclude_path '.fm-kimi-turnend'
      ;;
  esac
fi

# Delivery posture recorded in meta so fm-teardown's safety check and the
# validate/merge stages can branch on it. A ship task carries the explicit
# per-task decision validated above; a secondmate's posture is fixed; a scout
# records none at all, because its deliverable is a report rather than a merge
# (fm-teardown.sh defaults an absent mode to no-mistakes, and fm-promote.sh
# requires an explicit mode when a scout is promoted to a ship task).
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  : "${SECONDMATE_PROJECTS:=}"
elif [ "$KIND" = scout ]; then
  MODE=
  YOLO=
fi

# Resolve the optional default-off W3C trace context (bin/fm-trace-context-lib.sh,
# docs/configuration.md): the one carrier both recorded in meta and injected into
# the pane, so an observer reads exactly what the child receives. Empty only when
# disabled or on entropy/validation failure. Reuses this task's already-recorded
# value on relaunch; any other spawn roots a fresh trace, never adopting this
# process's own ambient TRACEPARENT, so each routed task is its own trace
# boundary even under a persistent supervisor. Never aborts the spawn and adds
# only the cost of reading a few bytes of entropy.
#
# The session-start path owns input resolution. Spawn consumes only the frozen
# home-session state and reuses it for the carrier and Secondmate launch prefix.
#
# A remote secondmate launch is the one case where this process is not the home
# that owns the task's identity: the parent home resolved and will record the
# carrier, and this host only delivers it. The validated --traceparent value
# then IS the decision, so the enablement snapshot handed to the new Secondmate
# agrees with the carrier it receives exactly as on the local path.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  SPAWN_TRACE_EFFECTIVE=on
  SPAWN_TRACEPARENT=$TRACEPARENT_ARG
else
  SPAWN_TRACE_EFFECTIVE=$(fm_trace_context_session_effective "$STATE/.trace-context-effective")
  if [ "$SPAWN_TRACE_EFFECTIVE" = on ]; then
    SPAWN_TRACEPARENT=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$STATE/$ID.meta" || true)
  else
    SPAWN_TRACEPARENT=
  fi
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
TELEMETRY_MODEL=${MODEL:-}
TELEMETRY_MODEL_VERSION=${MODEL:-unreported}
TELEMETRY_EFFORT=${EFFORT:-default}
TELEMETRY_CLI_VERSION=unreported
TELEMETRY_CLI_BIN=${KIMI_BIN:-$HARNESS}
if [ "$ACCESS" != reader ] && command -v "$TELEMETRY_CLI_BIN" >/dev/null 2>&1; then
  TELEMETRY_CLI_VERSION=$("$TELEMETRY_CLI_BIN" --version 2>/dev/null | sed -n '1{s/\r$//;p;}' || true)
  [ -n "$TELEMETRY_CLI_VERSION" ] || TELEMETRY_CLI_VERSION=unreported
  TELEMETRY_CLI_VERSION=$(printf '%.160s' "$TELEMETRY_CLI_VERSION")
fi
TELEMETRY_PROJECT_REF=$(printf '%s' "$PROJ_ABS" | node -e 'const c=require("crypto");let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write("project_"+c.createHash("sha256").update(s).digest("hex").slice(0,32)+"\n"));')
TELEMETRY_CONFIG_SHA=
if [ -f "$CONFIG/crew-dispatch.json" ] && [ ! -L "$CONFIG/crew-dispatch.json" ]; then
  TELEMETRY_CONFIG_SHA=$(node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex")+"\n")' "$CONFIG/crew-dispatch.json")
fi
TELEMETRY_MACHINE_CONDITION=$(node -e 'const os=require("os");const cpus=typeof os.availableParallelism==="function"?os.availableParallelism():os.cpus().length;const load=os.loadavg()[0];if(!Number.isFinite(load)||load<0||!Number.isInteger(cpus)||cpus<1)process.exit(1);process.stdout.write(JSON.stringify({observedAt:new Date().toISOString(),loadAverage1m:load,logicalCpuCount:cpus}));') || {
  echo "error: model telemetry could not observe the machine condition; no model launch was submitted" >&2
  exit 1
}
TELEMETRY_INTAKE=$(jq -cn \
  --arg root "$TELEMETRY_TASK_ROOT" --arg parent "$TELEMETRY_PARENT" \
  --arg project "$TELEMETRY_PROJECT_REF" --arg harness "$HARNESS" \
  --arg model "$TELEMETRY_MODEL" --arg modelVersion "$TELEMETRY_MODEL_VERSION" \
  --arg effort "$TELEMETRY_EFFORT" --arg cliVersion "$TELEMETRY_CLI_VERSION" \
  --arg accountProfile "$ACCOUNT_PROFILE" \
  --arg taskClass "$TASK_CLASS" --arg exploration "$EXPLORATION" \
  --argjson machine "$TELEMETRY_MACHINE_CONDITION" \
  --arg config "$TELEMETRY_CONFIG_SHA" --arg started "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg provider "$DISPATCH_PROVIDER" --arg modelFamily "$DISPATCH_MODEL_FAMILY" \
  --arg routingSource "$ROUTING_SOURCE" --arg tachikomaDecision "$TACHIKOMA_DECISION" \
  --argjson tachikomaRoute "${TACHIKOMA_ROUTE:-null}" \
  --argjson dispatchResolved "$DISPATCH_RESOLVED" \
  --arg overrideReason "$DISPATCH_OVERRIDE_REASON" \
  --argjson overrideReasonSet "$DISPATCH_OVERRIDE_REASON_SET" \
  --arg matchedRule "$MATCHED_RULE" --argjson matchedRuleSet "$MATCHED_RULE_SET" \
  --arg quotaDecision "$QUOTA_DECISION" --arg quotaHeadroom "$QUOTA_HEADROOM" --arg quotaRunway "$QUOTA_RUNWAY" \
  'def tuple: {harness:$harness,provider:(if $provider=="" then null else $provider[0:96] end),model:(if $model=="" then null else $model end),effort:$effort,modelVersion:$modelVersion,cliVersion:$cliVersion} + (if $accountProfile=="" then {} else {accountProfile:$accountProfile} end);
   def dispatchAttestation:
     (if $dispatchResolved==1 then {kind:"resolved"}
      elif $overrideReasonSet==1 and $overrideReason!="" then {kind:"override",reason:$overrideReason[0:160]}
      else null end);
   def selectionExtras:
     {}
     | (if $routingSource=="" then . else . + {routingSource:$routingSource} end)
     | (if $tachikomaDecision=="" then . else . + {tachikomaDecision:$tachikomaDecision} end)
     | (if $modelFamily=="" then . else . + {dispatchModelFamily:$modelFamily[0:96]} end)
     | (if dispatchAttestation==null then . else . + {dispatchAttestation:dispatchAttestation} end);
   def quotaObj:
     {decision:(if $quotaDecision=="" then "not-applicable" else $quotaDecision end),
      headroom:(if $quotaHeadroom=="" then "unknown" else $quotaHeadroom end),
      runway:(if $quotaRunway=="" then "unknown" else $quotaRunway end),
      observedAt:($tachikomaRoute.quotaObservedAt // null)};
   {attemptClass:"real",source:"firstmate",taskRootId:(if $root=="" then null else $root end),parentAttemptId:(if $parent=="" then null else $parent end),projectRef:$project,taskClass:$taskClass,tuple:tuple,
    selection:({matchedRule:(if $matchedRuleSet==1 then $matchedRule else null end),configSha256:(if $config=="" then null else $config end),fitReasons:[],candidateAssessments:[{tuple:tuple,eligibility:"selected",reasons:[]}],quota:quotaObj} + selectionExtras),
    neutralExecution:{correlation:null,capabilityProfile:"not-applicable",owner:"not-applicable",phase:null,behavioralResult:"not-applicable"},evaluation:{kind:"none",fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},exploration:{kind:$exploration,machineCondition:$machine},startedAt:$started,privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"}}')
if ! TELEMETRY_RESULT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$FM_ROOT/bin/fm-model-telemetry.sh" intake --state "$STATE" --task "$ID" --payload "$TELEMETRY_INTAKE"); then
  echo "error: model telemetry intake refused; no model launch was submitted" >&2
  exit 1
fi
TELEMETRY_ATTEMPT=$(printf '%s' "$TELEMETRY_RESULT" | jq -er '.attemptId | select(test("^mra_[0-9a-f-]{36}$"))') || { echo "error: invalid model telemetry intake receipt" >&2; exit 1; }
TELEMETRY_TASK_ROOT=$(printf '%s' "$TELEMETRY_RESULT" | jq -er '.taskRootId | select(test("^mrt_[0-9a-f-]{36}$"))') || { echo "error: invalid model telemetry task root" >&2; exit 1; }
TELEMETRY_SESSION_ID=
if [ "$KIND" != secondmate ] && { [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; } \
  && [ "${PI_SESSION_ID_SUPPORTED:-0}" = 1 ]; then
  TELEMETRY_SESSION_ID=$TELEMETRY_ATTEMPT
elif [ "$KIND" != secondmate ] && [ "$HARNESS" = claude ] \
  && [ "${CLAUDE_SESSION_ID_SUPPORTED:-0}" = 1 ]; then
  TELEMETRY_SESSION_ID=${TELEMETRY_ATTEMPT#mra_}
fi
BILLING_POOL_REF=
if [ -n "${TACHIKOMA_ROUTE:-}" ]; then
  BILLING_POOL_REF=$(printf '%s' "$TACHIKOMA_ROUTE" | jq -r '.pool // empty') || BILLING_POOL_REF=
  case "$BILLING_POOL_REF" in ''|*[!A-Za-z0-9._:-]*) BILLING_POOL_REF= ;; esac
  [ "${#BILLING_POOL_REF}" -le 160 ] || BILLING_POOL_REF=
fi

SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
SPAWN_META_PATH="$STATE/$ID.meta"
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_TMP="$STATE/.$ID.meta.relaunch.${BASHPID:-$$}"
else
  SPAWN_META_TMP="$STATE/.$ID.meta.spawn.${BASHPID:-$$}"
  # Persistent supervisors are not backlog items, and their record is the only
  # durable handle for a live endpoint when later launch delivery cannot be
  # verified. Preserve that record for recovery exactly as before; ordinary
  # work keeps the paired-record rollback required by the backlog invariant.
  if [ "$KIND" = secondmate ]; then
    SPAWN_FRESH_COMMIT_PENDING=0
  else
    SPAWN_FRESH_COMMIT_PENDING=1
  fi
fi
SPAWN_META_PATH=$SPAWN_META_TMP
preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree treehouse_slot treehouse_lease project harness kind code code_parent parent child_seq access mode yolo tasktmp model effort busy_gen spawn_gen telemetry_session_id billing_pool_ref traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id home projects control_relaunch_tx", keys, " ")
      for (i in keys) owned[keys[i]] = 1
    }
    !($1 in owned)
  ' "$RELAUNCH_META"
}
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  [ -z "${TREEHOUSE_SLOT:-}" ] || echo "treehouse_slot=$TREEHOUSE_SLOT"
  [ -z "${TREEHOUSE_LEASE:-}" ] || echo "treehouse_lease=$TREEHOUSE_LEASE"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  [ -z "$TASK_CODE" ] || echo "code=$TASK_CODE"
  [ -z "$TASK_CODE_PARENT_ID" ] || echo "code_parent=$TASK_CODE_PARENT_ID"
  [ -z "$TASK_PARENT_ID" ] || echo "parent=$TASK_PARENT_ID"
  [ -z "$TASK_CHILD_SEQ" ] || echo "child_seq=$TASK_CHILD_SEQ"
  # access= is written only for readers, so every writer meta stays
  # byte-identical (absent access= means writer, mirroring absent backend=).
  [ "$ACCESS" != reader ] || echo "access=reader"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "$ACCOUNT_PROFILE" ] || echo "account_profile=$ACCOUNT_PROFILE"
  # routing_source= is written when the caller declared it or when a no-argument
  # secondmate recovery resolved a concrete config/secondmate-harness pin.
  # Other legacy metas stay byte-identical, and the escalation ladder
  # (fm-harness.sh escalate) reads absent as unknown provenance and stops.
  [ -z "$ROUTING_SOURCE" ] || echo "routing_source=$ROUTING_SOURCE"
  [ -z "$TACHIKOMA_DECISION" ] || echo "tachikoma_decision=$TACHIKOMA_DECISION"
  echo "telemetry_attempt=$TELEMETRY_ATTEMPT"
  echo "telemetry_task_root=$TELEMETRY_TASK_ROOT"
  [ -z "$TELEMETRY_SESSION_ID" ] || echo "telemetry_session_id=$TELEMETRY_SESSION_ID"
  [ -z "$BILLING_POOL_REF" ] || echo "billing_pool_ref=$BILLING_POOL_REF"
  [ -z "$TASK_BASE_COMMIT" ] || echo "base_commit=$TASK_BASE_COMMIT"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  # Default-off writes no traceparent= line.
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
  # Per-task no-mistakes run-root binding (finding 2): recorded only for a
  # no-mistakes ship, so crew-state and teardown observe the exact root this
  # worker uses. Absent for every other kind/mode, including pre-rollout tasks
  # whose runs live at the legacy shared root.
  if [ "${NM_HOME_BOUND:-0}" = 1 ]; then
    echo "nm_home=$NM_HOME"
  fi
  # Dispatch attestation record (AGENTS.md section 4): written when the
  # dispatch profiles or cooldowns are active, or when a secondmate relaunch
  # explicitly carries the same selection facts from the automatic quota owner.
  # A spawn with no applicable routing evidence stays byte-identical.
  # --dispatch-resolved records that the configured selection point was used;
  # --dispatch-override-reason records a deliberate departure and its reason.
  if [ -f "$CONFIG/crew-dispatch.json" ] || [ -f "$DATA/quota-cooldowns.json" ] \
    || [ "$DISPATCH_RESOLVED" -eq 1 ] || [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 1 ] \
    || [ "$DISPATCH_PROVIDER_SET" -eq 1 ] || [ "$DISPATCH_MODEL_FAMILY_SET" -eq 1 ]; then
    if [ "$DISPATCH_TACHIKOMA" -eq 1 ]; then
      echo "dispatch=tachikoma"
    elif [ "$DISPATCH_RESOLVED" -eq 1 ]; then
      echo "dispatch=resolved"
    elif [ "$DISPATCH_OVERRIDE_REASON_SET" -eq 1 ]; then
      echo "dispatch=override"
      echo "dispatch_override_reason=$DISPATCH_OVERRIDE_REASON"
    fi
    [ "$DISPATCH_PROVIDER_SET" -eq 0 ] || echo "dispatch_provider=$DISPATCH_PROVIDER"
    [ "$DISPATCH_MODEL_FAMILY_SET" -eq 0 ] || echo "dispatch_model_family=$DISPATCH_MODEL_FAMILY"
    [ "$MATCHED_RULE_SET" -eq 0 ] || echo "matched_rule=$MATCHED_RULE"
    [ "$QUOTA_DECISION_SET" -eq 0 ] || echo "quota_decision=$QUOTA_DECISION"
    [ "$QUOTA_HEADROOM_SET" -eq 0 ] || echo "quota_headroom=$QUOTA_HEADROOM"
    [ "$QUOTA_RUNWAY_SET" -eq 0 ] || echo "quota_runway=$QUOTA_RUNWAY"
  fi
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
} > "$SPAWN_META_PATH" || {
  echo "error: task record for $ID could not be prepared at $SPAWN_META_PATH" >&2
  exit 1
}
if [ "$RELAUNCH" -eq 0 ]; then
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  SPAWN_META_TMP=
  if reconcile_output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$FM_ROOT/bin/fm-pipeline.sh" reconcile "$ID" 2>&1 >/dev/null); then
    :
  else
    reconcile_status=$?
    reconcile_output=${reconcile_output//$'\n'/ }
    printf 'warning: pipeline record for %s was not reconciled (rc=%s): %s\n' \
      "$ID" "$reconcile_status" "$reconcile_output" >&2
  fi
fi

# Fuse the backlog In-flight transition into the publication that just created
# the record (bin/fm-backlog-transition-lib.sh owns the invariant). It runs under
# this task's own meta lock, so a steer or teardown racing the same id stays
# serialized exactly as before. The call itself is deferred to the final commit
# point below so every earlier launch-delivery failure remains unwindable.
spawn_commit_backlog_transition() {
  [ "$BACKLOG_TRANSITION" = 1 ] || return 0
  fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"
}

# The deferred-signal exit path's preservation report. A claim about preserved
# state is only trustworthy if that state is read back after the commit: the
# commit's own exit status has been observed to agree with a row that did not
# actually move (fm-yi4j evidence, 2026-09-05). This re-reads the paired record
# and the backlog row under the same per-task lock as the commit, repairs a row
# the commit believed it moved, and sets SPAWN_PRESERVED_CLAIM to exactly what
# was verified or attempted - never intent phrased as outcome.
spawn_report_preserved_state() {
  local repair_error=
  if ! fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE"; then
    SPAWN_PRESERVED_CLAIM="preservation could not be verified: its paired task record is missing; close out its backlog item by hand"
    return 1
  fi
  if ! fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item was not found; close out its paired task record by hand"
    else
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item state is unreadable (${FM_BACKLOG_ROW_ERROR:-no error recorded}); close out its paired task record and backlog item by hand"
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="verified preserved: its paired task record is present and its backlog item is In flight"
    return 0
  fi
  # The commit reported success, but the row does not read back In flight:
  # move it now under the same lock and verify the result before naming it.
  fm_backlog_start "$DATA" "$ID" || repair_error=$FM_BACKLOG_TRANSITION_ERROR
  if [ -z "$repair_error" ] \
     && fm_backlog_row_probe "$DATA" "$ID" \
     && [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="its backlog item did not read back In flight after the commit; it was moved to In flight now and verified, together with its paired task record"
    return 0
  fi
  SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item reads ${FM_BACKLOG_ROW_STATE:-unreadable}${repair_error:+, and moving it to In flight failed ($repair_error)}; close out its paired task record and backlog item by hand"
  return 1
}

if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_PUBLISH_STARTED=1
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: replacement task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  RELAUNCH_REPLACEMENT_PENDING=0
  SPAWN_META_PUBLISH_STARTED=0
  SPAWN_META_TMP=
  if reconcile_output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$FM_ROOT/bin/fm-pipeline.sh" reconcile "$ID" 2>&1 >/dev/null); then
    :
  else
    reconcile_status=$?
    reconcile_output=${reconcile_output//$'\n'/ }
    printf 'warning: pipeline record for %s was not reconciled (rc=%s): %s\n' \
      "$ID" "$reconcile_status" "$reconcile_output" >&2
  fi
fi
TREEHOUSE_ABORT_CLEANUP=0
TREEHOUSE_ACQUIRED_PATH=
if [ "$TREEHOUSE_ACQUISITION_LOCK_HELD" = 1 ]; then
  TREEHOUSE_ACQUISITION_LOCK_HELD=0
  fm_lock_release "$TREEHOUSE_ACQUISITION_LOCK" || true
fi
# A dispatch or relaunch keeps the per-task meta lock through launch delivery.
# The backlog mutation is deliberately the final fallible commit below, so
# teardown cannot remove a relaunched record while its replacement worker is
# still being delivered, cannot observe or complete a fresh provisional record
# between its state check and `tasks-axi start`, and a delivery failure cannot
# follow a committed In-flight transition.
if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
  fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK"
fi
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
fi
# A launched endpoint is durable even before harness readiness and backlog
# commit. Publish that provisional observation so a failed readiness gate still
# leaves the endpoint visible; the post-commit refresh below then converges the
# summary to the paired lifecycle state on success.
"$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

PI_WORKER_CONTEXT_FLAGS=
if [ "$RAW_LAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] \
  && { [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; } \
  && project_is_firstmate_repo "$PROJ_ABS"; then
  PI_WORKER_CONTEXT_FLAGS="--no-context-files --append-system-prompt $(shell_quote "$PI_FIRSTMATE_WORKER_SYSTEM_PROMPT") "
  PI_WORKER_CONTEXT_FLAGS+=$(pi_worker_module_context_flags "$WT" "$BRIEF")
fi

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_ompext=$(shell_quote "$STATE/$ID.omp-ext.ts")
sq_ompcfg=$(shell_quote "${OMP_WORKER_CFG:-$FM_ROOT/.omp/fm-worker-overlay.yml}")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
sq_worktree=$(shell_quote "$WT")
RESUMEFLAG=
SESSIONFLAG=
if [ "$RESUME_SESSION_SET" -eq 1 ]; then
  RESUMEFLAG='resume '
  SESSIONFLAG="$(shell_quote "$RESUME_SESSION") "
fi
LAUNCH=${LAUNCH//__RESUME__/$RESUMEFLAG}
LAUNCH=${LAUNCH//__SESSION__/$SESSIONFLAG}
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
if [ "$HARNESS" = rovo ]; then
  ROVOCONFIGOVERRIDE=$(rovo_config_override_flag "$EFFORT" "$DATA" "$STATE" "$ID") || {
    echo "error: could not resolve this task's home paths for rovo's allowedExternalPaths grant" >&2
    exit 1
  }
  LAUNCH=${LAUNCH//__ROVOCONFIGOVERRIDE__/$ROVOCONFIGOVERRIDE}
fi
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PIWORKERCONTEXT__/$PI_WORKER_CONTEXT_FLAGS}
PI_SESSION_FLAG=
CLAUDE_SESSION_FLAG=
if [ -n "$TELEMETRY_SESSION_ID" ]; then
  case "$HARNESS" in
    pi|pi-signed) PI_SESSION_FLAG="--session-id $TELEMETRY_SESSION_ID " ;;
    claude) CLAUDE_SESSION_FLAG="--session-id $TELEMETRY_SESSION_ID " ;;
  esac
fi
LAUNCH=${LAUNCH//__PISESSIONFLAG__/$PI_SESSION_FLAG}
LAUNCH=${LAUNCH//__CLAUDESESSIONFLAG__/$CLAUDE_SESSION_FLAG}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__OMPEXT__/$sq_ompext}
LAUNCH=${LAUNCH//__OMPWORKERCFG__/$sq_ompcfg}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
case "$HARNESS" in
  pi|pi-signed) LAUNCH=${LAUNCH//__PIBIN__/"$(shell_quote "$PI_BIN")"} ;;
  cursor|cursor-agent) LAUNCH=${LAUNCH//__CURSORBIN__/"$(shell_quote "$CURSOR_BIN")"} ;;
esac
LAUNCH=${LAUNCH//__WORKTREE__/$sq_worktree}
case "$HARNESS" in
  claude|codex|opencode|pi|pi-signed|grok|kimi|gemini|muse|rovo)
    LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI $LAUNCH"
    ;;
esac
# A selected account profile wins over the invoking firstmate's ambient store.
# Without a selection, preserve the existing forwarding behavior for a firstmate
# already running under CLAUDE_CONFIG_DIR; an unset value remains the byte-identical
# single-store default. shell_quote makes the directory one assignment value in
# the literal launch string, so its bytes are never evaluated as shell syntax.
if [ "$HARNESS" = claude ] && [ -n "$CLAUDE_ACCOUNT_CONFIG_DIR" ]; then
  LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_ACCOUNT_CONFIG_DIR") $LAUNCH"
elif [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fi
if [ "$KIND" != secondmate ] && [ "$ACCESS" != reader ] \
  && { [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; }; then
  LAUNCH="PI_CODING_AGENT_DIR=$(shell_quote "$PI_TRUST_AGENT_DIR") $LAUNCH"
fi
# A no-mistakes ship resolves its private NM_HOME at intake (finding 1): carry it
# across the pane process boundary as a shell-quoted prefix assignment on the
# literal launch command, the same verified channel that ships CLAUDE_CONFIG_DIR
# and GIT_CONFIG_COUNT. An export in this fm-spawn process alone never reaches a
# separately-created pane; the prefix assignment puts it in the agent's own
# environment so every child (including the worker's no-mistakes calls) inherits
# the exact root the observer queries. Skipped for a raw launch command, which
# is an escape hatch where the caller owns the full command verbatim (the same
# gate that skips the co-author sanitizer), and for a secondmate (no no-mistakes
# run). NM_HOME_BOUND is set only for a no-mistakes ship at intake.
if [ "${NM_HOME_BOUND:-0}" = 1 ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  LAUNCH="NM_HOME=$(shell_quote "$NM_HOME") $LAUNCH"
fi
install_no_mistakes_stand_down_shim || exit 1
if [ "$ACCESS" = reader ]; then
  LAUNCH=$(reader_confine_launch "$LAUNCH") || {
    echo "error: reader process confinement could not wrap the launch command; refusing to launch" >&2
    exit 1
  }
fi
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  sq_primary_home=$(shell_quote "$FM_HOME")
  # Keep this in step with fm_supervision_model (bin/fm-wake-lib.sh): Claude's
  # Stop auto-arm and Cursor's stop-hook park both run the watcher only BETWEEN
  # turns, so a fresh beacon with no live watcher is their healthy mid-turn state.
  # Pi and pi-signed secondmates previously received persistent here and now
  # receive extension to match fm_supervision_model's own table, so their pull
  # guard tolerates the extension hand-off exactly as a Pi primary does.
  case "$HARNESS" in
    claude|cursor) supervision_model=autoarm ;;
    pi|pi-signed|omp) supervision_model=extension ;;
    *) supervision_model=persistent ;;
  esac
  # Deliver the primary's EFFECTIVE trace-context decision as a normalized on/off
  # literal (never the raw FM_TRACE_CONTEXT string) so a FM_TRACE_CONTEXT override
  # on the primary reaches the secondmate's OWN workers, not just the copied
  # config/trace-context file: otherwise off would not disable them and on would
  # not enable them across the launch boundary (bin/fm-trace-context-lib.sh header).
  # Reuse the single frozen decision from the carrier resolution above so the
  # injected carrier and this on/off snapshot are guaranteed to agree.
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$sq_primary_home FM_HOME=$sq_home FM_TRACE_CONTEXT=$SPAWN_TRACE_EFFECTIVE FM_SUPERVISION_MODEL=$supervision_model $LAUNCH"
fi
# Ordinary worker templates inherit the launch-scoped sanitizer. A raw launch
# command is the captain-supplied escape hatch and must stay byte-identical.
if [ "$RAW_LAUNCH" -eq 0 ] && [ "$KIND" != secondmate ]; then
  install_agent_coauthor_sanitizer
fi
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  # Fresh publication still owns the lock. Relaunch deliberately uses a short
  # independent critical section so other metadata interfaces can serialize.
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK"
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] \
     || ! awk -F= '$1 != "traceparent"' "$meta" > "$SPAWN_META_TMP" \
     || ! printf 'traceparent=%s\n' "$SPAWN_TRACEPARENT" >> "$SPAWN_META_TMP" \
     || ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$meta" "task record" "$STATE"; then
    status=1
    rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  fi
  SPAWN_META_TMP=
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$SPAWN_META_LOCK" || status=1
    SPAWN_META_LOCK_HELD=0
  fi
  return "$status"
}

# Send through the exact channel that already shipped GOTMPDIR, so every backend
# and harness - ship, scout, and secondmate - gets it before launch. Skipped
# entirely when trace context is off.
if [ -n "$SPAWN_TRACEPARENT" ]; then
  if spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then
    if ! spawn_record_traceparent; then
      LAUNCH="unset TRACEPARENT; $LAUNCH"
    fi
  else
    TRACE_SEND_STATUS=$?
    if [ "$TRACE_SEND_STATUS" -eq 2 ]; then
      echo "error: trace-context input could not be cleared for $W; refusing to append the launch command" >&2
      exit 1
    fi
    LAUNCH="unset TRACEPARENT; $LAUNCH"
  fi
fi
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  LAUNCH_ENV_PREFIX='/usr/bin/env -i'
  for env_name in HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE \
    TMPDIR TMP TEMP GOTMPDIR TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH \
    HERDR_PANE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID \
    CMUX_SOCKET_PATH ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID FM_ZELLIJ_SESSION \
    FM_TASK_ID \
    $LAUNCH_ENV_NAMES; do
    # Only validated names enter shell syntax. Values expand once, quoted, in
    # the pane shell and never become source text or spawn-process snapshots.
    # shellcheck disable=SC2016
    printf -v env_arg '${%s+"%s=$%s"}' "$env_name" "$env_name" "$env_name"
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX $env_arg"
  done
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    # shellcheck disable=SC2016
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX "'${TRACEPARENT+"TRACEPARENT=$TRACEPARENT"}'
  fi
  LAUNCH="$LAUNCH_ENV_PREFIX /bin/sh -c $(shell_quote "$LAUNCH")"
fi
SPAWN_TIMING_LAUNCH_START=$(fm_timing_now_ms)
# Herdr's pane run types and submits atomically; avoid the two round-trips and
# fixed settle sleeps required by literal-text delivery on other backends.
if [ "$BACKEND" = herdr ]; then
  spawn_send_text_line "$T" "$LAUNCH"
else
  sleep 0.3
  spawn_send_literal "$T" "$LAUNCH"
  sleep 0.3
fi
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
fi
# The single Enter here submits the literal launch command to the pane shell.
# Herdr's pane run already submits atomically, so only other backends need it.
if [ "$BACKEND" != herdr ]; then
  spawn_send_key "$T" Enter
fi
if [ "$HARNESS" = kimi ]; then
  if ! kimi_wait_for_ready; then
    kimi_spawn_fail "kimi did not show a verified ready signal before brief delivery"
    exit 1
  fi
  KIMI_POINTER="Read the brief at $BRIEF_REAL and follow it exactly."
  KIMI_SUBMIT_RETRIES=${FM_KIMI_SUBMIT_RETRIES:-3}
  KIMI_SUBMIT_SLEEP=${FM_KIMI_SUBMIT_SLEEP:-${FM_KIMI_POLL_INTERVAL:-0.5}}
  KIMI_SUBMIT_SETTLE=${FM_KIMI_SUBMIT_SETTLE:-0}
  if ! KIMI_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
      "$BACKEND" "$T" "$KIMI_POINTER" "$KIMI_SUBMIT_RETRIES" \
      "$KIMI_SUBMIT_SLEEP" "$KIMI_SUBMIT_SETTLE" "$W" "$HARNESS"); then
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  fi
  if [ "$KIMI_SUBMIT_VERDICT" = send-failed ]; then
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  fi
  if ! kimi_wait_for_delivery; then
    kimi_spawn_fail "kimi brief pointer delivery was not confirmed"
    exit 1
  fi
fi
if [ "$HARNESS" = cursor-agent ] && [ "$ACCESS" != reader ]; then
  if ! cursor_wait_for_ready; then
    cursor_spawn_fail "cursor-agent did not show a verified empty composer before brief delivery"
    exit 1
  fi
  CURSOR_POINTER="Read the launch brief at $BRIEF_REAL and follow it exactly."
  CURSOR_PAYLOAD=$(printf '%s' "$CURSOR_POINTER" | "$FM_ROOT/bin/fm-operational-input.sh" encode launch-brief) || {
    cursor_spawn_fail "cursor-agent launch brief could not be encoded"
    exit 1
  }
  CURSOR_SUBMIT_RETRIES=${FM_CURSOR_SUBMIT_RETRIES:-3}
  CURSOR_SUBMIT_SLEEP=${FM_CURSOR_SUBMIT_SLEEP:-${FM_CURSOR_POLL_INTERVAL:-0.5}}
  CURSOR_SUBMIT_SETTLE=${FM_CURSOR_SUBMIT_SETTLE:-0}
  CURSOR_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
    "$BACKEND" "$T" "$CURSOR_PAYLOAD" "$CURSOR_SUBMIT_RETRIES" \
    "$CURSOR_SUBMIT_SLEEP" "$CURSOR_SUBMIT_SETTLE" "$W" "$HARNESS") || {
    cursor_spawn_fail "cursor-agent launch brief could not be submitted"
    exit 1
  }
  if [ "$CURSOR_SUBMIT_VERDICT" != empty ]; then
    cursor_spawn_fail "cursor-agent launch brief could not be submitted"
    exit 1
  fi
fi
spawn_timing_finish launch "$SPAWN_TIMING_LAUNCH_START"
SPAWN_TIMING_BUSY_START=$(fm_timing_now_ms)
if [ "$KIND" != secondmate ] && [ -n "${BUSY_GEN:-}" ]; then
  fm_busy_record_read "$STATE_REAL" "$ID" >/dev/null 2>&1 || true
fi
if [ "$KIND" = secondmate ] && [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

# This is the commit point: all endpoint and harness delivery that can reject
# the spawn has succeeded. Re-read and transition while holding the same
# per-task lock as metadata publication, then and only then report success.
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  SPAWN_TIMING_LOCK_WAIT_STARTED=$(fm_timing_now_ms)
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_TIMING_LOCK_WAIT_NOW=$(fm_timing_now_ms)
  SPAWN_TIMING_LOCK_WAIT_MS=$((SPAWN_TIMING_LOCK_WAIT_NOW - SPAWN_TIMING_LOCK_WAIT_STARTED))
  [ "$SPAWN_TIMING_LOCK_WAIT_MS" -ge 0 ] || SPAWN_TIMING_LOCK_WAIT_MS=0
  SPAWN_META_LOCK_HELD=1
fi
SPAWN_DEFERRED_SIGNAL=
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  trap 'SPAWN_DEFERRED_SIGNAL=HUP' HUP
  trap 'SPAWN_DEFERRED_SIGNAL=INT' INT
  trap 'SPAWN_DEFERRED_SIGNAL=TERM' TERM
fi
SPAWN_BACKLOG_COMMIT_STATUS=0
# Both the commit and its preservation read-back run under this task's meta
# lock, so an unresponsive tasks-axi there would hold the lock - and every
# lifecycle operation waiting on it - open ended, with even the deferred
# signals parked in a trap. Bound each invocation
# (bin/fm-backlog-transition-lib.sh's fm_tasks_axi): a timed-out call
# fails through the ordinary error plumbing, and the interrupted exit path
# reports it as the reason the preservation could not be verified.
FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
if spawn_commit_backlog_transition; then
  SPAWN_FRESH_COMMIT_PENDING=0
else
  SPAWN_BACKLOG_COMMIT_STATUS=$?
  if spawn_commit_backlog_transition; then
    SPAWN_BACKLOG_COMMIT_STATUS=0
    SPAWN_FRESH_COMMIT_PENDING=0
  fi
fi
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  if [ "$RELAUNCH" -eq 0 ]; then
    if spawn_fresh_commit_rollback; then
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); its record was removed so no worker is left that the backlog does not own - close out endpoint $T and local copy $WT by hand, then re-run the spawn" >&2
    else
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR), and failed-dispatch cleanup is incomplete; the provisional record may remain at $STATE/$ID.meta - close out endpoint $T and local copy $WT by hand, then remove the record and busy state before retrying" >&2
    fi
  else
    echo "error: task $ID was republished but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); fix the backlog and re-run the relaunch" >&2
  fi
fi
trap - HUP INT TERM
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  exit "$SPAWN_BACKLOG_COMMIT_STATUS"
fi
if [ -n "$SPAWN_DEFERRED_SIGNAL" ]; then
  case "$SPAWN_DEFERRED_SIGNAL" in
    HUP) SPAWN_DEFERRED_SIGNAL_STATUS=129 ;;
    INT) SPAWN_DEFERRED_SIGNAL_STATUS=130 ;;
    TERM) SPAWN_DEFERRED_SIGNAL_STATUS=143 ;;
  esac
  # Keep deferring further signals so the read-back below cannot itself be
  # killed halfway through verifying or correcting the preserved state.
  trap 'SPAWN_DEFERRED_SIGNAL=$SPAWN_DEFERRED_SIGNAL' HUP INT TERM
  # Deliberately unguarded against errexit: a failed verification still set
  # the honest attempted-preservation claim the exit below reports.
  spawn_report_preserved_state || true
  trap - HUP INT TERM
  echo "error: spawn of $ID was interrupted after launch delivery began; $SPAWN_PRESERVED_CLAIM" >&2
  exit "$SPAWN_DEFERRED_SIGNAL_STATUS"
fi
fm_lock_release "$SPAWN_META_LOCK"
SPAWN_META_LOCK_HELD=0

# Publish the observational summary only after endpoint delivery and the paired
# backlog transition commit. Refreshing the provisional record here used to
# delay delivery and could leave a stale summary behind when a later step
# rolled that record back.
"$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
spawn_timing_finish busy "$SPAWN_TIMING_BUSY_START"

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
SPAWN_ACCESS=
[ "$ACCESS" != reader ] || SPAWN_ACCESS=" access=reader"
spawn_timing_emit 0
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_ACCESS$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT"
