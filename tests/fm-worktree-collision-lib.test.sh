#!/usr/bin/env bash
# tests/fm-worktree-collision-lib.test.sh - the worktree double-registration
# guard owned by bin/fm-worktree-collision-lib.sh and surfaced by
# bin/fm-bootstrap.sh's WORKTREE_COLLISION line.
#
# The gap under test: firstmate hands each task a pooled worktree, and nothing
# detects two state/*.meta records claiming the same worktree= path. That is
# quiet and expensive - a commit can land on the wrong task's branch, or a
# teardown can return a copy another task still needs.
#
# The guarantees under test:
#   - fm_worktree_collision_path_state judges the SHARED PATH once from git
#     alone, and separates a probe's answer from a probe that could not answer.
#     `missing`, `landed`, and `unlanded` are reserved for probes that actually
#     ran; every unanswerable probe collapses into one `unverifiable:<cause>`
#     verdict that names which probe failed and keeps the do-not-discard force.
#     A failed probe never reaches `landed` or `missing` (falsely reassuring)
#     and never claims `unlanded` work it did not see (falsely alarming).
#     `landed` is earned only against the PUBLISHED default branch: work
#     merged into a local default branch that was pushed nowhere is not
#     proven safe to reclaim, so it never drops the do-not-discard caveat.
#   - fm_worktree_collision_claimant_process judges ONE claimant from its own
#     recorded backend endpoint alone and passes the backend's own verdict
#     through, so the printed detail never blames a backend that answered.
#     Only dead/missing are non-hazards. The path's content never makes a dead
#     record look hazardous, and a dead record's own detail never claims work
#     that belongs to a live sibling.
#   - fm_worktree_collision_lines groups state/*.meta by worktree=, reports
#     only paths claimed by 2+ records, names every claimant, and marks the
#     collision `live` only when 2+ claimants' processes are still hazardous -
#     one live task plus a finished task's stale leftover record is `stale`,
#     not `live`, even when the shared worktree holds the live task's own
#     uncommitted work. That work is then reported once as a path-level
#     caveat, so a leftover record is never cleaned up blind - including when
#     every claimant's process is gone, where the caveat is the only thing
#     keeping the hazard from going silent.
#   - Path state never decides the kind and never withholds a line: every
#     colliding path prints exactly one line, an unverifiable process stays a
#     hazard even over a path that no longer exists, and every path that is not
#     proven landed states its own risk as a caveat on either kind instead of
#     being passed over in silence.
#   - Only LOCAL records are grouped: a record carrying remote_host= names a
#     path on another machine, so it can never collide with a local worktree.
#   - A path claimed by exactly one record never produces a line, and neither
#     does a path whose second record is torn down mid-scan - the collision has
#     resolved itself, so the vanished record is dropped rather than named.
#   - Grouping is by the physically resolved path, so two spellings of one
#     pooled copy still collide, and the transport survives any character a
#     recorded path or a resolved key can hold - a backslash never empties the
#     claimant list, a tab never drops the line, a newline never truncates one.
#     The key encoding is injective, so a copy whose name holds a real newline
#     and a different copy whose name holds a literal backslash-n never merge
#     into one line naming records that claim neither, and a copy whose name
#     ends in a newline is named as itself rather than resolved away to a
#     shorter path that is not there.
#   - The line separates what grouping proved from what each record says: the
#     path after the kind is the resolved copy the claimants share, and every
#     claimant names the worktree= its own record actually contains, so no one
#     spelling is ever printed as though every claimant recorded it.
#   - `unlanded` means the task's OWN work: firstmate's spawn-written
#     scaffolding is filtered exactly as bin/fm-teardown.sh filters it before
#     deciding whether a copy is safe to discard.
#   - bin/fm-bootstrap.sh surfaces the same line and stays silent on a clean
#     home, matching every other detect-only bootstrap check's contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"
# shellcheck source=bin/fm-worktree-collision-lib.sh
. "$ROOT/bin/fm-worktree-collision-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-worktree-collision)
fm_git_identity fmtest fmtest@example.invalid

# A fake tmux with two sessions: `livesess` has a window `alive` whose
# foreground command classifies as a verified harness (agent state: alive),
# and a window `ambig` whose foreground command is an ordinary process the
# classifier cannot place (agent state: ambiguous). Any other session reports
# a clean "no such session" failure (agent state: missing). No real tty/ps
# reads are involved - fm_backend_tmux_agent_state's own current-command
# fallback settles the verdict directly from the faked pane_current_command,
# exactly like the equivalent probe in tests/fm-secondmate-liveness.test.sh.
make_collision_tmux() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
prev=
target=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
case "${1:-}" in
  list-windows)
    case "$target" in
      livesess) printf '%s\n' alive; printf '%s\n' ambig ;;
      *) printf "can't find session: %s\n" "$target" >&2; exit 1 ;;
    esac
    ;;
  display-message)
    case "$target" in
      livesess:alive) printf '%s\n' claude ;;
      livesess:ambig) printf '%s\n' node ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# The path a collision line prints for a recorded path: the physically resolved
