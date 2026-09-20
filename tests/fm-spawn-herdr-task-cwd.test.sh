#!/usr/bin/env bash
# Regression test: a Herdr task pane is created with its task worktree as the
# pane's own working directory.
#
# Herdr records a pane's cwd at creation and restores the pane there after a
# reboot or server restart. A task pane created in the project's primary
# checkout therefore came back in the primary checkout after every reboot, and a
# resumed worker could act there before anything noticed. bin/fm-spawn.sh now
# acquires the task worktree before it creates the Herdr pane, so the recorded
# cwd is already the worktree the task's record names.
#
# The fake `herdr` below keeps a pane's creation cwd (`pane get`'s `.cwd`)
# apart from its live foreground cwd (`.foreground_cwd`), as the real server
# does (bin/backends/herdr.sh fm_backend_herdr_current_path), and models an
# interactive `treehouse get` typed into the pane as moving only the foreground
# cwd. The fake `treehouse` hands out one prepared worktree either way, so the
# test measures only where the pane itself was created.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-task-cwd)

make_herdr_cwd_fakebin() {  # <dir> -> echoes fakebin dir
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
if [ ! -f "$STATE" ]; then
  # A projected spawn is placed under the launcher home's own workspace, so the
  # captain's workspace is seeded here (focused, with its active tab) exactly as
  # a live session presents it. Absent, the session is empty and the ordinary
  # flat layout applies.
  if [ -n "${FM_FAKE_HERDR_PARENT_LABEL:-}" ]; then
    jq -n --arg l "$FM_FAKE_HERDR_PARENT_LABEL" \
      '{next:1,
        workspaces:[{workspace_id:"w0", label:$l, focused:true, active_tab_id:"w0:t0"}],
        panes:[{pane_id:"w0:p0", tab_id:"w0:t0", workspace_id:"w0", label:"captain", cwd:"/", foreground_cwd:"/"}]}' \
      > "$STATE"
  else
    printf '{"next":1,"workspaces":[],"panes":[]}\n' > "$STATE"
  fi
fi
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
args=("$@")
ws=""; label=""; cwd=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
  esac
done
new_pane() {  # <workspace> <tab-label> <cwd> -> "<tab> <pane>"
  local n tab pane
  n=$(jq -r '.next' "$STATE"); tab="$1:t$n"; pane="$1:p$n"
  jq --arg w "$1" --arg l "$2" --arg c "$3" --arg t "$tab" --arg p "$pane" \
    '.panes += [{pane_id:$p, tab_id:$t, workspace_id:$w, label:$l, cwd:$c, foreground_cwd:$c}]
     | .next += 1' "$STATE" | save
  printf '%s %s\n' "$tab" "$pane"
}
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.9.0","protocol":16},"server":{"running":true,"version":"0.9.0","protocol":16}}\n'
    ;;
  "session list")
    # The named session's socket identity, which the projection path hashes
    # into its focus-order lock path. One fake server per case.
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' \
      "${HERDR_SESSION:-default}" "$STATE.sock"
    ;;
  "workspace list")
    jq '{result:{workspaces:.workspaces}}' "$STATE"
    ;;
  "workspace create")
    n=$(jq -r '.next' "$STATE"); wsid="w$n"
    jq --arg w "$wsid" --arg l "$label" '.workspaces += [{workspace_id:$w, label:$l, focused:false, active_tab_id:null}] | .next += 1' "$STATE" | save
    read -r tab pane <<EOF
$(new_pane "$wsid" 1 "$cwd")
EOF
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$tab" "$pane"
    ;;
  "tab list")
    jq --arg w "$ws" '
      ([.workspaces[]|select(.workspace_id==$w)|.active_tab_id]|first) as $a
      | {result:{tabs:[.panes[]|select(.workspace_id==$w)
        |{tab_id, label, workspace_id, focused:(.tab_id == $a)}]}}' "$STATE"
    ;;
  "tab get")
    jq -e --arg t "${3:-}" 'any(.panes[]; .tab_id==$t)' "$STATE" >/dev/null || {
      printf '{"error":{"code":"tab_not_found","message":"tab %s not found"}}\n' "${3:-}"
      exit 1
    }
    jq --arg t "${3:-}" '{result:{tab:([.panes[]|select(.tab_id==$t)|{tab_id, label, workspace_id}]|first)}}' "$STATE"
    ;;
  "tab focus")
    jq --arg t "${3:-}" '
      ([.panes[]|select(.tab_id==$t)|.workspace_id]|first) as $w
      | .workspaces |= map(if .workspace_id == $w
          then (.focused = true | .active_tab_id = $t)
          else .focused = false end)' "$STATE" | save
    ;;
  "tab create")
    read -r tab pane <<EOF
