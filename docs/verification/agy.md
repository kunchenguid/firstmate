# Verification: the agy (Antigravity CLI) crewmate/scout adapter

Active empirical facts for firstmate's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0` |
| Verified | 2026-09-10 |
| Binary | `/home/andpod/.local/bin/agy`, an ELF 64-bit Go-compiled single executable |
| Platform | Linux x64 (Arch, kernel 7.2.3) |
| Backend | Herdr, in an isolated non-`default` lab session (`fm-lab-firstmate-agy-ad-*` via `bin/fm-herdr-lab.sh`); the live `default` session was unchanged throughout |

Every command below ran inside the disposable firstmate task worktree or the named Herdr lab session.
No captain fleet state was touched.

## Detection: ancestry only, no marker

```
$ agy --version
1.2.0
```

A live TUI's `/proc/<pid>/environ` carries no `AGY_*` or `ANTIGRAVITY_*` variable.
It does carry `AGENT=1` and `CLAUDECODE=1`, both inherited from the launching environment, so neither is an agy identity and neither is promoted to a marker.
Herdr's `pane process-info` for the same pane reports the foreground process as `name=agy` with `argv=["agy", ...]`, and `ps -o comm=` reports `agy`.
`bin/fm-harness.sh` therefore matches the anchored process name `agy` alone, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` at the launch boundary.
`tests/fm-agy-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `agy` ancestor once the spawn clears it.

## Launch: positional prompt-interactive with auto-submit

```
$ agy --prompt-interactive "Reply with exactly AGY_LIVE_PROBE_OK and nothing else" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions
```

The brief submitted itself with no extra Enter, the turn ran, and the reply rendered in the pane.
A second launch into the same directory answered a fresh prompt the same way, so the shape is repeatable, not a first-run accident.
The footer rendered `Gemini 3.8 Flash · low`, proving both flags were accepted together.

## Trust dialog: answered by the spawn, then gated on a busy turn

A first launch in a fresh worktree shows this dialog:

```
Accessing workspace:

/home/andpod/.treehouse/firstmate-7bab20/1/firstmate/agy-probe-tmp

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```
`agy --help` (1.2.0) lists no trust flag, pre-registration command, or add-dir style grant, so there is no pre-launch way to suppress it, and firstmate does not pre-write the captain's settings file.
Two supervised Herdr runs in treehouse worktrees completed file-writing turns while the dialog was still unanswered at observation time (worker file and `done:` status line both verified on disk before Enter was ever sent to those panes).
Isolated runs in untrusted `/tmp` directories never reached the workspace until Enter: the turn spun through exploratory tool calls in agy's own scratch directory instead, and only the queued prompt ran after the answer.
One run left unanswered for several minutes wrote its file to agy's scratch directory instead of the workspace once finally answered.
The mechanism behind the difference was not established; path, backend, and latency were all varied across runs without isolating a single cause.
The spawn therefore does not depend on it: `bin/fm-spawn.sh` runs a post-launch readiness gate (`agy_wait_for_working`) in the rovo/kimi launch-then-confirm shape.
It polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the contents of this project?` text renders, and reports success only once `fm_busy_classify` returns a busy verdict for the pane (Herdr's native `working` status or the pinned `esc to cancel` status row).
When neither the dialog nor a busy turn appears within the window, or the answered dialog never turns busy, the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
A reused path shows no dialog and passes the gate on the busy verdict alone with no extra Enter.
Answering appended the worktree to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, which firstmate never writes.
`tests/fm-agy-harness.test.sh` drives a fake pane through launch, dialog, and busy row, pinning the single Enter, the busy-before-success order, the no-dialog reused path, and the fail-and-close path.

## Model and effort

```
$ agy models
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
...
```

`agy --help` documents `--effort` as `low|medium|high` and `--model` as the model for the session.
The bare `gemini-3.8-flash` id from this home's previous config is not listed; only the suffixed `-high`, `-medium`, and `-low` variants are.
`bin/fm-spawn.sh`'s `agy_model_validate` refuses a requested id a reachable `agy models` listing omits, and launches unvalidated with a stderr notice when the listing is unreachable.
The listing is a remote fetch (`Fetching available models...`), so the probe runs with stdin detached under the shared hard bound from `bin/fm-timeout-lib.sh` (15 seconds by default, `FM_AGY_MODELS_TIMEOUT`); a stalled fetch or a sign-in prompt is cut off and falls through to the unvalidated launch instead of blocking the spawn before any pane exists.
Print mode (`agy -p "Reply with exactly: AGY_PRINT_PROBE_OK" --model gemini-3.8-flash-low`) returned the exact reply with exit 0 in about 8 seconds, proving the credential path without a pane.

## Busy state: the pinned status row, unknown on absence

Mid-turn the pane rendered the status row and a spinner line at once:

```
⣯  Generating...
└ Tip: When reviewing a file edit, press f to see the full diff.
...
esc to cancel                                                           Gemini 3.8 Flash · low
```

The completed turn showed the reply, then the idle composer:

```
>
──────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                         Gemini 3.8 Flash · low
```

`fm_busy_agy_tail_busy` and the delivery guard in `bin/fm-composer-lib.sh` match the `esc to cancel` token alone: the TUI pins that status row to the bottom of the pane for the whole turn, and the idle row replaces it with `? for shortcuts`.
The `Generating...` spinner word is deliberately not a signal: it is a free-floating output line, so ordinary worker output such as `Generating report...` would otherwise classify an idle worker as busy or acknowledge a submit that did not land.
No busy phase without the status row was observed live; every captured mid-turn frame carried it.
`fm_busy_classify` reports `unknown agy-regex` when the token is absent, because a long turn can scroll the marker out of the captured tail.
The signature is hardcoded with no environment override, so a stray variable can never change worker-state classification.
Herdr's own registry agreed throughout: `agent get` reported `agent_status=working` mid-turn and `idle` after, so on Herdr the native verdict carries busy with no new code.

## Interrupt and exit

A single `Escape` sent mid-turn through `herdr pane send-keys` cancelled it and printed this row, with the composer back at idle and no repolluted text:

```
  ⎿  Interrupted · What should Antigravity CLI do instead?
