# Verification: the agy (Antigravity CLI) crewmate/scout adapter

Active empirical facts for firstmate's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0`; the send-confirmation timing below was re-measured on `agy 1.2.1` (2026-09-12) |
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

## Trust dialog: pre-registered before launch, gated on a busy turn as the backstop

A first launch in a fresh worktree shows this dialog:

```
Accessing workspace:

/home/andpod/.treehouse/firstmate-7bab20/1/firstmate/agy-probe-tmp

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```
`agy --help` (1.2.0) lists no trust flag or pre-registration command, but agy honours a `trustedWorkspaces` entry written to `~/.gemini/antigravity-cli/settings.json` ahead of launch.
Verified under a throwaway `HOME` holding a copy of `~/.gemini` (the real settings file was never written): a folder appended to that array by hand launched `--prompt-interactive` straight into its turn and rendered the reply with no dialog, while an unregistered sibling folder launched the same way parked on the dialog.
agy compares the pane's logical working directory, not its resolved path: a symlinked cwd whose real path alone was registered still parked on the dialog, so `bin/fm-agy-trust.sh` records both the logical path and its resolved form when they differ.
`bin/fm-spawn.sh` runs that helper before launch at the same point it pre-registers claude trust; the helper applies the same structural scope test (a linked worktree of the spawning project, never a primary checkout, a subdirectory, a plain directory, or the home directory), preserves every other key in the store, and writes atomically with a fingerprint check.
A failed registration is a stderr warning rather than a refusal, because agy's dialog preselects the safe answer and the gate below can answer it.
Two supervised Herdr runs in treehouse worktrees completed file-writing turns while the dialog was still unanswered at observation time (worker file and `done:` status line both verified on disk before Enter was ever sent to those panes).
Isolated runs in untrusted `/tmp` directories never reached the workspace until Enter: the turn spun through exploratory tool calls in agy's own scratch directory instead, and only the queued prompt ran after the answer.
One run left unanswered for several minutes wrote its file to agy's scratch directory instead of the workspace once finally answered.
The mechanism behind the difference was not established; path, backend, and latency were all varied across runs without isolating a single cause.
The spawn therefore does not depend on it: after pre-registration, `bin/fm-spawn.sh` runs a post-launch readiness gate (`agy_wait_for_working`) in the rovo/kimi launch-then-confirm shape as the backstop.
It polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the contents of this project?` text renders, and reports success only once `fm_busy_classify` returns a busy verdict for the pane (Herdr's native `working` status or the pinned `esc to cancel` status row).
Because Herdr's native `working` verdict is known to coexist with an unanswered dialog, the gate is strict about order: a busy verdict counts as ready only when the worktree was pre-registered before launch or the dialog has already been seen and answered; on an unregistered path it keeps polling for the dialog instead of accepting the early busy verdict.
When the brief cannot be confirmed to run within the window (an answered dialog never turns busy, a pre-trusted pane never turns busy, or an unregistered pane never shows the dialog), the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
`tests/fm-agy-harness.test.sh` covers the helper's registration and scope refusals against a throwaway store, and drives a fake pane whose dialog decision reads the store the spawn just wrote: the pre-trusted launch with no dialog, a dialog that renders anyway answered exactly once, the premature busy verdict on an unregistered path waiting for the dialog, and both fail-and-close paths.

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
The listing is a remote fetch (`Fetching available models...`), so the probe runs with stdin detached under the shared hard bound from `bin/fm-timeout-lib.sh` (15 seconds by default, `FM_AGY_MODELS_TIMEOUT`; a non-positive or non-numeric value clamps back to that default, because a non-positive bound is not a bound); a stalled fetch or a sign-in prompt is cut off and falls through to the unvalidated launch instead of blocking the spawn before any pane exists.
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
The tmux adapter classifies the anchored process name `agy` as `agent` through the shared name vocabulary in `bin/fm-agent-process-lib.sh`, the muse/omp precedent for short bare-word names.
agy stays out of the session-lock name vocabulary in `bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent.

## Composer: unknown by design

