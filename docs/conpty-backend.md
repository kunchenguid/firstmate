# ConPTY backend

The ConPTY backend is the Windows-native terminal backend for the native core.
It gives each task a real pseudo-console via the Windows ConPTY API (through
`node-pty`), with a scrollback ring buffer, so the fleet gets genuine ANSI
output fidelity and interactive attach — the same model as tmux on POSIX.

## Why ConPTY

The bash fleet's backends (tmux, herdr, zellij, orca, cmux) are Unix terminal
multiplexers. None run natively on Windows. ConPTY is the Windows equivalent:
a kernel-level pseudo-console that interactive CLIs (including the coding-agent
harnesses) render into, exactly as if attached to a real terminal.

## Design

- `fm pty-host` (long-running per-home service) is the tmux-server analog.
  It exposes JSON-RPC over a Windows named pipe
  (`\\.\pipe\firstmate-<home>-pty`).
- Each task is a `node-pty.spawn(harnessCli, args, { useConpty: true, ... })`
  with a raw + ANSI-stripped scrollback ring buffer per session.
  `capture` mirrors `tmux capture-pane`.
- `fm attach <id>` connects over the pipe, replays the ring buffer, then
  bridges local stdin/stdout to the ConPTY — a Windows Terminal tab behaves
  like `tmux attach`.
- Agent-state classification ports the tmux classifier against captured
  output; the doorbell for `fm send` writes a constant line to the pty.
- Host autostart registers a logon scheduled task (`schtasks`); the host
  survives firstmate's own session restarts.
- Kill is node-pty `kill()` + job-object tree kill (taskkill fallback).

## Current implementation

The native core's `src/backend/conpty.ts` implements the ConPTY backend. It:

- refuses on non-Windows platforms (POSIX uses tmux/stdio);
- falls back to the stdio backend when `node-pty` is not installed;
- tracks an `exited` flag from the pty exit event for liveness.

## Enable

The ConPTY backend is the auto-detected default on Windows when `node-pty` is
installed. Override with:

```sh
FM_BACKEND=stdio        # force the stdio fallback
FM_BACKEND=conpty       # force ConPTY
```

## Verification

The behavior suite covers the stdio backend (used by tests) on all platforms.
Real-ConPTY smoke tests require a Windows runner with `node-pty` installed and
are self-skipping otherwise.
