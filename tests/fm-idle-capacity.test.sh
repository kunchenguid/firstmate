#!/usr/bin/env bash
# Behavior tests for the idle-capacity report and the supervision predicate's
# idle branch (bin/fm-supervision-lib.sh), and for the four wiring sites that
# must surface it. An idle firstmate home with a full queue used to get no
# watcher, no wake, and no turn; these cases pin the four states that must not
# go quiet again.
#
#   state 1  present + live   the turn-end guard's blocked banner carries the line
#   state 2  present + idle    teardown of the last task prints it, and the
#                              widened predicate reports supervision needed
#   state 3  away + live       the away daemon's catch-all scan buffers it
#   state 4  away + idle       same, with no status file in the home at all
#
# Plus the two silencing/hygiene rules: state/.dispatch-freeze replaces the line
# with FREEZE, and an undated hold with no recheck event reports HOLD_STALE.
#
# Real processes throughout: the installed tasks-axi owns every backlog row, and
# `treehouse` is the one PATH shim, because a worktree pool cannot be built in a
# temp dir. Nothing here reads implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-capacity)
fm_git_identity fmtest fmtest@example.invalid

command -v tasks-axi >/dev/null 2>&1 \
  || fail "tasks-axi is required: these cases drive real backlog rows, never a stub"

# --- fixtures ---------------------------------------------------------------

# A firstmate home shaped enough for the predicate and the report: state/, data/
# with a real backlog, and a fakebin whose `treehouse status` reports a pool of
# the requested size. Echoes the home dir.
#   make_home <name> <available-slots>
make_home() {
  local name=$1 slots=$2 home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
# Pool listing in treehouse status's own column shape: name, status, path, with
# indented process lines that must never be counted as worktrees.
[ "\${1:-}" = status ] || exit 0
i=1
while [ "\$i" -le $slots ]; do
  printf '%s     available    /pool/%s\n' "\$i" "\$i"
  i=\$((i + 1))
done
printf 'busy  in-use       /pool/busy\n'
printf '      bash (1234), claude (5678)\n'
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

add_ready() {  # <home> <id>
  tasks-axi add "$2" "ready fixture $2" --kind ship \
    --file "$1/data/backlog.md" >/dev/null
}

add_hold() {  # <home> <id> <reason> [--until <date>]
  local home=$1 id=$2 reason=$3; shift 3
  tasks-axi add "$id" "held fixture $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$id" --reason "$reason" --kind captain "$@" \
    --file "$home/data/backlog.md" >/dev/null
}

# Backdate a queued row's recorded start date, the only date tasks-axi keeps for
# a held item and therefore the one the stale-hold age is measured from.
backdate_row() {  # <home> <id> <days>
  local home=$1 id=$2 days=$3 when
  when=$(date -d "-${days} days" +%Y-%m-%d 2>/dev/null) \
    || when=$(date -v"-${days}d" +%Y-%m-%d 2>/dev/null) \
    || fail "no portable way to compute a past date on this platform"
  sed -i.bak "s/^\(- \[ \] $id .*\)(since [0-9-]*)/\1(since $when)/" \
    "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.bak"
  tasks-axi show "$id" --file "$home/data/backlog.md" |
    grep -q "created: $when" || fail "backdating $id to $when did not take"
}

report() {  # <home> [root]
  local home=$1
  local root=${2:-$home}
  PATH="$home/fakebin:$PATH" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_idle_capacity_report "$2/state" "$2/data" "$3"' _ "$ROOT" "$home" "$root"
}

predicate_needed() {  # <home>
  PATH="$home/fakebin:$PATH" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$2/state" 300 "$2/data" "$3"
    printf "%s %s\n" "$FM_SUP_NEEDED" "${FM_SUP_IDLE_CAPACITY:-unset}"' \
    _ "$ROOT" "$1" "$1"
}

# --- report shape -----------------------------------------------------------

test_report_counts_and_disposition() {
  local home out
  home=$(make_home report-shape 3)
  add_ready "$home" idle-a
  add_ready "$home" idle-b
  add_hold "$home" idle-h "waiting on the captain" --until 2099-01-01
  : > "$home/state/live-1.meta"
  out=$(report "$home")
  case "$out" in
    *"IDLE CAPACITY: ready=2 held=1 free_slots=3 live=1"*) ;;
    *) fail "expected the counted IDLE CAPACITY header, got: $out" ;;
  esac
  case "$out" in *idle-a*) ;; *) fail "ready ids must be listed, got: $out" ;; esac
  case "$out" in *idle-b*) ;; *) fail "ready ids must be listed, got: $out" ;; esac
  case "$out" in
    *"dispatch, hold with a due date or recheck event, or record the exact blocking rule on the item"*) ;;
    *) fail "the required disposition line is missing, got: $out" ;;
  esac
  pass "report: counts, ready ids, and the disposition line"
}