# copy fm_worktree_collision_group_key keys the group on, which is not the
# recorded string wherever a test root sits under a symlink (macOS /tmp).
shown_path() {  # <recorded-path>
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

# Mirrors fm_worktree_collision_line_safe: every backslash is doubled first -
# unconditionally, which is what keeps the encoding injective - and every
# newline then becomes the two literal characters `\n`, so a test can predict
# the escaped form of a resolved path without depending on the library's own
# implementation.
line_safe() {  # <string>
  local s=$1
  s=${s//\\/\\\\}
  printf '%s' "${s//$'\n'/\\n}"
}

# A clean repo on `main` with one commit, ready to be a task's worktree. Its
# default branch is PUBLISHED - a pooled copy comes from a clone, and
# fm_worktree_collision_path_state only reads `landed` off origin/<default> -
# so the tracking ref and origin/HEAD are written directly rather than fetched,
# keeping every fixture here entirely offline.
make_worktree() {  # <dir>
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# --- unit level: the two independent classifiers ------------------------------

test_path_state_classification() {
  local wt got

  got=$(fm_worktree_collision_path_state "$TMP_ROOT/never-existed")
  [ "$got" = missing ] || fail "a worktree path with nothing at it should classify as missing, got '$got'"

  # No path at all is a non-answer, not an observed absence: nothing was
  # examined, so it may not reach the one verdict that drops the warning.
  got=$(fm_worktree_collision_path_state "")
  [ "$got" != missing ] \
    || fail "an empty path argument examined nothing and must never read as an observed absence, got '$got'"
  [ "$got" = unverifiable:no-path ] \
    || fail "an empty path argument should name that cause, got '$got'"
  assert_contains "$(fm_worktree_collision_path_caveat "$got")" "do not discard" \
    "an empty path argument must still carry the do-not-discard warning"

  # Present on disk but not a readable git worktree - a returned-but-not-deleted
  # pool copy, or a dangling .git pointer. The probe proves only that it could
  # not be read, never that it is empty.
  wt="$TMP_ROOT/uninspectable-wt"
  mkdir -p "$wt"
  echo "work nobody can account for" > "$wt/scratch.txt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unverifiable:not-a-worktree ] \
    || fail "a path that exists but is not a readable git worktree should name that cause, got '$got'"

  # Present but not a work tree at all: a plain file, a bare repository, and a
  # dangling symlink each leave `-d`/exit-status probes free to fall back on a
  # reassuring verdict. None of them proves the recorded copy is gone, so none
  # of them may read `missing`.
  wt="$TMP_ROOT/file-at-path"
  printf 'not a worktree\n' > "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unverifiable:not-a-worktree ] \
    || fail "a plain file left at the recorded path is not proof the copy is gone, got '$got'"

  wt="$TMP_ROOT/bare-repo"
  git init -q --bare "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unverifiable:not-a-worktree ] \
    || fail "a bare repository has no work tree to inspect, exactly as bin/fm-teardown.sh treats it, got '$got'"

  wt="$TMP_ROOT/dangling-link"
  ln -s "$TMP_ROOT/never-existed" "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unverifiable:not-a-worktree ] \
    || fail "a dangling symlink at the recorded path is still an entry that could not be inspected, got '$got'"

  wt="$TMP_ROOT/landed-wt"
  make_worktree "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = landed ] || fail "a clean worktree on the default branch should classify as landed, got '$got'"

  wt="$TMP_ROOT/unlanded-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unlanded ] || fail "a dirty worktree should classify as unlanded, got '$got'"

  # A worktree git can resolve but whose working-tree probe fails: the copy
  # holds an uncommitted file and HEAD is reachable from main, so every other
  # signal points at `landed` while the one probe that could see the work
  # exited non-zero with empty output. Reading that silence as "clean" is the
  # strongest possible claim from a probe that read nothing.
  wt="$TMP_ROOT/unverifiable-wt"
  make_worktree "$wt"
  echo uncommitted > "$wt/uncommitted.txt"
  printf 'garbage' > "$wt/.git/index"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" != landed ] \
    || fail "a worktree whose status probe failed must never read as landed, got '$got'"
  [ "$got" = unverifiable:worktree-state ] \
    || fail "a worktree git resolved but could not read should name that cause, got '$got'"
  [ -n "$(fm_worktree_collision_path_caveat "$got")" ] \
    || fail "an unverifiable shared path must carry a caveat, got an empty one"
  assert_contains "$(fm_worktree_collision_path_caveat "$got")" "do not discard" \
    "an unverifiable shared path must keep the do-not-discard warning"

  wt="$TMP_ROOT/unmerged-wt"
  make_worktree "$wt"
  git -C "$wt" checkout -q -b side
  git -C "$wt" commit -q --allow-empty -m "work not on main"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unlanded ] \
    || fail "a clean worktree whose HEAD is not reachable from the default branch should classify as unlanded, got '$got'"

  # Firstmate's own spawn-written scaffolding is not the task's work:
  # bin/fm-teardown.sh's validate_worktree_teardown_safety filters exactly
  # these entries out of the identical probe before deciding whether a copy is
  # safe to discard, and it is the code that actually discards. A copy whose
  # only porcelain lines are firstmate's wiring holds nothing to lose.
  wt="$TMP_ROOT/scaffolding-only-wt"
  make_worktree "$wt"
  mkdir -p "$wt/.claude"
  echo '{}' > "$wt/.claude/settings.json"
  echo '{}' > "$wt/.claude/settings.local.json"
  : > "$wt/.fm-grok-turnend"
  [ -n "$(git -C "$wt" status --porcelain)" ] \
    || fail "the scaffolding fixture must leave git status non-empty, or it proves nothing"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = landed ] \
    || fail "a copy holding only firstmate's own scaffolding must read exactly as teardown reads it, got '$got'"

  # One real file beside the same scaffolding is the task's work, and must
  # still be reported.
  echo "the task's own work" > "$wt/work.txt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unlanded ] \
    || fail "a copy holding the task's own uncommitted file is unlanded, got '$got'"

  # A project whose default branch is neither main nor master, wired with
  # `git init` + `git remote add` rather than `git clone`, so nothing ever
  # wrote refs/remotes/origin/HEAD. The copy is clean and may be sitting
  # exactly on its own default branch; the ancestry check cannot run at all.
  # Reporting unlanded work here names work no probe ever saw.
  wt="$TMP_ROOT/no-default-branch-wt"
  git init -q -b develop "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" != unlanded ] \
    || fail "an ancestry check that could not run must not be reported as unlanded work, got '$got'"
  [ "$got" = unverifiable:default-branch ] \
    || fail "a worktree with no resolvable default branch should name that cause, got '$got'"
  assert_contains "$(fm_worktree_collision_path_caveat "$got")" "do not discard" \
    "an unresolvable default branch must still keep the do-not-discard warning"
  assert_not_contains "$(fm_worktree_collision_path_caveat "$got")" "still has unlanded work" \
    "a check that never ran must not assert work at the shared path"

  # Absence has to be observed, not assumed: a stat refused by an unsearchable
  # ancestor is indistinguishable from a real ENOENT to `test`, while the
  # worktree and its uncommitted file sit intact underneath. Root reads through
  # the mode bits, so this drives the real distinction only where the
  # filesystem can actually refuse the stat.
  if [ "$(id -u)" != 0 ]; then
    mkdir -p "$TMP_ROOT/locked-parent"
    wt="$TMP_ROOT/locked-parent/wt"
    make_worktree "$wt"
    echo uncommitted > "$wt/uncommitted.txt"
    chmod 000 "$TMP_ROOT/locked-parent"
    got=$(fm_worktree_collision_path_state "$wt")
    chmod 755 "$TMP_ROOT/locked-parent"
    [ "$got" != missing ] \
      || fail "a stat refused by an unsearchable ancestor is not proof the worktree is gone, got '$got'"
    [ "$got" = unverifiable:path-unreadable ] \
      || fail "a path whose absence could not be observed should name that cause, got '$got'"
    assert_contains "$(fm_worktree_collision_path_caveat "$got")" "do not discard" \
      "a path whose absence could not be observed must carry the do-not-discard warning"
  fi

  pass "fm_worktree_collision_path_state: only an observed absence reads missing, and no unanswerable probe claims a fact"
}

