# Verification: the copilot (GitHub Copilot CLI) crewmate/scout adapter

Active empirical facts for firstmate's copilot adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/copilot.md`](../../.agents/skills/harness-adapters/references/harness/copilot.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `GitHub Copilot CLI 1.0.88` (`copilot --version`) |
| Verified | 2026-09-24 |
| Binary | `/Users/manijoshi/.npm-global/bin/copilot`, a `#!/usr/bin/env node` loader shim (symlink to `../lib/node_modules/@github/copilot/npm-loader.js`) that execs a native child (`@github/copilot-darwin-arm64/copilot`) |
| Platform | macOS arm64, Node v24 |
| Backend | tmux, in scratch sessions (`copilot-probe`) outside any firstmate home; no captain fleet state was touched |

Every command below ran inside scratch directories under `/tmp` or the disposable firstmate task worktree.
Model spend for the whole probe series was about 2 AI credits on a Copilot student plan.

## Detection: COPILOT_CLI marker plus structural ancestry

```
$ copilot --version
GitHub Copilot CLI 1.0.88.
```

A live TUI's tool process reported this environment (via a model-executed `env | sort | grep -E 'COPILOT|AGENT'`):

```
AGENT=1
COPILOT_AGENT_SESSION_ID=283ff860-650c-48d5-9c61-e6475f081c7a
COPILOT_CLI_BINARY_VERSION=1.0.88
COPILOT_CLI_RESOLVED_DIST_DIR=/Users/manijoshi/Library/Caches/copilot/pkg/darwin-arm64/1.0.88
COPILOT_CLI=1
COPILOT_LOADER_PID=27640
```

`COPILOT_CLI=1` is copilot's own harness-identity marker and `bin/fm-harness.sh` tests it before `CLAUDECODE`.
`AGENT=1` is present in the launching environment too, so like agy's it is inherited launcher state and is never promoted.
Copilot does NOT scrub an inherited `CLAUDECODE`: a non-interactive probe with `CLAUDECODE=1` exported printed `1` back through the model's shell tool, so the marker ordering above is load-bearing and the spawn clears foreign markers at the launch boundary.
The same pane's processes read:

```
27639 27539 node  node /Users/manijoshi/.npm-global/bin/copilot -i ... --model auto
27640 27639 /Users/manijoshi  /Users/manijoshi/.npm-global/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot -i ... --model auto
```

`comm` is `node` for the loader shim (and `MainThread` on modern Linux Node, the gemini precedent), while the native child's comm truncates to its path prefix on macOS.
`bin/fm-copilot-lib.sh` therefore resolves identity from argv[1] - basename `copilot` or a path under `@github/copilot/` - the same structural shape as `bin/fm-gemini-lib.sh`, and the native child additionally matches the anchored comm arm.
`tests/fm-copilot-harness.test.sh` pins the marker precedence, the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real copilot ancestor once the spawn clears it.

## Launch: -i prompt with auto-submit

```
$ copilot -i "reply with exactly the word PONG and run no tools" --model auto --yolo
```

The brief submitted itself with no extra Enter, the turn ran, and `● PONG` rendered in the pane with the footer `Auto → mai-code-1.1-flash`, proving `--model auto` was accepted and routed (a later run resolved `Auto → gpt-5.6-luna`; auto routing varies per turn).
`copilot --help` (1.0.88) documents `--model <model>` (`use 'auto' to let Copilot pick automatically`) and `--reasoning-effort <level>` (`none, minimal, low, medium, high, xhigh, max`).
There is no `copilot models` subcommand, so a requested model id passes through unvalidated, the gemini/cursor shape rather than agy's validated catalog.

## Trust dialog: env bypass on the launch, gate as the backstop

A first launch in a fresh directory stops on this dialog:

```
Confirm folder trust
...
/private/tmp/copilot-probe
...
Copilot can read files in this folder and, with your permission, edit them or run code and shell commands. It will remember your permissions for the rest of this session.

Do you trust the files in this folder?

❯ 1. Yes
  2. Yes, and remember this folder for future sessions
  3. No (Esc)
```

The cursor sits on the safe `1. Yes`, so a single Enter answers it (verified live).
An identical launch with `--yolo` and no trust control still parked on the dialog, so `--yolo` is autonomy only, not trust.
`COPILOT_ALLOW_ALL=true` (exactly `true`) trusts the working directory for the run without prompting - a fresh-directory launch with the env prefix never rendered the dialog and its `-i` turn ran - so the spawn carries it as an env prefix on every copilot launch, the gemini shape: per-session, with no growing global record of disposable worktree paths.
Trusting the workspace loads that directory's skills, plugins, MCP servers, and hooks, the same posture the other adapters already run under in a task worktree.
The post-launch gate (`copilot_wait_for_working`) is the backstop: it answers a dialog that renders anyway exactly once, then requires the session-events fold to read busy before the spawn reports success, and fails the spawn with endpoint cleanup when the brief cannot be confirmed to run in the worktree.

