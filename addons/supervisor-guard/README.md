# supervisor-guard

The supervisor-work guard: a PreToolUse hook that stops a firstmate supervisor
session from doing a worker's job. It refuses to drive a crew-owned
`no-mistakes axi run` or `respond`, to sleep or poll inside a turn, and (for a
secondmate lead) to type into a worker's pane. The add-on owns this logic. Upstream
Kun's Firstmate has no such guard.

## Layout

- `bin/fm-supervisor-work-pretool-check.sh` — the hook. It scopes to any listed home
  it was installed for, prefilters the Bash command in shell, asks the decider,
  and writes the deny object on stderr. Fails open.
- `bin/fm-supervisor-work-decide.mjs` — the command-line entry for the policy.
  It loads the shell lexer from the checkout named by `--lexer`.
- `bin/fm-supervisor-work-command-policy.mjs` — the rules and the allow/deny
  decision. The only place the patterns live.
- `install.sh` / `uninstall.sh` — copy the three files to
  `${XDG_DATA_HOME:-$HOME/.local/share}/fm-supervisor-guard`, record the home in
  its `home` file, and merge or remove one PreToolUse Bash hook in
  `~/.claude/settings.json`. Install adds a home; `uninstall.sh <fm-home>` removes
  only that home, while no-argument uninstall removes everything. Both take `--dry-run` and back up what they change.
- `tests/fm-supervisor-work-guard.test.sh` — installs into a throwaway HOME, runs
  the installed hook against a fixture home and a linked worktree, then uninstalls.

## Dependencies on the Firstmate checkout

The add-on reads two files from the home's checkout and copies neither:
`bin/fm-primary-scope-lib.sh` (the scope predicate) and
`bin/fm-arm-command-policy.mjs` (the shell lexer). Upgrading the checkout upgrades
both with no merge here.

## Behaviour

- Scope: only a session whose root is one of the registered homes is judged. A linked
  worktree of that home, or any other repo, is allowed. The root is
  `CLAUDE_PROJECT_DIR`, else the hook payload's `cwd` git root.
- The hook accepts Claude `PreToolUse` JSON with `tool_input.command` and `cwd`; Pi and omp
  callers can use the same payload.
- Fail open: missing `jq`, `node`, the home file, the scope lib or the lexer
  each print one stderr line naming the cause, then allow.
- Prefilter: a command naming none of `no-mistakes`, `sleep`, `herdr` or `tmux`,
  once quotes and backslashes are stripped, is allowed without starting node.
  A command with ANSI-C or locale quoting always reaches the policy.
- Deny: exit 2 with the deny object on stderr.

## Status

- Not run on the live host by this change. Install and uninstall are proven only
  in the throwaway HOME the test uses.
- The fork still registers and runs its own guard until a later fork PR drops it.

## Checks

- `FM_CODE_ROOT=<checkout> bash supervisor-guard/tests/fm-supervisor-work-guard.test.sh`
- `shellcheck -x -e SC2015,SC1091 supervisor-guard/*.sh supervisor-guard/bin/*.sh supervisor-guard/tests/*.sh`
- `node --check` on each `.mjs`, and `bash -n` on each script.