Byte-level capture of the idle pane shows a bare unstyled `>` between two full-width `─` rules, with an unstyled `? for shortcuts` cell and a dim (`SGR 2`) model cell in the status row below.
The shared classifier reads that bare `>` as `unknown` under the dead-shell rule, never `empty`.
Steering still confirms delivery: the Herdr submit core leads with the native `idle`-to-`working` transition, which agy performs, and the delivery footer regex covers the tmux path.
agy renders the busy footer late for that confirm loop - about 1.5 s after Enter for a short steer and 4-5 s for a realistic longer brief, measured live on `agy 1.2.1` (2026-09-12) against the shared budget's 3 x 0.4 s - so `bin/fm-send.sh` gives agy typed targets a longer default submit-confirm budget (20 retries, about 8 s at the default cadence); an explicit `FM_SEND_RETRIES` still wins and every other harness keeps the shared 3-retry default.
`tests/fm-send-agy-confirm.test.sh` pins the raised default and `tests/fm-agy-harness.test.sh` pins the Herdr transition path.
This is the cursor precedent, not a gap to patch in shared code.

## Supervised task: spawn, steer, relaunch, and exit through the new path

A trivial scout ran end to end through `bin/fm-spawn.sh --harness agy` against the same isolated lab session: `spawned agy-e2e1 harness=agy kind=scout` with a treehouse-provisioned worktree, `--model gemini-3.8-flash-low`, and `--effort low` all recorded in task metadata.
The worker wrote its worktree file and appended `done: agy e2e turn complete` to its status file, which lives outside the worktree, proving prompt processing, tool execution, outside-workspace file access, and a new completion event.
Durable steering held: a `bin/fm-send.sh` message landed in the task inbox, the worker appended the steered lines to both files, and its inbox record moved to `handled/`.
Same-copy relaunch held: `bin/fm-control.sh relaunch --note` replaced the worker in place on the identical worktree, model, and effort, the replacement verified both prior lines intact and appended `relaunched: done`.
Exit held: `bin/fm-control.sh exit` stopped the worker, the registry returned `agent_not_found`, and the pane remained a lone shell in the worktree with all work intact.
No automatic quota failover was exercised or claimed; every handoff above was an explicit supervised relaunch.

## Crew turn-end: a native Stop hook, gated on fullyIdle

An earlier revision of this adapter recorded that agy exposes no hook surface at all.
That is wrong, and the claim is corrected here rather than left to rot.
agy loads named hooks from `$HOME/.gemini/config/hooks.json`, verified present on `agy 1.2.2` (2026-09-13) on a host where an unrelated third-party tool was already registered there on both `PreInvocation` and `Stop`.
The binary carries the `hooks_json` and `workspacePaths` strings and this changelog line:

```
- Fixed a bug where the `/hooks` command wrote configurations to
  `~/.gemini/antigravity-cli/hooks.json` instead of the shared
  `~/.gemini/config/hooks.json`, ensuring hooks remain synchronized between
  the TUI and the backend.
```

`bin/fm-agy-turnend-hook.sh` owns exactly one `firstmate-turn-end` key in that file and rewrites every other named hook untouched.
An operator hook present before the install survived it and survived the removal:

```
$ HOME=$H bin/fm-agy-turnend-hook.sh install
installed: firstmate-turn-end in .../.gemini/config/hooks.json
$ cat $H/.gemini/config/hooks.json
{
  "operator-lint": { "PostToolUse": [ { "type": "command", "command": "true" } ] },
  "firstmate-turn-end": {
    "Stop": [ { "type": "command", "command": "bash \"$HOME/.gemini/antigravity-cli/fm-turn-end.sh\"", "timeout": 5 } ]
  }
}
```

### The fullyIdle gate is load-bearing

agy moves a shell command that outruns its `WaitMsBeforeAsync` into the background, yields the composer, and fires `Stop` with `fullyIdle` false while that command is still running; a second `Stop` with `fullyIdle` true follows once it finishes and the agent has reported it (observed on `agy 1.1.25` with a 40s sleep: two Stop events, false then true).
Signalling on the first event would report a worker done while its own build or test run is still going.
Both events driven apart against the installed hook on 2026-09-13:

