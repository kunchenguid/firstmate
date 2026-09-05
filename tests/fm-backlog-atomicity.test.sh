#!/usr/bin/env bash
# Behavior tests for the backlog<->record pairing invariant:
# `state/<id>.meta` exists <=> this home's backlog row for that id is In flight.
#
# bin/fm-backlog-transition-lib.sh states the contract; the three scripts that
# own a task's physical record enforce it. These tests drive those real scripts
# against a real backlog file and the real tasks-axi CLI, and assert the
# resulting RECORD STATE - never the wording of a reminder a later turn was
# expected to act on, which is exactly what let the two records drift before.
#
#   dispatch    bin/fm-spawn.sh moves the row In flight in the same run that
#               publishes the record, so a live worker the backlog does not own
#               cannot arise on the ordinary path.
#   completion  bin/fm-teardown.sh closes the row before it reports success, so
#               a finished task cannot be left showing as running.
#   recovery    bin/fm-bootstrap.sh reconciles THIS home's own books at session
#               start, covering the millisecond crash window inside those two
#               scripts and any drift a home was already carrying.
#
# The invariant is single-host: a home's backlog and its records live together,
# so a persistent secondmate keeps its own books through its own copies of these
# scripts. A parent's view of a mate lagging is a freshness question and is
# deliberately not asserted here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture
# in fm_tasks_axi_backend, so the backend cases must start from a clean slate.
unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-atomicity)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the fused transitions are inert without it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

# A home with a real backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to.
make_home() {  # <name> [task-id...]
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise backlog dispatch for $id.

## Firstmate spec
Verify the atomic backlog transition.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  done

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  # A secondmate-shaped home refuses to spawn unless treehouse advertises the
  # --root option that scopes its pool, so model the pinned build here.
  fm_fake_treehouse "$fakebin"

  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }
backlog_of() { printf '%s/home/data/backlog.md\n' "$1"; }

add_item() {  # <case-dir> <id> [kind]
  tasks-axi add "$2" "item for $2" --kind "${3:-ship}" --file "$(backlog_of "$1")" >/dev/null
}

start_item() {  # <case-dir> <id>
  tasks-axi start "$2" --file "$(backlog_of "$1")" >/dev/null
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$(backlog_of "$1")" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi with a wrapper that fails one verb and delegates every other
# verb to the real binary, so a test can drive a genuine mid-transition failure
# without faking the reads around it.
require_show_cwd() {  # <case-dir> <expected-dir>
  local case_dir=$1 expected=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  show|start|done)
    if [ "\$PWD" != "$expected" ]; then
      echo "error: wrong tasks root: \$PWD" >&2
      exit 1
    fi
    ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

record_tasks_axi_calls() {  # <case-dir>
  local case_dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

make_beads_tasks_axi_stub() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
case "\${1:-}" in
  --version)
    printf '%s\n' '0.2.5'
    ;;
  update)
    [ "\${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "\${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  show)
    [ "\${2:-}" = "$id" ] || exit 1
    if [ "\${3:-}" = --file ]; then
      printf '%s\n' 'error: beads show failed' >&2
      printf '%s\n' 'code: UNKNOWN' >&2
      exit 1
    fi
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$id"
    printf '%s\n' '  state: in_flight' '  held: no' '  blocked: no'
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

make_tasks_axi_incompatible() {  # <case-dir>
  local case_dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != --version ] || exit 1
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

break_verb() {  # <case-dir> <verb>
  local case_dir=$1 verb=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$verb" ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

interrupt_spawn_during_start() {  # <case-dir> <before|after>
  local case_dir=$1 timing=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ] && [ ! -f "$case_dir/start-interrupted" ]; then
  : > "$case_dir/start-interrupted"
  spawn_pid=\$(ps -o ppid= -p "\$PPID" | tr -d ' ')
  case "\$spawn_pid" in ''|*[!0-9]*) exit 1 ;; esac
  if [ "$timing" = before ]; then
    kill -TERM "\$spawn_pid"
    kill -TERM "\$\$"
  fi
  "$real" "\$@" || exit \$?
  if [ "$timing" = after ]; then
    kill -TERM "\$spawn_pid"
    kill -TERM "\$\$"
  fi
  exit 0
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

change_row_on_second_show() {  # <case-dir> <done|rm>
  local case_dir=$1 action=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then
  count=0
  [ ! -f "$case_dir/show-count" ] || count=\$(cat "$case_dir/show-count")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "$case_dir/show-count"
  if [ "\$count" -eq 2 ]; then
    "$real" "$action" "\$2" --file "\$4" >/dev/null || exit 1
  fi
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

break_launch_delivery() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

track_teardown_resource_actions() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$case_dir/backend-resource-action"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
# Model the pinned build's global options: a home that owns its own Treehouse
# pool needs --root, and a stub that advertises nothing reads as too old.
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '      --root string   Worktree root directory'
  exit 0
fi
: > "$case_dir/local-copy-resource-action"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"
}

interrupt_teardown_during_treehouse_return() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
# Model the pinned build's global options: a home that owns its own Treehouse
# pool needs --root, and a stub that advertises nothing reads as too old.
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '      --root string   Worktree root directory'
  exit 0
fi
if [ "\${1:-}" = return ] && [ ! -f "$case_dir/teardown-interrupted" ]; then
  : > "$case_dir/teardown-interrupted"
  teardown_pid=\$(ps -o ppid= -p "\$PPID" | tr -d ' ')
  case "\$teardown_pid" in ''|*[!0-9]*) exit 1 ;; esac
  kill -TERM "\$teardown_pid"
  kill -TERM "\$\$"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

interrupt_kimi_readiness() {  # <case-dir>
  local case_dir=$1 home
  home=$(home_of "$case_dir")
  mkdir -p "$home/.kimi-code"
  printf '# test config\n' > "$home/.kimi-code/config.toml"
  fm_fake_exit0 "$case_dir/fakebin" kimi
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\\n'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  capture-pane)
    if [ ! -f "$case_dir/kimi-interrupted" ]; then
      : > "$case_dir/kimi-interrupted"
      spawn_pid=\$(ps -o ppid= -p "\$PPID" | tr -d ' ')
      case "\$spawn_pid" in ''|*[!0-9]*) exit 1 ;; esac
      kill -TERM "\$spawn_pid"
    fi
    printf 'shell starting\\n$ \\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

