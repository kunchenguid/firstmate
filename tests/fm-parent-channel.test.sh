#!/usr/bin/env bash
# The parent escalation channel: a decision closes in the channel where it opened.
#
# A secondmate home and its parent home keep SEPARATE status logs. The mate
# escalates onto the parent's own log (state/<mate>.status under the parent
# home, or the mirrored parent-replies.status on a remote route), and that log
# is the only decision surface the parent's OPEN DECISIONS fold reads for that
# mate.
#
# The forensic failure these tests pin (2026-08-23, key
# wi812-codex-review-4-scope): the same key existed in TWO copies - opened by
# the mate in the parent channel, and opened by its worker in the worker's own
# local status - and the mate's answer closed only the worker's copy, because
# fm-send --resolve-key pointed at the WORKER. Neither copy knew about the
# other, so the parent's fold showed an answered, already-executed decision as
# open forever and the parent had to close it by hand. A second gap sat next to
# it: a mate-ORIGINATED escalation had no mechanism to reach the parent channel
# at all, because the only correlated-report helper demanded a corr= id that a
# self-raised decision has by contract.
#
# Chosen resolution: tag relayed opens with their originating task and propagate
# a close only to the upstream copy owned by the answered task. The parent's log
# is a real append-only stream that wake classification, crew-state,
# pending-reply resolution, and the open-decision fold all read directly; it
# cannot become a projection of some other owner without a new source of truth
# spanning two independent homes with no shared transaction. Serialized channel
# writes make same-task retries idempotent and reject a different task reusing an
# already-open key.
#
# These tests drive the real executables and assert through the real consumer
# (fm-wake-drain.sh's OPEN DECISIONS section for the parent home), never
# through source text:
#   1. FULL CYCLE: the mate opens a keyed decision in the parent channel, the
#      parent sees it, the answer is sent pointing AT THE WORKER, and the
#      parent's fold comes out clean.
#   2. A mate-ORIGINATED escalation that nobody asked for reaches the parent
#      channel, with no corr= id.
#   3. A remote-route home escalates and closes onto its mirrored channel.
#   4. A primary home is untouched, and a secondmate home whose parent binding
#      is unreadable refuses loudly instead of closing only locally.
#   5. The reserved pending-reply-<id> namespace keeps its single owner: a
#      close aimed at it never propagates a foreign line into the parent
#      channel.
#   6. Conflicting same-key opens and answers for another task fail before any
#      decision or delivery state changes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-parent-channel)

# Stub tmux so the submit path reaches a clean "empty" verdict, and stub sleep.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
root=${FM_FAKE_TASKS_STATE:-}
case "${1:-}:${2:-}" in
  --version:) printf 'tasks-axi 0.2.4\n' ;;
  update:--help) printf '%s\n' 'usage: tasks-axi update <id> --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
  hold:--help) printf '%s\n' 'usage: tasks-axi hold <id> --kind captain' ;;
  show:*)
    [ -n "$root" ] && [ -f "$root/$2.state" ] || exit 1
    state=$(cat "$root/$2.state")
    hold_kind=$(cat "$root/$2.hold" 2>/dev/null || true)
    body=$(cat "$root/$2.body" 2>/dev/null || true)
    body_json=$(printf '%s' "$body" | perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)')
    printf '  state: %s\n  hold_kind: %s\n  body: %s\n' "$state" "${hold_kind:--}" "$body_json"
    ;;
  update:*)
    [ -n "$root" ] || exit 1
    id=$2
    shift 2
    body_file=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file) shift; body_file=${1:-} ;;
      esac
      shift
    done
    [ -n "$body_file" ] || exit 1
    cp "$body_file" "$root/$id.body"
    ;;
  done:*)
    [ -n "$root" ] || exit 1
    printf 'done\n' > "$root/$2.state"
    ;;
  unhold:*)
    [ -n "$root" ] || exit 1
    printf '%s\n' '-' > "$root/$2.hold"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

