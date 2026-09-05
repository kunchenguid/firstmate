#!/usr/bin/env bash
# Regression tests pinning the ABSENCE of fm-guard's watcher-down banner.
#
# The passive "WATCHER DOWN - SUPERVISION IS OFF" output was removed outright,
# for every supervision model, after the 2026-09-04 investigation showed it could
# not distinguish a working watcher from a stopped one. These tests assert the
# guard emits nothing about watcher liveness, that no equivalent banner survives
# on another harness model, and that the independent alarms it was never part of
# - queued wakes and the worktree tangle - still fire. The turn-end guard
# (bin/fm-turnend-guard.sh) is a separate turn-boundary safeguard and is not
# exercised or changed here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-stale-banner)

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

record_live_watcher() {
  local dir=$1 pid=$2 home identity
  home=$(case_home "$dir")
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") || return 1
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

# These cases exercise the persistent-watcher model (a live pid is the real
# liveness signal), so pin the model rather than letting the host test runner's
# ambient harness ancestry pick it.
run_guard_case() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The Claude Stop auto-arm model: the watcher runs only between turns, so a fresh
# beacon with no live watcher process is the healthy mid-turn state.
run_guard_case_autoarm() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The Pi extension model: .pi/extensions/fm-primary-pi-watch.ts tears the watcher
# down on every actionable wake and spawns the replacement itself, so the lock is
# legitimately unheld during a hand-off.
run_guard_case_extension() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The same extension-model call from the supervision branch actor
# (FM_SUPERVISION_ACTOR=branch, as the Pi branch extension injects it).
run_guard_case_extension_as_branch() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=extension \
    FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Set <file>'s mtime to exactly <epoch> seconds. touch -t takes a local-time
# stamp rather than an epoch on both platforms, so convert via BSD `date -r` or
# GNU `date -d @`. Same helper shape as tests/fm-watch-triage.test.sh.
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# --- The banner is gone. These tests pin its ABSENCE, per model. ------------
#
# 2026-09-04 supervision investigation: the watcher-down banner could not tell a
# working watcher from a stopped one, and under the auto-arm model it was a false
# alarm in essentially every printing. It was removed outright rather than made
# conditional. The risk this file now guards is the opposite of the old one: that
# an equivalent passive banner quietly survives on one of the other harness
# models, or grows back later under a new name.

# The guard must say NOTHING about watcher liveness under EVERY supervision
# model, including the two that were never the source of the false alarms. A
# model-specific survivor is exactly the silent narrowing this asserts against.
test_no_watcher_liveness_output_under_any_model() {
  local dir out model runner
  for model in persistent autoarm extension; do
    dir=$(make_guard_case "silent-$model")
    case "$model" in
      persistent) runner=run_guard_case ;;
      autoarm) runner=run_guard_case_autoarm ;;
      extension) runner=run_guard_case_extension ;;
    esac
    # No live watcher, no beacon at all: the worst reading the old banner had.
    out=$("$runner" "$dir")
    [ -z "$out" ] \
      || fail "the $model model must print nothing about watcher liveness, got: $out"
    # And again, so a survivor that only prints on a repeat call is caught too.
    out=$("$runner" "$dir")
    [ -z "$out" ] \
      || fail "the $model model must stay silent on repeat calls, got: $out"
  done
  pass "fm-guard: no watcher-liveness output under persistent, autoarm or extension"
}

# A stale beacon with a live, identity-matched holder was the exact 2026-09-04
# false alarm. It must produce no output now, under every model.
test_stale_beacon_with_live_holder_is_silent() {
  local dir home pid out model runner
  for model in persistent autoarm extension; do
    dir=$(make_guard_case "stale-live-$model")
    home=$(case_home "$dir")
    sleep 600 &
    pid=$!
    record_live_watcher "$dir" "$pid"
    : > "$home/state/.last-watcher-beat"
    set_mtime "$(( $(date +%s) - 4000 ))" "$home/state/.last-watcher-beat"
    case "$model" in
      persistent) runner=run_guard_case ;;
      autoarm) runner=run_guard_case_autoarm ;;
      extension) runner=run_guard_case_extension ;;
    esac
    out=$(FM_GUARD_GRACE=1 "$runner" "$dir")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -z "$out" ] \
      || fail "a live holder with a stale beacon must be silent under $model, got: $out"
  done
  pass "fm-guard: a live holder with a stale beacon produces no output"
}

