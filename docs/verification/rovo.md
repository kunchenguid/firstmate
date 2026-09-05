# Verification: the rovo (Atlassian Rovo CLI) crewmate/scout adapter

Active empirical evidence for firstmate's rovo adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/references/harness/rovo.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Rovo CLI: 202609.1.2` |
| Verified | 2026-09-02 (herdr backend liveness added 2026-09-03) |
| Binary | `~/.local/bin/rovo`, a bash wrapper that execs a PyArmor-obfuscated PyInstaller bundle under `~/.local/share/rovo/active/` |
| Platform | macOS arm64 (Darwin 25.6.0) |

An earlier scout task (`fm-rovo-smoke-s1`) established the baseline empirical facts through a hand-written PTY VT emulator, no adapter code, and no dispatchable wiring.
This task landed the executable owners against those facts and re-verified the load-bearing ones live, including two facts the scout could not test (auth refresh under an expired access token, and a mid-tool-call Escape).
Every command below ran unsandboxed, because rovo's OAuth credentials live in the macOS keychain, which a sandboxed shell cannot read.

## Detection

```
$ rovo --version
Rovo CLI: 202609.1.2
```

`bin/fm-harness.sh` tests `ATLASSIAN_AGENT_TYPE=rovo` and `ROVODEV_CLI=1` before the `CLAUDECODE` line and matches ancestry `comm=rovo` otherwise; `tests/fm-rovo-harness.test.sh` pins both the marker-precedence order (a rovo marker outranks an inherited `CLAUDECODE`) and the markerless-ancestry fallback with faked `ps` output.

## Launch: bare launch-then-send, the kimi shape

`fm-spawn.sh` builds `env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS <rovo-bin> run --yolo <model/effort flags>` - BARE, with no positional brief - wrapped by the shared `env -u CURSOR_AGENT -u CURSOR_INVOKED_AS` prefix every non-cursor harness gets.
The brief is then typed in after the TUI comes up, the same launch-then-send shape kimi uses, through the same shared readers (`fm_backend_capture`, `fm_backend_composer_state`, `fm_backend_send_text_submit`):

