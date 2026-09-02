#!/usr/bin/env bash
# tests/fm-secondmate-reconcile.test.sh - the cooldown-limited reconcile ask.
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home no longer
# blanks that home in the fleet snapshot, so the parent asks the home that owns
# those books to fix them. This suite pins that ask: it lands as a real durable
# steering record, a home is asked at most once per cooldown window however
# often the snapshot runs, a mismatch still sitting there after the window
# earns one gentle re-nudge, and the parent never touches the mate's own files.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

RECONCILE="$ROOT/bin/fm-secondmate-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-reconcile)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1

# A main home with one registered, live, local secondmate reachable through the
# fake tmux backend, so fm-send's real inbox plane is exercised end to end.
make_main_home() {  # <name> <mate-id>
  local home="$TMP_ROOT/$1" mate="$TMP_ROOT/$1-mate" id=$2 abs fakebin
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$mate" "$id"
  abs=$(cd "$mate" && pwd -P)
  printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-08-26)\n' \
    "$id" "$abs" > "$home/data/secondmates.md"
  cat > "$home/state/$id.meta" <<META
window=firstmate:fm-$id
kind=secondmate
harness=claude
backend=tmux
spawn_gen=spawn-$id
home=$abs
worktree=$abs
META
  fakebin=$(make_fake_tmux "$TMP_ROOT/$1-fake")
  printf '%s\n' "$home" "$mate" "$fakebin"
}

# A minimal but schema-true fleet snapshot carrying one structured-home record.
write_snapshot() {  # <path> <mate-id> <invalidity-json> [state]
  jq -n --arg id "$2" --argjson inv "$3" --arg state "${4:-captain_decision}" '{
    schema:"fm-fleet-snapshot.v1", generated:"2026-08-26T00:00:00Z",
    secondmate_current:{records:[{
      id:$id, home:("/tmp/" + $id), spawn_gen:("spawn-" + $id),
      current:{state:$state, reason:null},
      invalidity:$inv, reconcile_inventory:($inv // {kind:null,ids:[]}),
      provenance:{selected:"structured-home", trust:"partial-structured"}}]}}' > "$1"
}

# The same shape, but for a persistent REMOTE secondmate: no spawn_gen (its
# parent metadata never carries one), host instead.
write_remote_snapshot() {  # <path> <mate-id> <host> <invalidity-json> [state]
  jq -n --arg id "$2" --arg host "$3" --argjson inv "$4" --arg state "${5:-captain_decision}" '{
    schema:"fm-fleet-snapshot.v1", generated:"2026-08-26T00:00:00Z",
    secondmate_current:{records:[{
      id:$id, home:("/tmp/" + $id), host:$host, spawn_gen:null,
      current:{state:$state, reason:null},
      invalidity:$inv, reconcile_inventory:($inv // {kind:null,ids:[]}),
      provenance:{selected:"structured-home", trust:"partial-structured"}}]}}' > "$1"
}

# A fake ssh that decodes fm-on.sh's base64 remote-home/argv payload and
# EXECUTES the real host-local leg (fm-remote-secondmate-control.sh) against a
# genuinely seeded remote-home fixture, exactly like the ssh stub proven in
# tests/fm-send-remote-delivery.test.sh.
make_remote_ssh_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
home_b64=$3
argv_b64=$4
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
rc=0
if [ "${FM_TEST_RECONCILE_REMOTE_DELAY:-0}" -gt 0 ]; then
  sleep "$FM_TEST_RECONCILE_REMOTE_DELAY"
fi
env FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}" || rc=$?
exit "$rc"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# A seeded remote secondmate home the real host-local leg validates and writes
# into (identity marker, Firstmate-checkout shape, parent-route endpoint meta).
make_remote_secondmate_home() {  # <name> -> echoes remote home dir
  local rh="$TMP_ROOT/$1-rhome"
  mkdir -p "$rh/state/parent-route" "$rh/bin"
  printf '%s\n' "$1" > "$rh/.fm-secondmate-home"
  printf '# remote secondmate home fixture\n' > "$rh/AGENTS.md"
  cat > "$rh/state/parent-route/$1.meta" <<META
window=fm-remote:p1
worktree=-
project=-
backend=herdr
endpoint_task_id=$1
harness=claude
herdr_session=fm-remote
herdr_workspace_id=w1
herdr_tab_id=t1
herdr_pane_id=p1
META
  printf '%s\n' "$rh"
}

# A parent home whose secondmate is a persistent REMOTE route (as
# spawn_remote_secondmate() writes it: no spawn_gen, remote_host instead).
make_remote_parent_home() {  # <name> <mate-id> <remote-home> <host> -> echoes home dir
  local home="$TMP_ROOT/$1" id=$2 rhome host=$4
  mkdir -p "$home/data" "$home/state"
  # Canonicalize: fm-on.sh's registry route parser rejects an empty path
  # component, and $TMP_ROOT can carry one (a raw mktemp base under a
  # trailing-slash TMPDIR), same as make_main_home's $abs above.
  rhome=$(cd "$3" && pwd -P)
  cat > "$home/state/$id.meta" <<META
window=remote:$id
endpoint_task_id=$id
harness=claude
kind=secondmate
mode=secondmate
yolo=off
remote_host=$host
remote_root=/remote/root
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:p1
META
  cat > "$home/data/secondmates.md" <<EOF
- $id - remote fixture domain (host: $host; root: /remote/root; home: $rhome; scope: remote fixture; projects: sample; added 2026-08-26)
EOF
  printf '%s\n' "$home"
}

remote_inbox_records() {  # <remote-home> <mate-id>
  find "$1/state/parent-route/$2.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null
}

run_remote_notify() {  # <home> <fakebin> <snapshot>
  local home=$1 fakebin=$2 snap=$3
  FM_SSH_BIN="$fakebin/fake-ssh" FM_REMOTE_CODE_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    "$RECONCILE" notify --snapshot "$snap"
}

