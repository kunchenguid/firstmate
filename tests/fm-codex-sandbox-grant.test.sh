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

# The comparison bin/fm-watch.sh scan_signals makes for one signal file, run
# through the library that owns it rather than reimplemented here.
signal_reads_as_reported() {  # <state> <signal file>
  ( . "$ROOT/bin/fm-wake-lib.sh" && fm_wake_signal_seen_current "$1" "$2" )
}

# Enqueue one steer the way firstmate does. Firstmate is not sandboxed, so this
# is always the unconfined side; the record format belongs to its own library.
enqueue_steer() {  # <state> <task id> <text>
  ( . "$ROOT/bin/fm-task-inbox-lib.sh" && fm_task_inbox_write "$1" "$2" "$3" ) >/dev/null
}

# The physically-resolved spelling of a path, computed here independently of
# fm-spawn: codex resolves a writable root through its symlinks, and so does the
# notify hook's own turn-ended path, so a root spelled through a symlinked home
# names a path the worker never actually writes.
canonical_of() {  # <path>
  local p=$1 parent
  if [ -d "$p" ]; then ( cd "$p" && pwd -P ); return; fi
  parent=$(cd "$(dirname "$p")" && pwd -P) || return 1
  printf '%s/%s\n' "${parent%/}" "$(basename "$p")"
}

# --- 1. Composition ---------------------------------------------------------

test_ship_grants_only_its_own_state_files_and_out_of_tree_git_dir() {
  local rec out roots gitdir state_real home_real data_real r forbidden
  rec=$(make_case ship); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --mode no-mistakes --yolo off) \
    || fail "codex ship spawn failed: $out"

  gitdir=$(cd "$(git -C "$WT_DIR" rev-parse --git-common-dir)" && pwd -P)
  home_real=$(cd "$HOME_DIR" && pwd -P)
  state_real="$home_real/state"
  data_real="$home_real/data"
  roots=$(granted_roots "$LAUNCH_LOG")
  # A ship crewmate never runs the completion gate and writes no report, so the
  # only paths it gets outside its worktree are its OWN two per-task state files,
  # its OWN steering inbox, and the out-of-tree git dir.
  printf '%s\n' "$roots" | grep -qxF "$state_real/$CASE_ID.status" \
    || fail "the task's own status file was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$state_real/$CASE_ID.turn-ended" \
    || fail "the task's own turn-ended wake marker was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$state_real/$CASE_ID.inbox" \
    || fail "the task's own steering inbox was not granted, so the worker cannot acknowledge a steer: $roots"
  printf '%s\n' "$roots" | grep -qxF "$gitdir" \
    || fail "the linked worktree's git common dir was not granted: $roots"
  [ "$(count_roots "$LAUNCH_LOG")" = 4 ] \
    || fail "expected exactly 4 granted roots, got: $roots"

  # Every root must be spelled the way the sandbox and the launch's own notify
  # hook resolve it, or the grant names a path the worker never writes.
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$r" = "$(canonical_of "$r")" ] \
      || fail "granted root is not canonicalized, so it names a path the sandbox never resolves to: $r"
  done <<EOF
