#!/usr/bin/env bash
# tests/fm-worktree-runtime-lib.test.sh - unit tests for
# bin/fm-worktree-runtime-lib.sh: what fm-spawn.sh copies into a task
# worktree (dev database, env files) and how it validates and writes an
# explicit BACKEND_PORT/FRONTEND_PORT pair firstmate already decided at
# intake to code/web/.ports.worktree. Synthetic project/worktree fixtures
# only, no real project clone and no spawn required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-runtime-lib.sh"

TMP=$(fm_test_tmproot fm-worktree-runtime) || fail "could not create temp root"
PROJ="$TMP/proj"
WT="$TMP/wt"
mkdir -p "$PROJ/code/web/backend/.wrangler/state/v3/d1" \
  "$PROJ/code/web/backend/.wrangler/state/v3/do" \
  "$PROJ/code/web/frontend" \
  "$WT"

# --- database copy skips backup snapshots -----------------------------------

echo 'active-db' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
echo 'stale-backup' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite.bak-before-merge"
mkdir -p "$PROJ/code/web/backend/.wrangler/state/v3/.bak-20260101"
echo 'stale-dir-backup' > "$PROJ/code/web/backend/.wrangler/state/v3/.bak-20260101/main.sqlite"
echo 'do-state' > "$PROJ/code/web/backend/.wrangler/state/v3/do/object.sqlite"
echo 'dev-vars' > "$PROJ/code/web/backend/.dev.vars"
echo 'front-env' > "$PROJ/code/web/frontend/.env"
echo 'front-env-prod' > "$PROJ/code/web/frontend/.env.production"

fm_worktree_runtime_provision "$WT" "$PROJ" "" ""

DEST="$WT/code/web/backend/.wrangler/state/v3"
[ "$(cat "$DEST/d1/main.sqlite" 2>/dev/null)" = active-db ] \
  || fail "active database file was not copied into the worktree"
pass "fm_worktree_runtime_provision copies the active database file"

[ ! -e "$DEST/d1/main.sqlite.bak-before-merge" ] \
  || fail "a *.bak-* database snapshot file was copied; it must be skipped"
pass "fm_worktree_runtime_provision skips a *.bak-* backup file"

[ ! -e "$DEST/.bak-20260101" ] \
  || fail "a .bak-* backup directory was copied; it must be pruned whole"
pass "fm_worktree_runtime_provision prunes a .bak-* backup directory"

[ "$(cat "$DEST/do/object.sqlite" 2>/dev/null)" = do-state ] \
  || fail "the durable-object state directory was not copied"
pass "fm_worktree_runtime_provision copies sibling state dirs (do/)"

# --- env files ---------------------------------------------------------------

[ "$(cat "$WT/code/web/backend/.dev.vars" 2>/dev/null)" = dev-vars ] \
  || fail ".dev.vars was not copied into the worktree"
pass "fm_worktree_runtime_provision copies backend/.dev.vars"

[ "$(cat "$WT/code/web/frontend/.env" 2>/dev/null)" = front-env ] \
  || fail "frontend/.env was not copied into the worktree"
[ "$(cat "$WT/code/web/frontend/.env.production" 2>/dev/null)" = front-env-prod ] \
  || fail "frontend/.env.production was not copied into the worktree"
pass "fm_worktree_runtime_provision copies frontend/.env and .env.production"

# --- absent inputs are a silent no-op, never a failure -----------------------

EMPTY_PROJ="$TMP/empty-proj"
EMPTY_WT="$TMP/empty-wt"
mkdir -p "$EMPTY_PROJ" "$EMPTY_WT"
fm_worktree_runtime_provision "$EMPTY_WT" "$EMPTY_PROJ" "" ""
rc=$?
[ "$rc" -eq 0 ] || fail "provisioning a project with none of this layout must not fail the spawn (exit $rc)"
[ ! -e "$EMPTY_WT/code" ] || fail "a project with no code/web layout must be left untouched"
pass "fm_worktree_runtime_provision is a silent no-op for a project with no code/web layout (e.g. firstmate's own worktrees)"

# --- explicit port pair: firstmate's decision, this library only validates/writes it --

PORTS_PROJ="$TMP/ports-proj"
mkdir -p "$PORTS_PROJ/code/web"
{
  printf 'BACKEND_PORT=8802\n'
  printf 'FRONTEND_PORT=5302\n'
} > "$PORTS_PROJ/code/web/.ports.main"

