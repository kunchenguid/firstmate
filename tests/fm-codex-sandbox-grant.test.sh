#!/usr/bin/env bash
# tests/fm-codex-sandbox-grant.test.sh - the portable regression for the writable
# roots firstmate grants a codex crewmate, scout, or secondmate.
#
# codex is the only adapter firstmate launches inside a filesystem sandbox
# (-s workspace-write), which confines every shell command the worker runs to its
# own worktree. Three things the crewmate contract requires live outside it, so
# without a grant a codex worker cannot deliver a report, cannot append the status
# line supervision reads, cannot pass the captain-hold completion gate, and cannot
# even stage a commit in a linked worktree.
#
# This suite pins two independent halves with NO codex installed:
#   1. Composition: what fm-spawn actually puts on the launch command, per kind,
#      and that no other adapter's launch acquired a grant.
#   2. Sufficiency and necessity of that exact root set, proven by running the
#      REAL contract operations against a fixture home where everything outside
#      the roots fm-spawn just emitted is unwritable, then removing one root at a
#      time and asserting the matching operation fails.
#
# Half 2 is deliberately not a codex test: it proves the root SET is the right
# one. That codex's own sandbox honors --add-dir for exactly those roots is a
# harness-dependent fact, proven against the real binary by the live guard in
# tests/fm-codex-sandbox-grant-live-e2e.test.sh and recorded with dated evidence
# in docs/verification/codex-sandbox.md. Neither replaces the other.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CAPTAIN_HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-sandbox-grant)
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

# Fake tmux that answers the pane-path query and logs every send-keys payload,
# so the composed launch command is observable without launching anything.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A home plus a REAL project and REAL linked worktree, so the git common dir this
# suite reasons about is a genuine out-of-tree one rather than a fixture string.
make_case() {  # <name> -> home|proj|wt|fakebin|launchlog|id
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-t1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The roots the launch granted. The launch text is shell-quoted, so the roots are
# read back the way the pane's shell would read them.
granted_roots() {  # <launchlog>
  local line
  line=$(grep -F -- '--add-dir' "$1" | tail -1)
  [ -n "$line" ] || return 0
  printf '%s' "$line" | tr ' ' '\n' | grep -A1 -F -- '--add-dir' \
    | grep -v -F -- '--add-dir' | grep -v '^--$' | sed "s/^'//; s/'$//"
}

count_roots() { granted_roots "$1" | grep -c . || true; }

# --- 1. Composition ---------------------------------------------------------

test_ship_grants_only_its_own_state_files_and_out_of_tree_git_dir() {
  local rec out roots gitdir
  rec=$(make_case ship); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --mode no-mistakes --yolo off) \
    || fail "codex ship spawn failed: $out"

  gitdir=$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)
  roots=$(granted_roots "$LAUNCH_LOG")
  # A ship crewmate never runs the completion gate and writes no report, so it
  # gets only its OWN two per-task state files plus the out-of-tree git dir.
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/state/$CASE_ID.status" \
    || fail "the task's own status file was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/state/$CASE_ID.turn-ended" \
    || fail "the task's own turn-ended wake marker was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$gitdir" \
    || fail "the linked worktree's git common dir was not granted: $roots"
  [ "$(count_roots "$LAUNCH_LOG")" = 3 ] \
    || fail "expected exactly 3 granted roots, got: $roots"

  # The two granted state files must be pre-created so the single-file roots
  # resolve, and neither the shared state directory nor any other task's records
  # come with them.
  [ -f "$HOME_DIR/state/$CASE_ID.status" ] \
    || fail "the granted status file was not pre-created, so its single-file root cannot resolve"
  [ -f "$HOME_DIR/state/$CASE_ID.turn-ended" ] \
    || fail "the granted turn-ended file was not pre-created, so its single-file root cannot resolve"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/state" \
    && fail "a ship crewmate must NOT receive the shared state directory; only its own two files: $roots"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/data/$CASE_ID" \
    && fail "a ship crewmate writes no report, so it must not receive a data grant: $roots"

  # The grant is those paths and nothing wider: $FM_HOME itself stays denied,
  # which is what keeps .env, config/, and projects/ unwritable.
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR" \
    && fail "the firstmate home itself must never be granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/config" \
    && fail "config/ must never be granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/data" \
    && fail "the shared data/ root must never be granted: $roots"
  grep -q '__CODEXADDDIRS__' "$LAUNCH_LOG" \
    && fail "the placeholder leaked into the launch command"

  # The grant does not make codex able to drive the pipeline: its sandbox still
  # denies the no-mistakes data directory, so the dispatch says so out loud rather
  # than leaving it to be rediscovered at the gate. It must NOT assert the network
  # limit, which is the operator's own codex setting and varies per machine
  # (docs/verification/codex-sandbox.md).
  printf '%s\n' "$out" | grep -q 'cannot run validation itself' \
    || fail "a codex ship dispatch must name the pipeline limit the grant does not lift: $out"
  printf '%s\n' "$out" | grep -qE 'denies (ALL )?network|cannot push, open the PR' \
    && fail "the dispatch must not assert a network limit that depends on the operator's codex config: $out"
  pass "codex ship: grants only its own status + turn-ended files and the out-of-tree git common dir, never the shared state directory"
}

