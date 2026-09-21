# Verification: the devin (Devin CLI) crewmate/scout adapter

Active empirical facts for firstmate's devin adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/devin.md`](../../.agents/skills/harness-adapters/references/harness/devin.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `devin 3000.10.31` (`b98cc431`) at first verification; vendor-controlled surfaces re-verified on `devin 3000.11.1` (`cc4e349ca55e`) below |
| Verified | 2026-09-21 (3000.10.31); re-verified 2026-09-21 (3000.11.1: trust dialog, hook payloads, busy row, interrupt, exit, markers, models shape, `--help`) |
| Binary | `/home/mustafa/.local/bin/devin` -> `../.local/share/devin/cli/_versions/current/bin/devin`, an ELF 64-bit natively-compiled single executable |
| Platform | Linux x64 |
| Backend | tmux, in the fleet session, against scratch directories and the task worktree; no captain fleet state was touched |

Every command below ran inside a disposable scratch directory, a scratch tmux window of the fleet session (created and killed for the probe), or the task worktree.
No captain fleet state was touched, except the trust-store entries noted below, which were restored after each probe.

## Detection: ancestry only, no marker

```
$ devin --version
devin 3000.10.31 (b98cc431)
```

A live TUI launched with `DEVIN_PERMISSION_MODE` unset carries no `DEVIN_*` variable in `/proc/<pid>/environ`; the one devin-set variable on 3000.10.31 is `CHISEL_SESSION_DB`, a sessions-db path, which is never promoted to a marker, the muse precedent.
On 3000.11.1 a live TUI additionally carries `AI_AGENT=devin_3000-11-1_agent` and `AGENT=1`, and the fleet multiplexer started under devin carries `AI_AGENT` fleet-wide into every worker pane regardless of harness - an opencode worker under it still detects as opencode, which is the ancestry design proving itself.
`AI_AGENT` is therefore ambient launcher state, never identity, and is pinned unpromoted alongside the others.
`DEVIN_PERMISSION_MODE=bypass` observed on other live TUIs is inherited launcher state.
`ps -o comm=` reports `devin` with `argv[0]=devin` or the versioned install path `.../cli/_versions/3000.10.31/bin/devin`.
`bin/fm-harness.sh` therefore matches the anchored process name `devin` alone, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `GEMINI_CLI`, `CURSOR_AGENT`, and `CURSOR_INVOKED_AS` at the launch boundary.
`tests/fm-devin-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `devin` ancestor once the spawn clears it.

## Launch: positional prompt with auto-submit

```
$ devin -- "Reply with exactly DEVIN_PROBE_OK and nothing else"
```

The brief submitted itself with no extra Enter, the turn ran, and `DEVIN_PROBE_OK` rendered in the pane with the composer back at its idle placeholder.
A second launch into the same directory answered a fresh prompt the same way, so the shape is repeatable, not a first-run accident.

## Trust dialog: pre-registered before launch, gated on semantic busy as the backstop

A first launch in a fresh directory shows this dialog:

```
✱ Do you trust the authors of this directory?
   For security, devin should not be run in directories with untrusted content.

 /tmp/devin-probe-scratch

 ❭ 1 Yes, trust
 · 2 No, exit

 ↓↑ to select · ↵ to choose · esc to quit
```

The safe answer is preselected: a single Enter answers it.
A directory under the already-trusted `/home/mustafa` starts clean with no dialog, so trust walks ancestors.
Answering records the folder in the `trusted_paths` array of `~/.local/share/devin/cli/trusted_workspaces.json`; devin honors `${XDG_DATA_HOME:-$HOME/.local/share}` as its data root (verified: pointing `XDG_DATA_HOME` elsewhere makes `devin auth status` look for credentials there, and it honors `XDG_CONFIG_HOME` for the user config the same way, creating `$XDG_CONFIG_HOME/devin/config.json` on first run).
Verified under a staged store: a folder appended to that array by hand launched straight into its turn with no dialog, while the same folder with the entry removed parked on the dialog, and the dialog displays the resolved path.
A symlinked cwd with only the real path registered still started clean, so the resolved path is what the comparison needs; `bin/fm-devin-trust.sh` records the logical path alongside it anyway when they differ, the agy shape.
`bin/fm-spawn.sh` runs that helper before launch at the same point it pre-registers claude trust; the helper applies the same structural scope test (a linked worktree of the spawning project, never a primary checkout, a subdirectory, a plain directory, or the home directory), preserves every other key in the store, and writes atomically with a fingerprint check.
A failed registration is a stderr warning rather than a refusal, because the dialog preselects the safe answer and the gate below can answer it.
After pre-registration, `bin/fm-spawn.sh` runs a post-launch readiness gate (`devin_wait_for_working`): it polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the authors of this directory?` text renders, and reports success only once `fm_busy_classify` returns `busy devin-hook` for the pane (never the `fm-spawn` seed, which proves nothing about hook liveness).
On an unregistered path a busy verdict never counts as ready until the dialog has been answered.
When the brief cannot be confirmed to run within the window (an answered dialog never turns hook-busy, a pre-trusted pane never turns hook-busy, or an unregistered pane never shows the dialog), the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
`tests/fm-devin-harness.test.sh` covers the helper's registration and scope refusals against a throwaway store, and drives a fake pane whose dialog decision reads the store the spawn just wrote: the pre-trusted launch with no dialog, a dialog that renders anyway answered exactly once, and both fail-and-close paths.