## Autonomy: --yolo

Without `--yolo` (env trust only) every shell command parks on a `Do you want to run this command?` approval dialog (`1. Yes` / `2. Yes, and don't ask again for ...` / `3. No, ...`), verified live on an `env | sort` probe.
`--yolo` is documented as `--allow-all-tools --allow-all-paths --allow-all-urls`; `sleep 25/60/120` shell tools ran with no approval under the combined launch, so the spawn passes `--yolo` on every copilot launch, the muse shape.

## Credential binding: login account, not a copied store

The verifying host authenticates through `copilot login` (user `Mani212005` in `~/.copilot/config.json`).
Two cheaper credential paths were tried for the isolated live guard and both failed live, so neither is used:
a whole-`~/.copilot` copy under a throwaway `HOME` still parked on `Please use /login to sign in to use Copilot`, and `COPILOT_GITHUB_TOKEN` holding the `gh auth token` value is refused outright (`Classic Personal Access Tokens (ghp_) are not supported ... will be ignored`).
The opt-in live guard therefore runs under the operator's own HOME against fresh temp workspaces, with session-only trust answers and its own session history as its only footprint; an unauthenticated run fails loudly at the reply poll, which names the `/login` screen when that is the cause.

## Model and effort

`--model auto` is the allowance-constrained selection: the verifying account holds a Copilot student plan, which only allows the `auto` model.
The adapter passes any requested `--model` straight through (`--model %s`, like every other adapter); dispatch owns selecting `auto`.
`--reasoning-effort` maps the shared vocabulary straight across (`low|medium|high|xhigh|max`, with `max` only ever as an explicit captain choice, never as a fallback); `none|minimal` sit below the shared vocabulary and stay unreachable, the muse shape.
Non-default effort values were verified at the flag-mapping level (help text plus portable spawn-template tests); a live non-default-effort turn was not exercised.

## Busy state: the session event log, unknown on absence

Every session persists `events.jsonl` plus `workspace.yaml` (carrying `cwd:`) under `$COPILOT_HOME/session-state/<uuid>/`, appended live - `tool.execution_start` was observed mid-turn.
One turn brackets as:

```
session.start, session.model_change, session.auto_mode_resolved,
user.message, system.message, hook.start,
model.turn_started, model.model_call_started, ..., model.turn_ended, ...,
hook.end,
assistant.turn_start, assistant.message, assistant.turn_end,
session.usage_checkpoint
```

A tool turn adds `assistant.turn_start, assistant.message, tool.execution_start, tool.execution_complete, assistant.turn_end`, then a second `assistant.turn_start, assistant.message (<reply>), assistant.turn_end` pair carries the final answer.
The fold (`fm_busy_copilot_turn_state`) is last-boundary-wins: `user.message`, `model.turn_started`, and `assistant.turn_start` open while `assistant.turn_end`, `abort`, and `session.shutdown` close, and everything else is skipped, so a model-call gap between `model.turn_ended` and the following `assistant.turn_start` still reads busy through the earlier opener.
Assistant boundaries can lag the visible turn: two single-reply sessions showed the reply rendered with `assistant.turn_end` still unflushed half a minute later, one converging through a later flush and one only at `session.shutdown`.
A trailing open after a rendered reply therefore stays busy until the flush lands; the lag runs only in the safe direction, never idle-while-working, and the opt-in live guard polls for the convergence rather than asserting it once.
Mid-turn the pane rendered the status row:

```
◎ Working · 113 B esc interrupt                                        Auto → mai-code-1.1-flash
```

and after the 30s foreground-tool auto-background (see below):

```
◎ Waiting for background shells · 120 B esc interrupt                  Auto → mai-code-1.1-flash
```

The completed turn showed the reply, then the idle composer with the plain footer (`<- open sidebar · / commands · ? help · tab next tab`).
The rendered rows are deliberately NOT state sources: the `Working` word is ordinary prose a worker could echo, and `Waiting for background shells` can linger past turn end, so both stay delivery-guard signals only (`esc interrupt` token, `bin/fm-composer-lib.sh`).
`fm_busy_classify` reports `unknown copilot-session-log` with no sidecar, no matching session, or an unreadable or boundary-free log, and the spawn writes the binding sidecar (`state/<id>.copilot-session`) with pre-existing sessions excluded, the muse/cursor shape.
Nothing is armed and no record is seeded, because no writer could ever clear one.

