# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## Delegated continuation on Pi

The installed Pi 0.87.1 SDK and CLI passed the isolated delegated-continuation guard on 2026-09-28.
Run `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh` to refresh this evidence without Herdr or external provider traffic.
The guard uses a deterministic local provider with the real session, tool, extension and persistence owners.
Its same-input v1/v2 comparison observed MAIN routine tool calls of 1 and 0 respectively; the delegated path persisted a provisional precheck while retaining an open goal and served an independent MAIN request before branch settlement.
This measures routing and host concurrency, not model judgment quality or production latency.
The final guard output was `ok - real Pi delegated continuation preserves open goals and handles MAIN input concurrently`.

## Live Pi continuation

The 2026-09-26 Pi 0.87.1 / pi-openai-codex-compat 0.0.16 live run verified heartbeat delivery and retained task obligations through provider success and compaction on isolated Herdr.
[Supervision verification](supervision.md#live-continuation-and-heartbeat) owns the exact command and output.
The portable handoff matrix covers the unchanged inbox plane for tmux, Herdr, Zellij, Orca, and cmux through controlled backend fixtures.
Codex primary and TraeX worker behavior gains no Pi scheduling loop; the shared semantic guards apply only after explicit task enrollment.

## Harness detection precedence

`bin/fm-harness.sh` owns retained marker and process-ancestry precedence.
Verified on 2026-09-24 with the candidate code and portable real-process fixtures:

```sh
bin/fm-test-run.sh --jobs 1 tests/fm-harness-precedence.test.sh tests/fm-session-lock-ancestry.test.sh tests/fm-harness-support.test.sh
```

```text
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=8222
```

The tests distinguish inherited markers from owning Pi and Codex processes, refuse removed selections, and retain historical records and uncommitted work on refused lifecycle operations.
Historical live lock owners continue excluding a competing writer without becoming supported session identities.
The real installed-harness refresh command remains `tests/fm-harness-liveness-drift-live-e2e.test.sh`.

## Herdr-only fork boundary (2026-09-25)

This fork supports Herdr as its terminal provider.
Pi and Codex retain primary and worker roles; TraeX remains worker-only.
Historical records that omit `backend=` still mean tmux and are refused without migration or cleanup.

Linux candidate checks on 2026-09-25 used Pi 0.87.1, Codex 0.156.1, traecli 0.207.1 and Herdr 0.8.0.
The fixture used an empty synthetic startup digest, so this is role and control evidence, not a full startup-content proof.
The exact commands and private home-independent receipts are retained with the feature-pruning task evidence.

The token-free Calm and branch responsiveness guards passed through named Herdr labs:

```sh
FM_CALM_PI_E2E=1 tests/fm-calm-pi-herdr-live-e2e.test.sh
FM_PI_BRANCH_RESPONSIVENESS_E2E=1 tests/fm-pi-branch-responsiveness-live-e2e.test.sh
```

The full credentialed Pi primary guard passed on the candidate in a bounded baseline/candidate comparison.
The unchanged baseline both passed once and failed an Ahoy ASCII near-miss case once; earlier candidate near-miss failures therefore have no demonstrated causal link to this pruning.
[`supervision.md`](supervision.md#post-start-instruction-refresh) owns the compact-refresh guard and its current baseline/candidate limitation.
The TraeX guard independently verified initial execution and durable steering through file receipts on both versions, but both failed to prove an empty composer after Escape and Ctrl+U (`state=unknown`).
Native unknown remains unknown; the full interrupt sequence has no current passing claim.
Baseline failures document retained limitations; they do not by themselves waive acceptance or establish a complete root cause.
Historical observations below remain dated evidence, not restored backend support or current installation instructions.

## Composer classification matrix

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape fleet-wide; each backend contributes only a capture and a capability descriptor.
The retained idle-composer observations from the 2026-08-10 tmux 3.6a macOS arm64 run were:

```text
ok - codex (codex-cli 0.146.0): real idle composer classifies empty
ok - pi (0.84.0): real idle composer classifies empty
```

`FM_COMPOSER_MATRIX_LIVE=1 tests/fm-composer-matrix-live-e2e.test.sh` refreshes the installed retained harness surfaces.
Portable geometry and typed-input safety are covered by `tests/fm-composer-lib.test.sh` and `tests/fm-composer-ghost.test.sh`.

### 2026-09-15 codex-cli 0.154.0 idle starfield and status footer through Herdr

Idle, codex 0.154 animates a braille starfield on the row above its bold `›` prompt row, on the `›` row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on the row below it, then draws a status footer reading `gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief`.
The starfield cells are truecolor greys whose luminance runs from roughly 66 to 165, so the cells above the 128 ghost ceiling survive ghost stripping, and the footer is bright, non-blank, and carries no structural edge.

The capture is a read-only `herdr pane read <pane> --format ansi` of the live pane; its 20-row tail is fed to the shared classifier with the descriptor above:

```sh
herdr pane read w4Z:p2 --format ansi > codex-0.154-idle-herdr.ansi
bash -c '. bin/fm-composer-lib.sh
  caps=$(printf "styled=1\ncursor=0\nidentity=1\nrows=20")
  fm_composer_classify_screen "$caps" "$(tail -n 20 codex-0.154-idle-herdr.ansi)"'
```

Observed output on the same capture before the fix (`bin/fm-composer-lib.sh` at b85e28b5) and then after it:

```text
pending
empty
```

Before the fix the bare `›` shape extended its wrap region over the two rows beneath the glyph (`kind=bare first=17 last=19` within the 20-row tail), read the surviving starfield cells and the footer as wrapped typed input, and answered `pending`.
The steering doorbell (`fm_task_inbox_ring` in `bin/fm-task-inbox-lib.sh`) defers on exactly that verdict, so every ring for the pane was recorded as skipped and the marked request was reported as a missed delivery.
After the fix, braille-only rows bound the wrap region (the status footer sits beneath the starfield row, so the region never reaches it), starfield cells behind the placeholder are stripped from the glyph row, and the same capture reads `empty` under the Herdr and Zellij styled profiles and with a tmux cursor on the glyph row, while a plain (`styled=0`) capture still reads `unknown`, never `pending`.
A second read-only capture of the same pane, taken during the fix with a bright starfield cell drawn between the `›` and the placeholder, read `pending` before and `empty` after as well.
`test_matrix_codex_idle_starfield_furniture` in `tests/fm-composer-lib.test.sh` carries both samples byte-for-byte, the divergence (the same screen with letters in place of the starfield reads `pending`), and the over-stripping negatives (wrapped typed input, braille mixed with text, a typed row with a middle dot, and the footer or a starfield row alone).

The current live guard launches installed Codex in a named Herdr lab and checks the retained styled composer capture; it spends no model tokens:

```sh
tests/fm-composer-codex-idle-live-e2e.test.sh
```

The 2026-09-15 run predated the current Herdr lab guard: its then-current tmux guard skipped on this Herdr-only machine, so the read-only Herdr capture above supplied that dated evidence.
The current guard reports the actual rendered surface rather than assuming every Codex session draws the historical starfield.

## Steering-inbox doorbell

The steering channel's one behavioral assumption - a real worker agent follows the constant self-describing doorbell line (list the inbox, read and act on its records in numeric order, then `mv` each into `handled/`) - was verified on 2026-08-23 against every installed verified harness, on tmux 3.6a, macOS arm64, on an isolated private socket, driving the REAL `bin/fm-send.sh` end to end (durable record plus doorbell, with one mid-wait re-ring playing the watcher's role).

```sh
FM_SEND_INBOX_LIVE_E2E=1 tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

The retained observed outputs were:

```text
ok - codex (codex-cli 0.147.0): the doorbell reached a real worker, which acted and acked with the mv
ok - pi (0.84.1): the doorbell reached a real worker, which acted and acked with the mv
```

The doorbell pre-check skips only proven pending text; an ambiguous composer does not indefinitely suppress a recoverable constant notification.
Portable ladder and enqueue regressions remain in `tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh`.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.
Default-on presentation projection has its own floor at Herdr 0.8.0, protocol 19, verified below.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed protocol-16 compatibility shapes:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

### In-turn transcript input consumption

Verified on 2026-09-29 with Herdr 0.8.0, Codex 0.158.0 and TraeX 0.207.1 on Linux.
The named-lab guard below uses installed default TUIs and a local simulated provider inside private namespaces.
It submits two durable doorbells during one actual root turn, verifies both typed UserMessage events belong to that turn, checks one tool execution reads and acknowledges both records, and observes busy followed by idle through the public classifier.
The provider advances only after actual tool-result requests, so speculative requests cannot substitute for execution.
The prior start-count fence reproduced busy followed by unknown for both adapters on this sequence.
Private task evidence preserves independent before/after transcript hashes and the bounded event inventory.

```sh
HERDR_LAB_HELPER=/home/chengyuhang/firstmate/bin/fm-herdr-lab.sh \
  FM_BUSY_TRANSCRIPT_LAB_TASK=remove-codex-transcript-version-gate-20260929 \
  FM_BUSY_TRANSCRIPT_LIVE_E2E=1 \
  bin/fm-test-run.sh tests/fm-busy-transcript-live-e2e.test.sh
```

The additional stable success lines are:

```text
ok - codex multiple in-turn steering receipts settle without invented starts
ok - traex multiple in-turn steering receipts settle without invented starts
```

The same guard covers fresh launch, exact original-process recovery, single-message steering, interruption, tool and simulated API failures, process exit and endpoint death.
It does not establish authenticated provider availability.
Portable coverage demonstrates that nonempty future `cli_version` values do not change transcript admission; the stable compatibility contract is owned by [Busy state is semantic, per adapter](../architecture.md#busy-state-is-semantic-per-adapter).
The accounting, structural transcript admission, bounded refusal categories and conservative legacy-input limits belong to [`fm-busy-transcript.py`](../../bin/fm-busy-transcript.py).
Portable coverage in `tests/fm-busy-state.test.sh` additionally separates partial and complete reads, unmatched and duplicate inputs, append-only compaction, unsupported replacement/rotation, malformed records and wrong identity.

### TraeX thin worker adapter

The fresh-directory trust path was verified on 2026-09-24 with traecli 0.207.1 internal edition and Herdr 0.8.0.
That combination renders `enter continue | esc quit` and reports native `unknown` at the exact chooser, so the guard binds the TraeX identity, pane, and isolated cwd to that complete rendering before sending Enter.
The same live run observed native `working`, verified the worker's benign instruction output, kept the post-turn native `unknown` unclassified, cleaned up the pane, and preserved the default-session tripwire.

```sh
HERDR_LAB_HELPER=/home/chengyuhang/firstmate/bin/fm-herdr-lab.sh \
  FM_TRAEX_HERDR_LAB_TASK=fix-traex-trust-recognition-20260924 \
  FM_TRAEX_HERDR_LIVE=1 \
  bin/fm-test-run.sh tests/fm-traex-harness-live-e2e.test.sh
```

```text
ok - real TraeX fresh-copy trust reached native working through generic Herdr
note: Herdr kept native status unknown after the completed TraeX turn
ok - real TraeX processed the benign initial instruction after guarded trust acceptance
ok - native unknown remains unclassified after completion rather than being treated as idle
ok - real TraeX exit cleanup uses the generic Herdr owner
traex=traecli 0.207.1(internal edition)
herdr=herdr 0.8.0
ok - real TraeX lab teardown preserved the default Herdr session
ok - thin TraeX/Herdr smoke completed
```

#### Preserved launch and steering recovery

Verified on 2026-09-26 with Herdr 0.8.0, TraeX 0.207.1 internal edition, and Codex 0.156.1 on Linux.
`tests/fm-busy-transcript-live-e2e.test.sh` runs the installed default TUIs in private user, PID, and network namespaces with a local simulated Responses provider and a generated non-default Herdr session.
Its spawn regression creates a private harmless `true` hook and observes the real `Hooks need review` screen after directory trust.
The failed spawn preserves its original records; only the test approves that known private hook, then the recovery entrypoint and ordinary inbox doorbell execute and acknowledge the original instruction.
The same guard passes each public check's unchanged JSON stdout directly to public apply, restores a missing original generation for both retained transcript adapters, verifies that each real TUI reads and acknowledges one durable steering record, and checks later input, interrupt, completion, API failure, and endpoint death.
The procedure and refusal boundaries belong to `bin/fm-busy-event.sh recover`, with mutation mechanics in `bin/fm-busy-recover.sh` and provenance checks in `bin/fm-busy-transcript.py`.

```sh
HERDR_LAB_HELPER=/home/chengyuhang/firstmate/bin/fm-herdr-lab.sh \
  FM_BUSY_TRANSCRIPT_LAB_TASK=fix-traex-launch-steering-recovery-20260925 \
  FM_BUSY_TRANSCRIPT_LIVE_E2E=1 \
  bin/fm-test-run.sh tests/fm-busy-transcript-live-e2e.test.sh
```

```text
ok - codex real original-generation recovery
ok - codex recovered steering read and acknowledged one durable message
ok - traex real original-generation recovery
ok - traex recovered steering read and acknowledged one durable message
ok - real hook trust is not accepted; failed spawn preserves original records and durable instruction
ok - late trust, same-process recovery and ordinary re-ring executed the original durable instruction
ok - real legacy missing-generation recovery preserves absent spawn_gen and ordinary fm-send reaches another vendor turn
ok - recovery preserves the worker commit and unfinished work
ok - real normal fm-spawn launch confirmed without requiring recovery
```

TraeX can expose both its root TUI and a same-name app-server process in the foreground process list.
Recovery selects the unique native process carrying the exact generation-bearing launch argument, then verifies its kernel arguments and process identity; a name alone is insufficient.
`tests/fm-busy-state.test.sh` supplies Codex and TraeX real-process regressions for that distinction, stale-lock reclamation without stealing a live owner, ambiguous roots, replacement processes, changed task or home receipts, missing or contradictory records, repeated recovery, and interrupted recovery.
`tests/fm-backlog-atomicity.test.sh` checks that pre-launch failure still rolls back while post-submission failure preserves ownership; `tests/fm-busy-adapter-wiring.test.sh` covers retained Pi extension guarantees.
The provider is simulated, so this guard proves vendor lifecycle and local delivery behavior, not an external model service or production credentials.

The broader ordinary TraeX worker/scout lifecycle was verified on 2026-08-11 with traecli 0.200.19 internal edition and Herdr 0.8.0.
That guarded smoke used the same generic Herdr input, current-state, key, and cleanup owners as the other harnesses, while the only TraeX-specific backend fact was exact fresh-directory trust recognition.

```sh
bin/fm-test-run.sh tests/fm-traex-harness.test.sh
FM_TRAEX_HERDR_LIVE=1 bin/fm-test-run.sh tests/fm-traex-harness-live-e2e.test.sh
```

Bounded live output:

```text
ok - real TraeX fresh-copy trust reached native working through generic Herdr
ok - real TraeX steering and current state use generic Herdr owners
ok - real TraeX interrupt clearing stays on generic key and send paths
ok - real TraeX exit cleanup uses the generic Herdr owner
traex=traecli 0.200.19(internal edition)
herdr=herdr 0.8.0
ok - real TraeX lab teardown preserved the default Herdr session
ok - thin TraeX/Herdr smoke completed
```

The smoke intentionally proves no exactly-once completion, crash-perfect edge recovery, or harness-specific lifecycle storage.
Ambiguous interruption remains owned by ordinary endpoint inspection, stale supervision, and stuck-worker recovery.

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible on some harnesses; live Claude Code 2.1.236 on Herdr 0.8.0 kept `agent_status=idle` for an entire landed turn, including a multi-second tool call, so submit confirmation falls through to the shared composer verdict. Native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Client selection

Measured 2026-09-08 on a macOS aarch64 host running a Herdr 0.9.0 server (protocol 22) while `~/.local/bin/herdr` still held the self-updated 0.8.2 client (protocol 20) ahead of the Nix-managed 0.9.0 client on `PATH`.

```sh
~/.local/bin/herdr --version
~/.local/bin/herdr pane get wCY:p2 --session fm-lab-client-select; echo "rc=$?"
~/.local/bin/herdr status --json --session fm-lab-client-select | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
herdr status --json --session fm-lab-client-select | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
```

```text
herdr 0.8.2
{"id":"cli:pane:get","error":{"code":"protocol_mismatch","message":"client protocol 20 is older than server protocol 22; upgrade the Herdr client before using this command"}}
rc=1
{"c":20,"s":{"running":true,"protocol":22,"compatible":false}}
{"c":22,"s":{"running":true,"protocol":22,"compatible":true}}
```

The refusal is a JSON error on stderr with exit 1 and empty stdout, and both client generations report `.server.compatible` and `.server.protocol` per named session, which is what the selection in `bin/backends/herdr.sh` reads.
`tests/fm-backend-herdr.test.sh` pins the bypass, same-process same-session caching, cross-session isolation, forced reselection, and both status shapes against fakes; `tests/fm-backend-herdr-smoke.test.sh` refreshes the real status normalization against the installed binary's running lab server.

### Submit confirmation

`tests/fm-backend-herdr.test.sh` covers native transition, composer fallback, and queued-Enter confirmation behavior with deterministic fixtures.
The previous live submit guard launched only a removed harness and has been retired.
Retained real-runtime evidence must be refreshed through an isolated Herdr lab before changing vendor-dependent submit signals.

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=fm-lab-fm-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/kunchen/.config/herdr/sessions/fm-lab-fm-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Firstmate requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Presentation topology

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

That historical run included multi-home coverage. The retained single-home suite verifies ordinary worker placement, focus preservation, serialized ordering, and exact-pane cleanup without provisioning other homes.

Observed retained guarantees include:

```text
ok - real Herdr lab: concurrent primary workers form one stable contiguous block without active workspace/tab drift
ok - real Herdr lab: exact task-pane close removes the projected workspace with no unrestored wrong-focus interval
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed token and refusal guarantees:

```text
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab: three repeated concurrent create/order/cleanup waves have zero active workspace or tab drift
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and the value `off` opts out; since 2026-08-05 an absent file enables the projection only at or above the 0.8.0 floor recorded under "Presentation version floor" below, and `on` is the explicit opt-in that survives the floor:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
Recovery-path presentation lock contention remains a deliberate hard refusal rather than a flat fallback.
That run measured the default-on projection on Herdr 0.8.0 only, while the focus-flash regression below was last run on 0.7.5 before the flip, so neither run covered a defective release under default-on projection; the version floor and the focus-flash suite's Part C close that gap.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-08-05 against both Herdr 0.7.5 protocol 17 and Herdr 0.8.0 protocol 19 on macOS aarch64, with the 0.7.5 run using the pinned upstream release binary first on `PATH`:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-focus-flash-e2e.test.sh
```

Observed output on Herdr 0.7.5:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a defective release: a bounded wrong-focus window of 4 samples was fully restored to the anchor
ok - version floor: herdr 0.7.5 protocol 17 remains conservatively below the floor with steal_live=1
ok - version floor: an unconfigured home falls back flat on herdr 0.7.5 and the explicit opt-in still projects
evidence: herdr=0.7.5 protocol=17 steal_live=1 floor_verdict=1 default-session-tripwire=armed
```

Observed output on Herdr 0.8.0:

```text
ok - old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout
ok - version floor: herdr 0.8.0 protocol 19 is at or above the floor and preserves focus
ok - version floor: an unconfigured home stays projected on herdr 0.8.0 and the explicit opt-in agrees
evidence: herdr=0.8.0 protocol=19 steal_live=0 floor_verdict=0 default-session-tripwire=armed
```

The same guarded named-lab command passed on 2026-09-03 against Herdr 0.8.2 after this regression joined the required `real-herdr-gated` lane.
It reported `steal_live=0 floor_verdict=0 default-session-tripwire=armed`, with the fleet's default session unchanged before and after.

Part C is the case the suite could not reach before: a doomed pane whose shell holds a persistent background child fails the lone-idle-shell proof on every sample, so the plan takes the plain explicit close, in the geometry where the closing workspace's right neighbour is a spacer rather than the focused anchor.
On 0.7.5 that fallback exposed a bounded four-sample wrong-focus window and restored the anchor exactly; on 0.8.0 the same fallback exposed none, which is why default-on projection is floored at 0.8.0 rather than mitigated further below it.
The suite also cross-checks its own Part A measurement against the floor classifier on whatever release it runs, so a drifted protocol-to-release mapping fails there rather than silently gating on the wrong thing.

### Attached foreground viewer

A pseudo-terminal registers as a Herdr foreground client only when its window grid is non-zero.
`script` and a bare `pty.fork()` from a non-tty parent both start at 0x0, which is why PR #4131 could validate only the detached half of the teardown focus guard and left its four attached-client scenarios untested.
The guarded `viewer start` path fixes the pty at the proven 40-row by 120-column grid, sets that size on the master fd before the fork, and scrubs inherited `HERDR_*` variables, which makes the attached scenarios reachable from a headless runner.

Measured on 2026-09-11 against Herdr 0.9.0 protocol 22 on macOS 26.5.2 aarch64 with Python 3.14.6:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-attached-viewer-live-e2e.test.sh
```

```text
ok - attached viewer: a pty sized before the fork registers as a real Herdr foreground client
ok - attached viewer: a live client on the target tab refuses the close and keeps the pane
ok - attached viewer: focus moving onto the target between planning and mutation still blocks the close
ok - attached viewer: a close preserves the fresh non-target focus the viewer moved to
ok - attached viewer: the projection seeded-tab prune refuses while a live client watches it
ok - attached viewer: detaching releases the refusal, so the guard tracks the client and not the pointer
```

Both halves of the recipe are load-bearing, and each was measured by removing it from the helper and re-running the guard on the same host and release.
Dropping the `TIOCSWINSZ` call and dropping the environment scrub each left startup reporting `no_foreground_client`, followed by the guard failure:

```text
not ok - could not attach a real foreground Herdr viewer over a sized pty
```

Re-run this guard after every Herdr upgrade.
A release that changed the foreground-client contract, the window-grid requirement, or the nested-viewer refusal would fail here first, and the detached regressions would keep passing while saying nothing about it.

### Presentation version floor

Default-on presentation projection is floored at Herdr 0.8.0.
The floor's structural signal is the selected running server's protocol number, falling back to the client protocol only when that selected session positively reports no running server, and the release mapping was measured on 2026-08-05 by running each pinned upstream macOS aarch64 release asset's own `status --json` through the guarded lab helper:

| Release | Reported version | Protocol | Carries both upstream focus fixes | Floor verdict |
|---|---|---|---|---|
| v0.7.3 | 0.7.3 | 16 | no | below |
| v0.7.4 | 0.7.4 | 16 | no | below |
| v0.7.5 | 0.7.5 | 17 | no | below |
| preview-2026-07-21-0f10e1453a7f | 0.7.5-preview.2026-07-21-0f10e1453a7f | 17 | no | below |
| preview-2026-07-29-44b3adb12552 | 0.7.5-preview.2026-07-29-44b3adb12552 | 18 | yes | below |
| preview-2026-08-04-d78e3d3b5126 | 0.8.0-preview.2026-08-04-d78e3d3b5126 | 19 | yes | above |
| v0.8.0 | 0.8.0 | 19 | yes | above |

No build lacking both fixes reaches protocol 19, and every pre-fix build tops out at 17, so protocol 19 is a safe structural expression of the 0.8.0 floor.
The one post-fix build below it is a preview that still reports a 0.7.5 version, so it is conservatively treated as below the floor, which costs a preview build its projection and never lets an unfixed build through.
The 2026-08-05 named-lab cross-version probe started a server from Herdr 0.7.5 and queried it with the installed 0.8.0 client; status reported client version 0.8.0 protocol 19, server version 0.7.5 protocol 17, server running true, and server compatible false.
That ordinary post-upgrade shape proves the running server owns the focus behavior, so the unconfigured default composes client and selected-server verdicts conservatively and rechecks after server ensure before publishing a journal or creating a workspace.

Refresh this table with the opt-in guard, which re-downloads the pinned assets, verifies their digests, and fails naming any release whose reported version, protocol, or verdict has moved:

```sh
FM_HERDR_VERSION_FLOOR_LIVE_E2E=1 tests/fm-herdr-version-floor-live-e2e.test.sh
```

The classifier itself, the config preference it composes with, and the one-warning-per-release behavior are pinned portably with no Herdr installed:

```sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: every measured release classifies as the table records; either the protocol or the version signal alone carries an at-or-above verdict, and each divergent pair flips once the carrying signal is removed; client and running selected-session server verdicts compose conservatively, an unreadable server-running state and losing both release signals report indeterminate and fall back flat, the default is rechecked after server ensure before projection publication, an unconfigured home is projected only at or above the floor, an explicit `on`, including the historical empty opt-in file, is honored below it, and the below-floor warning is emitted once per home per detected release rather than once per spawn.

The whole real-Herdr lane was run on 2026-08-05 against both the CI-pinned Herdr 0.7.4 protocol 16, which is below the floor, and Herdr 0.8.0 protocol 19, which is at it:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh bin/fm-test-run.sh --lane real-herdr-gated
```

Both runs reported `family=real-herdr-gated count=11 failed=0`.
The projection suite's unconfigured-home case is release-aware rather than pinned to one outcome, so it proves the projected default on 0.8.0 and the flat fallback with its naming warning on 0.7.4:

```text
ok - real Herdr lab: a home that configured nothing is projected by default on herdr 0.8.0
ok - real Herdr lab: a home that configured nothing falls back flat on below-floor herdr 0.7.4 with one naming warning
```

Every other case in that suite uses an explicit opt-in or opt-out, so the floor leaves them unchanged on both releases.

Direct lab probes on 2026-07-28 established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `fm-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run on 2026-07-28 on Herdr 0.7.5 with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

### Composer and operational input

Real captures verified these active distinctions:

- Codex uses a bare `›` agent composer.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.
- Codex 0.154's idle braille starfield rows are composer furniture, with the dated Herdr evidence and refresh command in [Composer classification matrix](#composer-classification-matrix).

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Agent lifecycle control

Herdr is one of the two backends whose recovery-grade agent-state classifier the control plane may trust ([agent-control.md](../agent-control.md)), so its lifecycle gating is measured against the real binary; reverified 2026-08-08 on Herdr 0.8.0, and first measured 2026-08-02 on Herdr 0.7.5 with identical results:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed output, refreshed 2026-09-10 on Herdr 0.9.0 after the stale-registration fix (the two stale-registration lines are recorded under "Stale agent registration" below):

```text
ok - real herdr: exit on a pane with no registered agent is idempotent success
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
ok - real herdr: interrupt refuses when herdr's own agent registry reports no agent
ok - real herdr: interrupt delivers the harness's key and proves the agent survived it
ok - real herdr: no control verb removed the endpoint or the task's local copy
ok - real herdr 0.9.0: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead
ok - real herdr: exit on a pane with a stale registration is idempotent success
ok - real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive
ok - real herdr: an agent that does not stop fails closed instead of being reported as stopped
```

The registry read through `herdr pane report-agent` is the same source `fm_backend_herdr_agent_state` classifies, and since 2026-09-10 that registration counts as an agent only while `pane process-info` shows a harness process behind it, so the guard backs the registration with a real process named like a harness (a symlink to `sleep`) and then stops that process, with no real harness launched.
That command is the guard that refreshes this record; run it after every Herdr upgrade rather than trusting the version above.

For Pi on Herdr 0.9.0, `herdr agent get` reflects whether the agent process remains live; its registration does not persist merely because the pane and parent shell do.
A Pi launched as a child of the pane shell (not via `exec`) that then `/quit`s or is SIGKILL'd leaves the pane and shell in place, and `agent get` returns `agent_not_found`.
A sibling live idle Pi stays `agent=pi` with `agent_status=idle`.
`fm_backend_herdr_pane_agent_state` maps that `agent_not_found` leftover shell to `no-agent` and `fm_backend_herdr_agent_state` maps it to `dead` (relaunch-allowed), while the live idle pane stays `alive`.
`herdr pane get` `.agent_status` can still read `idle` after the occupant is gone; liveness is `agent get`, never that pane field.

```sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
```

Refresh that live pair after every Herdr upgrade. Observed 2026-09-10 on Herdr 0.9.0 / protocol 22 with Pi 0.82.0 in an isolated `fm-lab-` session:

```text
ok - agent get distinguishes leftover-shell (dead/no-agent) from live idle Pi
ok - pane get agent_status lag cannot keep an exited occupant classified alive
```

### Endpoint recovery classification

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) in an isolated `fm-lab-` session.

An endpoint recorded in a session whose server is not running cannot be read by any operational call, and `status` is the one command that answers with a body instead of refusing:

```sh
herdr pane get w1:p2 --session fm-lab-never-started
herdr status --json --session fm-lab-never-started | jq -c "{running: .server.running, status: .server.status}"
```

```text
{"id":"cli:pane:get","error":{"code":"server_not_running","message":"no herdr server is running at /Users/kunchen/.config/herdr/sessions/fm-lab-never-started/herdr.sock; run `herdr session attach fm-lab-never-started` to start or attach it"}}
{"running":false,"status":"not_running"}
```

`fm_backend_herdr_agent_state` therefore settles an uninterpretable pane read with `.server.running` rather than with the `server_not_running` error code, which keeps the verdict working across the supported range: the field is present on 0.8.2 protocol 20 and 0.9.0 protocol 22 alike (measured in "Client selection" above), while the code is not.
Only that recovery-grade read is widened; the husk classifier under it stays strict, because it licenses closing panes.
Observed in the lab, in one run:

```text
live agent-free pane                 dead
endpoint in a session with no server missing
malformed target                     unreadable
```

The same run drove `bin/fm-spawn.sh --relaunch` against a real Herdr pane whose shell had been moved outside its recorded worktree: the shell was told once to return, ended in the recorded worktree, and the replacement was launched into the SAME pane, leaving one task tab.

Herdr 0.8.x is not installed on this host, so protocol-20 coverage is structural plus the adapter fixture exercising both response shapes; it is not a live result.
Refresh the live half, which fails naming the installed version, with:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed 2026-09-10:

```text
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
```

`tests/fm-backend-herdr.test.sh` pins the logic portably by driving the two signals apart - the same failed pane read yields `missing` under a stopped server and `unreadable` under a running one - and asserts that the husk classifier still refuses on that identical read.
`tests/fm-control-herdr-smoke.test.sh` proves the Herdr-only drift recovery against a real binary in an isolated lab session.
`tests/fm-control-relaunch.test.sh` uses a Herdr fixture; `tests/fm-retired-backends.test.sh` proves retired endpoint refusals without terminal input or record loss.
The Herdr refusal when a shell accepts the command but does not move is not exercised in this change.

### Stale agent registration

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) and Pi 0.85.1 in an isolated `fm-lab-` session (upstream issue #4115, duplicates #3639, #3487, #2908, #3545).

Herdr keeps a Pi registration after the Pi process has exited to a shell when a nested interactive shell sits under the pane's top shell, which is the crew shape `treehouse get` leaves behind; a plain `/quit` directly under the top shell, and a `kill -9` of Pi, both released it on this version.
Reproduced in the lab with a nested `zsh` under the pane shell, then `pi` with no prompt, then `/quit`:

```sh
herdr pane run w1:p1 zsh --session "$LAB"; herdr pane run w1:p1 pi --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
herdr pane send-text w1:p1 '/quit' --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
```

```text
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35952,"procs":[{"pid":35952,"name":"node","argv0":"pi"}]}
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35834,"procs":[{"pid":35834,"name":"zsh","argv0":"zsh"}]}
```

Before the fix `fm_backend_agent_state herdr` read that second state as `alive`, so `bin/fm-control.sh <id> relaunch` and `bin/fm-spawn.sh --relaunch` were refused for as long as the registration lived, which is hours.
The registration is still present after the wait, and Herdr's own `pane report-agent` leaves the same shape behind on any pane, which is what the lifecycle-control guard uses.

Two vendor facts the fix rests on, both read from the outputs above and from `fm_backend_herdr_pane_process_state`'s `pane process-info` parse:

- Pi's process presents with kernel name `node` and argv0 `pi` (its foreground group also carries Pi's child `node` helpers with argv0 such as `npm view ... version`), so a running Pi is attributed by argv[0] through the structural process probe; a symlink named `claude` to `sleep` presents as name `sleep`, argv0 `claude`.
- Herdr creates the record with its own placeholder `agent_status` of `unknown` the moment it notices Pi, before Pi's extension reports `idle`; that transient reads `unknown` in the pane classifier as it always did, and only a lifecycle status is subject to the process-level proof.

Subcommand presence below the 0.9.0 measurement, checked 2026-09-10 on macOS aarch64 against the pinned upstream release clients fetched from `https://github.com/ogulcancelik/herdr/releases/download/v<version>/herdr-macos-aarch64`:

