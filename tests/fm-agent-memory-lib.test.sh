#!/usr/bin/env bash
# tests/fm-agent-memory-lib.test.sh - unit tests for the per-worker memory
# throttling primitives (bin/fm-agent-memory-lib.sh): argv composition (with
# and without systemd-run on PATH), the /proc/meminfo percentage math, config
# resolution, and the idempotent OOM status-append. Pure functions plus a
# fake systemd-run/systemctl PATH shim - no real systemd required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-memory-lib.sh"

# This file tests fm_agent_memory_systemd_user_available itself, so it must
# see the real detection logic rather than tests/lib.sh's global test-suite
# exemption (FM_AGENT_MEMORY_DISABLE=1).
unset FM_AGENT_MEMORY_DISABLE

TMP_ROOT=$(fm_test_tmproot fm-agent-memory-lib)

# --- unit naming --------------------------------------------------------

[ "$(fm_agent_memory_unit_name task-123 s1700000000.42.7)" = "fm-task-123-s1700000000.42.7.scope" ] \
  || fail "unit name for clean inputs should pass through unchanged"
pass "fm_agent_memory_unit_name builds fm-<id>-<gen>.scope for clean inputs"

# shellcheck disable=SC2016 # single quotes are deliberate: this is literal unsafe input, never meant to expand
UNSAFE=$(fm_agent_memory_unit_name 'weird id/../x' 'g$(rm)')
case "$UNSAFE" in
  *[!A-Za-z0-9:_.@-]*) fail "unit name leaked an unsafe character: $UNSAFE" ;;
esac
case "$UNSAFE" in *.scope) ;; *) fail "unit name must end .scope: $UNSAFE" ;; esac
pass "fm_agent_memory_unit_name folds unsafe characters and always ends .scope"

# --- shell quoting + pure argv composition -------------------------------

Q=$(fm_agent_memory_shell_quote "it's a 'test' \$(x)")
[ "$(eval "printf '%s' $Q")" = "it's a 'test' \$(x)" ] \
  || fail "shell_quote must round-trip through eval unchanged"
pass "fm_agent_memory_shell_quote round-trips single quotes and shell metacharacters"

# shellcheck disable=SC2016 # single quotes are deliberate: the launch text is literal input data, never meant to expand here
COMPOSED=$(fm_agent_memory_compose_launch 'claude --flag "$(cat brief)"' 'fm-x-1.scope' 3G 6G 2G)
case "$COMPOSED" in
  "systemd-run --user --scope --slice="*"--unit="*"-p MemoryHigh="*"-p MemoryMax="*"-p MemorySwapMax="*"-- bash -c "*) ;;
  *) fail "composed launch missing an expected flag: $COMPOSED" ;;
esac
pass "fm_agent_memory_compose_launch emits the full systemd-run --user --scope invocation"

# The composed string must itself be valid, executable shell: run it with a
# fake systemd-run that logs its argv, proving the flags and the wrapped
# launch survive the round trip through a real shell parse (item 5's "with
# systemd-run available" argv-composition case).
FAKEBIN=$(fm_fakebin "$TMP_ROOT/argv-with")
ARGV_LOG="$TMP_ROOT/argv-with/argv.log"
cat > "$FAKEBIN/systemd-run" <<SH
#!/usr/bin/env bash
: > "$ARGV_LOG"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGV_LOG"; done
exit 0
SH
chmod +x "$FAKEBIN/systemd-run"
COMPOSED2=$(fm_agent_memory_compose_launch 'echo hi' 'fm-x-2.scope' 3G 6G 2G)
( PATH="$FAKEBIN:$PATH"; eval "$COMPOSED2" ) || fail "composed launch did not execute cleanly against a fake systemd-run"
grep -qx -- '--unit=fm-x-2.scope' "$ARGV_LOG" || fail "fake systemd-run never saw --unit=fm-x-2.scope; argv: $(cat "$ARGV_LOG")"
grep -qx -- '-p' "$ARGV_LOG" || fail "fake systemd-run never saw a -p flag; argv: $(cat "$ARGV_LOG")"
grep -qx -- 'MemoryMax=6G' "$ARGV_LOG" || fail "fake systemd-run never saw MemoryMax=6G; argv: $(cat "$ARGV_LOG")"
grep -qx -- 'echo hi' "$ARGV_LOG" || fail "fake systemd-run never received the wrapped launch as its bash -c argument; argv: $(cat "$ARGV_LOG")"
pass "the composed launch round-trips through a real shell parse into systemd-run's argv"

# --- availability: with and without systemd-run on PATH ------------------