## Interrupt and exit

A single `Ctrl+C` sent into a running `sleep 120` tool turn recorded `abort {'reason': 'user_initiated'}` in the session events, closed the turn, reaped the tool process, and left the composer on the empty `❯` row with no repolluted text.
Single and double `Escape` showed no verifiable effect on a running model or tool turn across three live trials, despite the footer's `esc interrupt` label, so `bin/fm-control-lib.sh` records `C-c` once, no clear key, no ack source for copilot, the grok precedent for the key.
Sending `/exit` plus the composer submit exited the process; the pane returned to its shell.
The 30s foreground-tool auto-background is copilot behavior worth knowing beside the interrupt: a shell tool still running after 30s backgrounds itself (`command with shellId N is still running after 30 seconds...`), the turn continues past it, and the status row switches to `Waiting for background shells` until it is reaped - it is not an interrupt and needs no control-plane action.

## Composer settle race

Typed text followed by an immediate Enter does not submit: the text sits in the composer until a later Enter arrives (reproduced deterministically: two trials, both needed the second Enter).
A 4s settle between typing and a single Enter submitted on the first press (`ZEBRA` turn ran), and a lone Enter into an empty composer is a harmless no-op, so the tmux submit core's type-once-then-retry-Enter shape covers it with no copilot-specific tuning - the two manual trials are exactly that shape by hand.
The `-i` launch brief is unaffected: it auto-submits inside the CLI, never through the composer.
Skill submission (`/skills` opened the skills browser) shares the race and the same cover.

## Backend liveness: tmux names it, Herdr shares the classifier

The tmux adapter classifies the anchored process name `copilot` as `agent` through the shared name vocabulary in `bin/fm-agent-process-lib.sh`, the agy/devin precedent for short bare-word names, and reaches the node loader shim through the structural argv rules in `bin/fm-copilot-lib.sh` on both the `/proc` pid path and the flattened-args fallback.
Herdr's registry already tracks copilot as a known integration, and Herdr pane classification shares `fm_agent_process_classify`, so both backends mean the same thing by a copilot process.
copilot stays out of the session-lock name vocabulary in `bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent.

## Skills

`copilot skill --help` (no model cost) documents discovery from project (`.github/skills/`, `.agents/skills/`, `.claude/skills/`), personal (`~/.copilot/skills/`, `~/.agents/skills/`), plugin, and custom directories.
`~/.agents/skills/no-mistakes` exists on the verifying machine, so a copilot worker discovers `/no-mistakes` as a personal skill, which is what keeps firstmate's delivery path available; workspace skills need the workspace trust the launch already grants.
The `/skills` browser rendered live (user-source skills listed), proving the `/<skill>` submission form subject to the composer race above.
A worker-executed `/no-mistakes` run was not exercised here; the delivery pipeline owns that proof.

## Supervised task: launch, trust, steer, interrupt, and exit through the new path

The opt-in live guard `tests/fm-copilot-signals-live-e2e.test.sh` exercises the real CLI end to end on an isolated tmux server against fresh temp workspaces (about 2 AI credits per run on the student plan, 2026-09-24).
A fresh workspace parked on `Confirm folder trust` and one Enter on the preselected `1. Yes` started the `-i` turn, which rendered the computed `80235` reply.
A second fresh workspace launched with `COPILOT_ALLOW_ALL=true` never rendered the dialog and rendered its `BYPASS_OK` reply; its session directory recorded the lab workspace and the fold converged from open to settled.
A steered `sleep 60` prompt submitted through the composer race (settle plus busy-row proof) started its turn, folded busy mid-turn, and a single `Ctrl+C` recorded the abort and folded settled.
`/exit` stopped the agent and returned the pane to its shell.
Refresh with `FM_COPILOT_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh`.

## What is still unproven

The unauthenticated failure mode was never observed; this host's copilot runs signed in, so any auth prompt is a fail-loud credential blocker, not a handled dialog.
A live non-default effort turn (`--reasoning-effort` other than the default) was never exercised; only the flag mapping is verified.
`--resume` / `--continue` pane resume was never exercised; recovery uses deterministic relaunch from the brief on disk.
A worker-executed `/no-mistakes` skill run was never exercised; discovery and the submission form are verified, the pipeline run is not.
No primary or secondmate behavior was built or tested, and none is claimed.

## Refreshing this record

Run the portable suite and the live guard after any copilot upgrade, because the process shape, marker set, trust dialog text, event log schema, and rendered busy/interrupt text are all vendor-controlled surfaces that the spawn gate and the busy fold match:

```
bin/fm-test-run.sh tests/fm-copilot-harness.test.sh
FM_COPILOT_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh
```