test_scout_grants_state_dir_data_and_out_of_tree_git_dir() {
  local rec out roots
  rec=$(make_case scout); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --scout) || fail "codex scout spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/data/$CASE_ID" \
    || fail "a scout cannot deliver data/<id>/report.md without its own data/<id>/ grant: $roots"
  # A scout runs the captain-hold completion gate, which creates a mktemp-named
  # lock owner directory and a lock symlink directly in state/, so it needs write
  # on the DIRECTORY - a per-file grant cannot serve those unnameable new entries.
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/state" \
    || fail "a scout cannot pass the completion gate without the state directory grant: $roots"
  printf '%s\n' "$roots" | grep -qxF "$HOME_DIR/data" \
    && fail "a scout must not receive the shared data/ root, only its own data/<id>/: $roots"
  pass "codex scout: the report, status, and completion-gate paths are all granted, and the shared data/ root is not"
}

test_secondmate_grants_only_the_parent_status_file() {
  local base prim sm smlog smfake roots out
  base="$TMP_ROOT/secondmate"
  prim="$base/primary"
  sm="$base/sm"
  mkdir -p "$prim/config" "$prim/data/sm-a" "$prim/state" "$prim/projects"
  printf '%s\n' "$$" > "$prim/state/.lock"
  touch "$prim/state/.last-watcher-beat"
  printf 'charter brief\n' > "$prim/data/sm-a/brief.md"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-a\n' > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  smlog="$base/launch.log"
  smfake=$(make_spawn_fakebin "$base/fake")
  : > "$smlog"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$smlog" PATH="$smfake:$PATH" \
    "$SPAWN" sm-a "$sm" codex --secondmate 2>&1) \
    || fail "codex secondmate spawn failed: $out"

  roots=$(granted_roots "$smlog")
  # A secondmate's own home IS its workspace, so only the parent status FILE it
  # reports through is outside the sandbox. Copying the crewmate grant here would
  # hand it the parent's data/ and git objects for no contract reason, and even
  # the parent's whole state/ would expose every sibling task's records.
  [ "$(count_roots "$smlog")" = 1 ] \
    || fail "a secondmate must get exactly the parent status file, got: $roots"
  printf '%s\n' "$roots" | grep -qxF "$prim/state/sm-a.status" \
    || fail "the parent status file was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$prim/state" \
    && fail "a secondmate must NOT receive the parent's whole state directory, only its own status file: $roots"
  [ -f "$prim/state/sm-a.status" ] \
    || fail "the granted parent status file was not pre-created, so its single-file root cannot resolve"
  pass "codex secondmate: only the parent status file is granted, not the parent state directory or the crewmate set"
}

test_other_adapters_are_untouched() {
  local rec out harness
  for harness in claude opencode grok; do
    rec=$(make_case "other-$harness"); read_case "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" "$PROJ_DIR" "$harness" --mode no-mistakes --yolo off) \
      || fail "$harness spawn failed: $out"
    grep -q -- '--add-dir' "$LAUNCH_LOG" \
      && fail "$harness's launch acquired a writable-root grant it never asked for"
    grep -q '__CODEXADDDIRS__' "$LAUNCH_LOG" \
      && fail "$harness's launch carries the codex placeholder"
    printf '%s\n' "$out" | grep -q 'cannot run validation itself' \
      && fail "$harness's dispatch inherited codex's sandbox notice"
  done
  pass "claude, opencode, and grok launches are unchanged"
}