```

Sending `/quit` plus Enter exited the process; the pane closed under the `exec` launch, and Herdr reported the pane gone.
`bin/fm-control-lib.sh` records `Escape` once, no clear key, no ack source, and `/quit` for agy.

## Backend liveness: Herdr recognizes agy, tmux names it

```
$ herdr agent get w2:p1 --session fm-lab-firstmate-agy-ad-1599574-8823
{"result":{"agent":{"agent":"agy","agent_status":"idle",...,"agent_session":{"agent":"agy","kind":"id","source":"herdr:antigravity_cli",...}}}}
```

Herdr tracks agy natively (`antigravity-cli` integration, detected as `agent=agy`), so `fm_backend_herdr_pane_agent_state` returns `live` for every registered agy status and no exit-detection hardening was needed.
`bin/backends/tmux.sh` matches the anchored process name `agy` as `agent`, the muse/omp precedent for short bare-word names.
agy stays out of the session-lock name vocabulary in `bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent.

## Composer: unknown by design

Byte-level capture of the idle pane shows a bare unstyled `>` between two full-width `─` rules, with an unstyled `? for shortcuts` cell and a dim (`SGR 2`) model cell in the status row below.
The shared classifier reads that bare `>` as `unknown` under the dead-shell rule, never `empty`.
Steering still confirms delivery: the Herdr submit core leads with the native `idle`-to-`working` transition, which agy performs, and the delivery footer regex covers the tmux path.
This is the cursor precedent, not a gap to patch in shared code.

## Supervised task: spawn, steer, relaunch, and exit through the new path

A trivial scout ran end to end through `bin/fm-spawn.sh --harness agy` against the same isolated lab session: `spawned agy-e2e1 harness=agy kind=scout` with a treehouse-provisioned worktree, `--model gemini-3.8-flash-low`, and `--effort low` all recorded in task metadata.
The worker wrote its worktree file and appended `done: agy e2e turn complete` to its status file, which lives outside the worktree, proving prompt processing, tool execution, outside-workspace file access, and a new completion event.
Durable steering held: a `bin/fm-send.sh` message landed in the task inbox, the worker appended the steered lines to both files, and its inbox record moved to `handled/`.
Same-copy relaunch held: `bin/fm-control.sh relaunch --note` replaced the worker in place on the identical worktree, model, and effort, the replacement verified both prior lines intact and appended `relaunched: done`.
Exit held: `bin/fm-control.sh exit` stopped the worker, the registry returned `agent_not_found`, and the pane remained a lone shell in the worktree with all work intact.
No automatic quota failover was exercised or claimed; every handoff above was an explicit supervised relaunch.

## What is still unproven

The unauthenticated failure mode was never observed; this host's agy runs signed in, so any auth prompt is a fail-loud credential blocker, not a handled dialog.
No slash-skill invocation form was verified, so skill invocation stays natural language.
`--continue` and `--conversation` resume were never exercised; recovery uses deterministic relaunch from the brief on disk.
No primary or secondmate behavior was built or tested, and none is claimed.

## Refreshing this record

Run the portable suite and the live guard after any agy upgrade, because the process name, marker set, trust dialog text, and rendered busy/interrupt text are all vendor-controlled surfaces that the spawn gate and the busy fallback match verbatim:

```
bin/fm-test-run.sh tests/fm-agy-harness.test.sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```
