# Kill guard

Literal PID kills use the caller's existing descendant/worktree ownership rule.
The primary Main session additionally may signal fleet processes outside its own tree.
Workers and leads retain the ordinary ownership rule.
PID 1, the systemd user manager, herdr server, no-mistakes daemon, sshd, tailscaled and interactive shells remain protected for every caller, including their parent.
All `pkill` and `killall` commands are refused; use a literal PID.

Main approval requires the guard's actual process ancestry to reach the supplied caller and the live harness PID recorded in `~/firstmate/state/.lock`.
The account home comes from the OS account record, ignoring `HOME`, `FM_HOME` and other environment overrides.
The lock holder's resolved working directory must be under `~/firstmate`; a different harness in that ancestry outside the primary home disqualifies the allowance.
A missing, malformed, symlinked, dead or uncertain lock never grants it.
Environment variables and `--caller` alone cannot select Main.
The lock is same-user writable: this is a cooperative hook preventing accidental kills, not a security boundary against hostile programs running as that user.

Fleet ownership uses resolved cwd or absolute command-line paths under the primary home, `~/.treehouse/<pool>[/<slot>]/firstmate*`, or `~/.local/{share,bin}/fm-*` add-on tools.
Project worktrees also qualify when their resolved Git common directory is under the primary home's `projects/`.
Symlinks resolve before comparison and directory boundaries matter.
Process start time is read before and after identity collection, and checked again before Main approval.
There remains a PID-reuse window between hook approval and the shell's subsequent kill; the hook does not execute signals or hold a pidfd.

Each approved Main target appends a JSON line to `<guard directory>/state/main-kills.jsonl` (normally `~/.local/share/fm-kill-guard/state/main-kills.jsonl`) for Lookout Incidents.
Fields are `pid`, `starttime`, `cmdline` (argument array), `cwd`, `caller` (PID), and `reason`.
The hook CLI accepts `--reason <text>`; otherwise `FM_KILL_REASON`, then command text supplies the reason.
Only fleet paths, numeric PIDs, option names and a small set of operational words survive in command/reason fields; arbitrary values, prompts, URLs and credentials become `[redacted]`.
A failure to record the approval refuses the Main kill; commands rejected by policy create no approval rows.
Rows record approvals, not confirmation that the shell later delivered a signal.

Install with `kill-guard/install.sh` only after merging; it preserves the private audit directory across updates.
Without installing, verify with `node kill-guard/tests/main-allowance.test.mjs` and `bash kill-guard/tests/kill-guard.test.sh --guard-only`.
The first uses synthetic process trees plus one task-owned sleep; the second exercises the real CLI against only processes it starts.