WT1="$TMP/ports-wt1"
mkdir -p "$WT1"
fm_worktree_runtime_provision "$WT1" "$PORTS_PROJ" 8902 5402
rc=$?
[ "$rc" -eq 0 ] || fail "a valid explicit port pair was refused (exit $rc)"
B1=$(fm_worktree_runtime_kv "$WT1/code/web/.ports.worktree" BACKEND_PORT)
F1=$(fm_worktree_runtime_kv "$WT1/code/web/.ports.worktree" FRONTEND_PORT)
[ "$B1" = 8902 ] && [ "$F1" = 5402 ] \
  || fail "the given explicit pair was not written verbatim to .ports.worktree (got backend=$B1 frontend=$F1)"
pass "fm_worktree_runtime_provision writes an explicit valid port pair verbatim"

# --- frontend/.env's VITE_BACKEND_URL is rewritten to the assigned backend port --

ENV_PROJ="$TMP/env-proj"
mkdir -p "$ENV_PROJ/code/web/frontend"
printf 'VITE_BACKEND_URL=http://localhost:8802\nOTHER_KEY=unchanged\n' > "$ENV_PROJ/code/web/frontend/.env"
printf 'VITE_BACKEND_URL=https://example.workers.dev\n' > "$ENV_PROJ/code/web/frontend/.env.production"

ENV_WT="$TMP/env-wt"
mkdir -p "$ENV_WT"
fm_worktree_runtime_provision "$ENV_WT" "$ENV_PROJ" 9001 9101
[ "$(fm_worktree_runtime_kv "$ENV_WT/code/web/frontend/.env" VITE_BACKEND_URL)" = "http://localhost:9001" ] \
  || fail "frontend/.env's VITE_BACKEND_URL was not rewritten to the assigned backend port"
[ "$(fm_worktree_runtime_kv "$ENV_WT/code/web/frontend/.env" OTHER_KEY)" = unchanged ] \
  || fail "rewriting VITE_BACKEND_URL must not disturb other lines in frontend/.env"
pass "fm_worktree_runtime_provision rewrites frontend/.env's VITE_BACKEND_URL to the assigned backend port"

[ "$(fm_worktree_runtime_kv "$ENV_WT/code/web/frontend/.env.production" VITE_BACKEND_URL)" = "https://example.workers.dev" ] \
  || fail "frontend/.env.production's VITE_BACKEND_URL must never be rewritten - it points at the real deployed backend, unrelated to any local dev port"
pass "fm_worktree_runtime_provision leaves frontend/.env.production untouched"

ENV_WT_NOPORTS="$TMP/env-wt-noports"
mkdir -p "$ENV_WT_NOPORTS"
fm_worktree_runtime_provision "$ENV_WT_NOPORTS" "$ENV_PROJ" "" ""
[ "$(fm_worktree_runtime_kv "$ENV_WT_NOPORTS/code/web/frontend/.env" VITE_BACKEND_URL)" = "http://localhost:8802" ] \
  || fail "frontend/.env's VITE_BACKEND_URL must be left as copied when no backend-port is given"
pass "fm_worktree_runtime_provision leaves VITE_BACKEND_URL untouched when no ports are given (no ports contract for this spawn)"

# --- both ports empty with a code/web layout present is a silent no-op -------

WT_NOPORTS="$TMP/ports-wt-noports"
mkdir -p "$WT_NOPORTS"
fm_worktree_runtime_provision "$WT_NOPORTS" "$PORTS_PROJ" "" ""
rc=$?
[ "$rc" -eq 0 ] || fail "both ports empty (no ports contract for this spawn) must not fail (exit $rc)"
[ ! -e "$WT_NOPORTS/code/web/.ports.worktree" ] \
  || fail "both ports empty must not write .ports.worktree"
pass "fm_worktree_runtime_provision is a silent no-op when both ports are empty"

# --- both ports empty on a RECYCLED worktree actively removes a stale
# .ports.worktree instead of leaving it (two recycled copies once inherited the
# same stale pair, gitignored so it survives worktree reuse) ------------------

WT_STALE="$TMP/ports-wt-stale"
mkdir -p "$WT_STALE/code/web"
{
  printf 'BACKEND_PORT=8907\n'
  printf 'FRONTEND_PORT=5408\n'
} > "$WT_STALE/code/web/.ports.worktree"
fm_worktree_runtime_provision "$WT_STALE" "$PORTS_PROJ" "" ""
rc=$?
[ "$rc" -eq 0 ] || fail "removing a stale .ports.worktree on a no-ports spawn must not fail (exit $rc)"
[ ! -e "$WT_STALE/code/web/.ports.worktree" ] \
  || fail "a stale .ports.worktree from a prior occupant must be actively removed, not left for a spawn with no port pair"
pass "fm_worktree_runtime_provision removes a stale .ports.worktree from a recycled worktree when no port pair is given"

# --- only one of the two ports given is refused -------------------------------

