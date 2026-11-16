#!/usr/bin/env bash
# Safety regressions for bin/fm-footprint.sh, one per way a removal could
# reach material it cannot prove disposable, each driven through the script's
# public commands with real files, real git, and the real deletion code; only
# Docker is a stand-in client, and a race is scheduled by wrapping a real
# command at the exact point the race needs.
#   - a scratch area holding any version-controlled work (an unpublished, a
#     published, a gate-only, or a bare detached-HEAD repository, or another
#     tool's marker) is kept whole at close and by the daily pass, and is
#     removed once that work is gone;
#   - work added to an area after its first check but before its removal is
#     caught by a second check of the set-aside copy;
#   - a set-aside folder left by an interrupted removal, or any folder with a
#     set-aside name, is never removed again, only reported;
#   - scratch ownership needs the key directory's recorded home identity;
#   - the daily pass removes an orphan only under the task's spawn lock, with
#     the record rechecked, and gives a reused task id a fresh area;
#   - Docker objects are selected by the task's random generation, so task
#     ids that lowercase alike, colliding short hashes, and a later task
#     reusing an id never share a label or a compose project, and a queued
#     retry never touches a later task;
#   - the old-folder preview offers only rebuildable directories holding no
#     version-controlled work and no record, nothing from a folder holding an
#     unsafe name, and its apply removes nothing when an entry changed before
#     or while it was set aside;
#   - an unknown flag or --help anywhere, including in a position, removes
#     nothing;
#   - a Docker listing that fails is recorded as unknown, queued, and retried.
# shellcheck disable=SC2016 # snippets are expanded by the child bash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-footprint-safety)
FOOTPRINT="$ROOT/bin/fm-footprint.sh"
unset FM_SCRATCH_ROOT_OVERRIDE
SHORT=$(mktemp -d /tmp/fmfs.XXXXXX) || fail "cannot create a short temp root"
SHORT=$(cd -P "$SHORT" && pwd -P) || fail "cannot resolve the short temp root"
FM_TEST_CLEANUP_DIRS+=("$SHORT")
export FM_FOOTPRINT_CACHE_NAMES='' FM_FOOTPRINT_SYSTEM_TMPDIR=''

new_home() {  # <name>: sets H, U, FB, and a short scratch root for H
  H="$TMP_ROOT/$1/home"
  U="$TMP_ROOT/$1/user"
  mkdir -p "$H/data" "$H/state" "$H/config" "$U"
  FB=$(fm_fakebin "$TMP_ROOT/$1")
  ln -sf "$(command -v jq)" "$FB/jq"
  ln -sf "$(command -v git)" "$FB/git"
  printf 'scratch-root %s\n' "$SHORT/$1" > "$H/config/footprint"
  export FM_FOOTPRINT_DOCKER=
}

fp() {
  HOME="$U" FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$H/state" \
    FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    PATH="$FB:$BASE_PATH" "$FOOTPRINT" "$@" 2>&1
}

lib() {
  HOME="$U" H="$H" LIB_DIR="$ROOT/bin" PATH="$FB:$BASE_PATH" \
    bash -c '. "$LIB_DIR/fm-timeout-lib.sh"; . "$LIB_DIR/fm-footprint-lib.sh"; '"$1" 2>&1
}

home_key() { lib 'fm_footprint_home_key "$H"'; }

scratch_for() {  # <id>: creates the task's scratch area as spawn does and prints it
  lib 'fm_footprint_task_env "$H/config" "$H" '"$1"' codex' | sed -n 's/^FM_TASK_SCRATCH=//p'
}

git_q() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@"; }

# local_repo <dir>: a repository with one commit that exists nowhere else.
local_repo() {
  mkdir -p "$1"
  git_q -C "$1" init -q
  printf 'unpublished work\n' > "$1/unique.txt"
  git_q -C "$1" add unique.txt
  git_q -C "$1" commit -qm 'unique local work'
}