## Config override: user config copied through, hooks merged, project hooks kept

```
$ devin --config /tmp/devin-probe-config.json -- "Reply with exactly DEVIN_CFG_PROBE_OK and nothing else"
```

The TUI ran normally and hooks from the override file fired, while the project's own `.devin/hooks.v1.json` hooks fired alongside for the same turn (both logs show the same `session_id`), proving hook layers merge rather than override.
`bin/fm-spawn.sh` therefore writes `state/<id>.devin-config.json` as the launching user's own user config copied through opaquely (account, permissions, and existing hooks all survive) with firstmate's four hooks merged into its `hooks` key, and passes it via `--config`.
A present-but-unparseable user config refuses the spawn rather than silently dropping the operator's settings.
Nothing is written into the worktree and the captain's own user config is never mutated.
`tests/fm-devin-harness.test.sh` pins the merge, the refusal, and that no worktree config is written.

## Model and effort

```
$ devin models list --format json
{
  "families": [
    {
      "family_label": "Claude Opus 5",
      "family_uid": "claude-opus-5",
      "slug": "claude-opus-5",
      "aliases": ["opus"],
      "variants": [{"model_uid": "claude-opus-5-medium", ...}, ...]
    },
    ...
  ]
}
```

`devin --help` on 3000.10.31 exposes no effort, reasoning, or thinking flag, so the shared effort axis stays in task metadata under the record-and-omit contract; `Alt+T` cycles reasoning interactively only.
`--permission-mode bypass` is a verified alias of the dangerous mode (`devin --permission-mode bogus` fails with `Valid options: normal (auto), accept-edits, dangerous (yolo, bypass), autonomous (requires --sandbox)`), and exec turns ran with no approval gate under it.
`bin/fm-spawn.sh`'s `devin_model_validate` refuses a requested value no family slug, alias, or model id in a reachable listing matches, and launches unvalidated with a stderr notice when the listing is unreachable or jq is absent.

## Busy state: semantic hooks, unknown on absence

One text-only turn fired exactly, in order:

```
{"hook_event_name":"SessionStart","source":"startup","session_id":"fast-juniper"}
{"hook_event_name":"UserPromptSubmit","prompt":"Reply with exactly ...","session_id":"fast-juniper","prompt_id":"37cd17df-..."}
{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"DEVIN_PROBE_OK","session_id":"fast-juniper","prompt_id":"37cd17df-..."}
```

`/exit` fired `{"hook_event_name":"SessionEnd","reason":"prompt_input_exit","session_id":"..."}`, and the process exited with status 0.
A double-Escape interrupt fired NO hook: the cancelled turn's `UserPromptSubmit` stands alone with no following `Stop`, so like Claude an interrupt preserves the adapter-owned busy record until the next hook event settles it, and `bin/fm-control-lib.sh` records no ack source for devin for the same reason.
`SessionStart` carries no `prompt_id`.
`fm_busy_classify` reports the seeded `busy fm-spawn` until the first hook event, then `busy devin-hook` / `idle devin-hook`.
No busy phase without a hook event was needed; every captured mid-turn frame still carried the running-turn row, but rendered text is never a state source.
`tests/fm-devin-harness.test.sh` drives the generated config's real hook commands through the real writer and classifier, including the stale-generation refusal.

## Interrupt and exit

A double `Escape` sent mid-turn through `tmux send-keys` cancelled it: the tool card printed `Canceled due to user interrupt`, the transcript printed `✱ Canceled. What should Devin do?`, and the composer returned to its idle placeholder with no repolluted text.
A single `Escape` alone does not cancel; the running turn names the key itself (`esc twice to interrupt`).
The two presses must be separated: a back-to-back pair in one `send-keys` call was observed not to cancel on 3000.11.1, while two presses about a second apart cancelled at once, so the control plane and the live guard both space them.
Sending `/exit` plus Enter exited the process; the pane returned to its shell.
`bin/fm-control-lib.sh` records `Escape` twice, no clear key, no ack source, and `/exit` for devin.
The idle composer classifies `empty` and typed text classifies `pending` through the shared classifier (the `❭` glyph and both placeholders, below), so the exit verb's proven-empty gate and the submit core's Enter-only retries both operate; a typed Enter is occasionally swallowed with the text left unsubmitted, a further Enter submits the pile, and a multi-row unsubmitted composer can read `unknown` under the strict blank-row rule, so one ring's Enter stays best-effort and the watcher's re-ring ladder owns redelivery.

