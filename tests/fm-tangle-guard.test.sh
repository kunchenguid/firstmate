#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit and a local origin. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# Spawn isolation uses the shared spawn fakebin (pane path + window ops).
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  fm_test_spawn_brief "$home" "$id" brief
  fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn durable worktree claims ----------------------------

test_spawn_durable_worktree_claims() {
  local home proj claimed free own alias fakebin rec out status
  home="$TMP_ROOT/spawn-claim-home"
  mkdir -p "$home/data" "$home/state"
  proj=$(make_repo "$TMP_ROOT/spawn-claim-proj")
  claimed="$TMP_ROOT/spawn-claim-wt"
  free="$TMP_ROOT/spawn-free-wt"
  own="$TMP_ROOT/spawn-own-wt"
  alias="$TMP_ROOT/spawn-claim-alias"
  git -C "$proj" worktree add -q --detach "$claimed" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$free" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$own" >/dev/null 2>&1
  ln -s "$claimed" "$alias"
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-claim-fake")
  rec="$TMP_ROOT/spawn-claim.log"
  : > "$rec"

  {
    echo 'window=firstmate:fm-incumbent'
    echo 'endpoint_task_id=incumbent'
    echo "worktree=$alias/"
    echo "project=$proj"
    echo 'harness=codex'
    echo 'kind=ship'
  } > "$home/state/incumbent.meta"

  # fm-collision-gg7-fix is an unrelated live task whose window name EXTENDS the
  # contender's. It is what tmux's fnmatch/prefix resolution (and its fallback to
  # the current window) would wrongly report as the contender's own surviving
  # endpoint, and it is also the window an operator would kill if the refusal
  # named a target that resolves by prefix.
  out=$(FM_TMUX_REC="$rec" FM_FAKE_WINDOWS='fm-collision-gg7-fix' \
    run_spawn "$home" collision-gg7 "$proj" "$claimed" "$fakebin")
  status=$?
  expect_code 1 "$status" "spawn into another live task's worktree should refuse"
  assert_contains "$out" "claimed by task incumbent in $home/state/incumbent.meta" \
    "the collision refusal must name the owning task and the durable record it read"
  assert_contains "$out" "does not prove a live worker" \
    "the refusal must not present a durable claim as proof that a worker is running"
  assert_contains "$out" "leftover from an incomplete cleanup and must be removed" \
    "the refusal must tell the operator how to clear a stale claim"
  assert_not_contains "$out" "claimed by live task" \
    "the refusal must not assert liveness the record cannot prove"
  assert_absent "$home/state/collision-gg7.meta" "a collision refusal must not publish contender metadata"
  assert_grep 'kill-window -t =firstmate:=fm-collision-gg7' "$rec" \
    "a collision refusal must retire the new endpoint so treehouse can reallocate the slot"
  assert_no_grep 'send-keys -t firstmate:fm-collision-gg7 -l' "$rec" \
    "a collision refusal must not type an agent launch command"
  assert_not_contains "$out" "survived the refusal" \
    "a retired endpoint must not be reported as a survivor, even beside a prefix-sharing sibling window"

  # A close that reports success while the window survives is not a retirement:
  # the leftover endpoint is exactly what refuses the next attempt, so it has to
  # be named rather than swallowed behind the best-effort kill's exit status.
  : > "$rec"
  out=$(FM_TMUX_REC="$rec" FM_FAKE_TMUX_KILL_NOOP=1 \
    run_spawn "$home" stuck-jj0 "$proj" "$claimed" "$fakebin")
  status=$?
  expect_code 1 "$status" "spawn into another live task's worktree should refuse"
  assert_contains "$out" "endpoint firstmate:fm-stuck-jj0 named fm-stuck-jj0 survived" \
    "a surviving endpoint must be named so the operator can retire it"
  out=$(FM_TMUX_REC="$rec" run_spawn "$home" stuck-jj0 "$proj" "$claimed" "$fakebin")
  status=$?
  expect_code 1 "$status" "the leftover endpoint should block the next attempt"
  assert_contains "$out" "window firstmate:fm-stuck-jj0 already exists" \
    "the endpoint the warning named is what refuses the retry"

  rm "$home/state/incumbent.meta"
  : > "$rec"
  out=$(FM_TMUX_REC="$rec" FM_FAKE_WINDOWS='fm-collision-gg7-fix' \
    run_spawn "$home" collision-gg7 "$proj" "$claimed" "$fakebin")
  status=$?
  expect_code 0 "$status" "the same spawn should be retryable after the durable claim retires"
  assert_contains "$out" 'spawned collision-gg7' "the retry did not launch after the claim retired"

  out=$(FM_TMUX_REC="$rec" run_spawn "$home" free-hh8 "$proj" "$free" "$fakebin")
  status=$?
  expect_code 0 "$status" "a different, genuinely free worktree should remain launchable"
  assert_contains "$out" 'spawned free-hh8' "the free-worktree spawn did not report success"

  fm_test_spawn_brief "$home" own-ii9 brief
  {
    echo 'window=firstmate:fm-own-ii9'
    echo 'endpoint_task_id=own-ii9'
    echo "worktree=$own/"
    echo "project=$proj"
    echo 'harness=codex'
    echo 'kind=ship'
    echo 'mode=no-mistakes'
    echo 'yolo=off'
    echo 'tasktmp=/tmp/fm-own-ii9'
    echo 'model=default'
    echo 'effort=default'
  } > "$home/state/own-ii9.meta"
  out=$(FM_TMUX_REC="$rec" FM_FAKE_WINDOWS='fm-own-ii9' FM_FAKE_PANE_COMMAND=zsh \
    fm_test_run_spawn "$home" "$own" "$fakebin" own-ii9 --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch into the task's own recorded worktree should remain allowed"
  assert_contains "$out" 'spawned own-ii9' "the own-worktree relaunch did not report success"
  assert_not_contains "$out" 'is already claimed by task' \
    "the own-worktree relaunch treated its own metadata as a collision"
  pass "fm-spawn: durable canonical worktree claims refuse collisions, release retries, and leave free slots launchable"
}

# --- GUARD 1d: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
# The fake also models WINDOW LIVENESS, because retryability after a refused
# spawn is a real tmux state question: `new-window` records the created name,
# `kill-window` retires it, and `list-windows` answers from that set - so a
# spawn that leaves its window behind is refused by the same exact
# duplicate-name check real tmux enforces. FM_FAKE_TMUX_KILL_NOOP=1 makes
# kill-window a no-op, reproducing the best-effort close that reports success
# while the window survives.
# `display-message` deliberately succeeds for EVERY target, matching tmux 3.7b
# measured behavior: an absent window resolves by fnmatch, then by prefix, and
# otherwise falls back to the client's current window, exiting 0 either way -
# even for `=session:=window` or a session that does not exist. Any endpoint
# check that trusts it therefore reports a live sibling, so this fake makes
# that unsoundness observable instead of hiding it behind exact matching.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
FM_FAKE_TMUX_LIVE=\${FM_FAKE_TMUX_LIVE:-"$dir/live-windows"}
SH
  cat >> "$fakebin/tmux" <<'SH'
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
: >> "$FM_FAKE_TMUX_LIVE"

live_names() {
  local n
  for n in ${FM_FAKE_WINDOWS:-}; do printf '%s\n' "$n"; done
  cat "$FM_FAKE_TMUX_LIVE"
}

flag_value() {  # <flag> <args...>
  local want=$1 prev=
  shift
  for a in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s\n' "$a"; return 0; }
    prev=$a
  done
  return 1
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    name=$(flag_value -n "$@") || name=
    [ -z "$name" ] || printf '%s\n' "$name" >> "$FM_FAKE_TMUX_LIVE"
    printf '%s\n' "@spawnwid"; exit 0 ;;
  kill-window)
    if [ "${FM_FAKE_TMUX_KILL_NOOP:-0}" != 1 ]; then
      target=$(flag_value -t "$@") || target=
      name=${target#*:}
      name=${name#=}
      grep -vx "$name" "$FM_FAKE_TMUX_LIVE" > "$FM_FAKE_TMUX_LIVE.next" || true
      mv "$FM_FAKE_TMUX_LIVE.next" "$FM_FAKE_TMUX_LIVE"
    fi
    exit 0 ;;
  list-windows) live_names; exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  fm_test_spawn_brief "$home" "$id" brief
  FM_TMUX_REC="$rec" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

# A recording fake `zellij` for a full spawn drive-through. It models the two
# facts this guard depends on: `new-tab` registers a titled tab that
# `list-tabs` keeps returning, and `close-pane` does NOT remove the now-empty
# tab (verified real zellij behavior, recorded in bin/backends/zellij.sh's
# header) while `close-tab-by-id` does. FM_FAKE_ZJ_PANES_FAIL_AFTER_DUMPS makes
# `list-panes` start failing once worktree discovery has finished, reproducing
# the transient CLI failure that leaves the kill with no resolvable owning tab.
make_spawn_zellij_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/zellij" <<SH
#!/usr/bin/env bash
set -u
FM_FAKE_ZJ_STATE=\${FM_FAKE_ZJ_STATE:-"$dir/zjstate"}
SH
  cat >> "$fakebin/zellij" <<'SH'
mkdir -p "$FM_FAKE_ZJ_STATE"
tabs="$FM_FAKE_ZJ_STATE/tabs"
dumps="$FM_FAKE_ZJ_STATE/dumps"
: >> "$tabs"
[ -f "$dumps" ] || echo 0 > "$dumps"
[ -z "${FM_ZJ_REC:-}" ] || printf 'zellij %s\n' "$*" >> "$FM_ZJ_REC"

zj_flag_value() {  # <flag> <args...>
  local want=$1 prev= a
  shift
  for a in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s\n' "$a"; return 0; }
    prev=$a
  done
  return 1
}

zj_tabs_json() {
  local id name first=1
  printf '['
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    [ "$first" = 1 ] || printf ','
    printf '{"tab_id":%s,"name":"%s","active":false}' "$id" "$name"
    first=0
  done < "$tabs"
  printf ']\n'
}

case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) printf '%s\n' "${FM_FAKE_ZJ_SESSION:-firstmate}"; exit 0 ;;
  attach) exit 0 ;;