# The regression `landed`'s published-ref requirement exists for: a branch
# merged into the LOCAL default branch and pushed nowhere. Every local signal
# says the work is safely in main, but the commits exist on no remote -
# bin/fm-teardown.sh's validate_worktree_teardown_safety refuses to discard
# exactly this copy ("work not on any remote and not landed"). Reading it as
# `landed` prints the empty caveat, which is byte-for-byte the strongest
# safe-to-reclaim claim this check can make, over the only copy of the work.
test_path_state_local_only_merge_is_not_landed() {
  local wt got

  wt="$TMP_ROOT/local-merge-wt"
  git init -q -b main "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b feature
  git -C "$wt" commit -q --allow-empty -m "work merged locally, pushed nowhere"
  git -C "$wt" checkout -q main
  git -C "$wt" merge -q --ff-only feature
  git -C "$wt" checkout -q feature

  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "the local-merge fixture must be clean, or it proves nothing"
  git -C "$wt" merge-base --is-ancestor HEAD main \
    || fail "the local-merge fixture must be reachable from the local default branch"
  git -C "$wt" rev-parse --verify -q origin/main >/dev/null \
    && fail "the local-merge fixture must have no published default branch"

  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" != landed ] \
    || fail "work merged only into an unpublished local default branch must never read as landed, got '$got'"
  [ "$got" = unverifiable:unpublished-default ] \
    || fail "a HEAD reachable only from a local default branch should name that cause, got '$got'"
  [ -n "$(fm_worktree_collision_path_caveat "$got")" ] \
    || fail "a copy whose work is on no remote must carry a caveat, got an empty one"
  assert_contains "$(fm_worktree_collision_path_caveat "$got")" "do not discard" \
    "a copy whose work is on no remote must keep the do-not-discard warning"
  assert_not_contains "$(fm_worktree_collision_path_caveat "$got")" "still has unlanded work" \
    "an ancestry check that only a local ref could answer must not claim work it did not see"

  # The same copy once its default branch IS published: the ancestry check now
  # has a ref proving the commits are not only local, so `landed` is earned and
  # the caveat is empty.
  git -C "$wt" update-ref refs/remotes/origin/main main
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = landed ] \
    || fail "a HEAD reachable from the published default branch is landed, got '$got'"
  [ -z "$(fm_worktree_collision_path_caveat "$got")" ] \
    || fail "a landed shared path must print no caveat, got '$(fm_worktree_collision_path_caveat "$got")'"

  pass "fm_worktree_collision_path_state: only a published default branch earns landed"
}

# The caveat function is the last thing between a verdict and the reader. A
# verdict it does not recognise must not fall through to the empty caveat,
# which is byte-for-byte the `landed` output and the strongest safe-to-reclaim
# claim the check can make.
test_path_caveat_defaults_to_unverified() {
  local got

  got=$(fm_worktree_collision_path_caveat "some-verdict-added-later")
  [ -n "$got" ] \
    || fail "an unrecognised path verdict must not print the empty, safe-to-reclaim caveat"
  [ "$got" != "$(fm_worktree_collision_path_caveat landed)" ] \
    || fail "an unrecognised path verdict must not read exactly like a landed path"
  assert_contains "$got" "do not discard" \
    "an unrecognised path verdict must default to the do-not-discard warning"
  assert_contains "$got" "cannot be verified" \
    "an unrecognised path verdict must say the state could not be verified"

  [ -z "$(fm_worktree_collision_path_caveat landed)" ] \
    || fail "a landed path is the one verdict that earns an empty caveat"

  pass "fm_worktree_collision_path_caveat: an unknown verdict fails safe, not reassuring"
}

test_claimant_process_classification() {
  local fakebin meta wt got

  fakebin=$(make_collision_tmux "$TMP_ROOT/tmux")

  # Every case below records the same dirty worktree, so the path's content is
  # constant: any difference in verdict comes from the process alone. That is
  # the split this classifier exists to enforce - a dead record must read dead
  # even when the shared path is full of somebody's uncommitted work.
  wt="$TMP_ROOT/proc-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"

  meta="$TMP_ROOT/alive.meta"
  fm_write_meta "$meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = alive ] || fail "a live agent process should classify as alive, got '$got'"

  meta="$TMP_ROOT/ambig.meta"
  fm_write_meta "$meta" "window=livesess:ambig" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = ambiguous ] \
    || fail "a backend that answered but could not attribute the process should report ambiguous, not a flat unverifiable verdict, got '$got'"

  meta="$TMP_ROOT/dead.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = missing ] \
    || fail "an authoritatively absent endpoint should report missing even when the shared worktree is dirty, got '$got'"

  meta="$TMP_ROOT/no-endpoint.meta"
  fm_write_meta "$meta" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = no-endpoint ] || fail "a record with no recorded target should report no-endpoint, got '$got'"

  # A corrupt record naming a backend firstmate does not know is unreadable,
  # not finished - and bootstrap's own output is captured with stderr merged
  # (bin/fm-session-start.sh), so the backend's refusal must not leak into the
  # digest as an unprefixed line no diagnostic skill can route.
  meta="$TMP_ROOT/bogus-backend.meta"
  fm_write_meta "$meta" "window=livesess:alive" "backend=bogus" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta" 2>"$TMP_ROOT/bogus-backend.err")
  [ "$got" = unverified ] || fail "an unknown backend has no recovery classifier, so it should report unverified, got '$got'"
  [ ! -s "$TMP_ROOT/bogus-backend.err" ] \
    || fail "an unknown backend must not leak diagnostics onto stderr, got:"$'\n'"$(cat "$TMP_ROOT/bogus-backend.err")"

  pass "fm_worktree_collision_claimant_process: the backend's own verdict, from the process alone, quietly"
}

# --- fm_worktree_collision_lines: grouping and live/stale classification ----