# A parent home plus a LOCAL-route secondmate home bound to it.
# Echoes "<parent-home> <mate-home>".
setup_pair() {  # <name> <mate-id>
  local base="$TMP_ROOT/$1-$RANDOM" parent mate id=$2
  parent="$base/parent"; mate="$base/mate"
  mkdir -p "$parent/state" "$parent/data" "$mate/state" "$mate/data"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$parent"
  } > "$mate/.fm-secondmate-parent"
  printf '%s %s\n' "$parent" "$mate"
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

run_send() {  # <fakebin> <home> <log> <fm-send args...>
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

resolve_channel() {  # <home> <state>
  FM_HOME="$1" FM_STATE_OVERRIDE="$2" bash -c '
    . "$1"
    fm_parent_channel_path "$2" "$3" >/dev/null
  ' _ "$ROOT/bin/fm-parent-channel-lib.sh" "$1" "$2"
}

dispatch_channel() {  # <home> <state> <dispatch args...>
  local home=$1 state=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    . "$2"
    . "$3"
    shift 3
    fm_parent_channel_append "$@"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-parent-channel-lib.sh" "$@"
}

fold_status() {  # <status-path>
  bash -c '. "$1"; status_open_decisions "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$1"
}

# ---------------------------------------------------------------------------
# 1. The full cycle, exactly as it failed in the field.
# ---------------------------------------------------------------------------
test_full_cycle_close_reaches_parent_channel() {
  local dir fb log parent mate pair rc out
  dir="$TMP_ROOT/full-cycle"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair full-cycle amplifica)
  parent=${pair% *}; mate=${pair#* }

  # (a) The mate's worker raises a keyed decision in the mate's own home, and
  #     the mate escalates that same key onto the PARENT channel.
  fm_write_meta "$mate/state/wi812.meta" "window=sess:fm-wi812" "kind=ship"
  printf 'needs-decision [key=review-4-scope]: fix 24+25, defer 26/27/28?\n' \
    > "$mate/state/wi812.status"
  printf 'needs-decision [key=review-4-scope] [task=wi812]: relaying my worker: fix 24+25, defer 26/27/28?\n' \
    > "$parent/state/amplifica.status"

  # (b) The parent sees it.
  out=$(drain_out "$parent")
  printf '%s' "$out" | grep -F '[key=review-4-scope]' >/dev/null \
    || fail "precondition: the escalated decision should list as open in the parent's fold: $out"

  # (c)+(d) The answer is sent pointing AT THE WORKER - the exact field case.
  run_send "$fb" "$mate" "$log" wi812 --resolve-key review-4-scope \
    "fix 24+25, defer 26/27/28"; rc=$?
  expect_code 0 "$rc" "answering the worker with --resolve-key should succeed"
  grep -F 'resolved [key=review-4-scope]' "$mate/state/wi812.status" >/dev/null \
    || fail "the worker's own copy was not closed: $(cat "$mate/state/wi812.status")"

  # (e) The parent's fold must come out clean. THIS is what regressed.
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=review-4-scope]' >/dev/null; then
    fail "the answered decision is STILL open in the parent's fold; the close never left the mate's home:"$'\n'"--- parent channel ---"$'\n'"$(cat "$parent/state/amplifica.status")"$'\n'"--- drain ---"$'\n'"$out"
  fi
  grep -F 'resolved [key=review-4-scope]' "$parent/state/amplifica.status" >/dev/null \
    || fail "no closing line reached the parent channel: $(cat "$parent/state/amplifica.status")"
  pass "parent channel: a close aimed at the worker also closes the key the mate opened upstream"
}