# --- 2. Sufficiency and necessity of the granted set ------------------------

# Confine a fixture home the way codex's sandbox does, using the ONLY portable
# mechanism available with no codex installed: make every directory outside the
# granted roots unwritable. This cannot forbid appending to an already-writable
# file, so the assertions below turn on operations that CREATE something (a lock
# owner directory, a report, a git index lock) - exactly the operations that
# failed on 2026-08-26.
deny_outside_roots() {  # <home> <granted roots...>
  local home=$1 root
  shift
  chmod a-w "$home" "$home/config" "$home/projects" 2>/dev/null || true
  # The confinement must not have caught a granted root, or every assertion that
  # follows would be measuring the fixture instead of the grant.
  for root in "$@"; do
    [ -w "$root" ] || fail "the confinement denied a GRANTED root ($root); the fixture is wrong, not the grant"
  done
}

allow_all() { chmod -R u+w "$1" 2>/dev/null || true; }

# The necessity/isolation probes below prove a grant is load-bearing by removing
# the write bit from a path OUTSIDE the grant and asserting the write is then
# denied. That confinement is discretionary (chmod a-w), and UID 0 bypasses the
# discretionary write bit, so as root - which containerized CI commonly runs as -
# the "denied" write would instead succeed and trip the vacuity guard, failing a
# correct grant. Skip the negative probes when they cannot bind; the positive
# sufficiency assertions still run and are what prove the grant actually works.
dac_confines() { [ "$(id -u 2>/dev/null || echo 0)" -ne 0 ]; }

test_granted_set_is_sufficient_for_the_whole_contract() {
  local rec out roots status_file report gitdir
  rec=$(make_case sufficiency); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --scout) || fail "codex scout spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  gitdir=$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)
  status_file="$HOME_DIR/state/$CASE_ID.status"
  report="$HOME_DIR/data/$CASE_ID/report.md"

  # Seed the backlog BEFORE the confinement: firstmate owns backlog state, and a
  # crewmate only reads it through the completion gate.
  if command -v tasks-axi >/dev/null 2>&1; then
    cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml" || fail "could not seed the backlog config"
    ( cd "$HOME_DIR" && tasks-axi add "$CASE_ID" --title origin ) >/dev/null \
      || fail "could not seed the origin task"
    ( cd "$HOME_DIR" && tasks-axi add "$CASE_ID-call" --title call ) >/dev/null \
      || fail "could not seed the captain call"
    ( cd "$HOME_DIR" && tasks-axi hold "$CASE_ID-call" --reason "captain call" --kind captain ) >/dev/null \
      || fail "could not hold the captain call"
  fi

  # shellcheck disable=SC2086 # roots is a newline list of paths without spaces here.
  deny_outside_roots "$HOME_DIR" $roots

  echo "working: setup done" >> "$status_file" \
    || fail "a status append must survive the confinement"
  printf '# report\n' > "$report" \
    || fail "the scout report must be creatable under the granted data root"
  ( cd "$WT_DIR" && echo change > delivered.txt && git add delivered.txt \
      && git -c user.email=t@t -c user.name=t commit -qm "delivered" ) \
    || fail "a commit in the linked worktree must survive the confinement"
  [ "$(git -C "$WT_DIR" log --oneline -1 --format=%s)" = delivered ] \
    || fail "the commit did not land"

  if command -v tasks-axi >/dev/null 2>&1; then
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      "$CAPTAIN_HOLD" complete "$CASE_ID" "${CASE_ID}-call" 2>&1) \
      || fail "the captain-hold completion gate must survive the confinement: $out"
    pass "granted set is sufficient: status append, report, captain-hold completion gate, and commit all succeed"
  else
    pass "granted set is sufficient: status append, report, and commit all succeed (captain-hold gate skipped: tasks-axi not found)"
  fi
  allow_all "$HOME_DIR"
}