test_collision_lines_grouping() {
  local state fakebin wt_live wt_stale wt_solo out

  state="$TMP_ROOT/group-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/group-tmux")

  # Genuine live collision: two records share one dirty worktree and neither
  # process is provably finished - fm-live-a's agent is alive, fm-live-b's
  # state is ambiguous. Both count as hazards, so this is the real thing.
  wt_live="$TMP_ROOT/wt-live"
  make_worktree "$wt_live"
  echo dirty > "$wt_live/scratch.txt"
  fm_write_meta "$state/fm-live-a.meta" "window=livesess:alive" "worktree=$wt_live" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-live-b.meta" "window=livesess:ambig" "worktree=$wt_live" "harness=codex" "kind=ship"

  # Stale collision: the pool slot was recycled. fm-old-finished's process is
  # gone - a finished task's leftover record - and the shared path is clean and
  # on the default branch. fm-new-active's process is genuinely alive. Only one
  # hazardous claimant, so this must read `stale`, not `live`.
  wt_stale="$TMP_ROOT/wt-stale"
  make_worktree "$wt_stale"
  fm_write_meta "$state/fm-old-finished.meta" "window=deadsess:win" "worktree=$wt_stale" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-new-active.meta" "window=livesess:alive" "worktree=$wt_stale" "harness=codex" "kind=ship"

  # A solo task with its own unique path must never produce a collision line.
  wt_solo="$TMP_ROOT/wt-solo"
  make_worktree "$wt_solo"
  fm_write_meta "$state/fm-solo.meta" "window=livesess:alive" "worktree=$wt_solo" "harness=claude" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $(shown_path "$wt_live") claimed by fm-live-a (process alive, recorded $wt_live), fm-live-b (process state unknown (backend=tmux reported ambiguous), recorded $wt_live) - shared path still has unlanded work, do not discard" \
    "two hazardous processes on one worktree should be reported as a live collision naming both verdicts, and a dirty shared path still states its own risk"
  assert_not_contains "$out" "not verifiable" \
    "a backend that answered every query must never be described as unverifiable"

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt_stale") claimed by fm-new-active (process alive, recorded $wt_stale), fm-old-finished (process gone, recorded $wt_stale)" \
    "a finished task's leftover record alongside one live task should read stale and name each process verdict"

  assert_not_contains "$out" "$wt_solo" \
    "a path claimed by only one record must never produce a collision line"

  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 2 ] \
    || fail "expected exactly 2 collision lines, got:"$'\n'"$out"

  pass "fm_worktree_collision_lines: groups by path, distinguishes live from stale, ignores solo paths"
}

# The regression this file's split classifiers exist for: a recycled pool slot
# where the surviving task is still working. The shared worktree is dirty with
# the LIVE claimant's own work in progress, so counting that dirt once per
# record used to promote the collision to `live` and to print the live task's
# unfinished work against the FINISHED record's name. Only one process is a
# hazard, so the kind is `stale`, the dead record's own detail says nothing but
# `process gone`, and the unlanded work is stated once, for the path.
test_collision_lines_live_claimants_wip_stays_path_level() {
  local state fakebin wt out

  state="$TMP_ROOT/wip-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/wip-tmux")

  wt="$TMP_ROOT/wt-wip"
  make_worktree "$wt"
  fm_write_meta "$state/fm-new-active.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-old-finished.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  # Case A: the live claimant has uncommitted work in the shared worktree.
  echo wip > "$wt/live-task-wip.txt"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-new-active (process alive, recorded $wt), fm-old-finished (process gone, recorded $wt) - shared path still has unlanded work, do not discard" \
    "one live claimant working in the shared worktree is still a stale collision, with the unlanded work stated once for the path"
  assert_not_contains "$out" "work not landed" \
    "the live claimant's work in progress must never be described as a claimant's own unlanded work"
  assert_not_contains "$out" "fm-old-finished (process gone, recorded $wt, " \
    "the finished record's own detail must say nothing beyond its process state and its own recorded path"

  # Case B: the same fixture with that work removed - clean and merged.
  rm -f "$wt/live-task-wip.txt"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-new-active (process alive, recorded $wt), fm-old-finished (process gone, recorded $wt)" \
    "a clean, landed shared worktree with one live claimant is still a stale collision"
  assert_not_contains "$out" "unlanded" \
    "a landed shared path must carry no unlanded-work caveat"

  pass "fm_worktree_collision_lines: a live claimant's own WIP never promotes the kind or lands on a finished record"
}

# All claimants finished, shared path still dirty: the kind is decided by
# process concurrency alone, so this reads `stale` - but the unlanded work must
# still be stated, or the one thing that could be destroyed here goes unsaid.
test_collision_lines_all_dead_unlanded_keeps_caveat() {
  local state fakebin wt out

  state="$TMP_ROOT/dead-unlanded-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/dead-unlanded-tmux")

  wt="$TMP_ROOT/wt-dead-unlanded"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$state/fm-dead-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-dead-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-dead-a (process gone, recorded $wt), fm-dead-b (process gone, recorded $wt) - shared path still has unlanded work, do not discard" \
    "two finished records over dirty shared work should read stale and still carry the unlanded caveat"

  pass "fm_worktree_collision_lines: unlanded work is never silent even when no process is a hazard"
}

# A path that no longer exists is still a path two records both claim, so it is
# never dropped from the output: the vanished path becomes its own caveat, and
# an unverifiable process stays a hazard there exactly as it would anywhere
# else - the detector says what it cannot verify rather than staying silent.
test_collision_lines_gone_path_is_always_reported() {
  local state fakebin gone_path out

  state="$TMP_ROOT/gone-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/gone-tmux")
  gone_path="$TMP_ROOT/torn-down-wt"

  fm_write_meta "$state/fm-ambig-a.meta" "window=livesess:ambig" "worktree=$gone_path" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-ambig-b.meta" "window=livesess:ambig" "worktree=$gone_path" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $gone_path claimed by fm-ambig-a (process state unknown (backend=tmux reported ambiguous), recorded $gone_path), fm-ambig-b (process state unknown (backend=tmux reported ambiguous), recorded $gone_path) - shared worktree no longer exists at that path" \
    "two unverifiable claimants of a torn-down worktree must still be reported, naming the backend that could not answer and the vanished path"

  # A confirmed-alive claimant over the same vanished path: still reported, and
  # the alive claimant is named as the hazard it is.
  fm_write_meta "$state/fm-ambig-b.meta" "window=livesess:alive" "worktree=$gone_path" "harness=codex" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $gone_path claimed by fm-ambig-a (process state unknown (backend=tmux reported ambiguous), recorded $gone_path), fm-ambig-b (process alive, recorded $gone_path) - shared worktree no longer exists at that path" \
    "a confirmed-alive claimant of a worktree that no longer exists must still be reported"

  # One hazard only (alive plus a finished record) reads stale, and the gone
  # caveat is a path fact, so it rides that kind too.
  fm_write_meta "$state/fm-ambig-a.meta" "window=deadsess:win" "worktree=$gone_path" "harness=claude" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: stale $gone_path claimed by fm-ambig-a (process gone, recorded $gone_path), fm-ambig-b (process alive, recorded $gone_path) - shared worktree no longer exists at that path" \
    "a live claimant beside a finished record over a vanished path reads stale and still carries the gone caveat"

  pass "fm_worktree_collision_lines: a vanished path is reported with its own caveat, never silenced"
}