| Release | sha256 |
|---------|--------|
| 0.7.1 | `16f4653f0491ea1e7d2b46b5b02542f18e1b82e88daaf9e2900572e5bb634df8` |
| 0.7.3 | `b31345392d004ec1f1b2c821e1ad601019fa8385fe1e4c6931321eb58a920773` |
| 0.7.4 | `24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7` |
| 0.7.5 | `37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6` |

The command run against each client was `<client> pane --help`, which is client-side, session-independent, and opens no socket, and each printed the line:

```text
process-info  Show pane process information
```

This proves subcommand presence in the client only, not the server response shape, which is measured only on 0.9.0 above.

The live guard that refreshes this record runs by default wherever Herdr and Pi are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
```

Observed 2026-09-10:

```text
# pi 0.85.1 under herdr 0.9.0: registered idle, foreground [{"name":"node","argv0":"node"},{"name":"node","argv0":"node"},{"name":"node","argv0":"rpiv-ask-user-question version"},{"name":"node","argv0":"npm view gentle-engram version"},{"name":"node","argv0":"pi"}]
ok - real herdr 0.9.0 + pi 0.85.1: a running registered pi classifies alive at process level
# herdr 0.9.0 kept the pi registration (idle) after /quit under a nested shell: the stale-registration branch is exercised
ok - real herdr 0.9.0 + pi 0.85.1: the registration left behind by a quit pi reads stale-agent and recovers as dead
```

`tests/fm-control-herdr-smoke.test.sh` proves the same shape through the control plane with no harness launched (the two `stale` lines under "Agent lifecycle control" above): a registration over a real agent-named process reads `alive`, stopping that process makes the pane read `stale-agent` and recover as `dead` while `agent get` still reports the record, `exit` then reports `already-stopped`, and `--relaunch` reuses the same endpoint with the local copy intact.
`tests/fm-backend-herdr.test.sh` pins the logic portably with canned `process-info` bodies over real processes, driving the signals apart: the identical shell-only foreground reads `stale-agent` for a childless shell and `live` when an agent-named process is still a descendant of that shell, a `working`, `done`, or `blocked` record over a shell-only pane reads the same as `idle`, an unreadable process view reads `unknown` and refuses husk closing, a transient prompt helper beside the shell settles into `stale-agent` on the next shell-only sample while a foreground that never settles within the bound still reads `live`, and `busy_state` verifies a `working` record before reporting busy, returning `unknown` when its process evidence is unreadable.
`tests/fm-crew-state.test.sh` pins the recovery classifier: a stale registration over a shell-only pane reports agent gone rather than alive or unreachable, and a stale `working` record never reports the pane working.
A stale-registration pane is never a husk: create, reclaim, presentation recovery, and session cleanup keep refusing it, and only recovery reuses it.

The portable unreadable-process regression was refreshed on 2026-09-24 with `bin/fm-test-run.sh tests/fm-backend-herdr.test.sh` (no vendor CLI required):

```text
ok - herdr stale registration: busy_state proves a working record at process level before reporting busy
```

That case checks a shell-only foreground and a failed process read against the same working registration, and requires `unknown` for both instead of accepting the cached busy claim.

### Away-mode transport

The away daemon is no longer launched on Pi; the away posture there is the record `bin/fm-afk-contract.sh` owns.
The Pi/Herdr away posture and return transport was verified on 2026-09-08 against a real Pi primary in an isolated Herdr lab session, Herdr 0.9.0 and Pi 0.82.0:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Relevant transport output:

```text
ok - real Pi primary: the away posture is recorded with no daemon launched
ok - real Pi/Herdr: nothing injects into the captain pane under the away posture
evidence: herdr=herdr 0.9.0 pi=0.82.0 target=fm-lab-fm-afk-pi-return-37189-7133:w1:p1 archived-records=2
```

Observed guarantees: `fm-afk-launch.sh start` refused on the Pi primary and `confirm` recorded the posture with no daemon pid, flag, or terminal; a pending real Pi draft was left untouched with nothing submitted into the captain pane; the unmarked return request was recognized as the return, rendered the brief health first, and opened the catch-up gate on the live blocker; resolving the blocker cleared the gate, and a clean re-entry and return left exactly one archived record per away window.
The current catch-up reporting boundary is pinned by `tests/fm-afk-return.test.sh` and the same live entry point: Bearings continues through a pending return catch-up, projects its posture as an action-free warning outside Captain's Call, and drops that warning after the gate clears, while an active away window still refuses.
The fixture captures submitted input through Pi's `input` extension hook, so the lab agent directory needs no provider credentials.
The daemon injection transport into a live composer keeps its coverage in `tests/fm-afk-inject-herdr-e2e.test.sh` for the harnesses that still run the daemon, and the dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

## Pi supervision branch

The supervision-branch extension (`.pi/extensions/fm-branch-supervision.ts`, [docs/pi-supervision-branch.md](../pi-supervision-branch.md)) builds its persistent second session through the Pi SDK surface: `createAgentSession` (including its `model`, `modelRuntime`, and `thinkingLevel` options), `DefaultResourceLoader` with `extensionFactories` and a shared `SettingsManager` snapshot that every branch build reads from `SettingsManager.create`'s `getGlobalSettings`/`drainErrors` and re-wraps with `SettingsManager.inMemory` for the loader and session (plus, for an `openai-codex` branch, `DefaultPackageManager` resolving the installed `pi-openai-codex-compat` package entry through that same manager and `additionalExtensionPaths`, `bindExtensions` before the first prompt, and the post-start `getActiveToolNames` allowlist check), `SessionManager`, `createBashToolDefinition` with a `spawnHook`, `sendCustomMessage` for routine notes, `appendEntry` and `registerEntryRenderer` for captain outcomes, the `before_provider_request` hook, the command context's model registry for picker candidates, a fresh `ModelRuntime` for isolated-branch resolution, and Pi's own `getSupportedThinkingLevels`/`clampThinkingLevel` plus its `getThinkingLevel` and `thinking_level_select` extension surface for effort.
In TUI mode, its `/supervision-model` model list is drawn with Pi's own `SelectList`, `Input`, `fuzzyFilter`, and `DynamicBorder` through the extension context's `ui.custom` surface, which is what bounds and searches a long catalog.
Its `/supervision-reset` command drives the branch session's `abort` and `waitForIdle` lifecycle calls to settle an active turn before rotating the conversation.

Evidence produced 2026-08-25 on macOS 26.5.2 arm64, Node v24.13.1:

- Historical real-SDK guard: `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh` against the globally installed `@earendil-works/pi-coding-agent` 0.81.1 printed `ok - real Pi SDK 0.81.1 accepts the branch session construction and preserves an unpromptable wake`.
  The guard read no credentials and made no provider call: an isolated empty `PI_CODING_AGENT_DIR` left model resolution empty, so the branch's first prompt failed fast and exercised the former direct-branch fallback.
  That fallback probe predates watcher-owned settlement and is not current evidence for the replacement-safe delivery boundary.
  The same run confirms that a real `ModelRegistry` over that empty agent dir still exposes the picker-facing availability surface, then pins `openai/no-such-live-model` and proves that the branch's own `ModelRuntime` refuses the unresolvable pin instead of silently running supervision on main's model.
- Model-pin precedence: the same guard run printed `ok - real Pi SDK 0.81.1 applies an explicit branch model on create and over a reopened session's recorded model`.
  It declares a local `fm-live-fake` provider in an isolated `models.json`, never contacts it, and proves through `session.model` that an explicit model is applied on create, still wins over the model a reopened session recorded, and is absent-pin-restorable - the SDK behavior needed when a model or effort change reopens the current main session's branch conversation.