esac

case "${4:-}" in
  list-tabs) zj_tabs_json; exit 0 ;;
  new-tab)
    name=$(zj_flag_value --name "$@") || name=
    printf '4\t%s\n' "$name" >> "$tabs"
    printf '4\n'
    exit 0 ;;
  list-panes)
    [ "$(cat "$dumps")" -lt "${FM_FAKE_ZJ_PANES_FAIL_AFTER_DUMPS:-9999}" ] || exit 1
    printf '[{"id":7,"tab_id":4,"is_plugin":false}]\n'
    exit 0 ;;
  dump-screen)
    echo $(( $(cat "$dumps") + 1 )) > "$dumps"
    printf '%s\n%s\n%s\n' '__FM_ZELLIJ_CWD_BEGIN__' "${FM_FAKE_PANE_PATH:-}" '__FM_ZELLIJ_CWD_END__'
    exit 0 ;;
  close-tab-by-id)
    grep -v "^${5:-}$(printf '\t')" "$tabs" > "$tabs.next" || true
    mv "$tabs.next" "$tabs"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/zellij"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# The claim refusal must retire the endpoint it just created even when the
# backend's own pane->tab lookup transiently fails, because the leftover TAB -
# not the pane - is what refuses the retry. The spawn is holding the tab id it
# captured at create time, so the close has to carry it.
test_spawn_claim_cleanup_retires_the_zellij_tab() {
  local home proj claimed fakebin rec out status blocks
  home="$TMP_ROOT/spawn-zj-home"
  mkdir -p "$home/data" "$home/state"
  proj=$(make_repo "$TMP_ROOT/spawn-zj-proj")
  claimed="$TMP_ROOT/spawn-zj-wt"
  git -C "$proj" worktree add -q --detach "$claimed" >/dev/null 2>&1
  fakebin=$(make_spawn_zellij_fakebin "$TMP_ROOT/spawn-zj-fake")
  rec="$TMP_ROOT/spawn-zj.log"
  : > "$rec"
  {
    echo 'window=firstmate:9'
    echo "worktree=$claimed"
    echo "project=$proj"
    echo 'harness=codex'
    echo 'kind=ship'
    echo 'backend=zellij'
  } > "$home/state/zincumbent.meta"

  fm_test_spawn_brief "$home" zj-collide-kk1 brief
  out=$(FM_ZJ_REC="$rec" FM_FAKE_ZJ_PANES_FAIL_AFTER_DUMPS=2 \
    fm_test_run_spawn "$home" "$claimed" "$fakebin" \
      zj-collide-kk1 "$proj" codex --backend zellij --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a zellij spawn into a claimed worktree should refuse"
  assert_contains "$out" "claimed by task zincumbent" \
    "the zellij collision refusal did not name the owning record"
  assert_grep 'close-tab-by-id 4' "$rec" \
    "the claim cleanup must close the tab it created, using the tab id the spawn already holds"
  assert_no_grep 'close-pane' "$rec" \
    "closing only the pane leaves behind the empty tab that refuses the retry"
  assert_not_contains "$out" "survived the refusal" \
    "a fully retired zellij endpoint must not be reported as a survivor"

  # The retryability claim, read from the backend's own tab inventory through
  # the same predicate a fresh spawn is refused by.
  blocks=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE='' \
    bash -c '
      . "$0/bin/fm-backend.sh"
      if fm_backend_endpoint_blocks_respawn zellij firstmate:7 fm-zj-collide-kk1; then
        echo blocks=yes
      else
        echo blocks=no
      fi
    ' "$ROOT")
  assert_contains "$blocks" "blocks=no" \
    "the refused allocation must be retryable without manual cleanup"
  pass "fm-spawn: a claim refusal retires the zellij tab it created, even when the pane lookup fails"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_durable_worktree_claims
test_spawn_claim_cleanup_retires_the_zellij_tab
test_spawn_tmux_window_construction