# A path that is present but unreadable is the case bin/fm-teardown.sh refuses
# on: the probe proves only that git could not inspect it, so the line must not
# imply the path is empty, and the do-not-discard warning must survive.
test_collision_lines_uninspectable_path_keeps_do_not_discard() {
  local state fakebin wt out

  state="$TMP_ROOT/uninspectable-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/uninspectable-tmux")

  wt="$TMP_ROOT/wt-uninspectable"
  mkdir -p "$wt"
  echo "uncommitted work nobody can account for" > "$wt/scratch.txt"
  fm_write_meta "$state/fm-u-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-u-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-u-a (process gone, recorded $wt), fm-u-b (process gone, recorded $wt) - shared path is not an inspectable git worktree, so whether work would be lost cannot be verified, do not discard" \
    "a shared path that exists but cannot be inspected must keep the do-not-discard warning"
  assert_not_contains "$out" "no longer exists" \
    "a path that is still on disk must never be reported as gone"

  # The same guarantee for a pool slot that is present but has no work tree at
  # all - the case bin/fm-teardown.sh's own --show-toplevel probe refuses on.
  wt="$TMP_ROOT/wt-bare-shared"
  git init -q --bare "$wt"
  fm_write_meta "$state/fm-u-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-u-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-u-a (process gone, recorded $wt), fm-u-b (process gone, recorded $wt) - shared path is not an inspectable git worktree, so whether work would be lost cannot be verified, do not discard" \
    "a shared path with no inspectable work tree must keep the do-not-discard warning"
  assert_not_contains "$out" "no longer exists" \
    "a path git could not inspect must never be reported as gone"

  pass "fm_worktree_collision_lines: an uninspectable shared path is never reported as empty"
}

# The emitted line for the same defect one level up: a shared copy holding an
# uncommitted file whose .git/index git cannot read. Everything except the
# failed probe says `landed`, and a landed path prints no caveat at all - which
# would tell the reader the shared copy holds nothing to lose.
test_collision_lines_unreadable_worktree_state_keeps_do_not_discard() {
  local state fakebin wt out

  state="$TMP_ROOT/unverifiable-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/unverifiable-tmux")

  wt="$TMP_ROOT/wt-unverifiable"
  make_worktree "$wt"
  echo "work only the index knew about" > "$wt/uncommitted.txt"
  printf 'garbage' > "$wt/.git/index"
  fm_write_meta "$state/fm-v-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-v-b.meta" "window=livesess:alive" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-v-a (process gone, recorded $wt), fm-v-b (process alive, recorded $wt) - shared path is a git worktree whose working-tree state could not be read, so whether work would be lost cannot be verified, do not discard" \
    "a shared worktree whose working-tree state could not be read must name that cause and keep the do-not-discard warning"
  assert_not_contains "$out" "no longer exists" \
    "a path that is still on disk must never be reported as gone"
  assert_not_contains "$out" "not an inspectable git worktree" \
    "a path git did resolve must not be described as one it could not resolve"

  pass "fm_worktree_collision_lines: a failed working-tree probe never prints as a path with nothing to lose"
}

# The same overclaim one level up, in the other direction: an ancestry check
# that could not run at all used to print `still has unlanded work`, telling
# the reader a clean copy holds work in progress. The emitted line must name
# the check that could not be made instead.
test_collision_lines_unresolvable_default_branch_names_the_missing_check() {
  local state fakebin wt out

  state="$TMP_ROOT/no-default-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/no-default-tmux")

  wt="$TMP_ROOT/wt-no-default"
  git init -q -b develop "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  fm_write_meta "$state/fm-d-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-d-b.meta" "window=livesess:alive" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-d-a (process gone, recorded $wt), fm-d-b (process alive, recorded $wt) - shared path is a git worktree whose HEAD could not be checked against the project's default branch, so whether work would be lost cannot be verified, do not discard" \
    "a shared path whose default branch could not be resolved must name that check and keep the do-not-discard warning"
  assert_not_contains "$out" "still has unlanded work" \
    "a check that never ran must never be printed as work seen at the shared path"

  pass "fm_worktree_collision_lines: an ancestry check that could not run never invents unlanded work"
}

# Two records can spell one pooled copy differently - one backend reports the
# physically resolved cwd, another the shell's logical symlink-preserving path
# - and grouping on the raw strings would let a real double registration go
# entirely unreported, which is the one thing this check exists to prevent.
test_collision_lines_groups_symlinked_spellings_of_one_copy() {
  local state fakebin phys link out

  state="$TMP_ROOT/symlink-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/symlink-tmux")

  phys="$TMP_ROOT/pool-physical"
  mkdir -p "$phys"
  make_worktree "$phys/wt-3"
  ln -s "$phys" "$TMP_ROOT/pool-link"
  link="$TMP_ROOT/pool-link"

  fm_write_meta "$state/fm-phys.meta" "window=livesess:alive" "worktree=$phys/wt-3" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-sym.meta" "window=livesess:ambig" "worktree=$link/wt-3" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $(shown_path "$phys/wt-3") claimed by " \
    "the path after the kind must be the physically resolved copy the claimants share"
  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 1 ] \
    || fail "one physical worktree must produce exactly one collision line, got:"$'\n'"$out"

  # Grouping proves the two records point at one copy, not that either record
  # contains the printed string. An agent sent to inspect fm-sym opens its meta
  # and finds the symlinked spelling; if the line never said so, the natural
  # reading is that fm-sym is not a claimant and the line is a false positive -
  # the exact conclusion this check exists to prevent.
  assert_contains "$out" "fm-phys (process alive, recorded $phys/wt-3)" \
    "the record that spelled the path physically must be named with its own recorded spelling"
  assert_contains "$out" "fm-sym (process state unknown (backend=tmux reported ambiguous), recorded $link/wt-3)" \
    "the record that spelled the path through the symlink must be named with its own recorded spelling"

  pass "fm_worktree_collision_lines: one physical copy spelled two ways is one collision naming both spellings"
}