```
$ printf '{"fullyIdle":false,"workspacePaths":["$WS"]}' | bash fm-turn-end.sh
{}
exit=0
marker: absent

$ printf '{"fullyIdle":true,"workspacePaths":["$WS"]}' | bash fm-turn-end.sh
{}
exit=0
marker: touched
```

`tests/fm-agy-harness.test.sh` pins that divergence.
Deleting the `fullyIdle` check from the hook body turns it red with `a Stop with fullyIdle false reported the turn finished`, so the assertion cannot go quietly vacuous.

### Removal refuses while a task still expects a wake

A live token means a task is still waiting on a turn-end signal, so removal is refused rather than silently silencing it:

```
$ HOME=$H bin/fm-agy-turnend-hook.sh remove
fm-agy-turnend-hook: refused: 1 task token(s) still registered in .../fm-turn-end.d; tear those tasks down first.
exit=1
```

After the token is retired, removal restores the file to exactly its pre-install content, and a home that never had a `hooks.json` gets none back.

### Live wake: one real agy turn produced the marker

The turn-end wake was captured live on 2026-09-13 through the installed binary (`agy 1.2.2` at `/home/jon/.local/bin/agy`) in a throwaway lab built on this record's established method: a scratch workspace under `/tmp`, a `HOME` holding a copy of `~/.gemini`, and no hand-fed payload anywhere in the capture.
The workspace was pre-registered in the copy's `trustedWorkspaces` (the effect `bin/fm-agy-trust.sh` produces ahead of every spawn), the hook was installed through this script, and one task token was registered in the lab's `fm-turn-end.d` pointing at a `state/task1.turn-ended` marker:

```
$ HOME=$H bin/fm-agy-turnend-hook.sh install
installed: firstmate-turn-end in $H/.gemini/config/hooks.json
$ printf '%s\n' "$STATE/task1.turn-ended" > "$H/.gemini/antigravity-cli/fm-turn-end.d/fm.W8b0AU6TQ6lW"
$ printf 'token=fm.W8b0AU6TQ6lW\n' > "$WS/.fm-agy-turnend"
$ tmux new-session -d -s agy-wake -c "$WS" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS HOME=$H agy --prompt-interactive 'Reply with exactly AGY_LIVE_WAKE_OK and nothing else' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
```

The turn launched at 17:08:36, the reply `AGY_LIVE_WAKE_OK` rendered within 5 s, and the pane settled to the idle composer:

```
>
──────────────────────────────────────────────────────────────────────────────
? for shortcuts                                           Gemini 3.8 Flash · low
```

The marker then existed with a mtime inside the turn window, so it was agy's own Stop event, delivered to the installed hook, that touched it:

```
$ ls -la --time-style=full-iso "$STATE"
total 8
drwxrwxr-x 2 jon jon 4096 2026-09-13 17:08:47.539006865 -0400 .
-rw-rw-r-- 1 jon jon    0 2026-09-13 17:08:47.539999961 -0400 task1.turn-ended
```

One edge was observed live and matters: until agy has confirmed a workspace in-session, the Stop payload arrives with `"fullyIdle": true` but an empty `"workspacePaths": []`, and the hook stays silent.
That state was captured on a fresh unregistered workspace whose folder-trust dialog was left unanswered: the turn still completed, but the marker stayed absent (the payload was read by temporarily wrapping the installed hook, which otherwise ran byte-identical).
Once the workspace was registered ahead of the launch, or its dialog was answered once in-session, the payload listed the path and the wake landed - both were driven live against the unmodified hook.
The spawn path is covered either way, because `bin/fm-spawn.sh` pre-registers the worktree before launch and its readiness gate answers a rendered dialog as the backstop.

### What this does NOT establish

The Stop payload reports only that a turn ended, so it is not a primary supervision protocol.
`docs/supervision-protocols/` still carries no agy wake protocol, and `bin/fm-spawn.sh` still refuses `--secondmate` on agy for that reason - not for the absence of hooks.
The hook reports turn END only, so it cannot source a busy START: the rendered-tail fallback above remains the busy source.

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
