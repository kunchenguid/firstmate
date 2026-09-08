# Running Firstmate on Windows

Audience: operator, current behavior.

Firstmate runs natively on Windows under Git Bash or MSYS2.
It does not need WSL, and it is not run through WSL.
Everything below assumes a 64-bit x86 Windows 10 or 11 host and the Git Bash shell that ships with Git for Windows.

The supported runtime backend on Windows is Herdr.
The reference tmux backend has no native Windows build, so tmux is not an option here.
[`herdr-backend.md`](herdr-backend.md) owns that backend's own setup, safety boundaries, and limits, and this page owns only what Windows changes.

## What Firstmate is

Firstmate is an agent distro: a cloned repository of instructions, skills, and helper scripts that turns a general-purpose coding agent into a fleet supervisor.
You talk to one agent, the first mate, and it dispatches autonomous workers into isolated git worktrees, supervises them to completion, and hands back finished pull requests, approved local merges, or standalone investigation reports.
Firstmate itself has no installer and ships no binary of its own, because the clone is the distro, and launching a supported agent harness inside it is what instantiates your first mate.
It does depend on separately installed tools, which is what the install section below is for.

[`../README.md`](../README.md) owns the full description and feature list, and [`architecture.md`](architecture.md) owns the architecture.
This page owns only what Windows changes.

## Install

### Before you start

- Git for Windows, which provides the Git Bash shell this page assumes and the required `jq`, `perl`, and `unzip`.
- The GitHub CLI, authenticated with `gh auth login`.
- A verified primary agent harness; the README's "Recommended harnesses" section owns that choice.
- `python3` is optional, and affects only the entries under "Supported limits" below.

Herdr, Treehouse, ShellCheck, and actionlint are installed by this repository's own scripts under "Toolchain" below rather than by a package manager.

### Steps

Run every step from Git Bash, not from PowerShell or `cmd`.

1. Clone the branch that carries this support, and pin its line endings.

   The Windows support described here is not in the upstream repository yet, so a clone of `kunchenguid/firstmate` does not carry it.
   It lives on the `windows` branch of the fork below.

   ```sh
   gh auth login
   git clone -b windows https://github.com/nathan-rosquist/firstmate
   cd firstmate
   git config --local core.autocrlf false
   ```

2. Confirm `MSYS=winsymlinks:sys` is live, using the probe under "The one setting you must get right" below.
   Nothing else on this page holds if that probe returns empty.

3. Install the pinned tools, under "Toolchain" below, into one directory, and add that directory to `PATH`.

4. Point Herdr's default pane shell at Git Bash, under "Herdr pane shell" below.

5. Select Herdr as the runtime backend by writing `herdr` into `config/backend`.
   [`configuration.md`](configuration.md) owns that file and every other configuration knob.

### Or hand the setup to Claude Code

Start `claude` in the directory you want the clone to live in, and paste this:

```text
Set up firstmate on this Windows machine, natively under Git Bash, without WSL.
Treat docs/windows.md in the cloned repository as the authoritative source and do not improvise around it.
Clone the windows branch specifically: git clone -b windows https://github.com/nathan-rosquist/firstmate - the upstream kunchenguid repository does not carry Windows support yet, so do not substitute it.
Set core.autocrlf=false locally, and verify MSYS=winsymlinks:sys is live with that page's symlink probe before continuing.
Install the pinned tools with bin/fm-install-herdr.sh, bin/fm-install-treehouse.sh, bin/fm-install-shellcheck.sh, and bin/fm-install-actionlint.sh into one directory, then tell me the PATH line to add.
Set Herdr's default pane shell to Git Bash in %APPDATA%/herdr/config.toml, and select the herdr backend in config/backend.
Stop and ask me before installing anything outside that list.
Report what you did, what you skipped, and anything that failed.
```

## Run

Start the session from Git Bash inside the clone.

```sh
cd firstmate
claude
```

Substitute your own harness's launch command; the README owns the per-harness form and the one-time trust step each of them needs.

`AGENTS.md` takes over from there.
A new session's first act is its own startup check, which reports missing tools, authentication problems, and any work already under way, and asks your consent before installing anything.