# A recorded worktree path may contain any character a directory name can hold.
# A backslash used to be eaten by awk's own escape processing before the path
# was compared, so no record matched, and the line printed with nothing at all
# after "claimed by" - a collision naming no claimant.
test_collision_lines_path_with_backslash_names_every_claimant() {
  local state fakebin wt out
  local leaf='wt-back\tslash'

  state="$TMP_ROOT/backslash-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/backslash-tmux")

  wt="$TMP_ROOT/$leaf"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$state/fm-bs-a.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-bs-b.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $(line_safe "$(shown_path "$wt")") claimed by fm-bs-a (process alive, recorded $wt), fm-bs-b (process state unknown (backend=tmux reported ambiguous), recorded $wt) - shared path still has unlanded work, do not discard" \
    "a worktree path containing a backslash must still group its records and name every claimant"
  assert_not_contains "$out" "claimed by -" \
    "a collision line must never print with no claimant at all"
  assert_not_contains "$out" "claimed by $wt" \
    "a collision line must never print with no claimant at all"

  pass "fm_worktree_collision_lines: a path with a backslash still names every claimant"
}

# The grouping key is machine-generated (`pwd -P`), so nothing fm_meta_get
# bounds constrains it: a symlinked pool prefix whose real target name holds a
# newline must never split the line-based transport or truncate the printed
# path. Both records here spell the path identically, so this pins the escape
# path alone; test_collision_lines_groups_differently_spelled_newline_path
# below is the one that requires the escaped form to be used AS the key, not
# just as an over-cautious fallback.
test_collision_lines_newline_in_resolved_path_is_still_reported() {
  local state fakebin phys link out expected

  state="$TMP_ROOT/newline-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/newline-tmux")

  phys="$TMP_ROOT/pool"$'\n'"real"
  mkdir -p "$phys"
  make_worktree "$phys/wt"
  link="$TMP_ROOT/pool-plain"
  ln -s "$phys" "$link"

  fm_write_meta "$state/fm-n-a.meta" "window=livesess:alive" "worktree=$link/wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-n-b.meta" "window=livesess:alive" "worktree=$link/wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  expected=$(line_safe "$phys/wt")

  assert_contains "$out" "WORKTREE_COLLISION: live $expected claimed by fm-n-a (process alive, recorded $link/wt), fm-n-b (process alive, recorded $link/wt)" \
    "a resolved path holding a newline must print its escaped physically resolved form, naming each claimant's own recorded spelling"
  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 1 ] \
    || fail "the collision must print exactly once, against a whole path, got:"$'\n'"$out"
  assert_not_contains "$out" "WORKTREE_COLLISION: live $TMP_ROOT/pool claimed" \
    "a collision must never be printed against a path truncated at a newline"
  case "$out" in
    *$'\n'*) fail "a raw newline must never reach the printed line, got:"$'\n'"$out" ;;
  esac

  pass "fm_worktree_collision_lines: a newline in the resolved path never splits, truncates, or breaks the printed line"
}

# The actual defect this pins: fm_worktree_collision_group_key's newline
# fallback used to return each RECORDED string, not a canonical form of the
# resolved path. Two records that spell the SAME newline-holding physical copy
# differently through two valid symlink paths then keyed apart - the group
# vanished and a real double registration went completely unreported, which is
# the one guarantee this whole check exists to make.
test_collision_lines_groups_differently_spelled_newline_path() {
  local state fakebin phys link_a link_b out expected

  state="$TMP_ROOT/newline-spelling-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/newline-spelling-tmux")

  phys="$TMP_ROOT/pool2"$'\n'"real"
  mkdir -p "$phys"
  make_worktree "$phys/wt-9"
  link_a="$TMP_ROOT/pool2-link-a"
  link_b="$TMP_ROOT/pool2-link-b"
  ln -s "$phys" "$link_a"
  ln -s "$phys" "$link_b"

  fm_write_meta "$state/fm-link-a2.meta" "window=livesess:alive" "worktree=$link_a/wt-9" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-link-b2.meta" "window=livesess:ambig" "worktree=$link_b/wt-9" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  expected=$(line_safe "$phys/wt-9")

  [ -n "$out" ] \
    || fail "two different valid spellings of the same newline-holding physical copy must still collide, got no output at all"
  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 1 ] \
    || fail "one physical worktree spelled two ways must produce exactly one collision line, got:"$'\n'"$out"
  assert_contains "$out" "WORKTREE_COLLISION: live $expected claimed by " \
    "the path after the kind must be the shared physically resolved copy, escaped for the newline it holds"
  assert_contains "$out" "fm-link-a2 (process alive, recorded $link_a/wt-9)" \
    "the first valid spelling must be named with its own recorded spelling"
  assert_contains "$out" "fm-link-b2 (process state unknown (backend=tmux reported ambiguous), recorded $link_b/wt-9)" \
    "the second valid spelling must be named with its own recorded spelling"

  pass "fm_worktree_collision_lines: two different spellings of one newline-holding copy still group into one collision"
}

# Resolving a recorded path through a command substitution silently drops the
# path's OWN trailing newline, so a pooled copy at <pool>/wt<LF> resolves to
# <pool>/wt - a different path, which normally does not exist. The scan then
# keys, prints, and classifies that other path, and the copy still holding the
# task's work is reported with `shared worktree no longer exists at that path`:
# the single caveat that carries no do-not-discard clause. Both records here
# spell the copy through a newline-free symlink, so this pins the RESOLUTION
# step alone.
test_collision_lines_trailing_newline_path_names_the_real_copy() {
  local state fakebin pool wt link out

  state="$TMP_ROOT/trailing-nl-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/trailing-nl-tmux")

  pool="$TMP_ROOT/trailing-nl-pool"
  mkdir -p "$pool"
  wt="$pool/wt"$'\n'
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  link="$pool/link"
  ln -s "$wt" "$link"

  [ ! -e "$pool/wt" ] \
    || fail "the fixture must leave nothing at the truncated path, or it proves nothing"

  fm_write_meta "$state/fm-tn-a.meta" "window=livesess:alive" "worktree=$link" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-tn-b.meta" "window=livesess:ambig" "worktree=$link" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 1 ] \
    || fail "one shared copy must produce exactly one collision line, got:"$'\n'"$out"
  assert_not_contains "$out" "no longer exists" \
    "a copy still on disk must never be reported as gone because its name ends in a newline"
  assert_contains "$out" "WORKTREE_COLLISION: live $(line_safe "$wt") claimed by fm-tn-a (process alive, recorded $link), fm-tn-b (process state unknown (backend=tmux reported ambiguous), recorded $link) - shared path still has unlanded work, do not discard" \
    "the collision must name the copy that actually exists, escaped, and report the work it holds"

  pass "fm_worktree_collision_lines: a copy whose name ends in a newline is named, never resolved away"
}