test_answer_enumerates_every_live_ledger() {
  local dir fb log parent mate pair tasks rc out
  dir="$TMP_ROOT/all-ledgers"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; tasks="$dir/tasks"
  mkdir -p "$tasks"
  pair=$(setup_pair all-ledgers ledger-mate)
  parent=${pair% *}; mate=${pair#* }

  fm_write_meta "$mate/state/w7.meta" "window=sess:fm-w7" "kind=ship"
  printf 'captain-held [key=all-copies]: tracked by all-copies\n' > "$mate/state/w7.status"
  printf 'needs-decision [key=all-copies] [task=w7]: choose a or b\n' > "$parent/state/ledger-mate.status"
  printf 'queued\n' > "$tasks/all-copies.state"
  printf 'captain\n' > "$tasks/all-copies.hold"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 FM_FAKE_TASKS_STATE="$tasks" \
    "$SEND" w7 --resolve-key all-copies "choose a" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "one answer should close every ledger that claims the key"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=all-copies]' >/dev/null; then
    fail "the parent-channel copy remained open after the shared answer: $out"
  fi
  [ "$(cat "$tasks/all-copies.state")" = 'done' ] \
    || fail "the local captain-held copy was not closed by the shared answer"

  fm_write_meta "$mate/state/w8.meta" "window=sess:fm-w8" "kind=ship"
  printf 'working: no decision here\n' > "$mate/state/w8.status"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 FM_FAKE_TASKS_STATE="$tasks" \
    "$SEND" w8 --resolve-key nowhere "choose a" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a key claimed by no ledger was still sent"
  [ ! -s "$log" ] || fail "the no-ledger refusal still typed text: $(cat "$log")"
  pass "parent channel: one answer closes every claiming ledger and none means refusal"
}

# Reopening a key is a new decision lifetime even when its answer repeats, while
# repeating a close against an already-closed lifetime remains a no-op.
test_reopened_key_closes_and_close_replay_is_idempotent() {
  local dir parent mate pair rc n out channel receipt event
  dir="$TMP_ROOT/idem"; mkdir -p "$dir"
  pair=$(setup_pair idem beta)
  parent=${pair% *}; mate=${pair#* }
  channel="$parent/state/beta.status"
  receipt='done [key=inactive-outcome-beta-w1-done]: inactive terminal child=w1 fingerprint=abc123'
  event='working: identical wake-worthy event'

  if dispatch_channel "$mate" "$mate/state"; then
    fail "a parent-channel write without a category was accepted"
  fi
  if dispatch_channel "$mate" "$mate/state" unknown "$channel" "ignored"; then
    fail "a parent-channel write with an unknown category was accepted"
  fi
  [ ! -e "$channel" ] || fail "a refused unclassified write still created the channel"

  dispatch_channel "$mate" "$mate/state" receipt "$channel" "$receipt" \
    || fail "the immutable receipt could not be appended"
  dispatch_channel "$mate" "$mate/state" receipt "$channel" "$receipt" \
    || fail "the immutable receipt replay could not converge"
  n=$(grep -Fc "$receipt" "$channel" || true)
  [ "$n" = 1 ] || fail "the immutable receipt appeared $n times"

  dispatch_channel "$mate" "$mate/state" event "$channel" "$event" \
    || fail "the first repeated event could not be appended"
  dispatch_channel "$mate" "$mate/state" event "$channel" "$event" \
    || fail "the second repeated event could not be appended"
  n=$(grep -Fc "$event" "$channel" || true)
  [ "$n" = 2 ] || fail "two real event occurrences produced $n channel lines"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key dup-guard "a or b" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the first decision open should succeed"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key dup-guard "pick a" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the first decision close should succeed"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key dup-guard "a or b" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the byte-identical decision open should reopen a settled key"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key dup-guard "pick a" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the reopened decision should accept the repeated answer"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=dup-guard]' >/dev/null; then
    fail "the reopened decision stayed open after the repeated answer: $out"
  fi
  n=$(grep -c 'resolved \[key=dup-guard\]' "$channel" || true)
  [ "$n" = 2 ] \
    || fail "two decision lifetimes should have two closes, found $n: $(cat "$channel")"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key dup-guard "pick a" >/dev/null 2>&1 \
    || fail "replaying an already-settled close should succeed"
  n=$(grep -c 'resolved \[key=dup-guard\]' "$channel" || true)
  [ "$n" = 2 ] \
    || fail "an already-settled close replay appended a third line: $(cat "$channel")"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision "default route" >/dev/null 2>&1 \
    || fail "the first default-key decision could not open"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved "same default answer" >/dev/null 2>&1 \
    || fail "the first default-key decision could not close"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision "default route" >/dev/null 2>&1 \
    || fail "the identical default-key decision did not reopen"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved "same default answer" >/dev/null 2>&1 \
    || fail "the reopened default-key decision could not close"
  n=$(grep -c '^resolved \[task=beta\]: same default answer$' "$channel" || true)
  [ "$n" = 2 ] || fail "two default-key lifetimes produced $n closes"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=default]' >/dev/null; then
    fail "the reopened default-key decision stayed open: $out"
  fi
  pass "parent channel: write categories fail closed and retain distinct live semantics"
}