# Age the home's cooldown record so the next run sees the window as elapsed.
age_cooldown() {  # <state-dir> <mate-id> <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $3 ))" > "$1/$2.reconcile-nudged"
}

run_notify() {  # <home> <fakebin> <name> <snapshot> [extra args...]
  local home=$1 fakebin=$2 name=$3 snap=$4
  shift 4
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-mate" \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/$name-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/$name-fake/pane.txt" \
    "$RECONCILE" notify --snapshot "$snap" "$@"
}

inbox_records() {  # <state-dir> <task-id>
  find "$1/$2.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]'
}

# Content-and-name fingerprint of a whole home, so any parent-side write shows up.
fingerprint_tree() {  # <dir>
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
    | while IFS= read -r -d '' f; do printf '%s %s\n' "${f#"$1"}" "$(cksum < "$f")"; done
}

inbox_text() {  # <state-dir> <task-id>
  local rec
  for rec in "$1/$2.inbox"/*.msg; do
    [ -f "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
  done
}

hold_lock_until_released() {  # <lock> <ready> <release>
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    while [ ! -f "$4" ]; do sleep 0.01; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2" "$3" &
}


test_an_inventory_mismatch_asks_the_mate_once_per_window() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home once mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["stale-scout","watch-row"]}'

  out=$(run_notify "$home" "$fakebin" once "$snap") || fail "the first reconcile ask failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "the first ask did not report what it sent: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the ask did not land as exactly one durable steering record"
  assert_contains "$(inbox_text "$home/state" mate)" "check your current books" \
    "the instruction did not ask the mate to inspect its current state"
  if printf '%s' "$(inbox_text "$home/state" mate)" | grep -Fq 'stale-scout'; then
    fail "the instruction prescribed a repair from sampled details that can become stale"
  fi

  # Every later recap sees the same mismatch; none of them may nag.
  out=$(run_notify "$home" "$fakebin" once "$snap") || fail "the repeat run failed: $out"
  assert_contains "$out" "cooldown: mate" "a repeated snapshot did not report the cooldown: $out"
  run_notify "$home" "$fakebin" once "$snap" >/dev/null
  run_notify "$home" "$fakebin" once "$snap" >/dev/null
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "repeated snapshots asked the mate more than once inside the cooldown"
  pass "a home in mismatch is asked once, and later recaps stay silent"
}

test_a_mismatch_still_there_after_the_window_earns_one_more_nudge() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home window mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" window "$snap" >/dev/null || fail "the first ask failed"

  # Just inside four hours: still silent.
  age_cooldown "$home/state" mate 14000
  out=$(run_notify "$home" "$fakebin" window "$snap") || fail "the in-window run failed: $out"
  assert_contains "$out" "cooldown: mate" "an ask inside the window was not suppressed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "an in-window ask was sent anyway"

  # Past four hours: exactly one gentle re-nudge, then silent again.
  age_cooldown "$home/state" mate 14500
  out=$(run_notify "$home" "$fakebin" window "$snap") || fail "the past-window run failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "a mismatch outliving the window did not earn a re-nudge: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "the re-nudge did not send exactly one more instruction"
  run_notify "$home" "$fakebin" window "$snap" >/dev/null
  [ "$(inbox_records "$home/state" mate)" -eq 2 ] \
    || fail "the re-nudge did not restart the cooldown"
  pass "a mismatch outliving the cooldown earns one re-nudge, then goes quiet again"
}

test_the_cooldown_starts_when_delivery_finishes() {
  local home mate fakebin snap started nudged
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home deliverytime mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  mv "$fakebin/tmux" "$fakebin/tmux-real"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send-keys ]; then sleep 2; fi
exec "$(dirname "$0")/tmux-real" "$@"
SH
  chmod +x "$fakebin/tmux"

  started=$(date +%s)
  run_notify "$home" "$fakebin" deliverytime "$snap" >/dev/null \
    || fail "the delayed reconcile ask failed"
  nudged=$(cat "$home/state/mate.reconcile-nudged")
  [ "$nudged" -ge "$((started + 2))" ] \
    || fail "the cooldown began before delivery finished: start=$started nudged=$nudged"
  pass "the cooldown begins when delivery finishes"
}

test_the_window_is_four_hours() {
  local home mate fakebin snap out now
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home fourhours mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"terminal_in_flight","ids":["done-row"]}'
  run_notify "$home" "$fakebin" fourhours "$snap" >/dev/null || fail "the first ask failed"
  now=$(date +%s)
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_DATE_NOW:-}" ] && [ "${1:-}" = +%s ]; then
  printf '%s\n' "$FM_TEST_DATE_NOW"
  exit 0
fi
exec /bin/date "$@"
SH
  chmod +x "$fakebin/date"
  # One second short of four hours is still inside; one second past is not.
  printf '%s\n' "$((now - 14399))" > "$home/state/mate.reconcile-nudged"
  out=$(FM_TEST_DATE_NOW=$now run_notify "$home" "$fakebin" fourhours "$snap")
  assert_contains "$out" "cooldown: mate" "the window was shorter than four hours: $out"
  printf '%s\n' "$((now - 14401))" > "$home/state/mate.reconcile-nudged"
  out=$(FM_TEST_DATE_NOW=$now run_notify "$home" "$fakebin" fourhours "$snap")
  assert_contains "$out" "sent: mate" "the window was longer than four hours: $out"
  pass "the cooldown window is four hours"
}

test_each_home_carries_its_own_cooldown() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home perhome mate)
  # A second registered mate in the same home, so one nudge cannot silence the other.
  cp "$home/state/mate.meta" "$home/state/other.meta"
  sed -i.bak 's/fm-mate/fm-other/' "$home/state/other.meta" && rm -f "$home/state/other.meta.bak"
  snap="$home/snapshot.json"
  jq -n '{schema:"fm-fleet-snapshot.v1", generated:"2026-08-26T00:00:00Z",
    secondmate_current:{records:[
      {id:"mate", home:"/tmp/mate", spawn_gen:"spawn-mate", current:{state:"captain_decision",reason:null},
       invalidity:{kind:"orphan_in_flight",ids:["a"]},
       reconcile_inventory:{kind:"orphan_in_flight",ids:["a"]},
       provenance:{selected:"structured-home",trust:"partial-structured"}},
      {id:"other", home:"/tmp/other", spawn_gen:"spawn-mate", current:{state:"captain_decision",reason:null},
       invalidity:{kind:"unowned_current",ids:["b"]},
       reconcile_inventory:{kind:"unowned_current",ids:["b"]},
       provenance:{selected:"structured-home",trust:"partial-structured"}}]}}' > "$snap"
  out=$(run_notify "$home" "$fakebin" perhome "$snap") || fail "the first run failed: $out"
  assert_contains "$out" "sent: mate" "the first home was not asked: $out"
  assert_contains "$out" "sent: other" "the second home was not asked: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "the first home got the wrong count"
  [ "$(inbox_records "$home/state" other)" -eq 1 ] || fail "the second home got the wrong count"
  # Only one home's window elapses; the other must stay quiet.
  age_cooldown "$home/state" mate 14500
  out=$(run_notify "$home" "$fakebin" perhome "$snap")
  assert_contains "$out" "sent: mate" "an elapsed window did not re-nudge its own home: $out"
  assert_contains "$out" "cooldown: other" "one home's nudge reset another home's window: $out"
  pass "the cooldown is per home, not fleet-wide"
}

test_the_ask_never_arms_a_reply_expectation_or_a_re_ring() {
  local home mate fakebin snap ladder
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home fireforget mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" fireforget "$snap" >/dev/null || fail "the ask failed"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] || fail "the ask was not durably recorded"

  # The parent expects no answer, so nothing may chase one.
  [ "$(find "$home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d '[:space:]')" -eq 0 ] \
    || fail "the reconcile ask armed a pending-reply expectation"

  # The record stays unhandled. With the ladder's grace elapsed, an ordinary
  # steer in that position is due for a re-ring; this one must stay invisible.
  ladder=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" "$3"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state" mate 2>&1 || true)
  [ "$ladder" = quiet ] \
    || fail "the unacknowledged reconcile record entered the re-ring ladder: $ladder"

  # Divergence check, so the assertion above cannot pass for the wrong reason:
  # the same inbox, same grace, with an ordinary unhandled steer added.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-mate" \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/fireforget-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fireforget-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" mate "an ordinary steer that does expect handling" >/dev/null 2>&1 \
    || fail "the control steer could not be recorded"
  ladder=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" "$3"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state" mate 2>&1 || true)
  case "$ladder" in
    ring\ *) ;;
    *) fail "the ladder ignored an ordinary steer too, so the quiet verdict proved nothing: $ladder" ;;
  esac
  pass "the reconcile ask expects no reply and stays out of a ladder that still rings ordinary steers"
}

test_a_readable_home_without_a_mismatch_is_never_asked() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home quiet mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"child_current_unavailable","ids":["x"]}' unknown
  out=$(run_notify "$home" "$fakebin" quiet "$snap") || fail "notify failed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] \
    || fail "an unavailable child state was mistaken for a books problem"
  write_snapshot "$snap" mate '{"kind":null,"ids":[]}' no_active_work
  out=$(run_notify "$home" "$fakebin" quiet "$snap") || fail "notify failed: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] || fail "a healthy home was asked to reconcile"
  pass "only a backlog-vs-metadata mismatch produces an ask"
}

test_the_parent_never_changes_the_mates_own_files() {
  local home mate fakebin snap before after
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home readonly mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  before=$(fingerprint_tree "$mate")
  [ -n "$before" ] || fail "the mate fixture has no files to compare"
  run_notify "$home" "$fakebin" readonly "$snap" >/dev/null || fail "the ask failed"
  after=$(fingerprint_tree "$mate")
  [ "$before" = "$after" ] \
    || fail "asking for a reconcile changed the mate's own files: $before / $after"
  pass "the parent asks and changes nothing inside the mate's home"
}

test_a_failed_send_is_retried_on_the_next_run() {
  local home mate fakebin snap out rc
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home retry mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" absent-mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  set +e
  out=$(run_notify "$home" "$fakebin" retry "$snap"); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unroutable ask reported success: $out"
  assert_contains "$out" "failed: absent-mate" "the failure was not reported: $out"
  assert_absent "$home/state/absent-mate.reconcile-nudged" \
    "a failed ask started a cooldown and would never be retried"
  pass "a failed ask starts no cooldown, so the next run retries it"
}

test_busy_lifecycle_locks_never_hold_up_the_digest() {
  local label home mate fakebin snap lock ready release holder notify out i
  for label in reconcile control meta; do
    { read -r home; read -r mate; read -r fakebin; } < <(make_main_home "busy-$label" mate)
    snap="$home/snapshot.json"
    write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
    case "$label" in
      reconcile) lock="$home/state/.mate.reconcile.lock" ;;
      control) lock="$home/state/.control-mate.lock" ;;
      meta) lock="$home/state/.meta-mate.lock" ;;
    esac
    ready="$home/lock-ready"
    release="$home/lock-release"
    hold_lock_until_released "$lock" "$ready" "$release"
    holder=$!
    while [ ! -f "$ready" ]; do sleep 0.01; done
    run_notify "$home" "$fakebin" "busy-$label" "$snap" > "$home/notify.out" 2>&1 &
    notify=$!
    i=0
    while kill -0 "$notify" 2>/dev/null && [ "$i" -lt 40 ]; do
      i=$((i + 1))
      sleep 0.05
    done
    if kill -0 "$notify" 2>/dev/null; then
      : > "$release"
      wait "$notify" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      fail "a busy $label lock blocked the reconcile path"
    fi
    wait "$notify" || fail "a busy $label lock made notify fail"
    : > "$release"
    wait "$holder" || fail "the $label lock holder failed"
    out=$(cat "$home/notify.out")
    assert_contains "$out" "skipped: mate lock" \
      "a busy $label lock was not reported as a skipped nudge: $out"
    assert_absent "$home/state/mate.reconcile-nudged" \
      "a skipped $label-lock nudge started the cooldown"
  done
  pass "busy reconcile lifecycle locks never block the digest or start cooldown"
}

test_concurrent_recaps_send_one_instruction() {
  local home mate fakebin snap
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home concurrent mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  run_notify "$home" "$fakebin" concurrent "$snap" >/dev/null 2>&1 &
  run_notify "$home" "$fakebin" concurrent "$snap" >/dev/null 2>&1 &
  wait
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "two simultaneous recaps asked the mate twice"
  pass "simultaneous recaps still ask the mate only once"
}

test_a_delayed_snapshot_never_prescribes_a_stale_repair() {
  local home mate fakebin old_snap new_snap out text
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home delayed mate)
  old_snap="$home/old-snapshot.json"
  new_snap="$home/new-snapshot.json"
  write_snapshot "$old_snap" mate '{"kind":"orphan_in_flight","ids":["already-repaired"]}'
  write_snapshot "$new_snap" mate '{"kind":"unowned_current","ids":["current-row"]}'

  out=$(run_notify "$home" "$fakebin" delayed "$old_snap") \
    || fail "the delayed reconcile ask failed: $out"
  assert_contains "$out" "sent: mate orphan_in_flight" \
    "the delayed snapshot did not produce the cooldown-limited check: $out"
  out=$(run_notify "$home" "$fakebin" delayed "$new_snap") \
    || fail "the current snapshot reconcile failed: $out"
  assert_contains "$out" "cooldown: mate" \
    "the per-home cooldown did not deduplicate the newer observation: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 1 ] \
    || fail "the old and new snapshots produced more than one ask inside the cooldown"
  text=$(inbox_text "$home/state" mate)
  assert_contains "$text" "check your current books" \
    "the delayed ask did not direct the mate to current state"
  if printf '%s' "$text" | grep -Eq 'already-repaired|current-row'; then
    fail "the delayed ask embedded sampled row details and could prescribe a stale repair: $text"
  fi
  pass "a delayed snapshot asks for a current check instead of prescribing a stale repair"
}

test_a_stale_snapshot_never_targets_a_replacement_mate() {
  local home mate fakebin snap out
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home stale mate)
  snap="$home/snapshot.json"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["old-ghost"]}'
  awk '{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-replacement"); print }' \
    "$home/state/mate.meta" > "$home/state/mate.meta.tmp"
  mv "$home/state/mate.meta.tmp" "$home/state/mate.meta"

  out=$(run_notify "$home" "$fakebin" stale "$snap") \
    || fail "a stale snapshot made reconcile fail: $out"
  assert_contains "$out" "stale: mate orphan_in_flight" \
    "the stale snapshot was not identified: $out"
  [ "$(inbox_records "$home/state" mate)" -eq 0 ] \
    || fail "a replacement mate received its predecessor's reconcile ask"
  assert_absent "$home/state/mate.reconcile-nudged" \
    "a replacement mate inherited cooldown from a stale snapshot"
  pass "a stale snapshot cannot ask or silence a replacement mate"
}

test_teardown_cannot_leave_its_replacement_in_cooldown() {
  local home mate fakebin snap signal release lifecycle_done cooldown notify_pid lifecycle_pid
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home lifecycle mate)
  snap="$home/snapshot.json"
  signal="$home/send-ringing"
  release="$home/release-ring"
  lifecycle_done="$home/lifecycle-done"
  cooldown="$home/state/mate.reconcile-nudged"
  write_snapshot "$snap" mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  mv "$fakebin/tmux" "$fakebin/tmux-real"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send-keys ]; then
  : > "$FM_FAKE_TMUX_SEND_SIGNAL"
  while [ ! -f "$FM_FAKE_TMUX_SEND_RELEASE" ]; do sleep 0.01; done
fi
exec "$(dirname "$0")/tmux-real" "$@"
SH
  chmod +x "$fakebin/tmux"

  FM_FAKE_TMUX_SEND_SIGNAL="$signal" FM_FAKE_TMUX_SEND_RELEASE="$release" \
    run_notify "$home" "$fakebin" lifecycle "$snap" >/dev/null 2>&1 &
  notify_pid=$!
  while [ ! -f "$signal" ]; do sleep 0.01; done

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$home/state/.control-mate.lock"
    fm_lock_acquire_wait "$home/state/.meta-mate.lock"
    rm -rf "$home/state/mate.inbox"
    rm -f "$home/state/mate.meta" "$home/state/mate.reconcile-nudged"
    cat > "$home/state/mate.meta" <<META
window=firstmate:fm-mate
kind=secondmate
harness=claude
backend=tmux
spawn_gen=spawn-replacement
home=$mate
worktree=$mate
META
    fm_lock_release "$home/state/.meta-mate.lock"
    fm_lock_release "$home/state/.control-mate.lock"
    : > "$lifecycle_done"
  ) &
  lifecycle_pid=$!

  sleep 0.1
  : > "$release"
  wait "$notify_pid" 2>/dev/null || true
  wait "$lifecycle_pid" || fail "the simulated teardown and reseed failed"
  [ -f "$lifecycle_done" ] || fail "the simulated lifecycle transition did not finish"
  assert_absent "$cooldown" \
    "a retired mate's cooldown was recreated after its replacement was seeded"
  pass "teardown retires the cooldown before a replacement can inherit it"
}

# A persistent REMOTE secondmate's parent metadata never carries spawn_gen
# (bin/fm-spawn.sh's spawn_remote_secondmate() never writes one). This is the
# proven marker-bearing path's counterpart: same durable fire-and-forget
# delivery and cooldown behavior, driven end to end through the real remote
# transport, for a mate that legitimately has no generation marker at all.
test_a_markerless_remote_secondmate_is_nudged_once_per_window() {
  local home rhome fakebin snap out
  fakebin=$(make_remote_ssh_stub "$TMP_ROOT/remote-once")
  rhome=$(make_remote_secondmate_home remote-once-mate)
  home=$(make_remote_parent_home remote-once remote-once-mate "$rhome" remote-once-host)
  snap="$home/snapshot.json"
  write_remote_snapshot "$snap" remote-once-mate remote-once-host \
    '{"kind":"orphan_in_flight","ids":["stale-scout"]}'

  out=$(run_remote_notify "$home" "$fakebin" "$snap") \
    || fail "the first markerless reconcile ask failed: $out"
  assert_contains "$out" "sent: remote-once-mate orphan_in_flight" \
    "a legitimately markerless remote mate got no ask: $out"
  [ -n "$(remote_inbox_records "$rhome" remote-once-mate)" ] \
    || fail "the ask did not land as a durable record in the remote steering inbox"
  [ -f "$home/state/remote-once-mate.reconcile-nudged" ] \
    || fail "a successful markerless ask did not start the cooldown"

  out=$(run_remote_notify "$home" "$fakebin" "$snap") \
    || fail "the repeat markerless run failed: $out"
  assert_contains "$out" "cooldown: remote-once-mate" \
    "a repeated markerless snapshot did not report the cooldown: $out"
  [ "$(remote_inbox_records "$rhome" remote-once-mate | grep -c . || true)" -eq 1 ] \
    || fail "repeated markerless snapshots asked the mate more than once inside the cooldown"
  pass "a legitimately markerless persistent remote secondmate is nudged once per window"
}

# The safety boundary the spawn_gen check protects for local mates has a
# host-keyed counterpart for markerless remote mates: a snapshot sampled
# before the route moved to a different host must never reach the new host's
# mate or arm its cooldown.
test_a_stale_remote_route_is_refused() {
  local home rhome fakebin snap out
  fakebin=$(make_remote_ssh_stub "$TMP_ROOT/remote-stale")
  rhome=$(make_remote_secondmate_home remote-stale-mate)
  home=$(make_remote_parent_home remote-stale remote-stale-mate "$rhome" old-host)
  snap="$home/snapshot.json"
  write_remote_snapshot "$snap" remote-stale-mate old-host \
    '{"kind":"orphan_in_flight","ids":["old-ghost"]}'
  # The route was re-seeded to a different host since the snapshot was taken.
  sed -i.bak 's/^remote_host=.*/remote_host=new-host/' "$home/state/remote-stale-mate.meta" \
    && rm -f "$home/state/remote-stale-mate.meta.bak"

  out=$(run_remote_notify "$home" "$fakebin" "$snap") \
    || fail "a stale remote-route snapshot made reconcile fail: $out"
  assert_contains "$out" "stale: remote-stale-mate orphan_in_flight" \
    "a snapshot sampled from a retired remote route was not identified: $out"
  [ -z "$(remote_inbox_records "$rhome" remote-stale-mate)" ] \
    || fail "a replacement remote route received its predecessor's reconcile ask"
  assert_absent "$home/state/remote-stale-mate.reconcile-nudged" \
    "a replacement remote route inherited cooldown from a stale snapshot"
  pass "a stale remote-route snapshot cannot ask or silence a replacement mate"
}