# The group key is an ENCODING, so it has to be injective: two different
# physical copies may never encode to one key. Doubling backslashes only for
# strings that already hold a newline breaks that - a copy whose real name
# holds a newline and a copy whose real name literally contains backslash-then-n
# both encode to the same key, merge into ONE line, and name four records of
# which half claim a copy that line does not describe. That is the false
# positive this whole check exists to avoid producing.
test_collision_lines_newline_and_literal_backslash_n_stay_distinct() {
  local state fakebin pool real_nl literal_nl nl_link out line_nl line_bs

  state="$TMP_ROOT/injective-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/injective-tmux")

  pool="$TMP_ROOT/injective-pool"
  mkdir -p "$pool"
  real_nl="$pool/a"$'\n'"b"
  literal_nl="$pool/a\\nb"
  make_worktree "$real_nl"
  make_worktree "$literal_nl"
  # Both records reach the newline-holding copy through a newline-free
  # spelling, so this pins the KEY, not the transport the newline tests cover.
  nl_link="$pool/link-to-newline-copy"
  ln -s "$real_nl" "$nl_link"

  fm_write_meta "$state/fm-nl-a.meta" "window=livesess:alive" "worktree=$nl_link" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-nl-b.meta" "window=livesess:alive" "worktree=$nl_link" "harness=codex" "kind=ship"
  fm_write_meta "$state/fm-bs-x.meta" "window=livesess:alive" "worktree=$literal_nl" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-bs-y.meta" "window=livesess:alive" "worktree=$literal_nl" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 2 ] \
    || fail "two different physical copies must produce two collision lines, got:"$'\n'"$out"

  line_nl=$(printf '%s\n' "$out" | grep -F 'fm-nl-a' || true)
  line_bs=$(printf '%s\n' "$out" | grep -F 'fm-bs-x' || true)

  assert_contains "$line_nl" "WORKTREE_COLLISION: live $(line_safe "$real_nl") claimed by fm-nl-a (process alive, recorded $nl_link), fm-nl-b (process alive, recorded $nl_link)" \
    "the newline-holding copy must print its own escaped path and only its own claimants"
  assert_not_contains "$line_nl" "fm-bs-" \
    "a record claiming the literal backslash-n copy must never be named on the newline copy's line"

  assert_contains "$line_bs" "WORKTREE_COLLISION: live $(line_safe "$literal_nl") claimed by fm-bs-x (process alive, recorded $literal_nl), fm-bs-y (process alive, recorded $literal_nl)" \
    "the copy whose name literally contains backslash-n must print its own escaped path and only its own claimants"
  assert_not_contains "$line_bs" "fm-nl-" \
    "a record claiming the newline copy must never be named on the literal backslash-n copy's line"

  pass "fm_worktree_collision_lines: a real newline and a literal backslash-n path never merge into one collision"
}

# The internal id-to-path transport is tab-delimited, so a tab inside a
# recorded path used to split the grouping key: no record matched its own path,
# the claimant set came back empty, and the whole collision line vanished
# silently - indistinguishable from a home with no collision at all.
test_collision_lines_path_with_tab_is_still_reported() {
  local state fakebin wt out
  local leaf
  leaf=$(printf 'wt-tab\there')

  state="$TMP_ROOT/tab-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/tab-tmux")

  wt="$TMP_ROOT/$leaf"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$state/fm-tab-a.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-tab-b.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  [ -n "$out" ] \
    || fail "a genuine collision on a path containing a tab must never vanish silently"
  assert_contains "$out" "WORKTREE_COLLISION: live $(shown_path "$wt") claimed by fm-tab-a (process alive, recorded $wt), fm-tab-b (process state unknown (backend=tmux reported ambiguous), recorded $wt) - shared path still has unlanded work, do not discard" \
    "a worktree path containing a tab must still group its records and name every claimant"

  pass "fm_worktree_collision_lines: a path with a tab is reported, never silently dropped"
}

# The scan is a snapshot taken without a fleet lock, so bin/fm-teardown.sh can
# remove state/<id>.meta between the snapshot and that record's process probe.
# The vanished record must be dropped, never reported as an unverifiable hazard
# pointing the reader at a record that no longer exists - and a path left with
# one surviving claimant is no longer a collision at all.
test_collision_lines_record_removed_mid_scan_is_dropped() {
  local state fakebin wt out
  local vanish_target=

  state="$TMP_ROOT/vanish-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/vanish-tmux")

  wt="$TMP_ROOT/wt-vanish"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"

  # Drop the record from disk as the scan finishes reading it, which is exactly
  # where a concurrent teardown lands: present for the snapshot, gone for the
  # probe.
  eval "$(declare -f fm_meta_get | sed '1s/^fm_meta_get/fm_meta_get_orig/')"
  fm_meta_get() {
    fm_meta_get_orig "$@"
    if [ -n "$vanish_target" ] && [ "$2" = remote_host ] && [ "$1" = "$vanish_target" ]; then
      rm -f "$1"
    fi
  }
  vanish_target="$state/fm-torn-down.meta"

  fm_write_meta "$state/fm-live-a.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-live-b.meta" "window=livesess:alive" "worktree=$wt" "harness=codex" "kind=ship"
  fm_write_meta "$vanish_target" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $(shown_path "$wt") claimed by fm-live-a (process alive, recorded $wt), fm-live-b (process alive, recorded $wt) - shared path still has unlanded work, do not discard" \
    "the surviving claimants of a still-real collision must still be reported"
  assert_not_contains "$out" "fm-torn-down" \
    "a record removed during the scan must never be named as a claimant"

  # Only one record survives the teardown, so the collision has resolved itself.
  rm -f "$state/fm-live-b.meta"
  fm_write_meta "$vanish_target" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  unset -f fm_meta_get
  eval "$(declare -f fm_meta_get_orig | sed '1s/^fm_meta_get_orig/fm_meta_get/')"
  unset -f fm_meta_get_orig

  [ -z "$out" ] \
    || fail "a path left with one surviving record is no longer a collision, got:"$'\n'"$out"

  pass "fm_worktree_collision_lines: a record torn down mid-scan is dropped, not reported as a phantom hazard"
}

