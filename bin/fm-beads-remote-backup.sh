#!/usr/bin/env bash
# fm-beads-remote-backup.sh - verify and repair the fleet task store's off-box
# Dolt copy on mini1.
#
# WHAT IT IS
# ----------
# The routine durability check for the one private Dolt remote the captain
# approved: the `mini1` SQL remote served by mini1's dolt sql-server
# remotesapi on port 3310 over Tailscale. `--verify` is read-only and answers
# whether the backup is currently reachable and correctly wired. `--repair`
# additionally converges the wiring (re-add a missing remote entry, commit the
# working set, push this machine's commits, confirm both ends share one head).
# Every outcome is one `BEADS_BACKUP:` line, so a caller can relay them as its
# own diagnostics without re-spelling any of them.
#
# WHAT IT IS NOT
# -------------
# This script never invents a destination: the remote name and URL below are
# the approved off-box copy, and a present entry pointing anywhere else is
# reported, never overwritten. It never creates an `origin` remote, because
# Dolt's implicit default remote is exactly what this store has never had. It
# never holds the mesh password: the credential is read from the Dolt server's
# own environment by `dolt_push`/`dolt_fetch`. It never runs `bd init`, never
# passes `--force` to any push, never removes a remote, and never drops a
# database, because any of those could discard history the local store is the
# single authority for.
# Rebuilding a corrupt remote copy from the authority (quarantine with a file
# backup, reseed, re-verify) stays a documented manual procedure exactly
# because it needs that judgment; see docs/beads-sync-topology.md.
# [`docs/beads-sync-topology.md`](../docs/beads-sync-topology.md) owns the why
# (single write authority, best-effort durability) and points here for the how.
#
# CALLERS
# -------
# `bin/fm-bootstrap.sh`'s beads sync sweep calls `--repair` for the routine
# pass, and `bin/fm-tasks-axi-lib.sh`'s `fm_beads_sync_once` delegates its WHOLE
# remote leg to that same `--repair` call rather than reimplementing the
# server-side push. That delegation is why the routine sweep needs no remote
# name of its own: this script is the single definition of the destination, the
# credential path, and the head test, so the two paths cannot disagree.
# The sweep bounds this call with fm_run_timed, so this script takes no step
# timeout of its own except the HTTP reachability probe
# (`FM_BEADS_BACKUP_PROBE_TIMEOUT`, default 10 seconds): every other step runs
# to completion and the caller owns the bound. Standalone runs inherit the
# same contract and should themselves run under `timeout` when a bound matters.
#
# OUTCOMES
# --------
# This script is the single owner of the `BEADS_BACKUP:` vocabulary; a caller
# relays these payloads rather than re-spelling them. The terminal outcome on
# success is `pushed-verified:` when the wiring was already correct, or
# `repaired:` followed by `repaired-verified:` when a missing remote entry had
# to be re-added first. A head that cannot be read is `unverified:`, which is
# deliberately distinct from `diverged:`.
#
# EXIT STATUS
# -----------
# 0 means healthy (`--verify`) or converged and verified (`--repair`). 1 means
# something still needs an operator, named by its own failure outcome: a missing
# or mismatched remote entry, an unreachable remote, a push that failed or could
# not be verified, diverged heads, or a commit that left this home's writes
# stranded in the Dolt working set (`commit-failed:`).
# A stranded working set is never a silent success even when the push itself
# succeeded, because the durability gap that commit step exists to close is still
# open.
#
# ENVIRONMENT OVERRIDES (used by tests/fm-beads-remote-backup.test.sh)
# --------------------------------------------------------------------
# FM_BEADS_BACKUP_TASK_BIN  task CLI to drive (default: task).
# FM_BEADS_BACKUP_CURL_BIN  curl binary for the reachability probe (default: curl).
# FM_BEADS_BACKUP_REMOTE_NAME / FM_BEADS_BACKUP_REMOTE_URL: the approved copy.
# FM_BEADS_BACKUP_USER      Dolt user the mesh authenticates as (default: brainsync).
#                           The password is never a script input: it comes from
#                           the dolt server's own environment, as it does for
#                           every other mesh operation.
set -uo pipefail