$(new_pane "$ws" "$label" "$cwd")
EOF
    printf '{"result":{"tab":{"tab_id":"%s","label":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$label" "$pane"
    ;;
  "pane list")
    jq --arg w "$ws" '{result:{panes:[.panes[]|select(.workspace_id==$w)|{pane_id, tab_id, workspace_id}]}}' "$STATE"
    ;;
  "pane get")
    jq -e --arg p "${3:-}" '.panes[]|select(.pane_id==$p)' "$STATE" >/dev/null || {
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "${3:-}"
      exit 1
    }
    if [ -n "${FM_FAKE_FOREGROUND_CWD:-}" ]; then
      jq --arg p "${3:-}" --arg c "$FM_FAKE_FOREGROUND_CWD" \
        '{result:{pane:(.panes[]|select(.pane_id==$p)|.foreground_cwd = $c)}}' "$STATE"
    else
      jq --arg p "${3:-}" '{result:{pane:(.panes[]|select(.pane_id==$p))}}' "$STATE"
    fi
    ;;
  "pane send-text")
    # Launch delivery, which runs AFTER the task record is published: failing
    # it is how a case reaches the abort path with a record already written.
    [ "${FM_FAKE_HERDR_SEND_FAIL:-0}" = 1 ] && exit 1
    ;;
  "pane send-keys")
    # The Enter that submits the staged launch command: failing it is how a
    # case reaches the abort path with the pane and its agent already live.
    [ "${FM_FAKE_HERDR_SENDKEY_FAIL:-0}" = 1 ] && exit 1
    ;;
  "pane close")
    jq --arg p "${3:-}" '.panes |= [.[]|select(.pane_id != $p)]' "$STATE" | save
    ;;
  "tab close")
    jq --arg t "${3:-}" '.panes |= [.[]|select(.tab_id != $t)]' "$STATE" | save
    ;;
  "pane run")
    # An interactive `treehouse get` typed into the pane moves only the pane
    # shell's foreground cwd; the pane's own recorded cwd never changes.
    case "${4:-}" in
      "treehouse get")
        jq --arg p "${3:-}" --arg c "${FM_FAKE_TREEHOUSE_WT:?}" \
          '.panes |= map(if .pane_id == $p then .foreground_cwd = $c else . end)' "$STATE" | save
        ;;
    esac
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}"
    ;;
  "terminal title")
    printf '{"result":{"reason":"no_foreground_client"}}\n'
    ;;
esac
exit 0
SH
  # The fake pool keeps the one fact the real `treehouse status --json`
  # publishes and this spawn path reads: which holder, if any, a worktree is
  # leased to. `get --lease` records it, `return` drops it.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
LEASES="${FM_FAKE_TREEHOUSE_LEASES:?}"
[ -f "$LEASES" ] || : > "$LEASES"
holder=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --lease-holder|--if-lease-holder) holder=$arg ;;
  esac
  prev=$arg
done
case "${1:-}" in
  get)
    case " $* " in
      *" --lease "*)
        [ "${FM_FAKE_TREEHOUSE_LEASE_FAIL:-0}" = 1 ] && exit 1
        printf '%s\t%s\n' "${FM_FAKE_TREEHOUSE_WT:?}" "$holder" >> "$LEASES"
        printf '%s\n' "$FM_FAKE_TREEHOUSE_WT"
        ;;
    esac
    ;;
  status)
    awk -F'\t' '
      BEGIN { printf "[" }
      { if (NR > 1) printf ","
        printf "{\"name\":\"%d\",\"path\":\"%s\",\"status\":\"leased\",\"lease_holder\":\"%s\"}", NR, $1, $2 }
      END { printf "]\n" }
    ' "$LEASES"
    ;;
  return)
    [ "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" = 1 ] && exit 1
    # The real `treehouse return --force` cleans and resets the checkout before
    # the slot goes back to the pool, so anything unlanded in it is gone. The
    # fake does the same, or a test could not tell a returned slot from a kept
    # one by looking at the work.
    case " $* " in
      *" --force "*)
        git -C "${!#}" reset --hard -q 2>/dev/null || true
        git -C "${!#}" clean -fdq 2>/dev/null || true
        ;;
    esac
    awk -F'\t' -v p="${!#}" -v h="$holder" '$1 != p || (h != "" && $2 != h)' "$LEASES" > "$LEASES.tmp"
    mv "$LEASES.tmp" "$LEASES"
    ;;