test_report_frontier_empty() {
  local home out
  home=$(make_home frontier-empty 3)
  add_hold "$home" only-held "waiting on the captain" --until 2099-01-01
  out=$(report "$home")
  [ "$out" = "FRONTIER EMPTY, HELD=1" ] \
    || fail "no ready work with holds must print FRONTIER EMPTY only, got: $out"
  pass "report: FRONTIER EMPTY, HELD=M when ready is empty but holds exist"
}

test_report_silent_when_nothing_applies() {
  local home out
  home=$(make_home nothing-applies 3)
  out=$(report "$home")
  [ -z "$out" ] || fail "an empty backlog must print nothing, got: $out"
  pass "report: silent with neither ready work nor a hold"
}

test_report_fails_soft_on_unreadable_pool() {
  local home out
  home=$(make_home unreadable-pool 3)
  add_ready "$home" idle-a
  out=$(report "$home" "$TMP_ROOT/no-such-pool-root")
  case "$out" in
    *WARN*) ;;
    *) fail "an unreadable pool must print one WARN line, got: $out" ;;
  esac
  case "$out" in
    *"IDLE CAPACITY: ready="*) fail "free slots are unknown; the counted line must not print: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || fail "the soft-fail path must be exactly one line, got: $out"
  pass "report: an unreadable worktree pool degrades to one WARN line"
}

test_report_dedupes_pool_roots() {
  local home out
  home=$(make_home dedupe-pools 2)
  add_ready "$home" idle-a
  # Two registry entries naming the home's own root, one with a trailing slash.
  printf -- '- A [no-mistakes] - a; repository: %s (added 2026-01-01)\n' "$home" \
    > "$home/data/projects.md"
  printf -- '- B [no-mistakes] - b; repository: %s/ (added 2026-01-01)\n' "$home" \
    >> "$home/data/projects.md"
  out=$(report "$home")
  case "$out" in
    *"free_slots=2"*) ;;
    *) fail "one repository named three times must be counted once, got: $out" ;;
  esac
  pass "report: repeated references to one repository count its pool once"
}

test_report_warns_when_one_pool_of_several_is_unreadable() {
  local home out
  home=$(make_home partial-pools 2)
  add_ready "$home" idle-a
  printf -- '- Gone [no-mistakes] - gone; repository: %s/no-such-repo (added 2026-01-01)\n' \
    "$TMP_ROOT" > "$home/data/projects.md"
  out=$(report "$home")
  case "$out" in
    *WARN*) ;;
    *) fail "an unreadable pool among readable ones must warn, got: $out" ;;
  esac
  case "$out" in
    *"free_slots="*) fail "a partial pool read must not report a confident count: $out" ;;
  esac
  pass "report: one unreadable pool warns instead of under-reporting free slots"
}

# --- freeze -----------------------------------------------------------------

test_freeze_silences_line() {
  local home out
  home=$(make_home freeze-on 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch for the release' '2099-01-01' \
    > "$home/state/.dispatch-freeze"
  out=$(report "$home")
  [ "$out" = "FREEZE: captain paused dispatch for the release until 2099-01-01" ] \
    || fail "an applying freeze must replace the line, got: $out"
  pass "freeze: the record silences IDLE CAPACITY and prints FREEZE instead"
}

test_freeze_expired_unsilences() {
  local home out
  home=$(make_home freeze-expired 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch for the release' '2000-01-01' \
    > "$home/state/.dispatch-freeze"
  out=$(report "$home")
  case "$out" in
    *FREEZE*) fail "an expired freeze must not silence the line, got: $out" ;;
    *"IDLE CAPACITY: ready=1"*) ;;
    *) fail "an expired freeze must un-silence the line, got: $out" ;;
  esac
  pass "freeze: an expired until date un-silences the line"
}

test_freeze_keeps_predicate_false() {
  local home verdict
  home=$(make_home freeze-predicate 3)
  add_ready "$home" idle-a
  printf '%s\n' 'captain paused dispatch' '2099-01-01' \
    > "$home/state/.dispatch-freeze"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "a frozen home must not be forced to hold a watcher, got: $verdict"
  pass "freeze: the idle branch of the predicate stays false while frozen"
}