test_route_replacement_during_send_is_refused() {
  local home rhome fakebin snap signal release out rc notify_pid
  fakebin=$(make_remote_ssh_stub "$TMP_ROOT/remote-send-race")
  rhome=$(make_remote_secondmate_home remote-send-race-mate)
  home=$(make_remote_parent_home remote-send-race remote-send-race-mate "$rhome" old-host)
  snap="$home/snapshot.json"
  signal="$home/fm-send-started"
  release="$home/release-fm-send"
  write_remote_snapshot "$snap" remote-send-race-mate old-host \
    '{"kind":"orphan_in_flight","ids":["old-ghost"]}'
  cat > "$fakebin/dirname" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  */fm-send.sh)
    : > "$FM_RECONCILE_RACE_SIGNAL"
    while [ ! -f "$FM_RECONCILE_RACE_RELEASE" ]; do sleep 0.01; done
    ;;
esac
case "${1:-}" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
SH
  chmod +x "$fakebin/dirname"

  rc=0
  FM_RECONCILE_RACE_SIGNAL="$signal" FM_RECONCILE_RACE_RELEASE="$release" \
    run_remote_notify "$home" "$fakebin" "$snap" > "$home/notify.out" 2>&1 &
  notify_pid=$!
  while [ ! -f "$signal" ]; do
    kill -0 "$notify_pid" 2>/dev/null || fail "reconcile exited before entering fm-send"
    sleep 0.01
  done

  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$home/state/.control-remote-send-race-mate.lock"
  fm_lock_acquire_wait "$home/state/.meta-remote-send-race-mate.lock"
  sed 's/^remote_host=.*/remote_host=new-host/' \
    "$home/state/remote-send-race-mate.meta" > "$home/state/remote-send-race-mate.meta.tmp"
  mv "$home/state/remote-send-race-mate.meta.tmp" "$home/state/remote-send-race-mate.meta"
  sed 's/host: old-host/host: new-host/' \
    "$home/data/secondmates.md" > "$home/data/secondmates.md.tmp"
  mv "$home/data/secondmates.md.tmp" "$home/data/secondmates.md"
  fm_lock_release "$home/state/.meta-remote-send-race-mate.lock"
  fm_lock_release "$home/state/.control-remote-send-race-mate.lock"
  : > "$release"
  wait "$notify_pid" || rc=$?
  out=$(cat "$home/notify.out")

  [ "$rc" -ne 0 ] || fail "a route replacement during send reported success: $out"
  assert_contains "$out" "failed: remote-send-race-mate orphan_in_flight" \
    "a route replacement during send was not refused: $out"
  [ -z "$(remote_inbox_records "$rhome" remote-send-race-mate)" ] \
    || fail "a replacement route received its predecessor's reconcile ask"
  assert_absent "$home/state/remote-send-race-mate.reconcile-nudged" \
    "a refused route replacement started the cooldown"
  pass "a route replacement between reconcile and fm-send cannot receive a stale ask"
}

