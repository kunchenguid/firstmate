#!/usr/bin/env bash
# tests/supervision-host-helpers.sh - shared fixtures for the supervision-host
# behavior suites. These encode the stub engine, fixture home, host process
# lifecycle, and host-hand-back waits, so they live here rather than in the
# generic tests/lib.sh. Generic reporters/assertions come from lib.sh via
# wake-helpers.sh.
#
# Source this from a supervision-host test file:
#   # shellcheck source=tests/supervision-host-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"
#
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

if [ -n "${FM_SUPERVISION_HOST_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_SUPERVISION_HOST_HELPERS_SOURCED=1

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

HOST="$ROOT/bin/fm-supervision-host.sh"
# shellcheck disable=SC2034 # read by the sourcing fm-supervision-host*.test.sh files
REPORT="$ROOT/bin/fm-branch-report.sh"
# shellcheck disable=SC2034 # read by the sourcing fm-supervision-host*.test.sh files
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
# shellcheck disable=SC2034 # read by the sourcing fm-supervision-host*.test.sh files
LEASE="$ROOT/bin/fm-lease.sh"

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'skip: perl absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-supervision-host)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The stub engine. It records its environment and arguments, then acts like a
# branch turn through the real scripts according to $FM_HOME/stub-mode:
#   handle      drain, claim the task's lease, report, acknowledge, release
#   captain     the same as handle, but report verdict captain naming the rows
#               the drain presented
#   hold-lease  the same, but leave the lease held (the host must release it),
#               logging its check line while held
#   return      handle, but the captain returns (the record is archived) before
#               the turn ends
#   return-silent the same, but the routine outcome is silent
#   return-fail the same, then exit nonzero without a result
#   return-fail-silent the same, but the routine outcome is silent
#   return-many handle, then seed more than 1,000 same-turn receipts after an
#               early visible outcome
#   return-lookup-fail handle, then corrupt the store before the return lookup
#   return-first the captain returns first, then handle, then block until the
#               host is stopped (an owner killing its host at the turn's end)
#   noack       the same as handle, but skip the acknowledgement
#   held        handle, but first block reading the $FM_HOME/stub-release FIFO
#               until the test writes to it, so the test chooses when the turn
#               ends
#   captain-held the same, but record a captain outcome before the turn ends
#   emptyresult the same as handle, but print {} as its result
#   noreport    drain and exit cleanly without a report
#   go-away     the captain goes away (the record is written) mid-turn, then
#               the turn reports verdict captain
#   fail        exit nonzero at once, with no result and no report (an engine
#               error the latch counts)
#   hang        before anything else, start a descendant in a process group of
#               its own, then block
#   hold-marker the same as handle, but before the result a helper takes the
#               recovery-marker lock for a few seconds, so the host's handled-
#               turn settle is still waiting for it (holding the queue lock)
# A $FM_HOME/stub-tz file sets the engine's TZ, as a wrapper launching the
# real engine binary may, independent of the host's own TZ.
STUB="$TMP_ROOT/engine-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
mode=$(cat "$FM_HOME/stub-mode" 2>/dev/null || echo handle)
[ ! -s "$FM_HOME/stub-tz" ] || { TZ=$(cat "$FM_HOME/stub-tz"); export TZ; }
n=$(( $(ls "$FM_HOME"/engine-call.* 2>/dev/null | wc -l) + 1 ))
{
  printf 'mode=%s\nactor=%s\nholder=%s\nprimary=%s\nturn=%s\n' "$mode" "${FM_SUPERVISION_ACTOR:-}" \
    "${FM_LEASE_HOLDER_PID:-}" "${FM_SUPERVISION_PRIMARY_HARNESS:-}" "${FM_BRANCH_REPORT_TURN:-}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FM_HOME/engine-call.$n"
case "$mode" in held|captain-held) printf 'ready\n' > "$FM_HOME/stub-ready" ;; esac
# Like Claude, the reported cost is the conversation's running total.
result() {
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":%s,' "$(awk -v n="$n" 'BEGIN { print n * 0.25 }')"
  printf '"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20},"session_id":"stub"}\n'
}
if [ "$mode" = hang ]; then
  perl -e 'setpgrp(0, 0); exec "sleep", $ARGV[0]' "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
  printf '%s\n' "$!" > "$FM_HOME/orphan-pid"
  sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
  exit 0
fi
drain=$("$FM_REPO/bin/fm-wake-drain.sh" 2>&1)
printf '%s\n' "$drain" > "$FM_HOME/engine-drain.$n"
ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
task=$(sed -n 's/^tasks=//p' "$STATE/.supervision-host-turn" | awk '{ print $1 }')
[ -n "$task" ] || task=fleet
verdict=routine
[ "$mode" != go-away ] || verdict=captain
case "$mode" in
  fail) exit 3 ;;
  handle|captain|captain-close-before-return|held|captain-held|hold-lease|hold-marker|return|return-silent|return-fail|return-fail-silent|return-many|return-lookup-fail|return-first|noack|emptyresult|go-away)
    case "$mode" in held|captain-held) read -r _ < "$FM_HOME/stub-release" ;; esac
    [ "$mode" != return-first ] || "$FM_REPO/bin/fm-afk-contract.sh" archive >> "$FM_HOME/engine-return.log" 2>&1
    [ "$mode" != go-away ] || "$FM_REPO/bin/fm-afk-contract.sh" enter --words 'gone mid-turn' >> "$FM_HOME/engine-return.log" 2>&1
    "$FM_REPO/bin/fm-lease.sh" claim "$task" >> "$FM_HOME/engine-lease.log" 2>&1
    [ "$mode" != hold-lease ] || "$FM_REPO/bin/fm-lease.sh" check "$task" >> "$FM_HOME/engine-lease.log" 2>&1
    if [ "$mode" = captain ] || [ "$mode" = captain-held ] \
      || [ "$mode" = captain-close-before-return ]; then
      "$FM_REPO/bin/fm-branch-report.sh" --task "$task" --verdict captain \
        --summary "stub escalated: $(printf '%s\n' "$drain" | grep -v '^WAKE_' | tr '\n' ' ' | cut -c1-400)" \
        >> "$FM_HOME/engine-report.log" 2>&1
    else
      report_args=(--task "$task" --verdict "$verdict" --summary "stub handled $task")
      case "$mode" in
        return-silent|return-fail-silent)
          report_args=(--task "$task" --verdict routine --summary 'still working; nothing new has happened; no action was taken' --silent true)
          ;;
      esac
      "$FM_REPO/bin/fm-branch-report.sh" "${report_args[@]}" >> "$FM_HOME/engine-report.log" 2>&1
    fi
    if [ "$mode" = return-many ]; then
      awk -v task="$task" 'BEGIN { for (seq = 2; seq <= 1001; seq++)
        printf "{\"seq\":%d,\"epoch\":1,\"task\":\"%s\",\"wake\":\"host test\",\"verdict\":\"routine\",\"summary\":\"bulk silent fixture\",\"silent\":true}\n", seq, task
      }' >> "$STATE/branch-outcomes.jsonl"
      awk -v turn="$FM_BRANCH_REPORT_TURN" -v task="$task" 'BEGIN { for (seq = 2; seq <= 1001; seq++)
        printf "%s\t%d\troutine\t%s\n", turn, seq, task
      }' >> "$STATE/.supervision-host-receipts"
    fi
    if [ "$mode" = return-lookup-fail ]; then
      printf 'not-json\n' >> "$STATE/branch-outcomes.jsonl"
    fi
    # shellcheck disable=SC2086 # the printed acknowledgement arguments
    [ -z "$ack" ] || [ "$mode" = noack ] || "$FM_REPO/bin/fm-wake-drain.sh" $ack >> "$FM_HOME/engine-ack.log" 2>&1
    case "$mode" in captain-close-before-return)
      watcher=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
      [ -z "$watcher" ] || kill -TERM "$watcher" 2>/dev/null || true
      i=0
      while [ -n "$watcher" ] && kill -0 "$watcher" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
      done
      ;;
    esac
    [ "$mode" = hold-lease ] || "$FM_REPO/bin/fm-lease.sh" release "$task" >> "$FM_HOME/engine-lease.log" 2>&1
    case "$mode" in
      return|return-silent|return-fail|return-fail-silent|return-many|return-lookup-fail) "$FM_REPO/bin/fm-afk-contract.sh" archive >> "$FM_HOME/engine-return.log" 2>&1 ;;
    esac
    case "$mode" in return-fail|return-fail-silent) exit 3 ;; esac
    [ "$mode" != return-first ] || sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
    [ "$mode" != emptyresult ] || { printf '{}\n'; exit 0; }
    if [ "$mode" = hold-marker ]; then
      perl -e 'setpgrp(0, 0); exec @ARGV' bash -c '
        . "$1"
        fm_lock_acquire_wait "$2" || exit 1
        : > "$3"
        sleep 3
        fm_lock_release "$2"' _ "$FM_REPO/bin/fm-wake-lib.sh" "$STATE/.watcher-down.lock" "$FM_HOME/marker-held" \
        >/dev/null 2>&1 </dev/null &
      i=0
      while [ ! -e "$FM_HOME/marker-held" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
      done
    fi
    result
    ;;
  noreport) result ;;