WT_ONE="$TMP/ports-wt-one"
mkdir -p "$WT_ONE"
ONE_ERR="$TMP/one.err"
fm_worktree_runtime_write_ports "$WT_ONE" "$PORTS_PROJ" 8903 "" 2>"$ONE_ERR"
rc=$?
[ "$rc" -ne 0 ] || fail "only backend-port given (frontend-port empty) must be refused, not silently accepted"
[ ! -e "$WT_ONE/code/web/.ports.worktree" ] || fail "a refused one-sided pair must not write .ports.worktree"
grep -q . "$ONE_ERR" || fail "a refused one-sided pair must print a clear error"
pass "fm_worktree_runtime_write_ports refuses when only one of backend-port/frontend-port is given"

# --- a non-integer or non-positive port value is refused ----------------------

WT_BAD="$TMP/ports-wt-bad"
mkdir -p "$WT_BAD"
for bad in "abc" "0" "-5" "8902.5"; do
  fm_worktree_runtime_write_ports "$WT_BAD" "$PORTS_PROJ" "$bad" 5403 2>/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "backend-port='$bad' must be refused as a non-positive-integer value"
  [ ! -e "$WT_BAD/code/web/.ports.worktree" ] || fail "a refused malformed pair must not write .ports.worktree"
done
pass "fm_worktree_runtime_write_ports refuses a non-integer or non-positive port value"

# --- a pair equal to each other is refused ------------------------------------

WT_SAME="$TMP/ports-wt-same"
mkdir -p "$WT_SAME"
fm_worktree_runtime_write_ports "$WT_SAME" "$PORTS_PROJ" 8904 8904 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] || fail "backend-port and frontend-port equal to each other must be refused"
[ ! -e "$WT_SAME/code/web/.ports.worktree" ] || fail "a refused same-port pair must not write .ports.worktree"
pass "fm_worktree_runtime_write_ports refuses a pair whose two values are equal"

# --- a pair equal to .ports.main's values is refused ---------------------------

WT_MAIN_COLLIDE="$TMP/ports-wt-main-collide"
mkdir -p "$WT_MAIN_COLLIDE"
fm_worktree_runtime_write_ports "$WT_MAIN_COLLIDE" "$PORTS_PROJ" 8802 5403 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] || fail "a backend-port equal to .ports.main's BACKEND_PORT must be refused"
[ ! -e "$WT_MAIN_COLLIDE/code/web/.ports.worktree" ] || fail "a refused main-collision pair must not write .ports.worktree"
pass "fm_worktree_runtime_write_ports refuses a pair colliding with .ports.main"

# --- a port that is already listening is refused, never silently swapped ------

LISTEN_PORT=41879
nc -l "$LISTEN_PORT" >/dev/null 2>&1 &
NC_PID=$!
trap 'kill "$NC_PID" 2>/dev/null; wait "$NC_PID" 2>/dev/null; fm_test_cleanup' EXIT
sleep 0.3
if lsof -nP -iTCP:"$LISTEN_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  WT_BOUND="$TMP/ports-wt-bound"
  mkdir -p "$WT_BOUND"
  fm_worktree_runtime_write_ports "$WT_BOUND" "$PORTS_PROJ" "$LISTEN_PORT" 5404 2>/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "a backend-port that is already listening must be refused, not silently swapped"
  [ ! -e "$WT_BOUND/code/web/.ports.worktree" ] || fail "a refused already-bound pair must not write .ports.worktree"
  pass "fm_worktree_runtime_write_ports refuses a port that is already listening"
else
  echo "note: could not confirm the test listener bound $LISTEN_PORT via lsof; skipping the already-listening assertion" >&2
fi
kill "$NC_PID" 2>/dev/null
wait "$NC_PID" 2>/dev/null
trap fm_test_cleanup EXIT

# --- fresh copy every spawn: a recycled worktree's stale content is replaced -

mkdir -p "$WT1/code/web/backend/.wrangler/state/v3/d1" \
  "$PROJ/code/web/backend/.wrangler/state/v3/d1"
echo 'stale-from-prior-crew' > "$WT1/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
echo 'active-db-refreshed' > "$PROJ/code/web/backend/.wrangler/state/v3/d1/main.sqlite"
fm_worktree_runtime_provision "$WT1" "$PROJ" "" ""
[ "$(cat "$WT1/code/web/backend/.wrangler/state/v3/d1/main.sqlite" 2>/dev/null)" = active-db-refreshed ] \
  || fail "a recycled worktree kept its stale database instead of a fresh copy"
pass "fm_worktree_runtime_provision takes a fresh copy on every call, replacing recycled content"

echo "# all fm-worktree-runtime-lib tests passed"