FAKEBIN_NO=$(fm_fakebin "$TMP_ROOT/no-systemd-run")
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_NO"; fm_agent_memory_systemd_user_available ) \
  && fail "availability must be false with no systemd-run on PATH"
pass "fm_agent_memory_systemd_user_available is false with systemd-run absent from PATH"

FAKEBIN_YES=$(fm_fakebin "$TMP_ROOT/with-systemd-run")
cat > "$FAKEBIN_YES/systemd-run" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN_YES/systemctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --user ] && [ "${2:-}" = show-environment ] && exit 0
exit 1
SH
chmod +x "$FAKEBIN_YES/systemd-run" "$FAKEBIN_YES/systemctl"
cat > "$FAKEBIN_YES/uname" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -s ] && { printf 'Linux\n'; exit 0; }
exit 1
SH
chmod +x "$FAKEBIN_YES/uname"
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_YES:$PATH"; fm_agent_memory_systemd_user_available ) \
  || fail "availability must be true with systemd-run present and a reachable --user manager"
pass "fm_agent_memory_systemd_user_available is true with systemd-run present and --user reachable"

cat > "$FAKEBIN_YES/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN_YES/systemctl"
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_YES:$PATH"; fm_agent_memory_systemd_user_available ) \
  && fail "availability must be false when systemctl --user show-environment fails (no reachable manager)"
pass "fm_agent_memory_systemd_user_available is false when the --user manager is unreachable"

# --- /proc/meminfo percentage math ---------------------------------------

MEMINFO="$TMP_ROOT/meminfo"
printf 'MemTotal:       16384000 kB\nMemFree:         100000 kB\n' > "$MEMINFO"
KB=$(fm_agent_memory_meminfo_total_kb "$MEMINFO") || fail "meminfo read failed on a well-formed file"
[ "$KB" = 16384000 ] || fail "expected MemTotal 16384000 kB, got $KB"
pass "fm_agent_memory_meminfo_total_kb reads MemTotal from an arbitrary meminfo path"

BYTES55=$(fm_agent_memory_pct_bytes "$KB" 55) || fail "pct_bytes failed for 55%"
[ "$BYTES55" = $(( 16384000 * 1024 * 55 / 100 )) ] || fail "55% of 16384000kB computed wrong: $BYTES55"
BYTES0=$(fm_agent_memory_pct_bytes "$KB" 0) || fail "pct_bytes failed for 0%"
[ "$BYTES0" = 0 ] || fail "0% must be exactly 0 bytes, got $BYTES0"
BYTES100=$(fm_agent_memory_pct_bytes "$KB" 100) || fail "pct_bytes failed for 100%"
[ "$BYTES100" = $(( 16384000 * 1024 )) ] || fail "100% must equal the full byte total, got $BYTES100"
pass "fm_agent_memory_pct_bytes computes exact integer byte percentages of MemTotal"

fm_agent_memory_meminfo_total_kb "$TMP_ROOT/does-not-exist" 2>/dev/null \
  && fail "meminfo read must fail on a missing file, not print garbage"
fm_agent_memory_pct_bytes not-a-number 50 2>/dev/null \
  && fail "pct_bytes must reject a non-numeric total"
pass "meminfo helpers fail closed on a missing file or non-numeric input"

# --- config resolution -----------------------------------------------------

CFG_DIR="$TMP_ROOT/config-empty"
mkdir -p "$CFG_DIR"
[ "$(fm_agent_memory_worker_high "$CFG_DIR")" = "$FM_AGENT_MEMORY_WORKER_HIGH_DEFAULT" ] \
  || fail "worker_memory_high must fall back to the compiled default when config/agent-memory is absent"
[ "$(fm_agent_memory_slice_max_pct "$CFG_DIR")" = "$FM_AGENT_MEMORY_SLICE_MAX_PCT_DEFAULT" ] \
  || fail "slice_memory_max_pct must fall back to the compiled default when absent"
pass "every knob falls back to its compiled default when config/agent-memory is absent"

CFG_DIR2="$TMP_ROOT/config-set"
mkdir -p "$CFG_DIR2"
printf 'worker_memory_high=9G\nslice_memory_max_pct=80\n' > "$CFG_DIR2/agent-memory"
[ "$(fm_agent_memory_worker_high "$CFG_DIR2")" = 9G ] || fail "worker_memory_high override was not read"
[ "$(fm_agent_memory_slice_max_pct "$CFG_DIR2")" = 80 ] || fail "slice_memory_max_pct override was not read"
[ "$(fm_agent_memory_worker_max "$CFG_DIR2")" = "$FM_AGENT_MEMORY_WORKER_MAX_DEFAULT" ] \
  || fail "an unset key in a present config file must still fall back to its default"
