# Kimi harness verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the Kimi crewmate and scout adapter.
The `harness-adapters` skill owns current operating facts and safety boundaries.
Kimi primary firstmate hosting and secondmate launches are intentionally outside this verification scope.

## Version and config

The local binary and config were verified on 2026-07-25.
Home-directory prefixes in commands and observed output are normalized to `$HOME`.

```sh
$HOME/.kimi-code/bin/kimi --version
```

Observed output:

```text
0.29.1
status=0
```

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi provider list
```

Observed output:

```text
managed:kimi-code  type=kimi  models=4  source=oauth

Default model: kimi-code/kimi-for-coding
status=0
```

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi doctor
```

Observed output:

```text
Kimi doctor

OK config.toml  $HOME/.kimi-code/config.toml
OK tui.toml     $HOME/.kimi-code/tui.toml

All checked config files are valid.
status=0
```

The active model declarations were checked with this command.

```sh
awk '/^default_model[[:space:]]*=/ || /^\[models\./ || /^[[:space:]]*support_efforts[[:space:]]*=/' \
  $HOME/.kimi-code/config.toml
```

Observed output:

```text
default_model = "kimi-code/kimi-for-coding"
[models."kimi-code/kimi-for-coding"]
[models."kimi-code/kimi-for-coding-highspeed"]
[models."kimi-code/k3-256k"]
support_efforts = [ "low", "high", "max" ]
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
status=0
```

## Launch and ingestion

Kimi 0.29.1 does not accept the firstmate launch brief as a positional interactive prompt.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi --auto 'Reply with exactly OK.'
```

Observed output:

```text
unknown command 'Reply with exactly OK.'. See 'kimi --help'.
status=1
```

Kimi 0.29.1 also refuses prompt mode combined with interactive auto mode.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi --auto -p 'Reply with exactly OK.' --output-format stream-json
```

Observed output:

```text
error: Cannot combine --prompt with --auto.
status=1
```

Prompt mode emits a resumable session, and the firstmate adapter resumes that same session in auto mode from the same working directory.
The authenticated adapter path was verified end to end with Kimi Code CLI 0.29.1, K3, and high effort on 2026-07-25.
The disposable project, Treehouse pool, Firstmate home, and tmux server all lived under an isolated verification directory.

```sh
ISOLATED_HOME=/path/to/isolated-firstmate-home
ISOLATED_PROJECT=/path/to/isolated-project
env \
  FM_HOME="$ISOLATED_HOME" \
  FM_STATE_OVERRIDE="$ISOLATED_HOME/state" \
  FM_DATA_OVERRIDE="$ISOLATED_HOME/data" \
  FM_PROJECTS_OVERRIDE="$ISOLATED_HOME/projects" \
  FM_CONFIG_OVERRIDE="$ISOLATED_HOME/config" \
  KIMI_CODE_BIN=$HOME/.kimi-code/bin/kimi \
  KIMI_CODE_HOME=$HOME/.kimi-code \
  bin/fm-spawn.sh kimi-live "$ISOLATED_PROJECT" \
    --harness kimi --model kimi-code/k3 --effort high --backend tmux
```

The launch brief was:

```text
Run the shell command sleep 8, then reply with exactly ADAPTER_BOOTSTRAP_OK.
```

While prompt mode was still running, the secure control directory, foreground process, published metadata, pane marker, and current-state reader reported:

```text
control=.kimi-bootstrap-kimi-live.OladFJWpHHad
live=bootstrap=35365
capture=present
metadata=present
pane_current_command=kimi
pane=🌑 · Kimi prompt bootstrap
state: working · source: pane · harness busy

window=firstmate:fm-kimi-live
worktree=<isolated-project>/.treehouse/project-aa9544/1/project
project=<isolated-project>
harness=kimi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-kimi-live
model=kimi-code/k3
effort=high
```

This proves that local validation and the real paid preflight completed before metadata publication, while publication itself occurred only after the foreground prompt bootstrap and busy marker were observable.
The spawn then returned successfully:

```text
spawned kimi-live harness=kimi kind=ship mode=no-mistakes yolo=off window=firstmate:fm-kimi-live worktree=<isolated-project>/.treehouse/project-aa9544/1/project
status=0
```

After prompt mode finished, its real stream output and the resumed TUI showed the same session id, K3 model, high effort, original operational envelope, command execution, and response:

```text
{"role":"assistant","content":"ADAPTER_BOOTSTRAP_OK"}
{"role":"meta","type":"session.resume_hint","session_id":"session_7c167f0d-5f42-4da3-ab91-59dd63692567","command":"kimi -r session_7c167f0d-5f42-4da3-ab91-59dd63692567","content":"To resume this session: kimi -r session_7c167f0d-5f42-4da3-ab91-59dd63692567"}

Directory: <isolated-project>/.treehouse/project-aa9544/1/project
Session:   session_7c167f0d-5f42-4da3-ab91-59dd63692567
Model:     K3
Version:   0.29.1
Permission mode: auto

FIRSTMATE_OP: v1 launch-brief: Run the shell command sleep 8, then reply
with exactly ADAPTER_BOOTSTRAP_OK.

Ran a command
$ sleep 8
Command executed successfully.

ADAPTER_BOOTSTRAP_OK
auto  K3 thinking: high
```

The ordinary `fm-send.sh` path then submitted one follow-up to that resumed session.
During `sleep 5`, the shared pane reader reported `pane-state=busy` and captured `Running a command`.
After completion, it reported `composer=empty` and `pane-state=idle`.

```text
Run the shell command sleep 5, then reply with exactly ADAPTER_RESUME_OK.

Running a command
$ sleep 5
pane-state=busy

Ran a command
$ sleep 5
Command executed successfully.

ADAPTER_RESUME_OK
composer=empty
pane-state=idle
```

The secure bootstrap control directory was gone after resume, while task metadata remained published.
No second prompt copy was present in the pane transcript.

## Model and effort

Unknown models fail before a model call.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi -m does-not-exist -p 'Reply with exactly OK.' --output-format stream-json
```

Observed output:

```text
error: failed to run prompt: config.invalid: Model "does-not-exist" is not configured in config.toml. Add a [models."does-not-exist"] entry with max_context_size.
See log: $HOME/.kimi-code/logs/kimi-code.log
status=1
```

Kimi 0.29.1 help exposes no effort flag.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  $HOME/.kimi-code/bin/kimi --effort low -p 'Reply with exactly OK.' --output-format stream-json
```

Observed output:

```text
error: unknown option '--effort'
status=1
```

The installed CLI honors the effort environment variable for K3 models that declare `support_efforts`.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  KIMI_MODEL_THINKING_EFFORT=low \
  $HOME/.kimi-code/bin/kimi -m kimi-code/k3 -p 'Reply with exactly K3_LOW_OK.' --output-format stream-json
```

Observed output:

```text
{"role":"assistant","content":"K3_LOW_OK"}
{"role":"meta","type":"session.resume_hint","session_id":"session_c93be1e1-ad9c-4bd2-a310-2cb214c20143","command":"kimi -r session_c93be1e1-ad9c-4bd2-a310-2cb214c20143","content":"To resume this session: kimi -r session_c93be1e1-ad9c-4bd2-a310-2cb214c20143"}
status=0
```

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  KIMI_MODEL_THINKING_EFFORT=max \
  $HOME/.kimi-code/bin/kimi -m kimi-code/k3-256k -p 'Reply with exactly K3_256K_MAX_OK.' --output-format stream-json
```

Observed output:

```text
{"role":"assistant","content":"K3_256K_MAX_OK"}
{"role":"meta","type":"session.resume_hint","session_id":"session_989bbc53-9aa8-4996-8618-b01289654f89","command":"kimi -r session_989bbc53-9aa8-4996-8618-b01289654f89","content":"To resume this session: kimi -r session_989bbc53-9aa8-4996-8618-b01289654f89"}
status=0
```

An unsupported K3 effort override fails provider-side, so firstmate rejects it before spawn.

```sh
env KIMI_CODE_HOME=$HOME/.kimi-code \
  KIMI_MODEL_THINKING_EFFORT=medium \
  $HOME/.kimi-code/bin/kimi -m kimi-code/k3 -p 'Reply with exactly K3_MEDIUM_SHOULD_FAIL.' --output-format stream-json
```

Observed output:

```text
error: failed to run prompt: provider.api_error: 400 Invalid request Error
See log: $HOME/.kimi-code/logs/kimi-code.log
status=1
```

`fm-spawn` uses this same prompt-mode shape as one cheap model preflight before writing task metadata.
The preflight passes the requested `--model`, accepts only exit zero, and surfaces Kimi's own error on rejection.
For explicit `kimi-code/k3` and `kimi-code/k3-256k`, the preflight and launch also pass `KIMI_MODEL_THINKING_EFFORT` values `low`, `high`, and `max`.
For other or default-resolved models, firstmate records the requested effort and omits the environment override because Kimi may ignore it.
Firstmate does not reparse `config.toml`.

## Supervision class

The installed 0.29.1 command surface exposes ACP server mode, but this adapter uses the TUI path.
No installed hook-backed firstmate crew turn-end path was verified.
Kimi crewmate and scout supervision is therefore stale-based, with the moon-plus-middot spinner as pane busy corroboration.