Then talk to it in plain language.

```text
> ahoy! clone my github project xyz and fix the flaky login test
```

On the reference platforms Firstmate clones the project under `projects/`, spawns a worker in its own Herdr tab and its own git worktree, supervises it, and reports the pull request URL when it is ready for you.

Three things differ here from those platforms:

- **A worker spawn does not yet complete on Windows.** Herdr reports the pane's own shell as the working directory rather than the foreground subshell, so the spawn never sees `treehouse get` reach the acquired copy and refuses at its deadline. Everything up to that point - cloning, the session lock, supervision, and the whole toolchain - does work. This is the one remaining gap, and "Supported limits" below records what causes it.
- Watch a worker with `bin/fm-peek.sh` and steer it with `bin/fm-send.sh`, because Herdr's `terminal attach` is unsupported on Windows.
- Keep `MSYS` intact in every session you launch, because a session without it supervises nothing and reports nothing, as described in the next section.

## The one setting you must get right

Set `MSYS=winsymlinks:sys` in the environment of every Firstmate process.

Firstmate's entire lock layer is built from symbolic links.
Under the Git Bash default, `ln -s` reports success and creates a **directory copy** instead of a link, so `readlink` returns nothing and no lock can ever be proved owned.
The failure is silent rather than loud: locks never succeed, the supervision cycle never starts, and a supervision checkpoint then reports a quiet fleet because it cannot tell "nothing happened" from "nothing ran".
Residue accumulates as ever-deeper `<lock>.steal.steal...` directories, which eventually exceed the Windows path limit.

The repository ships this variable in its `.claude/settings.json` environment block, so a Claude session started in a checkout that has it is already correct.
A home that predates that block must add it.
Confirm the setting is live before trusting supervision:

```sh
ln -s "$PWD" /tmp/fm-symlink-probe && readlink /tmp/fm-symlink-probe
```

A path on the second line means links work.
Empty output means they do not, whatever the exit status said.

Do not use `winsymlinks:nativestrict`.
Without Windows Developer Mode enabled it aborts the shell rather than degrading.

## Line endings

Git for Windows ships `core.autocrlf=true` in its system configuration, so a fresh clone checks every file out with CRLF line endings.
Shell scripts with CRLF fail to lint and fail to run.
This repository pins LF for tracked text through `.gitattributes`, and a clone should also carry `core.autocrlf=false` locally:

```sh
git config --local core.autocrlf false
```

An existing checkout that already has CRLF on disk keeps working, but convert it before running the linter there.

## Toolchain

Install the pinned tools with the repository's own installers rather than a package manager, so the versions and checksums match the ones CI verifies:

```sh
bin/fm-install-herdr.sh <destination-directory>
bin/fm-install-treehouse.sh <destination-directory>
bin/fm-install-shellcheck.sh <destination-directory>
bin/fm-install-actionlint.sh <destination-directory>
```

Each script header owns its exact release asset, checksum, download bound, and post-install version gate.
All four carry a Windows arm and select it from `uname`.

`jq`, `perl`, and `unzip` come with Git for Windows and are all required.
`python3` is optional and only affects the features named under "Supported limits" below.

The Herdr installer pins 0.8.2 on every platform because that is the earliest stable release carrying a Windows asset.
The Treehouse installer needed no version bump, because its existing pin already publishes Windows assets.

## Herdr pane shell

Set Herdr's default pane shell to Git Bash, in `%APPDATA%/herdr/config.toml`:

```toml
[terminal]
default_shell = "C:/Program Files/Git/usr/bin/bash.exe"
```

Check it with `herdr config check`.
Existing panes keep whatever shell they were created with, so recreate them after changing this.

This is not cosmetic.
Firstmate proves a pane's shell is idle and childless before closing it, and that proof only recognizes a real POSIX shell.
A PowerShell pane fails the proof permanently, which leaves quarantined workspaces behind on every cleanup.

