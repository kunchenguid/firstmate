# Polytoken worker verification

Audience: maintainer verification.

Verified 2026-09-25 and 2026-09-26 on macOS arm64 (Darwin 27.0.0) with `polytoken 0.8.14` and tmux 3.5a.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/polytoken.md) owns operating facts; [`bin/fm-polytoken-lib.sh`](../../bin/fm-polytoken-lib.sh) and the other executable owners carry the mechanics.
This verification covers crewmates and scouts with tmux as the exercised runtime backend.
Primary, secondmate, Herdr, and quota-provider integration are outside this guarantee.

## Refresh commands

```sh
polytoken --version
polytoken new --help
polytoken models --format json
polytoken sessions --format json
polytoken print slash-commands
polytoken print tui-command-actions
bin/fm-test-run.sh tests/fm-polytoken-harness.test.sh
FM_POLYTOKEN_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-polytoken-signals-live-e2e.test.sh
```

The credentialed guard runs the actual command `fm-spawn.sh` generates in a private tmux socket against the operator's own Polytoken config and login, then steers, interrupts, relaunches, exits, and resumes through the real control plane.
It skips when the chosen model is not listed; the shared live gate owns absent-tool and opt-in behavior, and failures name the installed version.
The portable suite replays the real frames recorded in [`tests/captures/polytoken-0.8.14/`](../../tests/captures/polytoken-0.8.14/README.md).

## Live guard results

On 2026-09-26 the guard completed with exit 0 in 213 seconds with `FM_POLYTOKEN_MODEL=codex/gpt-6-luna` and `FM_POLYTOKEN_EFFORT=low`:

```text
ok - polytoken 0.8.14: spawn brief, model variant, bypass overlay, ancestry identity, and native hooks
ok - polytoken 0.8.14: identity-proven empty composer; real fm-send doorbell read and acknowledged
ok - polytoken 0.8.14: idle interrupt opens nothing; an open rewind picker blocks exit and is closed without rewinding
ok - polytoken 0.8.14: one Escape cancels the tool call, preserves the agent, and invalidates busy state
ok - polytoken 0.8.14: relaunch waits out the old daemon and re-arms one fresh session
ok - polytoken 0.8.14: /quit stops the daemon; polytoken continue resumes the session
ok - polytoken 0.8.14: a daemon that outlives its pane is detected and refuses another agent until reaped
ok - polytoken 0.8.14: the license gate matches the launch-prompt backstop
```

The guard interrupts only once the model's shell tool is running, because an Escape before any output cancels without drawing a `Canceled after` row (below).

## Observed vendor surfaces

### Launch and process shape

`polytoken new --help` offers `--model`, `--facet`, `--prompt`, `--no-attach`, `--sessions-dir`, and `--log-dir`, and no permission, hook, or trust flag.
A `--prompt` holding two lines was submitted once the TUI attached, and the `pre_user_prompt` hook received it intact as `"prompt":"Line one of the brief.\nLine two: reply with only the word PONG."`.
No trust dialog appeared in a fresh repository.

The TUI is the pane's foreground process and the session daemon is detached from it:

```text
$ ps -axo pid=,ppid=,pgid=,args=    (filtered to one session)
82332     1 82331 polytoken daemon --listener-fd 3 --session-id 0c0z3p-busy --sessions-dir <scratch>/sessions --log-dir <scratch>/logs --project-dir <scratch>/proj --credential-file <scratch>/sessions-v1/0c0z3p-busy/credential.json --project-config-dir <scratch>/pcfg --isolated
82321 81854 82321 polytoken --config-dir <scratch>/pcfg new --sessions-dir <scratch>/sessions --log-dir <scratch>/logs
```

A shell tool call descends from the daemon, not the TUI, and carries no `POLYTOKEN_*` variable:

```text
self=3295
 3295  3294  3294 /bin/bash
 3294 99628  3294 /opt/homebrew/bin/bash
99628     1 99627 polytoken
```

`lsof -a -p <daemon> -d cwd` reported the project directory as the daemon's working directory.
Killing the tmux server left the daemon running and listed by `polytoken sessions`; `kill -TERM` stopped it after 5 seconds and removed it from the live list.

### Configuration layers and hooks

The `--config-dir <dir>` form above starts the daemon with `--project-config-dir <dir> --isolated` and no global layer: with only `hooks.json` in that directory, `polytoken doctor` reported `no config file found in any searched location`, and after a symlinked `config.yaml` was added a full turn ran while no hook in that `hooks.json` fired.
A project-layer `.polytoken/hooks.json` in the working directory did fire, alongside the operator's global hooks.
One ordinary turn logged these events in order, each handler running as a child of the daemon:

```text
session_start {"event":"session_start","matcher_subject":"session_start","session_id":"0c0z8b-speed"}
post_clear    {"event":"post_clear","matcher_subject":"post_clear","session_id":"0c0z8b-speed","clear_count":0}
pre_user_prompt {"event":"pre_user_prompt","matcher_subject":"pre_user_prompt","prompt_id":"01a0db0a-f7e8-7161-abf9-45076c83f743","prompt":"..."}
pre_model_turn  {"event":"pre_model_turn","matcher_subject":"pre_model_turn","prompt_id":"01a0db0a-f7e8-7161-abf9-45076c83f743"}
post_model_turn {"event":"post_model_turn","matcher_subject":"post_model_turn","prompt_id":"01a0db0a-f7e8-7161-abf9-45076c83f743"}
stop            {"event":"stop","matcher_subject":"stop","prompt_id":"01a0db0a-f7e8-7161-abf9-45076c83f743"}
```

A prompt submitted while a turn ran fired a second `pre_user_prompt` at once, was folded in at the next agent pause, and the turn still ended with exactly one `stop`.
One Escape during a shell tool call cancelled it (`Canceled after 16.98s`, the tool process gone) with no `stop` hook; the daemon log recorded `turn.cancelled`.
An Escape 0.6 seconds into a turn, while it still showed `Thinking...`, also cancelled it and flashed `Cancelling turn`, but left the prompt card with no turn row beneath it.
Polytoken exposes no session-end hook.

The project layer controls the permission mode over the global layer:

```text
.polytoken/config.yaml "default_permission_matcher: standard" -> status row "perms: standard"
.polytoken/config.yaml "default_permission_matcher: bypass"   -> status row "perms: bypass"
```

Polytoken wrote nothing else into the project during these sessions.

### Model and effort

`polytoken models --format json` lists each model's `name`, `reasoning` (an `effort` set with `levels`, or `thinking` with no levels), and `selectable` variants, plus `default_model`.
`polytoken new --no-attach --model <value>` accepted and refused:

```text
codex/gpt-6-luna(low)     session_id=0c0zw3-debug port=54301
codex/gpt-6-luna(xhigh)   session_id=0c0zw4-fence port=54310
minimax/MiniMax-M3(t)     session_id=0c0zw4-vice port=54321
gpt-6-luna                [unknown_model] model 'gpt-6-luna' is not in ...
codex/gpt-6-luna(bogus)   [invalid_model_reference] invalid ...
ogo/glm-5.3(medium)       [invalid_model_reference] invalid ...   (glm-5.3 lists low, high, max)
nonexistent/model         [unknown_model] model 'nonexistent/model' ...
```

### Launch-time gates

With two fresh throwaway `XDG_DATA_HOME` directories, a plain launch wrote `polytoken/update_check.json` and `polytoken/update/update.seq`, while the same launch with `POLYTOKEN_SKIP_UPDATE_CHECK=1` wrote neither; `polytoken update --check --format json` reported `"status":"up_to_date"` for 0.8.14, so the update prompt itself was not rendered.
Both fresh data directories opened the license gate before any session work, which `license.ansi` records: a `License Agreement` box ending `An explicit choice is required.` over `1. View the agreement`, `2. Accept - agree and start the session`, and `3. Reject - end the session and exit`.

### TUI lifecycle

- `/quit` opens the slash palette (`/quit  End session  also /exit`), one Enter runs it, the TUI exits at once without a resume hint, and the daemon logged `shutdown: complete` 5004 ms later.
- On an idle agent one Escape shows `Press Esc again to rewind to a prompt.` in the status row; a second Escape 0.5 seconds later opened the boxed `Rewind` list with footer `Enter rewind  Esc close`, and one Escape closed it; a pair 0.15 seconds apart did not open it.
- `polytoken continue <session-id>` restored the conversation and the `(low)` model variant and re-ran `session_start`.
- `@skill:fmprobe` opened a `References` completion popup that took the first Enter; the second submitted `"prompt":"@skill:fmprobe "` and the skill's instruction ran.
- The composer is one blank row between two full-width rules with the cursor on it; Alt+Enter adds a row, and Ctrl+U clears one row.
- The turn row reads `Running for <n>` while a turn runs and `Completed in`, `Canceled after`, or `Errored after` once it ends; those four strings are the binary's own.
- tmux `#{pane_title}` did not change between idle and busy, so it carries no busy signal.