# The removal must not leave its bookkeeping behind: no episode marker, no lock,
# no other state file. A survivor here would mean the banner is still being
# computed somewhere.
test_no_banner_state_files_are_created() {
  local dir home leftovers
  dir=$(make_guard_case "no-state")
  home=$(case_home "$dir")
  run_guard_case "$dir" >/dev/null
  run_guard_case_autoarm "$dir" >/dev/null
  run_guard_case_extension "$dir" >/dev/null
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "fm-guard must no longer create a stale-banner episode marker"
  leftovers=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ -z "$leftovers" ] \
    || fail "fm-guard left banner bookkeeping behind: $leftovers"
  pass "fm-guard: no banner episode state is created"
}

# --- What the removal must NOT touch ----------------------------------------

# The queued-wakes warning is independent of watcher liveness and predates the
# banner. Removing the banner must not remove or gate it.
test_queued_wake_warning_survives_banner_removal() {
  local dir home out
  dir=$(make_guard_case "queued")
  home=$(case_home "$dir")
  printf '1 1 signal task note\n' > "$home/state/.wake-queue"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "queued wakes pending" \
    "the queued-wakes warning must survive the banner removal"
  assert_not_contains "$out" "SUPERVISION IS OFF" \
    "the queued-wakes path must not resurrect a watcher banner"
  pass "fm-guard: queued-wakes warning survives, with no banner"
}

# The supervision branch actor stays exempt from the queued-wakes warning; that
# exemption is unrelated to the banner and must be preserved verbatim.
test_branch_actor_is_not_told_to_drain_queued_wakes() {
  local dir home out
  dir=$(make_guard_case "branch-actor")
  home=$(case_home "$dir")
  printf '1 1 signal task note\n' > "$home/state/.wake-queue"
  out=$(run_guard_case_extension_as_branch "$dir")
  assert_not_contains "$out" "queued wakes pending" \
    "the supervision branch actor must not be told to drain the rows it is handling"
  pass "fm-guard: the branch actor is still exempt from the queued-wakes warning"
}

# The worktree-tangle alarm is checked before anything else and is independent of
# supervision entirely. It must still fire.
test_worktree_tangle_alarm_survives_banner_removal() {
  local dir root out
  dir=$(make_guard_case "tangle")
  root=$(case_root "$dir")
  git -C "$root" init -q 2>/dev/null || { pass "fm-guard: tangle alarm (skipped, no git)"; return; }
  git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$root" checkout -q -b fm/some-crew-branch
  out=$(run_guard_case "$dir")
  assert_contains "$out" "WORKTREE TANGLE" \
    "the worktree-tangle alarm must survive the banner removal"
  pass "fm-guard: worktree-tangle alarm survives"
}

# Nothing riding on supervision means the guard exits silently, as before.
test_no_supervision_need_is_silent() {
  local dir home out
  dir=$(make_guard_case "idle")
  home=$(case_home "$dir")
  rm -f "$home/state/task.meta"
  out=$(run_guard_case "$dir")
  [ -z "$out" ] || fail "an idle home must stay silent, got: $out"
  pass "fm-guard: an idle home is silent"
}

# A read-only session must behave identically: silent about liveness, and it must
# not write anything.
test_read_only_is_silent_and_writes_nothing() {
  local dir home before after out
  dir=$(make_guard_case "read-only")
  home=$(case_home "$dir")
  before=$(find "$home/state" -mindepth 1 | sort)
  out=$(run_guard_case_read_only "$dir")
  after=$(find "$home/state" -mindepth 1 | sort)
  [ -z "$out" ] || fail "a read-only guard call must be silent, got: $out"
  [ "$before" = "$after" ] \
    || fail "a read-only guard call must not change state files"
  pass "fm-guard: read-only stays silent and writes nothing"
}

test_no_watcher_liveness_output_under_any_model
test_stale_beacon_with_live_holder_is_silent
test_no_banner_state_files_are_created
test_queued_wake_warning_survives_banner_removal
test_branch_actor_is_not_told_to_drain_queued_wakes
test_worktree_tangle_alarm_survives_banner_removal
test_no_supervision_need_is_silent
test_read_only_is_silent_and_writes_nothing