A Herdr pane opens that shell without login mode, so `/etc/profile` never runs and the pane's `PATH` carries Git for Windows' `bin` directory, which holds only `bash`, `sh`, and `git`.
Firstmate exports its own `PATH` into each pane before the launch command for that reason; without it `env`, every `#!/usr/bin/env bash` script, and the agent binary itself are unresolvable there.
Nothing is required of you here beyond starting Firstmate from a normal Git Bash shell, because the pane inherits whatever that shell resolved.

Text Firstmate types into a pane crosses one more Windows boundary on the way.
The Herdr client is a native Windows program, so Git Bash rewrites any argument it reads as a POSIX path before that program receives it.
Left alone, a harness slash command such as `/exit` arrives in the pane as `C:/Program Files/Git/exit`, the agent never acts on it, and the send still looks like it succeeded.
Firstmate suppresses that rewriting for the calls whose payload is literal pane input, and leaves it in place for the calls that genuinely pass paths a native client must receive in native form.
Nothing is required of you here either.

The Windows `jq` build ends every line it writes with a carriage return.
A value Firstmate reads as a single line is unharmed, because the shell strips that ending whole; a read of several lines at once keeps a carriage return inside every line but the last, which then travels inside workspace, tab, and pane identifiers.
Firstmate filters those multi-line reads, so the same bytes come back on Windows as anywhere else.

## Supported limits

These are current, measured Windows limits rather than defects awaiting a fix.
Each degrades to a documented fallback rather than failing silently.

- Windows cannot host remote second mates, because it cannot serve as a `--remote` target.
- Herdr's `terminal attach` is unsupported, so use `bin/fm-peek.sh` and `bin/fm-send.sh` rather than attaching.
- Windows Python has no `AF_UNIX`, so native event subscription and presentation-space ordering fall back to polling and flat placement.
- A `noacl` NTFS mount cannot create a directory at mode 700, so the presentation lock namespace accepts the mode it can get after probing for the capability, while its directory, symbolic-link, and owner checks stay unconditional on every platform.
- MSYS `ps` supports no `-o` selectors, so process reads are served from `bin/fm-winproc-lib.sh` in native Windows process-id space, and signalling uses `/usr/bin/kill -W` by absolute path because the shell builtin has no `-W` flag.
- `/usr/bin/kill -W` cannot address a process outside the MSYS runtime at all. That is a safety property rather than a gap, because the signalling path can never reach a process the adapter did not itself resolve.
- Herdr's pane working directory on Windows tracks the pane's own shell and not a foreground subshell, so the spawn-time worktree wait never observes `treehouse get` moving into the acquired copy. A crewmate or scout spawn on the Herdr backend therefore still refuses at its deadline on this platform. That refusal is the isolation guard working, not a silent failure, and it is the one remaining Windows gap on this page.
- The downloaded binaries are unsigned, so SmartScreen may warn if they are launched from Explorer. Fetching them with the installers above does not mark them, so they run without a prompt.

## Verification entry points

The Windows lane's measured evidence, including the exact live-suite results and the four adapter paths that carry the platform's differences, lives in [`verification/runtime-backends.md`](verification/runtime-backends.md#windows-x86_64).

Run the linter before treating any script change as done:

```sh
bin/fm-lint.sh
```

It refuses to run under any ShellCheck or actionlint version other than its pins, which the installers above provide.

## Troubleshooting

**A session reports that it cannot locate the harness process in its ancestry, and stays read-only.**
The session lock walks the process ancestry, which needs the Windows process bridge in `bin/fm-winproc-lib.sh`.
A checkout that does not carry that file cannot take the lock and correctly refuses to mutate anything.
Update the checkout rather than working around the refusal.

**Supervision reports a quiet fleet while work is clearly outstanding.**
Check the symbolic-link probe under "The one setting you must get right".
A supervision checkpoint cannot distinguish a completed quiet cycle from a cycle that never started, so a broken lock layer presents as silence.

**The linter reports failures on files you did not touch.**
Check for CRLF line endings first, under "Line endings".

**A spawn refuses because the pane never entered an isolated worktree.**
Treehouse must be installed and on `PATH`, and the project must have a Treehouse pool; `treehouse status` reports the pool for the repository it is run in.
If both are in order, this is the known Herdr pane working-directory limit under "Supported limits" rather than a local misconfiguration.