# Remote secondmate records name a home on another machine: that path is unique
# only when host-qualified, so it can never collide with a local worktree and
# neither the local git probe nor the local backend probe can judge it.
# The emitted line for the same divergence: a shared copy whose only content is
# firstmate's own wiring must not be described as holding the task's work,
# because bin/fm-teardown.sh - the code that would discard it - reads the
# identical probe and calls that copy clean.
test_collision_lines_scaffolding_only_path_is_not_called_unlanded() {
  local state fakebin wt out

  state="$TMP_ROOT/scaffolding-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/scaffolding-tmux")

  wt="$TMP_ROOT/wt-scaffolding"
  make_worktree "$wt"
  mkdir -p "$wt/.claude"
  echo '{}' > "$wt/.claude/settings.json"
  fm_write_meta "$state/fm-s-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-s-b.meta" "window=livesess:alive" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $(shown_path "$wt") claimed by fm-s-a (process gone, recorded $wt), fm-s-b (process alive, recorded $wt)" \
    "the collision itself must still be reported"
  assert_not_contains "$out" "still has unlanded work" \
    "a copy holding only firstmate's own scaffolding must not be reported as holding the task's work"

  pass "fm_worktree_collision_lines: firstmate's own scaffolding is never reported as the task's work"
}

test_collision_lines_skips_remote_records() {
  local state fakebin wt out

  state="$TMP_ROOT/remote-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/remote-tmux")

  wt="$TMP_ROOT/wt-shared-remote-home"
  make_worktree "$wt"
  fm_write_meta "$state/fm-remote-a.meta" "window=remote:fm-remote-a" "worktree=$wt" \
    "harness=claude" "kind=secondmate" "remote_host=hostA" "remote_root=/srv/code"
  fm_write_meta "$state/fm-remote-b.meta" "window=remote:fm-remote-b" "worktree=$wt" \
    "harness=claude" "kind=secondmate" "remote_host=hostB" "remote_root=/srv/code"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  [ -z "$out" ] \
    || fail "two remote secondmates whose homes share a path string are on different machines and must not collide, got:"$'\n'"$out"

  fm_write_meta "$state/fm-local-x.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-local-y.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $(shown_path "$wt") claimed by fm-local-x (process alive, recorded $wt), fm-local-y (process state unknown (backend=tmux reported ambiguous), recorded $wt)" \
    "the local pair sharing that same path must still be reported"
  assert_not_contains "$out" "fm-remote-a" \
    "a remote record must never be named as a claimant of a local worktree"
  assert_not_contains "$out" "fm-remote-b" \
    "a remote record must never be named as a claimant of a local worktree"

  pass "fm_worktree_collision_lines: remote_host= records are out of scope and never join a local collision"
}

test_collision_lines_silent_on_clean_home() {
  local state wt out

  state="$TMP_ROOT/clean-state"
  mkdir -p "$state"
  out=$(fm_worktree_collision_lines "$state")
  [ -z "$out" ] || fail "an empty state dir must produce no output, got: $out"

  wt="$TMP_ROOT/clean-wt"
  make_worktree "$wt"
  fm_write_meta "$state/fm-only.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  out=$(fm_worktree_collision_lines "$state")
  [ -z "$out" ] || fail "a home with no shared worktree paths must produce no output, got: $out"

  pass "fm_worktree_collision_lines: silent when no path is claimed twice"
}

# --- bootstrap integration ---------------------------------------------------

# Local-half-only bootstrap on a pinned PATH: the collision check reads meta
# files, the recorded backend endpoint, and the worktree's own git state, so
# neither case may depend on the host's real gh auth or tool versions.
run_bootstrap() {  # <home> <fakebin>
  PATH="$2:$BASE_PATH" FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_surfaces_collision_line() {
  local home fakebin wt out

  fakebin=$(make_collision_tmux "$TMP_ROOT/bootstrap-tmux")

  home="$TMP_ROOT/bootstrap-clean"
  mkdir -p "$home/state"
  out=$(run_bootstrap "$home" "$fakebin" | grep '^WORKTREE_COLLISION:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a WORKTREE_COLLISION line on a clean home: $out"

  home="$TMP_ROOT/bootstrap-collision"
  mkdir -p "$home/state"
  wt="$TMP_ROOT/bootstrap-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$home/state/fm-one.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/fm-two.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(run_bootstrap "$home" "$fakebin" | grep '^WORKTREE_COLLISION:' || true)
  assert_contains "$out" "live $(shown_path "$wt") claimed by" "bootstrap did not report the double-registered worktree"
  assert_contains "$out" "fm-one" "bootstrap's collision line did not name the first claimant"
  assert_contains "$out" "fm-two" "bootstrap's collision line did not name the second claimant"

  pass "fm-bootstrap.sh: WORKTREE_COLLISION line fires only when a worktree is double-registered"
}

test_path_state_classification
test_path_state_local_only_merge_is_not_landed
test_path_caveat_defaults_to_unverified
test_claimant_process_classification
test_collision_lines_grouping
test_collision_lines_live_claimants_wip_stays_path_level
test_collision_lines_all_dead_unlanded_keeps_caveat
test_collision_lines_gone_path_is_always_reported
test_collision_lines_uninspectable_path_keeps_do_not_discard
test_collision_lines_unreadable_worktree_state_keeps_do_not_discard
test_collision_lines_unresolvable_default_branch_names_the_missing_check
test_collision_lines_path_with_backslash_names_every_claimant
test_collision_lines_path_with_tab_is_still_reported
test_collision_lines_newline_in_resolved_path_is_still_reported
test_collision_lines_groups_differently_spelled_newline_path
test_collision_lines_newline_and_literal_backslash_n_stay_distinct
test_collision_lines_trailing_newline_path_names_the_real_copy
test_collision_lines_groups_symlinked_spellings_of_one_copy
test_collision_lines_scaffolding_only_path_is_not_called_unlanded
test_collision_lines_record_removed_mid_scan_is_dropped
test_collision_lines_skips_remote_records
test_collision_lines_silent_on_clean_home
test_bootstrap_surfaces_collision_line