## Composer: the bare ❭ row

Byte-level capture of the idle pane shows an unstyled `❭` (U+276D) followed by the dim truecolor-124 placeholder `Ask Devin to build features, fix bugs, or work on your code`, between dim `─` rules above and the `SWE-2 High ...` status row below.
Mid-turn the composer keeps the submitted prompt rendered bright, or shows `Guide Devin while it works`.
The shared classifier reads the bare `❭` row as `empty` once ghost stripping removes the dim placeholder, and as `pending` with real typed text; the transcript's own `❭ <submitted prompt>` echoes never prove a composer without the cursor.
`tests/fm-devin-harness.test.sh` pins the glyph and both placeholders (portable), and `tests/fm-devin-signals-live-e2e.test.sh` re-proves them against the live TUI.

## Backend liveness: tmux names it

The tmux adapter classifies the anchored process name `devin` as `agent` through the shared name vocabulary in `bin/fm-agent-process-lib.sh`, the muse/omp/agy precedent for short bare-word names.
devin stays out of the session-lock name vocabulary in `bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent.
Herdr carries no native devin integration; a devin pane proves liveness at process level through the shared classifier.

## Credential precondition

This host's devin runs signed in (`devin auth status` reports `Logged in (via Devin)`, Pro tier), so every probe above ran with no key export and no dialog.
The unauthenticated failure mode was never observed; treat any auth prompt as a fail-loud credential blocker, not a handled dialog.

## Supervised task: spawn, steer, and exit through the new path

A trivial scout ran end to end through `bin/fm-spawn.sh --harness devin` on tmux: `spawned <id> harness=devin kind=scout` with a treehouse-provisioned worktree, `--model swe`, and `--effort low` (recorded, omitted from the launch) all recorded in task metadata.
The worker wrote its worktree file and appended `done:` to its status file, proving prompt processing, tool execution, and a new completion event.
The `SessionStart` hook recorded `busy devin-hook` before the spawn reported success, proving the wiring live at launch; `Stop` recorded `idle devin-hook` and touched `turn-ended` at turn end.
Durable steering held: a `bin/fm-send.sh` message landed in the task inbox, the worker appended the steered lines, and its inbox record moved to `handled/`.
Exit held: `bin/fm-control.sh exit` stopped the worker and the pane returned to a lone shell in the worktree with all work intact.

Re-run on 2026-09-21 against 3000.11.1 from an isolated tmux server and a scratch home, so no fleet state was touched:

```
$ bin/fm-spawn.sh devin-e2e-1 $E2E/proj --harness devin --mode no-mistakes --yolo off --model swe-2-medium --effort low --backend tmux
spawned devin-e2e-1 harness=devin kind=ship mode=no-mistakes yolo=off window=e2e:fm-devin-e2e-1 worktree=<treehouse worktree>
```

The worker wrote `hello-devin.txt` with the exact content `HELLO` and appended `done: hello-devin.txt written` to its status file.
`state/devin-e2e-1.busy-state` read `state=idle source=devin-hook event=stop`, and `state/devin-e2e-1.turn-ended` existed.
Steering held through the real inbox: `bin/fm-send.sh devin-e2e-1 "Reply with exactly STEER_OK and nothing else"` landed in `state/devin-e2e-1.inbox/001.msg`, the worker read that file, moved it to `handled/` itself, and replied `STEER_OK` in its turn.
Exit held: `bin/fm-control.sh devin-e2e-1 exit` printed `stopped devin-e2e-1 harness=devin backend=tmux ...` and the pane returned to `bash` with the work intact.
The scratch trust-store entry, worktree, and pool directory were all removed afterwards, and the operator trust store was restored byte-identical from its snapshot.

## What is still unproven

The unauthenticated failure mode was never observed; this host's devin runs signed in, so any auth prompt is a fail-loud credential blocker, not a handled dialog.
No slash-skill invocation form was verified, so skill invocation stays natural language.
`-c/--continue` and `-r/--resume` pane resume were never exercised; recovery uses deterministic relaunch from the brief on disk.
The exact first-Enter-swallow timing was not isolated to a single cause; the submit core's Enter-only retries plus the re-ring ladder cover it, and the record above states the observed behavior, not a mechanism.
Herdr carries no native devin pane recognition; tmux liveness plus the shared process classifier is the verified path, and Herdr behavior is unclaimed.
No primary or secondmate behavior was built or tested, and none is claimed.

## Refreshing this record

Run the portable suite and the live guard after any devin upgrade, because the process name, marker set, trust dialog text, rendered busy/interrupt text, and hook payload shapes are all vendor-controlled surfaces that the spawn gate, the busy wiring, and the composer rules match verbatim:

```
bin/fm-test-run.sh tests/fm-devin-harness.test.sh
FM_DEVIN_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-devin-signals-live-e2e.test.sh
```