# published_repo <dir> <bare>: a repository whose commit is pushed to <bare> as origin.
published_repo() {
  local_repo "$1"
  git init -q --bare "$2"
  git_q -C "$1" remote add origin "$2"
  git_q -C "$1" push -q origin HEAD:main
  git_q -C "$1" fetch -q origin
}

age() {  # <days> <path>...: set every path's times that many days back
  local days=$1 old stamp
  shift
  old=$(( $(date +%s) - days * 86400 ))
  stamp=$(TZ=UTC0 date -d "@$old" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -r "$old" +%Y%m%d%H%M.%S)
  TZ=UTC0 find "$@" -exec touch -h -t "$stamp" {} + 2>/dev/null
}

finished_folder() {  # <id>: an old task folder with its brief
  mkdir -p "$H/data/$1"
  printf 'brief\n' > "$H/data/$1/brief.md"
}

preview_id() { awk -F '\t' '$1 == "id" {print $2}' "$H/state/footprint-old-tasks.preview" 2>/dev/null; }

env_of() {  # <id> <NAME>: creates the task's area as spawn does and prints one export
  lib 'fm_footprint_task_env "$H/config" "$H" '"$1"' codex' | sed -n "s/^$2=//p"
}

# docker_standin <dir>: a Docker client over <dir>/objects ("id<TAB>label"
# lines) that lists by an exact label filter and removes by id, logging each
# call to <dir>/log. <dir>/on-info, when present, runs before info answers.
docker_standin() {
  mkdir -p "$1"
  : > "$1/objects"
  cat > "$FB/docker" <<SH
#!/usr/bin/env bash
dir="$1"
printf '%s\n' "\$*" >> "\$dir/log"
filter=
for a in "\$@"; do case "\$a" in label=*) filter=\${a#label=} ;; esac; done
case "\$1 \${2:-}" in
  "info "*) [ ! -x "\$dir/on-info" ] || "\$dir/on-info"; echo 29 ;;
  "ps "*|"network ls"|"volume ls"|"image ls") [ "\$1" = ps ] || exit 0; awk -F '\t' -v f="\$filter" '\$2 == f { print \$1 }' "\$dir/objects" ;;
  "rm "*) shift 3; for id in "\$@"; do awk -F '\t' -v i="\$id" '\$1 != i' "\$dir/objects" > "\$dir/objects.new"; mv "\$dir/objects.new" "\$dir/objects"; done ;;
esac
exit 0
SH
  chmod +x "$FB/docker"
  export FM_FOOTPRINT_DOCKER="$FB/docker"
}

# lock_hook <task-id> <script>: wraps ln so <script> runs right after the
# real spawn lock for <task-id> is taken (fm_lock_try_acquire uses ln -s).
lock_hook() {
  cat > "$FB/ln" <<SH
#!/usr/bin/env bash
"$(command -v ln)" "\$@" || exit \$?
for a in "\$@"; do
  case "\$a" in */.spawn-$1.lock*) [ -e "$TMP_ROOT/hook.done" ] || { : > "$TMP_ROOT/hook.done"; $2; } ;; esac
done
exit 0
SH
  chmod +x "$FB/ln"
  rm -f "$TMP_ROOT/hook.done"
}

# --- version-controlled work inside a scratch area ------------------------------

