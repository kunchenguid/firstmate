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
[ -f "$STATE" ] || printf '{"next":1,"workspaces":[],"panes":[]}\n' > "$STATE"
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
  "workspace list")
    jq '{result:{workspaces:.workspaces}}' "$STATE"
    ;;
  "workspace create")
    n=$(jq -r '.next' "$STATE"); wsid="w$n"
    jq --arg w "$wsid" --arg l "$label" '.workspaces += [{workspace_id:$w, label:$l}] | .next += 1' "$STATE" | save
    read -r tab pane <<EOF
$(new_pane "$wsid" 1 "$cwd")
EOF
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$tab" "$pane"
    ;;
  "tab list")
    jq --arg w "$ws" '{result:{tabs:[.panes[]|select(.workspace_id==$w)|{tab_id, label, workspace_id}]}}' "$STATE"
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
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
case "${1:-}" in
  get)
    case " $* " in
      *" --lease "*)
        [ "${FM_FAKE_TREEHOUSE_LEASE_FAIL:-0}" = 1 ] && exit 1
        printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:?}"
        ;;
    esac
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

# make_case <name> <id> -> sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_DIR
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(make_herdr_cwd_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  # The ordinary flat layout: presentation spaces are a separate projection
  # whose own task tab takes the same cwd argument.
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
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

test_task_pane_is_created_in_its_worktree
test_aborted_spawn_returns_its_lease
test_failed_lease_creates_no_pane
# all fm-spawn-herdr-task-cwd tests passed
