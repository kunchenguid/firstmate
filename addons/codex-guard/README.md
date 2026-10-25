# codex-guard

Runs the fleet delete, kill and read guards before every Codex shell command. Codex crewmates start with `--disable hooks` (a new hook would park the launch on Codex's hook-trust screen), so no hook reaches them. This add-on uses Codex's own `shell_environment_policy` instead: `config.toml` sets `BASH_ENV` to `bash-env.sh`, which every Codex command shell reads before it runs anything.

Codex 0.159 runs a command as `bash -lc '<snapshot wrapper>'`, and the wrapper ends in `exec bash -c '<command>'`. `bash-env.sh` skips the wrapper and judges the inner shell's `$BASH_EXECUTION_STRING`, which is exactly the agent's command, through each installed guard's Claude hook entry (`fm-delete-guard` with `--runtime codex`, `fm-kill-guard` with `--caller` set to the Codex process, `fm-read-guard`). Exit 2 is the guard's final block; Codex shows its reason to the agent. A delete block lands in the delete guard's log and watcher check like any other runtime. The shell then drops `BASH_ENV`, so scripts the command starts run unchecked, as under the Claude hook. A guard that is not installed is skipped; a guard that fails prints its cause and lets the command run, as a failing Claude hook does.

Wire in: `codex-guard/install.sh` after the guards (`--dry-run` prints the block it would append). It appends one block to `${CODEX_HOME:-~/.codex}/config.toml` after a backup, refuses when the config already sets `shell_environment_policy` (add the line by hand there), and checks the result parses first. Remove: `codex-guard/uninstall.sh`.

Proven on Codex 0.159.2 in the crewmate launch shape, which runs embedded because it passes `--disable` and `-c`. A Codex started without such flags runs its commands in the shared background server instead; that path was not probed.

Test: `bash codex-guard/tests/codex-guard.test.sh` (throwaway HOME, the real guard installers, commands run the way Codex runs them; nothing real is signalled or read).