test_scratch_with_version_control_is_kept_whole() {
  local s sb sh sp sha out
  new_home vcs-scratch
  s=$(scratch_for task-u1)
  local_repo "$s/extra-checkout"
  printf 'cache\n' > "$s/tmp/cache.bin"
  sp=$(scratch_for task-p1)
  published_repo "$sp/extra" "$TMP_ROOT/vcs-scratch/origin.git"
  sb=$(scratch_for task-b1)
  local_repo "$TMP_ROOT/vcs-scratch/src"
  git clone -q --bare "$TMP_ROOT/vcs-scratch/src" "$sb/extra.git"
  sha=$(git -C "$sb/extra.git" rev-parse HEAD)
  git -C "$sb/extra.git" update-ref --no-deref HEAD "$sha"
  git -C "$sb/extra.git" update-ref -d refs/heads/main
  git -C "$sb/extra.git" remote remove origin 2>/dev/null || true
  rm -rf "$TMP_ROOT/vcs-scratch/src"
  [ -z "$(git -C "$sb/extra.git" for-each-ref)" ] || fail "the bare fixture must have no refs left"
  sh=$(scratch_for task-h1)
  mkdir -p "$sh/other/.hg"
  for pair in "task-u1 $s" "task-p1 $sp" "task-b1 $sb" "task-h1 $sh"; do
    # shellcheck disable=SC2086 # pair is "id path"
    out=$(fp task-close $pair)
    assert_contains "$out" "kept whole" "close must keep ${pair%% *}'s area"
    assert_contains "$out" "is version-controlled work" "close must name the reason for ${pair%% *}"
  done
  assert_present "$s/extra-checkout/unique.txt" "an unpublished checkout must survive close"
  assert_present "$s/tmp/cache.bin" "the whole area must be kept"
  assert_present "$sp/extra/unique.txt" "a published checkout must survive too: landing is not proof"
  assert_equals "$sha" "$(git -C "$sb/extra.git" rev-parse HEAD)" "a bare repository's detached HEAD commit must survive"
  assert_present "$sh/other/.hg" "another tool's repository must survive"
  assert_equals "kept kept kept kept" "$(awk -F '\t' '{print $8}' "$H/data/footprint-ledger.tsv" | tr '\n' ' ' | sed 's/ $//')" "the ledger must record each kept area"
  age 3 "$s" "$sp" "$sb" "$sh"
  out=$(fp sweep)
  assert_present "$s/extra-checkout/unique.txt" "the daily pass must keep it"
  assert_equals "$sha" "$(git -C "$sb/extra.git" rev-parse HEAD)" "the daily pass must keep the bare repository"
  assert_contains "$out" "finding: 4 orphaned scratch area(s) kept because they hold version-controlled work" "the daily pass must report them"
  # Once the work is gone the next pass removes the area.
  rm -rf "$sh/other"
  age 3 "$sh"
  fp sweep >/dev/null
  assert_absent "$sh" "an area whose version-controlled work is gone is removed"
  pass "a scratch area holding any version-controlled work is kept whole, then removed once that work is gone"
}

test_work_added_after_the_first_check_is_caught() {
  local s out
  new_home late-work
  s=$(scratch_for task-w1)
  printf 'old cache\n' > "$s/old-cache"
  age 3 "$s"
  # Right after the pass takes the task's spawn lock, a straggling process
  # starts a repository in the area: the first scan has already passed.
  lock_hook task-w1 "git init -q $s/late"
  out=$(fp sweep)
  assert_present "$s/late/.git" "work created between the first check and removal must survive"
  assert_present "$s/old-cache" "the whole area must be put back"
  assert_contains "$out" "Kept 1 orphaned scratch area(s) whole" "the pass must report the kept area"
  rm -f "$FB/ln"
  pass "a second check of the set-aside copy catches work added after the first check"
}