# A row with neither a spawn generation nor a host carries no safe identity at
# all - the markerless path must not swallow that case the way the original
# bug swallowed every markerless row.
test_a_row_with_no_identity_at_all_fails_loudly() {
  local home rhome fakebin snap out
  fakebin=$(make_remote_ssh_stub "$TMP_ROOT/remote-noid")
  rhome=$(make_remote_secondmate_home remote-noid-mate)
  home=$(make_remote_parent_home remote-noid remote-noid-mate "$rhome" remote-noid-host)
  snap="$home/snapshot.json"
  write_remote_snapshot "$snap" remote-noid-mate "" \
    '{"kind":"orphan_in_flight","ids":["ghost"]}'

  set +e
  out=$(run_remote_notify "$home" "$fakebin" "$snap"); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a row with no sampled identity at all reported success: $out"
  assert_contains "$out" "failed: remote-noid-mate orphan_in_flight" \
    "an unidentifiable row was not reported as failed: $out"
  [ -z "$(remote_inbox_records "$rhome" remote-noid-mate)" ] \
    || fail "an unidentifiable row still received a reconcile ask"
  assert_absent "$home/state/remote-noid-mate.reconcile-nudged" \
    "an unidentifiable row started a cooldown"
  pass "a row with neither a spawn generation nor a host fails loudly instead of vanishing"
}

