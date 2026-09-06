#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch is the only control verb that changes durable records, so these
# tests pin the transaction itself, hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
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
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

make_herdr_stub() {  # <dir>
  local fb="$1/fakebin"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":19},"server":{"running":true}}'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s"}}}\n' "$(cat "$D/cwd")"
    ;;
  "agent get")
    if [ -e "$D/launch-entered" ]; then
      printf '%s\n' '{"result":{"agent":{"agent":"shell","agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  "pane send-text")
    printf '%s\n' "${4:-}" >> "$D/literal"
    : > "$D/launch-pending"
    ;;
  "pane send-keys")
    [ ! -e "$D/launch-pending" ] || : > "$D/launch-entered"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --help ] || printf '%s\n' 'Usage: pi'
SH
  chmod +x "$fb/pi"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# --- 1. same-harness relaunch -----------------------------------------------

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc launch
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  launch=$(grep '^env -u TRACEPARENT .*claude' "$dir/fake/literal") \
    || fail "disabled relaunch must clear the pane carrier in the replacement process environment"
  ! grep -q '^export TRACEPARENT=' "$dir/fake/literal" \
    || fail "disabled relaunch must not export a replacement trace carrier"
  if command -v fish >/dev/null 2>&1; then
    cat > "$dir/fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TRACEPARENT-unset}" > "$FM_FAKE_DIR/fish-traceparent"
SH
    chmod +x "$dir/fakebin/claude"
    PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" TRACEPARENT=stale \
      fish -c "$launch" >/dev/null 2>&1 \
      || fail "Fish rejected the trace-disabled replacement launch"
    [ "$(cat "$dir/fake/fish-traceparent")" = unset ] \
      || fail "the replacement process inherited TRACEPARENT under Fish"
  elif [ "${FM_TEST_REQUIRE_FISH:-0}" = 1 ]; then
    fail "Fish is required for the trace-disabled replacement launch regression"
  fi
  pass "fm-control relaunch: disabling tracing clears metadata and replacement process context"
}

test_herdr_pi_relaunch_rejects_a_surviving_shell() {
  local dir out rc meta
  dir=$(new_case herdr-pi-shell rl42)
  add_ship_task "$dir" rl42 pi
  make_herdr_stub "$dir"
  meta="$dir/home/state/rl42.meta"
  sed -i.bak 's|^window=.*|window=fake:w1:p1|' "$meta"
  rm -f "$meta.bak"
  {
    printf '%s\n' 'backend=herdr'
    printf '%s\n' 'herdr_session=fake'
    printf '%s\n' 'herdr_workspace_id=w1'
    printf '%s\n' 'herdr_tab_id=w1:t1'
    printf '%s\n' 'herdr_pane_id=w1:p1'
  } >> "$meta"

  out=$(run_control "$dir" rl42 relaunch --note "retry the Pi worker") || rc=$?
  expect_code 1 "${rc:-0}" "a surviving Herdr shell must not prove the replacement Pi agent started"$'\n'"$out"
  assert_contains "$out" "replacement Pi agent" \
    "the refusal should name the selected agent that never started"
  assert_contains "$out" "Herdr reports 'shell'" \
    "the refusal should identify the surviving shell that failed launch verification"
  pass "fm-control relaunch: Herdr rejects a surviving shell when the selected Pi agent never starts"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  pass "fm-control relaunch: the progress note lands in the instructions the replacement reads"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "encode launch-brief" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  rmdir "$dir/smhome/state/bad.meta"
  cat > "$dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "failed child-state traversal should refuse"
  assert_contains "$out" "child records cannot be traversed" \
    "the refusal should preserve a find traversal failure"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child traversal failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable and untraversable child state fails checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the lifecycle lock"
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the promotion lifecycle lock"
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding the work"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_herdr_pi_relaunch_rejects_a_surviving_shell
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
