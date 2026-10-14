#!/usr/bin/env bash
# Shared supervision-host fixture, fake harness, and stub engine.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
# shellcheck disable=SC2034 # fixture variables are consumed by the sourcing suites

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

HOST="$ROOT/bin/fm-supervision-host.sh"
REPORT="$ROOT/bin/fm-branch-report.sh"
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
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
[ "$mode" != fleet ] || task=fleet
verdict=routine
[ "$mode" != go-away ] || verdict=captain
case "$mode" in
  fail) exit 3 ;;
  handle|fleet|captain|captain-close-before-return|held|captain-held|hold-lease|return|return-silent|return-fail|return-fail-silent|return-many|return-lookup-fail|return-first|noack|emptyresult|go-away)
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
      while [ ! -e "$FM_HOME/session.stop" ]; do
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


# A registered check the real watcher sweeps. Every sweep appends its epoch to
# <home>/sweeps, and it reports one event for each <home>/emit.<n> it finds.
register_sweep_check() {  # <home>
  local home=$1
  cat > "$home/state/sweep.check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(date +%s)" >> "$home/sweeps"
for f in "$home"/emit.*; do
  [ -e "\$f" ] || continue
  rm -f "\$f"
  printf 'fixture-event-%s\n' "\${f##*.}"
  exit 0
done
SH
  chmod 700 "$home/state/sweep.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" sweep >/dev/null || fail "fixture: could not register the sweep check"
}
sweep_count() { if [ -f "$1/sweeps" ]; then wc -l < "$1/sweeps" | tr -d ' '; else echo 0; fi; }
sweeps_reach() { [ "$(sweep_count "$1")" -ge "$2" ]; }
event_consumed() { [ ! -e "$1/emit.$2" ]; }
# The longest wait between two completed sweeps, from the <from>th sweep on.
max_sweep_gap() {  # <home> <from>
  awk -v from="$2" 'NR >= from { if (prev && $1 - prev > max) max = $1 - prev; prev = $1 } END { print max + 0 }' "$1/sweeps"
}
# The sweep cadence the fixture accepts between two completed sweeps: the
# one-second interval, the restart throttle, and a restarted watcher's start.
SWEEP_GAP_BOUND=15

# Emit event <n> and require sweeps to carry on after the close it causes.
emit_and_expect_sweeps() {  # <home> <n> <label>
  local home=$1 n=$2 before
  before=$(sweep_count "$home")
  : > "$home/emit.$n"
  wait_until 200 event_consumed "$home" "$n" || fail "$3: event $n was never swept"
  wait_until 300 sweeps_reach "$home" $((before + 4)) \
    || fail "$3: check sweeps stopped after event $n (sweeps $(sweep_count "$home"), were $before): the cycle that closed on it was not restarted"
}

# The watcher processes running from <home>'s bin. A command substitution
# inside a watcher is a forked copy with the same command line, so a process
# whose parent is itself a watcher is not counted.
home_watchers() {  # <home>
  ps -A -o pid= -o ppid= -o command= 2>/dev/null | awk -v w="$1/bin/fm-watch.sh" '
    $3 ~ /(^|\/)bash$/ && $4 == w { ppid[$1] = $2; order[++n] = $1 }
    END { for (i = 1; i <= n; i++) if (!(ppid[order[i]] in ppid)) c++; print c + 0 }'
}


parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

spool_ends_with() {
  local spool=$1 prefix=$2
  [ "$(tail -n 1 "$spool" 2>/dev/null | cut -f1)" = "$prefix" ]
}

