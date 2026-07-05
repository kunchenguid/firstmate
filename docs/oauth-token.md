# Durable `CLAUDE_CODE_OAUTH_TOKEN` (macOS)

firstmate launches crewmate agents that rely on `CLAUDE_CODE_OAUTH_TOKEN` being present in their environment.
A token set only in the current login shell is lost on reboot, so agents fail until it is manually re-exported.
This page documents the durable mechanism that re-establishes the token at every login, with no manual step and no committed secret.

## What the mechanism is

A per-user LaunchAgent (`com.firstmate.oauth-token`) runs at login and calls `launchctl setenv CLAUDE_CODE_OAUTH_TOKEN <value>` to push the token into the user's launchd session domain.
From there it is inherited by every GUI-launched process: Terminal/iTerm, the shells inside them, any tmux server started from those shells, and the crewmate agents firstmate spawns inside tmux.
After a reboot, the agent runs once at login and the token is back before any terminal opens.

The token value is never committed.
The committed plist template at [`bin/launchd/com.firstmate.oauth-token.plist`](../bin/launchd/com.firstmate.oauth-token.plist) only references the helper script; it carries placeholders, not a secret.
The helper, [`bin/fm-oauth-token-load.sh`](../bin/fm-oauth-token-load.sh), reads the token from a secure source at run time.
The installer, [`bin/fm-oauth-token-install.sh`](../bin/fm-oauth-token-install.sh), renders the template into `~/Library/LaunchAgents/` and loads it.

## Why a LaunchAgent, not env passthrough in a daemon plist

Two approaches were considered:

1. A login-time `launchctl setenv` driven by a per-user LaunchAgent (chosen).
2. Passing the token through as an `EnvironmentVariables` entry in a daemon/agent plist.

The LaunchAgent is the cleaner fit because firstmate is not a launchd-managed daemon.
It runs interactively in a terminal, usually inside tmux, so there is no existing firstmate plist to inject `EnvironmentVariables` into.
Creating a firstmate LaunchAgent purely to host one env var would re-architect how firstmate launches (foreground interactive versus background daemon) for a single variable, and a static `EnvironmentVariables` entry would either bake the secret into the plist or shell out to a lookup at load time, which is the LaunchAgent approach with extra steps.

`launchctl setenv` at login matches the actual process tree: GUI terminal inherits the launchd session env, the login shell inherits the terminal, a tmux server started from that shell inherits the shell, and crewmate windows inherit the tmux server.
It is one focused, idempotent mechanism that does not change how firstmate runs.

## Setup

1. Put the token in a secure source the helper can read.
   The default source is a gitignored file at `~/.config/firstmate/claude-code-oauth-token` containing just the token, with mode `0600`:

   ```sh
   mkdir -p ~/.config/firstmate
   printf '%s' 'YOUR_TOKEN_VALUE' > ~/.config/firstmate/claude-code-oauth-token
   chmod 600 ~/.config/firstmate/claude-code-oauth-token
   ```

   Never commit this file.
   It lives under your home directory, outside this repo, and the helper only reads it.

2. Install and load the LaunchAgent from this repo:

   ```sh
   bin/fm-oauth-token-install.sh --install
   ```

   This renders the plist into `~/Library/LaunchAgents/com.firstmate.oauth-token.plist`, loads it, and runs the helper once so the token is set immediately without a re-login.

3. Verify the token is in the launchd user domain:

   ```sh
   bin/fm-oauth-token-load.sh --check
   ```

   Print `CLAUDE_CODE_OAUTH_TOKEN: present in the launchd user domain` means new shells and tmux servers will inherit it.
   To confirm a fresh shell actually sees it, open a new terminal and run `printenv CLAUDE_CODE_OAUTH_TOKEN`.

After a reboot or a fresh login, the LaunchAgent re-runs at login and re-exports the token automatically.

## Secure source alternatives

If you do not want a token file on disk, point the helper at your existing secret store with a gitignored `config/oauth-token-source` file under your firstmate home.
Its first non-comment line is one of:

- A literal path to a token file (e.g. `/Users/you/.secure/claude-token`).
- `cmd:<shell command>` whose stdout is the token, run via `sh -c`.
- `op:<1Password item reference>` resolved with `op read <reference>` (requires the 1Password CLI).

Examples:

```sh
# 1Password: op://Vault/Item/field
echo 'op://Private/Claude Code/token' > config/oauth-token-source

# any command that prints the token
echo 'cmd:op read "op://Private/Claude Code/token"' > config/oauth-token-source
```

`config/oauth-token-source` is gitignored; never commit it.
You can also override the source for a single invocation with `FM_OAUTH_TOKEN_FILE=<path>`.

## Rotation

To rotate the token:

1. Update the value in your secure source (overwrite the token file, or update the 1Password item).
2. Re-run the installer, which reloads the agent and runs the helper once:

   ```sh
   bin/fm-oauth-token-install.sh --install
   ```

   Or, without touching the plist, just push the new value into the current session:

   ```sh
   bin/fm-oauth-token-load.sh --setenv
   ```

   The helper also best-effort pushes the token into a running tmux server with `tmux set-environment -g`, so new tmux windows pick up the rotated value without restarting tmux.
   Existing windows do not retroactively inherit it; open a new window or restart tmux to refresh them.

3. Reboot (or log out and back in) to confirm the new value survives a fresh login via the LaunchAgent.

## Uninstall

```sh
bin/fm-oauth-token-install.sh --uninstall
```

This unloads the agent, removes the plist from `~/Library/LaunchAgents/`, and `launchctl unsetenv`s the token from the user domain.
The secure source (token file or secret store) is left untouched.

## Status

```sh
bin/fm-oauth-token-install.sh --status
```

Reports the template path, whether the plist is installed and rendered, whether the token is present in the launchd user domain, and whether the secure source is resolvable.

## Security notes

- The token value is never committed, logged, or echoed by the helper in its default `--setenv` mode.
- `launchctl setenv VAR value` exposes the value in the process list briefly while the call runs.
  This is inherent to `launchctl` and the standard login-time approach; the helper calls it once at login and never otherwise prints the value.
- The `--print` and `--export` modes do emit the token to stdout by design, for operator use during manual refresh or sourcing.
  Never run them in a context where stdout is captured into a committed file or shared log.
- The committed plist template contains only placeholders and a reference to the helper, never a token.
- A token file with permissions looser than `0600` produces a stderr warning but still resolves, so a one-time setup mistake does not silently break agents.

## Troubleshooting

- **New shell does not see the token.** Run `bin/fm-oauth-token-load.sh --check`; if absent, re-run `--install` or `--setenv`. If present in the domain but missing from the shell, the shell was started before the agent ran; open a fresh terminal.
- **tmux windows still see the old token after rotation.** The helper pushes the new value to the tmux server's global environment, but existing windows do not retroactively inherit it. Open a new tmux window, or restart the tmux server after rotating.
- **SSH login shells do not see the token.** `launchctl setenv` populates the GUI/aqua session domain, which non-GUI SSH login shells do not inherit. For SSH coverage, also source the token in your shell rc from the same secure source, e.g. `eval "$(bin/fm-oauth-token-load.sh --export)"` in `~/.zshrc` / `~/.bashrc` (guarded by the source existing).
- **`launchctl load` is deprecated.** On newer macOS the installer may emit a deprecation warning; it is harmless and the load still succeeds. The unload/load commands remain functional across current macOS versions.
- **First agent run failed after install.** The installer loads the agent first, then runs the helper once. If the helper fails (e.g. the secure source is not populated yet), the agent is still installed and will succeed at the next login once the source is ready. Check `~/Library/Logs/firstmate/oauth-token.err.log`.

## Integration with firstmate conventions

This mechanism follows the repo's `bin/` conventions: plain bash helpers with usage headers, a committed plist template under `bin/launchd/`, behavior tests at `tests/fm-oauth-token.test.sh`, and no change to firstmate's session-start or supervision machinery.
It is a one-time OS-level setup step, not something bootstrap manages; the captain installs it once per Mac.