# --- hold hygiene -----------------------------------------------------------

test_hold_stale_reported() {
  local home out
  home=$(make_home hold-stale 3)
  add_hold "$home" undated-hold "captain has not ruled"
  backdate_row "$home" undated-hold 2
  out=$(report "$home")
  case "$out" in
    *"HOLD_STALE: undated-hold 2d"*) ;;
    *) fail "an undated, event-less hold older than a day must be named, got: $out" ;;
  esac
  pass "hold hygiene: HOLD_STALE names an undated hold with no recheck event"
}

test_hold_with_event_is_not_stale() {
  local home out
  home=$(make_home hold-event 3)
  add_hold "$home" event-hold "dispatch when the release PR lands"
  backdate_row "$home" event-hold 2
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a hold naming a recheck event must not be named, got: $out" ;;
  esac
  pass "hold hygiene: a hold naming a recheck event is left alone"
}

test_hold_with_until_is_not_stale() {
  local home out
  home=$(make_home hold-dated 3)
  add_hold "$home" dated-hold "captain has not ruled" --until 2099-01-01
  backdate_row "$home" dated-hold 2
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a dated hold must not be named, got: $out" ;;
  esac
  pass "hold hygiene: a hold carrying a due date is left alone"
}

test_fresh_hold_is_not_stale() {
  local home out
  home=$(make_home hold-fresh 3)
  add_hold "$home" fresh-hold "captain has not ruled"
  out=$(report "$home")
  case "$out" in
    *HOLD_STALE*) fail "a hold placed today must not be named yet, got: $out" ;;
  esac
  pass "hold hygiene: a hold younger than a day is not yet stale"
}

# --- state 2: present + idle (the widened predicate) ------------------------

test_predicate_true_on_idle_capacity() {
  local home verdict
  home=$(make_home predicate-idle 2)
  add_ready "$home" idle-a
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true true" ] \
    || fail "ready work with a free slot must need supervision, got: $verdict"
  pass "state 2: an idle home with ready work and a free slot needs supervision"
}

test_predicate_false_when_both_false() {
  local home verdict
  home=$(make_home predicate-both-false 0)
  add_ready "$home" idle-a
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "ready work with no free slot must not need supervision, got: $verdict"
  home=$(make_home predicate-empty-queue 3)
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "false false" ] \
    || fail "no work and no ready item must not need supervision, got: $verdict"
  pass "state 2: the predicate stays false when in-flight work and idle capacity both are"
}

test_predicate_unchanged_when_work_in_flight() {
  local home verdict
  home=$(make_home predicate-in-flight 0)
  : > "$home/state/live-1.meta"
  verdict=$(predicate_needed "$home")
  [ "$verdict" = "true false" ] \
    || fail "in-flight work must still carry the predicate on its own, got: $verdict"
  pass "state 2: in-flight work still carries the predicate without the idle branch"
}

# --- state 1: present + live (the turn-end guard) ---------------------------

install_guard_home() {  # <home>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard.sh fm-operational-input.sh fm-supervision-instructions.sh \
    fm-harness.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
    fm-hook-host-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-operational-input.sh" \
    "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

test_guard_banner_names_idle_capacity() {
  local home out rc
  home=$(make_home guard-live 3)
  install_guard_home "$home"
  add_ready "$home" idle-a
  : > "$home/state/live-1.meta"
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a home with work and no watcher must block the turn (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=3 live=1"*) ;;
    *) fail "the blocked banner must carry the idle-capacity line, got: $out" ;;
  esac
  case "$out" in
    *"●  IDLE CAPACITY"*) ;;
    *) fail "the line must be rendered in the banner's own style, got: $out" ;;
  esac
  pass "state 1: the turn-end guard's blocked banner carries the idle-capacity line"
}

test_guard_banner_names_idle_only_need() {
  local home out rc
  home=$(make_home guard-idle-only 3)
  install_guard_home "$home"
  add_ready "$home" idle-a
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "ready work with a free slot and no watcher must block the turn (rc=$rc): $out"
  case "$out" in
    *"Ready work could be dispatched into a free slot right now"*) ;;
    *) fail "the banner must name idle capacity as the reason, got: $out" ;;
  esac
  pass "state 1: idle capacity alone blocks a blind turn end and names itself"
}