# ---------------------------------------------------------------------------
# 2. A mate-ORIGINATED escalation, with no corr= id, reaches the parent.
# ---------------------------------------------------------------------------
test_mate_originated_escalation_reaches_parent() {
  local dir parent mate pair rc out
  dir="$TMP_ROOT/originated"; mkdir -p "$dir"
  pair=$(setup_pair originated gamma)
  parent=${pair% *}; mate=${pair#* }

  # Nobody asked for this: no marked request, so no corr= id exists by contract.
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key money-risk \
    "review-26/27 look like real money leaving without its discount; decide before I touch them" \
    >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a mate-originated escalation should be deliverable without a corr id"

  grep -F '[key=money-risk]' "$parent/state/gamma.status" >/dev/null \
    || fail "the mate's own escalation never reached the parent channel: $(cat "$parent/state/gamma.status" 2>&1)"
  case "$(cat "$parent/state/gamma.status")" in
    *corr=*) fail "a self-raised escalation must not invent a correlation id" ;;
  esac

  out=$(drain_out "$parent")
  printf '%s' "$out" | grep -F '[key=money-risk]' >/dev/null \
    || fail "the escalation did not reach the parent's OPEN DECISIONS fold: $out"

  # And it closes through the same channel, so the pair is symmetric.
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key money-risk "captain confirmed: scout it separately" \
    >/dev/null 2>&1 || fail "closing a self-raised escalation should succeed"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=money-risk]' >/dev/null; then
    fail "the self-raised escalation stayed open after its own close: $out"
  fi
  pass "parent channel: a self-raised escalation reaches the parent with no corr id, and closes there"
}

# ---------------------------------------------------------------------------
# 3. Remote route: the same two directions land on the mirrored channel.
# ---------------------------------------------------------------------------
test_remote_route_uses_mirrored_channel() {
  local dir mate rc
  dir="$TMP_ROOT/remote-route"; mkdir -p "$dir/state"
  mate="$dir"
  printf 'delta\n' > "$mate/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=remote\n'
  } > "$mate/.fm-secondmate-parent"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate blocked --key vpn-down "cannot reach the forge" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote-route escalation should succeed"
  grep -F '[key=vpn-down]' "$mate/state/parent-replies.status" >/dev/null \
    || fail "a remote-route escalation must land on the mirrored channel: $(ls "$mate/state")"
  [ ! -e "$mate/state/delta.status" ] \
    || fail "a remote-route escalation must not write a local task log"
  pass "parent channel: a remote route escalates onto its mirrored channel, not a local log"
}

