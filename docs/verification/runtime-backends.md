# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `fm-spawn.sh` launches.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

The seven primary-capable adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |
| kimi | 0.31.1 | `kimi` | `kimi` | alive |

Claude Code is the harness whose title no longer attributes it at all; every other adapter is currently attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, and Kimi Code reported `kimi-code` as its foreground `comm` at 0.29.1 and `kimi` at 0.31.1, so these identities move between ordinary patch releases in both directions.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

The crewmate-only Muse Code 0.1.0-R708.1 adapter was verified separately on 2026-08-05 against tmux on macOS arm64.
Its installed `muse-bin-0.1.0-R708.1` foreground identity classified `alive`, while `musescore`, `amuse`, `muse-binary`, and `muse-bind` remained ambiguous in the portable regression.
[`muse.md`](muse.md#process-identity) owns the artifact identity and launcher evidence for that verification.

Bounded observed output:

```text
foreground comms:
  zsh
  .../instbin/muse-bin-0.1.0-R708.1
classify each:
  zsh                            -> shell
  muse-bin-0.1.0-R708.1          -> agent
fm_backend_agent_state tmux museliv:zsh
alive
```

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced, while the real-harness drift guard is opt-in under the policy in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Bounded output from the run that produced the table:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

### Harness-adapter instruction routing

Two checks keep the evidence boundaries separate.
`tests/fm-harness-adapter-references.test.sh` parses the router's declared JSON contract as normalized data and proves every selected reference is readable, which is structural evidence only.
`tests/fm-harness-adapter-instructions-live-e2e.test.sh` is an opt-in development check that sends the directly loaded router and every operation scenario across all nine harness identities to a local Ollama model, requires the generated plan as normalized JSON, and makes no external-provider call.

```sh
FM_HARNESS_ADAPTER_INSTRUCTION_EVAL=1 FM_HARNESS_ADAPTER_LOCAL_MODEL=ambient-router-gemma4:e4b bin/fm-test-run.sh tests/fm-harness-adapter-instructions-live-e2e.test.sh
```

That local evaluation demonstrates instruction-driven scenario selection, but it does not claim that a native harness loaded the selected files.
The guard prints the exact installed version or unavailable status for every native harness so absent tools and unexercised provider transports remain explicit rather than becoming passes.
Native loader behavior still requires the applicable live agent-tool check; no uniform deterministic zero-provider transport currently spans Claude, Codex, OpenCode, and Pi, and the other five tools remain unavailable where their binaries are absent.

Bounded output from the 2026-08-29 local run:

```text
ok - local model ambient-router-gemma4:e4b selected every operation scenario and all nine harness identities
# native loader not claimed: claude 2.1.220 (Claude Code) is installed, but this harness-neutral evaluation does not exercise its provider transport
# native loader not claimed: codex 0.147.0-alpha.6+local.4 is installed, but this harness-neutral evaluation does not exercise its provider transport
# native loader not claimed: opencode 1.14.48 is installed, but this harness-neutral evaluation does not exercise its provider transport
# native loader not claimed: pi 0.84.0 is installed, but this harness-neutral evaluation does not exercise its provider transport
# unverified native loader: pi-signed is not installed on this machine
# unverified native loader: grok is not installed on this machine
# unverified native loader: kimi is not installed on this machine
# unverified native loader: cursor is not installed on this machine
# unverified native loader: muse is not installed on this machine
# installed native tools recorded without overstating loader coverage: 4
# unavailable native tools: pi-signed grok kimi cursor muse
```

The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
FM_HOME="$fixture_home" bin/fm-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Firstmate therefore sets the exact `FM_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.
Herdr combines native registered-agent state with backend-generic idle-shell corroboration and needs no Pi-specific process-name branch.
Zellij has no verified recovery-grade agent process probe, while Orca and cmux do not support secondmate spawns, so those three retain their existing generic ordinary-launch semantics without a new liveness matcher.

The current classifier matrix and its refresh guard are recorded in [Composer classification matrix](#composer-classification-matrix), with portable shape coverage in `tests/fm-composer-lib.test.sh` and `tests/fm-composer-ghost.test.sh`.
Kimi pointer delivery and OpenCode 1.18.4 busy-queue behavior remain pinned by `tests/fm-kimi-harness.test.sh`, `tests/fm-tmux-submit-busy.test.sh`, and `tests/fm-composer-lib.test.sh`.
Herdr's Claude idle-native submit confirmation is pinned by `tests/fm-backend-herdr.test.sh` and refreshed by `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for every supported backend.

```sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-orca.test.sh
tests/fm-backend-cmux.test.sh
```

Bounded output from the incident regression:

```text
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - fm-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
The metadata-only validation covers tmux, Herdr, Zellij, Orca, and cmux before backend dispatch.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse share that backend cleanup boundary; their harness-specific hook files, tokens, transcript bindings, and session-log sidecars are cleaned only after it, so no harness needs a separate endpoint parser.

## Claude workspace trust

Verified 2026-09-03 on Claude Code 2.1.259.
Claude gates a folder it has never seen behind an interactive workspace-trust dialog, and the CLI documents the only bypass as non-interactive mode, which a crewmate pane is not.

```sh
claude --version
claude --help | grep -A 5 'workspace trust dialog'
```

```
2.1.259 (Claude Code)
                                        pipes). Note: The workspace trust dialog
                                        is skipped when Claude is run in
                                        non-interactive mode (via -p, or when
                                        stdout is not a TTY, e.g. piped or
                                        redirected output). Only use this in
                                        directories you trust. Settings files
```

`--dangerously-skip-permissions` is a permission control and is absent from that bypass, so an interactive worker in a fresh worktree still reaches the dialog.
Firstmate cannot answer it either, because its key plane carries only Enter, Escape, and C-c with no arrow navigation.
Suppression itself was then observed directly on the same date and version, with a control arm and a treatment arm.

The control arm launched a fresh linked worktree with no pre-registration, the way `bin/fm-spawn.sh` launches one.

```sh
tmux new-session -d -s tp-a -c /tmp/trustproof/wt-a \
  "CLAUDE_CONFIG_DIR=<cfg> CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '<brief>'"