esac
SH
chmod +x "$STUB"

export FM_REPO="$ROOT"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$STUB"
export FM_SUPERVISION_HOST_PRIMARY=claude
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
# Keep the real engine watchdog/reaping path, but not its production grace in fixtures.
export FM_SUPERVISION_ENGINE_GRACE=1
export FM_ARM_CONFIRM_TIMEOUT=30
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID PI_CODING_AGENT

# Homes are registered in a file: make_home runs in a command substitution,
# whose variables never reach this shell.
HOMES_FILE="$TMP_ROOT/homes"
# Stop whatever a case left running, by the exact pids its home recorded.
stop_home_processes() {  # <home>
  local home=$1 pid arms='' i=0
  pid=$(cut -f1 "$home/state/.supervision-handoff-owner" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  if [ -f "$home/state/.supervision-host" ]; then
    arms=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt 50 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
  for pid in $arms; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  while IFS= read -r pid; do
    if [ -e "$home/session.stop" ]; then
      wait "$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(cat "$home/claude-pids" 2>/dev/null)
  while IFS= read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done < <(cat "$home/orphan-pid" 2>/dev/null)
}
suite_cleanup() {
  local home
  while IFS= read -r home; do
    [ -n "$home" ] && stop_home_processes "$home"
  done < <(cat "$HOMES_FILE" 2>/dev/null)
  fm_test_cleanup
}
trap suite_cleanup EXIT

make_home() {  # <name> <attended|away|quiet> [config line]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  # An unreachable backend: the watcher reads no endpoint as dead, so the only
  # wakes are the status appends each case makes.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  make_fake_crew_state "$home/fakebin" >/dev/null
  printf '%s\n' "${3:-}" > "$home/config/supervision-host"
  [ -n "${3:-}" ] || : > "$home/config/supervision-host"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  echo handle > "$home/stub-mode"
  # The captain has spoken in this session, so an attended wake has a mirror.
  [ "$2" = away ] \
    || printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  if [ "$2" = away ]; then
    FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
      || fail "fixture: could not record the away posture"
  fi
  # Quiet mode's record with no daemon flag: a quiet entry whose daemon never
  # started or stopped, left beside a present captain.
  if [ "$2" = quiet ]; then
    FM_HOME="$home" FM_AFK_MODE=quiet "$CONTRACT" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
    [ "$(FM_HOME="$home" "$CONTRACT" mode)" = quiet ] || fail "fixture: the record is not quiet mode's"
  fi
  printf '%s\n' "$home" >> "$HOMES_FILE"
  printf '%s\n' "$home"
}

# A git checkout that passes the primary-scope check, so the dialog-mirror
# writer runs from a linked worktree too; its bin is this repo's bin.
MIRROR_ROOT="$TMP_ROOT/mirror-root"
mkdir -p "$MIRROR_ROOT"
git init -q "$MIRROR_ROOT"
: > "$MIRROR_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$MIRROR_ROOT/bin"

# Run the host under the fake harness that holds the home's session lock.
# Every hook payload in $home/mirror-seed.* is first written to the dialog
# mirror by that same session, as its prompt and Stop hooks would.
start_host() {  # <home> [park options...]
  local home=$1
  shift
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      rm -f "$FM_HOME/host.rc"
      for seed in "$FM_HOME"/mirror-seed.*; do
        [ -f "$seed" ] || continue
        FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$seed"
      done
      "$0" park "$@" > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" "$@" 2>> "$home/claude.err" &
}

# Extended-regex twins of tests/lib.sh's fixed-string assert_grep pair.
assert_re() {  # <regex> <file> <msg>
  grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}
assert_no_re() {  # <regex> <file> <msg>
  ! grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Time-based wait used for host hand-back. The previous poll-count waits
# (wait_until 200|250 host_exited, ~20-25s) flake on a slow runner; this
# helper polls at the same 0.1s interval until the deadline. On timeout of
# host_exited it dumps the fixture host log, supervision-host log, health
# file, and a process tree so a CI failure is diagnosable.
wait_until_deadline() {  # <seconds> <command...>
  local limit=$1 start
  shift
  case "$limit" in
    ''|*[!0-9]*) return 1 ;;
  esac
  start=$SECONDS
  while true; do
    "$@" && return 0
    [ $((SECONDS - start)) -lt "$limit" ] || break
    sleep 0.1
  done
  case "${1:-}" in
    host_exited|hook_exited) dump_host_handback_diagnostics "${2:-}" "$1" ;;
  esac
  return 1
}