# ---------------------------------------------------------------------------
# 4. A primary home is untouched; an unreadable binding fails visibly.
# ---------------------------------------------------------------------------
test_primary_home_unaffected_and_broken_binding_refuses() {
  local dir fb log home rc err mate pair parent out
  dir="$TMP_ROOT/edges"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"

  # A primary home has no parent channel: the close is purely local, unchanged.
  home="$dir/primary"; mkdir -p "$home/state"
  fm_write_meta "$home/state/p1.meta" "window=sess:fm-p1" "kind=ship"
  printf 'needs-decision [key=plain]: a or b\n' > "$home/state/p1.status"
  run_send "$fb" "$home" "$log" p1 --resolve-key plain "a"; rc=$?
  expect_code 0 "$rc" "a primary home's answer must keep working exactly as before"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=plain]' >/dev/null; then
    fail "a primary home's own close regressed: $out"
  fi

  # A secondmate home whose parent binding is unreadable must refuse rather
  # than close only locally and strand the upstream copy in silence.
  pair=$(setup_pair broken epsilon)
  parent=${pair% *}; mate=${pair#* }
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nroute=local\n' \
    > "$mate/.fm-secondmate-parent"
  fm_write_meta "$mate/state/w2.meta" "window=sess:fm-w2" "kind=ship"
  printf 'needs-decision [key=stranded]: a or b\n' > "$mate/state/w2.status"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w2 --resolve-key stranded "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unresolvable parent channel must refuse, not close only locally"
  assert_contains "$(cat "$err")" "parent" "the refusal should name the parent channel"
  [ ! -s "$log" ] || fail "the refused send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$mate/state/w2.status" >/dev/null; then
    fail "the refused send still closed the local copy: $(cat "$mate/state/w2.status")"
  fi
  [ -n "$parent" ] || fail "unreachable"
  pass "parent channel: a primary home is unchanged, and an unreadable binding refuses before sending"
}