$roots
EOF
  grep -qF -- "--add-dir '$state_real/$CASE_ID.turn-ended'" "$LAUNCH_LOG" \
    || fail "the granted turn-ended root does not match the canonical spelling the notify hook touches"

  # The two granted state files and the inbox (with its handled/ subdirectory)
  # must be pre-created so the roots resolve, and neither the shared state
  # directory nor any other task's records come with them.
  [ -f "$HOME_DIR/state/$CASE_ID.status" ] \
    || fail "the granted status file was not pre-created, so its single-file root cannot resolve"
  [ -f "$HOME_DIR/state/$CASE_ID.turn-ended" ] \
    || fail "the granted turn-ended file was not pre-created, so its single-file root cannot resolve"
  [ -d "$HOME_DIR/state/$CASE_ID.inbox/handled" ] \
    || fail "the granted inbox and its handled/ were not pre-created, so the acknowledgement move has nowhere to land"
  # The isolation half of the per-kind scoping, and the only assertions that
  # prove it. Every forbidden path is spelled CANONICALLY, because the emitted
  # roots are: comparing a $TMPDIR-spelled path against a /private-resolved root
  # would make each of these guards unfireable on macOS, which is the platform of
  # record in docs/verification/codex-sandbox.md, and they would pass while the
  # grant leaked exactly what they forbid.
  [ "$state_real" = "$(canonical_of "$HOME_DIR/state")" ] \
    || fail "the forbidden-path spellings are not canonical, so the isolation guards below cannot fire"
  for forbidden in \
    "$state_real:a ship crewmate must NOT receive the shared state directory; only its own per-task paths" \
    "$data_real/$CASE_ID:a ship crewmate writes no report, so it must not receive a data grant" \
    "$data_real:the shared data/ root must never be granted" \
    "$home_real:the firstmate home itself must never be granted" \
    "$home_real/config:config/ must never be granted" \
    "$home_real/projects:projects/ must never be granted" \
    "$state_real/sibling-task.status:a ship root reaches a SIBLING task's status file" \
    "$state_real/sibling-task.inbox:a ship root reaches a SIBLING task's steering inbox"
  do
    printf '%s\n' "$roots" | grep -qxF "${forbidden%%:*}" \
      && fail "${forbidden#*:}: $roots"
  done
  grep -q '__CODEXADDDIRS__' "$LAUNCH_LOG" \
    && fail "the placeholder leaked into the launch command"

  # The grant does not make codex able to drive the pipeline: its sandbox still
  # denies the no-mistakes data directory, so the dispatch says so out loud rather
  # than leaving it to be rediscovered at the gate. It must NOT assert a network
  # limit, because the launch itself grants network access unconditionally
  # (docs/verification/codex-sandbox.md).
  printf '%s\n' "$out" | grep -q 'cannot run validation itself' \
    || fail "a codex ship dispatch must name the pipeline limit the grant does not lift: $out"
  printf '%s\n' "$out" | grep -qE 'denies (ALL )?network|cannot push, open the PR|depends on this machine' \
    && fail "the dispatch must not assert a network limit the launch's own network_access grant lifts: $out"
  grep -qF -- '-c sandbox_workspace_write.network_access=true' "$LAUNCH_LOG" \
    || fail "the dispatch claims no network limit, so the launch must actually grant network access"
  pass "codex ship: grants only its own status + turn-ended files, its own steering inbox, and the out-of-tree git common dir, never the shared state directory"
}

# The dispatch notice names the ONE thing no writable root gives back: the
# no-mistakes data directory. Only a no-mistakes brief needs it. A direct-PR brief
# says "Do NOT run /no-mistakes" and completes by pushing and opening the PR
# itself (bin/fm-dod-lib.sh), which the git and network grants already cover, so
# firing the notice there would tell the captain to expect a landing problem for a
# task codex can finish end to end.
test_pipeline_notice_fires_only_for_the_mode_that_needs_the_pipeline() {
  local rec out mode
  for mode in no-mistakes direct-PR local-only; do
    rec=$(make_case "notice-$mode"); read_case "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" "$PROJ_DIR" codex --mode "$mode" --yolo off) \
      || fail "codex ship spawn failed for mode=$mode: $out"
    if [ "$mode" = no-mistakes ]; then
      printf '%s\n' "$out" | grep -q 'cannot run validation itself' \
        || fail "a codex no-mistakes dispatch must name the pipeline limit the grant does not lift: $out"
    else
      printf '%s\n' "$out" | grep -q 'cannot run validation itself' \
        && fail "mode=$mode does not run the pipeline, so the dispatch must not claim it cannot: $out"
    fi
    # The grant itself is mode-independent: narrowing the notice must not have
    # narrowed what the worker can write.
    [ "$(count_roots "$LAUNCH_LOG")" = 4 ] \
      || fail "mode=$mode did not get the same four ship roots: $(granted_roots "$LAUNCH_LOG")"
  done
  pass "the no-mistakes pipeline notice fires for no-mistakes alone, and every mode gets the same ship grant"
}