dump_host_handback_diagnostics() {  # <home> [wait-name]
  local home=${1:-} waited=${2:-host_exited}
  printf 'wait_until_deadline: %s timed out for %s\n' "$waited" "${home:-<missing home>}" >&2
  printf '--- host.out ---\n' >&2
  if [ -n "$home" ] && [ -f "$home/host.out" ]; then
    cat "$home/host.out" >&2
  else
    printf '(missing)\n' >&2
  fi
  printf '--- .supervision-host.log ---\n' >&2
  if [ -n "$home" ] && [ -f "$home/state/.supervision-host.log" ]; then
    cat "$home/state/.supervision-host.log" >&2
  else
    printf '(missing)\n' >&2
  fi
  printf '--- .supervision-host-health ---\n' >&2
  if [ -n "$home" ] && [ -f "$home/state/.supervision-host-health" ]; then
    cat "$home/state/.supervision-host-health" >&2
  else
    printf '(missing)\n' >&2
  fi
  if [ "$waited" = hook_exited ]; then
    printf '--- hook.out ---\n' >&2
    if [ -n "$home" ] && [ -f "$home/hook.out" ]; then
      cat "$home/hook.out" >&2
    else
      printf '(missing)\n' >&2
    fi
    printf '--- hook.err ---\n' >&2
    if [ -n "$home" ] && [ -f "$home/hook.err" ]; then
      cat "$home/hook.err" >&2
    else
      printf '(missing)\n' >&2
    fi
  fi
  printf '--- process tree ---\n' >&2
  if ps -axo pid,ppid,pgid,etime,command >/dev/null 2>&1; then
    ps -axo pid,ppid,pgid,etime,command >&2
  else
    ps -ef >&2
  fi
}


