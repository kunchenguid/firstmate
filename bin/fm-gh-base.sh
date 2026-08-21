#!/usr/bin/env bash
# Pin a clone's `gh`/`gh-axi` PR base to its OWN origin, never a fork's upstream
# parent. `gh pr create` defaults a FORK's base repo to the upstream parent when
# the clone has no gh default-repo set; ephemeral worktrees inherit clone config,
# so a bare `gh pr create` from any worktree then opens the PR against upstream.
# Setting `remote.origin.gh-resolved=base` once on the clone makes gh treat origin
# as the base repo, so every worktree's PR targets origin without needing --repo.
# Idempotent; harmless for non-forks, decisive for forks. It only affects
# `gh pr create`, which local-only projects never run, so it changes no other
# behaviour. Call it after any clone and on the backfill/sync pass.
# No-ops (exit 0) on a clone with no origin remote - there is no PR base to pin.
# Usage: fm-gh-base.sh <clone-dir>
set -eu

DIR=${1:?usage: fm-gh-base.sh <clone-dir>}
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "fm-gh-base: not a git repo: $DIR" >&2; exit 1; }
git -C "$DIR" remote get-url origin >/dev/null 2>&1 || exit 0
git -C "$DIR" config remote.origin.gh-resolved base