test_each_root_is_load_bearing() {
  local rec out roots report
  rec=$(make_case necessity); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --scout) || fail "codex scout spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  report="$HOME_DIR/data/$CASE_ID/report.md"

  printf '%s\n' "$roots" | grep -qc . >/dev/null \
    || fail "no roots were granted at all"

  if ! dac_confines; then
    pass "each granted root is load-bearing: negative confinement probes skipped as root (DAC write bits do not restrain UID 0)"
    return
  fi

  # The data root: without it the report cannot be created at all, which is the
  # exact 2026-08-26 loss (a finished report with nowhere to land).
  chmod a-w "$HOME_DIR/data/$CASE_ID"
  if ( exec 2>/dev/null; printf '# report\n' > "$report" ); then
    chmod -R u+w "$HOME_DIR/data"
    fail "the data root is not load-bearing in this fixture; the necessity assertion is vacuous"
  fi
  chmod -R u+w "$HOME_DIR/data"

  # The state root: the completion gate's lock owner directory is mktemp-named,
  # so it needs the DIRECTORY, which is why a per-file grant cannot serve it.
  chmod a-w "$HOME_DIR/state"
  if ( cd "$HOME_DIR/state" && mktemp -d ".meta-$CASE_ID.lock.owner.XXXXXX" ) >/dev/null 2>&1; then
    chmod -R u+w "$HOME_DIR/state"
    fail "the state root is not load-bearing in this fixture; the necessity assertion is vacuous"
  fi
  chmod -R u+w "$HOME_DIR/state"

  # The git common dir: with it denied, staging fails before any commit does.
  chmod -R a-w "$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)"
  if ( cd "$WT_DIR" && echo x > staged.txt && git add staged.txt ) >/dev/null 2>&1; then
    chmod -R u+w "$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)"
    fail "the git common dir is not load-bearing in this fixture; the necessity assertion is vacuous"
  fi
  chmod -R u+w "$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)"

  pass "each granted root is load-bearing: removing it breaks the report, the completion-gate lock, or staging"
}

# A ship crewmate's grant is its two per-task state FILES plus the git dir. Prove
# that set carries the whole ship contract (status append, turn-ended touch,
# commit) while the shared state directory - every OTHER task's records - stays
# unwritable, which is the isolation the per-file grant buys over granting state/.
test_ship_grant_is_sufficient_and_isolates_siblings() {
  local rec out roots status_file turnend_file
  rec=$(make_case ship-suff); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --mode no-mistakes --yolo off) \
    || fail "codex ship spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  status_file="$HOME_DIR/state/$CASE_ID.status"
  turnend_file="$HOME_DIR/state/$CASE_ID.turn-ended"

  # Deny everything the ship grant did NOT name, including the state directory
  # itself, then confirm the two granted files survive.
  chmod a-w "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/state" 2>/dev/null || true
  [ -w "$status_file" ] || fail "the confinement denied the GRANTED status file; the fixture is wrong, not the grant"
  [ -w "$turnend_file" ] || fail "the confinement denied the GRANTED turn-ended file; the fixture is wrong, not the grant"

  echo "working: setup done" >> "$status_file" \
    || fail "a ship status append must survive with only the status-file grant"
  touch "$turnend_file" \
    || fail "the codex notify turn-ended touch must survive with only the turn-ended-file grant"
  ( cd "$WT_DIR" && echo change > delivered.txt && git add delivered.txt \
      && git -c user.email=t@t -c user.name=t commit -qm "delivered" ) \
    || fail "a commit in the linked worktree must survive the confinement"
  [ "$(git -C "$WT_DIR" log --oneline -1 --format=%s)" = delivered ] \
    || fail "the commit did not land"

  # Isolation: with state/ denied, a mistaken command targeting ANOTHER task's
  # records (a new file in state/) fails - exactly what granting state/ would have
  # allowed and what Greptile flagged. This is a discretionary-write-bit probe, so
  # it only binds off root (UID 0 bypasses the write bit).
  if dac_confines && ( exec 2>/dev/null; echo x > "$HOME_DIR/state/sibling.status" ); then
    chmod -R u+w "$HOME_DIR"
    fail "the ship grant let a worker create a sibling task record in state/; the per-file grant is not isolating"
  fi
  chmod -R u+w "$HOME_DIR"
  pass "ship grant is sufficient (status, turn-ended, commit) and isolates siblings: the shared state directory stays unwritable"
}

test_ship_grants_only_its_own_state_files_and_out_of_tree_git_dir
test_scout_grants_state_dir_data_and_out_of_tree_git_dir
test_secondmate_grants_only_the_parent_status_file
test_other_adapters_are_untouched
test_ship_grant_is_sufficient_and_isolates_siblings
test_granted_set_is_sufficient_for_the_whole_contract
test_each_root_is_load_bearing