test_reconcile_request_rejects_an_unbounded_input_without_filling_storage() {
  local home started elapsed files
  { read -r home; read -r _; read -r _; } < <(make_main_home bounded-request bounded-request-mate)
  started=$(date +%s)
  if yes x | FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_RECONCILE_REQUEST_MAX_BYTES=64 "$RECONCILE" request --snapshot - \
      > "$home/request.out" 2> "$home/request.err"; then
    fail "an oversized streaming request was accepted"
  fi
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 3 ] || fail "an oversized streaming request did not stop at its byte bound"
  files=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
  [ "$files" -eq 0 ] || fail "an oversized streaming request left captured data behind"
  pass "reconcile requests stop oversized streams at the capture bound"
}

test_reconcile_request_requires_one_snapshot_document() {
  local home snap quiet stream files
  { read -r home; read -r _; read -r _; } < <(make_main_home single-request-document single-document-mate)
  snap="$home/mismatch.json"
  quiet="$home/quiet.json"
  stream="$home/stream.json"
  write_snapshot "$snap" single-document-mate '{"kind":"orphan_in_flight","ids":["ghost"]}'
  write_snapshot "$quiet" single-document-mate '{"kind":null,"ids":[]}'
  cat "$snap" "$quiet" > "$stream"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      "$RECONCILE" request --snapshot "$stream" > "$home/request.out" 2> "$home/request.err"; then
    fail "a multi-document reconcile request was accepted"
  fi
  files=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$files" -eq 0 ] || fail "a multi-document request published partial durable work"
  pass "reconcile requests require exactly one snapshot document"
}

