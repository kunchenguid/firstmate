#!/usr/bin/env bash
# Ensure a no-mistakes-mode project's gate is initialized and its post-receive
# hook is current, so a crewmate pushing from its task worktree
# (git push no-mistakes <branch>) actually creates a pipeline run instead of
# failing the push with "invalid gate path".
#
# Why this exists: no-mistakes keys ONE gate per repo identity (the origin URL),
# shared by the main clone and every linked task worktree of it - there is
# no per-worktree gate, and `no-mistakes init` run inside a worktree just
# refreshes that one shared gate. The gate's post-receive hook is installed by
# `no-mistakes init`. An older no-mistakes installed a hook that passed a
# RELATIVE gate path (git runs hooks with a relative GIT_DIR, so it resolved to
# "."), which the daemon rejects with "invalid gate path: ."; no run is created
# and a later `rerun` then reports "no previous run for branch". Current
# no-mistakes passes an absolute path ("$(pwd)") and works, but that fix only
# lands on an already-initialized bare repo when init is re-run. `no-mistakes
# init` is idempotent ("Gate already initialized (refreshed)") and refreshes the
# hook and the no-mistakes remote, so running it here heals a stale gate before a
# crewmate ever pushes.
#
# This is the AGENTS.md section 6 sanctioned-init exception: it runs git
# remote/config setup inside the project but never edits, commits, or otherwise
# mutates project files. It is best-effort and non-fatal - a refresh failure
# warns to stderr but never blocks the caller, because the gate may already be
# healthy and the crewmate's own /no-mistakes run would surface a real problem.
#
# Mode-agnostic by design: the caller decides when a project is no-mistakes mode
# (fm-spawn calls this only for no-mistakes-mode ship tasks). Positive refreshes
# and ordinary skips print one concise status line to stdout; missing tooling and
# refresh failures warn to stderr.
# Usage: fm-nm-gate.sh <project-clone-dir>
set -eu

usage() {
  echo "usage: fm-nm-gate.sh <project-clone-dir>" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 1 ] || { usage; exit 2; }

DIR=$1
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 2; }
DIR=$(cd "$DIR" && pwd -P)

# Best-effort guards below: each prints a skip line and exits 0, because a gate
# that cannot be refreshed here is not a reason to block a spawn.

if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "nm-gate: skipped $DIR (not a git repository)"
  exit 0
fi

# no-mistakes init requires an origin remote to identify the gate; without one
# this is not a gate-backed clone (or it is local-only) and there is nothing to
# refresh.
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  echo "nm-gate: skipped $DIR (no origin remote)"
  exit 0
fi

if ! command -v no-mistakes >/dev/null 2>&1; then
  echo "nm-gate: skipped $DIR (no-mistakes not installed)" >&2
  exit 0
fi

# Refresh the gate. init keys off the origin URL, so running it in the main
# clone refreshes the one shared bare repo every worktree pushes to, repairing a
# stale post-receive hook in place.
if init_out=$(cd "$DIR" && no-mistakes init 2>&1); then
  echo "nm-gate: refreshed $DIR"
  exit 0
fi

echo "nm-gate: warning $DIR (no-mistakes init failed; gate may be stale)" >&2
printf '%s\n' "$init_out" >&2
exit 0
