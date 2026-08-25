#!/usr/bin/env bash
# Regression test for fm-spawn.sh's shell-readiness gate on the first text line
# sent into a pane (bin/fm-spawn.sh, spawn_await_shell_ready).
#
# A freshly created pane's shell can still be sourcing its rc files when the
# first send lands, and a slow init eats the leading byte(s). Seen live on herdr
# under load (2026-08-17): the leading 't' of `treehouse get` was swallowed three
# times running, the pane ran `reehouse get`, and the worktree was never entered -
# with nothing on firstmate's side to notice. The gate proves the shell is
# reading command lines before trusting a send, so a corrupted first line can no
# longer reach the pane silently.
#
# The fake tmux below is a byte-lossy shell: it drops the leading character of
# every delivery in a configurable window, records what the pane actually
# received, and executes a delivered `touch <path>` for real. That makes the
# gate's own readiness signal - a marker file only a byte-exact line can create -
# observable end to end, and lets each case assert on the exact bytes the pane
# saw rather than on the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-first-send)

# make_lossy_fakebin <dir> builds a fake tmux that models the pane's shell.
#
# Every `send-keys -t <target> <text> Enter` is one delivery. Deliveries numbered
# FM_FAKE_SWALLOW_FROM..FM_FAKE_SWALLOW_UNTIL inclusive lose their leading
# character, exactly like the live incident; every delivery (corrupted or not) is
# appended to FM_FAKE_DELIVERED so a case can assert what the pane received. A
# delivered line of the form `touch <path>` is then executed for real, which is
# the only way the readiness marker can ever appear - and, exactly like a real
# shell, a head-truncated form is not that shape and creates nothing.
#
# FM_FAKE_SEND_FAIL_STATUS models the other failure mode: a send channel that
# reports the given exit status and delivers nothing at all, which is what a
# closed or renumbered pane looks like to the adapters. FM_FAKE_SEND_FAIL_ATTEMPTS
# narrows that to a list of attempt numbers, which models a channel that hiccups
# and then recovers rather than one that is simply dead.
make_lossy_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log_delivery() {
  local line=$1 path
  printf '%s\n' "$line" >> "${FM_FAKE_DELIVERED:?FM_FAKE_DELIVERED unset}"
  case "$line" in
    touch\ /*)
      path=${line#touch }
      path=${path% 2>/dev/null}
      : > "$path"
      ;;
  esac
}
case "$*" in
  *'#{pane_current_path}'*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  send-keys)
    shift
    literal=0
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) args+=("$1"); shift ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      # A literal send types without submitting, so it is not a delivery yet.
      printf 'literal %s\n' "${args[0]:-}" >> "${FM_FAKE_DELIVERED:?}"
      exit 0
    fi
    if [ "${#args[@]}" -eq 1 ]; then
      # A bare key: the gate's retry pre-clear Enter, or the launch submit.
      printf 'key %s\n' "${args[0]}" >> "${FM_FAKE_DELIVERED:?}"
      exit 0
    fi
    text=${args[0]}
    if [ -n "${FM_FAKE_SEND_FAIL_STATUS:-}" ]; then
      # A send channel that reports failure and delivers nothing. Attempts are
      # numbered on their own counter, so a failed send never advances the
      # delivery numbering the loss window keys on. With no attempt list every
      # attempt fails; with one, only the listed attempt numbers do, which is how
      # a case models a channel that hiccups between delivered probes. The
      # attempt is recorded either way so a case can count what the caller made.
      attemptfile="${FM_FAKE_DELIVERY_COUNTFILE:?}.send-attempts"
      a=0
      [ -f "$attemptfile" ] && a=$(cat "$attemptfile")
      a=$((a + 1))
      printf '%s\n' "$a" > "$attemptfile"
      fail_this=1
      if [ -n "${FM_FAKE_SEND_FAIL_ATTEMPTS:-}" ]; then
        fail_this=0
        for want in ${FM_FAKE_SEND_FAIL_ATTEMPTS}; do
          [ "$want" = "$a" ] && fail_this=1
        done
      fi
      if [ "$fail_this" = 1 ]; then
        printf 'send-failed %s\n' "$FM_FAKE_SEND_FAIL_STATUS" >> "${FM_FAKE_DELIVERED:?}"
        exit "$FM_FAKE_SEND_FAIL_STATUS"
      fi
    fi
    countfile="${FM_FAKE_DELIVERY_COUNTFILE:?FM_FAKE_DELIVERY_COUNTFILE unset}"
    seenfile="$countfile.post-treehouse"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -ge "${FM_FAKE_SWALLOW_FROM:-1}" ] \
       && [ "$n" -le "${FM_FAKE_SWALLOW_UNTIL:-0}" ]; then
      text=${text:1}
    elif [ -f "$seenfile" ]; then
      used=$(cat "$seenfile")
      if [ "$used" -lt "${FM_FAKE_SWALLOW_AFTER_TREEHOUSE:-0}" ]; then
        text=${text:1}
        printf '%s\n' "$((used + 1))" > "$seenfile"
      fi
    fi
    # Opening the post-treehouse window on the delivery CONTENT, not on a
    # delivery number, keeps the case independent of how many probes the
    # implementation sends - so it still corrupts the launch environment when the
    # gate is absent, which is what makes the case non-vacuous.
    if [ "$text" = 'treehouse get' ] && [ ! -f "$seenfile" ]; then
      printf '0\n' > "$seenfile"
    fi
    log_delivery "$text"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home plus a real project/worktree pair, and
# echoes the per-case paths the run helper needs.
#
# Each case also gets its own empty TMPDIR. The gate derives its probe directory
# from TMPDIR, so a case-private root is what makes the leak assertion hermetic:
# the real-backend smoke suites in this same family run the gate unbypassed and
# would otherwise be writing identically named directories into the shared
# ambient TMPDIR while this suite counted them.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_lossy_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/tmp"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$home" "$proj" "$wt" "$fakebin" "$case_dir/delivered" "$case_dir/delivery-count" \
    "$case_dir/tmp"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR DELIVERED COUNTFILE CASE_TMP <<EOF
$1
EOF
}

# run_spawn <id> <swallow-from> <swallow-until> [extra KEY=VAL ...]
run_spawn() {
  local id=$1 from=$2 upto=$3
  shift 3
  # SPAWN_BACKEND selects an explicit backend for the one case that needs a
  # non-reference adapter; unset keeps every other case on the fake tmux.
  local -a spawn_args
  spawn_args=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  [ -z "${SPAWN_BACKEND:-}" ] || spawn_args+=(--backend "$SPAWN_BACKEND")
  # -u FM_SPAWN_READY_BYPASS: tests/lib.sh exports that bypass for every
  # fixture-based suite, and this is the suite whose whole subject is the gate.
  env -u FM_SPAWN_READY_BYPASS "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_DELIVERED="$DELIVERED" \
    FM_FAKE_DELIVERY_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SWALLOW_FROM="$from" FM_FAKE_SWALLOW_UNTIL="$upto" \
    FM_FAKE_SWALLOW_AFTER_TREEHOUSE="${FM_FAKE_SWALLOW_AFTER_TREEHOUSE:-0}" \
    FM_SPAWN_READY_INTERVAL=0.05 FM_SPAWN_READY_RESEND_EVERY=1 \
    TMPDIR="$CASE_TMP" \
    PATH="$FAKEBIN_DIR:$PATH" \
    FM_FAKE_CMUX_STATE="${CMUX_STATE:-}" \
    "$SPAWN" "${spawn_args[@]}" 2>&1
}

# install_cmux_fake <fakebin-dir> adds a `cmux` CLI stub keyed on COMMAND SHAPE,
# not on an ordered response queue, so the number of readiness probes a case
# provokes cannot desynchronize it.
#
# It models exactly the calls a cmux ship spawn makes before the first gate, plus
# one failure mode: every `send-key` fails. That is what makes the real adapter
# return status 2 - fm_backend_cmux_send_text_line types the line, fails to
# submit it with Enter, then fails to clear it with C-c, which is the "input
# could not be cleared" condition only zellij and cmux define.
install_cmux_fake() {
  local fakebin=$1
  cat > "$fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_CMUX_STATE:?FM_FAKE_CMUX_STATE unset}"
case "${1:-}" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
  new-workspace)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) printf '%s\n' "${2:-}" > "$STATE/title"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  workspace)
    if [ "${2:-}" = list ]; then
      if [ -f "$STATE/title" ]; then
        printf '{"workspaces":[{"id":"ws-1","title":"%s"}]}\n' "$(cat "$STATE/title")"
      else
        printf '{"workspaces":[]}\n'
      fi
      exit 0
    fi
    exit 0
    ;;
  list-panes)
    printf '{"panes":[{"selected_surface_id":"sf-1","surface_ids":["sf-1"]}]}\n'
    exit 0
    ;;
  send)
    printf 'literal %s\n' "${!#}" >> "${FM_FAKE_DELIVERED:?}"
    exit 0
    ;;
  send-key)
    printf 'key %s\n' "${!#}" >> "${FM_FAKE_DELIVERED:?}"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/cmux"
}

# delivered_line_count <exact-line>
delivered_line_count() {
  grep -c -x -F -- "$1" "$DELIVERED" 2>/dev/null || true
}

# count_probe_scratch: probe directories left in THIS case's private probe root.
# Scoped to the case so no concurrent spawn elsewhere can decide the verdict.
count_probe_scratch() {
  find "$CASE_TMP" -maxdepth 1 -name 'fm-spawn-ready.*' 2>/dev/null | wc -l | tr -d ' '
}

# delivered_prefix_count <prefix>: delivered lines that START with <prefix>.
# Anchored on purpose: every truncated form this suite must catch is a substring
# of its intact form (`reehouse get` sits inside `treehouse get`), so an
# unanchored match cannot tell the two apart.
delivered_prefix_count() {
  awk -v want="$1" 'index($0, want) == 1 { n++ } END { print n + 0 }' \
    "$DELIVERED" 2>/dev/null || printf '0\n'
}

# assert_delivered_prefix <prefix> <msg>
assert_delivered_prefix() {
  [ "$(delivered_prefix_count "$1")" -gt 0 ] || fail \
    "$2 (no delivered line starts with '$1')"$'\n'"--- delivered ---"$'\n'"$(cat "$DELIVERED" 2>/dev/null)"
}

# assert_not_delivered_prefix <prefix> <msg>
assert_not_delivered_prefix() {
  [ "$(delivered_prefix_count "$1")" -eq 0 ] || fail \
    "$2 (a delivered line starts with '$1')"$'\n'"--- delivered ---"$'\n'"$(cat "$DELIVERED" 2>/dev/null)"
}

# assert_only_probes_delivered <msg>: nothing but readiness probes and the
# gate's own bookkeeping keys ever reached the pane.
#
# Stated as a whole-file invariant rather than as a list of forbidden spellings
# on purpose. A case that truncates EVERY delivery cannot detect a leaked send by
# the intact text - `treehouse get` would arrive as `reehouse get` and no
# prefix-anchored check on the intact form could ever fire. A probe line is an
# intact `touch <marker>` or one of its head-truncated forms, and every marker
# lives under a `fm-spawn-ready.` directory and is named `ready` before the
# probe's own stderr redirect, so anything else on the wire is a leak whichever
# way it arrived.
assert_only_probes_delivered() {
  local stray
  stray=$(awk '
    /^key / { next }
    index($0, "fm-spawn-ready.") > 0 && /\/ready( 2>\/dev\/null)?$/ { next }
    { print }
  ' "$DELIVERED" 2>/dev/null)
  [ -z "$stray" ] || fail \
    "$1"$'\n'"--- non-probe deliveries ---"$'\n'"$stray"
}

# The live incident: the first three deliveries lose their leading byte. The
# gate must absorb all three on its own probe and hand the pane an intact
# `treehouse get`, never the truncated `reehouse get` that reached it before.
test_swallowed_leading_bytes_never_corrupt_the_first_command() {
  local rec id out status
  id=first-send-swallow-three-a1
  rec=$(make_case swallow-three "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 3)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the gate absorbs the lossy window"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_delivered_prefix "treehouse get" \
    "the pane never received an intact treehouse get"
  assert_not_delivered_prefix "reehouse get" \
    "the pane received a head-truncated treehouse get - the gate did not absorb the loss"
  [ "$(delivered_line_count 'treehouse get')" = 1 ] \
    || fail "treehouse get was not delivered exactly once"
  pass "a lossy shell init cannot corrupt the first command line"
}

# The loss window opens only AFTER treehouse get, so the second gate - the one
# covering the launch environment sent into treehouse's new subshell - is the one
# that has to absorb it. That send is the path a leading-space mitigation on the
# treehouse line alone leaves unprotected.
test_second_gate_protects_the_launch_environment() {
  local rec id out status
  id=first-send-swallow-later-b2
  rec=$(make_case swallow-later "$id")
  read_case "$rec"

  # The lossy window opens on the delivery AFTER treehouse get lands, so it
  # corrupts only the post-subshell sends however many probes precede them.
  out=$(FM_FAKE_SWALLOW_AFTER_TREEHOUSE=3 run_spawn "$id" 1 0)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the second gate absorbs the lossy window"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_delivered_prefix "treehouse get" \
    "the pane never received an intact treehouse get"
  assert_delivered_prefix "export GOTMPDIR=" \
    "the pane never received an intact launch environment"
  assert_not_delivered_prefix "xport GOTMPDIR=" \
    "the pane received a head-truncated launch environment - that send was unguarded"
  pass "the launch-environment send is guarded too, not only treehouse get"
}

# A shell that never accepts a line must stop the spawn loudly. Silently
# proceeding is the exact failure this change exists to remove, so the refusal
# has to be an error exit that names the send it refused - and no task command
# may reach the pane after it.
test_unready_shell_fails_loudly() {
  local rec id out status
  id=first-send-never-ready-c3
  rec=$(make_case never-ready "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 100000 FM_SPAWN_READY_POLLS=3)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn exited 0 with a shell that never accepted a command line"
  assert_contains "$out" "never confirmed it can read a command line" \
    "the refusal did not explain that the pane shell was never proven ready"
  assert_contains "$out" "treehouse get" \
    "the refusal did not name the send it refused"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite an unready shell"
  assert_only_probes_delivered \
    "a task command reached the pane after the readiness gate had given up"
  # Each resend flushes whatever a prior attempt left half-typed, so it cannot be
  # concatenated onto the next probe. It must be a bare Enter and never an
  # interrupt: the pane may still be running productive work at this point.
  [ "$(delivered_line_count 'key Enter')" -ge 1 ] \
    || fail "the gate's resends never flushed the input line, so a half-typed probe would be concatenated onto the next one"
  [ "$(delivered_line_count 'key C-c')" = 0 ] \
    || fail "the gate sent an interrupt into the pane, which can signal foreground work such as treehouse get"
  pass "an unready pane shell refuses the spawn loudly instead of sending into it"
}

# The gate must not tax a healthy spawn: a shell that answers the first probe
# costs one poll interval per gated send, not a retry cycle. It must also run
# BEFORE the command it protects, which the delivery order proves.
test_healthy_shell_pays_one_probe_per_gate() {
  local rec id out status start end elapsed first_line
  id=first-send-healthy-d4
  rec=$(make_case healthy "$id")
  read_case "$rec"

  start=$(date +%s)
  out=$(run_spawn "$id" 1 0)
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed against a healthy shell"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  first_line=$(sed -n '1p' "$DELIVERED")
  case "$first_line" in
    touch\ /*) : ;;
    *) fail "the readiness probe did not precede the first task command (first delivery: '$first_line')" ;;
  esac
  # The count the case name claims, pinned exactly. The fake shell creates the
  # marker synchronously inside the send, so a healthy gate's very next marker
  # check succeeds and each of the two gates owes exactly one probe. A regression
  # that re-probed on the next stride before checking would slide under the 8s
  # bound and leave every other assertion here true.
  [ "$(delivered_prefix_count 'touch ')" = 2 ] \
    || fail "a healthy spawn sent $(delivered_prefix_count 'touch ') readiness probes, not one per gate"
  [ "$(delivered_line_count 'key Enter')" = 1 ] \
    || fail "a healthy spawn should send exactly one bare Enter, the launch submit"
  [ "$elapsed" -le 8 ] || fail "a healthy spawn took ${elapsed}s - the gate is charging retries it should not need"
  pass "a healthy pane answers the first probe, and the probe precedes the command it guards"
}

# The probe directory is scratch: it must never survive the spawn, on the
# success path or the refusal path.
#
# Each half runs against its own fully scaffolded fixture with its own empty
# probe root, so the count is an absolute zero attributable to that one spawn
# rather than a before/after diff of state anything else can write. The refusal
# half needs a real brief: an id without one dies at fm-spawn's brief check long
# before a pane or a probe directory exists, so its cleanup assertion would pass
# vacuously. The case therefore proves the refusal came from the readiness gate
# before it trusts what that gate left behind.
test_probe_scratch_is_cleaned_up() {
  local rec id out status
  id=first-send-scratch-e5
  rec=$(make_case scratch "$id")
  read_case "$rec"
  out=$(run_spawn "$id" 1 0)
  status=$?
  expect_code 0 "$status" "the success half of the cleanup case never spawned"
  assert_contains "$out" "spawned $id" "the success half of the cleanup case never spawned"
  [ "$(count_probe_scratch)" = 0 ] \
    || fail "readiness probe scratch survived a successful spawn ($(count_probe_scratch) left in $CASE_TMP)"

  id=first-send-scratch-refused-g7
  rec=$(make_case scratch-refused "$id")
  read_case "$rec"
  out=$(run_spawn "$id" 1 100000 FM_SPAWN_READY_POLLS=2)
  status=$?
  [ "$status" -ne 0 ] || fail "the refusal half of the cleanup case did not refuse"
  assert_contains "$out" "never confirmed it can read a command line" \
    "the refusal half never reached the readiness gate, so its cleanup is unproven"
  [ "$(count_probe_scratch)" = 0 ] \
    || fail "readiness probe scratch survived a refused spawn ($(count_probe_scratch) left in $CASE_TMP)"
  pass "readiness probe scratch is removed on both the success and refusal paths"
}

# A send channel that reports failure is not a pane refusing to answer, and the
# refusal has to say so. Before the gate existed, a non-zero send aborted the
# spawn at once under set -eu; swallowing the status would instead spend the whole
# poll budget and then blame the pane's shell for a probe that never left the box.
test_broken_send_channel_refuses_on_the_channel_not_the_pane() {
  local rec id out status start end elapsed
  id=first-send-dead-channel-k1
  rec=$(make_case dead-channel "$id")
  read_case "$rec"

  start=$(date +%s)
  out=$(run_spawn "$id" 1 0 FM_FAKE_SEND_FAIL_STATUS=1)
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$status" -ne 0 ] || fail "a send channel that delivered no probe at all still spawned"
  assert_contains "$out" "send path is failing, not its shell" \
    "the refusal did not attribute the failure to the send channel"
  assert_not_contains "$out" "never confirmed it can read a command line" \
    "a send-channel failure was reported with the pane-shell timeout message"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite a dead send channel"
  # One bounded retry, then refuse - not the whole poll budget. run_spawn's
  # 300 polls at 0.05s would be 15s if the status were swallowed.
  [ "$(delivered_line_count 'send-failed 1')" = 2 ] \
    || fail "the gate made $(delivered_line_count 'send-failed 1') probe attempts, not one bounded retry"
  [ "$elapsed" -le 8 ] \
    || fail "a dead send channel cost ${elapsed}s - the gate spent its poll budget instead of refusing on the send error"
  pass "a failing send channel refuses promptly and names the channel, not the pane"
}

# Status 2 means "input could not be cleared" only on zellij and cmux, which are
# the adapters that define it. This suite drives the reference tmux backend, where
# 2 carries no such meaning - orca, for instance, returns it for invalid JSON or an
# ok:false response - so it must get the ordinary bounded retry and a refusal that
# does not name a cause the backend never reported.
test_status_2_is_not_read_as_uncleared_input_on_tmux() {
  local rec id out status
  id=first-send-status2-m2
  rec=$(make_case status2 "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 0 FM_FAKE_SEND_FAIL_STATUS=2)
  status=$?
  [ "$status" -ne 0 ] || fail "a send channel returning status 2 still spawned"
  assert_not_contains "$out" "probe input could not be cleared" \
    "a tmux send failure was blamed on an uncleared input line, which tmux never reports"
  assert_contains "$out" "send path is failing" \
    "the refusal did not attribute the failure to the send channel"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite a failing send channel"
  [ "$(delivered_line_count 'send-failed 2')" = 2 ] \
    || fail "status 2 skipped the bounded retry every other backend gets ($(delivered_line_count 'send-failed 2') attempts)"
  pass "status 2 is read as uncleared input only on the adapters that define it"
}

# The other half of the same contract, on a backend that really does define
# status 2 as "input could not be cleared". There the typed `touch <marker>` is
# sitting on the pane's input line with no way to clear it, so retrying would
# concatenate the next probe onto it: the refusal has to fire on sight and say
# what the adapter actually reported.
test_uncleared_probe_input_is_terminal_on_cmux() {
  local rec id out status
  id=first-send-cmux-uncleared-p4
  rec=$(make_case cmux-uncleared "$id")
  read_case "$rec"
  install_cmux_fake "$FAKEBIN_DIR"
  CMUX_STATE="$CASE_TMP/cmux"
  mkdir -p "$CMUX_STATE"

  out=$(SPAWN_BACKEND=cmux run_spawn "$id" 1 0)
  status=$?
  CMUX_STATE=
  [ "$status" -ne 0 ] || fail "a cmux endpoint whose input could not be cleared still spawned"
  assert_contains "$out" "probe input could not be cleared" \
    "the refusal did not report the uncleared input line the cmux adapter signalled"
  assert_not_contains "$out" "send path is failing" \
    "an uncleared-input failure fell through to the retryable send-channel path"
  assert_not_contains "$out" "never confirmed it can read a command line" \
    "an uncleared-input failure was reported with the pane-shell timeout message"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite uncleared pane input"
  # Terminal on sight: exactly one probe was typed, so no second probe could be
  # concatenated onto the line the adapter could not clear.
  [ "$(delivered_prefix_count 'literal touch ')" = 1 ] \
    || fail "the gate typed $(delivered_prefix_count 'literal touch ') probes into a pane whose input it could not clear, instead of refusing on sight"
  pass "an uncleared-input send failure is terminal on sight on the adapters that define it"
}

# The bounded retry must count CONSECUTIVE failures. This is the gate's own target
# scenario: a pane eating every probe's leading bytes while the channel itself is
# merely intermittent. Two hiccups separated by delivered probes must still be
# refused as a pane-shell timeout, because that is what actually happened - a
# cumulative counter would abort on the send channel and name the wrong fault.
test_intermittent_send_hiccups_still_refuse_on_the_pane() {
  local rec id out status
  id=first-send-hiccup-n3
  rec=$(make_case hiccup "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 100000 FM_SPAWN_READY_POLLS=6 \
    FM_FAKE_SEND_FAIL_STATUS=1 FM_FAKE_SEND_FAIL_ATTEMPTS='1 3')
  status=$?
  [ "$status" -ne 0 ] || fail "a pane that never answered a probe still spawned"
  assert_contains "$out" "never confirmed it can read a command line" \
    "two non-consecutive send hiccups were reported as a broken send channel instead of an unready pane"
  assert_not_contains "$out" "send path is failing" \
    "a channel that delivered probes between two hiccups was declared broken"
  # Both hiccups really happened, so the case is exercising the path it claims.
  [ "$(delivered_line_count 'send-failed 1')" = 2 ] \
    || fail "the fixture produced $(delivered_line_count 'send-failed 1') send hiccups, not the two this case needs"
  pass "intermittent send hiccups do not turn an unready pane into a send-channel abort"
}

# The probe root is derived from an INHERITED TMPDIR, so a TMPDIR that cannot
# carry an unquoted probe line must not fail the spawn. fm-spawn worked in such
# an environment before this gate existed, and the pane is not at fault, so the
# probe falls back to the fixed /tmp root and says so once instead of refusing.
test_unusable_tmpdir_falls_back_instead_of_refusing() {
  local rec id out status
  id=first-send-odd-tmpdir-j9
  rec=$(make_case odd-tmpdir "$id")
  read_case "$rec"
  mkdir -p "$CASE_TMP/has space"
  CASE_TMP="$CASE_TMP/has space"

  out=$(run_spawn "$id" 1 0)
  status=$?
  expect_code 0 "$status" \
    "a TMPDIR that cannot carry an unquoted probe line refused the spawn instead of falling back"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "falling back to /tmp" \
    "the probe root fallback was silent, so the condition is invisible to the captain"
  assert_delivered_prefix "treehouse get" \
    "the pane never received an intact treehouse get, so the fallback probe never proved readiness"
  [ "$(count_probe_scratch)" = 0 ] \
    || fail "a probe directory was created under the unusable root instead of the fallback"
  pass "an unusable TMPDIR falls back to /tmp with a notice instead of failing the spawn"
}

# A misconfigured budget knob must not brick spawning. A zero poll count would
# otherwise skip the probe loop entirely and refuse every spawn with a message
# blaming a pane that was never asked anything, so it falls back to the default.
test_misconfigured_budget_knob_falls_back_to_its_default() {
  local rec id out status
  id=first-send-bad-knob-h8
  rec=$(make_case bad-knob "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 0 FM_SPAWN_READY_POLLS=0)
  status=$?
  expect_code 0 "$status" "a zero poll count refused a spawn a healthy pane should have passed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "never confirmed it can read a command line" \
    "a zero poll count made the gate blame the pane instead of falling back to its default"
  assert_delivered_prefix "treehouse get" \
    "the pane never received an intact treehouse get"
  pass "a zero budget knob falls back to its default instead of refusing every spawn"
}

# The fixture escape hatch has to be explicit, and it has to be the ONLY thing
# that stands the gate down: the same never-ready pane that refuses above must
# spawn when FM_SPAWN_READY_BYPASS=1 is set, and only then. Pinning both halves
# keeps a future change from quietly turning the gate into a no-op by default.
test_fixture_bypass_is_explicit() {
  local rec id out status
  id=first-send-bypass-f6
  rec=$(make_case bypass "$id")
  read_case "$rec"

  out=$(run_spawn "$id" 1 100000 FM_SPAWN_READY_POLLS=3 FM_SPAWN_READY_BYPASS=1)
  status=$?
  expect_code 0 "$status" "an explicitly bypassed gate should not stop a fixture spawn"
  assert_contains "$out" "spawned $id" "the bypassed spawn did not report success"
  assert_not_contains "$out" "never confirmed it can read a command line" \
    "the gate still refused despite an explicit bypass"
  pass "the gate stands down only for an explicit fixture bypass"
}

test_swallowed_leading_bytes_never_corrupt_the_first_command
test_second_gate_protects_the_launch_environment
test_unready_shell_fails_loudly
test_healthy_shell_pays_one_probe_per_gate
test_misconfigured_budget_knob_falls_back_to_its_default
test_broken_send_channel_refuses_on_the_channel_not_the_pane
test_status_2_is_not_read_as_uncleared_input_on_tmux
test_uncleared_probe_input_is_terminal_on_cmux
test_intermittent_send_hiccups_still_refuse_on_the_pane
test_unusable_tmpdir_falls_back_instead_of_refusing
test_fixture_bypass_is_explicit
test_probe_scratch_is_cleaned_up

echo "# all fm-spawn-first-send tests passed"