test_reconcile_requests_coalesce_per_target_until_delivery() {
  local home mate fakebin second_mate second_abs snap bearings requests remaining out i ready_a ready_b ready_b2 release_a release_b release_b2 holder_a holder_b holder_b2
  { read -r home; read -r mate; read -r fakebin; } < <(make_main_home coalesced-requests coalesce-a)
  second_mate="$TMP_ROOT/coalesced-requests-mate-b"
  seed_secondmate_home_marker "$second_mate" coalesce-b
  second_abs=$(cd "$second_mate" && pwd -P)
  printf -- '- coalesce-b - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-08-26)\n' \
    "$second_abs" >> "$home/data/secondmates.md"
  cat > "$home/state/coalesce-b.meta" <<META
window=firstmate:fm-coalesce-b
kind=secondmate
harness=claude
backend=tmux
spawn_gen=spawn-coalesce-b
home=$second_abs
worktree=$second_abs
META
  snap="$home/coalesced-snapshot.json"
  write_snapshot "$snap" coalesce-a '{"kind":"orphan_in_flight","ids":["a-1"]}'
  jq '.secondmate_current.records += [(.secondmate_current.records[0]
    | .id = "coalesce-b"
    | .home = "/tmp/coalesce-b"
    | .spawn_gen = "spawn-coalesce-b"
    | .reconcile_inventory.ids = ["b-1"]
    | .invalidity.ids = ["b-1"])]' "$snap" > "$snap.next"
  mv "$snap.next" "$snap"

  i=0
  while [ "$i" -lt 4 ]; do
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      "$RECONCILE" request --snapshot "$snap" >/dev/null \
      || fail "a repeated reconcile request could not be published"
    i=$((i + 1))
  done
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 2 ] || fail "repeated requests did not coalesce to one pending file per target"
  bearings="$home/coalesced-bearings.json"
  jq '{schema:"fm-bearings.v1",secondmate_reconcile:[.secondmate_current.records[] | {
    id,spawn_gen,host:(.host // null),kind:.reconcile_inventory.kind,ids:.reconcile_inventory.ids}]}' \
    "$snap" > "$bearings"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$RECONCILE" request --snapshot "$bearings" >/dev/null \
    || fail "the equivalent Bearings request could not be published"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 2 ] || fail "equivalent fleet and Bearings requests used different target keys"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$RECONCILE" request --snapshot "$snap" >/dev/null \
    || fail "the fleet request could not replace its Bearings representation"
  jq '(.secondmate_current.records[] | select(.id == "coalesce-a") | .spawn_gen) = "spawn-coalesce-a-v2"' \
    "$snap" > "$snap.next"
  mv "$snap.next" "$snap"
  awk '{ if ($0 ~ /^spawn_gen=/) print "spawn_gen=spawn-coalesce-a-v2"; else print }' \
    "$home/state/coalesce-a.meta" > "$home/state/coalesce-a.meta.next"
  mv "$home/state/coalesce-a.meta.next" "$home/state/coalesce-a.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$RECONCILE" request --snapshot "$snap" >/dev/null \
    || fail "the relaunched target request could not replace its predecessor"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 2 ] || fail "a target relaunch created an additional pending request"
  jq -s -e '[.[].secondmate_current.records[] | select(.id == "coalesce-a")]
    | length == 1 and .[0].spawn_gen == "spawn-coalesce-a-v2"' \
    "$home/state/reconcile-notify"/request-*.json >/dev/null \
    || fail "the relaunched target did not replace its pending identity payload"

  out="$home/process.out"
  ready_a="$home/lock-a-ready"
  ready_b="$home/lock-b-ready"
  release_a="$home/lock-a-release"
  release_b="$home/lock-b-release"
  hold_lock_until_released "$home/state/.coalesce-a.reconcile.lock" "$ready_a" "$release_a" &
  holder_a=$!
  hold_lock_until_released "$home/state/.coalesce-b.reconcile.lock" "$ready_b" "$release_b" &
  holder_b=$!
  while [ ! -f "$ready_a" ] || [ ! -f "$ready_b" ]; do sleep 0.01; done
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_FAKE_TMUX_WINDOW='' FM_FAKE_TMUX_LOG="$home/tmux.log" \
      FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/coalesced-requests-fake/pane.txt" \
      "$RECONCILE" process-requests > "$out"; then
    : > "$release_a"
    : > "$release_b"
    wait "$holder_a" 2>/dev/null || true
    wait "$holder_b" 2>/dev/null || true
    fail "failed reconcile deliveries unexpectedly retired their requests"
  fi
  : > "$release_a"
  : > "$release_b"
  wait "$holder_a" 2>/dev/null || true
  wait "$holder_b" 2>/dev/null || true
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 2 ] || fail "failed delivery did not preserve one request per target"

  ready_b2="$home/lock-b2-ready"
  release_b2="$home/lock-b2-release"
  hold_lock_until_released "$home/state/.coalesce-b.reconcile.lock" "$ready_b2" "$release_b2" &
  holder_b2=$!
  while [ ! -f "$ready_b2" ]; do sleep 0.01; done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-coalesce-a' FM_FAKE_TMUX_LOG="$home/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/coalesced-requests-fake/pane.txt" \
    "$RECONCILE" process-requests > "$out" 2>&1 || true
  : > "$release_b2"
  wait "$holder_b2" 2>/dev/null || true
  [ -s "$home/state/coalesce-a.reconcile-nudged" ] \
    || fail "successful delivery did not commit the first target cooldown"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 1 ] || fail "successful delivery did not retire only its target request"
  remaining=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' -print -quit)
  jq -e '.secondmate_current.records | length == 1 and .[0].id == "coalesce-b"' "$remaining" >/dev/null \
    || fail "delivery of one target did not preserve the other target independently"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-coalesce-b' FM_FAKE_TMUX_LOG="$home/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/coalesced-requests-fake/pane.txt" \
    "$RECONCILE" process-requests > "$out" 2>&1 \
    || fail "the remaining target request could not be delivered"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 0 ] || fail "successful delivery did not clear the remaining coalesced request"
  pass "reconcile requests coalesce per target and retire independently after delivery"
}