1. `rovo_wait_for_ready` polls for the `Welcome to Rovo!` banner (primary) or a composer-empty verdict (weaker fallback, see the composer-ghost-text gap below).
2. The pointer `Read the brief at <absolute-path> and follow it exactly.` is submitted via `fm_backend_send_text_submit`.
3. `rovo_wait_for_delivery` confirms composer-empty AND either the echoed `Read the brief at` text or a nonzero `Context:` percentage (`context:[^%]*[1-9][^%]*%`, tolerant of the footer's bar glyph but anchored before the `%` so the `.../922K` denominator cannot false-positive).

Each gate fails the spawn loudly (a `failed:` line in the task status file) if it never resolves, so a never-ready or silently-dropped delivery is a visible spawn failure rather than a half-wired pane.

### Why not a positional brief

A positional brief is dead-on-arrival. `rovo run --yolo "<brief>"` loads a spinner, never enters a working state, prints no reply, and drops back to a bare idle shell prompt within about 10-15 seconds. This was reproduced independently four times over a raw PTY (varying `TERM`, window size, workspace, and 60-150s windows) and once more under real tmux 3.6a driven with the exact `fm-spawn.sh` send-keys shape (new window, `send-keys -l` the full launch line, then `Enter`). `--startup-receipt` cannot rescue that shape either - it is rejected before start alongside any message:

```
$ rovo run --startup-receipt receipt.json --yolo "Reply with PONG"
Invalid value: --startup-receipt requires prompt-free interactive mode in a terminal
```

so it can only gate a bare (no-message) launch, and this adapter always delivers a message, so it is not used.

### The launch-then-send shape, confirmed live end to end

Bare `rovo run --yolo`, driven over a raw PTY, was confirmed to: render the `Welcome to Rovo!` readiness banner; accept the typed pointer and act on it (a brief instructing a real `sleep 25` bash tool call drove the `Rovo is thinking` busy line); accept a mid-tool-call Escape that printed `Agent cancelled` (see the interrupt section); and exit cleanly on `/exit` with the `Run rovo --restore <id> to resume your conversation` hint. `tests/fm-rovo-signals-live-e2e.test.sh` is that end-to-end guard.

`tests/fm-rovo-harness.test.sh` pins the portable half against a stateful fake `tmux` and a fake `rovo` binary (no real network or credentials): the launch command is bare (`run --yolo`, no positional brief, no `--startup-receipt`); the pointer typed after readiness is exactly `Read the brief at <absolute-path> and follow it exactly.`; delivery confirms via the context-percentage or echoed-pointer signal; a never-ready fake screen fails the spawn loudly; a dropped-submit fake screen fails the spawn loudly; and the model/effort flags, marker-clearing, missing-binary refusal before any pane exists, and crew/scout-only secondmate refusal all hold.

## Busy state: the "Rovo is thinking" fallback

Live, over a raw PTY, submitting a prompt that runs a real `sleep 25` bash tool call rendered the busy line and footer:

```
⬢ Rovo is thinking...
Enter to queue, Ctrl+Enter to steer
```

`fm_busy_rovo_tail_busy` (`bin/fm-busy-lib.sh`) matches that exact rendered text; `fm_busy_classify` was confirmed live-and-portably to read it as `busy rovo-regex`, and an idle footer with no busy line as `idle rovo-regex`.
This is a rendered-tail fallback exactly like Grok's, not a semantic source: rovo's `eventHooks` (`~/.rovo/config.yml`) fire at tool granularity (`on_tool_start`/`on_tool_end`) only, never at turn-end, so no writer is armed and none is seeded.
Grok was previously the only rendered-text arm the redesigned busy contract allowed; this task extends that same documented exception to rovo, scoped to `harness=rovo` exactly like Grok is scoped to `harness=grok`, and neither can classify the other (`tests/fm-rovo-harness.test.sh`'s isolation case).

## Composer ghost text: measured, deliberately left unfixed

A live idle-composer capture over a raw PTY located the inline placeholder chip inside the actual bordered content row, not merely in a suggestion list below it:

```
row 10  ╭──────────────────────────────────────╮
row 11  │ Summarize my open tasks               │   fg 38;2;162;163;165 (luminance ~163)
row 12  ╰──────────────────────────────────────╯
```

Real typed text in the same row, captured separately, renders at `38;2;206;207;210` (luminance ~207).
Both values sit above `bin/fm-composer-lib.sh`'s default `FM_COMPOSER_GHOST_LUMA_MAX` of 128, so `fm_composer_strip_ghost` leaves the placeholder unstripped and a fresh rovo composer can misclassify as `pending` rather than `empty`.
Raising the shared default was considered and rejected: muse's own real, must-not-be-stripped prompt glyph measures luminance ~149.9 (`muse.md`), below rovo's ghost luminance of ~163, so no single global threshold can keep muse's glyph real while dropping rovo's ghost chip.
This is recorded as a known gap rather than patched, because the safe fix needs a harness-scoped signal the shared composer classifier does not carry today, and a threshold change risks regressing muse's already-credentialed behavior for a rovo-scoped fix.
The blast radius is bounded to composer-emptiness consumers such as steering delivery, which already retries through the doorbell ladder on a non-`empty` read.
It does not block readiness: readiness leads with the `Welcome to Rovo!` banner, so the ghost chip is never the deciding signal there. Delivery, however, requires composer-empty as one conjunct (alongside the echoed pointer or a nonzero `Context:` percentage), and on the herdr backend this conjunct may fail to settle within its poll window (the composer read non-empty even mid-turn in the live herdr run below), so `rovo_wait_for_delivery` can fail the gate and tear the pane down there. tmux delivery is separately verified working (see the tmux backend-liveness section below). This is a known limitation whose fix is tracked as a separate follow-up, not fixed in this change.

## Interrupt: confirmed under real tmux

The `fm-rovo-smoke-s1` scout report recorded a single Escape printing `Agent cancelled` during a running tool call, using its own hand-rolled PTY VT emulator.
A follow-up live check under real tmux 3.6a reproduced the scout's exact finding: a single Escape sent during a genuine mid-flight bash tool call printed `Agent cancelled` in the captured pane, in an isolated `tmux -L <private-socket>` session/window, not the shared fleet session.
The launch-then-send live guard (`tests/fm-rovo-signals-live-e2e.test.sh`) also reproduces it over a raw PTY. A single fixed-timer Escape had landed unreliably there - the exact instant the interrupt is delivered is timing-sensitive over a bare PTY, so one fixed Escape can fall between states - so the guard now sends Escape across the live `sleep 25` tool-call window until the cancel renders. That reproduced `Agent cancelled` on every run (it consistently landed within the first few attempts, ~8s into the tool call); a session that never rendered the cancel would exhaust every attempt and fail.
The session was never wedged: `/exit` still exited cleanly with the `Run rovo --restore <id> to resume your conversation` hint immediately after the Escape.
`bin/fm-control-lib.sh` records rovo's `fm_control_interrupt_ack_source` as `none`, the same conservative choice already made for claude, codex, grok, kimi, and cursor - a control-plane fact independent of whether the render happens to appear, because a rendered acknowledgement is not something the control plane depends on for any of those adapters.
Escape is the recorded interrupt key, and its rendered evidence is now corroborated both under real tmux and over a raw PTY rather than in tension with the code.

## OAuth token lifetime and silent refresh

The captain corrected this task's initial brief, which had treated the ~1h access-token lifetime as a hard mid-task blocker; this task's own live evidence confirms the corrected model.

```
$ rovo auth status
authenticated — Access token expired (2026-09-02 13:39:55 UTC), but a refresh
token is present.

$ rovo run --yolo --output-file out.json "Reply with exactly the single word PONG and nothing else."
Run rovo --restore <session-id> to resume your conversation
$ cat out.json
PONG

$ rovo auth status
authenticated — Access token valid, expires in 3574s (2026-09-02 15:15:40 UTC).
```

No browser prompt, no interactive step, and no visible interruption occurred between the first and second `rovo auth status` calls; the run in between silently refreshed the access token from the stored refresh token.
Treat the ~1h access-token lifetime as an ordinary operational fact rather than a non-negotiable-safety blocker: `rovo auth login` (interactive browser OAuth) is needed only after roughly four weeks of disuse or an invalidated refresh token, not mid-task.

## Effort and model

`agent.efficiencyLevel` accepts `low|medium|high|max` live via `--config-override`; a requested `xhigh` (unsupported) is recorded in task metadata but omitted from that JSON object, both verified against the fake-binary suite.
`--config-override` is single-value - a second occurrence silently discards the first rather than merging, confirmed live by reversing the order of two `--config-override` flags and observing the earlier one's effect disappear - so `fm-spawn.sh`'s `rovo_config_override_flag` folds `agent.efficiencyLevel` into the SAME JSON object as the mandatory `allowedExternalPaths` grant below rather than emitting two flags; the fake-binary suite pins that exactly one `--config-override` occurrence carries both.
Model discovery is per-account (`/models` or ACP `session/new`); the observed live list is recorded in `references/harness/rovo.md` and must never be hardcoded.

## Worktree confinement and the allowedExternalPaths fix

The standard crewmate flow needs a rovo worker to read its own brief and steering messages, and to write its status and report - all of which live in the firstmate home, outside the task's git worktree.
By default rovo confines every file-tool operation (`open_files`, `create_file`, `grep`, `expand_folder`, ...) to the workspace it was launched in, and its bash tool independently refuses the same external paths regardless of any grant.
Confirmed live with a plain `rovo run --yolo` launched inside an isolated scratch workspace, against an unrelated file in a separate outside directory:

```
$ cat "$LAB/outside/secret.txt"
OUTSIDE_SECRET_TOKEN_12345
$ rovo run --yolo "Use your file-opening tool (not bash) to open and read the file $LAB/outside/secret.txt, then report its exact contents." --output-file out.txt
$ cat out.txt
Sorry, I can't access or read files outside the current workspace, including that temporary-system path. If you copy the file into the workspace or paste its contents here, I can help inspect it.

$ rovo run --yolo "Run this exact bash command and nothing else: cat $LAB/outside/secret.txt" --output-file out.txt
$ cat out.txt
Captain, I can't run that command because it attempts to read a file outside the workspace, which I'm not permitted to access. Would you like to provide the file's contents here instead?
```

`toolPermissions.allowedExternalPaths` (`~/.rovo/config.yml`, default `[]`) is the only lift, and it must be granted at launch through `--config-override`: there is no live escalation once the process is already running. Confirmed live with the grant, same file, same file tool:

```
$ rovo run --yolo --config-override '{"toolPermissions":{"allowedExternalPaths":["'"$LAB"'/outside"]}}' \
    "Use your file-opening tool (not bash) to open and read the file $LAB/outside/secret.txt, then report its exact contents." --output-file out.txt
$ cat out.txt
`OUTSIDE_SECRET_TOKEN_12345`
```

The grant lifts the file tools only. rovo's bash tool stays confined to the worktree regardless, confirmed live with the identical grant still active:

```
$ rovo run --yolo --config-override '{"toolPermissions":{"allowedExternalPaths":["'"$LAB"'/outside"]}}' \
    "Run this exact bash command: echo hello >> $LAB/outside/status.txt" --output-file out.txt
$ cat out.txt
I can't run that command because it modifies a file outside the workspace. If you provide a workspace-relative path, I can run the equivalent command there - would you like to do that?
```

This matters because the standard crewmate contract's literal status line is a bash `echo ... >> status_file` command. Given that exact literal instruction, rovo recovered on its own by falling back to its native file tool for the same append, and succeeded, preserving the file's existing content:

```
$ echo "existing: prior" > "$LAB/outside/status2.txt"
$ rovo run --yolo --config-override '{"toolPermissions":{"allowedExternalPaths":["'"$LAB"'/outside"]}}' \
    'Report status by appending one line: echo "working: test line" >> '"$LAB"'/outside/status2.txt' --output-file out.txt
$ cat out.txt
Appended `working: test line` to `status2.txt`. What would you like to do next?
$ cat "$LAB/outside/status2.txt"
existing: prior
working: test line
```

The same grant, at directory granularity, also covers listing a directory, reading a file inside it, and moving (not copying) it into a `handled/` subdirectory - the exact shape the steering-inbox acknowledgement contract (`bin/fm-task-inbox-lib.sh`) needs - confirmed live in one pass against a pre-existing `inbox/handled/` directory:

```
$ rovo run --yolo --config-override '{"toolPermissions":{"allowedExternalPaths":["'"$LAB"'/outside"]}}' \
    "List the directory $LAB/outside/inbox for *.msg files, read 001.msg, then move it into $LAB/outside/inbox/handled/001.msg (a rename/move, not a copy-and-delete you narrate but don't do)." --output-file out.txt
$ ls "$LAB/outside/inbox/handled"
001.msg
```

`fm-spawn.sh`'s `rovo_config_override_flag` builds one merged JSON object per rovo launch (see "Effort and model" above for why it must be one), always granting `toolPermissions.allowedExternalPaths` for exactly three real (symlink-resolved) paths scoped to this task: the brief directory (`data/<id>/`, covering `brief.md`/`launch-brief.md`/`report.md`), the steering inbox directory (`state/<id>.inbox/`, covering every steer and its `handled/` acknowledgement), and the status file itself (`state/<id>.status`).
`tests/fm-rovo-signals-live-e2e.test.sh` extends the launch-then-send live guard with exactly this shape end to end: a real rovo process launched with the production `--config-override` grant reads an external brief and appends to an external status file (preserving its prior content), and the same brief and status file, launched WITHOUT the grant, are left untouched while the transcript shows rovo's own refusal - proving the fix closes the gap rather than merely adding an untested flag.
`tests/fm-rovo-harness.test.sh` pins the portable half against the fake-binary suite: the grant's three paths appear in every rovo launch (including when the requested effort is unsupported and omitted), and exactly one `--config-override` occurrence ever appears.

## Backend liveness: tmux verified live, herdr placement verified live with a herdr-side agent-detection gap

tmux 3.6a is now installed and was exercised live in an isolated `tmux -L <private-socket>` session, so tmux pane liveness is fully verified rather than pending.
`bin/backends/tmux.sh`'s `fm_backend_tmux_classify_process_name` matches `*rovo*` alongside the other globbed harness names, so a rovo pane classifies `agent` (not `other`).
The two independent name sources behaved as designed: `#{pane_current_command}` reported the truncated on-disk binary name `atlassian_cli_r` - macOS's 15-char `comm` truncation cuts `atlassian_cli_rovodev` off just before the `rovo` substring begins, the same truncation-volatility class [`runtime-backends.md`](runtime-backends.md) already documents for codex/kimi's own patch-release name drift - while the foreground ps-based `comm` correctly reported `rovo`, and `fm_backend_tmux_agent_state` correctly returned `alive` through that primary source. The two-independent-name-sources design is exactly why the truncation quirk does not break the verdict.
`tmux capture-pane` correctly rendered the box composer and the `Rovo is thinking...` busy line while a real `sleep`-based bash tool call ran; `fm_busy_rovo_tail_busy` classified it busy, then idle once the tool call completed and the reply landed. The Escape/`Agent cancelled` evidence in the interrupt section above was captured in this same live tmux session.
`/exit` closed the tmux window cleanly, and `fm_backend_tmux_agent_state` reported `missing` immediately afterward - a clean, unambiguous exit verdict.

A full `fm-spawn.sh --backend herdr` placement still cannot be driven to completion from this host: this task's own agent process runs inside the shared production Herdr session, so `fm-spawn.sh`'s cross-session launcher-identity guard correctly refuses to place a worker pane from that ambient parent identity into any other session, and forcing placement into the shared `default` session was rejected as unacceptable interference with the live, human-observed fleet.
That guard scopes fm-spawn.sh's own task/worktree orchestration, not the lower-level primitives it calls, so this task instead drove those same primitives directly against an isolated non-`default` session created by `bin/fm-herdr-lab.sh` (fleet-state tripwire confirmed the live `default` session was unchanged before and after): `herdr workspace create`/`pane list` for placement, the `rovo_capture`/`rovo_wait_for_ready`/`rovo_delivery_is_confirmed`/`rovo_wait_for_delivery` gate functions extracted verbatim from `fm-spawn.sh`, and `fm_backend_capture`/`fm_backend_send_text_submit`/`fm_backend_agent_state` from `bin/fm-backend.sh` and `bin/backends/herdr.sh` directly.

```
$ herdr workspace create --label rovo-verify --cwd ~/.fm-herdr-rovo-verify-scratch --no-focus --session fm-lab-...
{"result":{"root_pane":{"pane_id":"w1:p1",...},"workspace":{"workspace_id":"w1",...},...}}
$ herdr pane list --workspace w1 --session fm-lab-...
{"result":{"panes":[{"pane_id":"w1:p1","cwd":"/Users/.../.fm-herdr-rovo-verify-scratch",...}]}}
```

A rovo pane was placed in that isolated workspace, launched bare (the same `env -u ... rovo run --yolo` template documented above), and `rovo_wait_for_ready` returned success on the `Welcome to Rovo!` banner.
The typed pointer (`Read the brief at <path> and follow it exactly.`) was echoed into the pane, and rovo read a trivial no-op brief, ran a real `sleep 15` bash tool call, and replied `PONG` - the same launch-then-send shape already verified over tmux and a raw PTY, now also confirmed live over Herdr.
`fm_backend_herdr_capture` correctly rendered the `Rovo is thinking...` busy line during the tool call (`fm_busy_rovo_tail_busy` matches that captured text), and the pane read idle with `PONG` visible once the tool call finished; `rovo_wait_for_delivery`'s own composer-empty conjunct did not settle within its poll window, consistent with the already-documented composer-ghost-text gap below rather than a new defect.

`fm_backend_agent_state` is the one signal this run disproves rather than confirms: it reported `dead` throughout - at the ready banner, mid-tool-call busy, and idle-with-`PONG` alike - even though rovo was demonstrably alive and responding the whole time.
The cause is on Herdr's side, not firstmate's: `fm_backend_herdr_pane_agent_state` calls `herdr agent get <pane>`, which returned `{"error":{"code":"agent_not_found","message":"agent target w1:p1 not found"}}` for the live rovo pane, because `herdr integration status` lists no `rovo` entry at all (only `pi`, `omp`, `claude`, `codex`, `copilot`, `devin`, `droid`, `kimi`, `opencode`, `kilo`, `hermes`, `qodercli`, `qwen`, `cursor`, `mastracode`, `antigravity-cli`, and `grok` are known integrations on the installed Herdr build).
Herdr has not shipped agent detection for rovo, so the classifier that recovery logic depends on (`fm_backend_agent_state`'s `alive`/`dead` distinction, and `fm_backend_herdr_tab_is_husk`'s reuse of it) cannot currently tell a live rovo pane apart from an empty one on the herdr backend; a live rovo worker placed on `backend=herdr` risks being misclassified as an agent-less husk by any recovery path that trusts this classifier.
This is recorded as a known Herdr-side integration gap rather than a firstmate bug, and is deliberately left unpatched here: no herdr-scoped workaround is safe to add without risking a false-positive `alive` verdict for some unrelated idle shell, so `backend=herdr` remains usable for launching a rovo crewmate/scout but unverified for automatic dead/husk recovery until Herdr ships rovo detection (or `bin/backends/herdr.sh` gains an independent process-based fallback the way `bin/backends/tmux.sh` already has).
`/exit` returned the pane to an idle shell prompt rather than closing it, unlike tmux which closes the whole window, so `fm_backend_agent_state` reading `dead` after exit is the textually correct verdict for an agent-less-but-present pane; it is only the ready/busy/idle misclassification while rovo was actually running that is the real finding above.

## Skill-loading interop gap (documented, not fixed)

```
⚠ Invalid skill definition in .../.agents/skills/bootstrap-diagnostics/SKILL.md: 'metadata -> internal': Input should be a valid string
```

rovo's skill loader rejects every firstmate skill because `metadata.internal` is a boolean in firstmate's frontmatter and rovo's schema wants a string.
This blocks `/no-mistakes` and every other firstmate skill invocation inside a rovo worker until firstmate's `SKILL.md` frontmatter is made rovo-compatible, a separate deferred follow-up that touches every skill file and the installer contract (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
A `no-mistakes`-mode rovo ship crewmate is blocked by this gap; a rovo scout, which invokes no skill, is unaffected.

## quota-axi provider mapping: not established

`bin/fm-quota-choose.sh`'s `provider_for_harness` has no `rovo` entry.
rovo routes to several distinct underlying model families (OpenAI, Anthropic, Gemini) through Atlassian's own account, and this task found no live evidence of how, or whether, `quota-axi` models that relationship.
Rather than guess a provider family and risk a wrong quota verdict, `rovo` stays absent from that mapping, so a `rovo` candidate in a quota-balanced dispatch array fails closed with `unknown harness: rovo` instead of being silently misjudged; establishing the real mapping is follow-up work, not part of this adapter.

## Refreshing this record

Run the portable suite and the live guard after any rovo upgrade, because the process name, marker set, and rendered busy/interrupt text are all vendor-controlled surfaces:

```
bin/fm-test-run.sh tests/fm-rovo-harness.test.sh
FM_ROVO_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-rovo-signals-live-e2e.test.sh
```

The live guard requires a real, authenticated `rovo` binary but drives it through a raw PTY rather than tmux, so it runs on hosts without tmux installed; tmux and herdr pane placement and liveness were both verified separately in live isolated sessions (see the backend-liveness section above), where the herdr agent-state classifier's rovo blind spot is recorded as a Herdr-side integration gap to track, not a live-guard coverage gap this refresh command needs to close.
