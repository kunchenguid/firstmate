#!/usr/bin/env bash
# Fork-reduction regression coverage for bin/fm-supervision-host.sh helpers:
# host_identity_read (the fork-free /proc identity read), the refresh_process
# fast path (its cross-checked cache), and the park_sleep fifo timer. Each
# replaced a per-poll or per-half-second fork chain; these pin the observable
# behavior that chain produced.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOSTSCRIPT="$ROOT/bin/fm-supervision-host.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-host-fork-reduction)

# Extract function bodies for direct exercise. Multiple names are concatenated
# with the newline separators sed already prints between them (a single
# trailing newline is stripped by command substitution, which is harmless only
# at the very end - a naive "$(f1)$(f2)" would fuse bodies as `}next() {`).
host_fns() {  # <name>...
  local name
  for name in "$@"; do
    sed -n "/^$name() {/,/^}/p" "$HOSTSCRIPT"
  done
}

# The fork-free identity read needs the forkful one (via fm_pid_identity from
# fm-wake-lib.sh) as both its cross-check and its fallback.
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"

_fm_engine_identity() {  # <pid> -> identity line
  local identity
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf "%s\n" "$identity" | tr "\t\n" "  " | sed "s/ *$//"
}

eval "$(host_fns identity_of host_identity_read _refresh_row_current refresh_process park_sleep park_sleep_init park_sleep_fini)"
_REFRESH_ID_CACHE_PID=
_REFRESH_ID_CACHE_VALUE=
PARK_SLEEP_FD=
PARK_SLEEP_FIFO=

# ---- host_identity_read matches identity_of byte for byte --------------------
test_host_identity_read_matches_forkful() {
  local pid a b
  # This bash and a child with adversarial argv: spaces, quotes, UTF-8, and an
  # empty argument, each of which must survive the hex round-trip exactly.
  bash -c 'sleep 5' 'weird arg ünïcode "q" $dollar' '' extra & pid=$!
  sleep 0.2
  a=$(identity_of "$pid")
  host_identity_read "$pid" b || fail "host_identity_read must succeed for a live child"
  [ -n "$a" ] || fail "fixture child must have a forkful identity"
  [ "$a" = "$b" ] || fail "host_identity_read must match identity_of byte for byte: [$a] vs [$b]"
  a=$(identity_of "$$")
  host_identity_read $$ b
  [ "$a" = "$b" ] || fail "host_identity_read must match identity_of for the test shell: [$a] vs [$b]"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  b=
  host_identity_read 999999999 b 2>/dev/null \
    && fail "host_identity_read must fail for a missing pid"
  [ "$b" = "" ] || fail "host_identity_read must not emit an identity on failure"
  pass "host_identity_read: byte-identical to identity_of, fails closed"
}

# ---- refresh_process: full path repairs rows, fast path skips nothing -------
test_refresh_process_repairs_and_skips() {
  local rec=$TMP_ROOT/.supervision-host pid a
  : > "$rec"
  # shellcheck disable=SC2034  # consumed by the eval'd refresh_process
  HOST_RECORD=$rec
  bash -c 'sleep 30' probe-argv & pid=$!
  sleep 0.2
  # Seed the row refresh_process owns (registration writes it; refresh only
  # rewrites an existing row's identity).
  printf 'watcher\t%s\tinitial\t\n' "$pid" > "$rec"

  # First refresh records the child's current identity (forkful path).
  _REFRESH_ID_CACHE_PID=
  refresh_process "$pid"
  [ "$(awk -F '\t' -v pid="$pid" '$2 == pid { print $3 }' "$rec")" ] \
    || fail "first refresh must record an identity for the child"

  # Corrupt the row's identity: the next refresh (even with a populated
  # cache, because the recorded identity no longer equals the cached one)
  # must take the forkful path and repair it. Wait for the exec-free child.
  local good
  good=$(identity_of "$pid")
  printf 'watcher\t%s\tbroken\t\n' "$pid" > "$rec"
  refresh_process "$pid"
  [ "$(awk -F '\t' -v pid="$pid" '$2 == pid { print $3 }' "$rec")" = "$good" ] \
    || fail "refresh_process must repair a stale identity row"
  [ "$_REFRESH_ID_CACHE_PID" = "$pid" ] \
    || fail "refresh_process must prime the cache on a successful repair"

  # Unchanged child, cache primed: a no-op refresh must leave the row as-is
  # (the fast path's claim is exactly that nothing needs rewriting).
  local before
  before=$(cat "$rec")
  refresh_process "$pid"
  [ "$(cat "$rec")" = "$before" ] \
    || fail "cached no-op refresh must not rewrite the record"

  # A different pid (cache miss) must still go through the full path.
  printf 'watcher\t111\tstale\t\n' >> "$rec"
  refresh_process "$pid"
  [ "$(awk -F '\t' -v pid=111 '$2 == 111 { print $3 }' "$rec")" = stale ] \
    || fail "cache-miss refresh must not touch other rows"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "refresh_process: repairs stale rows, no-ops only on cross-checked cache hits"
}

# ---- park_sleep times its interval without forking or leaking ----------------
test_park_sleep_fifo_timer() {
  STATE=$TMP_ROOT/state
  HOST_PID=$$
  mkdir -p "$STATE"
  park_sleep_init
  if [ -n "$PARK_SLEEP_FD" ]; then
    local t0 elapsed
    t0=$SECONDS
    park_sleep 0.4
    park_sleep 0.4
    elapsed=$((SECONDS - t0))
    [ "$elapsed" -ge 1 ] || fail "two park_sleep 0.4 calls must span at least a second (took ${elapsed}s)"
    [ -p "$PARK_SLEEP_FIFO" ] || fail "park_sleep_init must create its fifo while active"
    park_sleep_fini
    [ -z "$PARK_SLEEP_FD" ] || fail "park_sleep_fini must clear the fd"
    [ ! -e "$PARK_SLEEP_FIFO" ] || fail "park_sleep_fini must remove its fifo"
    # A second fini (cleanup can run more than once) must stay quiet.
    park_sleep_fini
  else
    # Old bash fallback: still sleeps, via the portable path.
    park_sleep 0.2
    pass "park_sleep: portable fallback engaged"
    return 0
  fi
  pass "park_sleep: fifo timer spans its interval and cleans up after itself"
}

# ---- park_sleep keeps a child's exit status observable ------------------------
test_park_sleep_preserves_child_reaping() {
  STATE=$TMP_ROOT/state2
  # shellcheck disable=SC2034  # consumed by the eval'd park_sleep helpers
  HOST_PID=$$
  mkdir -p "$STATE"
  park_sleep_init
  local pid st
  (exit 9) & pid=$!
  park_sleep 0.2
  wait "$pid"; st=$?
  park_sleep_fini
  [ "$st" = 9 ] || fail "park_sleep must not consume a child's exit status (got $st)"
  pass "park_sleep: child exit statuses stay readable by pid"
}

test_host_identity_read_matches_forkful
test_refresh_process_repairs_and_skips
test_park_sleep_fifo_timer
test_park_sleep_preserves_child_reaping