test_bearings_request_returns_before_remote_delivery_and_supervision_sends_later() {
  local home rhome fakebin snap warm started elapsed watcher i requests beat_before beat_after processing beacon_advanced=0
  fakebin=$(make_remote_ssh_stub "$TMP_ROOT/remote-offpath")
  rhome=$(make_remote_secondmate_home remote-offpath-mate)
  rhome=$(cd "$rhome" && pwd -P)
  home=$(make_remote_parent_home remote-offpath remote-offpath-mate "$rhome" remote-offpath-host)
  jq -n --arg home "$rhome" '{
    schema:"fm-secondmate-home-summary.v1",generated:"2026-09-01T22:00:00Z",generated_epoch:1900,home:$home,
    valid:false,reason:"in-flight backlog item has no child metadata: stale-row",
    invalidity:{kind:"orphan_in_flight",ids:["stale-row"]},state:"no_active_work",
    active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]
  }' > "$rhome/state/home-summary.json"

  warm=$(FM_SSH_BIN="$fakebin/fake-ssh" FM_REMOTE_CODE_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_SNAPSHOT_BUDGET=3 FM_SNAPSHOT_NOW_EPOCH=2000 \
    FM_BEARINGS_NOW=2026-09-01T22:00:00Z "$ROOT/bin/fm-bearings-snapshot.sh" --json) \
    || fail "the initial remote ledger could not seed the parent cache"
  printf '%s' "$warm" | jq -e '.secondmate_reconcile | any(.id == "remote-offpath-mate" and .kind == "orphan_in_flight")' >/dev/null \
    || fail "the warm remote ledger did not carry its inventory mismatch"
  touch "$home/state/home-summary.json"

  started=$(date +%s)
  snap=$(FM_TEST_RECONCILE_REMOTE_DELAY=30 \
    FM_SSH_BIN="$fakebin/fake-ssh" FM_REMOTE_CODE_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_SNAPSHOT_BUDGET=1 FM_SNAPSHOT_NOW_EPOCH=2000 \
    FM_BEARINGS_NOW=2026-09-01T22:00:00Z "$ROOT/bin/fm-bearings-snapshot.sh" --json) \
    || fail "Bearings failed while the remote queue was delayed"
  printf '%s\n' "$snap" | FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$RECONCILE" request --snapshot - > "$home/request.out" \
    || fail "the reconcile notify request could not be recorded"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 5 ] \
    || fail "Bearings and request publication waited past the collector budget behind remote delivery (${elapsed}s)"
  printf '%s' "$snap" | jq -e '.secondmates | any(.id == "remote-offpath-mate" and .freshness == "cached" and .age_seconds == 100)' >/dev/null \
    || fail "the delayed queue did not leave an age-labeled cached mismatch row"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name 'request-*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 1 ] || fail "the mismatched-home snapshot did not leave one durable notify request"
  [ -z "$(remote_inbox_records "$rhome" remote-offpath-mate)" ] \
    || fail "the captain-facing request path sent to the mate inline"
  for lock in \
    "$home/state/.remote-offpath-mate.reconcile.lock" \
    "$home/state/.control-remote-offpath-mate.lock" \
    "$home/state/.meta-remote-offpath-mate.lock"; do
    [ ! -e "$lock" ] || fail "the request path left a mate lifecycle lock held: $lock"
  done

  FM_TEST_RECONCILE_REMOTE_DELAY=4 \
    FM_SSH_BIN="$fakebin/fake-ssh" FM_REMOTE_CODE_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watcher=$!
  i=0
  processing=''
  while [ "$i" -lt 100 ]; do
    processing=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name '.processing-*.json' -print -quit)
    [ -n "$processing" ] && [ -e "$home/state/.last-watcher-beat" ] && break
    kill -0 "$watcher" 2>/dev/null || break
    i=$((i + 1))
    sleep 0.05
  done
  [ -n "$processing" ] || fail "supervision did not claim the durable reconcile request"
  beat_before=$(stat -c %Y "$home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$home/state/.last-watcher-beat")
  i=0
  while [ -e "$processing" ] && [ "$i" -lt 70 ]; do
    sleep 0.05
    beat_after=$(stat -c %Y "$home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$home/state/.last-watcher-beat")
    if [ "$beat_after" -gt "$beat_before" ]; then
      beacon_advanced=1
      break
    fi
    i=$((i + 1))
  done
  [ "$beacon_advanced" -eq 1 ] \
    || fail "the watcher beacon stalled behind delayed reconcile delivery"
  # Delivery is detached from the watcher loop.
  # Observe the durable lifecycle itself rather than using watcher liveness as a proxy.
  # A watcher may exit after it has launched the delivery child.
  i=0
  while { [ -z "$(remote_inbox_records "$rhome" remote-offpath-mate)" ] \
      || [ ! -s "$home/state/remote-offpath-mate.reconcile-nudged" ] \
      || [ "$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d '[:space:]')" -gt 0 ]; } \
      && [ "$i" -lt 600 ]; do
    i=$((i + 1))
    sleep 0.05
  done
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  [ -n "$(remote_inbox_records "$rhome" remote-offpath-mate)" ] \
    || fail "supervision did not deliver the durable reconcile request later: $(cat "$home/watch.err")"
  [ -s "$home/state/remote-offpath-mate.reconcile-nudged" ] \
    || fail "the delivered reconcile request did not commit its cooldown: $(cat "$home/watch.err")"
  requests=$(find "$home/state/reconcile-notify" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d '[:space:]')
  [ "$requests" -eq 0 ] || fail "the delivered one-shot reconcile request was not retired: $(cat "$home/watch.err")"
  for lock in \
    "$home/state/.remote-offpath-mate.reconcile.lock" \
    "$home/state/.control-remote-offpath-mate.lock" \
    "$home/state/.meta-remote-offpath-mate.lock"; do
    [ ! -e "$lock" ] || fail "later supervision delivery left a mate lifecycle lock held: $lock"
  done
  pass "Bearings records locally, returns before a delayed remote queue, and supervision delivers later"
}