# EVERY file the grant pre-creates so a single-file root can resolve becomes a
# brand-new signal file for the watcher's own scan: bin/fm-watch.sh scan_signals
# reports any status file or turn-end marker whose signature differs from its
# persisted state/.seen-* one, and codex has no verified semantic busy source that
# could absorb the resulting wake. So the spawn must mark each one as already
# reported, narrowly enough that REAL later activity still reports. This covers
# both pre-created files together, because the defect is a property of
# pre-creation rather than of either file.
test_precreated_state_files_are_not_read_as_new_activity() {
  local rec out f label
  rec=$(make_case precreate-seed); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --mode no-mistakes --yolo off) \
    || fail "codex ship spawn failed: $out"

  for label in status turn-ended; do
    f="$HOME_DIR/state/$CASE_ID.$label"
    [ -f "$f" ] || fail "the $label file was not pre-created, so its single-file root cannot resolve"
    # A false here is exactly the row the watcher's scan would emit.
    signal_reads_as_reported "$HOME_DIR/state" "$f" \
      || fail "the pre-created $label file reads as unreported, so the first watcher poll wakes the captain for activity nobody produced"
  done

  # Not vacuous: marking must record each file AS CREATED, not suppress it
  # forever. Real later activity changes the signature and must report again.
  printf 'working: real line\n' >> "$HOME_DIR/state/$CASE_ID.status"
  signal_reads_as_reported "$HOME_DIR/state" "$HOME_DIR/state/$CASE_ID.status" \
    && fail "the seeded status marker also suppresses a REAL status append; the mark is too broad"
  printf 'x' >> "$HOME_DIR/state/$CASE_ID.turn-ended"
  signal_reads_as_reported "$HOME_DIR/state" "$HOME_DIR/state/$CASE_ID.turn-ended" \
    && fail "the seeded turn-ended marker also suppresses a REAL turn end; the mark is too broad"
  pass "both pre-created state files are marked as already reported, and real later activity on each still reports"
}

test_scout_grants_state_dir_data_and_out_of_tree_git_dir() {
  local rec out roots data_real state_real
  rec=$(make_case scout); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --scout) || fail "codex scout spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  data_real=$(cd "$HOME_DIR/data" && pwd -P)
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  printf '%s\n' "$roots" | grep -qxF "$data_real/$CASE_ID" \
    || fail "a scout cannot deliver data/<id>/report.md without its own data/<id>/ grant: $roots"
  # A scout runs the captain-hold completion gate, which creates a mktemp-named
  # lock owner directory and a lock symlink directly in state/, so it needs write
  # on the DIRECTORY - a per-file grant cannot serve those unnameable new entries.
  # That same directory root is what covers its steering inbox, so a scout needs
  # no separate inbox grant.
  printf '%s\n' "$roots" | grep -qxF "$state_real" \
    || fail "a scout cannot pass the completion gate without the state directory grant: $roots"
  printf '%s\n' "$roots" | grep -qxF "$data_real" \
    && fail "a scout must not receive the shared data/ root, only its own data/<id>/: $roots"
  pass "codex scout: the report, status, and completion-gate paths are all granted, and the shared data/ root is not"
}