test_guard_silent_without_idle_capacity() {
  local home out rc
  home=$(make_home guard-quiet 0)
  install_guard_home "$home"
  add_ready "$home" idle-a
  set +e
  out=$(printf '{"stop_hook_active":false,"session_id":"s1"}' |
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a home with no free slot must let the turn end (rc=$rc): $out"
  pass "state 1: a full pool with no in-flight work still lets the turn end"
}

# --- state 2: present + idle (teardown of the last task) --------------------

make_teardown_home() {  # <name> <available-slots>
  local home=$1 slots=$2 dir fakebin
  dir=$(make_home "$home" "$slots")
  fakebin="$dir/fakebin"
  # treehouse also serves teardown's own `return`; the pool listing above is the
  # only subcommand these cases read.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/no-mistakes"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$dir/project" worktree add -q -b fm/task-t1 "$dir/wt" main
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

test_teardown_prints_idle_capacity() {
  local home out rc
  home=$(make_teardown_home teardown-idle 4)
  add_ready "$home" idle-a
  tasks-axi add task-t1 "teardown fixture" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi start task-t1 --file "$home/data/backlog.md" >/dev/null
  fm_write_meta "$home/state/task-t1.meta" \
    "window=firstmate:fm-task-t1" \
    "endpoint_task_id=task-t1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=idle-capacity-test-task-t1"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-t1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of landed local-only work must succeed (rc=$rc): $out"
  case "$out" in
    *"IDLE CAPACITY: ready=1 held=0 free_slots=4 live=0"*) ;;
    *) fail "teardown of the last task must report the idle home, got: $out" ;;
  esac
  pass "state 2: teardown of the last task prints the idle-capacity line"
}

# --- states 3 and 4: away mode ----------------------------------------------

# Drive the daemon's real housekeeping scan in library mode, which is how the
# daemon suites exercise it, and read the escalation buffer it writes.
run_away_scan() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_ROOT_OVERRIDE="$home" \
  FM_ESCALATE_BATCH_SECS=99999 FM_HEARTBEAT_SCAN_SECS=0 \
    bash -c '
      # shellcheck disable=SC1090
      . "$1/bin/fm-supervise-daemon.sh"
      housekeeping "$2/state"' _ "$ROOT" "$home"
}

test_away_live_scan_buffers_idle_capacity() {
  local home
  home=$(make_home away-live 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_ready "$home" idle-a
  : > "$home/state/live-1.meta"
  printf 'working: still going\n' > "$home/state/live-1.status"
  : > "$home/state/.afk"
  run_away_scan "$home" >/dev/null 2>&1 || true
  grep -q "IDLE CAPACITY: ready=1 held=0 free_slots=3 live=1" \
    "$home/state/.subsuper-escalations" \
    || fail "the away scan must buffer the idle-capacity line: $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "state 3: away + live buffers the idle-capacity line as an escalation"
}

test_away_idle_scan_buffers_idle_capacity() {
  local home
  home=$(make_home away-idle 3)
  cp -R "$ROOT/bin" "$home/bin"
  add_ready "$home" idle-a
  : > "$home/state/.afk"
  [ -z "$(find "$home/state" -maxdepth 1 -name '*.status' -print -quit)" ] \
    || fail "state 4 must have no status file at all"
  run_away_scan "$home" >/dev/null 2>&1 || true
  grep -q "IDLE CAPACITY: ready=1 held=0 free_slots=3 live=0" \
    "$home/state/.subsuper-escalations" \
    || fail "an away home with no status file at all must still buffer the line: $(cat "$home/state/.subsuper-escalations" 2>/dev/null)"
  pass "state 4: away + idle still buffers the line with no status file to scan"
}

# --- run --------------------------------------------------------------------

test_report_counts_and_disposition
test_report_frontier_empty
test_report_silent_when_nothing_applies
test_report_fails_soft_on_unreadable_pool
test_report_dedupes_pool_roots
test_report_warns_when_one_pool_of_several_is_unreadable
test_freeze_silences_line
test_freeze_expired_unsilences
test_freeze_keeps_predicate_false
test_hold_stale_reported
test_hold_with_event_is_not_stale
test_hold_with_until_is_not_stale
test_fresh_hold_is_not_stale
test_predicate_true_on_idle_capacity
test_predicate_false_when_both_false
test_predicate_unchanged_when_work_in_flight
test_guard_banner_names_idle_capacity
test_guard_banner_names_idle_only_need
test_guard_silent_without_idle_capacity
test_teardown_prints_idle_capacity
test_away_live_scan_buffers_idle_capacity
test_away_idle_scan_buffers_idle_capacity