test_reconcile_request_rejects_an_unbounded_input_without_filling_storage
test_reconcile_request_requires_one_snapshot_document
test_reconcile_requests_coalesce_per_target_until_delivery
test_bearings_request_returns_before_remote_delivery_and_supervision_sends_later
test_an_inventory_mismatch_asks_the_mate_once_per_window
test_a_mismatch_still_there_after_the_window_earns_one_more_nudge
test_the_cooldown_starts_when_delivery_finishes
test_the_window_is_four_hours
test_each_home_carries_its_own_cooldown
test_the_ask_never_arms_a_reply_expectation_or_a_re_ring
test_a_readable_home_without_a_mismatch_is_never_asked
test_the_parent_never_changes_the_mates_own_files
test_a_failed_send_is_retried_on_the_next_run
test_busy_lifecycle_locks_never_hold_up_the_digest
test_concurrent_recaps_send_one_instruction
test_a_delayed_snapshot_never_prescribes_a_stale_repair
test_a_stale_snapshot_never_targets_a_replacement_mate
test_teardown_cannot_leave_its_replacement_in_cooldown
test_a_markerless_remote_secondmate_is_nudged_once_per_window
test_a_stale_remote_route_is_refused
test_route_replacement_during_send_is_refused
test_a_row_with_no_identity_at_all_fails_loudly
