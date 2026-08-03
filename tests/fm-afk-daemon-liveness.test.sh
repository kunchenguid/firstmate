#!/usr/bin/env bash
# tests/fm-afk-daemon-liveness.test.sh - away-mode supervision must be
# trustworthy: it may not crash on an unreadable age, and it may not report
# itself active while nothing is triaging.
#
# REGRESSION (the housekeeping-gate incident): every age helper guarded only the
# EXIT STATUS of its stat call. A `stat` that exits 0 while printing non-numeric
# text reached $(( )), where `set -u` turns the recursive arithmetic evaluation
# of that text into an unbound-variable error. The echo then never ran, the
# helper returned an EMPTY string on a ZERO exit status, and the caller's
# `[ ... -ge <tick> ]` gate died with "integer expression expected" AND read as
# FALSE - so housekeeping silently stopped running while away mode still
# reported itself active. bin/fm-watch.sh's own header documents this exact
# "File" stray-token hazard for the stat fallback form; these tests pin the
# helpers themselves so any other route to non-numeric output fails safe.
#
# Every assertion drives a real interface: the shipped helper functions and the
# shipped bin/fm-afk-health.sh, never implementation source bytes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH="$ROOT/bin/fm-afk-health.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-liveness.XXXXXX")
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A `stat` earlier on PATH that exits 0 but prints non-integer text. This is the
# real-world shape: a stat wrapper/shim, or a non-BSD stat reached with BSD
# flags, where `-f` means --file-system and prints a filesystem block.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/stat" <<'SHIM'
#!/bin/sh
echo "  File: \"/\""
echo "  ID: 0 Namelen: 255 Type: apfs"
exit 0
SHIM
chmod +x "$WORK/shim/stat"

# --- 1. every age helper must fail SAFE, never return an empty operand -------
# Each helper is exercised in its own shell with the shim first on PATH and with
# `set -u` active, exactly as the daemon and watcher run.
check_age_helper() {  # <label> <script> <load-snippet> <call>
  local label=$1 script=$2 load=$3 call=$4 out rc
  out=$(PATH="$WORK/shim:$PATH" bash -c "
    set -u
    $load
    $call
  " 2>/dev/null) || true
  rc=0
  # The defect signature: an EMPTY string, which then makes an integer gate die.
  case $out in
    '') fail "$label: returned an EMPTY age (the crash signature)"; return ;;
    *[!0-9]*) fail "$label: returned a non-integer age [$out]"; return ;;
  esac
  # Fail-safe direction: an untrustworthy age must read as DUE, so the cadence
  # gate does the work instead of silently skipping it forever.
  if [ "$out" -ge 15 ]; then
    pass "$label: unparseable mtime reads as due ($out), gate survives"
  else
    fail "$label: unparseable mtime read as NOT due ($out) - cadence would stall"
  fi
  : "$rc" "$script"
}

check_age_helper "fm-supervise-daemon.sh _file_age" \
  "$ROOT/bin/fm-supervise-daemon.sh" \
  "FM_HOME=$WORK; FM_STATE_OVERRIDE=$WORK/state; . '$ROOT/bin/fm-supervise-daemon.sh' >/dev/null 2>&1 || true" \
  "_file_age '$WORK'"

check_age_helper "fm-watch.sh age_of" \
  "$ROOT/bin/fm-watch.sh" \
  "FM_HOME=$WORK; FM_STATE_OVERRIDE=$WORK/state; . '$ROOT/bin/fm-watch.sh' >/dev/null 2>&1 || true" \
  "age_of '$WORK'"

check_age_helper "fm-wake-lib.sh fm_path_age" \
  "$ROOT/bin/fm-wake-lib.sh" \
  "FM_HOME=$WORK; STATE=$WORK/state; FM_STATE_OVERRIDE=$WORK/state; . '$ROOT/bin/fm-wake-lib.sh' >/dev/null 2>&1 || true" \
  "fm_path_age '$WORK'"

# --- 2. the gate the incident actually killed -------------------------------
# Pin the caller, not just the helper: the housekeeping gate must still evaluate
# cleanly (no "integer expression expected") when the age is untrustworthy.
gate_err=$(PATH="$WORK/shim:$PATH" bash -c "
  set -u
  FM_HOME=$WORK; FM_STATE_OVERRIDE=$WORK/state
  . '$ROOT/bin/fm-supervise-daemon.sh' >/dev/null 2>&1 || true
  if [ \"\$(_file_age '$WORK/nofile')\" -ge 15 ]; then echo DUE; else echo NOTDUE; fi
" 2>&1) || true
case $gate_err in
  *"integer expression expected"*)
    fail "housekeeping gate still dies on an untrustworthy age: $gate_err" ;;
  *DUE*)
    pass "housekeeping gate evaluates cleanly and runs housekeeping" ;;
  *)
    fail "housekeeping gate produced an unexpected verdict: $gate_err" ;;
esac

# --- 3. counter files must not abort a poll either ---------------------------
counter_out=$(bash -c "
  set -u
  FM_HOME=$WORK; FM_STATE_OVERRIDE=$WORK/state
  . '$ROOT/bin/fm-watch.sh' >/dev/null 2>&1 || true
  # Guard against a vacuous pass: an ABSENT validator must fail this test, not
  # slip through as an empty command substitution that happens to sum to 1.
  type read_counter >/dev/null 2>&1 || { echo 'NO-VALIDATOR'; exit 0; }
  printf 'corrupt-not-a-number' > '$WORK/counter'
  echo \$(( \$(read_counter '$WORK/counter') + 1 ))
" 2>/dev/null) || true
if [ "$counter_out" = "1" ]; then
  pass "corrupt counter file reads as 0 instead of aborting the poll"
else
  fail "corrupt counter file did not fail safe (got [$counter_out], want 1)"
fi

# --- 4. away mode must not report itself active with no live daemon ---------
export FM_STATE_OVERRIDE="$WORK/health-state"
mkdir -p "$FM_STATE_OVERRIDE"

if out=$("$HEALTH" 2>&1); then
  case $out in
    AFK_OFF*) pass "no away-mode flag reports AFK_OFF" ;;
    *) fail "expected AFK_OFF with no flag, got: $out" ;;
  esac
else
  fail "health check failed with no away-mode flag: $out"
fi

date +%s > "$FM_STATE_OVERRIDE/.afk"
if out=$("$HEALTH" 2>&1); then
  fail "away-mode flag with NO live daemon reported healthy: $out"
else
  case $out in
    AFK_DEGRADED*) pass "away-mode flag with no live daemon is loudly AFK_DEGRADED" ;;
    *) fail "expected AFK_DEGRADED, got: $out" ;;
  esac
fi

# A durable exit record must be surfaced as the REASON, not just "gone".
printf '2026-08-03T00:00:00-0700\texit=1\tpid=999\tready=no\n' \
  > "$FM_STATE_OVERRIDE/.subsuper-daemon-exit"
out=$("$HEALTH" 2>&1) || true
case $out in
  *"exit=1"*) pass "durable exit record is surfaced as the reason the daemon is gone" ;;
  *) fail "exit record not surfaced by the health check: $out" ;;
esac

exit "$FAILED"