test_set_aside_folders_are_never_removed_by_name() {
  local s key base out q real_find
  new_home quarantine
  s=$(scratch_for task-q0)
  base=${s%/*}
  rm -rf "$s"
  # A folder that merely carries a set-aside name.
  local_repo "$base/.fm-closing-task-old.123/extra"
  mkdir -p "$base/.fm-reclaim-task-z.9"
  printf 'x\n' > "$base/.fm-reclaim-task-z.9/plain"
  out=$(fp sweep)
  assert_present "$base/.fm-closing-task-old.123/extra/unique.txt" "a set-aside name alone must never earn removal"
  assert_present "$base/.fm-reclaim-task-z.9/plain" "even one holding no repository is only reported"
  assert_contains "$out" "Left 2 set-aside scratch folder(s)" "the pass must report them"
  rm -rf "$base/.fm-closing-task-old.123" "$base/.fm-reclaim-task-z.9"
  # A real interrupted close: the deletion fails, the set-aside copy stays.
  s=$(scratch_for task-q1)
  printf 'x\n' > "$s/data"
  real_find=$(command -v find)
  cat > "$FB/find" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" != -delete ] || exit 42; done
exec "$real_find" "\$@"
SH
  chmod +x "$FB/find"
  out=$(fp task-close task-q1 "$s")
  rm -f "$FB/find"
  assert_contains "$out" "only partly removed" "the interrupted close must say so"
  q=$(find "$base" -maxdepth 1 -name '.fm-closing-task-q1*' | head -n 1)
  [ -n "$q" ] || fail "the interrupted close must leave its set-aside copy"
  local_repo "$q/late-extra"
  out=$(fp sweep)
  assert_present "$q/late-extra/unique.txt" "new work in a real set-aside copy must survive the next pass"
  assert_contains "$out" "Left 1 set-aside scratch folder(s)" "the pass must report it"
  assert_contains "$out" "Removed 0 orphaned scratch area(s)" "the pass must not count it removed"
  pass "set-aside folders, real or merely named so, are reported and never removed again"
}

# --- ownership of the scratch key directory --------------------------------

test_key_directory_identity_is_required() {
  local key other out s
  new_home ancestor-link
  key=$(home_key)
  other="$TMP_ROOT/ancestor-link/other-home-scratch"
  mkdir -p "$other/task-a"
  printf 'must survive\n' > "$other/task-a/other-task-work"
  chmod -R go-w "$other"
  mkdir -p "$SHORT/ancestor-link"
  chmod 700 "$SHORT/ancestor-link"
  ln -s "$other" "$SHORT/ancestor-link/$key"
  out=$(fp task-close task-a "$SHORT/ancestor-link/$key/task-a")
  assert_present "$other/task-a/other-task-work" "a linked key directory must never lead to another home's files"
  assert_contains "$out" "is not this home's area" "close must refuse"
  rm "$SHORT/ancestor-link/$key"
  mkdir -p "$SHORT/ancestor-link/$key/task-b"
  chmod 700 "$SHORT/ancestor-link/$key" "$SHORT/ancestor-link/$key/task-b"
  out=$(fp task-close task-b "$SHORT/ancestor-link/$key/task-b")
  assert_present "$SHORT/ancestor-link/$key/task-b" "a key directory with no recorded identity must not be trusted"
  printf '/some/other/home\n' > "$SHORT/ancestor-link/$key/.fm-home"
  out=$(fp task-close task-b "$SHORT/ancestor-link/$key/task-b")
  assert_present "$SHORT/ancestor-link/$key/task-b" "a key directory naming another home must not be trusted"
  out=$(fp sweep)
  assert_contains "$out" "does not carry this home's identity" "the daily pass must report the untrusted key directory"
  assert_present "$SHORT/ancestor-link/$key/task-b" "the daily pass must remove nothing under it"
  s=$(lib 'fm_footprint_task_env "$H/config" "$H" task-c codex' 2>&1)
  assert_contains "$s" "not a private directory owned by this user" "spawn must refuse a key directory naming another home"
  pass "scratch ownership needs the key directory's recorded home identity"
}

# --- the daily pass and a spawn reusing the task id ---------------------------

test_sweep_respects_the_spawn_lock_and_live_records() {
  local s s2 holder out
  new_home sweep-lock
  s=$(scratch_for task-r1)
  printf 'work\n' > "$s/unique.txt"
  s2=$(scratch_for task-r2)
  age 3 "$s" "$s2"
  ( STATE="$H/state" FM_HOME="$H" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; echo held; sleep 30' _ "$ROOT" "$H/state/.spawn-task-r1.lock" ) > "$TMP_ROOT/sweep-lock/holder.out" &
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$TMP_ROOT/sweep-lock/holder.out" 2>/dev/null && break; sleep 0.3; done
  out=$(fp sweep)
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  assert_present "$s/unique.txt" "an area whose task is being spawned must not be removed"
  assert_contains "$out" "Skipped 1 orphaned scratch area(s) whose task was being spawned" "the pass must say it skipped it"
  assert_absent "$s2" "an ordinary orphan beside it is still removed"
  printf 'worktree=/x\nscratch=%s\n' "$s" > "$H/state/task-r1.meta"
  rm -rf "$H/state/.spawn-task-r1.lock"
  fp sweep >/dev/null
  assert_present "$s/unique.txt" "a live task's area must stay"
  rm -f "$H/state/task-r1.meta"
  fp sweep >/dev/null
  assert_absent "$s" "the orphan is removed once its task is gone"
  s=$(scratch_for task-r1)
  assert_present "$s/tmp" "a spawn reusing the id must get a fresh area"
  pass "the daily pass removes an orphan only under its spawn lock with the record rechecked"
}

# --- Docker identity ---------------------------------------------------------------

test_docker_identity_is_the_task_generation() {
  local a b pa pb la lb out dir
  new_home compose
  dir="$TMP_ROOT/compose/docker"
  # Ids that lowercase alike, and a pair whose exact-id SHA-256 shares its
  # first six hex digits (b8de98), both valid task ids.
  for pair in "Task.A task_a" "aAAaAAAaaAaAaaaaaaaa AAaaaaaAAaaaAaaaaaaa"; do
    a=${pair% *} b=${pair#* }
    lib '. "$LIB_DIR/fm-pr-lib.sh"; fm_task_id_creation_valid '"$a"' && fm_task_id_creation_valid '"$b" >/dev/null ||
      fail "$a and $b must be valid task ids"
    pa=$(env_of "$a" COMPOSE_PROJECT_NAME)
    if [ -e "$SHORT/compose/$(home_key)/$b" ]; then
      # A case-insensitive filesystem: the two ids name one task record and
      # one area, so they cannot be two tasks. Closing one with no proven
      # area still removes nothing of the other's compose project.
      docker_standin "$dir"
      printf 'sibling\tcom.docker.compose.project=fm-%s-%s-b8de98\n' "$(home_key)" "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" > "$dir/objects"
      out=$(fp task-close "$a" "")
      assert_contains "$out" "no Docker object was removed" "a close with no proven area removes nothing"
      assert_grep sibling "$dir/objects" "the other id's object must survive"
      continue
    fi
    pb=$(env_of "$b" COMPOSE_PROJECT_NAME)
    la=$(env_of "$a" FM_DOCKER_LABEL) lb=$(env_of "$b" FM_DOCKER_LABEL)
    [ -n "$pa" ] && [ "$pa" != "$pb" ] || fail "$a and $b must not share a compose project ($pa)"
    [ -n "$la" ] && [ "$la" != "$lb" ] || fail "$a and $b must not share a label ($la)"
    docker_standin "$dir"
    printf 'sibling\tcom.docker.compose.project=%s\nsibling-l\t%s\nown\tcom.docker.compose.project=%s\n' "$pb" "$lb" "$pa" > "$dir/objects"
    printf 'worktree=/x\n' > "$H/state/$b.meta"
    out=$(fp task-close "$a" "$SHORT/compose/$(home_key)/$a")
    assert_contains "$out" "Docker: 1 labelled object(s) removed" "closing $a removes only its own object"
    assert_equals "sibling	com.docker.compose.project=$pb
sibling-l	$lb" "$(cat "$dir/objects")" "closing $a must not touch $b's objects"
  done
  # The generation survives a relaunch: the area keeps it.
  la=$(env_of task-g1 FM_DOCKER_LABEL)
  [ "$(env_of task-g1 FM_DOCKER_LABEL)" = "$la" ] || fail "a relaunch must keep the task's generation"
  pass "Docker objects are selected by the task's own random generation, never by an id that can collide"
}

test_docker_retry_never_touches_a_later_task() {
  local s gen dir out
  new_home retry-race
  dir="$TMP_ROOT/retry-race/docker"
  s=$(scratch_for task-a)
  gen=$(lib 'fm_footprint_task_generation '"$s")
  docker_standin "$dir"
  printf 'task-a\t1\t%s\n' "$gen" > "$H/state/footprint-docker-retry"
  # Exactly when the pass first asks Docker, a new task-a spawns through the
  # real spawn lock and its worker makes a container with its own label.
  cat > "$dir/on-info" <<SH
#!/usr/bin/env bash
[ -e "$dir/raced" ] && exit 0
: > "$dir/raced"
STATE="$H/state" FM_HOME="$H" bash -c '. "\$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "\$2/state/.spawn-task-a.lock" || exit 1; printf "worktree=/live/new\\n" > "\$2/state/task-a.meta"; fm_lock_release "\$2/state/.spawn-task-a.lock"' _ "$ROOT" "$H"
printf 'new-live\tfirstmate.task=$(home_key)/task-a/%s\n' "$gen" >> "$dir/objects"
SH
  chmod +x "$dir/on-info"
  out=$(fp sweep)
  assert_grep "new-live" "$dir/objects" "a task published while the retry starts must keep its container"
  assert_contains "$out" "Docker cleanup is pending for 1 closed task(s)" "the retry must stay pending while the id is live"
  # With the id closed again, a later generation's object is still never
  # selected: only the queued generation's is removed.
  rm -f "$H/state/task-a.meta" "$dir/on-info"
  printf 'old\tfirstmate.task=%s/task-a/%s\nlater\tfirstmate.task=%s/task-a/0123456789abcdef\n' "$(home_key)" "$gen" "$(home_key)" > "$dir/objects"
  fp sweep >/dev/null
  assert_equals "later	firstmate.task=$(home_key)/task-a/0123456789abcdef" "$(cat "$dir/objects")" "only the queued generation's object may be removed"
  assert_absent "$H/state/footprint-docker-retry" "the finished retry leaves the queue"
  pass "a queued Docker retry runs under the spawn lock and removes only its own generation"
}

# --- the old-folder preview -------------------------------------------

test_control_character_names_hide_the_whole_folder() {
  local victim crafted out id
  new_home newline
  victim=$(mktemp -d /tmp/fmvictim.XXXXXX)
  victim=$(cd -P "$victim" && pwd -P)
  FM_TEST_CLEANUP_DIRS+=("$victim")
  mkdir -p "$victim/.cache"
  printf 'other task work\n' > "$victim/.cache/must-survive"
  finished_folder old-n1
  mkdir -p "$H/data/old-n1/node_modules"
  crafted="$H/data/old-n1/prefix
$victim/.cache"
  mkdir -p "$crafted"
  printf 'own cache\n' > "$crafted/cache"
  finished_folder old-n2
  mkdir -p "$H/data/old-n2/node_modules/back\\slash"
  age 40 "$H/data/old-n1" "$H/data/old-n2"
  out=$(fp old-tasks)
  assert_not_contains "$out" "$victim" "a path outside the folder must never be offered"
  assert_not_contains "$out" "$H/data/old-n1" "nothing in a folder holding a control-character name may be offered"
  assert_not_contains "$out" "$H/data/old-n2" "nothing in a folder holding a backslash name may be offered"
  id=$(preview_id)
  [ -z "$id" ] || fp old-tasks --apply "$id" >/dev/null
  assert_present "$victim/.cache/must-survive" "the outside directory must survive"
  pass "a task folder holding a name with a control character or a backslash is never offered from"
}

test_only_rebuildable_directories_free_of_work_are_offered() {
  local out c origin
  new_home named
  finished_folder old-m1
  local_repo "$H/data/old-m1/node_modules/local-package"
  local_repo "$H/data/old-m1/.cache"
  mkdir -p "$H/data/old-m1/sub/.venv"
  printf 'report\n' > "$H/data/old-m1/sub/.venv/report.md"
  mkdir -p "$H/data/old-m1/plain/node_modules/p"
  printf 'x\n' > "$H/data/old-m1/plain/node_modules/p/i.js"
  # A published checkout whose ignored node_modules holds the only report.
  c="$H/data/old-m1/extra"
  origin="$TMP_ROOT/named/origin.git"
  published_repo "$c" "$origin"
  printf 'node_modules/\n' > "$c/.gitignore"
  git_q -C "$c" add .gitignore
  git_q -C "$c" commit -qm ignore
  git_q -C "$c" push -q origin HEAD:main
  mkdir -p "$c/node_modules" "$c/build/.next"
  printf 'irreplaceable\n' > "$c/node_modules/report.md"
  age 40 "$H/data/old-m1"
  out=$(fp old-tasks)
  assert_not_contains "$out" "$H/data/old-m1/node_modules" "a rebuildable directory holding a repository must not be offered"
  assert_not_contains "$out" "$H/data/old-m1/.cache" "a repository whose root has a rebuildable name must not be offered"
  assert_not_contains "$out" "$H/data/old-m1/sub/.venv" "a rebuildable directory holding a record must not be offered"
  assert_not_contains "$out" "$c" "nothing inside a repository, landed or not, may be offered"
  assert_contains "$out" "$H/data/old-m1/plain/node_modules" "an ordinary rebuildable directory is still offered"
  fp old-tasks --apply "$(preview_id)" >/dev/null
  assert_present "$H/data/old-m1/node_modules/local-package/unique.txt" "the nested repository must survive apply"
  assert_present "$H/data/old-m1/.cache/unique.txt" "the .cache repository must survive apply"
  assert_present "$H/data/old-m1/sub/.venv/report.md" "the record must survive apply"
  assert_present "$c/node_modules/report.md" "the record in the published checkout must survive apply"
  assert_absent "$H/data/old-m1/plain/node_modules" "the ordinary rebuildable directory is removed"
  pass "only rebuildable directories holding no version-controlled work and no record are offered"
}

test_preview_binds_contents_and_identity() {
  local id out e
  new_home preview-id
  finished_folder old-p1
  e="$H/data/old-p1/node_modules"
  mkdir -p "$e"
  printf 'before' > "$e/data"
  age 40 "$H/data/old-p1"
  fp old-tasks >/dev/null
  id=$(preview_id)
  printf 'after!' > "$e/data"
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "changed since preview" "a same-size edit after the preview must refuse"
  assert_present "$e/data" "a refused apply must remove nothing"
  fp old-tasks >/dev/null
  id=$(preview_id)
  mv "$e" "$H/data/old-p1/was"
  mkdir -p "$e"
  cp -p "$H/data/old-p1/was/data" "$e/data"
  age 40 "$H/data/old-p1"
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "changed since preview" "a replaced entry after the preview must refuse"
  assert_present "$e/data" "a refused apply must remove nothing"
  rm -rf "$H/data/old-p1/was"
  # A replacement after apply checked the preview, at the task's spawn lock:
  # the set-aside copy no longer matches, so everything goes back.
  age 40 "$H/data/old-p1"
  fp old-tasks >/dev/null
  id=$(preview_id)
  local_repo "$TMP_ROOT/preview-id/replacement"
  lock_hook old-p1 "mv $e $TMP_ROOT/preview-id/saved; mv $TMP_ROOT/preview-id/replacement $e"
  out=$(fp old-tasks --apply "$id")
  rm -f "$FB/ln"
  assert_present "$TMP_ROOT/preview-id/saved/data" "the swap must have happened"
  assert_present "$e/unique.txt" "the replacement must be put back, not removed"
  assert_contains "$out" "changed while it was being set aside; nothing removed" "apply must refuse"
  # Unchanged, the same apply removes the entry.
  rm -rf "$e"
  mv "$TMP_ROOT/preview-id/saved" "$e"
  age 40 "$H/data/old-p1"
  fp old-tasks >/dev/null
  out=$(fp old-tasks --apply "$(preview_id)")
  assert_absent "$e" "an unchanged entry is removed"
  assert_contains "$out" "Removed 1 entries" "apply must report the removal"
  pass "apply removes only entries whose set-aside copy matches the preview exactly"
}

# --- flags on destructive commands -----------------------------------------

test_unknown_flags_and_help_remove_nothing() {
  local s out rc dir
  new_home flags
  s=$(scratch_for task-f1)
  age 3 "$s"
  dir="$TMP_ROOT/flags/docker"
  docker_standin "$dir"
  printf 'c1\t%s\n' "$(env_of task-f1 FM_DOCKER_LABEL)" > "$dir/objects"
  for args in "sweep --help" "task-close task-f1 --help" "task-close task-f1 $s -h" "owns-scratch task-f1 --help" "old-tasks --apply --help"; do
    # shellcheck disable=SC2086 # args is a fixed word list
    out=$(fp $args)
    rc=$?
    expect_code 0 "$rc" "'$args' must succeed"
    assert_contains "$out" "fm-footprint.sh" "'$args' must print the help"
  done
  for args in "sweep --dryrun" "trim-caches --dryrun" "sweep --dry-run --dry-run" "check now" "caches --jsn" "task-close task-f1 --dry-run" "task-close task-f1 $s --force" "owns-scratch -x $s"; do
    # shellcheck disable=SC2086 # args is a fixed word list
    out=$(fp $args)
    rc=$?
    expect_code 2 "$rc" "'$args' must be refused"
    assert_contains "$out" "unknown argument" "'$args' must name the problem"
  done
  assert_present "$s" "no help or refused command may remove the area"
  assert_grep c1 "$dir/objects" "no help or refused command may remove the task's Docker object"
  assert_absent "$dir/log" "no help or refused command may even ask Docker"
  pass "an unknown flag or --help anywhere, positions included, removes nothing"
}

# --- Docker inventory failures ------------------------------------------------

test_docker_listing_failure_is_unknown_and_retried() {
  local s out dir
  new_home docker-fail
  dir="$TMP_ROOT/docker-fail/docker"
  s=$(scratch_for task-d1)
  docker_standin "$dir"
  printf 'c1\t%s\n' "$(env_of task-d1 FM_DOCKER_LABEL)" > "$dir/objects"
  mv "$FB/docker" "$FB/docker.real"
  cat > "$FB/docker" <<SH
#!/usr/bin/env bash
[ "\$1" = info ] || [ ! -e "$dir/listing.broken" ] || exit 42
exec "$FB/docker.real" "\$@"
SH
  chmod +x "$FB/docker"
  : > "$dir/listing.broken"
  out=$(fp task-close task-d1 "$s")
  assert_contains "$out" "Docker did not list the task's objects; its cleanup is queued" "a failed listing must not read as removed"
  assert_equals "unknown" "$(awk -F '\t' 'END {print $7}' "$H/data/footprint-ledger.tsv")" "the ledger must record unknown"
  assert_grep "task-d1	" "$H/state/footprint-docker-retry" "the task must be queued for a retry"
  out=$(fp sweep)
  assert_contains "$out" "finding: Docker cleanup is pending for 1 closed task(s)" "a pending retry must be reported"
  rm -f "$dir/listing.broken"
  fp sweep >/dev/null
  assert_equals "" "$(cat "$dir/objects")" "the daily pass must retry and remove the object"
  assert_absent "$H/state/footprint-docker-retry" "a finished retry must leave the queue"
  assert_equals "docker-retry" "$(awk -F '\t' 'END {print $7}' "$H/data/footprint-ledger.tsv")" "the retry must be in the ledger"
  pass "a Docker listing failure is recorded as unknown, queued, and retried by the daily pass"
}

fm_test_run \
  test_scratch_with_version_control_is_kept_whole \
  test_work_added_after_the_first_check_is_caught \
  test_set_aside_folders_are_never_removed_by_name \
  test_key_directory_identity_is_required \
  test_sweep_respects_the_spawn_lock_and_live_records \
  test_docker_identity_is_the_task_generation \
  test_docker_retry_never_touches_a_later_task \
  test_control_character_names_hide_the_whole_folder \
  test_only_rebuildable_directories_free_of_work_are_offered \
  test_preview_binds_contents_and_identity \
  test_unknown_flags_and_help_remove_nothing \
  test_docker_listing_failure_is_unknown_and_retried
