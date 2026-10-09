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
  # shellcheck disable=SC2016 # The generated instruction keeps the stamp literal.
  assert_grep 'blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree' "$brief" \
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
  # The assertions concern identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$fakebin"
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  # The non-git case must BE non-git wherever this suite runs. A directory under
  # TMPDIR is not one when TMPDIR itself sits inside a git repository - git walks
  # up and finds that repo, and the spawn reports the subdirectory cause instead.
  # GIT_CEILING_DIRECTORIES stops that upward walk: git does not chdir up into a
  # listed directory, though it never excludes the directory being searched, so
  # the ceiling is the PARENT of the path handed to the spawn (git(1),
  # "GIT_CEILING_DIRECTORIES").
  mkdir -p "$TMP_ROOT/spawn-notgit-root/plain" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  # The discovery poll screens every candidate with the isolation conditions, so
  # a path like this is never adopted and the refusal comes from the poll's own
  # deadline, naming the path and why it was rejected. The assertions pin which
  # cause fired, not the operator wording that explains it.
  out=$(GIT_CEILING_DIRECTORIES="$TMP_ROOT/spawn-notgit-root" \
    run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit-root/plain" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_contains "$out" "not inside a git worktree" "non-worktree spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "primary-checkout spawn lacked the isolation error"
  assert_contains "$out" "not a worktree root" "primary-checkout spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-primary-ee5.meta" "aborted spawn must not record meta"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1b': foreign-repository checkout ---------------------------------

# The isolation conditions must reject a checkout of a DIFFERENT repository,
# not just the spawning project's own paths. This is the 2026-09-29 leak shape:
# on WSL a brand-new window's pane read transiently reported firstmate's own
# checkout - a real, clean worktree root of an unrelated repository - during a
# spawn of another project; the adopted path passed a comparison that only
# knew the spawning project, and the task's claude hooks plus a fetch+reset
# base refresh landed in the primary checkout's .claude and git metadata.
test_spawn_isolation_foreign_repo_abort() {
  local home proj foreign fakebin out status
  home="$TMP_ROOT/spawn-foreign-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-foreign-proj")
  foreign=$(make_repo "$TMP_ROOT/spawn-foreign-wt")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-foreign-fake")
  fm_test_fake_sleep_noop "$fakebin"

  # Abort: the pane resolves to the root checkout of an unrelated repository.
  out=$(run_spawn "$home" abort-foreign-repo-hh8 "$proj" "$foreign" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into another repository's checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "foreign-repo spawn lacked the isolation error"
  assert_contains "$out" "checkout of a different repository" "foreign-repo spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-foreign-repo-hh8.meta" "aborted foreign-repo spawn must not record meta"

  pass "fm-spawn: aborts when the resolved worktree belongs to a different repository"
}

# --- GUARD 1b'': own-checkout identity refusal -------------------------------

# The isolation conditions now refuse foreign-repository checkouts, but the one
# directory whose pollution is fleet-wide - firstmate's own running checkout -
# also carries a second, independent identity refusal
# (spawn_assert_worktree_not_own_root) ahead of any task wiring. The only path
# that reaches it is a worktree that IS a legitimate linked worktree of the
# spawning project while also being the directory firstmate runs from, so this
# stages exactly that shape: FM_ROOT_OVERRIDE adopts a linked worktree of the
# project and the pane reports that same worktree. On the 2026-09-29 leak the
# claude-hook quartet for a dead task landed in that checkout's
# .claude/settings.local.json, and the leak's other half was a fetch+reset base
# refresh into its git metadata. The refusal alone is not the contract: nothing
# the spawn does below that point may touch the checkout either, so the fixture
# stages a base refresh that WOULD move HEAD (origin's default advanced past
# the checkout) and settings the wiring WOULD merge into, then fingerprints the
# whole checkout before the spawn and requires it identical after.

# checkout_fingerprint <dir>: path+content fingerprint of every regular file in
# a work tree, .git aside. Task wiring lands as files (claude hooks, settings,
# plugins), so a write anywhere in the checkout changes it.
checkout_fingerprint() { # <dir>
  (cd "$1" && find . -name .git -prune -o -type f -exec cksum {} + | LC_ALL=C sort)
}

test_spawn_own_root_identity_abort() {
  local home proj ownroot fakebin config settings excl fetch_head
  local head_before origin_main status_before tree_before excl_before out status
  home="$TMP_ROOT/spawn-ownroot-home"
  mkdir -p "$home/data" "$home/user-home"
  proj=$(make_repo "$TMP_ROOT/spawn-ownroot-proj")
  ownroot="$TMP_ROOT/spawn-ownroot-fm"
  git -C "$proj" worktree add -q --detach "$ownroot" >/dev/null 2>&1
  # Early spawn phases call $FM_ROOT/bin tools; keep them resolvable.
  ln -s "$ROOT/bin" "$ownroot/bin"
  # The running checkout already carries local settings of its own; the leak
  # MERGED the claude-hook quartet into a file like this, so the fixture starts
  # from one rather than from its absence.
  settings="$ownroot/.claude/settings.local.json"
  mkdir -p "$ownroot/.claude"
  printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git diff:*)"\n    ]\n  }\n}\n' > "$settings"
  # Keep the fixture invisible to the freshen cleanliness check: info/exclude
  # resolves through the common git dir even for a linked worktree.
  excl=$(git -C "$ownroot" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$excl")"
  printf 'bin\n.claude/\n' >> "$excl"
  # Advance origin's default branch past the checkout's detached HEAD. The
  # worktree shares the project's origin through the common config, so an
  # unguarded base refresh here would fetch and reset --hard onto that commit -
  # at the same commit as HEAD, a refresh leaves nothing a HEAD comparison
  # could catch. FETCH_HEAD is per-worktree, so it names the fetch alone.
  git -C "$proj" commit -q --allow-empty -m advance-origin-default
  git -C "$proj" push -q origin main
  fetch_head=$(git -C "$ownroot" rev-parse --git-path FETCH_HEAD)
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-ownroot-fake" claude)
  fm_test_fake_sleep_noop "$fakebin"
  config="$TMP_ROOT/spawn-ownroot-claude"
  mkdir -p "$config"
  fm_test_spawn_brief "$home" ownroot-ii9

  head_before=$(git -C "$ownroot" rev-parse HEAD)
  origin_main=$(git -C "$ownroot" rev-parse --verify --quiet origin/main 2>/dev/null || true)
  assert_not_equals "" "$origin_main" "fixture must expose origin's default branch to the worktree, else the refresh path never runs"
  assert_not_equals "$head_before" "$origin_main" \
    "fixture must stage origin's default ahead of the checkout, else a base refresh here cannot move HEAD"
  status_before=$(git -C "$ownroot" -c core.quotePath=false status --porcelain)
  assert_equals "" "$status_before" "fixture checkout must start clean, else the refusal could be blamed on dirt"
  tree_before=$(checkout_fingerprint "$ownroot")
  excl_before=$(cksum <"$excl")

  # fm_test_run_spawn pins FM_ROOT_OVERRIDE empty, so this inlines its env with
  # FM_ROOT_OVERRIDE naming the pane-reported worktree.
  out=$(FM_ROOT_OVERRIDE="$ownroot" FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR="$config" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$ownroot" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" ownroot-ii9 "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn adopting firstmate own checkout should abort"
  assert_contains "$out" "firstmate's own checkout" "own-root spawn lacked the identity refusal"
  assert_absent "$home/state/ownroot-ii9.meta" "aborted own-root spawn must not record meta"
  assert_equals "$head_before" "$(git -C "$ownroot" rev-parse HEAD)" \
    "a base refresh ran on firstmate's own checkout: HEAD moved toward origin's advanced default"
  assert_absent "$fetch_head" "the spawn fetched inside firstmate's own checkout before refusing"
  assert_equals "$status_before" "$(git -C "$ownroot" -c core.quotePath=false status --porcelain)" \
    "the spawn left firstmate's own checkout dirtier than it started"
  assert_equals "$tree_before" "$(checkout_fingerprint "$ownroot")" \
    "the spawn wrote task wiring into firstmate's own checkout"
  assert_no_grep "UserPromptSubmit" "$settings" \
    "own-root spawn leaked the claude-hook quartet into the running checkout's settings"
  assert_equals "$excl_before" "$(cksum <"$excl")" \
    "the spawn appended task excludes to the shared info/exclude of the running checkout"
  pass "fm-spawn: refuses before any base refresh or task wiring when the resolved worktree is firstmate's own checkout"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

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
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
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

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_isolation_foreign_repo_abort
test_spawn_own_root_identity_abort
test_spawn_tmux_window_construction