test_secondmate_grants_only_the_parent_status_file() {
  local base prim sm smlog smfake roots out prim_state_real
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
  prim_state_real=$(cd "$prim/state" && pwd -P)
  # A secondmate's own home IS its workspace, so the only paths outside the
  # sandbox are the parent status FILE it reports through and the parent-side
  # steering inbox it acknowledges in. Copying the crewmate grant here would hand
  # it the parent's data/ and git objects for no contract reason, and even the
  # parent's whole state/ would expose every sibling task's records.
  [ "$(count_roots "$smlog")" = 2 ] \
    || fail "a secondmate must get exactly the parent status file and its own inbox, got: $roots"
  printf '%s\n' "$roots" | grep -qxF "$prim_state_real/sm-a.status" \
    || fail "the parent status file was not granted: $roots"
  printf '%s\n' "$roots" | grep -qxF "$prim_state_real/sm-a.inbox" \
    || fail "the secondmate's steering inbox was not granted, so it cannot acknowledge a steer: $roots"
  printf '%s\n' "$roots" | grep -qxF "$prim_state_real" \
    && fail "a secondmate must NOT receive the parent's whole state directory, only its own status file and inbox: $roots"
  [ -f "$prim/state/sm-a.status" ] \
    || fail "the granted parent status file was not pre-created, so its single-file root cannot resolve"
  [ -d "$prim/state/sm-a.inbox/handled" ] \
    || fail "the granted inbox and its handled/ were not pre-created, so the acknowledgement move has nowhere to land"
  pass "codex secondmate: only the parent status file and its own steering inbox are granted, not the parent state directory or the crewmate set"
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

# The same confinement narrowed to state/: deny write on every directory under it
# that the grant did NOT name, which is how this fixture expresses "outside the
# sandbox's writable roots" for a kind whose state grant is per-path rather than
# the whole directory. Driven off the roots fm-spawn emitted, never a retyped list.
deny_state_dirs_outside_roots() {  # <canonical state dir> <granted roots...>
  local state=$1 d granted keep
  shift
  while IFS= read -r d; do
    keep=0
    for granted in "$@"; do
      case "$d/" in "$granted"/*) keep=1; break ;; esac
    done
    [ "$keep" -eq 1 ] || chmod a-w "$d" 2>/dev/null || true
  done < <(find "$state" -type d | sort -r)
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

# The steering-inbox acknowledgement is part of EVERY brief kind (bin/fm-brief.sh
# builds one INBOX_SECTION for all of them): the worker acknowledges a handled
# steer by moving the record into state/<id>.inbox/handled/, and firstmate's
# re-ring ladder escalates a worker that never acknowledges as stuck. That move
# needs write on the inbox directory, which lives outside the worktree, so a ship
# crewmate whose grant stopped at its two state FILES would be structurally unable
# to comply - the same shape as the 2026-08-26 defect this grant exists for.
test_ship_grant_covers_the_steering_inbox_acknowledgement() {
  local rec out roots inbox msg state_real
  rec=$(make_case ship-inbox); read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" codex --mode no-mistakes --yolo off) \
    || fail "codex ship spawn failed: $out"
  roots=$(granted_roots "$LAUNCH_LOG")
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  inbox="$state_real/$CASE_ID.inbox"

  # Firstmate writes the steer, and firstmate is not sandboxed, so this happens
  # before the confinement. The record format belongs to its own library.
  enqueue_steer "$HOME_DIR/state" "$CASE_ID" "steer: read the failing log first" \
    || fail "could not enqueue a steering message"
  msg=$(find "$inbox" -maxdepth 1 -name '*.msg' | head -1)
  [ -n "$msg" ] || fail "the steering message was not enqueued"

  # shellcheck disable=SC2086 # roots is a newline list of paths without spaces here.
  deny_state_dirs_outside_roots "$state_real" $roots
  mv "$msg" "$inbox/handled/" \
    || { allow_all "$HOME_DIR"; fail "a ship crewmate could not acknowledge a steer under its own grant"; }
  [ -f "$inbox/handled/$(basename "$msg")" ] \
    || { allow_all "$HOME_DIR"; fail "the acknowledgement move did not land in handled/"; }
  allow_all "$HOME_DIR"

  if dac_confines; then
    # Necessity: with the inbox root removed from the grant, the acknowledgement
    # is exactly the operation that breaks.
    enqueue_steer "$HOME_DIR/state" "$CASE_ID" "steer: second instruction" \
      || fail "could not enqueue a second steering message"
    msg=$(find "$inbox" -maxdepth 1 -name '*.msg' | head -1)
    chmod a-w "$inbox" "$inbox/handled"
    if ( exec 2>/dev/null; mv "$msg" "$inbox/handled/" ); then
      allow_all "$HOME_DIR"
      fail "the inbox root is not load-bearing in this fixture; the necessity assertion is vacuous"
    fi
    allow_all "$HOME_DIR"
  fi
  pass "ship grant covers the steering-inbox acknowledgement, and that inbox root is load-bearing"
}

test_ship_grants_only_its_own_state_files_and_out_of_tree_git_dir
test_pipeline_notice_fires_only_for_the_mode_that_needs_the_pipeline
test_precreated_state_files_are_not_read_as_new_activity
test_scout_grants_state_dir_data_and_out_of_tree_git_dir
test_secondmate_grants_only_the_parent_status_file
test_other_adapters_are_untouched
test_ship_grant_is_sufficient_and_isolates_siblings
test_ship_grant_covers_the_steering_inbox_acknowledgement
test_granted_set_is_sufficient_for_the_whole_contract
test_each_root_is_load_bearing
