---
name: global-agent-guardrails
description: >-
  Agent-only reference for a harness-independent denylist of catastrophic shell commands (rm -rf on / or ~, dd/mkfs, sudo rm, fork bombs, curl|sh, git push --force, gh repo/release/secret delete), adapted for Linux/WSL2 with a Bash test suite - NOT wired into any firstmate hook yet.
  Load before evaluating, tuning, or wiring this denylist into a harness hook, or when a captain or crewmate asks about a dangerous-command guard for this fleet.
user-invocable: false
metadata:
  internal: true
---

# global-agent-guardrails

Reviewed reference material adapted from `davidondrej/skills`' `ops-and-setup/global-agent-guardrails` (see that scout's report at `data/skillscan-davidondrej/report.md` §2.2 for the original).
It is a "bouncer" that blocks catastrophic shell commands before they run, checked against a shared regex denylist - a seatbelt against accidents, not a sandbox against a genuinely malicious agent (obfuscation such as a Python `shutil.rmtree` call can slip past a regex).

## Status: reference only, not wired

`scripts/deny-dangerous.sh` and `scripts/test-guard.sh` are real, working, and pass their full test suite (190/190) against `scripts/dangerous-patterns.txt`, but nothing in this fleet invokes them yet.
No firstmate primary, crewmate, or secondmate hook currently calls this guard.
Treat this skill as candidate material for a future wiring task, not as an active safety layer - do not tell the captain a command guard is protecting the fleet until that wiring lands and is verified.

## Why wiring is out of scope here

Wiring this into a real hook is a `firstmate-coding-guidelines` "Harness-dependent checks" item: each target harness's hook surface is something the vendor emits (a settings file shape, a trust/hash gate, an event name), so the guard's actual blocking behavior must be proven end to end against the real harness, not assumed from reading its docs.
`harness-adapters` already documents, per verified adapter, how much per-harness surface this is - Claude and Codex Stop/PreToolUse hooks, Grok's hash-pinned project hook trust, Pi's extension trust-once model, OpenCode's plugin lifecycle, and Kimi's global hook registry are each independently verified facts with their own dated evidence in `docs/turnend-guard.md` and `docs/arm-pretool-check.md`.
Wiring this denylist for real needs the same per-harness empirical proof, plus a portable regression test and a live-harness-optin guard per `firstmate-coding-guidelines`, for every verified harness this fleet actually spawns crewmates on (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`; `muse` has no hook surface at all per `harness-adapters`).
That is a materially bigger lift than porting and Linux-adapting the denylist itself, so it is intentionally not attempted in this pass; see the open `needs-decision` this task recorded for what that follow-up would take.

## What changed from upstream for Linux/WSL2

- `dangerous-patterns.txt`: replaced the macOS `/Users` rm-target pattern with `/home` (native Linux) and `/mnt/<drive>/Users` (a WSL2-mounted Windows user folder); replaced the macOS-only `diskutil` disk-destroyer pattern with Linux equivalents (`wipefs -a`, `parted`/`sgdisk --zap-all`, `blkdiscard`); the existing `dd`/`mkfs`/raw-device patterns were already OS-agnostic.
- `deny-dangerous.sh`: dropped the macOS Homebrew `PATH` prefix (`/opt/homebrew/bin`); resolves `dangerous-patterns.txt` relative to its own script directory by default (override with `FM_GUARD_PATTERNS_FILE`) instead of assuming a fixed `~/.agents/hooks/` install layout, since this copy is not installed anywhere yet.
- `test-guard.sh`: same relative-path resolution for the guard script under test; block/allow cases updated for the Linux-adapted patterns (`/home`, `/mnt/c/Users`, `wipefs`, `sgdisk`, `blkdiscard`, `mkfs.ext4`/`/dev/sda` in place of macOS disk identifiers); genericized the upstream author's personal repo name in `gh` test fixtures to a placeholder.
- Both scripts remain payload-compatible with Claude/Codex/Grok's `.tool_input.command` / `.toolInput.command` shape and Cursor's `.command` + JSON-deny shape, since that is about the calling convention, not the OS; only firstmate's own verified harnesses matter for an eventual wiring task.

## Design rule (unchanged from upstream, worth preserving)

Block only irreversible or catastrophic commands - data loss, disk wipe, repo deletion, credential exfiltration.
Leave locally destructive but recoverable commands alone (`git clean -fdx`, `rm -rf node_modules`, `git status`) - over-blocking kills agent usefulness, which is a real cost, not a hypothetical one.

## Verifying this reference material

```bash
.agents/skills/global-agent-guardrails/scripts/test-guard.sh          # expect: passed: 190, failed: 0
echo '{"tool_input":{"command":"rm -rf /"}}' | .agents/skills/global-agent-guardrails/scripts/deny-dangerous.sh; echo "exit=$?"   # expect exit=2
```

Both scripts are `shellcheck`-clean at the pinned version (`bin/fm-lint.sh`'s `REQUIRED_SHELLCHECK`), verified by explicit-path invocation since `.agents/skills/` is outside `fm-lint.sh`'s canonical `bin/`/`tests/` file set.

## Adding or tuning a pattern

1. Edit `scripts/dangerous-patterns.txt` in POSIX ERE (`grep -E`); use `[[:space:]]`, not `\s`.
2. Add matching block/allow cases to `scripts/test-guard.sh`, then run it - it must pass 100%.
3. Re-run the two verification commands above.
