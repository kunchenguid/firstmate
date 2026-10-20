#!/usr/bin/env bash
# tests/supervision-host-helpers.sh - the fixture and helpers shared by the
# supervision host suites, tests/fm-supervision-host.test.sh and
# tests/fm-supervision-host-late.test.sh. Sourcing it creates the suite's
# TMP_ROOT and installs the EXIT trap that stops whatever its homes left running.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# REPORT, DISPATCH, and LEASE are read only by the sourcing suites.
HOST="$ROOT/bin/fm-supervision-host.sh"
# shellcheck disable=SC2034
REPORT="$ROOT/bin/fm-branch-report.sh"
# shellcheck disable=SC2034
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
# shellcheck disable=SC2034
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
#   hold-lease  the same, but leave the lease held (the host must release it)
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
STUB="$TMP_ROOT/engine-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
mode=$(cat "$FM_HOME/stub-mode" 2>/dev/null || echo handle)
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
  handle|captain|captain-close-before-return|held|captain-held|hold-lease|return|return-silent|return-fail|return-fail-silent|return-many|return-lookup-fail|return-first|noack|emptyresult|go-away)
    case "$mode" in held|captain-held) read -r _ < "$FM_HOME/stub-release" ;; esac
    [ "$mode" != return-first ] || "$FM_REPO/bin/fm-afk-contract.sh" archive >> "$FM_HOME/engine-return.log" 2>&1
    [ "$mode" != go-away ] || "$FM_REPO/bin/fm-afk-contract.sh" enter --words 'gone mid-turn' >> "$FM_HOME/engine-return.log" 2>&1
    "$FM_REPO/bin/fm-lease.sh" claim "$task" >> "$FM_HOME/engine-lease.log" 2>&1
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

watcher_live() {  # <home>
  local pid
  pid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

host_exited() { [ -s "$1/host.rc" ]; }

engine_calls() { find "$1" -maxdepth 1 -name 'engine-call.*' 2>/dev/null | wc -l | tr -d ' '; }

handled_count() { local n; n=$(grep -c '	handled	' "$1/state/.supervision-host.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }

handled_at_least() { [ "$(handled_count "$1")" -ge "$2" ]; }

append_status() {  # <home> <text>
  printf '%s [at=%s]: %s\n' "${3:-working}" "$(date +%s)" "$2" >> "$1/state/demo.status"
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
      while [ ! -e "$FM_HOME/session.stop" ]; do
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