watcher_live() {  # <home>
  local pid
  pid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
host_exited() { [ -s "$1/host.rc" ]; }
# The recovery marker's episode kind (downtime or handling), read through its
# owner's parser; the Claude re-arm owner delivers a close only on downtime.
marker_kind() {  # <home>
  FM_HOME="$1" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    kind=${FM_RECOVERY_MARKER_TOKEN#*:}
    printf "%s\n" "${kind%%:*}"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1/state/.watcher-down"
}
engine_calls() { find "$1" -maxdepth 1 -name 'engine-call.*' 2>/dev/null | wc -l | tr -d ' '; }
handled_count() { local n; n=$(grep -c '	handled	' "$1/state/.supervision-host.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }
handled_at_least() { [ "$(handled_count "$1")" -ge "$2" ]; }
append_status() {  # <home> <text>
  printf '%s [at=%s]: %s\n' "${3:-working}" "$(date +%s)" "$2" >> "$1/state/demo.status"
}

# One store row exactly as bin/fm-branch-outcome.sh append writes it, at a
# chosen epoch, so a case can hold outcomes recorded days before the drain.
outcome_row() {  # <seq> <epoch> <task> <verdict> <summary>
  printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"signal: %s.status","verdict":"%s","summary":"%s","silent":false,"statusEndpoint":0,"statusIdent":"-"}\n' \
    "$1" "$2" "$3" "$3" "$4" "$5"
}


# A host home whose drain has presented a captain outcome twice without an
# acknowledgement: the read cursor is past it and the processed marker is
# still absent. Sets PRESENTED_HOME.
present_unacknowledged_outcome_twice() {  # <name>
  local drained
  PRESENTED_HOME="$TMP_ROOT/$1"
  mkdir -p "$PRESENTED_HOME/state" "$PRESENTED_HOME/config"
  : > "$PRESENTED_HOME/config/supervision-host"
  FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" append --task epsilon --verdict captain \
    --summary 'epsilon PR is ready to merge' >/dev/null || fail "fixture: could not record the captain outcome"
  for _ in 1 2; do
    drained=$(FM_HOME="$PRESENTED_HOME" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    assert_contains "$drained" "epsilon: epsilon PR is ready to merge" "fixture: the drain must present the captain outcome"
  done
  [ "$(cat "$PRESENTED_HOME/state/.branch-outcomes-cursor")" = 1 ] || fail "fixture: the drain did not advance the read cursor"
  assert_absent "$PRESENTED_HOME/state/.branch-outcomes-processed" "fixture: nothing acknowledged the outcome"
}


# The close is accepted attended as routine, then its task turns main-only (a
# decision is recorded) while the successor starts: the turn meets the offer
# rule again, so the close reaches main exactly as the arm printed it and no
# engine turn runs on the stale offer.
# Change the task immediately before the second offer computation, rather
# than racing the successor startup. The first offer accepts the close; the
# turn-boundary offer must see the new main-owned decision.
turn_main_only_at_second_offer() {  # <home> [quiet|snapshot]
  local real_node turn snapshot=':'
  real_node=$(command -v node)
  turn='printf '"'"'needs-decision [at=%s]: which export format?\n'"'"' "$(date +%s)" >> "$FM_HOME/state/demo.status"'
  # Quiet: the offer alone turns main-only, with no status line for the
  # successor watcher to close on.
  [ "${2:-}" != quiet ] || turn='echo eligible=0; exit 0'
  if [ "${2:-}" = snapshot ]; then
    # Freeze the accepted queue before the new status can reach the successor.
    # Pi must see the old signal plus the new status, not a later decision wake.
    snapshot='mkdir -p "$FM_HOME/pi-offer-state"
      cp "$FM_HOME/state/.wake-queue" "$FM_HOME/state/demo.meta" "$FM_HOME/pi-offer-state/"'
    turn="$turn"'
      cp "$FM_HOME/state/demo.status" "$FM_HOME/pi-offer-state/"'
  fi
  cat > "$1/fakebin/node" <<SH
#!/usr/bin/env bash
case "\$*" in
  *fm-branch-dispatch.mjs\ offer*)
    count=\$(cat "\$FM_HOME/offer-count" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$FM_HOME/offer-count"
    if [ "\$count" -eq 2 ]; then
      $snapshot
      $turn
    fi ;;
esac
exec "$real_node" "\$@"
SH
  chmod +x "$1/fakebin/node"
}


# --- the Claude re-arm owner around the host ----------------------------------

# A fixture home that is also a genuine primary checkout whose bin is this
# repo's, so the real Claude Stop hook (bin/fm-claude-stop-autoarm.sh) runs the
# real host in it.
make_primary_home() {  # <name>
  local home
  home=$(make_home "$1" attended)
  git init -q "$home"
  : > "$home/AGENTS.md"
  ln -s "$ROOT/bin" "$home/bin"
  printf '%s\n' "$home"
}


# One Claude main session under the fake harness. Each turn_end fires the real
# Stop hook as the tracked asyncRewake registration does, and records its exit
# status and stderr (the rewake banner Claude delivers on exit 2).
start_hook_session() {  # <home>
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    PATH="$home/fakebin:$PATH" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      for seed in "$FM_HOME"/mirror-seed.*; do
        [ -f "$seed" ] || continue
        "$FM_HOME/bin/fm-host-mirror.sh" hook claude < "$seed"
      done
      while [ ! -e "$FM_HOME/session.stop" ] && [ -d "$FM_HOME" ] \
        && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null; do
        if [ -e "$FM_HOME/stop.go" ]; then
          rm -f "$FM_HOME/stop.go"
          if [ -e "$FM_HOME/hook.own-group" ]; then
            # Claude owns the hook as a process group of its own and tears the
            # whole group down once the hook has exited.
            printf "{\"session_id\":\"sess-host-hook\",\"stop_hook_active\":false}\n" > "$FM_HOME/hook.stdin"
            set -m
            "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/hook.stdin" > "$FM_HOME/hook.out" 2> "$FM_HOME/hook.err" &
            printf "%s\n" "$!" > "$FM_HOME/hook.pgid"
            wait "$!"
            printf "%s\n" "$?" > "$FM_HOME/hook.rc"
            set +m
          else
            printf "{\"session_id\":\"sess-host-hook\",\"stop_hook_active\":false}\n" \
              | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/hook.out" 2> "$FM_HOME/hook.err"
            printf "%s\n" "$?" > "$FM_HOME/hook.rc"
          fi
        fi
        sleep 0.1
      done
    ' 2>> "$home/claude.err" &
}

turn_end() { rm -f "$1/hook.rc"; : > "$1/stop.go"; }

hook_exited() { [ -s "$1/hook.rc" ]; }


# Main's rewoken turn drains; the caller runs the printed acknowledgement
# (MAIN_ACK) when that turn's handling is done.
main_drain() {  # <home>; prints the drain and sets MAIN_ACK
  local out
  out=$(FM_HOME="$1" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  MAIN_ACK=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  printf '%s\n' "$out"
}


assert_rewoke_main() {  # <home> <label>
  expect_code 2 "$(cat "$1/hook.rc")" "$2: the Stop hook must rewake main: $(cat "$1/hook.err"; cat "$1/state/.watcher-down" 2>/dev/null)"
  assert_grep 'firstmate watcher wake - one supervision event needs a handling turn now.' "$1/hook.err" "$2: the rewake banner is missing"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=rewake ' "$1/state/.claude-autoarm-epoch" "$2: the auto-arm ledger must record the rewake"
}


# A second task closes the successor while the first turn still owns handling
# Its queued rows keep that handling episode open after the first turn's ack
assert_main_only_close_after_handled_turn() {  # <restore|refuse>
  local mode=$1 home successor real_mktemp
  home=$(make_primary_home "hook-inherited-handling-$mode")
  ln -s "$ROOT/.agents" "$home/.agents"
  cat > "$home/engine-delayed" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/before-drain.ready"
while [ ! -e "$FM_HOME/before-drain.release" ]; do sleep 0.1; done
"$FM_TEST_ENGINE_ORIGINAL" "$@"
rc=$?
: > "$FM_HOME/before-return.ready"
while [ ! -e "$FM_HOME/before-return.release" ]; do sleep 0.1; done
exit "$rc"
SH
  chmod +x "$home/engine-delayed"
  if [ "$mode" = refuse ]; then
    real_mktemp=$(command -v mktemp)
    cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/.watcher-down.tmp.'*) [ ! -e "\$FM_HOME/fail-downtime-write" ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
    chmod +x "$home/fakebin/mktemp"
  fi
  FM_TEST_ENGINE_ORIGINAL="$STUB" FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/engine-delayed" start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "inherited handling: no watcher started"
  append_status "$home" 'measurement driver running' paused
  wait_until 250 test -e "$home/before-drain.ready" || fail "inherited handling: the first turn never started"
  successor=$(cat "$home/state/.watch.lock/pid")
  printf 'project=demo\nwindow=fm-beta\nharness=claude\n' > "$home/state/beta.meta"
  printf 'needs-decision [at=%s]: select an export format\n' "$(date +%s)" > "$home/state/beta.status"
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "inherited handling: the main-only close did not occur during the first turn"
  : > "$home/before-drain.release"
  wait_until 250 test -e "$home/before-return.ready" || fail "inherited handling: the engine did not finish handling"
  assert_re '^pending:handling:' "$home/state/.watcher-down" \
    "fixture: the first turn did not leave an inherited handling episode"
  [ "$mode" != refuse ] || : > "$home/fail-downtime-write"
  : > "$home/before-return.release"
  wait_until_deadline 60 hook_exited "$home" || fail "inherited handling: the Stop hook did not finish"
  assert_re 'handled.*posture=attended' "$home/state/.supervision-host.log" "the first turn must finish"
  assert_re 'pass-through[[:space:]]+attended[[:space:]]+main-only[[:space:]]+signal: .*beta.status' \
    "$home/state/.supervision-host.log" "the second close must use the initial main-only path"
  assert_grep 'beta.status' "$home/state/.wake-queue" "the main-owned rows must remain queued"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "the engine took the main-only close"
  if [ "$mode" = restore ]; then
    assert_rewoke_main "$home" "inherited handling"
    assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
      "the inherited episode must become deliverable downtime"
    watcher_live "$home" || fail "the repaired hand-back must keep its successor alive"
  else
    expect_code 2 "$(cat "$home/hook.rc")" "restore refusal must notify main rather than exit silently"
    assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "the failure notice must reach main"
    assert_re 'pass-through[[:space:]]+downtime-unrestored' "$home/state/.supervision-host.log" \
      "fixture: the inherited episode restore did not fail"
    assert_re 'outcome=failed ' "$home/state/.claude-autoarm-epoch" "the failure notice must be committed"
  fi
  stop_home_processes "$home"
}


# A handled stale event for the idle worker, in the given posture, after the
# handled paused and resolved signals
stale_handled_after_resolved() {  # <home> <posture>
  awk -F '\t' -v posture="posture=$2" '
    $2 != "handled" { next }
    /signal: .*\/demo\.status$/ { signals++; next }
    signals >= 2 && index($0, posture) && /stale: firstmate:fm-demo$/ { found = 1 }
    END { exit !found }
  ' "$1/state/.supervision-host.log" 2>/dev/null
}


# Model the same returned driver with monitoring intact, in both postures
assert_returned_driver_is_caught() {  # <attended|away>
  local posture=$1 home
  home=$(make_primary_home "hook-returned-driver-$posture")
  ln -s "$ROOT/.agents" "$home/.agents"
  if [ "$posture" = away ]; then
    FM_HOME="$home" "$CONTRACT" enter --words 'keep the worker moving' >/dev/null 2>&1 \
      || fail "returned driver: could not record away posture"
  fi
  FM_STALE_ESCALATE_SECS=4 start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "returned driver: no watcher started"
  append_status "$home" 'measurement driver running' paused
  wait_until 250 handled_at_least "$home" 1 || fail "returned driver: the paused signal was not handled"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-demo\n'; exit 0 ;;
  capture-pane) printf 'Pi idle prompt; measurement driver returned\n'; exit 0 ;;
  display-message) printf 'node\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  printf 'window=firstmate:fm-demo\nproject=demo\nkind=ship\nharness=pi\nbackend=tmux\n' > "$home/state/demo.meta"
  append_status "$home" 'measurement driver returned; inspect receipts' resolved
  # A hang guard only; the stale event's order after the resolved hand-back is the assertion
  wait_until 1200 stale_handled_after_resolved "$home" "$posture" \
    || fail "returned driver: the idle worker was not stale-handled in posture $posture after its resolved signal: $(cat "$home/state/.supervision-host.log")"
  [ ! -s "$home/hook.rc" ] || fail "a routine returned-driver wake reached main"
  wait_until 250 watcher_live "$home" || fail "the returned-driver control lost monitoring"
  stop_home_processes "$home"
}


assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails() {
  local status=$1 home real_mktemp successor
  home=$(make_primary_home "hook-successor-restore-fails-$status")
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  real_mktemp=$(command -v mktemp)
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/.watcher-down.tmp.'*) [ ! -e "\$FM_HOME/fail-downtime-write" ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "restore failure: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "restore failure: the engine did not reach its hold"
  successor=$(cat "$home/state/.watch.lock/pid")
  append_status "$home" 'wake while the engine is handling'
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "restore failure: its watcher did not close during the engine turn"
  FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
    || fail "fixture: could not model the queued successor wake entering handling"
  if [ "$status" = announced ]; then
    FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_read "$2" && _fm_recovery_marker_write_locked "$2" handling "${FM_RECOVERY_MARKER_TOKEN##*:}" announced' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
      || fail "fixture: could not model the handling episode as announced"
  fi
  assert_re "^$status:handling:" "$home/state/.watcher-down" \
    "fixture: the closed handling successor must leave the marker in handling before the host hands back"
  : > "$home/fail-downtime-write"
  printf 'continue\n' > "$home/stub-release"
  wait_until_deadline 60 hook_exited "$home" || fail "restore failure: the Stop hook did not finish"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must notify main when neither hand-back nor downtime restoration commits"
  assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "the refused rewake must turn into a delivered failure notice"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=failed ' "$home/state/.claude-autoarm-epoch" \
    "the failed hand-back must be committed"
}


# The arm processes running from <home>'s bin, one "<pid> <ppid>" per line.
# A command substitution inside an arm is a forked copy that shows the same
# command line, so a process whose parent is itself an arm is not counted.
home_arms() {  # <home>
  ps -A -o pid= -o ppid= -o command= 2>/dev/null \
    | awk -v arm="$1/bin/fm-watch-arm.sh" '
        $3 ~ /(^|\/)bash$/ && $4 == arm { ppid[$1] = $2; order[++n] = $1 }
        END { for (i = 1; i <= n; i++) if (!(ppid[order[i]] in ppid)) print order[i], ppid[order[i]] }'
}

parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }


# True once the park's own arm owns the home's only watcher cycle: exactly one
# arm runs from the home, it is the host's child, and it is the watcher's parent.
host_owns_the_only_cycle() {  # <home>
  local home=$1 host watcher arm arms
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host" 2>/dev/null)
  watcher=$(cat "$home/state/.watch.lock/pid" 2>/dev/null)
  [ -n "$host" ] && [ -n "$watcher" ] && kill -0 "$watcher" 2>/dev/null || return 1
  arms=$(home_arms "$home")
  [ "$(printf '%s\n' "$arms" | grep -c .)" -eq 1 ] || return 1
  arm=$(parent_of "$watcher")
  [ "$arms" = "$arm $host" ]
}

leave_a_cycle_for_main_and_restart() {  # <home>
  local home=$1 first_session
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "takeover: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 hook_exited "$home" || fail "takeover: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "takeover (pass-through)"
  LEFT_WATCHER=$(cat "$home/state/.watch.lock/pid")
  LEFT_ARM=$(parent_of "$LEFT_WATCHER")
  [ -n "$LEFT_ARM" ] && [ "$LEFT_ARM" != 1 ] || fail "fixture: the successor watcher has no arm of its own"
  main_drain "$home" >/dev/null
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "takeover: main's acknowledgement failed: $MAIN_ACK"
  # The session restarts: the old one ends, and a new one holds the lock.
  first_session=$(tail -n 1 "$home/claude-pids")
  : > "$home/session.stop"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$first_session" || fail "fixture: the first session did not end"
  rm -f "$home/session.stop"
  kill -0 "$LEFT_ARM" 2>/dev/null || fail "fixture: the successor arm did not outlive its session"
  start_hook_session "$home"
}


no_home_arms() { [ -z "$(home_arms "$1")" ]; }


mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }


# Park again after a host was stopped mid-park: the new cycle's first close is
# the watcher's downtime resurface, which main drains before the next park.
# That close can end the park before its cycle is ever seen live, so this
# waits for the exit itself.
# The resurface pass-through leaves its successor running. Stop that watcher
# and acknowledge the downtime its exit records, so the next park starts a
# watcher it owns. Attaching instead would not observe the exit until the
# beacon went stale, and this fixture's turn budget would already be gone.
quiet_pass_through_successor() {  # <home>
  local home=$1 pid i gen
  pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && fail "fixture: the pass-through successor did not stop"
  fi
  gen=$(cat "$home/state/.watcher-down" 2>/dev/null || true)
  gen=${gen##*:}
  [ -n "$gen" ] || return 0
  FM_HOME="$home" bash -c '
    . "$1"
    fm_recovery_marker_ack "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" "$gen" \
    || fail "fixture: could not acknowledge the successor downtime"
}


park_after_stop() {  # <home>
  rm -f "$1/host.rc"
  : > "$1/park.go"
  wait_until_deadline 60 host_exited "$1" || fail "the watcher's downtime resurface did not reach main: $(cat "$1/host.out")"
  assert_re '^check: rearm-resurface' "$1/host.out" "fixture: the first close after the watcher stopped was not its resurface"
  main_drain_and_ack "$1"
  quiet_pass_through_successor "$1"
  park_again "$1"
}


compacted_once() { [ "$(compact_calls "$1")" = 1 ]; }

compact_calls() { grep -l '^arg=/compact$' "$1"/engine-call.* 2>/dev/null | wc -l | tr -d ' '; }


# Seed the engine record the way a handled turn leaves it, keyed to the live
# fake main session, with a transcript large enough to be due.
seed_idle_engine_record() {  # <home> <ended-age-seconds>
  local home=$1 key model state="$1/state" ended compacted
  key=$(FM_HOME="$home" bash -c '. "$1"; . "$2"; fm_supervision_host_main_key "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$state") \
    || fail "warm-compact: no main-session key"
  model=$(bash -c '. "$1"; fm_supervision_host_config "$2" claude; printf "%s" "$FM_SUPERVISION_ENGINE_MODEL"' _ "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/config")
  ended=$(sed -n 's/^ended=//p' "$state/.supervision-host-engine" 2>/dev/null | head -n 1)
  [ -n "$ended" ] || ended=$(( $(date +%s) - $2 ))
  compacted=$(sed -n 's/^compacted=//p' "$state/.supervision-host-engine" 2>/dev/null | head -n 1)
  printf 'engine=claude\nmodel=%s\nsession=warm-sess\nkey=%s\nturns=1\nconversation_cost=0\nended=%s\n' "$model" "$key" "$ended" > "$state/.supervision-host-engine"
  [ -z "$compacted" ] || printf 'compacted=%s\n' "$compacted" >> "$state/.supervision-host-engine"
  printf 'prompt\n' > "$state/.supervision-host-prompt"
}


# A park at or beyond the hook registration is refused for the default. The
# default is observable through the pre-turn margin: a turn bound plus grace of
# 27000 seconds crosses a 27000-second park, so the close goes to main at the
# boundary, while under a 28799-second park the same turn runs.
park_outcome() {  # <name> <park-seconds>; sets PARK_OUTCOME to boundary or handled
  local home
  home=$(make_home "$1" away)
  FM_SUPERVISION_HOST_PARK_SECONDS=$2 FM_SUPERVISION_HOST_TURN_TIMEOUT=26990 FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "$1: the host never started a watcher cycle"
  append_status "$home" 'one close'
  wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
    || fail "$1: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
  if host_exited "$home"; then
    grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$1: the host exited without the boundary: $(cat "$home/host.out")"
    ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "$1: an engine turn ran before the boundary exit"
    # shellcheck disable=SC2034 # read by the sourcing fm-supervision-host*.test.sh files
    PARK_OUTCOME=boundary
  else
    kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
    wait_until_deadline 60 host_exited "$home" || fail "$1: the host did not stop on TERM"
    # shellcheck disable=SC2034 # read by the sourcing fm-supervision-host*.test.sh files
    PARK_OUTCOME=handled
  fi
}


# Main's side of a handed-back wake: drain, then run the printed acknowledgement.
main_drain_and_ack() {  # <home>
  local out ack
  out=$(FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$ack" ] || FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1 || fail "main's acknowledgement failed: $ack"
}


# One main session across several parks, as a primary's arm owner runs the host
# again at each turn end: the session lock stays this one fake harness, so the
# host's per-session state (the latch, the engine conversation) carries
# across its parks; the mirror seeds are written before each park, as in
# start_host.
start_session() {  # <home>
  local home=$1
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      while [ ! -e "$FM_HOME/session.stop" ] && [ -d "$FM_HOME" ] \
        && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null; do
        if [ -e "$FM_HOME/park.go" ]; then
          rm -f "$FM_HOME/park.go"
          for seed in "$FM_HOME"/mirror-seed.*; do
            [ -f "$seed" ] || continue
            FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$seed"
          done
          "$0" park > "$FM_HOME/host.out" 2>&1
          printf "%s\n" "$?" > "$FM_HOME/host.rc"
        fi
        sleep 0.1
      done
    ' "$HOST" 2>> "$home/claude.err" &
}


park_again() {  # <home>
  rm -f "$1/host.rc"
  : > "$1/park.go"
  wait_until 150 watcher_live "$1" \
    || fail "the next park never started a watcher cycle: $(cat "$1/host.out"; tail -n 5 "$1/state/.supervision-host.log" 2>/dev/null)"
}


# Let the latch's cooldown pass, as the clock would, by moving its persisted
# probe time into the past, optionally with a cooldown already grown to
# <seconds>; the next close then probes the engine.
end_cooldown() {  # <home> [seconds]
  local health="$1/state/.supervision-host-health" tmp
  grep -q '^retry_after=[1-9]' "$health" 2>/dev/null || fail "the latch recorded no probe time"
  tmp=$(mktemp "$health.XXXXXX")
  if ! { sed -e 's/^retry_after=.*/retry_after=1/' ${2:+-e "s/^cooldown=.*/cooldown=$2/"} "$health" > "$tmp" \
    && mv -f "$tmp" "$health"; }; then
    fail "fixture: could not move the latch's probe time"
  fi
}


# Two consecutive engine errors in one main session: the second trips the latch.
trip_latch() {  # <home>
  echo fail > "$1/stub-mode"
  start_session "$1"
  park_again "$1"
  append_status "$1" 'first'
  wait_until_deadline 60 host_exited "$1" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$1/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$1"
  park_again "$1"
  append_status "$1" 'second'
  wait_until_deadline 60 host_exited "$1" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the tripping handback must still say why"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' \
    "$1/host.out" "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$1/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$1"
}


# The 2026-09-25 away-window flood: a held, green PR on a finished task was
# re-escalated on every inactive-outcome cadence, because the branch
# acknowledgement consumed the check row but left its terminal-outcome receipt
# pending, so each later scan re-queued the same fingerprint. Through the real
# watcher cadence, host, report surface, and drain, that unchanged situation
# now reaches the captain exactly once, and a new event on the same task - a
# decision - still reaches the captain path afterwards.
scan_marker_age() {  # <home> -> seconds since the last inactive-outcome scan
  perl -e 'my @s = stat $ARGV[0] or exit 1; print time - $s[9]' "$1/state/.inactive-outcome-reconcile"
}

scan_ran() { [ "$(scan_marker_age "$1" 2>/dev/null || echo 999999)" -lt 60 ]; }

scan_idle() {  # <home>
  [ ! -e "$1/state/.inactive-outcome-reconcile.lock" ] && [ ! -L "$1/state/.inactive-outcome-reconcile.lock" ]
}

captain_rows() {  # <home>
  local rows
  rows=$(grep -c '"verdict":"captain"' "$1/state/branch-outcomes.jsonl" 2>/dev/null)
  printf '%s\n' "${rows:-0}"
}

captain_rows_at_least() { [ "$(captain_rows "$1")" -ge "$2" ]; }

flood_signal() {  # <home>
  captain_rows_at_least "$1" 2 || grep -qs '	inactive-outcome:' "$1/state/.wake-queue"
}


assert_lost_handoff_keeps_watching() {  # <boundary|pass-through>
  local mode=$1 home watcher
  home=$(make_primary_home "lost-handoff-$mode")
  : > "$home/config/supervision-handoff-ack"
  : > "$home/hook.own-group"
  printf 'project=demo\nwindow=fm-other\nharness=claude\n' > "$home/state/other.meta"
  FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 FM_SUPERVISION_HOST_PARK_SECONDS=3600 \
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "$mode: no initial watcher"
  if [ "$mode" = boundary ]; then
    echo 3600 > "$home/park-clock"
  else
    append_status "$home" 'which export format?' needs-decision
  fi
  wait_until_deadline 60 hook_exited "$home" || fail "$mode: no hand-back"
  assert_rewoke_main "$home" "$mode"
  # The hand-back keeps the row the default path writes: it is what the
  # diagnosis of an unsupervised home reads first.
  if [ "$mode" = boundary ]; then
    assert_re '	boundary	after [0-9]+s$' "$home/state/.supervision-host.log" "$mode: the hand-back dropped the boundary row"
  else
    assert_re '	pass-through	attended	main-only	' "$home/state/.supervision-host.log" "$mode: the hand-back dropped the pass-through row"
  fi
  kill -TERM -- "-$(cat "$home/hook.pgid")" 2>/dev/null || true
  # Drop the continuation entirely: no drain, acknowledgement, or Stop follows.
  watcher_live "$home" || fail "$mode: lost continuation left no verified watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  printf 'working [at=%s]: another event\n' "$(date +%s)" >> "$home/state/other.status"
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" \
    || fail "$mode: the successor did not observe the later event"
  wait_until 150 watcher_live "$home" || fail "$mode: a successor close left supervision down"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" \
    || fail "$mode: the unacknowledged hand-back was not raised again"
  assert_grep 'other.status' "$home/state/.wake-queue" "the later event must stay durable"
  assert_grep 'supervision-handoff' "$home/state/.wake-queue" "the hand-back must remain acknowledgeable"
  main_drain "$home" > "$home/main-drain.out"
  assert_grep 'supervision-handoff' "$home/main-drain.out" "main must receive the hand-back again"
  [ -n "$MAIN_ACK" ] || fail "$mode: no main acknowledgement"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "$mode: presentation incorrectly confirmed ownership"
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through 0 --recovery-generation "${MAIN_ACK##* }" > "$home/stale-ack.out" 2>&1 \
    || fail "$mode: the stale acknowledgement could not be checked"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "$mode: a stale acknowledgement confirmed unseen work"
  # shellcheck disable=SC2086 # The drain's printed arguments.
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "$mode: main could not acknowledge"
  wait_until 150 bash -c '[ ! -e "$1/state/.supervision-handoff-pending" ]' _ "$home" \
    || fail "$mode: acknowledgement did not confirm ownership"
  watcher_live "$home" || fail "$mode: acknowledgement stopped supervision"
  echo 0 > "$home/park-clock"
  turn_end "$home"
  wait_until 250 host_owns_the_only_cycle "$home" || fail "$mode: the next park did not take over exactly one watcher"
  stop_home_processes "$home"
  pass "host+hook: $mode survives a lost continuation, retries, and transfers one watcher after acknowledgement"
}