```

```
Accessing workspace: /tmp/trustproof/wt-a
Quick safety check: Is this a project you created or one you trust? ...
Claude Code'll be able to read, edit, and execute files here.
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel
```

That pane confirms two load-bearing claims at once: the dialog fires despite `--dangerously-skip-permissions`, and the selection cursor sits on `No, exit`, so a sent Enter would have exited the worker.

The treatment arm pre-registered an equivalent fresh worktree and launched it identically against the operator's real config.

```sh
bin/fm-claude-trust.sh /tmp/trustproof/wt-c /tmp/trustproof/proj
tmux new-session -d -s tp-c -c /tmp/trustproof/wt-c \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions 'reply with exactly: BRIEF-REACHED'"
```

```
trusted: /tmp/trustproof/wt-c
```

```
Claude Code v2.1.259 ... /tmp/trustproof/wt-c
> reply with exactly: BRIEF-REACHED
. BRIEF-REACHED
```

No dialog appeared and the worker executed its brief with zero keypresses.
The scratch repo was deleted and the test entries were removed from the store and verified absent.
That verification is point-in-time rather than a durable guarantee, because a concurrent Claude session can re-add a path it visited: one entry reappeared after an earlier zero-residual check, most plausibly flushed by a session as it exited, and was removed again.

One limitation belongs beside that result.
An intermediate arm run against an isolated `CLAUDE_CONFIG_DIR` holding only a copied `.claude.json` cleared the trust dialog but then surfaced the separate machine-scoped Bypass Permissions warning.
That warning rendered in the same shape as the trust dialog, with the selection cursor on `No, exit` and the footer `Enter to confirm . Esc to cancel`, so a sent Enter would end that worker too.
That gate is not a production blocker, because a normal environment has already accepted it and the treatment arm above ran against the real config and saw neither dialog.
This change does not address that warning and does not claim to.

`bin/fm-spawn.sh` therefore pre-registers the task worktree through `bin/fm-claude-trust.sh` before launch, and `tests/fm-claude-trust.test.sh` pins both halves of the scope contract: a fresh worktree is trusted, and an out-of-scope path is refused.
That automated spawn case runs against a fake claude, so it asserts the store entry and the launch command and nothing more; the live arms above are what establish that the entry actually suppresses the dialog.
The composer-classification record below observes the same gate from the other side, where an untrusted worktree left Claude, Grok, and Muse unverified because the guard reads a first-launch trust dialog as an unreadable composer.

## Composer classification matrix

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape fleet-wide; each backend contributes only a capture and a capability descriptor.
The live half of that guarantee was verified on 2026-08-10 from an already-trusted checkout at the branch's final validated head, against every installed harness then covered by the empty-composer matrix on tmux 3.6a, macOS arm64, on an isolated private socket, with no prompt submitted to any harness.
An earlier untrusted-worktree run left Claude, Grok, and Muse unverified because the guard treats first-launch trust dialogs as an unreadable-composer state and never confirms them; this trusted-checkout rerun supersedes those missing results.

```sh
FM_COMPOSER_MATRIX_LIVE=1 tests/fm-composer-matrix-live-e2e.test.sh
```

Observed output:

```text
ok - claude (2.1.227 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.146.0): real idle composer classifies empty
ok - opencode (1.14.46): real idle composer classifies empty
ok - pi (0.84.0): real idle composer classifies empty
ok - grok (grok 1.0.0 (3cd0d0cbcebe)): real idle composer classifies empty
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.1.0 (0.1.0-R708.1)): real idle composer classifies empty
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - zellij (zellij 0.44.0): unrelated pane change never confirms delivery (verdict: unknown)
ok - live composer-matrix guard verified 8 live surface(s)
```

All six installed harnesses' real idle composers reached a proven `empty` (Claude auto-updated to 2.1.227 between the audit and this rerun, so the shipped classifier is proven against the newer release as well), including Pi through the tmux foreground-process identity probe, Grok through the titled-bottom-border tolerance, and OpenCode through the left-bar shape; Codex and OpenCode first parked on vendor update-available modals that the strict classifier correctly refused until the guard's single non-submitting Escape dismissed them.
The strict blank-row posture held live (a blank shell row deferred injection), and a zellij pane changing for reasons unrelated to submission never confirmed a delivery, replacing the retired content-diff heuristic's false positive.
Kimi was not installed on the verification machine; its bordered shape is pinned by the portable byte-capture regressions in `tests/fm-composer-lib.test.sh`, which also carry the other five adapters' capability profiles for every harness under both a UTF-8 locale and `LC_ALL=C`.
This guard is the refresh command after an upgrade to any matrix-covered harness; rerun it and update the versions above rather than trusting this table across releases.
Known staleness: on 2026-08-23 the steering-inbox doorbell run observed grok 1.0.5's idle composer classifying `unknown` (and sometimes pending-family), never `empty`, so the grok row above is stale for 1.0.5 and owes a refresh; steering is unaffected because the send path's composer check is advisory, but empty-requiring consumers (away-daemon injection, spawn readiness) should not trust the 1.0.0 grok result.
Cursor is deliberately outside this cursor-anchored empty-composer matrix because its terminal cursor is parked outside the composer; tmux's Cursor-specific, process-identity-gated cursorless fallback is covered by the [Cursor Agent CLI](#cursor-agent-cli) section's separate live evidence and drift guard.

`zellij action dump-screen --pane-id <id> --ansi` was verified at zellij 0.44.0 to preserve ANSI styling (real Claude Code rendered inside a zellij pane dumped `ESC[m` `❯` U+00A0 for its idle composer row), which is the capability the zellij composer classifier reads.

## Steering-inbox doorbell

The steering channel's one behavioral assumption - a real worker agent follows the constant self-describing doorbell line (list the inbox, read and act on its records in numeric order, then `mv` each into `handled/`) - was verified on 2026-08-23 against every installed verified harness, on tmux 3.6a, macOS arm64, on an isolated private socket, driving the REAL `bin/fm-send.sh` end to end (durable record plus doorbell, with one mid-wait re-ring playing the watcher's role).

```sh
FM_SEND_INBOX_LIVE_E2E=1 tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Observed output (combined across the full run and the grok rerun after the advisory-skip narrowing landed):

```text
ok - claude (2.1.241 (Claude Code)): the doorbell reached a real worker, which acted and acked with the mv
ok - codex (codex-cli 0.147.0): the doorbell reached a real worker, which acted and acked with the mv
ok - opencode (1.18.21): the doorbell reached a real worker, which acted and acked with the mv
ok - pi (0.84.1): the doorbell reached a real worker, which acted and acked with the mv
# grok (grok 1.0.5 (5115b46bc909) [stable]): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)
ok - grok (grok 1.0.5 (5115b46bc909) [stable]): the doorbell reached a real worker, which acted and acked with the mv
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.2.1 (0.2.1-R1215.1)): the doorbell reached a real worker, which acted and acked with the mv
```

All six installed harnesses honored the doorbell contract with real model turns: each listed the inbox named by the doorbell, read its record, executed the instruction inside it, and acknowledged with the atomic `mv`.
Two findings from the run shaped the shipped behavior: an OpenCode vendor update modal swallowed the first doorbell and the single re-ring recovered it, which is exactly the watcher ladder's job; and grok 1.0.5's idle composer never classifies `empty` (a classifier drift owned by the [Composer classification matrix](#composer-classification-matrix) guard, whose refresh for grok 1.0.5 is still owed), which is why the ring's advisory pre-check skips only on an exact proven `pending` verdict - a doorbell into an ambiguous composer is a recoverable constant line, while skipping on ambiguity would starve steering for any harness the classifier cannot positively identify.
Kimi was not installed on the verification machine; its receive path is the same one-line-plus-shell contract, and the portable ladder and enqueue regressions in `tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh` cover every harness-independent half.
This guard is the refresh command after any harness upgrade; it spends a small number of real tokens per installed harness, reports an absent harness explicitly, and refuses a run that verified nothing.

## Gemini

The Gemini crewmate adapter was verified on 2026-09-04 with gemini-cli 0.58.0 on Linux, Node v24.20.0, tmux 3.4.
Every check below ran in throwaway scratch worktrees against the real CLI; no task worktree was used and no agent was left running.
The credential was supplied only through the `GEMINI_API_KEY` environment variable and its value appears nowhere in this record.

### Trust options are not equivalent

The refusal an untrusted launch produces, and its headless exit status:

```sh
gemini -p 'say OK'; echo "rc=$?"
```

```text
Gemini CLI is not running in a trusted directory. To proceed, either use `--skip-trust`, set the `GEMINI_CLI_TRUST_WORKSPACE=true` environment variable, or trust this directory in interactive mode.
rc=55
```

Both documented options clear that refusal, but only one loads project configuration.
The A/B below ran twice in ONE worktree carrying a project `AfterAgent` hook, with the same config home and the same prompt, changing only the trust mechanism:

```text
--skip-trust                 project-hook-fired=NO   untrusted-warnings=0   turn=✦ ECHO
TRUST_WORKSPACE=true         project-hook-fired=YES  untrusted-warnings=0   turn=✦ FOXTROT
```

`gemini skills list` names the cause directly in the untrusted case:

```text
Skipping project agents due to untrusted folder. To enable, ensure that the project root is trusted.
Project hooks disabled because the folder is not trusted.
```

This is why `bin/fm-spawn.sh` launches with `GEMINI_CLI_TRUST_WORKSPACE=true` and why `--skip-trust` must not be substituted for it.

### Busy signal

A full turn was captured every two seconds. The status row above the separator carries the one ASCII token, and the phase text beside it is model-generated:

```text
busy_1 | 1 |  ⠸ Thinking... (esc to cancel, 1s)
busy_5 | 1 |  ⠸ Begin Counting Methodically (esc to cancel, 9s)
busy_6 | 1 |  ⠇ Continue Enumerating Concepts (esc to cancel, 11s)
busy_7 | 0 |
busy_12 | 0 |
```

The idle capture taken before the prompt also contained no `(esc to cancel,`.
Because the phase text varies per turn and the spinner is braille, neither is usable; `(esc to cancel,` is the only stable rendered token, and the adapter uses the semantic hooks below as its actual state source.

### Hook lifecycle

`BeforeAgent`, `AfterAgent`, `SessionStart`, and `SessionEnd` were registered on one probe that appends its event name, then driven through a normal turn, an Escape interrupt, and `/quit`:

```text
--- after startup ---   SessionStart
--- mid-turn ---        SessionStart, BeforeAgent
--- after INTERRUPT --- SessionStart, BeforeAgent, AfterAgent
--- after /quit ---     SessionStart, BeforeAgent, AfterAgent, SessionEnd, SessionEnd
```

Two facts the adapter depends on come from that run: `AfterAgent` closes a turn that was CANCELLED, not only one that completed, and `SessionEnd` fired TWICE for a single `/quit`, so the repeated idle event must be harmless.
The `AfterAgent` payload carried the worktree as `cwd`, which is what binds a hook to its task:

```text
keys: ['cwd', 'hook_event_name', 'prompt', 'prompt_response', 'session_id', 'stop_hook_active', 'timestamp', 'transcript_path']
hook_event_name = AfterAgent
stop_hook_active = False
prompt = 'Say the single word CEDAR and stop.'
```

On the cancelled turn the same payload carried `prompt_response = '[no response text]'`.

### Autonomous end-to-end worker

One throwaway worker was launched exactly as the spawn launches one - positional brief, `-y`, workspace trust - and observed from start to idle:

```text
t=5s   (esc to cancel, 2s)
t=30s  busy marker present
idle at ~34s, busy marker count 0
worker-output.txt: DELIVERED
turn-end hook fires: 1
```

Its pane showed `✓ WriteFile worker-output.txt → Accepted (+1, -0)` with no approval gate, confirming `-y` runs unattended, and `Executing Hook: fm-turn-end` in the status row after the turn.

The adapter was then driven through the REAL `bin/fm-spawn.sh` and `bin/fm-control.sh` against a real Gemini pane in an isolated home:

```text
spawned gm-e2e harness=gemini kind=ship mode=no-mistakes yolo=off window=... worktree=...
hooks installed by spawn (state/<id>.gemini-settings.json): ['BeforeAgent', 'AfterAgent', 'SessionEnd']
t=4s   state: working · source: pane · harness busy (gemini-hook)
t=8s   state: working · source: pane · harness busy (gemini-hook)
after turn: v1 gen=... state=idle source=gemini-hook event=after-agent
e2e-output.txt: SEAWORTHY
interrupt-delivered gm-e2e harness=gemini backend=tmux verified=agent-alive cancel=unconfirmed
after interrupt: v1 gen=... state=idle source=gemini-hook event=after-agent
stopped gm-e2e harness=gemini backend=tmux endpoint=... worktree=...
```

The interrupt line is the one worth keeping: `AfterAgent` closed the record on a CANCELLED turn, which is why a gemini interrupt needs no `fm-interrupt` fallback event.
A single Escape on a long turn printed `ℹ Request cancelled.`, dropped the busy token, and left the agent running; `/quit` then exited with status 0 and printed `To resume this session: gemini --resume <session-id>`, and resuming by that id restored the full transcript.

### Identity markers

Env var NAMES were read from a real Gemini tool process launched under a Claude primary; no value of `GEMINI_API_KEY` was read.

```text
GEMINI_CLI=[1]
AI_AGENT=[claude-code_2-1-260_agent]
TRUSTWS=[true]
CLAUDECODE=[1]
```

`GEMINI_CLI` is unset in the launching environment, so it is Gemini's own; `CLAUDECODE` is inherited, which is why `bin/fm-harness.sh` tests `GEMINI_CLI` first.
`AI_AGENT` carried the CLAUDE primary's value and is therefore an inherited launcher marker, never a Gemini identity.

Ancestry cannot substitute for the marker on this platform:

```sh
node -e 'const{execSync}=require("child_process");console.log(execSync("ps -o comm= -p "+process.pid).toString().trim())'
```

```text
MainThread
```

The shipped CLI is a node bundle, so its live process never presents as `node` and neither ancestry arm matches it.

The same shape breaks pane liveness, which the end-to-end run surfaced as a hard refusal rather than a silent wrong answer:

```text
error: task gm-e2e's endpoint reads 'ambiguous' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint
```

A live gemini pane's foreground group read `comm=MainThread` and `argv0=/home/<user>/.local/node/bin/node`, so `bin/fm-gemini-lib.sh` now identifies it from argv[1] instead.
After that change the same endpoint classified `alive` while the worker ran and `dead` once it exited, so the rule is not simply always positive.
`tests/fm-gemini-harness.test.sh` pins that boundary so it is not later documented away, and `tests/fm-busy-adapter-wiring.test.sh` drives the generated hooks through the real writer and classifier.

```sh
bin/fm-test-run.sh tests/fm-gemini-harness.test.sh tests/fm-busy-adapter-wiring.test.sh
```

### Credential wedge and its blast radius

With no resolvable credential the pane wedges on `Enter Gemini API Key` rather than failing.
That dialog is a credential FIELD, so lifecycle text sent to a wedged pane is submitted into it and stored.
Observed after an ordinary exit was delivered to such a pane: a `~/.gemini/gemini-credentials.json` (mode 0600) appeared that had not existed before, and a later credential-less run stopped refusing cleanly and instead reached the API:

```text
before: rc=41  When using Gemini API, you must specify the GEMINI_API_KEY environment variable.
after : rc=1   API key not valid. Please pass a valid API key.  (API_KEY_INVALID)
```

Clearing that stored credential restored both behaviours:

```text
GEMINI_API_KEY=<from the operator's own store> gemini --skip-trust -p 'Reply with exactly the word NOVEMBER.'  ->  NOVEMBER  rc=0
env -u GEMINI_API_KEY gemini --skip-trust -p hi                                                              ->  rc=41
```

The adapter reference records the operational rule this produces: never drive lifecycle text into a gemini pane showing that dialog; treat it as a credential blocker and retire the endpoint instead.
The credential must also be present before the session-provider daemon starts, since a long-lived tmux or Herdr server hands panes the environment it was started with.

### Settings placement

Firstmate's hooks are NOT written into the worktree's `.gemini/settings.json`, because unlike Claude's `settings.local.json` that path is the project's own committed settings file.
They go to a firstmate-owned `state/<id>.gemini-settings.json` reached through `GEMINI_CLI_SYSTEM_SETTINGS_PATH`.
Two measurements support that choice.
Hooks from the system layer fired under `--skip-trust` in an untrusted folder, so the busy contract does not depend on the trust decision:

```text
=== events (UNTRUSTED workspace, --skip-trust) ===
BeforeAgent
AfterAgent
```

And hook arrays MERGE across layers rather than overriding, so a project's own hooks keep running alongside firstmate's:

```text
=== which AfterAgent hooks ran (trusted workspace, both layers define AfterAgent) ===
PROJECT
SYSTEM
```

A second end-to-end spawn against a project that already committed its own `.gemini/settings.json` confirmed the file was untouched, that `git status` reported only the worker's own new output file, and that teardown removed firstmate's settings file:

```text
t=4s   state: working · source: pane · harness busy (gemini-hook)
t=8s   state: working · source: pane · harness busy (gemini-hook)
after turn: state=idle source=gemini-hook event=after-agent
e2e2-output.txt: ANCHOR
project .gemini/settings.json: {"context":{"fileName":"GEMINI.md"}}   (unchanged)
interrupt-delivered gm2 harness=gemini backend=tmux verified=agent-alive cancel=unconfirmed
stopped gm2 harness=gemini backend=tmux
teardown gm2 complete; state/gm2.gemini-settings.json removed
```

### Not verified

Gemini as a PRIMARY or SECONDMATE runtime is unverified and is refused by `bin/fm-spawn.sh`: no wake protocol exists under `docs/supervision-protocols/` and no turn-end guard adapter was built or exercised.
No reasoning-effort axis was found; `gemini --help` on 0.58.0 exposes no effort, reasoning, or thinking flag, so the record-and-omit contract applies.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, with agent lifecycle control and the agent-free proof measured on Herdr 0.8.2, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
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

### Submit confirmation

Measured 2026-08-19 against Herdr 0.8.0 and Claude Code 2.1.236 in an isolated `fm-lab-` session.

`herdr agent get` reported `agent_status=idle` on every sample across a landed one-word turn and an 8-second `sleep` tool call, while the pane rendered `Pontificating…` then `Sock-hopping… (11s · ↓ 234 tokens)`.
`fm_backend_herdr_send_text_submit` therefore cannot treat native idle as proof of a swallow.
The portable regressions in `tests/fm-backend-herdr.test.sh` and `tests/fm-composer-lib.test.sh` pin the verdicts: native idle plus a cleared composer is delivery, proven pending plus idle is a swallow, and proven pending plus a generating busy signal is a queued Enter.
Refresh the live Claude proof with:

```sh
FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh
```

Observed 2026-08-19:

```text
ok - live Herdr submit confirm: Claude Code (2.1.236 (Claude Code)) on herdr 0.8.0 reports empty for a landed idle steer
```

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
ok - real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-home and presentation topology

Per-home behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, active-tab refusal, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
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
ok - real Herdr lab: the primary presentation setting inherits into real secondmate homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
One concurrent cross-home recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention is a deliberate hard refusal rather than a flat fallback, which default-on now makes reachable from any Herdr home.
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

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced secondmate cleanup, including recursive cleanup of a nested secondmate whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced secondmate teardown preflights every Herdr child before cleanup mutation
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 \
  tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

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

Herdr is one of the two backends whose recovery-grade agent-state classifier the control plane may trust ([agent-control.md](../agent-control.md)), so its lifecycle gating is measured against the real binary; reverified 2026-09-02 on Herdr 0.8.2, macOS aarch64, and first measured 2026-08-02 on Herdr 0.7.5:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed output on Herdr 0.8.2:

```text
ok - real herdr: exit on a pane with no registered agent is idempotent success
ok - real herdr: interrupt refuses when herdr's own agent registry reports no agent
ok - real herdr: a reported registration the pane's own process inventory contradicts reads agent-free
ok - real herdr: an exited worker's pane is positively eligible for its replacement instead of being typed into
ok - real herdr: interrupt still refuses on a pane whose registration outlived its agent
ok - real herdr: the same registration over a running foreground process stays alive
ok - real herdr: interrupt delivers the harness's key and proves the agent survived it
ok - real herdr: an agent that does not stop fails closed instead of being reported as stopped
ok - real herdr: no control verb removed the endpoint, the task's local copy, or its branch
```

The registry written through `herdr pane report-agent` is the same source `fm_backend_herdr_agent_state` classifies, so the case drives the registry and the pane's processes apart deliberately and runs the identical registered reading twice: once over a plain shell and once over a real foreground process, with no real agent launched.

Herdr 0.8.2 keeps such a report registered even though the pane runs nothing but its shell, measured in an isolated `fm-lab-` session:

```text
herdr pane report-agent <pane> --source fm-control-smoke --agent fm-control-smoke-agent --state idle
herdr agent get <pane>   -> {"agent_status":"idle"}
herdr pane process-info  -> foreground_processes [{"name":"zsh","argv0":"zsh"}]
```

That is why the classifier corroborates the registry against the pane's own inventory rather than trusting a reported registration alone.
Herdr does validate a report claiming a source it owns itself: an otherwise identical `--source herdr:pi --agent pi` report on the same shell-only pane was rejected and `agent get` still answered `agent_not_found`.

`tests/fm-control-herdr-smoke.test.sh` is the guard that refreshes this record; run it after every Herdr upgrade rather than trusting the version above.

### Agent-free proof across installed harnesses

The classifier's negative verdict rests on `pane process-info` naming a lone bare idle shell, and both that name and its argv0 come from the harness vendor, so the proof is measured against every installed harness rather than a stub.
Reverified 2026-09-02 on Herdr 0.8.2, macOS aarch64, in an isolated `fm-lab-` session, and first measured 2026-09-01 on the same Herdr with the then-current claude 2.1.252 and codex 0.150.1:

```sh
FM_HERDR_AGENT_FREE_PROOF=1 tests/fm-herdr-agent-free-proof-live-e2e.test.sh
```

Observed output:

```text
# herdr: herdr 0.8.2
# claude 2.1.259 (Claude Code): foreground=[security/security 2.1.259/claude] state=alive
ok - herdr agent-free proof: claude 2.1.259 (Claude Code) running in a Herdr pane never proves a bare idle shell
# codex codex-cli 0.152.1: foreground=[codex/codex] state=alive
ok - herdr agent-free proof: codex codex-cli 0.152.1 running in a Herdr pane never proves a bare idle shell
# opencode 1.17.11: foreground=[opencode/opencode] state=alive
ok - herdr agent-free proof: opencode 1.17.11 running in a Herdr pane never proves a bare idle shell
# pi 0.84.4: foreground=[node/pi] state=alive
ok - herdr agent-free proof: pi 0.84.4 running in a Herdr pane never proves a bare idle shell
# skip: pi-signed is not installed on this machine, so its Herdr classification is unverified here
# skip: grok is not installed on this machine, so its Herdr classification is unverified here
# skip: kimi is not installed on this machine, so its Herdr classification is unverified here
# cursor 2026.08.31-4057e58: foreground=[node/cursor-agent] state=alive
ok - herdr agent-free proof: cursor 2026.08.31-4057e58 running in a Herdr pane never proves a bare idle shell
# skip: muse is not installed on this machine, so its Herdr classification is unverified here
# unverified on this machine (not installed): pi-signed grok kimi muse
# checked 5 installed harness(es) on herdr herdr 0.8.2 in workspace w1
```

Both guards resolve the harness binary through one shared helper (`tests/harness-binary-helpers.sh`), which is also what `tests/fm-harness-liveness-drift-live-e2e.test.sh` launches through, so neither guard can measure a different binary than the other or than a real spawn.

No installed harness leaves the pane holding one lone bare shell, so none can satisfy the proof, and Herdr registered each of them within the guard's wait.
Each owns the pane's foreground under its own argv0, and claude 2.1.259 additionally keeps a `security` helper in that foreground, which is a second process rather than a shell and so refuses the proof twice over.
`pi-signed`, `grok`, `kimi`, and `muse` were not installed on that machine and remain unverified here; the guard reports them explicitly and refuses a pass that checked nothing.
This is the command that refreshes this record; run it after every harness upgrade.

### Native busy-state corroboration cost

`fm_backend_herdr_busy_state` corroborates every reported agent state against the pane's own `pane process-info` inventory.
`bin/backends/herdr.sh` owns that contract and [`herdr-backend.md`](../herdr-backend.md#current-transport-behavior) states it; this record measures what it costs.
Busy state is read on watcher and away-mode ticks, so the added read was measured rather than assumed.
Each reported branch is measured twice, once through the shipped function and once through the same read without the corroboration, so the added cost is derivable from this output rather than asserted beside it.
The agent is registered before the first row, so every read priced here is a registered read rather than the `agent_not_found` path, which short-circuits before jq.
Measured 2026-09-02 on Darwin arm64, Herdr 0.8.2, in an isolated `fm-lab-` session, 50 calls per row:

```sh
# From the repo root. Isolated fm-lab- session only, never the default one.
. tests/herdr-test-safety.sh
. bin/fm-backend.sh
fm_backend_source herdr
herdr_forget_inherited_pane
SESSION=fm-lab-busycost-$$
export HERDR_SESSION="$SESSION"
fm_herdr_lab_prepare "$SESSION"
WT=$(mktemp -d)/wt && mkdir -p "$WT"
RAW=$(fm_backend_herdr_container_ensure "$WT")
IDS=$(fm_backend_herdr_create_task "${RAW%%$'\t'*}" fm-busycost "$WT" "${RAW#*$'\t'}")
PANE=${IDS##* }

report() { herdr pane report-agent "$PANE" --source fm-busy-cost \
  --agent fm-busy-cost-agent --state "$1" --session "$SESSION" >/dev/null; }
verdict() { printf '%-52s -> %s\n' "$1" "$(fm_backend_herdr_busy_state "$SESSION:$PANE")"; }
# The same read WITHOUT the corroboration, so the added cost is derivable from
# this output rather than asserted beside it.
uncorroborated() {  # <target>
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}
bench() {  # <label> <calls> <command...>
  local label=$1 n=$2 secs
  shift 2
  secs=$( { TIMEFORMAT=%R; time ( for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1; done ); } 2>&1 )
  awk -v l="$label" -v s="$secs" -v n="$n" \
    'BEGIN { printf "%-52s %6.1f ms/call (%s s / %d calls)\n", l, s * 1000 / n, s, n }'
}

printf '%s | %s\n' "$(uname -sm)" "$(herdr --version)"
report working
bench 'agent get (the existing per-poll read)' 50 fm_backend_herdr_agent_status_raw "$SESSION" "$PANE"
bench 'pane process-info (the added read)' 50 fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE"
verdict 'working registration over a bare idle shell'
bench 'busy_state, working over a bare idle shell' 50 fm_backend_herdr_busy_state "$SESSION:$PANE"
report idle
verdict 'idle registration over a bare idle shell'
bench 'busy_state, idle over a bare idle shell' 50 fm_backend_herdr_busy_state "$SESSION:$PANE"
herdr_pane_run_foreground "$SESSION" "$PANE" 'sleep 600'
report working
verdict 'working registration over a live foreground process'
bench 'busy_state, working over a live process' 50 fm_backend_herdr_busy_state "$SESSION:$PANE"
bench 'the same read uncorroborated, working' 50 uncorroborated "$SESSION:$PANE"
report idle
verdict 'idle registration over a live foreground process'
bench 'busy_state, idle over a live process' 50 fm_backend_herdr_busy_state "$SESSION:$PANE"
bench 'the same read uncorroborated, idle' 50 uncorroborated "$SESSION:$PANE"
fm_herdr_lab_teardown "$SESSION"
```

Observed output:

```text
Darwin arm64 | herdr 0.8.2
agent get (the existing per-poll read)                 11.8 ms/call (0.590 s / 50 calls)
pane process-info (the added read)                      7.1 ms/call (0.353 s / 50 calls)
working registration over a bare idle shell          -> unknown
busy_state, working over a bare idle shell             97.0 ms/call (4.848 s / 50 calls)
idle registration over a bare idle shell             -> unknown
busy_state, idle over a bare idle shell               111.8 ms/call (5.589 s / 50 calls)
working registration over a live foreground process  -> busy
busy_state, working over a live process                56.8 ms/call (2.841 s / 50 calls)
the same read uncorroborated, working                  26.3 ms/call (1.313 s / 50 calls)
idle registration over a live foreground process     -> idle
busy_state, idle over a live process                   54.0 ms/call (2.699 s / 50 calls)
the same read uncorroborated, idle                     31.0 ms/call (1.549 s / 50 calls)
```

Both reported branches do identical added work, and this run prices it at 30.5 ms on the `working` branch (56.8 against 26.3) and 23.0 ms on the `idle` branch (54.0 against 31.0).
The spread between those two is machine load across the run, not a difference between the branches; the added `pane process-info` read alone is 7.1 ms here and the rest is parsing it.
The sample ends as soon as the foreground process group turns out not to be the shell, before the operating-system process table is scanned.
An already-`unknown` verdict pays nothing, since no inventory reading can change it.

Only a pane that really is a lone bare idle shell runs the proof to the end, around 100 ms per call, since that is the one shape whose foreground process group is the shell and therefore reaches the process-table scan.
That pane is the husk this exists to catch, and it is read once per watcher tick rather than in a loop.
The verdict rows show it resolving to `unknown` from both a stale `working` and a stale `idle`, which is the behavior this record exists to price.

The tight submit-confirmation loops pay nothing at all, because they never call this function.
`fm_backend_herdr_wait_for_working`, `fm_backend_herdr_send_text_submit`, and `fm_backend_herdr_queued_enter_busy` each poll `fm_backend_herdr_agent_status_raw` directly, measured unchanged at 11.8 ms per call above on the same registered pane, and it deliberately skips even the server-ensure round trip that `fm_backend_herdr_busy_state` pays.
The consumers that do read busy state are `bin/fm-busy-lib.sh`, `bin/fm-supervise-daemon.sh`, and `bin/fm-pending-reply-lib.sh`, all once per tick.

Per-call figures move with machine load, so each row prints the raw elapsed seconds and call count it divided, and the verdict rows show which branch each measurement actually took.

### Away-mode transport

The Pi/Herdr return and injection path was reverified on Herdr 0.7.3 and Pi 0.80.7:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Observed guarantees: pending composer input refused injection and raised one alert; idle Pi accepted one marked escalation; the return gate refused ordinary work while a live blocker remained; resolving the blocker allowed the return flow.
The dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

## Zellij

The current compatibility floor and latest verification are Zellij 0.44.0 with `jq` on macOS aarch64.
All real tests use a uniquely named session and `tests/zellij-test-safety.sh`; they never touch a session named `firstmate` or call all-session deletion.

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Headless session | `zellij attach -b <name>` without a TTY | Created a persistent background session and returned. |
| Session list | `zellij list-sessions --short --no-formatting` | Returned one plain name per line without starting a session. |
| Create tab | `zellij action new-tab --cwd <dir> --name <title>` | Returned a numeric tab id and focused the new tab when a client was attached. |
| Pane discovery | `zellij action list-panes --json` | Included terminal pane id, tab id, plugin flag, and top-level `pane_cwd`. |
| Literal send | `zellij action paste --pane-id <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-keys --pane-id <id> Enter`, `Esc`, and one argument `Ctrl c` | All three shared operations worked. |
| Capture | `dump-screen --pane-id <id>` or `--full` | Worked with no attached client; no line-bound flag exists. |
| Styled capture | `dump-screen --pane-id <id> --ansi` | Preserved ANSI styling ("Composer classification matrix" above); feeds the zellij composer classifier. |
| Close | `close-tab-by-id <id>` | Removed the live task pane and tab together. |
| Failure exit | actions against missing targets | Returned exit 0, requiring structural preflight and output-shape validation. |

`pane_cwd` stayed frozen when a foreground subshell changed directory.
The marker-delimited `pwd` probe returned the live nested cwd and is covered by the real smoke.
The focus mitigation restored the previously active tab after `new-tab`, with the unavoidable narrow race documented in the operator guide.

```sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-zellij-smoke.test.sh
```

The real lifecycle smoke proved spawn, metadata, nested-subshell worktree discovery, send, capture, unlanded-work refusal, approved local landing, exact tab cleanup, and session cleanup without retaining task-specific ids or branch names here.

## Orca

Real readiness was verified against `/usr/local/bin/orca` with `/Applications/Orca.app` bundle version 1.4.116.

```sh
orca status --json
```

Observed fields:

```text
result.runtime.reachable=true
result.runtime.state=ready
```

`orca terminal create --json` returned `result.terminal.handle`.
`orca worktree create` returned `result.worktree.id` and `result.worktree.path`.
Speculative bare ids and nested terminal fields were deliberately rejected.

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

The fake-Orca suite covers readiness, registration, create response parsing, metadata routing, popup-safe submit, and path-matched release refusal.

## cmux

The current compatibility floor is cmux 0.64, and the active live evidence uses 0.64.17 build 97 on macOS aarch64.
Real tests use only exact `fm-test-` workspaces guarded by `tests/cmux-test-safety.sh` and never quit or relaunch the captain's app.

```sh
cmux version
cmux ping
```

Observed version:

```text
cmux 0.64.17 (97) [9ed29d81a]
```

Source and live checks established the five control modes:

- `off` starts no listener.
- `cmuxOnly` rejects an external Firstmate process by ancestry.
- `automation` uses an owner-only 0600 socket with no handshake.
- `password` uses the same 0600 socket plus `auth <password>`.
- `allowAll` uses a 0666 socket with no authentication.

The live default rejection was `Access denied - only processes started inside cmux can connect`.
The live password challenge was `Authentication required - send auth <password> first`.
The app configuration writer did not retain a hand-added socket password, which is why the operator guide requires Settings and a local Firstmate password source.

Current active CLI findings:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Create | `new-workspace --name <title> --cwd <dir> --focus false --id-format uuids` | Created one workspace with one surface without focusing it. |
| Fresh readiness | `list-panes --workspace <id> --json --id-format uuids` | Found a brand-new surface before content existed. |
| Fresh read counterexample | `read-screen` before any write | Returned `internal_error: Failed to read terminal text`. |
| Literal send | `send --workspace <id> --surface <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-key ... enter|escape|ctrl-c` | All shared key operations worked. |
| Nested cwd | `current_directory` plus foreground subshell | Structured cwd froze; the marker-delimited `pwd` probe found the live cwd. |
| Last surface | `close-surface` on the only surface | Refused with `invalid_state: Cannot close the last surface`. |
| Last workspace | `close-workspace` on the only workspace in a window | Printed success but left the workspace present. |

The last-workspace workaround was reverified on 2026-07-10 in Automation mode.
After creating one unfocused unnamed sibling in the same window, `close-workspace` removed the exact task workspace and left only cmux's default sibling.
A selected non-last workspace closed directly, proving that window cardinality rather than selection is the trigger.

Source inspection confirmed each workspace constructor creates a new UUID with no restored-id input.
Recovery therefore remains title-based.
The bundled Claude wrapper was observed stripping `CMUX_*` variables on its failed socket-probe path while retaining the app bundle id, supporting the macOS-only bundle-id and ancestry fallbacks.

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

The real smoke proves socket access, fresh readiness, current-path probing, send and keys, bounded capture, title identity, and guarded exact cleanup.

### Claude composer confirmation

The borderless Claude composer confirmation was verified on 2026-08-09 with cmux 0.64.22 build 102 and Claude Code 2.1.226 on macOS aarch64.
An isolated real Claude worker rendered a bare `❯` plus U+00A0 row between horizontal rules.
The cmux classifier returned `empty`, and one `fm-send.sh --resolve-key <key> ALBATROSS` command - which used the typed path before ordinary task steers moved to the inbox - appended the matching `resolved` event before the worker reported completion.
The terminal capture contained exactly one submitted `❯ ALBATROSS` row.
The dated proof used this command:

```sh
FM_CMUX_CLAUDE_COMPOSER_LIVE=1 bin/fm-test-run.sh tests/fm-cmux-claude-composer-live-e2e.test.sh
```

That guard still addresses the worker by task selector, so it no longer reaches the typed submit path and is not a current refresh entry point for this guarantee.
The portable classifier regression is `tests/fm-backend-cmux.test.sh`.

## Codex App host tools

A reusable Desktop host-tool smoke ran on 2026-07-06 against Codex Desktop bundle version 26.623.101652, build 4674, bundle id `com.openai.codex`.
Local paths and task-specific ids are intentionally not retained here.

The host-tool sequence was:

1. list a saved project;
2. create a Desktop-owned worktree thread;
3. recover and read the thread while active and after completion;
4. verify the thread appended a Firstmate status line and wrote its report;
5. send a follow-up to the same thread;
6. read the completed follow-up;
7. archive the exact thread;
8. read the archived transcript with state `notLoaded`.

Observed guarantee: a Desktop-owned thread can write Firstmate lifecycle files when the prompt provides an authorized absolute path, and create, send, read, and archive work at the Desktop host-tool layer.
The missing guarantee remains a supported shell-callable bridge that lets Firstmate perform those operations against the same visible Desktop endpoint.
App-server partial methods and raw socket experiments do not satisfy that bridge contract.

## Cursor Agent CLI

Cursor runs crewmate, scout, secondmate, and primary work; [`supervision.md`](supervision.md#cursor-primary-park-2026-08-13) owns the primary evidence.
The evidence below was produced on 2026-08-11 against the installed signed CLI on macOS 26.5.2 arm64 with tmux 3.6a, running as `kunchenguid`, and extended on 2026-08-13 with the tmux composer verdict below.

- Binary: `~/.local/bin/cursor-agent`, canonicalizing into `~/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent`.
- Version: `cursor-agent --version` reported `2026.08.11-e8db854`, and `cursor-agent status` reported a logged-in account.
- Both installed names, `cursor-agent` and the legacy alias `agent`, resolve into that same versioned install tree.

Resolution prints the STABLE launcher rather than the canonical target, because the canonical path carries a version the CLI replaces on its own auto-update.

### Process identity

`#{pane_current_command}` and `ps -o comm=` disagree for cursor, which is why identity reads both:

| Source | Observed value |
| --- | --- |
| `#{pane_current_command}` | `node` |
| `ps -o comm=` | `/Users/<user>/.local/bin/cursor-agent` |
| child argv | `.../bin/cursor-agent --use-system-ca .../versions/2026.08.11-e8db854/index.js --trust --yolo` |

`node` matches no harness name pattern, so a cursor pane is identified from Cursor's own name or install tree in the path or argv[0].
An unrelated `node` or `agent` matches neither and classifies `other`, which the liveness callers fold into `ambiguous` rather than `dead`.
A live cursor pane returned `alive`; a plain shell pane in the same run returned `dead`.

### Environment markers and detection ordering

Read from the live agent process and from a tool subprocess it spawned:

| Marker | Where observed |
| --- | --- |
| `CURSOR_INVOKED_AS=cursor-agent` | the agent process itself, and its children |
| `CURSOR_AGENT=1` | child/tool processes only |
| `CURSOR_CONVERSATION_ID=<uuid>` | child/tool processes |
| `AGENT_TRANSCRIPTS=<projects-root>/<slug>/agent-transcripts` | child/tool processes |

Cursor does not clear an inherited `CLAUDECODE`, so ordering decides the verdict.
With both markers set, `bin/fm-harness.sh` reports `cursor`; with `CLAUDECODE` alone it still reports `claude`.

### Composer

Cursor's composer is a BARE row whose prompt glyph is `→` (U+2192); there is no border.
Its idle placeholder is `Plan, search, build anything` in a fresh session and `Add a follow-up` after a completed turn.

The styled capture of an idle composer row was:

```
ESC[48;2;21;21;21m ESC[2m→ ESC[0;7mESC[48;2;21;21;21mPESC[0;2mESC[48;2;21;21;21mlan, search, build anythingESC[0m
```

The glyph and the placeholder tail are dim (SGR 2), but the cell under the terminal cursor is reverse video (SGR 0;7).
Reverse video is neither dim nor a dark foreground, so ghost stripping leaves a lone `P` and an idle composer read `pending` before the fix.
After teaching the shared classifier the glyph, both placeholders, and the plain-row remnant rule, the same captures read `empty` on the styled cursorless backends, while real typed text - including text typed to exactly match the placeholder - still read `pending`.
An unstyled capture has no ghost-strip proof and correctly stays `unknown`.

#### tmux composer verdict, corrected 2026-08-13

The 2026-08-11 record that a Cursor pane's tmux composer verdict is `unknown` in every state described the cursor-ANCHORED read, which remains true: `#{cursor_y}` was 25 with `#{cursor_flag}` 0 on an idle pane, pointing below the footer, so tmux's cursor row is not a composer locator for Cursor.
Read cursorlessly, the same live capture classifies correctly, so the composite verdict is no longer `unknown`:

```text
cursor_y=25  cursor_flag=0
with-cursor : unknown      cursorless : empty     (idle composer)
with-cursor : unknown      cursorless : pending   (real typed text, not submitted)
with-cursor : unknown      cursorless : unknown   (agent exited to a shell)
```

`bin/fm-tmux-lib.sh` therefore reclassifies cursorlessly only when the pane's foreground process group is provably Cursor, so every other harness keeps the strict blank-cursor-row posture.
That supplies the genuine composer-empty proof required for away-mode escalation delivery.
A live injection through `bin/fm-supervise-daemon.sh`'s own `inject_msg` into a real Cursor pane returned 0 and the pane processed the typed `FIRSTMATE_OP: v1 away-supervisor:` escalation.

`tests/fm-tmux-agent-liveness.test.sh` pins this with real processes and no Cursor installed: it asserts the cursor-anchored source is blind, that the composite still reads `empty` idle and `pending` with typed text, that an identical screen stays `unknown` when the pane is not Cursor, and that a stale Cursor screen over a dead shell never reads `empty`.

### Busy state

Cursor writes a per-conversation transcript at `<projects-root>/<workspace-slug>/agent-transcripts/<conversation-id>/<conversation-id>.jsonl`.
Each turn is bracketed by a `role:user` open and a typed `{"type":"turn_ended","status":...}` close.
Observed closes: `success` for a completed turn, and `aborted` with `"error":"User aborted/interrupted manually."` after a single Escape.

The trailing close landed 0 seconds after the pane's busy footer cleared on a normal turn.
The transcript does NOT accumulate one close per turn, so a count of closes is not a progress signal; only the trailing record is.
After an interrupt the aborted close was observed within seconds in some runs and not within twenty seconds in others, so `bin/fm-control-lib.sh` deliberately claims no cancellation acknowledgement for cursor.

Binding never reconstructs cursor's workspace-slug directory name, which collapses path separators.
Cursor records the exact absolute workspace path in each project directory's `.workspace-trusted`, and the binding matches on that value.

### Rendered busy token, delivery only

Mid-turn the pane showed a braille spinner plus a verb, and `ctrl+c to stop` on the composer row; both the verb line and that token were absent the instant the turn ended.
The same version rendered `Working` in one turn and `Running` in the next, so the TOKEN is matched and the verb is not.
This row is a delivery guard for submit acknowledgement only; recorded worker state comes from the transcript fold.

### Launch, lifecycle, and skills

| Fact | Observed |
| --- | --- |
| Workspace trust | `--trust` suppressed the prompt; `--yolo` alone did NOT, and the prompt blocks a fresh worktree |
| Autonomy | `--yolo` (alias of `--force`); the footer renders `Run Everything` |
| Worktree | `-w/--worktree` allocates a SECOND worktree under `~/.cursor/worktrees` and is never passed |
| Effort | no effort flag exists; requested effort stays in task metadata |
| Interrupt | single Escape; the pane showed `Cancelled` and the composer returned to its placeholder, so no clear key is needed |
| Exit | `/exit` |
| Skill invocation | `/<skill>`; cursor discovers firstmate's user-level skills, and `/no-mistakes` autocompleted with firstmate's own description and invoked the skill |
| Slash popup | real: the first Enter closes the popup and a SECOND Enter submits, the same hazard as grok, covered by the submit core's retried Enter |

### End-to-end

A throwaway scout was spawned through `bin/fm-spawn.sh --scout --backend tmux` on a real cursor worker and driven to completion:

1. the launch delivered its brief positionally and the agent executed it;
2. `state/<id>.cursor-session` was written with the task worktree;
3. the transcript fold read `busy` mid-turn and `idle` after it;
4. `bin/fm-send.sh` delivered a steer through the then-current typed path and exited 0;
5. `bin/fm-control.sh <id> interrupt` cancelled a running turn;
6. `bin/fm-control.sh <id> exit` stopped the agent;
7. `bin/fm-teardown.sh` refused until the scout's report and decision gate were satisfied, then removed the session record.

### Herdr backend

The tmux run above is the reference; this section is the separate Herdr proof, produced on 2026-08-12 against Herdr 0.8.0 (client and server, protocol 19) and the same signed `cursor-agent` 2026.08.11-e8db854 on macOS 26.5.2 arm64.
Every step ran inside an isolated `fm-lab-` session provisioned by `bin/fm-herdr-lab.sh`, launched from a neutral parent outside any Herdr pane, with the live default session's pane count checked before, during, and after; it stayed at 7 throughout.

**Herdr's native agent state is unusable for Cursor.**
A 60-sample probe of `agent get` across a full turn reported `agent_status=blocked` in every state - idle, mid-turn, and after.
The typed submit path's idle baseline is therefore structurally unreachable for Cursor, and every typed send falls into the composer branch.

| Pane state | Composer verdict | Rendered footer |
| --- | --- | --- |
| Idle | `empty` | no busy token |
| Text typed, not submitted | `pending` | no busy token |
| Mid-turn | `pending` (placeholder plus `ctrl+c to stop` on one row) | `ctrl+c to stop` |

Herdr draws the composer's rules with the half-block glyphs U+2584 and U+2580 rather than the box-drawing family.
Before those were taught to the shared edge detector, a bare composer's wrap region ran through its own closing rule and swallowed the model and path footer, so an idle pane read `pending`.
Measured as an A/B on the same live pane, the pre-fix classifier returned `pending` and the current one returned `empty`.

The idle fix alone did not confirm typed delivery, because the composer branch reads the mid-turn row instead.
With the rendered-footer transition in place, a typed-plane `bin/fm-send.sh` invocation exited 0 and the steer executed in the pane; the same send previously exited 1 with `delivery unconfirmed; verdict=pending` on a message that had actually landed.

The rest of the lifecycle was driven end to end on that worker:

1. `bin/fm-spawn.sh --scout --backend herdr` placed the worker and it executed its brief;
2. the transcript fold read `busy` mid-turn and `idle` after, unchanged from tmux, so the recorded worker state is backend-agnostic;
3. `bin/fm-control.sh <id> interrupt` reported `cancel=unconfirmed` by design and the pane showed `Cancelled`, with the footer and the fold both returning to idle;
4. `bin/fm-control.sh <id> exit` stopped the agent through the slash popup and the pane returned to its shell;
5. `bin/fm-teardown.sh` refused until the scout's report and decision gate were satisfied, then removed the session record and returned the worktree.

Other harnesses on Herdr are unaffected by the edge-detector change.
All seven live panes of the running default session - one Pi, four Claude, two plain shells - classified identically under the pre-fix and current classifiers.

**Typed-submit confirmation is verified on tmux and Herdr only.**
Zellij, cmux, and Orca share a submit core that never consults the busy footer, so a typed-plane Cursor send there lands but `fm-send` reports delivery unconfirmed and exits non-zero; ordinary text steers ride the durable inbox and exit 0 at enqueue.
Teaching that shared core the same transition is deliberately separate work, because it changes the submit path for every harness on those three backends and needs its own live validation on each.

The portable regression is `tests/fm-cursor-harness.test.sh`, the composer captures are pinned in `tests/fm-composer-lib.test.sh`, and the Herdr submit and footer behavior is pinned in `tests/fm-backend-herdr.test.sh`.
Refresh this harness-dependent proof before accepting a cursor upgrade:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

## Pi supervision branch

The supervision-branch extension (`.pi/extensions/fm-branch-supervision.ts`, [docs/pi-supervision-branch.md](../pi-supervision-branch.md)) builds its second session through the Pi SDK surface: `createAgentSession` (including its `model`, `modelRuntime`, and `thinkingLevel` options), `DefaultResourceLoader` with `extensionFactories`, `SessionManager`, `createBashToolDefinition` with a `spawnHook`, `sendCustomMessage` for routine notes, `appendEntry` and `registerEntryRenderer` for captain outcomes, the `before_provider_request` hook, the command context's model registry for picker candidates, a fresh `ModelRuntime` for isolated-branch resolution, and Pi's own `getSupportedThinkingLevels`/`clampThinkingLevel` plus its `getThinkingLevel` and `thinking_level_select` extension surface for effort.
In TUI mode, its `/supervision-model` model list is drawn with Pi's own `SelectList`, `Input`, `fuzzyFilter`, and `DynamicBorder` through the extension context's `ui.custom` surface, which is what bounds and searches a long catalog.

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
In both, the processed marker holds, the same sequence is presented again at the run boundary and after a session replacement, the triggered-turn budget gives way to a next-prompt copy without duplicates, and only `fm_branch_processed` with the presented sequence closes the outcome; a routine outcome never enters the path, and delivered history from before the marker existed is migrated once rather than re-presented.
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

Scope of the earlier evidence: the installed signed `pi` CLI (0.82.0 at verification time) is a compiled binary whose bundled SDK is not importable from Node, so the importable npm package is the only surface the guard and the typecheck can pin.
The extension executes inside the signed CLI's own runtime, so a CLI upgrade can drift ahead of the pinned npm surface; refresh the SDK construction, picker, renderer, and type evidence after every Pi upgrade by rerunning the applicable live guard probes, picker regression, and strict typecheck above (point `FM_PI_PACKAGE_DIR` at a matching npm install when one exists).
The live guard now drives both extensions through the watcher-owned settlement handshake, requires rejected branch settlement before main delivery, and verifies successor-delivery confirmation; rerun it against the matching importable Pi package to refresh end-to-end fallback evidence.

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