- Effort-pin vendor contract: the same guard run printed `ok - real Pi SDK 0.81.1 reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level`.
  Over its own local never-contacted provider it confirms that `getSupportedThinkingLevels` still returns `["off","minimal","low","medium","high","xhigh","max"]` for a model mapping every extended level, narrows to `["off","minimal","low","medium","high"]` for a reasoning model mapping none, returns `["off"]` for a non-reasoning model, and that `clampThinkingLevel` lowers `max` to `high` on the narrow model while collapsing an unrecognized token to `off` - which is why the extension rejects an unrecognized pin before that clamp can see it.
  It then proves through `session.thinkingLevel` that an explicit effort is applied on create, that a reopened session with no override restores its own recorded level, that an explicit effort beats that recorded level, and that an over-ceiling effort is clamped rather than refused.
  The recorded-level cases need a session file Pi will actually restore from, and Pi flushes one only once an assistant message exists, so the guard appends the level change and that message through the real `SessionManager` rather than hand-writing the format.
- Picker primitives: on 2026-08-26, after the final portable-shell and sentinel fixes, `bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh` again printed `ok - the installed Pi still bounds the picker's list and ranks its search` against the same installed 0.81.1 package.
  That case imports the real `SelectList`, `Input`, `fuzzyFilter`, and `DynamicBorder`, renders a 42-row catalog through the real `SelectList` at the visible bound the extension asks for, and fails naming the installed version if Pi stops exporting a primitive or stops bounding what it renders; it skips when no npm package is installed, and the portable stubbed cases in the same file hold the ordering, search, and branch-only-pin behavior everywhere.
