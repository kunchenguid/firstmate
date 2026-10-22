#!/usr/bin/env bash
# tests/rex-test-safety.sh - shared isolation for tests that talk to the REAL
# personal Rex server, which is usually the captain's live one. Sourced by the
# real-Rex suites (tests/fm-backend-rex-smoke.test.sh and
# tests/fm-backend-rex-eventwait-smoke.test.sh), which therefore:
#   - never start, stop, restart, or reconfigure a server: rex_test_prepare
#     reports a skip unless a server is already reachable without autostart;
#   - work only inside sessions they create, labeled fm-test-*, addressed by
#     explicit id, and killed at exit (rex_test_cleanup);
#   - route every adapter call through a forwarding guard on REX_BIN_DIR that
#     REFUSES any state-changing command naming a session outside the ones the
#     test created (and any `new` not labeled fm-test-*), recording the refusal
#     so rex_test_assert_isolated fails;
#   - compare a before/after snapshot of every other session's structure
#     (session, window, and block ids and labels), which must be byte-identical;
#     concurrent activity by another Rex user can also trip it, which the
#     failure says.
# The caller defines fail() and pass() before using these helpers.
set -u

REX_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_TEST_WORK=""
REX_TEST_REAL=""
REX_TEST_BEFORE=""
REX_TEST_CLEANED=""

# rex_test_prepare: isolate this process from the caller's own Rex session,
# load the adapter, and set up the guard and a scratch home. Prints a skip
# reason and returns 1 when the real-Rex suite cannot run here.
rex_test_prepare() {
  # Never mistake the caller's own Rex session for a launcher session the
  # adapter may place tabs into.
  unset REX_SESSION REX_BLOCK REX_SERVER
  export TERM_PROGRAM=fm-test
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; return 1; }
  # shellcheck source=/dev/null
  . "$REX_TEST_ROOT/bin/fm-backend.sh"
  fm_backend_source rex || { echo "skip: could not source the rex adapter"; return 1; }
  REX_TEST_REAL=$(fm_backend_rex_bin) || { echo "skip: rex CLI not found at \$REX_BIN_DIR, on PATH, or at the server bundle path"; return 1; }
  "$REX_TEST_REAL" --autostart=false api call server.status >/dev/null 2>&1 \
    || { echo "skip: no Rex server is reachable (this test never starts one)"; return 1; }
  fm_backend_rex_version_check read >/dev/null 2>&1 || { echo "skip: installed Rex is older than the verified API revision"; return 1; }
  REX_TEST_WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-test.XXXXXX")" && pwd -P)
  mkdir -p "$REX_TEST_WORK/guard" "$REX_TEST_WORK/home/state"
  : >"$REX_TEST_WORK/allowed"
  export FM_HOME="$REX_TEST_WORK/home" STATE="$REX_TEST_WORK/home/state"
  rex_test_write_guard "$REX_TEST_WORK/guard/rex"
  export REX_BIN_DIR="$REX_TEST_WORK/guard" FM_REX_TEST_REAL="$REX_TEST_REAL" \
    FM_REX_TEST_ALLOWED="$REX_TEST_WORK/allowed" FM_REX_TEST_TRIP="$REX_TEST_WORK/tripwire"
  REX_TEST_BEFORE=$(rex_test_foreign_snapshot) || { echo "skip: could not snapshot the other Rex sessions"; return 1; }
}

rex_test_write_guard() {  # <path>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
# Forwarding guard: reads pass through; a state-changing command must name a
# session the test created, and `new` must be labeled fm-test-*.
real=${FM_REX_TEST_REAL:?}; allowed=${FM_REX_TEST_ALLOWED:?}; trip=${FM_REX_TEST_TRIP:?}
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]#--}" != "${args[$i]}" ]; do i=$((i + 1)); done
cmd=${args[$i]:-}; sub=${args[$((i + 1))]:-}
sid=; j=$i
while [ "$j" -lt "${#args[@]}" ]; do
  [ "${args[$j]}" = -s ] && sid=${args[$((j + 1))]:-}
  j=$((j + 1))