esac
exit 0
SH
  # The pane-settle poll sleeps between reads; a refusal case would otherwise
  # spend its whole real-time window.
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/treehouse" "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# A backlog this home owns, plus the one tasks-axi build the dispatch path
# probes for. `start` is the In-flight commit fm-spawn.sh runs AFTER launch
# delivery; failing it rolls the just-published task record back, which is what
# puts an abort on the leased-slot branch with the pane already live.
make_backlog_fixture() {  # <home>
  local home=$1
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
fail_commit() {
  [ "${FM_FAKE_TASKS_AXI_START_FAIL:-0}" = 1 ] || return 0
  printf 'error: the backlog row could not be moved\n' >&2
  printf 'code: UNKNOWN\n' >&2
  exit 1
}
case "${1:-}" in
  --version) printf '0.2.5\n' ;;
  update)
    [ "${2:-}" = --help ] && { printf '%s\n' '--archive-body'; exit 0; }
    fail_commit
    ;;
  mv)
    [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi mv [<id>...]'; exit 0; }
    fail_commit
    ;;
  show) printf 'task:\n  state: queued\n  held: no\n  blocked: no\n' ;;
  start) fail_commit ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
}

# make_case <name> <id> -> sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_DIR
make_case() {
  local name=$1 id=$2 presentation=${3:-off}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(make_herdr_cwd_fakebin "$CASE_DIR/fake")
  FM_FAKE_HERDR_PARENT_LABEL=
  export FM_FAKE_HERDR_PARENT_LABEL
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  # The ordinary flat layout by default: presentation spaces are a separate
  # projection whose own task tab takes the same cwd argument. A projected case
  # opts in and needs the captain's own workspace to project underneath.
  printf '%s\n' "$presentation" > "$HOME_DIR/config/herdr-presentation-spaces"
  [ "$presentation" != on ] || FM_FAKE_HERDR_PARENT_LABEL=firstmate
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

run_herdr_spawn() {  # <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u TMUX \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state.json" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" FM_FAKE_TREEHOUSE_WT="$WT_DIR" \
    FM_FAKE_TREEHOUSE_LEASES="$CASE_DIR/treehouse-leases" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$1" "$PROJ_DIR" "sh -c 'echo herdr-cwd-ok'" --backend herdr --mode no-mistakes --yolo off 2>&1
}

pane_field() {  # <pane-id> <field>
  jq -r --arg p "$1" --arg f "$2" '.panes[]|select(.pane_id==$p)|.[$f]' "$CASE_DIR/herdr-state.json"
}

test_task_pane_is_created_in_its_worktree() {
  local id=herdr-cwd-a1 out status window pane recorded_wt
  make_case created-in-worktree "$id"
  mkdir -p "$CASE_DIR/user-home"
  out=$(run_herdr_spawn "$id")
  status=$?
  expect_code 0 "$status" "herdr spawn should succeed"$'\n'"$out"
  recorded_wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  [ "$(cd "$recorded_wt" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "task record names worktree '$recorded_wt', expected '$WT_DIR'"
  window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$id.meta")
  pane=${window#*:}
  [ "$(pane_field "$pane" label)" = "fm-$id" ] \
    || fail "task record window '$window' does not name the task pane"
  [ "$(pane_field "$pane" cwd)" = "$recorded_wt" ] \
    || fail "task pane was created in '$(pane_field "$pane" cwd)', not its worktree '$recorded_wt'; a restored pane would resume there"
  assert_grep "get --lease --lease-holder fm-$id" "$CASE_DIR/treehouse.log" \
    "the worktree was not durably leased to the task before its pane was created"
  pass "a new Herdr task pane records its task worktree as its own cwd"
}

# A spawn that aborts after leasing its worktree but before its task record
# exists must hand the durable lease back, or the slot stays leased forever.
test_aborted_spawn_returns_its_lease() {
  local id=herdr-cwd-b2 out status
  make_case aborted-returns-lease "$id"
  mkdir -p "$CASE_DIR/user-home" "$CASE_DIR/elsewhere"
  out=$(FM_FAKE_FOREGROUND_CWD="$CASE_DIR/elsewhere" run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a pane that never reports its leased worktree"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" "refusal did not name the unsettled pane"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "aborted spawn published a task record"
  assert_grep "return --force --if-lease-holder fm-$id $WT_DIR" "$CASE_DIR/treehouse.log" \
    "aborted spawn did not return its leased worktree"
  pass "an aborted Herdr spawn returns the worktree it leased"
}

# A slot the abort could not hand back stays leased to this id with no task
# record naming it, so nothing would ever find it again. The durable record is
# what bin/fm-bootstrap.sh turns into a session-start line.
test_retained_lease_is_recorded_for_session_start() {
  local id=herdr-cwd-e5 out status marker
  make_case retained-lease-record "$id"
  mkdir -p "$CASE_DIR/user-home" "$CASE_DIR/elsewhere"
  out=$(FM_FAKE_FOREGROUND_CWD="$CASE_DIR/elsewhere" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a pane that never reports its leased worktree"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "aborted spawn published a task record"
  marker="$HOME_DIR/state/.treehouse-lease-retained/$id.$(basename "$(dirname "$WT_DIR")").retained"
  [ -f "$marker" ] \
    || fail "an abort that could not return its leased slot recorded nothing under state/.treehouse-lease-retained/"
  [ "$(sed -n 's/^worktree=//p' "$marker")" = "$WT_DIR" ] \
    || fail "the retained-slot record does not name the leased worktree: $(cat "$marker")"
  [ "$(sed -n 's/^holder=//p' "$marker")" = "fm-$id" ] \
    || fail "the retained-slot record does not name the lease holder: $(cat "$marker")"
  [ "$(sed -n 's/^task=//p' "$marker")" = "$id" ] \
    || fail "the retained-slot record does not name the task: $(cat "$marker")"
  [ -n "$(sed -n 's/^reason=//p' "$marker")" ] \
    || fail "the retained-slot record does not say why the slot was kept: $(cat "$marker")"
  pass "an abort that keeps its Treehouse lease records the slot for a deliberate reclaim"
}

# No worktree, no pane: a failed lease refuses before Herdr creates anything.
test_failed_lease_creates_no_pane() {
  local id=herdr-cwd-c3 out status
  make_case failed-lease "$id"
  mkdir -p "$CASE_DIR/user-home"
  out=$(FM_FAKE_TREEHOUSE_LEASE_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the worktree lease fails"$'\n'"$out"
  assert_contains "$out" "did not lease a worktree" "refusal did not name the failed lease"
  if grep -q "^tab create" "$CASE_DIR/herdr.log" 2>/dev/null; then
    fail "a failed lease still created a Herdr task tab"
  fi
  pass "a failed worktree lease refuses before any Herdr task pane exists"
}

# The restart-recovery corridor: a reboot leaves the pane an agent-free husk
# with the worker's unlanded work sitting in the leased worktree, and the
# same-identity respawn replaces that husk. The respawn must take the slot the
# task already holds - a second slot would strand the first one, leased to this
# id with no record naming it and its unlanded work out of reach.
test_recorded_worktree_is_reused_with_its_work() {
  local id=herdr-cwd-d4 out status window pane recorded_wt leases
  make_case reuse-recorded-worktree "$id"
  mkdir -p "$CASE_DIR/user-home"
  out=$(run_herdr_spawn "$id")
  status=$?
  expect_code 0 "$status" "first herdr spawn should succeed"$'\n'"$out"
  printf 'unlanded\n' > "$WT_DIR/work.txt"
  printf 'edited by the worker\n' >> "$WT_DIR/README.md"
  out=$(run_herdr_spawn "$id")
  status=$?
  expect_code 0 "$status" "same-identity respawn should succeed"$'\n'"$out"
  recorded_wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  [ "$(cd "$recorded_wt" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "respawn record names worktree '$recorded_wt', expected the worktree it already held, '$WT_DIR'"
  [ -f "$WT_DIR/work.txt" ] && grep -q 'edited by the worker' "$WT_DIR/README.md" \
    || fail "the respawn discarded the unlanded work in the task's own worktree"
  leases=$(grep -c -- '--lease --lease-holder' "$CASE_DIR/treehouse.log" || true)
  [ "$leases" = 1 ] \
    || fail "the respawn leased a second pool slot ($leases leases) instead of reusing the one $id already held"
  window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$id.meta")
  pane=${window#*:}
  [ "$(pane_field "$pane" cwd)" = "$recorded_wt" ] \
    || fail "the replacement pane was created in '$(pane_field "$pane" cwd)', not the reused worktree '$recorded_wt'"
  pass "a same-identity Herdr respawn reuses the worktree it already leases, unlanded work intact"
}

# The reuse corridor's abort: a respawn that took the slot the task already
# held owns none of the work in it, so an abort must never hand that slot back
# - `treehouse return --force` deletes untracked files and resets the checkout.
# The abort cannot re-read the record to tell a reused slot from a fresh one,
# because the rollback has already removed it, so only what was captured when
# the slot was reused can decide this.
test_aborted_reuse_keeps_its_worktree_and_work() {
  local id=herdr-cwd-f6 out status marker
  make_case aborted-reuse-keeps-work "$id"
  mkdir -p "$CASE_DIR/user-home"
  out=$(run_herdr_spawn "$id")
  status=$?
  expect_code 0 "$status" "first herdr spawn should succeed"$'\n'"$out"
  printf 'unlanded\n' > "$WT_DIR/work.txt"
  printf 'edited by the worker\n' >> "$WT_DIR/README.md"
  out=$(FM_FAKE_HERDR_SEND_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a respawn whose launch delivery fails should not report success"$'\n'"$out"
  [ -f "$WT_DIR/work.txt" ] && grep -q 'edited by the worker' "$WT_DIR/README.md" \
    || fail "the aborted respawn discarded the unlanded work in the worktree it had only reused"
  if grep -q -- "return --force --if-lease-holder fm-$id $WT_DIR" "$CASE_DIR/treehouse.log"; then
    fail "the aborted respawn force-returned the slot it reused; teardown owns that slot's return"
  fi
  marker="$HOME_DIR/state/.treehouse-lease-retained/$id.$(basename "$(dirname "$WT_DIR")").retained"
  if [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -f "$marker" ]; then
    fail "the abort left the slot leased with no record naming it, so no session start would surface it"
  fi
  pass "an aborted respawn keeps the worktree it reused, with its unlanded work"
}

# The projected corridor's post-delivery abort. Presentation spaces are on, so
# the task pane lives in a disposable one-task workspace whose own shell - and
# now the launched agent - run in the leased worktree. Launch delivery has
# already happened, so this abort attempts no close at all; the pane is still
# there. `treehouse return --force` terminates every process whose cwd is under
# the slot, so returning it here would kill that agent, destroy its work, take
# the projected workspace down with it, and strand the projection journal.
# The slot must stay leased, and the retained record must say plainly that no
# close was attempted rather than blaming a refusal that never ran.
test_aborted_projected_spawn_keeps_its_live_pane() {
  local id=herdr-cwd-g7 out status marker pane
  make_case projected-abort-after-launch "$id" on
  mkdir -p "$CASE_DIR/user-home"
  make_backlog_fixture "$HOME_DIR"
  out=$(FM_FAKE_TASKS_AXI_START_FAIL=1 run_herdr_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose In-flight commit fails should not report success"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the rolled-back spawn left a task record"$'\n'"$out"
  pane=$(jq -r --arg l "fm-$id" '.panes[]|select(.label==$l)|.pane_id' "$CASE_DIR/herdr-state.json")
  [ -n "$pane" ] \
    || fail "the aborted spawn destroyed the projected task pane its agent is running in"$'\n'"$out"
  [ "$(pane_field "$pane" cwd)" = "$WT_DIR" ] \
    || fail "the projected task pane was created in '$(pane_field "$pane" cwd)', not its worktree '$WT_DIR'"
  if grep -q -- "return --force --if-lease-holder fm-$id $WT_DIR" "$CASE_DIR/treehouse.log"; then
    fail "the abort force-returned a slot whose projected pane and agent are still live"$'\n'"$out"
  fi
  [ -f "$HOME_DIR/state/$id.herdr-presentation" ] \
    || fail "the abort removed the projection journal the session sweeper retires"$'\n'"$out"
  marker="$HOME_DIR/state/.treehouse-lease-retained/$id.$(basename "$(dirname "$WT_DIR")").retained"
  [ -f "$marker" ] \
    || fail "the retained slot was not recorded, so no session start would surface it"$'\n'"$out"
  assert_contains "$(sed -n 's/^reason=//p' "$marker")" "$pane" \
    "the retained-slot reason does not name the pane that kept the slot"
  assert_contains "$(sed -n 's/^reason=//p' "$marker")" "attempted no close" \
    "the retained-slot reason blames a refused close this abort never attempted"
  pass "an aborted projected spawn keeps the slot its live task pane runs in"
}

test_task_pane_is_created_in_its_worktree
test_aborted_projected_spawn_keeps_its_live_pane
test_aborted_spawn_returns_its_lease
test_aborted_reuse_keeps_its_worktree_and_work
test_retained_lease_is_recorded_for_session_start
test_failed_lease_creates_no_pane
test_recorded_worktree_is_reused_with_its_work
# all fm-spawn-herdr-task-cwd tests passed