- Strict typecheck: `tests/fm-pi-primary-types.test.sh` printed `ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1` with the branch extension and its imported libraries included.
  This typecheck is also the enforcement for the extension's declared effort vocabulary: its bidirectional assertion against Pi's own `getThinkingLevel` return type fails the moment Pi adds or removes a thinking level, so the runtime list used to reject an unrecognized hand-edited pin cannot drift into a stale Firstmate catalog.
- Historical custom-message provider conversion: on 2026-08-26, `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh` against installed `@earendil-works/pi-coding-agent` 0.84.1 printed `ok - real Pi SDK 0.84.1 delivers a custom message to the provider as user text carrying only content, so the captain outcome's typed envelope is what reaches the model`.
  The guard passes a typed captain outcome and a plain rendered routine note through Pi's exported `convertToLlm`, proves that `customType` and `display` are not model-visible identity, and classifies the resulting provider text with `bin/fm-operational-input.sh`.
  This evidence explains the superseded model-relay path but is no longer the captain-delivery contract.

### 2026-08-28 Pi 0.84.4 SDK compatibility refresh

The credential-free live guard and strict typecheck were rerun against the installed `@earendil-works/pi-coding-agent` 0.84.4 package after the Pi primary compatibility repair.
The live guard used an isolated empty `PI_CODING_AGENT_DIR`, inspected no credentials, and made no provider call.

```sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 accepts the branch session construction and preserves an unpromptable wake
ok - real Pi SDK 0.84.4 applies an explicit branch model on create and over a reopened session's recorded model
ok - real Pi SDK 0.84.4 reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level
ok - real Pi SDK 0.84.4 delivers a custom message to the provider as user text carrying only content, so the captain outcome's typed envelope is what reaches the model
FM_TEST_END 2026-08-29T01:01:01Z tests/fm-pi-branch-live-e2e.test.sh exit=0 duration_ms=2520 gate_skip=false
```

The focused extension suite also exercised the installed Pi 0.84.4 picker and outcome-renderer consumers; [`calm-mode-feasibility.md`](../calm-mode-feasibility.md#2026-08-28-pi-0844-outcome-renderer-compatibility-verification) owns the version-scoped renderer evidence.

### 2026-08-29 deterministic captain-outcome delivery

The credential-free live guard, focused extension suite, store suite, and strict typecheck were run against the locally installed `@earendil-works/pi-coding-agent` 0.84.3 package.
No model was selected or prompted, no provider call was made, and the active Pi session was not changed.

```sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - captain outcomes are exact and exactly once across crash, reload, busy main, compaction, and an unrelated assistant response
ok - startup replay cannot advance the cursor across an unrendered captain outcome
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.3
ok - real Pi SDK 0.84.3 immediately renders appendEntry in the active transcript, persists it across reopen, and excludes it from model context
```

The live probe loads the extension through Pi's real resource loader and AgentSession, subscribes a stock InteractiveMode, verifies `ExtensionAPI.appendEntry` synchronously inserts the exact registered custom row into its active chat once, reopens the resulting session file to verify exact structured data, and verifies the entry is absent from `buildSessionContext().messages`.
The focused regression recreates the incident topology with stale compaction framing and an immediately preceding unrelated assistant response, then covers idle and busy delivery, cold startup with late fleet-lock acquisition, the crash boundary after entry persistence but before cursor advancement, and repeated reload without duplication.

### 2026-09-01 sequence-keyed captain-outcome processing

The focused extension suite, store suite, strict typecheck, and credential-free live guard were run against a locally installed `@earendil-works/pi-coding-agent` 0.84.4 package selected with `FM_PI_PACKAGE_DIR`, on macOS 26.5.0 arm64, Node v24.13.1.
No model was selected or prompted, no provider call was made, and the active Pi session was not changed.

```sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - a captain outcome reaches main's model as one typed, sequence-keyed processing request while routine notes stay plain
ok - a captain outcome opens one sequence-keyed processing turn, survives empty and unrelated answers, is re-presented at run end and session start, and closes only on its acknowledgement
ok - the processed marker is sequence-bound, never ahead of the read cursor, never backwards, and migrates delivered history once
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 immediately renders appendEntry in the active transcript, persists it across reopen, and excludes it from model context
```

The focused regression recreates the two 2026-08-31 incident shapes against the real store scripts: a delivered decision outcome whose processing turn returns an empty assistant message, and one whose turn repeats an unrelated prior answer.
In both, the processed marker holds, the same sequence is presented again at the run boundary and after a session replacement, and the triggered-turn budget gives way to a next-prompt copy without duplicates.
Only `fm_branch_processed` with the presented sequence closes the outcome, and it now refuses until `fm_branch_outcomes` has loaded every acknowledged sequence from the durable store since the latest session start or compaction; a routine outcome never enters the path, and delivered history from before the marker existed is migrated once rather than re-presented.
On this machine the globally installed npm package is 0.81.1, whose stock `ToolExecutionComponent` rendering differs from the 0.84 line and fails the suite's first rendering-consumer case before any delivery case runs, which is why `FM_PI_PACKAGE_DIR` points at the 0.84.4 install above.

### 2026-09-02 historical post-construction provider-error fallback

The focused extension suite, strict typecheck, and real-SDK guard were run against the npm `@earendil-works/pi-coding-agent` 0.84.4 package on macOS 26.5.0 arm64, Node v24.13.1, before fallback ownership moved from the branch extension to the watcher.
The real-SDK case configured an isolated local OpenAI-compatible model, intercepted its only `fetch` in-process with the incident's non-retryable 429 `Monthly usage limit reached` response, read no user credential, and allowed no external provider request.
It proved that Pi persisted an assistant message with `stopReason: "error"` and resolved the constructed branch prompt normally, after which the extension released the claimed-row grant, retained the durable queue row, and returned the exact wake to main as a follow-up.

```sh
FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-branch-extension.test.sh
FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - a settled branch turn without a durable outcome falls back and releases its grant for main replay
ok - post-construction provider errors fall back immediately and repeated failures defer later wakes directly to main
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 returns a post-construction 429 wake to main without losing its durable row
```

The current portable regression proves that only consecutive provider errors count toward the two-error broken-branch latch: a durable report between errors resets the streak, the error that reaches the threshold rejects to watcher-owned fallback, and the next wake remains on main without another branch prompt.
`tests/fm-pi-watch-extension.test.sh` owns the provider-free integration evidence that watcher fallback remains pending until Pi accepts the main follow-up or the branch settles successfully, and that a follow-up accepted while main is streaming neither stalls the successor chain nor escapes replacement replay until Pi consumes it.
[`pi-supervision-branch.md`](../pi-supervision-branch.md) owns the current cooldown, recovery, and re-latch contract and points to the regression that now covers it.

### 2026-09-03 Codex compatibility package in the supervision branch

The focused branch suite, strict installed-Pi typecheck, documentation-audience check, lint, and real-SDK guard were run on Linux 5.15.152.bsk.4-amd64 x86_64 with Node v22.22.2, installed `@earendil-works/pi-coding-agent` 0.84.4, and installed `pi-openai-codex-compat` 0.0.9.
The live compatibility probe copied that installed package and its declared runtime dependencies into an isolated Pi agent directory, supplied a synthetic unexpired OAuth token, forced only the isolated branch settings to SSE, and intercepted every request in-process; it read no captain credential and no provider request left the machine.

```sh
bash tests/fm-pi-branch-extension.test.sh
bash tests/fm-pi-primary-types.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
FM_PI_BRANCH_LIVE_E2E=1 bash tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - Codex branch create and reopen initialize only pi-openai-codex-compat before prompting without widening tools
ok - non-Codex branch startup remains unchanged when pi-openai-codex-compat is absent
ok - absent, malformed, incompatible, resolution, load, and startup failures return Codex wakes to main before prompting
ok - supervision-reset safely aborts active work, rotates history, releases ownership, and re-anchors the next branch
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
fm-doc-audience-check: ok surfaces=100 local_links=331
fm-lint.sh: full ShellCheck extended analysis enabled
ok - real installed pi-openai-codex-compat 0.0.9 initializes before prompting and persists native Codex compaction
```

The real-SDK probe drove `.pi/extensions/fm-branch-supervision.ts` through its public dispatch event.
It observed no request before branch startup completed, then exactly two Codex provider turns using only `read`, `bash`, and `fm_branch_report`, followed by one native compaction request whose turn metadata said `request_kind=compaction`, whose beta header included `remote_compaction_v2`, and whose final input item was `compaction_trigger`.
Reopening the real branch JSONL showed a `fromHook: true` compaction entry with `details.kind=openai-codex-compat-remote-compaction` and the returned encrypted checkpoint in `details.history`.
The portable suite separately proves create and reopen ordering, the isolated loader/session settings manager, exact resource and tool suppression, non-Codex independence, every fail-closed package-load class, and the reset lifecycle.

Scope of the earlier evidence: the installed signed `pi` CLI (0.82.0 at verification time) is a compiled binary whose bundled SDK is not importable from Node, so the importable npm package is the only surface the guard and the typecheck can pin.
The extension executes inside the signed CLI's own runtime, so a CLI upgrade can drift ahead of the pinned npm surface; refresh the SDK construction, picker, renderer, and type evidence after every Pi upgrade by rerunning the applicable live guard probes, picker regression, and strict typecheck above (point `FM_PI_PACKAGE_DIR` at a matching npm install when one exists).
The live guard now drives both extensions through the watcher-owned settlement handshake, requires rejected branch settlement before main delivery, and verifies successor-delivery confirmation; rerun it against the matching importable Pi package to refresh end-to-end fallback evidence.

### 2026-09-28 Pi/Codex compatibility version-gate removal

The branch loader no longer rejects initialization solely because Pi or `pi-openai-codex-compat` manifest versions differ from a pinned pair.
The existing package identity, declared entrypoint, package provenance, extension startup, and active-tool isolation checks remain fail-closed.
The host system library exposed through `GLIBCXX_3.4.30`, so `tree-sitter` 0.25.1 and `tree-sitter-bash` 0.25.1 were rebuilt from their npm sources with `npm rebuild --prefix ~/.pi/agent/npm tree-sitter tree-sitter-bash --build-from-source` rather than loading the incompatible published `tree-sitter` prebuild.
Both rebuilt bindings resolved from their `build/Release` directories and loaded successfully together with `node-pty` 1.2.0-beta.15.

The following commands exercised the tracked integration, including the portable non-pinned-version admission case:

```text
$ tests/fm-pi-branch-extension.test.sh
ok - Codex branch initializes with non-pinned Pi and compatibility versions without widening tools
ok - package identity, provenance, containment, startup, and unexpected-tool failures return Codex wakes to main before prompting

$ FM_PI_PACKAGE_DIR=<installed-pi> tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1

$ FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<installed-pi> FM_PI_CODEX_COMPAT_NODE_MODULES=<pi-user-node-modules> tests/fm-pi-branch-live-e2e.test.sh
ok - real Pi CLI 0.87.1 with pi-openai-codex-compat 0.0.16 inherits global SSE and connection settings without project resources or writes, preserving Luna/minimal, guarded tools, legacy outcomes and native compaction
ok - real Pi SDK 0.87.1 mirrors only provenance-verified Feishu text before idle/streaming branch turns, once and in order across persistence and cold creation
```

A generated Herdr lab session with a fresh disposable `FM_HOME` exercised real Pi TUI startup, one accepted branch wake, `fm_branch_report`, the durable outcome, main acknowledgement through sequence 1, and a main-only check wake.
It recorded `acceptedOffers=1`, `mainOnlyOffers=1`, `branchCalls=2`, `outcomes=1`, `processed=1`, and `visible=1`, then completed guarded teardown with `HERDR_TRIPWIRE_TEARDOWN_OK`.
An authenticated JSON-mode smoke test used the existing authorized `openai-codex/gpt-5.6-luna` credential surface and recorded a successful `read` tool start and completion followed by an assistant stop.

### 2026-09-08 Pi branch settings and trusted Feishu mirroring

On Linux x86_64 with Node v22.22.2, installed Pi 0.85.1 and `pi-openai-codex-compat` 0.0.10-alpha.7 passed the actual branch construction and provider-consumer regression.
The isolated global settings file selects SSE, a 7000 ms WebSocket connection timeout, a 23000 ms HTTP idle timeout, and a provider retry limit; conflicting project settings are ignored.
The real loader resolves no configured packages, exposes no discovered skills, prompts, themes or context, and retains the explicit compatibility extension and guarded tool allowlist.
Persistence-capable model, effort, transport and compaction setters are flushed on the branch manager without changing either settings file or the proxy environment.
The previous empty-manager construction fails this probe at the real provider consumer with `auto !== sse`.

```sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh tests/fm-branch-supervision.test.sh tests/fm-pi-watch-extension.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh tests/fm-pi-primary-types.test.sh
```

```text
ok - real Pi CLI 0.85.1 with pi-openai-codex-compat 0.0.10-alpha.7 inherits global SSE and connection settings without project resources or writes, preserving Luna/minimal, guarded tools, legacy outcomes and native compaction
ok - real Pi SDK 0.85.1 mirrors only provenance-verified Feishu text before idle/streaming branch turns, once and in order across persistence and cold creation
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.85.1
```

Those repeatable guards use synthetic authentication and intercepted responses.
The Feishu mirror probe publishes synthetic accepted input through the durable state owner and native encoder, then drives Pi's actual custom-message ingress while idle and streaming.
It offers a dependent branch wake during `message_start`, before the custom entry is persisted, and checks the resulting branch context for the originating captain text, user/assistant ordering, once-only catch-up, ordinary TUI continuity, and a new branch rebuilt from persisted main history.
Changed content, a mismatched binding generation, an unknown delivery reference, internal notifications, branch results, operational user envelopes, and tool results stay excluded.
The prior mirror fails the idle pre-persistence assertion; the corrected mirror and the existing Feishu channel suite pass.
This is a real-Pi ingress fixture, not a production Feishu transport roundtrip: no real Feishu message is sent and no live binding or configuration is changed.
A separate authenticated candidate run used the installed CLI dispatcher bootstrap and existing controlled SOCKS5 proxy inside a guarded non-default Herdr lab: five branch calls returned HTTP 200, all five persisted transport diagnostics recorded configured and selected `sse`, and the WebSocket constructor observer recorded zero attempts.
The real branch published one durable captain outcome and the real lab main acknowledged sequence 1; duplicate delivery produced no extra outcome and a separate captain-only decision remained unresolved.
Protected host files and the copied lab settings were unchanged, and the lab helper passed its default-session teardown tripwire.
The HTTP responses on this route had no content-type header; SSE evidence comes from the actual provider consumer and persisted compatibility transport diagnostics, not an inferred response MIME type.
This verifies candidate SDK behavior, not activation or a TUI reload of the running primary, and does not establish that the old branch bypassed a proxy: Pi's CLI initializes the process-wide dispatcher before branch construction.
Private task evidence retains the authenticated lab programs and transcripts; [the supervision owner](../pi-supervision-branch.md) defines settings ownership.

### 2026-09-07 lazy Codex branch creation after legacy outcome migration

On Linux x86_64 with Node v22.22.2, the installed Pi 0.85.1 CLI and an isolated copy of `npm:pi-openai-codex-compat@0.0.10-alpha.7` and its native dependency closure passed the Luna/minimal first-notification regression.
The fixture starts with delivered legacy endpoint outcomes and no branch pointer, lets the real primary extension reconcile history, then offers its first eligible synthetic notification through Pi's event bus.
The fixture pins `minimal`; Pi retains its supported-level clamp, producing `low` in the current Luna request.
It verifies lazy branch creation, provider startup, the exact `read`, guarded `bash`, and `fm_branch_report` request payload, a new report in the durable store and main's active session tree, and a persisted native compaction checkpoint.
The portable suite at that time separately checked that cache migration preserved authoritative history and unprocessed captain results, and that mismatched, non-semver, missing, and future version declarations did not prevent valid runtime startup; the [current version-gate removal evidence](#2026-09-28-picodex-compatibility-version-gate-removal) records the restored behavior.
Package identity, provenance, containment, startup, failed tool restoration, and unexpected tool mutations retain their safe fallback regressions.

```sh
bash tests/fm-branch-supervision.test.sh
bash tests/fm-pi-branch-extension.test.sh
bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bash tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - real Pi CLI 0.85.1 with pi-openai-codex-compat 0.0.10-alpha.7 creates Luna/minimal branch on its first eligible wake after legacy outcome migration, with guarded tools and native compaction
```

This is CLI and persisted-state evidence with synthetic OAuth and intercepted SSE, not a new authenticated-service or TUI verification.
No provider request left the process, and the running primary, its fleet state, the global/user installation, and the shared Herdr session were unchanged.

### 2026-09-07 Pi 0.85.1 and Codex compatibility alpha.7

On Linux x86_64 with Node v22.22.2, the 46-case focused branch suite, strict Pi typecheck, and seven real-SDK probes passed against installed Pi 0.85.1 and an isolated official `pi-openai-codex-compat@0.0.10-alpha.7` package.
The official Pi 0.84.4 / plugin 0.0.9 control also passed its real-SDK guard before the candidate was applied.
The candidate plugin's `tree-sitter@0.25.1` prebuild required an unavailable `GLIBCXX_3.4.31`; rebuilding that dependency from source with the host's existing toolchain made the unmodified plugin load.
The guard copies the installed dependency closure, including built native artifacts, without installing packages or changing the user's Pi store.

```sh
bash tests/fm-pi-branch-extension.test.sh
bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 \
  FM_PI_CODEX_COMPAT_NODE_MODULES="$compat_agent_dir/npm/node_modules" \
  bash tests/fm-pi-branch-live-e2e.test.sh
```

Here `compat_agent_dir` is the prepared isolated Pi agent directory containing the exact candidate package and its working native dependencies; `FM_PI_PACKAGE_DIR` can select a matching importable Pi package for a control.

```text
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.85.1
ok - real installed pi-openai-codex-compat 0.0.10-alpha.7 initializes before prompting and persists native Codex compaction
```

The real-SDK compaction probe intercepts provider responses and uses synthetic credentials; it proves the exact three-tool payload and persisted native checkpoint, not authentication.
A separate real authenticated SDK run inside a guarded named Herdr lab used Pi's installed CLI dispatcher bootstrap and the existing controlled SOCKS5 proxy, without changing main or its installation.
Its `openai-codex/gpt-5.6-sol` main request returned HTTP 200 and `LAB_AUTH_OK`; the actual alpha.7 branch then drained a synthetic task event, claimed its lease, read its report, wrote one captain outcome, acknowledged its queue row, and released its lease through the guarded bash tool.
The real main session called `fm_branch_processed` through sequence 1 and answered `LAB_OUTCOME_ACK`.
One visible outcome entry remained after a duplicate offer, and an unanswered captain-only decision row stayed queued for main.
This proves the SDK branch roundtrip, not a TUI reload or activation of the running primary.

A separate credential-free failure probe loaded the candidate with its incompatible native prebuild and observed the actual `GLIBCXX_3.4.31` loader error before any provider request.
The real watcher extension returned that rejected branch settlement to its recording main adapter exactly once and retained the durable wake; main delivery in that failure probe used an adapter, while authenticated main processing was proven by the preceding real session.
Private task evidence retains the exact lab programs and transcripts; [the supervision owner](../pi-supervision-branch.md) defines the runtime and tool boundaries, and the portable suite rejects invalid package identity, provenance, extension containment, startup failures, and unexpected tool mutations.

### 2026-09-02 streaming-time watcher delivery

The focused watcher suite, strict typecheck, and credential-free live guard were run against the npm `@earendil-works/pi-coding-agent` 0.84.4 package selected with `FM_PI_PACKAGE_DIR`, on macOS 26.6.2 arm64, Node v24.14.1, after the watcher extension stopped waiting for `before_agent_start` before settling a main delivery.
No credential was read, no request left the machine, and the active Pi session was not changed.

```sh
bin/fm-test-run.sh tests/fm-pi-watch-extension.test.sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - Pi hung successor falls back to one typed actionable wake
ok - Pi streaming-time wake delivery keeps the successor chain and replays only unconsumed wakes
ok - Pi retries a verified successor that failed during wake delivery once that delivery settles
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 queues a streaming-time watcher wake without before_agent_start, keeps the successor chain, and surfaces consumption of both follow-ups
```

The live probe loads the tracked watcher extension through Pi's real resource loader into a real AgentSession whose only provider is a local fake with its fetch intercepted in-process and held open mid-stream.
It proved that a follow-up the extension sends while main is streaming raises no `before_agent_start` at queue time or when the run reaches it, joins the run as a user `message_start` carrying the exact wake text in its own model turn, and is followed by a verified successor and delivery of the next close; a follow-up sent to the idle main raises `before_agent_start` with the exact text before its user `message_start`.
The portable regression drives the same shape with a fake main that never raises `before_agent_start` while streaming, then proves a replacement replays only the follow-up Pi had not consumed and that an exhausted restoration delivers its typed failure without launching a further arm.
A second regression holds a branch settlement open while the verified successor exits with a failure, and proves that failure takes the ordinary bounded retry once the delivery settles rather than leaving the generation with no watcher and no retry.

### 2026-09-04 off-thread supervision outcome delivery

The real-TUI responsiveness guard, focused extension suite, store suite, and strict typecheck were run on macOS 26.5.0 arm64, Node v24.13.1, tmux 3.6a, against the signed Pi launcher 0.82.0 for the TUI arms and the npm `@earendil-works/pi-coding-agent` 0.81.1 package for the typecheck.
The lab used a scratch `FM_HOME`, a scratch project holding a copy of the tracked extension, a private tmux socket, a scratch session directory, and `--offline`; only `/new` was ever sent, so no model turn ran and no request left the machine, and the captain's own Pi session was not touched.

```sh
FM_PI_BRANCH_RESPONSIVENESS_E2E=1 bash tests/fm-pi-branch-responsiveness-live-e2e.test.sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
```

```text
pi 0.82.0 keystroke echo, worst observed: floor 22.6 ms, extension idle 35.6 ms, extension delivering 36.8 ms
ok - supervision outcome delivery keeps the real Pi 0.82.0 TUI echoing keystrokes at its unloaded floor
ok - outcome delivery keeps the event loop running and interleaved reports stay ordered and exactly once
ok - a session replaced mid-delivery cancels cleanly and the stored outcome still arrives exactly once
ok - a failing store script surfaces to the branch and its outcome is neither lost nor delivered twice
ok - a failed cursor write re-delivers a routine note exactly once more while a captain outcome stays deduplicated
skip: installed Pi 0.81.1 predates the stock renderer contract 0.84.4 this case compares against
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1
```

That skip is the renderer case declining to render a verdict on a Pi older than the contract it compares against: since 0.84.4 the stock renderer no longer supplies an implicit reset at multiline boundaries and the extension emits that reset itself, so an older installed Pi differs legitimately.
It names the installed version and the floor rather than degrading quietly, and a package whose version cannot be read at all is still a failure.

The same guard against the pre-change extension in the same lab measured a 676.9 ms worst keystroke echo while delivering two outcomes and a 295.3 ms worst echo with nothing to deliver, against a 49.2 ms extension-free floor, and failed as designed.
Measured through the same real `fm_branch_report` tool and real `bin/` scripts with a 1 ms interval timer, the largest single block of the JavaScript thread fell from 273 ms to 2.0 ms for a routine outcome, from 286 ms to 2.0 ms for a captain outcome, and from 134 ms to 1.9 ms for main's acknowledgement, against a 1.3-2.2 ms idle-loop floor.
Those absolute figures are specific to this host and Pi version; the guards assert the relationship (delivery must stay in the class of the same machine's own floor) rather than a remembered millisecond number.

## Native Codex through Pi

Verified on 2026-09-08 with Pi 0.85.1 and the installed `pi-codex-native` 0.2.1 adapter.
Run this token-free guard after updating Pi, Codex, or the adapter:

```sh
FM_PI_CODEX_NATIVE_LIVE=1 bash tests/fm-pi-codex-native.test.sh
```

Observed result: `"result": "PASS"`.
The guard runs the real Pi runtime, native adapter, three FirstMate primary extensions, native MCP transport, and FirstMate's durable outcome scripts in an isolated home.
It verifies native `ultra` on initial and operational turns and after restart, startup operational input, watcher arming, a notification while main is idle, outcome read and one acknowledgement, refusal of a duplicate acknowledgement, and no reprocessing after restart.
Its native App Server peer and watcher-close process are deterministic fixtures; it does not claim a real backend or a live model was tested by that command.
`tests/fm-busy-state.test.sh`, `tests/fm-busy-adapter-wiring.test.sh`, and `tests/fm-watch-triage.test.sh` cover separate progress notification, unchanged semantic busy state, rejection of a superseded worker's events, and progress refreshing the busy-age bound without fabricating a completed turn.

## TraeX structural liveness fallback (2026-09-25)

[Semantic busy state](supervision.md#semantic-busy-state) owns the default-TUI lifecycle guard, versions, output, source coverage, and limits.
That run observed TraeX reporting native `agent_status=unknown` while its `traex` foreground process remained alive.
The busy reader uses the existing structural process probe in that case; exact `traex` and `traecli` names are recognized, with real-process decoy coverage in `tests/fm-agent-process-live-e2e.test.sh`.
Structural liveness permits the task-bound transcript read but does not itself infer busy or idle.

## Pi headless short tasks

On 2026-09-28, the portable exact-candidate suites passed after removing Firstmate's short-task input, output, request, tool-call, and wall-clock budgets while retaining operation grants, expiry, cancellation, process identity, durable receipts, and no replay.
The lifecycle fixture submitted a request carrying all four legacy budget fields at values below the former minima and observed completion after the former wall deadline, across more tool calls, model requests, and streamed bytes than those fields allowed.
It also captured five material entries including a file over 40,000 bytes, accepted goal and acceptance strings above the former limits, preserved a 4,096-character result through the public CLI, and verified that a stored v1 request remains readable without launching a duplicate child.
The operation fixture submitted the same ignored one-unit legacy fields and completed a real isolated Git sync after the former deadline, while the existing cancellation, expired-grant, unauthorized-target, identity-drift, uncertain-effect, and settlement refusals remained green.

```text
$ bin/fm-test-run.sh tests/fm-short-agent.test.sh tests/fm-short-operations.test.sh tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1
ok - short-agent read boundary, asynchronous lifecycle and durable notification
ok - short operation grants, real sync/recovery effects, receipts and refusals
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0
```

On 2026-09-27, Pi 0.87.1 and Node v22.22.2 passed the isolated SDK guard with authenticated `openai-codex/gpt-5.6-luna` for both read-only analysis and an authorized fast-forward of a disposable local clone.
Refresh with `FM_SHORT_AGENT_LIVE_E2E=1 FM_SHORT_LIVE_PROVIDER=openai-codex FM_SHORT_LIVE_MODEL=gpt-5.6-luna bin/fm-test-run.sh tests/fm-short-agent-live-e2e.test.sh`.
Both submitted through the loaded candidate extension and returned before child completion; the parent answered another real-model prompt while each child was active.
Both children excluded the parent-only sentinel.
The installed SDK read back `cacheWarming: "off"` and disabled compaction; each child loaded only `pi-openai-codex-compat@0.0.16`, with zero extension errors and zero starting parent messages.
Both children persisted the plugin's native response markers, proving execution by its registered provider rather than package presence alone.
Each successful child used two model requests and one tool call, while MAIN executed zero operation commands.
The sync receipt identifies the child-owned script executor, and readback verified the changed clone head and file contents.
The real SDK's separate zero-request initialization probe also verifies removal of plugin management tools, ignored parent/project extensions and context files, and the actual request handler's fixed verbosity and disabled provider web-search behavior.
Detailed timing and usage remain in the guard's `evidence.json`; these are single-run SDK responsiveness observations, not statistical latency or a terminal repaint measurement.
The harness invokes submit directly through the loaded tool definition, so it does not measure a full production primary conversation.

Two additional submissions changed only the detached child's proxy environment to an unreachable loopback endpoint.
The real provider returned `fetch failed` for both read-only and operation tasks; both ended `blocked` with one model request, zero tool calls, and no operation intent or receipt.
The transport journal retained `codes: ["ECONNREFUSED"]`, while the original provider message contained no underlying code.
Restoring the normal environment allowed the real fast-forward above without changing provider, model, or extension isolation.
This demonstrates the diagnostic boundary and refusal behavior; it does not identify the cause of an earlier failure whose underlying transport evidence was not retained.
The portable suites also cover nested/cyclic transport causes, secret exclusion, failure after a completed operation, refusal of provider-internal HTTP replay, and no operation replay after duplicate submission or reconciliation.
Plugin admission tests reject missing or mismatched packages, failed loading, extra discovered extensions and unexpected tool registrations.
Short sessions initialize the plugin compaction handlers but disable automatic compaction; provider or model context and output limits still apply and are not Firstmate controls.
This guard does not perform a primary `/compact`.

`tests/fm-short-operations.test.sh` uses a model fixture, real Git owners/effects, and a controlled Codebase forge to exercise merge-plus-sync, detached-checkout recovery, duplicate submission, cancellation, authority/identity drift, malformed output, partial success, and concurrent resource ownership.
It also proves that a lost merge response is reconciled by owner readback and that an owner killed after a possible effect is not replayed after restart.
The recovery cases release exact pre-intent and refused no-effect reservations only after the bound runner dies, while retaining reservations owned by a live runner, a possible effect, or another generation.
`FM_SHORT_INSTALL_LIVE=1` adds an actual verified ShellCheck 0.11.0 install into a temporary directory, without a global install.
`FM_SHORT_HERDR_E2E=1 bash tests/fm-short-operations-herdr.test.sh` adds real endpoint cleanup through a generated named lab and the guarded helper; the installed Herdr 0.8.0 run confirmed endpoint removal, refused dirty/unlanded/shared copies, and preserved the default-session tripwire.
The cleanup guard covers both an already absent copy and a real existing clean landed Treehouse 2.1.1 worktree.
The existing-copy case starts with a durable lease and a commit reachable from the disposable remote default branch, then observes the real owner return the slot from `leased` to `available`, clear its lease, and remove the exact endpoint and task record.
It verifies the returned copy remains clean at the landed head, another slot retains its lease identity, head, untracked sentinel and task metadata, and every unrelated pane remains present.
The saved `landed-cleanup-evidence.json` combines pre/post Treehouse and Herdr readbacks with the bound child-owner receipt; MAIN executes zero cleanup commands.
On 2026-09-27, the same Herdr guard also passed a real `fm-captain-hold.sh complete` update followed by short-task scout cleanup, with a doubled model and real completion/cleanup owners.
It first records an empty reviewed inventory, then records the source task's pending choice, and verifies one effective audit pair with the superseded assignments retained.
A second completion update after short-task binding refuses execution before any guarded effect.
A freshly bound request then removes only the synthetic scout's endpoint and metadata, preserving its report and both pending captain-held choices; `audit-cleanup-evidence.json` retains the before/after metadata, refusal and completed receipt.
The portable operation suite separately accepts only monotone legacy completion audit pairs, refuses repeated identity fields and malformed audit history, and refuses post-bind edits even when the final effective inventory is unchanged.
The fixture chains use one model fixture invocation and one operation tool per chain; fixture responses are not real-provider token evidence.
The optional install also repeats the tool call to prove receipt reuse without reinstalling.
The portable read-only companion is `tests/fm-short-agent.test.sh`; [the operator guide](../short-agents.md) owns current use, compatibility, and provider-limit distinctions.

## Pi branch activity display

Verified on 2026-09-29 (Asia/Shanghai) with Pi 0.87.1 and Node v22.22.2 on Linux using an isolated real Pi CLI pseudo-terminal and SDK branch.
This display is independent of terminal backend lifecycle; the guard does not call Herdr or operate fleet endpoints.
Other primary harnesses do not load Pi extensions, so this observational UI adds no Codex or TraeX runtime behavior.

```sh
bin/fm-test-run.sh tests/fm-pi-branch-status.test.sh tests/fm-pi-branch-status-live.test.sh tests/fm-pi-primary-types.test.sh
```

The real TUI guard captures the same installed Pi with and without the display extension and reports:

```text
VISIBLE Branch idle
VISIBLE Completed: unknown
VISIBLE model/tools
VISIBLE durable branch result
VISIBLE MAIN: check-main-only
VISIBLE ownership-lost
VISIBLE Branch disabled
VISIBLE Branch unknown
VISIBLE Branch error
VISIBLE Branch unknown
VISIBLE Branch
REAL_TUI_OK mixedMainClaimExcluded=true providerCalls=2 conflictBeforePrompt=true reload=true
```

The successful branch keeps an old MAIN-claimed row in the same queue while the unrelated new row alone receives a grant and completes the real `fm_branch_report` tool and durable outcome owner with a synthetic local provider transport.
The conflict case adds a MAIN claim after admission in the isolated home, uses the real pre-prompt classifier, and verifies that the accepted offer falls back without another provider request.
The portable branch-extension suite separately exercises the final locked grant after a claim race and exact branch acknowledgement that leaves the old MAIN row untouched.
The MAIN-only check uses the real trigger classifier; its routing observation is emitted by the fixture rather than a live fleet watcher.
The error and aged-evidence cases inject explicitly synthetic health observations into the supported event bus to test real terminal rendering, not a production provider outage or a two-minute wall-clock wait.
The portable test independently verifies that admission, mirror-independent observations, report-before-settlement and watcher no-op settlement never become successful completion, that 1000 notifications coalesce into one paint, and that shutdown/reload removes subscriptions and timers without changing unrelated queue/lock files or sending model messages.
Private task evidence retains raw before/after ANSI output and individual visible transition captures; the [branch operator guide](../pi-supervision-branch.md#activity-in-the-pi-terminal) owns their interpretation.