pass "config/agent-memory overrides the specific keys it sets and defaults the rest"

# --- human-readable bytes ---------------------------------------------------

[ "$(fm_agent_memory_human_bytes 1073741824)" = "1.0G" ] || fail "1073741824 bytes should format as 1.0G"
[ "$(fm_agent_memory_human_bytes 1048576)" = "1.0M" ] || fail "1048576 bytes should format as 1.0M"
[ "$(fm_agent_memory_human_bytes 500)" = "500B" ] || fail "500 bytes should format as 500B"
[ "$(fm_agent_memory_human_bytes not-a-number)" = "not-a-number" ] || fail "non-numeric input should pass through unchanged"
pass "fm_agent_memory_human_bytes formats G/M/B with a numeric fallback"

# --- oom predicate + idempotent status append -------------------------------

fm_agent_memory_is_oom oom-kill || fail "oom-kill must be recognized"
fm_agent_memory_is_oom success && fail "success must not be recognized as oom-kill"
fm_agent_memory_is_oom "" && fail "empty Result must not be recognized as oom-kill"
pass "fm_agent_memory_is_oom recognizes exactly the oom-kill Result value"

REPORT_STATE="$TMP_ROOT/report-state"
mkdir -p "$REPORT_STATE"
cat > "$REPORT_STATE/t1.meta" <<'META'
worktree=/does/not/matter
memory_scope=fm-t1-g1.scope
memory_max=6G
META
: > "$REPORT_STATE/t1.status"

FAKEBIN_OOM=$(fm_fakebin "$TMP_ROOT/oom-systemctl")
cat > "$FAKEBIN_OOM/systemctl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --user ] && [ "${2:-}" = show ]; then
  for a in "$@"; do
    case "$a" in
      Result) printf 'oom-kill\n'; exit 0 ;;
    esac
  done
fi
exit 1
SH
chmod +x "$FAKEBIN_OOM/systemctl"

# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_OOM:$PATH"; fm_agent_memory_report_oom_kill "$REPORT_STATE" t1 )
LAST=$(tail -1 "$REPORT_STATE/t1.status")
case "$LAST" in
  "failed: killed by the per-worker memory limit (MemoryMax=6G)") ;;
  *) fail "expected an exact failed: MemoryMax line, got: $LAST" ;;
esac
[ -e "$REPORT_STATE/t1.oom-reported" ] || fail "idempotency marker was not written"
pass "fm_agent_memory_report_oom_kill appends the exact failed: line once, naming the configured MemoryMax"

LINES_BEFORE=$(wc -l < "$REPORT_STATE/t1.status")
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_OOM:$PATH"; fm_agent_memory_report_oom_kill "$REPORT_STATE" t1 )
LINES_AFTER=$(wc -l < "$REPORT_STATE/t1.status")
[ "$LINES_BEFORE" = "$LINES_AFTER" ] || fail "a second call must not append a duplicate failed: line"
pass "fm_agent_memory_report_oom_kill is idempotent (state/<id>.oom-reported blocks a repeat append)"

# A task with no recorded scope (non-systemd host, or spawned before this
# feature) must never be touched.
cat > "$REPORT_STATE/t2.meta" <<'META'
worktree=/does/not/matter
META
: > "$REPORT_STATE/t2.status"
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_OOM:$PATH"; fm_agent_memory_report_oom_kill "$REPORT_STATE" t2 )
[ -s "$REPORT_STATE/t2.status" ] && fail "a task with no memory_scope must never get a synthetic status line"
pass "fm_agent_memory_report_oom_kill no-ops for a task with no recorded memory scope"

# A live (non-oom) scope must never be reported.
cat > "$REPORT_STATE/t3.meta" <<'META'
worktree=/does/not/matter
memory_scope=fm-t3-g1.scope
memory_max=6G
META
: > "$REPORT_STATE/t3.status"
FAKEBIN_LIVE=$(fm_fakebin "$TMP_ROOT/live-systemctl")
cat > "$FAKEBIN_LIVE/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'success\n'
exit 0
SH
chmod +x "$FAKEBIN_LIVE/systemctl"
# shellcheck disable=SC2030,SC2031 # deliberate: PATH is scoped to this subshell so the shim never leaks into the rest of the test
( PATH="$FAKEBIN_LIVE:$PATH"; fm_agent_memory_report_oom_kill "$REPORT_STATE" t3 )
[ -s "$REPORT_STATE/t3.status" ] && fail "a task whose scope Result is not oom-kill must never get a failed: line"
pass "fm_agent_memory_report_oom_kill no-ops when the recorded scope's Result is not oom-kill"

echo "# fm-agent-memory-lib.test.sh: all assertions passed"
