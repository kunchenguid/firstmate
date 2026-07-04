# cmux backend

The cmux backend is an experimental session-provider adapter for firstmate.
It uses cmux for visible task workspaces and keeps treehouse as the git worktree provider.

## Status

- Backend name: `cmux`
- Selection: explicit only via `--backend cmux`, `FM_BACKEND=cmux`, or local `config/backend`
- Auto-detection: none
- Worktree provider: treehouse
- Session shape: one cmux workspace per task, named `fm-<id>`
- Target shape: `workspace:<n>/surface:<n>`
- Recorded task metadata: `backend=cmux`, `cmux_workspace=`, `cmux_surface=`

## Requirements

Install cmux and jq:

```sh
brew install --cask cmux
brew install jq
```

The cmux app must be reachable through its CLI socket.
Check that with:

```sh
cmux version
cmux tree --all --json
```

Treehouse is still required for normal ship and scout tasks:

```sh
treehouse get --help
```

## Use

Set cmux as the default backend for new tasks:

```sh
mkdir -p config
printf 'cmux\n' > config/backend
```

Or select it per spawn:

```sh
bin/fm-spawn.sh <id> projects/<repo> --backend cmux
```

## Implementation notes

`bin/backends/cmux.sh` maps firstmate's backend interface to cmux CLI calls:

- create task: `cmux workspace create --name fm-<id> --cwd <project> --focus false`
- find task endpoint: `cmux tree --all --json`, then select the first terminal surface in that workspace
- capture: `cmux read-screen --workspace <workspace> --surface <surface> --scrollback --lines <n>`
- send text: `cmux send --workspace <workspace> --surface <surface> -- <text>`
- send keys: `cmux send-key --workspace <workspace> --surface <surface> -- enter|escape|ctrl+c`
- teardown endpoint: `cmux workspace close <workspace>`

Like the zellij adapter, cwd discovery after `treehouse get` uses an active shell probe.
The adapter sends a short `pwd` command wrapped in unique markers and reads it back from the terminal output.
This avoids relying on a passive cmux cwd field.

## Current limitations

- This backend is experimental and has not yet had the same long-running fleet soak as tmux.
- It requires `jq` for `cmux tree --json` parsing.
- It does not expose a verified composer-clear primitive yet.
  `fm-send.sh` therefore treats a successful cmux text send plus Enter as an inconclusive-but-landed submission rather than detecting swallowed Enter precisely.
- Secondmate support follows the generic backend path, but the workspace layout is not split per `FM_HOME` the way herdr is.
- The adapter does not auto-detect an ambient cmux session; choose it explicitly so firstmate never unexpectedly reuses a human workspace.