TASK_BIN=${FM_BEADS_BACKUP_TASK_BIN:-task}
CURL_BIN=${FM_BEADS_BACKUP_CURL_BIN:-curl}
REMOTE_NAME=${FM_BEADS_BACKUP_REMOTE_NAME:-mini1}
REMOTE_URL=${FM_BEADS_BACKUP_REMOTE_URL:-http://100.102.238.78:3310/tasks}
MESH_USER=${FM_BEADS_BACKUP_USER:-brainsync}
PROBE_TIMEOUT=${FM_BEADS_BACKUP_PROBE_TIMEOUT:-10}

say() { printf 'BEADS_BACKUP: %s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: fm-beads-remote-backup.sh [--verify|--repair|--help]

Verify or repair the fleet task store's off-box Dolt copy on mini1.
--verify is read-only; --repair additionally re-adds a missing remote entry,
commits the working set, pushes, and confirms one shared head. Never runs
bd init, never force-pushes, never removes a remote, never drops a database.
EOF
}

MODE=verify
for arg in "$@"; do
  case "$arg" in
    --verify) MODE=verify ;;
    --repair) MODE=repair ;;
    --help | -h) usage; exit 0 ;;
    *) say "unknown argument: $arg"; usage >&2; exit 1 ;;
  esac
done

command -v "$TASK_BIN" >/dev/null 2>&1 || { say "missing: task CLI not found ($TASK_BIN)"; exit 1; }
command -v "$CURL_BIN" >/dev/null 2>&1 || { say "missing: curl binary not found ($CURL_BIN)"; exit 1; }

if ! "$TASK_BIN" sql "select 1" >/dev/null 2>&1; then
  say "unreachable: the local task store does not answer a read; repair the store before its backup"
  exit 1
fi

REMOTE_LIST=$("$TASK_BIN" dolt remote list 2>&1) || {
  say "unreadable: 'task dolt remote list' failed, so a configured remote is indistinguishable from none"
  exit 1
}
HAVE_URL=$(printf '%s\n' "$REMOTE_LIST" | awk -v name="$REMOTE_NAME" '$1 == name { print $2; exit }')
WAS_REPAIRED=0
COMMIT_FAILED=0
if [ -z "$HAVE_URL" ]; then
  if [ "$MODE" = verify ]; then
    say "no-remote: no '$REMOTE_NAME' Dolt remote configured, so this store is single-machine only"
    exit 1
  fi
  if ! "$TASK_BIN" dolt remote add "$REMOTE_NAME" "$REMOTE_URL" >/dev/null 2>&1; then
    say "repair-failed: could not add the '$REMOTE_NAME' Dolt remote"
    exit 1
  fi
  say "repaired: re-added the '$REMOTE_NAME' Dolt remote ($REMOTE_URL)"
  WAS_REPAIRED=1
  HAVE_URL=$REMOTE_URL
elif [ "$HAVE_URL" != "$REMOTE_URL" ]; then
  say "remote-url-mismatch: '$REMOTE_NAME' points at $HAVE_URL, not the approved $REMOTE_URL; leaving it alone"
  exit 1
fi

HTTP_CODE=$("$CURL_BIN" -s -m "$PROBE_TIMEOUT" -o /dev/null -w "%{http_code}" "$REMOTE_URL" 2>/dev/null) || HTTP_CODE=000
if [ "$HTTP_CODE" = "000" ]; then
  say "unreachable-remote: '$REMOTE_NAME' ($REMOTE_URL) did not answer; sync stays best-effort until the transport recovers"
  exit 1
fi

