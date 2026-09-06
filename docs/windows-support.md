# Windows support (native core)

The native TypeScript core runs firstmate on Windows without WSL, Git Bash, or
a Unix emulation layer. It is a from-scratch reimplementation of the bash fleet
orchestration in cross-platform Node + TypeScript, and it keeps working on
macOS and Linux.

## Status

The native core covers the full task lifecycle on Windows:

- `fm setup` — check and install the toolchain.
- `fm session-start` — the one-shot startup digest (lock, wake queue, fleet).
- `fm spawn` — create a task: isolated `git worktree`, task brief, harness session.
- `fm send` — steer a worker through its durable inbox with a doorbell.
- `fm control` — interrupt / exit / relaunch a worker.
- `fm teardown` — kill the session, remove the worktree, mark the task done.
- `fm attach` — attach the captain's terminal to a task session (ConPTY).
- `fm capture` — print a session's recent output.
- `fm watch` — the supervision watcher loop.
- `fm crew-state` — a task's current reconciled state.
- `fm backlog` / `fm status` — fleet and queue views.

Legacy names (`fm-send`, `fm-control`, ...) are accepted as aliases.

## Requirements

- Node.js 18+ (LTS 22 recommended).
- git and GitHub CLI (`gh`) on PATH.
- The npm axi tools: `tasks-axi`, `no-mistakes`, `gh-axi`, `lavish-axi`,
  `quota-axi`, `chrome-devtools-axi` (`npm install -g ...`).
- `node-pty` is a dependency for the ConPTY backend; `fm setup` validates it.
- A coding-agent harness on PATH: `claude`, `codex`, `opencode`, `pi`, `grok`,
  `kimi`, `cursor`, `muse`, or `cmdc` (Command Code). Command Code resolves as
  `cmdc`, then `command-code`, then `commandcode`; the bare `cmd` name is never
  used because it collides with the Windows shell.

## Backends on Windows

The terminal backend is auto-detected:

- **conpty** (default on Windows) — each task gets a real pseudo-console via
  ConPTY, with a scrollback ring buffer. `fm attach <id>` bridges your terminal
  (e.g. a Windows Terminal tab) to the session.
- **stdio** (fallback) — platform-agnostic child-process backend with an
  in-memory scrollback. Works everywhere; `fm attach` replays the buffer.
- **tmux** — POSIX-only; on Windows it is refused loudly.

Override with `FM_BACKEND=stdio` or `--backend stdio`.

See `docs/conpty-backend.md` for the ConPTY design.

## Path and environment notes

- `FM_HOME` selects the operational home (`data/`, `state/`, `config/`,
  `projects/`). Default: `~/.firstmate`.
- Paths are normalized for the host platform; Windows case-insensitive
  comparison is handled by `PathUtil`.
- Enable long paths (`git config --system core.longpaths true`) for deep
  worktrees under `projects/`.
- Windows Defender may need an exclusion for the pty-host binary and the
  `projects/` directory to avoid slow scans.

## Developing

```sh
npm install        # or pnpm install
npm run typecheck  # tsc --noEmit
npm run lint       # eslint src tests
npm test           # vitest run
npm run build      # tsc -> dist/
```

The test suite is hermetic: it uses the stdio backend and a fake harness, so it
runs on any platform without a real agent CLI or tmux.
