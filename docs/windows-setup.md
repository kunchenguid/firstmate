# Windows setup

Firstmate runs natively on Windows 10 and 11 (x64) inside Git Bash, with Claude Code as the primary harness and Herdr's Windows preview as the runtime backend.
No WSL, Linux host, or virtual machine is needed.
This page covers setup and current limits; macOS and Linux users follow the [Quick Start](../README.md#quick-start) instead.

## 1. Base tools

Install these first, then open a new terminal so `PATH` picks them up:

- [Git for Windows](https://git-scm.com/download/win), which provides Git Bash; firstmate's scripts run in it.
- [Node.js](https://nodejs.org/) LTS, for the npm-installed tools below.
- The [GitHub CLI](https://cli.github.com/), then `gh auth login`.
- `jq`, for example `winget install jqlang.jq`.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) for Windows.

## 2. Symlinks and line endings

Firstmate tracks one symlink, `.claude/skills`, which is how Claude Code finds firstmate's bundled skills, and that link is what needs real symlinks and Developer Mode.
Firstmate's directory locks do not: on Windows they use atomic directory creation instead of symlinks.
Git for Windows disables symlinks by default and converts line endings, and both break firstmate.

1. Turn on Windows Developer Mode: Settings, then System, then For developers, then Developer Mode.
2. In Git Bash, make symlinks the default and have MSYS create real ones:

   ```sh
   git config --global core.symlinks true
   setx MSYS winsymlinks:nativestrict
   ```

3. Close and reopen every terminal, so the `MSYS` setting reaches new shells.

## 3. Clone

Clone with symlinks on and line-ending conversion off for this repository:

```sh
git clone -c core.symlinks=true -c core.autocrlf=false https://github.com/kunchenguid/firstmate
cd firstmate
readlink .claude/skills
```

`readlink` must print `../.agents/skills`.
If it prints nothing, the skills link was checked out as a plain file; repair it with:

```sh
git config core.symlinks true
git checkout -- .claude/skills
```

## 4. Firstmate's tools

The npm tools install directly:

```sh
npm install -g gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi
gh-axi setup hooks
chrome-devtools-axi setup hooks
lavish-axi setup hooks
```

The `treehouse` and `no-mistakes` install scripts refuse Windows, but both projects publish official Windows builds.
Install them into `~/bin`, which Git Bash puts on `PATH`, checking each download against the release checksums:

```sh
mkdir -p ~/bin
for r in treehouse no-mistakes; do
  (cd "$(mktemp -d)" &&
    gh release download -R "kunchenguid/$r" -p '*windows-amd64.zip' -p checksums.txt &&
    sha256sum -c --ignore-missing checksums.txt &&
    unzip -o "$r"-*-windows-amd64.zip -d ~/bin)
done
treehouse --version
no-mistakes --version
```

Contributors who run `bin/fm-lint.sh` also need its pinned ShellCheck and actionlint builds; `bin/fm-lint.sh --required-version` prints the ShellCheck pin, and both projects publish Windows release archives.
`bin/fm-doc-audience-check.sh` needs a real Python 3, not the Microsoft Store placeholder that `python3` resolves to on a fresh Windows install.

## 5. Herdr and first launch

Install Herdr's Windows preview from PowerShell:

```powershell
irm https://herdr.dev/install.ps1 | iex
```

Herdr opens new panes in PowerShell by default, but firstmate types POSIX commands into each worker pane and needs the Git Bash PATH there.
Add this to `%APPDATA%\herdr\config.toml`, then run `herdr config check` and `herdr server reload-config`:

```toml
[terminal]
default_shell = "C:/Program Files/Git/bin/bash.exe"
shell_mode = "login"
```

Start Herdr, open a pane, and launch Claude Code from the firstmate checkout:

```sh
cd firstmate
claude
```

Firstmate detects the Herdr runtime automatically; see [the Herdr backend](herdr-backend.md) for backend behavior.
On first start it checks its toolchain and offers to install anything still missing.
The session-start summary must not show a read-only banner; if it does, the banner names the reason.

## Current limits

- Herdr is the only backend with Windows support; the tmux, Zellij, Orca, and cmux backends have none.
- Git Bash mounts drives without POSIX permission bits, so the herdr presentation lock and process-event state directories are accepted on ownership alone there, relying on the per-user `%TEMP%` ACL, and so are custom monitoring check shims, such as the mail check, and pull-request poll sidecars; Relay's private artifact and poll shim mode checks still refuse.
- There is no `lsof`, so an abandoned lock or worktree is not reclaimed automatically and needs manual cleanup.
- no-mistakes runs the repository's lint command through `cmd.exe`, which cannot run `bin/fm-lint.sh`, so its lint step reports a failure on Windows; run `bin/fm-lint.sh` in Git Bash and approve the step only when it passes.
- `bin/fm-install-actionlint.sh` refuses Windows; install actionlint's Windows release archive by hand.
- Only Claude Code is exercised as the primary harness on Windows; the Pi and OpenCode Windows timeouts are listed in [the configuration reference](configuration.md).