# The resolver accepts only a positively usable channel shape.
test_channel_requires_positive_usable_shape() {
  local dir fb log parent mate pair rc err channel target out bad_parent bad_mate bad_pair
  dir="$TMP_ROOT/channel-shapes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  pair=$(setup_pair channel-shapes eta)
  parent=${pair% *}; mate=${pair#* }
  channel="$parent/state/eta.status"

  fm_write_meta "$mate/state/w4.meta" "window=sess:fm-w4" "kind=ship"
  printf 'needs-decision [key=sneaky]: a or b\n' > "$mate/state/w4.status"

  rmdir "$parent/state"
  resolve_channel "$mate" "$mate/state" \
    || fail "an absent channel should resolve after creating its real state directory"
  [ -d "$parent/state" ] && [ ! -L "$parent/state" ] \
    || fail "the resolver did not create a real parent state directory"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate working "first event creates the channel" >/dev/null 2>&1 \
    || fail "the first escalation did not create its absent channel file"
  [ -f "$channel" ] || fail "the first escalation did not create a regular channel file"
  rm -f "$channel"

  out=$(fold_status "$dir/absent.status"); rc=$?
  expect_code 0 "$rc" "a genuinely absent status ledger must still fold successfully"
  [ -z "$out" ] || fail "an absent status ledger unexpectedly reported decisions: $out"

  mkdir "$channel"
  rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
  expect_code 2 "$rc" "a directory in place of the channel must be unresolvable"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w4 --resolve-key sneaky "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular parent channel must refuse before sending"
  [ ! -s "$log" ] || fail "the refused send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$mate/state/w4.status" >/dev/null; then
    fail "the non-regular parent channel still allowed the local copy to close"
  fi
  rmdir "$channel"

  mkfifo "$channel"
  rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
  expect_code 2 "$rc" "a FIFO in place of the channel must be unresolvable"
  rm -f "$channel"

  target="$dir/regular-target"
  printf 'working: target\n' > "$target"
  ln -s "$target" "$channel"
  rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
  expect_code 2 "$rc" "a channel symlink must be unresolvable even when its target is regular"
  rm -f "$channel"

  ln -s "$dir/missing-target" "$channel"
  rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
  expect_code 2 "$rc" "a dangling channel symlink must be unresolvable"
  rm -f "$channel"

  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: read-only parent channel shape cannot be represented for root"
  else
    printf 'needs-decision [key=sneaky]: a or b\n' > "$channel"
    chmod 400 "$channel"
    rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
    expect_code 2 "$rc" "a read-only regular channel must be unresolvable"
    chmod 600 "$channel"
    rm -f "$channel"
  fi

  printf 'needs-decision [key=sneaky]: a or b\n' > "$channel"
  chmod 000 "$channel"
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: unreadable parent channel shape cannot be represented for root"
  else
    rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
    expect_code 2 "$rc" "an unreadable regular channel must be unresolvable"
    rc=0; fold_status "$channel" >/dev/null || rc=$?
    expect_code 2 "$rc" "an unreadable existing ledger must differ from an absent ledger"
    : > "$log"
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" w4 --resolve-key sneaky "a" >/dev/null 2>"$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "an unreadable parent channel did not refuse before sending"
    [ ! -s "$log" ] || fail "the unreadable-channel refusal still typed text: $(cat "$log")"
    if grep -F 'resolved' "$mate/state/w4.status" >/dev/null; then
      fail "the unreadable parent channel allowed the local copy to close"
    fi
    chmod 600 "$channel"
    out=$(drain_out "$parent")
    printf '%s' "$out" | grep -F '[key=sneaky]' >/dev/null \
      || fail "the unreadable-channel refusal lost the still-open upstream decision: $out"
  fi
  chmod 600 "$channel"

  rm -f "$channel"
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: non-writable parent directory shape cannot be represented for root"
  else
    chmod 500 "$parent/state"
    rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
    expect_code 2 "$rc" "an absent channel in a non-writable parent directory must be unresolvable"
    chmod 700 "$parent/state"

    chmod 600 "$parent/state"
    rc=0; resolve_channel "$mate" "$mate/state" || rc=$?
    expect_code 2 "$rc" "an absent channel in a non-searchable parent directory must be unresolvable"
    chmod 700 "$parent/state"
  fi

  bad_pair=$(setup_pair bad-parent-component lambda)
  bad_parent=${bad_pair% *}; bad_mate=${bad_pair#* }
  rmdir "$bad_parent/state"
  printf 'not a directory\n' > "$bad_parent/state"
  rc=0; resolve_channel "$bad_mate" "$bad_mate/state" || rc=$?
  expect_code 2 "$rc" "a regular file in place of the channel parent directory must be unresolvable"

  printf 'needs-decision [key=ordinary]: a or b\n' > "$channel"
  resolve_channel "$mate" "$mate/state" \
    || fail "an ordinary readable and writable channel must remain resolvable"
  pass "parent channel: only a positively usable channel shape resolves"
}

# The identity marker's strictness is a protection, not a convenience: a marker
# carrying more than one line is corrupt, and routing on line one would guess at
# which home this is instead of surfacing the corruption.
test_corrupt_identity_marker_refuses() {
  local dir parent mate pair marker
  dir="$TMP_ROOT/corrupt-marker"; mkdir -p "$dir"
  pair=$(setup_pair corrupt-marker theta)
  parent=${pair% *}; mate=${pair#* }
  marker="$mate/.fm-secondmate-home"

  for bad in 'theta
iota' '../parent' 'has space'; do
    printf '%s\n' "$bad" > "$marker"
    if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
        "$REPORT" --escalate blocked --key corrupt "routing on a corrupt marker" \
        >/dev/null 2>&1; then
      fail "a corrupt identity marker still routed an escalation: $(printf '%s' "$bad" | tr '\n' '/')"
    fi
  done
  [ ! -e "$parent/state/theta.status" ] \
    || fail "a corrupt marker still wrote into the parent home: $(cat "$parent/state/theta.status")"

  # And the well-formed single-line marker still routes, so the check is strict
  # rather than simply broken.
  printf 'theta\n' > "$marker"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate blocked --key corrupt "now it routes" >/dev/null 2>&1 \
    || fail "a well-formed marker should still route"
  grep -F '[key=corrupt]' "$parent/state/theta.status" >/dev/null \
    || fail "the well-formed marker did not reach the parent channel"
  pass "parent channel: a corrupt identity marker refuses, a well-formed one still routes"
}

test_parent_evidence_without_identity_refuses() {
  local dir fb log err parent mate pair rc
  dir="$TMP_ROOT/missing-marker"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  pair=$(setup_pair missing-marker iota)
  parent=${pair% *}; mate=${pair#* }

  fm_write_meta "$mate/state/w5.meta" "window=sess:fm-w5" "kind=ship"
  printf 'needs-decision [key=upstream]: a or b\n' > "$mate/state/w5.status"
  printf 'needs-decision [key=upstream] [task=w5]: a or b\n' > "$parent/state/iota.status"
  rm -f "$mate/.fm-secondmate-home"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w5 --resolve-key upstream "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a parent binding without an identity marker was treated as a primary home"
  assert_contains "$(cat "$err")" "cannot be resolved" "the missing identity must be classified as an unresolvable parent channel"
  [ ! -s "$log" ] || fail "the missing-identity send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$mate/state/w5.status" >/dev/null; then
    fail "the missing-identity send closed only the local copy"
  fi

  mv "$mate/.fm-secondmate-parent" "$mate/parent-binding-record"
  ln -s "$mate/parent-binding-record" "$mate/.fm-secondmate-parent"
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate blocked --key upstream "still waiting" \
      >/dev/null 2>"$err"; then
    fail "symlinked parent evidence without an identity marker was treated as no parent"
  fi
  assert_contains "$(cat "$err")" "cannot be resolved" "symlinked parent evidence must remain unresolvable"
  pass "parent channel: any parent evidence without a usable identity fails visibly"
}

test_long_key_metadata_survives_and_closes() {
  local dir fb log parent mate pair rc out long_key long_note line_len
  dir="$TMP_ROOT/long-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair long-key kappa)
  parent=${pair% *}; mate=${pair#* }
  long_key=$(printf 'k%.0s' {1..175})
  long_note=$(printf 'n%.0s' {1..240})

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key "$long_key" --task w6 "$long_note" \
    >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a key that fits with intact metadata should be accepted"
  grep -F "[key=$long_key]" "$parent/state/kappa.status" >/dev/null \
    || fail "the long opening key was truncated: $(cat "$parent/state/kappa.status")"
  line_len=$(awk 'NR == 1 { print length($0) }' "$parent/state/kappa.status")
  [ "$line_len" -le 220 ] || fail "the capped escalation exceeded 220 characters: $line_len"

  fm_write_meta "$mate/state/w6.meta" "window=sess:fm-w6" "kind=ship"
  printf 'needs-decision [key=%s]: local copy\n' "$long_key" > "$mate/state/w6.status"
  run_send "$fb" "$mate" "$log" w6 --resolve-key "$long_key" "closed"; rc=$?
  expect_code 0 "$rc" "the intact long key should remain closeable by its original value"
  grep -F "resolved [key=$long_key]" "$parent/state/kappa.status" >/dev/null \
    || fail "the long closing key was truncated: $(cat "$parent/state/kappa.status")"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F "[key=$long_key]" >/dev/null; then
    fail "the long key remained open after resolving it with the original value: $out"
  fi
  pass "parent channel: long decision keys preserve metadata and remain closeable"
}

test_same_key_different_task_refuses_before_send() {
  local dir fb log err parent mate pair channel rc before
  dir="$TMP_ROOT/task-provenance"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  pair=$(setup_pair task-provenance provenance-mate)
  parent=${pair% *}; mate=${pair#* }
  channel="$parent/state/provenance-mate.status"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key deploy --task worker-a \
    "worker A needs a deploy choice" >/dev/null 2>&1 \
    || fail "the first task-owned escalation should succeed"
  before=$(cat "$channel")
  assert_contains "$before" "[task=worker-a]" \
    "the relayed decision did not persist its originating task"
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate needs-decision --key deploy --task worker-b \
      "worker B independently needs a deploy choice" >/dev/null 2>"$err"; then
    fail "a conflicting same-key open from another task was treated as a retry"
  fi
  [ "$(cat "$channel")" = "$before" ] \
    || fail "the conflicting open changed the original task-owned decision"
  assert_contains "$(cat "$err")" "could not append" \
    "the conflicting same-key open did not fail loudly"

  fm_write_meta "$mate/state/worker-b.meta" "window=sess:fm-worker-b" "kind=ship"
  printf 'needs-decision [key=deploy]: worker B local copy\n' > "$mate/state/worker-b.status"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" worker-b --resolve-key deploy "deploy B" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "worker B's answer silently closed worker A's upstream decision"
  [ ! -s "$log" ] || fail "the conflicting-key refusal still typed the answer"
  assert_contains "$(cat "$err")" "assigns this key to task 'worker-a', not target task 'worker-b'" \
    "the answer refusal did not identify both conflicting task owners"
  grep -F 'resolved [key=deploy]' "$channel" >/dev/null 2>&1 \
    && fail "worker A's upstream decision was closed by worker B's answer"
  grep -F 'resolved [key=deploy]' "$mate/state/worker-b.status" >/dev/null 2>&1 \
    && fail "the refused answer closed worker B's local decision"

  printf 'needs-decision [key=legacy]: unprovenanced upstream copy\n' >> "$channel"
  fm_write_meta "$mate/state/worker-c.meta" "window=sess:fm-worker-c" "kind=ship"
  printf 'needs-decision [key=legacy]: worker C local copy\n' > "$mate/state/worker-c.status"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" worker-c --resolve-key legacy "answer C" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unprovenanced parent decision was guessed to belong to worker C"
  [ ! -s "$log" ] || fail "the unprovenanced-key refusal still typed the answer"
  assert_contains "$(cat "$err")" "without usable task provenance" \
    "the unprovenanced parent decision did not fail loudly before send"
  pass "parent channel: same-key decisions retain task ownership and conflicts refuse before send"
}

# ---------------------------------------------------------------------------
# 5. The reserved pending-reply-<id> namespace keeps its single owner.
# ---------------------------------------------------------------------------
test_reserved_namespace_is_not_propagated() {
  local dir fb log parent mate pair rc
  dir="$TMP_ROOT/reserved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair reserved zeta)
  parent=${pair% *}; mate=${pair#* }

  # The parent's own library raised this one in the parent channel and is the
  # only thing that may close it.
  printf 'needs-decision [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=x\n' \
    > "$parent/state/zeta.status"
  fm_write_meta "$mate/state/w3.meta" "window=sess:fm-w3" "kind=ship"
  printf 'needs-decision [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=x\n' \
    > "$mate/state/w3.status"

  run_send "$fb" "$mate" "$log" w3 --resolve-key pending-reply-abcdef0123456789 "answered"
  rc=$?
  expect_code 0 "$rc" "the existing reserved-key send behavior must not change"
  if grep -F 'answered' "$parent/state/zeta.status" >/dev/null; then
    fail "a foreign close was propagated into the reserved namespace's channel: $(cat "$parent/state/zeta.status")"
  fi
  # The mate-originated helper must refuse the reserved namespace outright.
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate needs-decision --key pending-reply-abcdef0123456789 "mine now" \
      >/dev/null 2>&1; then
    fail "the escalation helper claimed a reserved key namespace"
  fi
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate needs-decision --key pending-reply-abcdef0123456789 \
      "pending-reply-missed: task=x" >/dev/null 2>&1; then
    fail "owner-like caller text bypassed the reserved key namespace"
  fi
  pass "parent channel: the reserved pending-reply namespace keeps its single owner"
}

test_full_cycle_close_reaches_parent_channel
test_answer_enumerates_every_live_ledger
test_reopened_key_closes_and_close_replay_is_idempotent
test_mate_originated_escalation_reaches_parent
test_remote_route_uses_mirrored_channel
test_primary_home_unaffected_and_broken_binding_refuses
test_channel_requires_positive_usable_shape
test_corrupt_identity_marker_refuses
test_parent_evidence_without_identity_refuses
test_long_key_metadata_survives_and_closes
test_same_key_different_task_refuses_before_send
test_reserved_namespace_is_not_propagated