# Reads one head hash through the store CLI, returning the 32-character hash
# from whatever the query printed and nothing at all when it printed none.
remote_head_sql() { # <sql>
  "$TASK_BIN" sql "$1" 2>/dev/null | grep -E '^[a-z0-9]{32}$' | head -1
}

if [ "$MODE" = verify ]; then
  LOCAL_HEAD=$(remote_head_sql "select hash from dolt_branches where name='main'")
  say "ok: '$REMOTE_NAME' is configured at $REMOTE_URL and answers (local main ${LOCAL_HEAD:-unknown})"
  exit 0
fi

# `task dolt commit` exits 0 whether it committed or found a clean working set,
# so a non-zero status is reported as a commit failure and a clean working set is
# silent. The CLI's own first output line is carried into the diagnostic, because
# a non-zero commit leaves this home's writes stranded in the Dolt working set and
# the reason is the only actionable part of that outcome.
if ! COMMIT_OUT=$("$TASK_BIN" dolt commit 2>&1); then
  say "commit-failed: 'task dolt commit' exited non-zero; continuing to push previously committed work: $(printf '%s' "$COMMIT_OUT" | head -1)"
  COMMIT_FAILED=1
fi

# The push goes through the Dolt server's own mesh credential via `dolt_push`.
# A client-side `task dolt push --remote` cannot do this: it has no mesh
# credential and fails with `root has not been granted CLONE_ADMIN`.
if ! PUSH_OUT=$("$TASK_BIN" sql "call dolt_push('$REMOTE_NAME','main','--user','$MESH_USER')" 2>&1); then
  say "push-failed: 'dolt_push' to '$REMOTE_NAME' failed: $(printf '%s' "$PUSH_OUT" | head -1)"
  exit 1
fi

if ! "$TASK_BIN" sql "call dolt_fetch('$REMOTE_NAME','main','--user','$MESH_USER')" >/dev/null 2>&1; then
  say "pushed-unverified: push to '$REMOTE_NAME' returned ok but the post-push fetch failed, so head equality is unconfirmed"
  exit 1
fi
# Head equality is read from Dolt's own catalogs, and the REMOTE-tracking branch
# lives in `dolt_remote_branches`, NOT in `dolt_branches`: a `dolt_branches`
# lookup for 'remotes/<remote>/main' answers zero rows on a real store, so
# comparing against it made every correctly pushed head look diverged. The
# fallback covers a store that exposes only the older location.
#
# "The remote disagrees" and "I could not read the remote head" are opposite
# facts and never collapse into one another here: an unreadable head is reported
# as unverified, because reporting it as divergence would send an operator
# hunting a difference that may not exist, and never force-pushing is exactly
# what makes that mistake expensive.
LOCAL_HEAD=$(remote_head_sql "select hash from dolt_branches where name='main'")
REMOTE_HEAD=$(remote_head_sql "select hash from dolt_remote_branches where name='remotes/$REMOTE_NAME/main'")
[ -n "$REMOTE_HEAD" ] || REMOTE_HEAD=$(remote_head_sql "select hash from dolt_branches where name='remotes/$REMOTE_NAME/main'")
if [ -z "$LOCAL_HEAD" ] || [ -z "$REMOTE_HEAD" ]; then
  say "unverified: could not read both heads after a successful push (local ${LOCAL_HEAD:-unknown}, '$REMOTE_NAME' ${REMOTE_HEAD:-unknown}), so head equality is unconfirmed"
  exit 1
fi
if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
  if [ "$WAS_REPAIRED" = 1 ]; then
    say "repaired-verified: '$REMOTE_NAME' now shares local main ($LOCAL_HEAD)"
  else
    say "pushed-verified: '$REMOTE_NAME' now shares local main ($LOCAL_HEAD)"
  fi
  exit "$COMMIT_FAILED"
fi
say "diverged: '$REMOTE_NAME' main (${REMOTE_HEAD:-unknown}) differs from local main (${LOCAL_HEAD:-unknown}); needs an operator, never a force-push"
exit 1