done
refuse() { printf '%s\n' "$*" >>"$trip"; echo "fm-rex-test guard: refused $*" >&2; exit 97; }
scoped() { [ -n "$sid" ] && grep -qxF -- "$sid" "$allowed" || refuse "$@"; }
case "$cmd" in
  version|whoami|ls|capture) ;;
  api)
    case " $* " in
      *" server.status "*|*" session.view "*) ;;
      *) refuse "$@" ;;
    esac ;;
  new)
    case "${args[$((i + 1))]:-}" in fm-test-*) ;; *) refuse "$@" ;; esac ;;
  window) [ "$sub" = new ] && scoped "$@" || refuse "$@" ;;
  block)
    case "$sub" in
      rename|close) scoped "$@" ;;
      call)
        case " $* " in
          *" size "*|*" process "*|*" program_status "*) ;;
          *) scoped "$@" ;;
        esac ;;
      *) refuse "$@" ;;
    esac ;;
  send|send-key|do) scoped "$@" ;;
  kill) grep -qxF -- "${args[$((i + 1))]:-}" "$allowed" || refuse "$@" ;;
  *) refuse "$@" ;;
esac
exec "$real" "$@"
SH
  chmod +x "$1"
}

# rex_test_foreign_snapshot: every session the test did not create, reduced to
# its ids and labels (focus and revision change whenever a viewer clicks).
rex_test_foreign_snapshot() {
  local sid
  "$REX_TEST_REAL" --autostart=false ls --json | jq -r '.sessions[].session_id' | sort | while IFS= read -r sid; do
    [ -z "$REX_TEST_WORK" ] || ! grep -qxF -- "$sid" "$REX_TEST_WORK/allowed" || continue
    "$REX_TEST_REAL" --autostart=false api call -s "$sid" session.view \
      | jq -cS '{session_id, label, windows: [.windows[]? | {window_id, label,
          blocks: [.layers[]?.blocks[]? | {block_id, label}]}]}'
  done
}

# rex_test_new_session: create one fm-test-* session, allow the guard to act on
# it, and print "<session-id> <first-block-id>".
rex_test_new_session() {  # <label-suffix>
  local out sid bid
  out=$(fm_backend_rex_cli new "fm-test-$1-$$" --window fm-test-main --cwd "$REX_TEST_WORK" --json) || return 1
  sid=$(printf '%s' "$out" | jq -r .session_id)
  bid=$(printf '%s' "$out" | jq -r '.initial_windows[0].block_ids[0]')
  fm_backend_rex_id_valid session "$sid" && fm_backend_rex_id_valid block "$bid" || return 1
  printf '%s\n' "$sid" >>"$REX_TEST_WORK/allowed"
  printf '%s %s' "$sid" "$bid"
}

# rex_test_wait_for: retry a predicate every 0.2s.
rex_test_wait_for() {  # <tries> <command...>
  local tries=$1 n=0
  shift
  while [ "$n" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    n=$((n + 1))
  done
  return 1
}

# rex_test_assert_isolated: no guard refusal and every other session unchanged.
rex_test_assert_isolated() {
  local after
  [ ! -s "$REX_TEST_WORK/tripwire" ] \
    || fail "the guard refused state-changing calls outside the test session:"$'\n'"$(cat "$REX_TEST_WORK/tripwire")"
  after=$(rex_test_foreign_snapshot) || fail "could not snapshot the other sessions after the test"
  [ "$REX_TEST_BEFORE" = "$after" ] \
    || fail "other sessions changed during the test (another Rex user acting concurrently can also cause this):"$'\n'"$(diff <(printf '%s\n' "$REX_TEST_BEFORE") <(printf '%s\n' "$after"))"
  pass "real rex: no state-changing call left the test sessions and every other session is byte-identical"
}

# rex_test_cleanup: kill exactly the sessions this test created, re-checking
# each one's fm-test- label first, and remove the scratch directory.
rex_test_cleanup() {
  local sid label
  [ -z "$REX_TEST_CLEANED" ] || return 0
  REX_TEST_CLEANED=1
  [ -n "$REX_TEST_WORK" ] || return 0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    label=$("$REX_TEST_REAL" --autostart=false api call -s "$sid" session.view 2>/dev/null | jq -r '.label // empty')
    case "$label" in
      fm-test-*) "$REX_TEST_REAL" --autostart=false kill "$sid" >/dev/null 2>&1 || true ;;
      '') ;;
      *) printf 'note: not killing %s (label %s is not a test session)\n' "$sid" "$label" >&2 ;;
    esac
  done <"$REX_TEST_WORK/allowed"
  rm -rf "$REX_TEST_WORK"
}
