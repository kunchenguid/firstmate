#!/usr/bin/env bash
# Herdr-visible supervision metadata must describe the watcher without changing
# the primary agent's real idle/working lifecycle state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-visibility)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_LOG="$TMP_ROOT/herdr.log"
WATCH="$ROOT/bin/fm-watch.sh"
: > "$HERDR_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
if [ "${FM_FAKE_HERDR_HANG:-0}" = 1 ]; then
  exec sleep 30
fi
printf '%s\n' '{"ok":true}'
SH
chmod +x "$FAKEBIN/herdr"

HOME_UNIT="$TMP_ROOT/unit-home"
mkdir -p "$HOME_UNIT/state" "$HOME_UNIT/config"
FM_HOME="$HOME_UNIT"
FM_STATE_OVERRIDE="$HOME_UNIT/state"
FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=bin/fm-watch.sh
. "$WATCH"

run_visibility() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$HERDR_LOG" "$@"
}

reset_visibility_globals() {
  FM_SUPERVISION_VISIBILITY_PUBLISHED=0
  FM_SUPERVISION_VISIBILITY_SOURCE=firstmate-supervision:test
  FM_SUPERVISION_VISIBILITY_SESSION=
  FM_SUPERVISION_VISIBILITY_PANE=
}

test_active_and_clean_exit_metadata() {
  reset_visibility_globals
  : > "$HERDR_LOG"
  FM_SUPERVISOR_BACKEND=herdr
  FM_SUPERVISOR_TARGET=fm-lab-visible:w1:p1
  HERDR_ENV=
  TMUX=
  run_visibility fm_supervision_visibility_refresh
  grep -Fx "pane report-metadata w1:p1 --source firstmate-supervision:test --custom-status supervised --state-label idle=idle · supervised --ttl-ms 360000 --session fm-lab-visible" "$HERDR_LOG" >/dev/null \
    || fail "active watcher did not publish the truthful Herdr state label"
  [ "$FM_SUPERVISION_VISIBILITY_PUBLISHED" -eq 1 ] \
    || fail "successful active metadata publication was not recorded"

  run_visibility fm_supervision_visibility_clear
  grep -Fx "pane report-metadata w1:p1 --source firstmate-supervision:test --clear-custom-status --clear-state-labels --session fm-lab-visible" "$HERDR_LOG" >/dev/null \
    || fail "clean watcher exit did not clear its Herdr metadata source"
  [ "$FM_SUPERVISION_VISIBILITY_PUBLISHED" -eq 0 ] \
    || fail "clean metadata clear retained the published marker"
  pass "Herdr visibility publishes idle-supervised without faking work and clears on clean exit"
}

test_hung_metadata_call_cannot_wedge_supervision() {
  local started elapsed
  reset_visibility_globals
  : > "$HERDR_LOG"
  FM_SUPERVISOR_BACKEND=herdr
  FM_SUPERVISOR_TARGET=fm-lab-visible:w1:p1
  HERDR_ENV=
  TMUX=
  started=$(date +%s)
  FM_FAKE_HERDR_HANG=1 run_visibility fm_supervision_visibility_refresh
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 4 ] || fail "hung Herdr metadata call delayed supervision for ${elapsed}s"
  [ "$FM_SUPERVISION_VISIBILITY_PUBLISHED" -eq 0 ] \
    || fail "timed-out metadata publication was recorded as visible"
  pass "a hung optional Herdr metadata call times out without wedging supervision"
}

test_inactive_and_non_herdr_runtimes_stay_unpublished() {
  reset_visibility_globals
  : > "$HERDR_LOG"
  FM_SUPERVISOR_BACKEND=tmux
  FM_SUPERVISOR_TARGET=firstmate:0
  HERDR_ENV=1
  HERDR_PANE_ID=w1:p1
  HERDR_SESSION=fm-lab-visible
  TMUX=/tmp/tmux-1/default,1,0
  run_visibility fm_supervision_visibility_refresh
  [ ! -s "$HERDR_LOG" ] || fail "an explicit non-Herdr supervisor published Herdr metadata"

  FM_SUPERVISOR_BACKEND=
  FM_SUPERVISOR_TARGET=
  run_visibility fm_supervision_visibility_refresh
  [ ! -s "$HERDR_LOG" ] || fail "a tmux runtime nested in Herdr published metadata on its outer pane"

  TMUX=
  HERDR_ENV=
  HERDR_PANE_ID=
  run_visibility fm_supervision_visibility_refresh
  [ ! -s "$HERDR_LOG" ] || fail "an inactive non-Herdr watcher published Herdr metadata"
  pass "inactive, non-Herdr, and nested-tmux supervision do not claim a Herdr indicator"
}

wait_for_log_match() { # <pattern> [attempts]
  local pattern=$1 attempts=${2:-100} i=0
  while [ "$i" -lt "$attempts" ]; do
    grep -F -- "$pattern" "$HERDR_LOG" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_singleton_duplicate_does_not_publish_or_clear() {
  local home first_pid duplicate_pid duplicate_out source
  home="$TMP_ROOT/singleton-home"
  duplicate_out="$TMP_ROOT/duplicate.out"
  mkdir -p "$home/state" "$home/config"
  : > "$HERDR_LOG"

  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=fm-lab-visible:w1:p1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
    bash "$WATCH" >"$TMP_ROOT/first.out" 2>&1 &
  first_pid=$!
  source="firstmate-supervision:$first_pid"
  if ! wait_for_log_match "--source $source --custom-status supervised"; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "singleton watcher did not publish its active Herdr metadata: $(cat "$TMP_ROOT/first.out" 2>/dev/null)"
  fi

  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=fm-lab-visible:w1:p1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
    bash "$WATCH" >"$duplicate_out" 2>&1 &
  duplicate_pid=$!
  wait "$duplicate_pid" || true
  grep -F "watcher: already running pid $first_pid" "$duplicate_out" >/dev/null \
    || fail "duplicate watcher did not stand down on the singleton"
  if grep -F -- "--source firstmate-supervision:$duplicate_pid" "$HERDR_LOG" >/dev/null; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "duplicate watcher published or cleared a second Herdr metadata source"
  fi
  if grep -F -- "--source $source --clear-custom-status" "$HERDR_LOG" >/dev/null; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "duplicate arm cleared the live watcher's Herdr indicator"
  fi

  kill -TERM "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
  wait_for_log_match "--source $source --clear-custom-status --clear-state-labels" \
    || fail "clean singleton exit did not clear its unique Herdr metadata source"
  pass "duplicate arm preserves one live supervision cycle and one truthful Herdr indicator"
}

test_active_and_clean_exit_metadata
test_hung_metadata_call_cannot_wedge_supervision
test_inactive_and_non_herdr_runtimes_stay_unpublished
test_singleton_duplicate_does_not_publish_or_clear