break_meta_removal() {  # <case-dir> <meta-path>
  local case_dir=$1 meta=$2 real
  real=$(command -v rm)
  cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$meta" ] || exit 1
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

break_busy_removal() {  # <case-dir> <id>
  local case_dir=$1 id=$2 real state
  real=$(command -v rm)
  state="$(home_of "$case_dir")/state"
  cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$state/$id.busy-state"|"$state/$id.busy-gen") exit 1 ;;
  esac
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

remove_data_during_startup_budget_check() {  # <case-dir>
  local case_dir=$1 real data saved budget
  real=$(command -v stat)
  data="$(home_of "$case_dir")/data"
  saved="$case_dir/bootstrap-data"
  budget="$(home_of "$case_dir")/config/startup-memory-budget"
  printf '7500\n' > "$budget"
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$budget" ] && [ ! -e "$case_dir/data-removed" ]; then
    mv "$data" "$saved" || exit 1
    : > "$case_dir/data-removed"
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

break_meta_publication() {  # <case-dir> <meta-path>
  local case_dir=$1 meta=$2 real
  real=$(command -v mv)
  cat > "$case_dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$meta" ] || exit 1
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

write_task_meta() {  # <case-dir> <id> <kind> <mode> [extra-line...]
  local case_dir=$1 id=$2 kind=$3 mode=$4
  shift 4
  fm_write_meta "$(home_of "$case_dir")/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree" \
    "project=$case_dir/absent-project" \
    "harness=claude" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off" \
    "$@"
}

run_spawn() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  run_spawn "$case_dir" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Teardown against a recorded worktree that no longer exists: the landed-work and
# worktree-return steps are then no-ops, which keeps these cases about the
# backlog transition rather than re-testing tests/fm-teardown.test.sh's matrix.
run_teardown() {  # <case-dir> <id> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

run_bootstrap() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_BOOTSTRAP_NETWORK=skip \
    PATH="$case_dir/fakebin:$PATH" \
    "$BOOTSTRAP" 2>&1
}

# --- dispatch ---------------------------------------------------------------

test_dispatch_moves_the_item_in_flight_in_the_same_run() {
  local case_dir id out
  id=atomic-dispatch-b1
  case_dir=$(make_home dispatch-ok "$id")
  add_item "$case_dir" "$id"
  cp "$ROOT/.tasks.toml" "$(home_of "$case_dir")/.tasks.toml"
  record_tasks_axi_calls "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "spawn published no record"
  assert_grep "show $id --file $(backlog_of "$case_dir")" \
    "$case_dir/tasks-axi-calls" \
    "markdown dispatch did not pass the backlog file to show"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "spawn reported success with its backlog item still $(row_state "$case_dir" "$id")"
  pass "dispatch publishes the record and moves the backlog item In flight in one run"
}

test_dispatch_omits_the_file_for_a_beads_show() {
  local case_dir home id out
  id=atomic-dispatch-beads-b1
  case_dir=$(make_home dispatch-beads "$id")
  home=$(home_of "$case_dir")
  printf '%s\n' 'backend = "beads"' '[beads]' 'path = ".beads"' \
    'prefix = "atomic"' > "$home/.tasks.toml"
  make_beads_tasks_axi_stub "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "Beads spawn failed: $out"
  assert_contains "$out" "spawned $id" "Beads spawn did not report success"
  assert_grep "show $id" "$case_dir/tasks-axi-calls" \
    "Beads dispatch did not probe the backlog row"
  assert_no_grep "show $id --file" "$case_dir/tasks-axi-calls" \
    "Beads dispatch passed the markdown file to show"
  pass "dispatch omits the markdown file when probing a Beads backlog"
}

test_dispatch_refuses_a_pending_authoritative_close() {
  local case_dir id marker out rc=0
  id=atomic-dispatch-pending-close-b1
  case_dir=$(make_home dispatch-pending-close "$id")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-closing\narg=--pr\narg=https://github.com/example/repo/pull/12\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted work with an authoritative close still pending"
  assert_contains "$out" "pending authoritative backlog close" \
    "spawn did not explain why the pending close blocks dispatch"
  assert_present "$marker" "spawn discarded the pending authoritative close"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn published a new worker over a pending close"
  assert_absent "$case_dir/task-endpoint-created" \
    "spawn created an unowned endpoint before refusing the pending close"
  assert_absent "$case_dir/local-copy-requested" \
    "spawn requested an unowned local copy before refusing the pending close"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "refused dispatch changed the pending close's backlog row"
  pass "dispatch refuses to supersede a pending authoritative close"
}

test_dispatch_refuses_a_held_row_before_creating_resources() {
  local case_dir id out rc=0
  id=atomic-dispatch-held-b1
  case_dir=$(make_home dispatch-held "$id")
  add_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a held backlog row"
  assert_contains "$out" "state queued yes" \
    "held-row refusal did not name the actual ineligible state"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "held-row refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" \
    "held-row refusal created an unowned endpoint"
  assert_absent "$case_dir/local-copy-requested" \
    "held-row refusal requested an unowned local copy"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "held-row refusal changed the backlog state"
  pass "dispatch refuses held rows before creating resources"
}

test_dispatch_refuses_a_blocked_row_before_creating_resources() {
  local case_dir id blocker out rc=0
  id=atomic-dispatch-blocked-b16
  blocker=atomic-dispatch-blocker-b16
  case_dir=$(make_home dispatch-blocked "$id" "$blocker")
  add_item "$case_dir" "$blocker"
  tasks-axi add "$id" "item for $id" --kind ship --blocked-by "$blocker" \
    --file "$(backlog_of "$case_dir")" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a dependency-blocked backlog row"
  assert_contains "$out" "state queued no yes" \
    "blocked-row refusal did not name the actual ineligible state"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "blocked-row refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" \
    "blocked-row refusal created an unowned endpoint"
  assert_absent "$case_dir/local-copy-requested" \
    "blocked-row refusal requested an unowned local copy"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "blocked-row refusal changed the backlog state"
  pass "dispatch refuses dependency-blocked rows before creating resources"
}

test_dispatch_refuses_a_held_in_flight_row_before_relaunch() {
  local case_dir id out rc=0
  id=atomic-dispatch-held-in-flight-b16
  case_dir=$(make_home dispatch-held-in-flight "$id")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a held In-flight backlog row"
  assert_contains "$out" "state in_flight yes no" \
    "held In-flight refusal did not name the actual ineligible state"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "held In-flight refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" \
    "held In-flight refusal created a replacement endpoint"
  assert_absent "$case_dir/local-copy-requested" \
    "held In-flight refusal requested a replacement local copy"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "held In-flight refusal changed the backlog state"
  pass "dispatch refuses held In-flight rows before relaunch"
}

test_dispatch_reads_the_row_from_the_backlog_root() {
  local case_dir id out
  id=atomic-dispatch-root-b2
  case_dir=$(make_home dispatch-root "$id")
  add_item "$case_dir" "$id"
  require_show_cwd "$case_dir" "$(cd "$(home_of "$case_dir")" && pwd -P)"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn read outside the backlog root: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "root-addressed dispatch left the backlog row queued"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "root-addressed dispatch did not publish its task record"
  pass "dispatch reads backlog rows from the backlog addressing root"
}

test_recovery_uses_the_parent_of_a_trailing_slash_data_record() {
  local case_dir id relocated backlog marker out
  id=atomic-recovery-relocated-root-b2
  case_dir=$(make_home recovery-relocated-root)
  relocated="$case_dir/fm-records"
  mkdir -p "$relocated"
  backlog="$relocated/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$backlog"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog" >/dev/null
  tasks-axi start "$id" --file "$backlog" >/dev/null
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s/\nspawn_gen=spawn-relocated-recovery\narg=--note\narg=local%%20main\n' "$id" "$relocated" > "$marker"
  require_show_cwd "$case_dir" "$(cd "$case_dir" && pwd -P)"

  out=$(FM_DATA_OVERRIDE="$relocated/" run_bootstrap "$case_dir")
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "relocated-data recovery used the wrong addressing root: $out"
  assert_absent "$marker" "relocated-data recovery retained its close marker"
  pass "recovery uses the parent of a trailing-slash data record"
}

test_completion_targets_a_nested_relative_data_directory() {
  local case_dir id relative_data data data_resolved backlog out
  id=atomic-close-relative-data-b2
  case_dir=$(make_home close-relative-data)
  relative_data=relocated/data
  data="$case_dir/$relative_data"
  mkdir -p "$case_dir/relocated"
  mv "$(home_of "$case_dir")/data" "$data"
  data_resolved=$(cd "$data" && pwd -P)
  backlog="$data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog" >/dev/null
  tasks-axi start "$id" --file "$backlog" >/dev/null
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-relative-data"

  out=$(cd "$case_dir" && \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_DATA_OVERRIDE="$relative_data" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" 2>&1) \
    || fail "relative-data teardown failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "relative-data teardown mutated a different backlog file"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "relative-data teardown retained its task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "relative-data teardown retained its close marker"
  assert_contains "$out" "closed in $data_resolved/backlog.md" \
    "relative-data completion collapsed the configured backlog path"
  pass "completion targets nested relative data from the caller directory"
}

test_immediate_child_absolute_data_dispatches_and_completes() {
  local case_dir id data data_resolved backlog out
  id=atomic-immediate-child-data-b2
  case_dir=$(make_home immediate-child-data "$id")
  data="$case_dir/fm-records"
  mv "$(home_of "$case_dir")/data" "$data"
  data_resolved=$(cd "$data" && pwd -P)
  backlog="$data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog" >/dev/null

  out=$(FM_DATA_OVERRIDE="$data" run_ship_spawn "$case_dir" "$id") \
    || fail "immediate-child-data spawn failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "immediate-child absolute dispatch mutated a different backlog"
  rm -f "$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-immediate-child"
  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") \
    || fail "immediate-child-data teardown failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "immediate-child absolute completion mutated a different backlog"
  assert_contains "$out" "closed in $data_resolved/backlog.md" \
    "relocated completion confirmed the wrong backlog path"
  pass "an immediate-child absolute data path keeps one paired backlog"
}

test_bare_relative_data_dispatches_and_completes() {
  local case_dir id data backlog out
  id=atomic-bare-relative-data-b2
  case_dir=$(make_home bare-relative-data "$id")
  data="$case_dir/records"
  mv "$(home_of "$case_dir")/data" "$data"
  backlog="$data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog" >/dev/null

  out=$(cd "$case_dir" && FM_DATA_OVERRIDE=records run_ship_spawn "$case_dir" "$id") \
    || fail "bare-relative-data spawn failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "bare relative dispatch mutated a different backlog"
  rm -f "$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-bare-relative"
  out=$(cd "$case_dir" && FM_DATA_OVERRIDE=records run_teardown "$case_dir" "$id") \
    || fail "bare-relative-data teardown failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "bare relative completion mutated a different backlog"
  pass "bare relative data addresses one backlog through dispatch and completion"
}

test_dispatch_refuses_a_symlinked_backlog_without_crossing_homes() {
  local case_dir foreign_case id local_backlog foreign_backlog out rc=0
  id=atomic-dispatch-symlink-backlog-b2
  case_dir=$(make_home dispatch-symlink-backlog "$id")
  foreign_case=$(make_home dispatch-symlink-backlog-foreign)
  add_item "$foreign_case" "$id"
  local_backlog=$(backlog_of "$case_dir")
  foreign_backlog=$(backlog_of "$foreign_case")
  rm -f "$local_backlog"
  ln -s "$foreign_backlog" "$local_backlog"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a symlinked backlog"
  assert_contains "$out" "backlog file resolves outside its authorized directory" \
    "spawn did not identify the unsafe backlog boundary"
  [ -L "$local_backlog" ] || fail "spawn replaced the local backlog symlink"
  [ "$(row_state "$foreign_case" "$id")" = queued ] \
    || fail "spawn mutated the foreign backlog row"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "unsafe backlog dispatch published a local task record"
  pass "dispatch refuses symlinked backlogs without crossing homes"
}

test_automatic_backend_refuses_incompatible_tasks_axi_before_mutation() {
  local spawn_case teardown_case id out rc=0
  id=atomic-incompatible-tasks-axi-b2
  spawn_case=$(make_home incompatible-tasks-axi-spawn "$id")
  add_item "$spawn_case" "$id"
  make_tasks_axi_incompatible "$spawn_case"

  out=$(run_ship_spawn "$spawn_case" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "automatic spawn succeeded without compatible tasks-axi"
  assert_contains "$out" "automatic backlog transitions require tasks-axi" \
    "automatic spawn did not report its unavailable transition tool"
  assert_absent "$(home_of "$spawn_case")/state/$id.meta" \
    "automatic spawn published a record without transition tooling"
  rm -f "$spawn_case/fakebin/tasks-axi"
  [ "$(row_state "$spawn_case" "$id")" = queued ] \
    || fail "automatic spawn changed the row without transition tooling"

  teardown_case=$(make_home incompatible-tasks-axi-teardown)
  add_item "$teardown_case" "$id"
  start_item "$teardown_case" "$id"
  write_task_meta "$teardown_case" "$id" ship local-only "spawn_gen=spawn-incompatible"
  make_tasks_axi_incompatible "$teardown_case"
  rc=0
  out=$(run_teardown "$teardown_case" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "automatic teardown succeeded without compatible tasks-axi"
  assert_contains "$out" "automatic backlog transitions require tasks-axi" \
    "automatic teardown did not report its unavailable transition tool"
  assert_present "$(home_of "$teardown_case")/state/$id.meta" \
    "automatic teardown removed its record without transition tooling"
  rm -f "$teardown_case/fakebin/tasks-axi"
  [ "$(row_state "$teardown_case" "$id")" = in_flight ] \
    || fail "automatic teardown changed the row without transition tooling"
  pass "automatic homes refuse lifecycle mutation without compatible tasks-axi"
}

test_dispatch_refuses_an_unresolvable_data_directory() {
  local case_dir id saved out rc=0
  id=atomic-dispatch-missing-data-b2
  case_dir=$(make_home dispatch-missing-data "$id")
  add_item "$case_dir" "$id"
  saved="$case_dir/backlog-data"
  mv "$(home_of "$case_dir")/data" "$saved"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded with an unresolvable data directory"
  assert_contains "$out" "task $id" \
    "spawn did not identify the task blocked by fatal backlog addressing"
  assert_contains "$out" "$(home_of "$case_dir")/data" \
    "spawn did not identify the inaccessible data directory"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "fatal backlog addressing created a task record"
  [ "$(tasks-axi show "$id" --file "$saved/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "fatal backlog addressing changed the queued row"
  pass "dispatch refuses an unresolvable backlog data directory"
}

test_completion_refuses_an_unresolvable_data_directory() {
  local case_dir id saved meta out rc=0
  id=atomic-close-missing-data-b2
  case_dir=$(make_home close-missing-data)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-missing-data"
  meta="$(home_of "$case_dir")/state/$id.meta"
  saved="$case_dir/backlog-data"
  mv "$(home_of "$case_dir")/data" "$saved"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown succeeded with an unresolvable data directory"
  assert_contains "$out" "task $id cannot be torn down" \
    "teardown did not identify the task blocked by fatal backlog addressing"
  assert_present "$meta" "fatal backlog addressing removed the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "fatal backlog addressing wrote a close marker"
  [ "$(tasks-axi show "$id" --file "$saved/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "fatal backlog addressing changed the In-flight row"
  pass "completion refuses before mutation when backlog data is unresolvable"
}

test_dispatch_refuses_an_id_this_home_has_no_item_for() {
  local case_dir id out rc=0
  id=atomic-dispatch-b2
  case_dir=$(make_home dispatch-no-item "$id")

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched work no backlog item owns"
  assert_contains "$out" "no backlog item in this home" \
    "spawn refused without naming the missing backlog item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch still left a record behind"
  pass "dispatch refuses, before creating anything, when the home has no item for the id"
}

test_dispatch_reports_a_backlog_read_failure() {
  local case_dir id out rc=0
  id=atomic-dispatch-read-failure-b3
  case_dir=$(make_home dispatch-read-failure "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" show

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded though backlog preflight could not read its item"
  assert_contains "$out" "backlog item could not be read before dispatch" \
    "spawn misreported a backlog read failure"
  assert_contains "$out" "backlog is unwritable" \
    "spawn discarded the backlog reader's diagnostic"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "failed backlog preflight created a task record"
  pass "dispatch distinguishes backlog read failures from missing items"
}

test_dispatch_refuses_a_closed_item() {
  local case_dir id out rc=0
  id=atomic-dispatch-b3
  case_dir=$(make_home dispatch-closed "$id")
  add_item "$case_dir" "$id"
  tasks-axi "done" "$id" --file "$(backlog_of "$case_dir")" >/dev/null

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched onto an item the backlog already closed"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "refused dispatch silently reopened a closed item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch onto a closed item still left a record behind"
  pass "dispatch refuses a closed item instead of silently reopening it"
}

test_dispatch_refuses_to_commit_without_a_published_record() {
  local case_dir id meta out rc=0
  id=atomic-dispatch-publish-failure-b4
  case_dir=$(make_home dispatch-publish-failure "$id")
  add_item "$case_dir" "$id"
  meta="$(home_of "$case_dir")/state/$id.meta"
  break_meta_publication "$case_dir" "$meta"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded without publishing its task record"
  assert_contains "$out" "task record for $id could not be published" \
    "spawn did not report task-record publication failure"
  assert_absent "$meta" "failed publication left a task record"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "failed publication retained its busy state"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "failed publication moved the backlog row"
  pass "dispatch cannot commit without a verified task-record publication"
}

test_dispatch_leaves_no_record_when_the_transition_fails() {
  local case_dir id out rc=0
  id=atomic-dispatch-b4
  case_dir=$(make_home dispatch-transition-fails "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" start

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though the backlog transition failed"
  assert_contains "$out" "could not be moved to In flight" \
    "spawn failed without explaining the backlog transition failure"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed backlog transition left an orphaned record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed backlog transition left the task's armed busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "a failed dispatch left the backlog item in $(row_state "$case_dir" "$id")"
  pass "a failed backlog transition fails the dispatch loudly and leaves no record"
}

test_dispatch_reports_an_incomplete_record_rollback() {
  local case_dir id meta out rc=0
  id=atomic-dispatch-remove-failure-b5
  case_dir=$(make_home dispatch-remove-failure "$id")
  add_item "$case_dir" "$id"
  meta="$(home_of "$case_dir")/state/$id.meta"
  break_verb "$case_dir" start
  break_meta_removal "$case_dir" "$meta"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though transition and rollback failed"
  assert_contains "$out" "failed-dispatch cleanup is incomplete" \
    "spawn did not report that its provisional record remained"
  assert_present "$meta" "failed record removal was reported as successful"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "record-removal failure prevented busy-state rollback"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "failed rollback changed the backlog row"
  pass "dispatch reports when failed-transition rollback cannot remove its record"
}

test_dispatch_reports_an_incomplete_busy_rollback() {
  local case_dir id out rc=0
  id=atomic-dispatch-busy-remove-failure-b5
  case_dir=$(make_home dispatch-busy-remove-failure "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" start
  break_busy_removal "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded though busy rollback failed"
  assert_contains "$out" "did not remove both task and busy records" \
    "spawn did not report incomplete busy rollback"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "busy rollback failure retained the provisional task record"
  assert_present "$(home_of "$case_dir")/state/$id.busy-state" \
    "busy removal failure was reported as successful"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "failed busy rollback changed the backlog row"
  pass "dispatch verifies both task and busy records during rollback"
}

test_dispatch_rolls_back_before_a_failed_launch_delivery() {
  local case_dir id out rc=0
  id=atomic-dispatch-delivery-fails-b5
  case_dir=$(make_home dispatch-delivery-fails "$id")
  add_item "$case_dir" "$id"
  break_launch_delivery "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though launch delivery failed"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed launch delivery left its provisional record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed launch delivery left its provisional busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "launch delivery failed after committing backlog state $(row_state "$case_dir" "$id")"
  pass "dispatch commits neither record nor backlog state before launch delivery succeeds"
}

test_dispatch_defers_interruption_across_backlog_commit() {
  local timing case_dir id out rc
  for timing in before after; do
    id="atomic-dispatch-interrupted-$timing-b5"
    case_dir=$(make_home "dispatch-interrupted-$timing" "$id")
    add_item "$case_dir" "$id"
    interrupt_spawn_during_start "$case_dir" "$timing"

    rc=0
    out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
    [ "$rc" -ne 0 ] || fail "a $timing-commit interruption was reported as success"
    assert_contains "$out" "paired task record and In-flight backlog state were preserved" \
      "a $timing-commit interruption did not report its atomic outcome"
    [ "$(row_state "$case_dir" "$id")" = in_flight ] \
      || fail "a $timing-commit interruption left the backlog row queued"
    assert_present "$(home_of "$case_dir")/state/$id.meta" \
      "a $timing-commit interruption removed the paired task record"
  done
  pass "dispatch retries interrupted transitions before honoring termination"
}

test_dispatch_interruption_during_kimi_readiness_fails_before_commit() {
  local case_dir home id out rc=0
  id=atomic-dispatch-kimi-readiness-signal-b5
  case_dir=$(make_home dispatch-kimi-readiness-signal "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  interrupt_kimi_readiness "$case_dir"

  out=$(HOME="$home" FM_KIMI_READY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    run_spawn "$case_dir" "$id" "$case_dir/project" --harness kimi \
      --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi readiness interruption was reported as success"
  assert_absent "$home/state/$id.meta" \
    "Kimi readiness interruption retained an unconfirmed task record"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "Kimi readiness interruption committed unconfirmed work In flight: $out"
  pass "Kimi readiness interruptions fail before backlog commit"
}

test_dispatch_does_not_resurrect_a_row_closed_after_preflight() {
  local case_dir id out rc=0
  id=atomic-dispatch-closed-race-b5
  case_dir=$(make_home dispatch-closed-race "$id")
  add_item "$case_dir" "$id"
  change_row_on_second_show "$case_dir" "done"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded after its backlog row was closed"
  assert_contains "$out" "state done" "spawn did not report the row's ineligible state"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "spawn resurrected a row closed after preflight"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn retained a record after its row was closed"
  pass "dispatch does not resurrect a row closed after preflight"
}

test_dispatch_fails_when_its_row_vanishes_after_preflight() {
  local case_dir id out rc=0
  id=atomic-dispatch-removed-race-b6
  case_dir=$(make_home dispatch-removed-race "$id")
  add_item "$case_dir" "$id"
  change_row_on_second_show "$case_dir" rm

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded after its backlog row vanished"
  assert_contains "$out" "vanished before dispatch commit" \
    "spawn did not report that its backlog row vanished"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn retained a record after its backlog row vanished"
  [ -z "$(row_state "$case_dir" "$id")" ] || fail "spawn recreated a removed backlog row"
  pass "dispatch fails when its backlog row vanishes after preflight"
}

# --- completion -------------------------------------------------------------

test_completion_closes_a_local_only_ship_before_reporting_success() {
  local case_dir id out
  id=atomic-close-b5
  case_dir=$(make_home close-local-only)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-close-local"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the item still $(row_state "$case_dir" "$id")"
  assert_grep 'local main' "$(backlog_of "$case_dir")" \
    "a local-only landing was closed without its local-main note"
  pass "completion closes a local-only ship, with its landing note, before reporting success"
}

test_completion_closes_a_scout_with_its_report() {
  local case_dir id out
  id=atomic-close-b6
  case_dir=$(make_home close-scout)
  add_item "$case_dir" "$id" scout
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" scout '' "spawn_gen=spawn-close-scout"
  # A scout's deliverable is its report, and teardown also enforces the shared
  # captain-call completion gate; satisfy both the way a real scout does.
  mkdir -p "$(home_of "$case_dir")/data/$id"
  printf 'findings\n' > "$(home_of "$case_dir")/data/$id/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the scout's completed captain-call inventory"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the scout item still $(row_state "$case_dir" "$id")"
  assert_grep "data/$id/report.md" "$(backlog_of "$case_dir")" \
    "a closed scout item did not record its report"
  pass "completion closes a scout item against its report"
}

test_completion_refuses_a_legacy_record_without_an_incarnation() {
  local case_dir id meta out rc=0
  id=atomic-close-legacy-no-incarnation-b7
  case_dir=$(make_home close-legacy-no-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only
  meta="$(home_of "$case_dir")/state/$id.meta"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted a record with no durable incarnation"
  assert_contains "$out" "record has no spawn_gen" \
    "teardown did not explain why the legacy record cannot close automatically"
  assert_present "$meta" "legacy-record refusal removed the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "legacy-record refusal wrote an unrecoverable close marker"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "legacy-record refusal changed the backlog row"
  pass "completion leaves legacy records open when no incarnation can be recorded"
}

test_completion_refuses_ambiguous_incarnation_metadata() {
  local case_dir id meta marker out rc=0
  id=atomic-close-ambiguous-incarnation-b7
  case_dir=$(make_home close-ambiguous-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only \
    "spawn_gen=spawn-old" "spawn_gen=spawn-current"
  meta="$(home_of "$case_dir")/state/$id.meta"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted ambiguous incarnation metadata"
  assert_contains "$out" "has 2 spawn generation fields" \
    "teardown did not report the ambiguous incarnation"
  assert_present "$meta" "ambiguous-incarnation refusal removed the task record"
  assert_absent "$marker" "ambiguous-incarnation refusal published a close"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "ambiguous-incarnation refusal changed the backlog row"
  pass "completion refuses ambiguous task incarnations"
}

test_completion_records_a_relative_report_for_relocated_data() {
  local case_dir id relocated backlog out
  id=atomic-close-relocated-scout-b7
  case_dir=$(make_home close-relocated-scout)
  relocated="$case_dir/relocated/data"
  mkdir -p "$case_dir/relocated"
  mv "$(home_of "$case_dir")/data" "$relocated"
  backlog="$relocated/backlog.md"
  tasks-axi add "$id" "item for $id" --kind scout --file "$backlog" >/dev/null
  tasks-axi start "$id" --file "$backlog" >/dev/null
  write_task_meta "$case_dir" "$id" scout '' "spawn_gen=spawn-relocated-scout"
  mkdir -p "$relocated/$id"
  printf 'findings\n' > "$relocated/$id/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_DATA_OVERRIDE="$relocated////" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the relocated scout's captain-call inventory"

  out=$(FM_DATA_OVERRIDE="$relocated////" run_teardown "$case_dir" "$id") \
    || fail "relocated scout teardown failed: $out"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "relocated scout backlog row was not closed"
  assert_grep "data/$id/report.md" "$backlog" \
    "relocated scout close did not record a relative report path"
  pass "completion records relocated scout reports relative to the backlog root"
}

test_space_containing_scout_report_marker_replays() {
  local case_dir id data backlog marker out rc=0
  id=atomic-space-report-replay-b7
  case_dir=$(make_home space-report-replay)
  data="$case_dir/crew space/data"
  mkdir -p "$case_dir/crew space"
  mv "$(home_of "$case_dir")/data" "$data"
  backlog="$data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind scout --file "$backlog" >/dev/null
  tasks-axi start "$id" --file "$backlog" >/dev/null
  write_task_meta "$case_dir" "$id" scout '' "spawn_gen=spawn-space-report"
  mkdir -p "$data/$id"
  printf 'findings\n' > "$data/$id/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_DATA_OVERRIDE="$data" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the space-path scout's captain-call inventory"
  break_verb "$case_dir" "done"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "space-path scout teardown unexpectedly completed"
  assert_present "$marker" "space-path scout teardown recorded no pending close"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "space-path scout teardown retained meta after recording its close"
  rm -f "$case_dir/fakebin/tasks-axi"

  out=$(FM_DATA_OVERRIDE="$data" run_bootstrap "$case_dir")
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = "done" ] \
    || fail "space-containing report marker did not replay: $out"
  assert_grep "data/$id/report.md" "$backlog" \
    "report path from a space-containing data directory was lost during replay"
  assert_absent "$marker" "space-containing report marker remained after replay"
  pass "space-containing scout report paths round-trip through recovery"
}

test_trailing_newline_data_path_fails_closed() {
  local case_dir home id data backlog_alias out rc=0
  id=atomic-newline-data-refusal-c8
  case_dir=$(make_home newline-data-refusal "$id")
  home=$(home_of "$case_dir")
  data="$home/data"$'\n'
  mv "$home/data" "$data"
  mkdir -p "$home/data/$id"
  cp "$data/$id/brief.md" "$home/data/$id/brief.md"
  ln -s "$data" "$case_dir/data-alias"
  backlog_alias="$case_dir/data-alias/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog_alias" >/dev/null

  out=$(FM_DATA_OVERRIDE="$data" run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "trailing-newline data path bypassed dispatch transition"
  assert_absent "$home/state/$id.meta" \
    "trailing-newline dispatch published a task record"
  [ "$(tasks-axi show "$id" --file "$backlog_alias" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "trailing-newline dispatch changed the real backlog row: $out"

  tasks-axi start "$id" --file "$backlog_alias" >/dev/null
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-newline-data"
  rc=0
  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "trailing-newline data path bypassed completion transition"
  assert_present "$home/state/$id.meta" \
    "trailing-newline teardown removed the task record"
  assert_absent "$home/state/$id.backlog-close" \
    "trailing-newline teardown published a close marker"
  [ "$(tasks-axi show "$id" --file "$backlog_alias" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "trailing-newline teardown changed the real backlog row: $out"
  pass "control-byte data paths fail closed before paired transitions"
}

test_control_character_data_path_is_refused_before_cleanup() {
  local case_dir id data backlog marker out rc=0
  id=atomic-control-data-refusal-b7
  case_dir=$(make_home control-data-refusal "$id")
  data="$case_dir/crew"$'\t'"data"
  mv "$(home_of "$case_dir")/data" "$data"
  backlog="$data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$backlog" >/dev/null

  out=$(FM_DATA_OVERRIDE="$data" run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "control-character data path passed dispatch preflight"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "control-character dispatch published a task record"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "control-character dispatch changed the backlog row: $out"

  tasks-axi start "$id" --file "$backlog" >/dev/null
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-control-data"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  rc=0
  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "control-character data path passed close preflight"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "control-character close preflight removed the task record"
  assert_absent "$marker" "control-character close preflight published a marker"
  [ "$(tasks-axi show "$id" --file "$backlog" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "control-character close preflight changed the backlog row: $out"
  pass "unreplayable data paths are refused before destructive cleanup"
}

test_completion_preserves_records_when_meta_removal_fails() {
  local case_dir id meta marker out rc=0
  id=atomic-close-meta-remove-failure-b7
  case_dir=$(make_home close-meta-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-one"
  meta="$(home_of "$case_dir")/state/$id.meta"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  break_meta_removal "$case_dir" "$meta"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown succeeded though task-record removal failed"
  assert_contains "$out" "task record could not be removed" \
    "teardown did not report task-record removal failure"
  assert_present "$meta" "teardown lost meta after its removal failed"
  assert_present "$marker" "teardown discarded recovery after meta removal failed"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "teardown closed the row before verifying meta removal"
  pass "completion preserves recovery state when task-record removal fails"
}

test_completion_fails_loudly_and_records_the_close_it_still_owes() {
  local case_dir id out rc=0
  id=atomic-close-b7
  case_dir=$(make_home close-fails)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-close-fails"
  break_verb "$case_dir" "done"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown reported success while its item was still In flight"
  assert_contains "$out" "could not be closed" \
    "teardown failed without explaining the unclosed backlog item"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "teardown lost the close it still owes"
  pass "completion refuses to report success while its item is still open, and records what it owes"
}

test_interrupted_destructive_cleanup_leaves_a_recoverable_close() {
  local case_dir home id marker out rc=0
  id=atomic-close-destructive-interrupt-b8
  case_dir=$(make_home close-destructive-interrupt "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  marker="$home/state/$id.backlog-close"
  interrupt_teardown_during_treehouse_return "$case_dir"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted destructive cleanup reported success"
  assert_present "$marker" \
    "destructive cleanup began before recording its authoritative close"
  assert_present "$home/state/$id.meta" \
    "interrupted destructive cleanup lost the task incarnation"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "interrupted cleanup changed the backlog before recovery"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "restart left interrupted cleanup In flight: $out"
  assert_absent "$marker" "restart retained the recovered close marker"
  assert_absent "$home/state/$id.meta" "restart retained the interrupted task record"
  assert_contains "$out" "endpoint or local copy may remain" \
    "restart silently hid potentially incomplete physical cleanup"
  pass "restart recovers closes recorded before destructive cleanup"
}

test_completion_refuses_a_close_target_symlinked_to_a_directory() {
  local case_dir home id marker external out rc=0
  id=atomic-close-target-directory-symlink-b8
  case_dir=$(make_home close-target-directory-symlink)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-target-symlink"
  marker="$home/state/$id.backlog-close"
  external="$case_dir/external-directory"
  mkdir -p "$external"
  ln -s "$external" "$marker"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown published through a directory symlink"
  assert_contains "$out" "pending-close record target resolves outside its authorized directory" \
    "teardown did not report the unsafe publication target"
  [ -L "$marker" ] || fail "teardown replaced the unsafe close target"
  [ -z "$(find "$external" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "teardown wrote a staged close outside the home"
  assert_present "$home/state/$id.meta" \
    "unsafe close publication removed the task record"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "unsafe close publication changed the backlog row"
  pass "completion refuses directory-symlink close targets"
}

test_completion_fails_when_its_close_marker_cannot_be_removed() {
  local case_dir id marker out rc=0
  id=atomic-close-marker-remove-failure-b8
  case_dir=$(make_home close-marker-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-marker-fails"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  break_meta_removal "$case_dir" "$marker"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown reported success while its close marker remained"
  assert_contains "$out" "pending-close record could not be removed" \
    "teardown did not report its incomplete marker cleanup"
  assert_present "$marker" "teardown hid a close-marker removal failure"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "marker cleanup failure lost the completed backlog transition"
  pass "completion reports failure until its durable close marker is removed"
}

# --- same-home recovery -----------------------------------------------------

test_recovery_retries_when_a_close_marker_cannot_be_removed() {
  local case_dir id marker out
  id=atomic-heal-marker-remove-failure-b8
  case_dir=$(make_home heal-marker-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-marker-retry\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"
  break_meta_removal "$case_dir" "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "pending-close record could not be removed" \
    "session start did not report close-marker removal failure"
  assert_present "$marker" "recovery hid a close-marker removal failure"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "recovery did not land the close before marker cleanup"

  rm -f "$case_dir/fakebin/rm"
  out=$(run_bootstrap "$case_dir")
  assert_absent "$marker" "recovery did not retry close-marker cleanup: $out"
  pass "session start retries a close whose marker could not be removed"
}

test_recovery_reports_an_owned_row_read_failure() {
  local case_dir id out
  id=atomic-heal-read-failure-b8
  case_dir=$(make_home heal-owned-read-failure)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes
  break_verb "$case_dir" show

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "worker record exists but its backlog item could not be read" \
    "session start silently ignored an owned-row read failure"
  assert_contains "$out" "backlog is unwritable" \
    "session start discarded the backlog reader's diagnostic"
  rm -f "$case_dir/fakebin/tasks-axi"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "owned-row read failure changed the backlog state"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "owned-row read failure removed the worker record"
  pass "session start reports owned backlog rows it cannot read"
}

test_orca_cleanup_recovery_never_transitions_the_backlog() {
  local case_dir id meta out
  id=atomic-orca-cleanup-recovery-b8
  case_dir=$(make_home orca-cleanup-recovery)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "cleanup_recovery=orca"
  meta="$(home_of "$case_dir")/state/$id.meta"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start treated cleanup recovery as a launched worker: $out"
  assert_present "$meta" "session start removed the cleanup recovery record"

  out=$(run_teardown "$case_dir" "$id") \
    || fail "cleanup recovery teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "cleanup recovery teardown completed work that never launched"
  assert_absent "$meta" "cleanup recovery teardown retained its task record"
  pass "Orca cleanup recovery is excluded from backlog lifecycle transitions"
}

test_recovery_marks_an_owned_record_in_flight() {
  local case_dir id out
  id=atomic-heal-b8
  case_dir=$(make_home heal-queued)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start left an owned record's item at $(row_state "$case_dir" "$id"): $out"
  pass "session start marks an item In flight when this home already owns a worker for it"
}

test_recovery_rejects_an_internal_worker_record_symlink() {
  local case_dir home id target_id out rc=0
  id=atomic-heal-internal-symlink-b8
  target_id=atomic-heal-internal-target-b8
  case_dir=$(make_home heal-internal-symlink)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$target_id" ship no-mistakes "spawn_gen=internal-target"
  ln -s "$target_id.meta" "$home/state/$id.meta"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "session start accepted an internal worker-record symlink"
  assert_contains "$out" "task record resolves through a different final path" \
    "session start did not report the aliased worker record"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start paired the aliased worker record with its backlog row"
  [ -L "$home/state/$id.meta" ] \
    || fail "session start replaced or removed the aliased worker record"
  assert_present "$home/state/$target_id.meta" \
    "session start removed the internal symlink target"
  pass "session start rejects internal worker-record symlinks"
}

test_recovery_ignores_a_symlinked_worker_record() {
  local case_dir home id target out rc=0
  id=atomic-heal-symlink-meta-b8
  case_dir=$(make_home heal-symlink-meta)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  target="$case_dir/symlink-meta-target"
  printf 'kind=ship\nspawn_gen=unpublished\n' > "$target"
  ln -s "$target" "$home/state/$id.meta"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "session start accepted a symlinked worker record"
  assert_contains "$out" "bootstrap refused unsafe worker record" \
    "session start did not report the unsafe worker record"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start treated a symlink as an owned worker record: $out"
  [ -L "$home/state/$id.meta" ] \
    || fail "session start replaced or removed the inert symlinked record"
  pass "session start rejects symlinked worker records"
}

test_recovery_replays_a_close_an_interrupted_cleanup_left_open() {
  local case_dir id out
  id=atomic-heal-b9
  case_dir=$(make_home heal-pending-close)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-heal-pr\narg=--pr\narg=https://github.com/example/repo/pull/11\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "session start left an interrupted cleanup's item at $(row_state "$case_dir" "$id"): $out"
  assert_grep 'https://github.com/example/repo/pull/11' "$(backlog_of "$case_dir")" \
    "the replayed close dropped the completion link the cleanup had recorded"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a replayed close left its record behind"
  assert_not_contains "$out" "endpoint or local copy may remain" \
    "recovery claimed incomplete cleanup without task metadata"
  pass "session start finishes a close an interrupted cleanup recorded but never landed"
}

test_recovery_backfills_a_recorded_link_on_an_already_done_item() {
  local case_dir id marker out
  id=atomic-heal-done-backfill-b9
  case_dir=$(make_home heal-done-backfill)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  tasks-axi "done" "$id" --file "$(backlog_of "$case_dir")" >/dev/null
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-heal-done\narg=--pr\narg=https://github.com/example/repo/pull/13\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "replaying a completion link changed the closed row: $out"
  assert_grep 'https://github.com/example/repo/pull/13' "$(backlog_of "$case_dir")" \
    "recovery discarded the recorded link because the item was already Done"
  assert_absent "$marker" "recovery retained an applied completion-link marker"
  pass "recovery backfills recorded links onto already Done items"
}

test_recovery_preserves_a_close_when_the_backlog_cannot_be_read() {
  local case_dir id out
  id=atomic-heal-read-error-b10
  case_dir=$(make_home heal-read-error)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-heal-read\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"
  break_verb "$case_dir" show

  out=$(run_bootstrap "$case_dir")
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a transient backlog read failure discarded the pending close"
  rm -f "$case_dir/fakebin/tasks-axi"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "a failed recovery changed the backlog row: $out"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "the preserved close was not retried after the read recovered: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a successfully retried close left its marker behind"
  pass "session start preserves a pending close across a transient backlog read failure"
}

test_recovery_retry_preserves_incomplete_cleanup_warning() {
  local case_dir home id marker out
  id=atomic-heal-retry-warning-b10
  case_dir=$(make_home heal-retry-warning)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-warning"
  marker="$home/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-warning\narg=--note\narg=local%%20main\n' \
    "$id" "$home/data" > "$marker"
  break_verb "$case_dir" show

  out=$(run_bootstrap "$case_dir")
  assert_absent "$home/state/$id.meta" \
    "failed replay did not cross the task-record removal boundary"
  assert_present "$marker" "failed replay discarded its pending close"
  rm -f "$case_dir/fakebin/tasks-axi"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "retried recovery left the item In flight: $out"
  assert_contains "$out" "endpoint or local copy may remain" \
    "retry lost the incomplete-cleanup evidence after removing metadata"
  assert_absent "$marker" "retried recovery retained its applied marker"
  pass "recovery preserves incomplete-cleanup evidence across a failed replay"
}

test_recovery_finishes_a_close_for_the_same_meta_incarnation() {
  local case_dir id out
  id=atomic-heal-same-incarnation-b11
  case_dir=$(make_home heal-same-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-one"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "session start did not close the interrupted incarnation: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "session start retained the interrupted incarnation's meta"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "session start retained the completed incarnation's close marker"
  pass "session start finishes a close for the matching meta incarnation"
}

test_recovery_preserves_a_close_for_ambiguous_incarnation_metadata() {
  local case_dir home id marker out
  id=atomic-heal-ambiguous-incarnation-b12
  case_dir=$(make_home heal-ambiguous-incarnation)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes \
    "spawn_gen=spawn-old" "spawn_gen=spawn-current"
  marker="$home/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-current\narg=--note\narg=local%%20main\n' \
    "$id" "$home/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "has 2 spawn generation fields" \
    "recovery did not report ambiguous incarnation metadata"
  assert_present "$marker" "ambiguous metadata caused recovery to discard the close"
  assert_present "$home/state/$id.meta" \
    "ambiguous metadata caused recovery to remove the task record"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "ambiguous metadata allowed recovery to close the backlog row"
  pass "recovery preserves closes for ambiguous task incarnations"
}

test_recovery_preserves_both_records_when_meta_removal_fails() {
  local case_dir id meta out
  id=atomic-heal-remove-failure-b12
  case_dir=$(make_home heal-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  meta="$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-one"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"
  break_meta_removal "$case_dir" "$meta"

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "the interrupted task record could not be removed" \
    "session start did not surface the record-removal failure"
  assert_present "$meta" "failed recovery removed the task record"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "failed recovery discarded the pending close"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "failed recovery closed the backlog before removing meta"

  rm -f "$case_dir/fakebin/rm"
  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "recovery did not retry after meta removal recovered: $out"
  assert_absent "$meta" "successful retry retained the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "successful retry retained the pending close"
  pass "recovery preserves both records when meta removal fails"
}

test_recovery_preserves_a_close_beside_symlinked_metadata() {
  local case_dir home id marker target out
  id=atomic-heal-symlink-meta-close-b12
  case_dir=$(make_home heal-symlink-meta-close)
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  target="$case_dir/foreign-meta-target"
  printf 'kind=ship\nspawn_gen=other-incarnation\n' > "$target"
  ln -s "$target" "$home/state/$id.meta"
  marker="$home/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=closing-incarnation\narg=--note\narg=local%%20main\n' \
    "$id" "$home/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "unsafe interrupted task record" \
    "recovery did not report unsafe metadata beside the close"
  assert_present "$marker" "unsafe metadata caused recovery to discard the close"
  [ -L "$home/state/$id.meta" ] \
    || fail "recovery replaced or removed the unsafe metadata path"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "unsafe metadata allowed recovery to close the backlog row"
  pass "recovery preserves closes beside symlinked metadata"
}

test_recovery_rejects_a_marker_for_another_task_identity() {
  local case_dir locked_id target_id marker out
  locked_id=atomic-marker-lock-owner-b12
  target_id=atomic-marker-target-b12
  case_dir=$(make_home marker-identity-mismatch)
  add_item "$case_dir" "$target_id"
  start_item "$case_dir" "$target_id"
  write_task_meta "$case_dir" "$target_id" ship no-mistakes "spawn_gen=spawn-marker-target"
  marker="$(home_of "$case_dir")/state/$locked_id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-marker-target\narg=--note\narg=local%%20main\n' \
    "$target_id" "$(home_of "$case_dir")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "identity-mismatched close marker was consumed"
  assert_present "$(home_of "$case_dir")/state/$target_id.meta" \
    "identity-mismatched close marker removed another task record"
  [ "$(row_state "$case_dir" "$target_id")" = in_flight ] \
    || fail "identity-mismatched close marker changed another task's row: $out"
  pass "recovery binds close-marker identity to its locked filename"
}

test_recovery_rejects_a_foreign_data_directory() {
  local case_dir foreign_case id marker out
  id=atomic-marker-foreign-data-b12
  case_dir=$(make_home marker-foreign-data-local)
  foreign_case=$(make_home marker-foreign-data-remote)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  add_item "$foreign_case" "$id"
  start_item "$foreign_case" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-foreign-data"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-foreign-data\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$foreign_case")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "foreign-data close marker was consumed"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "foreign-data close marker removed the local task record"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "foreign-data close marker changed the local backlog row: $out"
  [ "$(row_state "$foreign_case" "$id")" = in_flight ] \
    || fail "foreign-data close marker reached into another home's backlog: $out"
  pass "recovery rejects close markers targeting another home's data"
}

test_recovery_rejects_an_unterminated_unknown_field() {
  local case_dir id marker out
  id=atomic-marker-unterminated-field-b12
  case_dir=$(make_home marker-unterminated-field)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-unterminated-field"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-unterminated-field\narg=--note\narg=local%%20main\nunknown=value' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "marker with an unterminated unknown field was consumed"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "unterminated unknown marker field allowed task-record removal"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "unterminated unknown marker field changed the backlog row: $out"
  pass "recovery validates an unterminated final marker field"
}

test_recovery_rejects_lexical_data_traversal() {
  local case_dir id marker data out
  id=atomic-marker-data-traversal-b12
  case_dir=$(make_home marker-data-traversal)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-data-traversal"
  data="$(home_of "$case_dir")/data"
  mkdir -p "$data/sub"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s/sub/..\nspawn_gen=spawn-data-traversal\narg=--note\narg=local%%20main\n' \
    "$id" "$data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "marker with lexical data traversal was consumed"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "lexical data traversal allowed task-record removal"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "lexical data traversal changed the backlog row: $out"
  pass "recovery rejects lexical traversal before resolving marker data"
}

test_recovery_rejects_raw_control_bytes() {
  local case_dir id marker data out
  id=atomic-marker-nul-byte-b12
  case_dir=$(make_home marker-nul-byte)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-nul-byte"
  data="$(home_of "$case_dir")/data"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\0\nspawn_gen=spawn-nul-byte\narg=--note\narg=local%%20main\n' \
    "$id" "$data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "NUL-bearing close marker was consumed"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "NUL-bearing close marker removed the task record"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "NUL-bearing close marker changed the backlog row: $out"
  pass "recovery rejects marker control bytes before parsing"
}

test_recovery_rejects_malformed_pr_urls() {
  local case_dir first_id second_id third_id first_marker second_marker third_marker out
  first_id=atomic-marker-pr-port-b12
  second_id=atomic-marker-pr-percent-b12
  third_id=atomic-marker-pr-host-label-b12
  case_dir=$(make_home marker-malformed-pr)
  add_item "$case_dir" "$first_id"
  start_item "$case_dir" "$first_id"
  add_item "$case_dir" "$second_id"
  start_item "$case_dir" "$second_id"
  add_item "$case_dir" "$third_id"
  start_item "$case_dir" "$third_id"
  first_marker="$(home_of "$case_dir")/state/$first_id.backlog-close"
  second_marker="$(home_of "$case_dir")/state/$second_id.backlog-close"
  third_marker="$(home_of "$case_dir")/state/$third_id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-pr-port\narg=--pr\narg=https://github.com:abc/pull/1\n' \
    "$first_id" "$(home_of "$case_dir")/data" > "$first_marker"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-pr-percent\narg=--pr\narg=https://github.com/pull/%%ZZ\n' \
    "$second_id" "$(home_of "$case_dir")/data" > "$second_marker"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-pr-host-label\narg=--pr\narg=https://foo.-bar.com/pull/1\n' \
    "$third_id" "$(home_of "$case_dir")/data" > "$third_marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$first_marker" "PR marker with a nonnumeric port was consumed"
  assert_present "$second_marker" "PR marker with an invalid percent escape was consumed"
  assert_present "$third_marker" "PR marker with a malformed host label was consumed"
  [ "$(row_state "$case_dir" "$first_id")" = in_flight ] \
    || fail "nonnumeric PR port changed the backlog row: $out"
  [ "$(row_state "$case_dir" "$second_id")" = in_flight ] \
    || fail "invalid PR percent escape changed the backlog row: $out"
  [ "$(row_state "$case_dir" "$third_id")" = in_flight ] \
    || fail "malformed PR host label changed the backlog row: $out"
  pass "recovery rejects malformed PR URL values"
}

test_failed_close_replay_is_not_started_as_live_work() {
  local case_dir id marker out
  id=atomic-pending-close-not-started-b12
  case_dir=$(make_home pending-close-not-started)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-pending-close"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-pending-close\narg=--pr\narg=https://\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "failed close replay discarded its pending marker"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "failed close replay removed its task record"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "retained pending close was started as live work: $out"
  pass "a retained pending close is never started by reconciliation"
}

test_recovery_rejects_invalid_close_arguments() {
  local case_dir id marker out
  id=atomic-marker-invalid-args-b12
  case_dir=$(make_home marker-invalid-args)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-invalid-args\narg=--unknown\narg=value\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"

  out=$(run_bootstrap "$case_dir")
  assert_present "$marker" "invalid-argument close marker was consumed"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "invalid close arguments changed the backlog row: $out"
  pass "recovery rejects close-marker arguments outside its protocol"
}

test_recovery_rejects_a_symlinked_close_marker() {
  local case_dir id marker payload out rc=0
  id=atomic-marker-symlink-b12
  case_dir=$(make_home marker-symlink)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  payload="$(home_of "$case_dir")/state/marker-payload"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-symlink\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" > "$payload"
  ln -s "$payload" "$marker"
  rm -f "$payload"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap accepted a symlinked close marker"
  [ -L "$marker" ] || fail "dangling symlink close marker was consumed: $out"
  assert_contains "$out" "bootstrap refused unsafe pending close" \
    "dangling symlink close marker was silently skipped"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "symlinked close marker changed the backlog row: $out"
  pass "recovery reports and rejects dangling symlink close markers"
}

test_recovery_drops_a_close_for_a_newer_meta_incarnation() {
  local case_dir id out
  id=atomic-heal-new-incarnation-b12
  case_dir=$(make_home heal-new-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-two"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start closed the newer task incarnation: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "session start removed the newer task incarnation's meta"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a stale recorded close was left to fire on a later restart"
  pass "session start drops a close recorded for an older meta incarnation"
}

test_recovery_rejects_a_legacy_close_without_an_incarnation() {
  local case_dir id out
  id=atomic-heal-legacy-close-b13
  case_dir=$(make_home heal-legacy-close)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-two"
  printf 'id=%s\ndata=%s\narg=--note\narg=local%%20main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start guessed that a legacy close belonged to the current meta: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "session start removed meta for an unversioned legacy close"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "session start consumed an unversioned close marker"
  pass "session start rejects an unversioned close marker"
}

test_bootstrap_rechecks_worker_record_boundary_after_locking() {
  local case_dir foreign_case home foreign_state id real_ln out rc=0
  id=atomic-bootstrap-state-swap-b13
  case_dir=$(make_home bootstrap-state-swap)
  foreign_case=$(make_home bootstrap-state-swap-foreign)
  home=$(home_of "$case_dir")
  foreign_state="$(home_of "$foreign_case")/state"
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=local-worker"
  write_task_meta "$foreign_case" "$id" ship no-mistakes "spawn_gen=foreign-worker"
  real_ln=$(command -v ln)
  cat > "$case_dir/fakebin/ln" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"$home/state/.meta-$id.lock"*)
    if [ ! -e "$case_dir/state-swapped" ]; then
      : > "$case_dir/state-swapped"
      mv "$home/state" "$home/state-original" || exit 1
      "$real_ln" -s "$foreign_state" "$home/state" || exit 1
    fi
    ;;
esac
exec "$real_ln" "\$@"
SH
  chmod +x "$case_dir/fakebin/ln"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap trusted a worker record after its state boundary changed"
  assert_contains "$out" "post-lock worker record check refused" \
    "bootstrap did not report the post-lock state-boundary failure"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "bootstrap changed the local row after reading through a swapped state path"
  assert_present "$foreign_state/$id.meta" "bootstrap removed the foreign worker record"
  pass "bootstrap rechecks worker-record containment after locking"
}

test_lifecycle_refuses_ancestor_symlinks_outside_home_roots() {
  local backlog_case worker_case close_case home foreign id marker out rc=0
  id=atomic-ancestor-symlink-b14

  backlog_case=$(make_home ancestor-symlink-backlog "$id")
  home=$(home_of "$backlog_case")
  foreign="$backlog_case/foreign-home"
  mkdir -p "$foreign/data"
  cp "$(backlog_of "$backlog_case")" "$foreign/data/backlog.md"
  ln -s "$foreign" "$home/foreign-link"
  out=$(FM_DATA_OVERRIDE="$home/foreign-link/data" run_ship_spawn "$backlog_case" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch accepted a backlog through an ancestor symlink"
  assert_absent "$home/state/$id.meta" "dispatch published through a foreign backlog root"

  worker_case=$(make_home ancestor-symlink-worker)
  home=$(home_of "$worker_case")
  foreign="$worker_case/foreign-home"
  mkdir -p "$foreign/state"
  add_item "$worker_case" "$id"
  fm_write_meta "$foreign/state/$id.meta" "kind=ship" "spawn_gen=foreign-worker"
  ln -s "$foreign" "$home/foreign-link"
  rc=0
  out=$(FM_STATE_OVERRIDE="$home/foreign-link/state" run_bootstrap "$worker_case") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap accepted a worker record through an ancestor symlink"
  [ "$(row_state "$worker_case" "$id")" = queued ] \
    || fail "bootstrap paired a foreign worker with the local backlog"

  close_case=$(make_home ancestor-symlink-close)
  home=$(home_of "$close_case")
  foreign="$close_case/foreign-home"
  mkdir -p "$foreign/state"
  add_item "$close_case" "$id"
  start_item "$close_case" "$id"
  marker="$foreign/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=foreign-close\narg=--note\narg=local%%20main\n' \
    "$id" "$home/data" > "$marker"
  ln -s "$foreign" "$home/foreign-link"
  rc=0
  out=$(FM_STATE_OVERRIDE="$home/foreign-link/state" run_bootstrap "$close_case") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap accepted a close record through an ancestor symlink"
  assert_present "$marker" "bootstrap discarded a foreign authoritative close"
  [ "$(row_state "$close_case" "$id")" = in_flight ] \
    || fail "bootstrap applied a foreign close to the local backlog"
  pass "lifecycle files reject ancestor symlinks outside home roots"
}

test_same_home_state_override_remains_supported() {
  local case_dir home state id out
  id=atomic-same-home-state-override-b14
  case_dir=$(make_home same-home-state-override)
  home=$(home_of "$case_dir")
  state="$home/runtime-state"
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=same-home-override"
  mv "$home/state" "$state"

  out=$(FM_STATE_OVERRIDE="$state" run_bootstrap "$case_dir") \
    || fail "same-home state override was refused: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "same-home state override did not reconcile its worker"
  pass "same-home state overrides remain supported"
}

test_bootstrap_refuses_a_symlinked_state_directory_before_reconciliation() {
  local case_dir foreign_case home foreign_state id out rc=0
  id=atomic-bootstrap-symlink-state-b11
  case_dir=$(make_home bootstrap-symlink-state)
  foreign_case=$(make_home bootstrap-symlink-state-foreign)
  home=$(home_of "$case_dir")
  foreign_state="$(home_of "$foreign_case")/state"
  add_item "$case_dir" "$id"
  write_task_meta "$foreign_case" "$id" ship no-mistakes "spawn_gen=foreign-worker"
  rm -rf "$home/state"
  ln -s "$foreign_state" "$home/state"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap accepted a symlinked state directory"
  assert_contains "$out" "state directory is not a real directory" \
    "bootstrap did not report the unsafe state boundary"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "bootstrap reconciled a foreign record into the local backlog"
  assert_present "$foreign_state/$id.meta" \
    "bootstrap removed the foreign worker record"
  pass "bootstrap refuses symlinked state before reconciliation"
}

test_bootstrap_stops_when_data_disappears_before_reconciliation() {
  local case_dir id saved out rc=0
  id=atomic-bootstrap-data-race-b11
  case_dir=$(make_home bootstrap-data-race)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-bootstrap-race"
  remove_data_during_startup_budget_check "$case_dir"
  saved="$case_dir/bootstrap-data"

  out=$(run_bootstrap "$case_dir") || rc=$?
  [ "$rc" -ne 0 ] || fail "bootstrap absorbed a fatal reconciliation addressing error: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "fatal bootstrap reconciliation removed the task record"
  [ "$(tasks-axi show "$id" --file "$saved/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "fatal bootstrap reconciliation changed the backlog row"
  pass "bootstrap stops when backlog data disappears before reconciliation"
}

test_bootstrap_addressing_exemptions_remain_nonfatal() {
  local manual_case no_backlog_case secondmate_case secondmate_id out
  manual_case=$(make_home bootstrap-manual-exempt)
  printf '%s\n' manual > "$(home_of "$manual_case")/config/backlog-backend"
  mv "$(home_of "$manual_case")/data" "$manual_case/manual-data"
  out=$(run_bootstrap "$manual_case") \
    || fail "manual bootstrap exemption became fatal: $out"

  no_backlog_case=$(make_home bootstrap-no-backlog-exempt)
  rm -f "$(backlog_of "$no_backlog_case")"
  out=$(run_bootstrap "$no_backlog_case") \
    || fail "no-backlog bootstrap exemption became fatal: $out"

  secondmate_id=atomic-bootstrap-secondmate-exempt-b11
  secondmate_case=$(make_home bootstrap-secondmate-exempt)
  write_task_meta "$secondmate_case" "$secondmate_id" secondmate '' \
    "spawn_gen=spawn-secondmate-exempt"
  mv "$(home_of "$secondmate_case")/data" "$secondmate_case/secondmate-data"
  out=$(run_bootstrap "$secondmate_case") \
    || fail "secondmate bootstrap exemption became fatal: $out"
  assert_present "$(home_of "$secondmate_case")/state/$secondmate_id.meta" \
    "secondmate bootstrap exemption removed the persistent agent record"
  pass "bootstrap preserves secondmate, manual, and absent-backlog exemptions"
}

test_recovery_leaves_a_captain_held_item_alone() {
  local case_dir id out
  id=atomic-heal-b11
  case_dir=$(make_home heal-held)
  add_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start moved a captain-held item to $(row_state "$case_dir" "$id"): $out"
  pass "session start leaves a captain-held item where the captain put it"
}

# --- backend selection and secondmate scope ---------------------------------

test_no_backlog_teardown_refuses_a_symlinked_task_record_at_entry() {
  local case_dir home id target target_dir foreign_worktree out rc=0
  id=atomic-no-backlog-symlink-meta-b12
  case_dir=$(make_home no-backlog-symlink-meta)
  home=$(home_of "$case_dir")
  rm -f "$(backlog_of "$case_dir")"
  foreign_worktree="$case_dir/foreign-worktree"
  mkdir -p "$foreign_worktree"
  target_dir="$home/state-foreign"
  target="$target_dir/$id.meta"
  mkdir -p "$target_dir"
  fm_write_meta "$target" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$foreign_worktree" "project=$case_dir/foreign-project" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  ln -s "$target" "$home/state/$id.meta"
  track_teardown_resource_actions "$case_dir"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "no-backlog teardown accepted a symlinked task record"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "teardown did not identify the unsafe task record"
  [ -L "$home/state/$id.meta" ] || fail "teardown removed the symlinked task record"
  assert_present "$foreign_worktree" "teardown removed a foreign local copy"
  assert_absent "$case_dir/backend-resource-action" \
    "teardown acted on the foreign endpoint"
  assert_absent "$case_dir/local-copy-resource-action" \
    "teardown acted on the foreign local copy"
  pass "no-backlog teardown refuses symlinked records before resource actions"
}

test_teardown_rechecks_record_parent_after_lock_acquisition() {
  local case_dir home id foreign_state foreign_worktree real_ln out rc=0
  id=atomic-state-parent-swap-b12
  case_dir=$(make_home state-parent-swap)
  home=$(home_of "$case_dir")
  rm -f "$(backlog_of "$case_dir")"
  write_task_meta "$case_dir" "$id" ship local-only
  foreign_state="$case_dir/foreign-state"
  foreign_worktree="$case_dir/foreign-worktree"
  mkdir -p "$foreign_state" "$foreign_worktree"
  fm_write_meta "$foreign_state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$foreign_worktree" "project=$case_dir/foreign-project" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  track_teardown_resource_actions "$case_dir"
  real_ln=$(command -v ln)
  cat > "$case_dir/fakebin/ln" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"$home/state/.meta-$id.lock"*)
    if [ ! -e "$case_dir/state-swapped" ]; then
      : > "$case_dir/state-swapped"
      mv "$home/state" "$home/state-original" || exit 1
      "$real_ln" -s "$foreign_state" "$home/state" || exit 1
    fi
    ;;
esac
exec "$real_ln" "\$@"
SH
  chmod +x "$case_dir/fakebin/ln"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown trusted a record after its parent was swapped"
  assert_contains "$out" "task record authorized directory resolves outside this home" \
    "post-lock record check did not report the swapped parent"
  assert_present "$foreign_state/$id.meta" "teardown removed the foreign record"
  assert_present "$foreign_worktree" "teardown removed the foreign local copy"
  assert_absent "$case_dir/backend-resource-action" \
    "teardown acted on a foreign endpoint after the parent swap"
  assert_absent "$case_dir/local-copy-resource-action" \
    "teardown acted on a foreign local copy after the parent swap"
  pass "teardown rechecks record parents after locking"
}

test_teardown_refuses_a_symlinked_state_directory_at_entry() {
  local case_dir home id external_state out rc=0
  id=atomic-symlink-state-b12
  case_dir=$(make_home symlink-state)
  home=$(home_of "$case_dir")
  external_state="$case_dir/external-state"
  mv "$home/state" "$external_state"
  fm_write_meta "$external_state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$case_dir/foreign-worktree" "project=$case_dir/foreign-project" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  ln -s "$external_state" "$home/state"
  track_teardown_resource_actions "$case_dir"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted a symlinked state directory"
  assert_contains "$out" "state directory is not a real directory" \
    "teardown did not identify the unsafe state directory"
  assert_present "$external_state/$id.meta" \
    "teardown removed metadata through the symlinked state directory"
  assert_absent "$case_dir/backend-resource-action" \
    "teardown acted on an endpoint through symlinked state"
  assert_absent "$case_dir/local-copy-resource-action" \
    "teardown acted on a local copy through symlinked state"
  pass "teardown refuses symlinked state before resource actions"
}

test_home_without_a_backlog_dispatches_and_completes() {
  local case_dir id out
  id=atomic-no-backlog-b12
  case_dir=$(make_home no-backlog "$id")
  rm -f "$(backlog_of "$case_dir")"
  make_tasks_axi_incompatible "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "no-backlog spawn failed: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "no-backlog spawn did not publish its task record"
  out=$(run_teardown "$case_dir" "$id") || fail "no-backlog teardown failed: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "no-backlog teardown retained its task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "no-backlog teardown recorded a close marker"
  pass "a home with no backlog remains exempt from lifecycle transitions"
}

test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog() {
  local case_dir id data data_resolved out
  id=atomic-manual-b12
  case_dir=$(make_home manual-backend "$id")
  printf '%s\n' manual > "$(home_of "$case_dir")/config/backlog-backend"
  data="$case_dir/manual-data"
  mv "$(home_of "$case_dir")/data" "$data"
  data_resolved=$(cd "$data" && pwd -P)
  make_tasks_axi_incompatible "$case_dir"
  # Deliberately no backlog item: on a manual home the operator owns the file,
  # so neither half of the lifecycle may hard-fail over its contents.
  out=$(FM_DATA_OVERRIDE="$data" run_ship_spawn "$case_dir" "$id") \
    || fail "manual-backend spawn failed: $out"
  assert_contains "$out" "spawned $id" "manual-backend spawn did not report success"

  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") \
    || fail "manual-backend teardown failed: $out"
  assert_contains "$out" "Update $data_resolved/backlog.md" \
    "manual-backend teardown did not name its configured backlog path"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "manual-backend teardown recorded a close it never owed"
  pass "a manual-backlog home dispatches and completes without a hard failure"
}

test_a_secondmate_home_keeps_its_own_books() {
  local case_dir id out
  id=atomic-mate-b13
  case_dir=$(make_home mate-own-books "$id")
  # The mate's home is a firstmate home in its own right; the invariant is
  # single-host, so its own dispatch and completion keep its own two records
  # paired with no parent involved.
  printf '%s\n' mate-h1 > "$(home_of "$case_dir")/.fm-secondmate-home"
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "mate-home spawn failed: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "a mate's own dispatch left its item at $(row_state "$case_dir" "$id")"

  rm -f "$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-mate-close"
  out=$(run_teardown "$case_dir" "$id") || fail "mate-home teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "a mate's own completion left its item at $(row_state "$case_dir" "$id")"
  pass "a secondmate home keeps its own books paired through dispatch and completion"
}

test_a_persistent_secondmate_is_never_a_backlog_item() {
  local case_dir id out mate
  id=atomic-mate-b14
  case_dir=$(make_home mate-not-an-item)
  mate="$case_dir/mate-home"
  mkdir -p "$mate/bin" "$mate/data"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$mate/data/charter.md"

  # No backlog item exists for the mate, and none should be required: agents are
  # not work items. The dispatch must succeed anyway.
  out=$(run_spawn "$case_dir" "$id" "$mate" --secondmate) \
    || fail "secondmate spawn failed: $out"
  assert_contains "$out" "spawned $id" "secondmate spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "secondmate spawn published no record"
  pass "dispatching a persistent secondmate needs no backlog item"
}

test_dispatch_moves_the_item_in_flight_in_the_same_run
test_dispatch_omits_the_file_for_a_beads_show
test_dispatch_refuses_a_pending_authoritative_close
test_dispatch_refuses_a_held_row_before_creating_resources
test_dispatch_refuses_a_blocked_row_before_creating_resources
test_dispatch_refuses_a_held_in_flight_row_before_relaunch
test_dispatch_reads_the_row_from_the_backlog_root
test_recovery_uses_the_parent_of_a_trailing_slash_data_record
test_completion_targets_a_nested_relative_data_directory
test_immediate_child_absolute_data_dispatches_and_completes
test_bare_relative_data_dispatches_and_completes
test_dispatch_refuses_a_symlinked_backlog_without_crossing_homes
test_automatic_backend_refuses_incompatible_tasks_axi_before_mutation
test_dispatch_refuses_an_unresolvable_data_directory
test_completion_refuses_an_unresolvable_data_directory
test_dispatch_refuses_an_id_this_home_has_no_item_for
test_dispatch_reports_a_backlog_read_failure
test_dispatch_refuses_a_closed_item
test_dispatch_refuses_to_commit_without_a_published_record
test_dispatch_leaves_no_record_when_the_transition_fails
test_dispatch_reports_an_incomplete_record_rollback
test_dispatch_reports_an_incomplete_busy_rollback
test_dispatch_rolls_back_before_a_failed_launch_delivery
test_dispatch_defers_interruption_across_backlog_commit
test_dispatch_interruption_during_kimi_readiness_fails_before_commit
test_dispatch_does_not_resurrect_a_row_closed_after_preflight
test_dispatch_fails_when_its_row_vanishes_after_preflight
test_completion_closes_a_local_only_ship_before_reporting_success
test_completion_closes_a_scout_with_its_report
test_completion_refuses_a_legacy_record_without_an_incarnation
test_completion_refuses_ambiguous_incarnation_metadata
test_completion_records_a_relative_report_for_relocated_data
test_space_containing_scout_report_marker_replays
test_trailing_newline_data_path_fails_closed
test_control_character_data_path_is_refused_before_cleanup
test_completion_preserves_records_when_meta_removal_fails
test_completion_fails_loudly_and_records_the_close_it_still_owes
test_interrupted_destructive_cleanup_leaves_a_recoverable_close
test_completion_refuses_a_close_target_symlinked_to_a_directory
test_completion_fails_when_its_close_marker_cannot_be_removed
test_recovery_retries_when_a_close_marker_cannot_be_removed
test_recovery_reports_an_owned_row_read_failure
test_orca_cleanup_recovery_never_transitions_the_backlog
test_recovery_marks_an_owned_record_in_flight
test_recovery_rejects_an_internal_worker_record_symlink
test_recovery_ignores_a_symlinked_worker_record
test_recovery_replays_a_close_an_interrupted_cleanup_left_open
test_recovery_backfills_a_recorded_link_on_an_already_done_item
test_recovery_preserves_a_close_when_the_backlog_cannot_be_read
test_recovery_retry_preserves_incomplete_cleanup_warning
test_recovery_finishes_a_close_for_the_same_meta_incarnation
test_recovery_preserves_a_close_for_ambiguous_incarnation_metadata
test_recovery_preserves_both_records_when_meta_removal_fails
test_recovery_preserves_a_close_beside_symlinked_metadata
test_recovery_rejects_a_marker_for_another_task_identity
test_recovery_rejects_a_foreign_data_directory
test_recovery_rejects_an_unterminated_unknown_field
test_recovery_rejects_lexical_data_traversal
test_recovery_rejects_raw_control_bytes
test_recovery_rejects_malformed_pr_urls
test_failed_close_replay_is_not_started_as_live_work
test_recovery_rejects_invalid_close_arguments
test_recovery_rejects_a_symlinked_close_marker
test_recovery_drops_a_close_for_a_newer_meta_incarnation
test_recovery_rejects_a_legacy_close_without_an_incarnation
test_bootstrap_rechecks_worker_record_boundary_after_locking
test_lifecycle_refuses_ancestor_symlinks_outside_home_roots
test_same_home_state_override_remains_supported
test_bootstrap_refuses_a_symlinked_state_directory_before_reconciliation
test_bootstrap_stops_when_data_disappears_before_reconciliation
test_bootstrap_addressing_exemptions_remain_nonfatal
test_recovery_leaves_a_captain_held_item_alone
test_no_backlog_teardown_refuses_a_symlinked_task_record_at_entry
test_teardown_rechecks_record_parent_after_lock_acquisition
test_teardown_refuses_a_symlinked_state_directory_at_entry
test_home_without_a_backlog_dispatches_and_completes
test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog
test_a_secondmate_home_keeps_its_own_books
test_a_persistent_secondmate_is_never_a_backlog_item
