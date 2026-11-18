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
#   - a process left in an orphaned area, or holding a file open there, keeps
#     the area, and so does a process table that cannot be read or a listing
#     that leaves out any live process; work a writer finished just before
#     the process check is caught by the content check after it; a running
#     process is never ended to free space;
#   - a set-aside folder left by an interrupted removal, or any folder with a
#     set-aside name, is never removed again, only reported;
#   - scratch ownership needs the key directory's recorded home identity;
#   - the daily pass removes an orphan only under the task's spawn lock, with
#     the record rechecked, and gives a reused task id a fresh area;
#   - Docker objects are selected by the task's random generation, so task
#     ids that lowercase alike, colliding short hashes, and a later task
#     reusing an id never share a label or a compose project, and a queued
#     retry never touches a later task, and a close that queues a retry
#     while the daily pass rewrites the queue keeps its entry;
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
# Processes started with a path under it are ended at exit too.
printf '%s\n' "$SHORT" >> "$FM_TEST_CLEANUP_REGISTRY"
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
# call to <dir>/log. <dir>/on-info, when present, runs before info answers,
# and while <dir>/down exists the daemon does not answer.
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
  "info "*) [ ! -x "\$dir/on-info" ] || "\$dir/on-info"; [ ! -e "\$dir/down" ] || exit 1; echo 29 ;;
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
  local s key base out q
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
  # The removal is interrupted: something new appears in the area while it
  # is being removed, so the area cannot be removed whole.
  printf '#!/usr/bin/env bash\n[ "$2" = . ] && : > "$1/appeared-late"\nexit 0\n' > "$FB/remove-hook"
  chmod +x "$FB/remove-hook"
  out=$(FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_REMOVE_HOOK="$FB/remove-hook" fp task-close task-q1 "$s")
  rm -f "$FB/remove-hook"
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

# --- processes still using an orphaned area ----------------------------------

# stray <dir> <cmd>: starts <cmd> in the background with its working directory
# in <dir>, exiting on its own within a minute, and waits until it runs there;
# records the pid in STRAYS. <cmd> ends with exec, so that pid is the process
# holding the directory and stopping it leaves nothing behind.
STRAYS=()
stray() {
  local ready n=0
  ready=$(mktemp "$TMP_ROOT/stray.XXXXXX") && rm -f "$ready"
  (cd "$1" && : > "$ready" && exec bash -c "$2") </dev/null >/dev/null 2>&1 &
  STRAYS+=("$!")
  until [ -e "$ready" ] || [ "$n" -ge 100 ]; do sleep .05; n=$((n + 1)); done
  [ -e "$ready" ] || fail "the stray process never started"
  sleep .2
}

stop_strays() {
  local pid
  for pid in "${STRAYS[@]+"${STRAYS[@]}"}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
  STRAYS=()
}

test_a_process_still_using_an_orphan_keeps_it() {
  local idle busy held writer out n
  new_home orphan-proc
  idle=$(scratch_for task-i1)
  printf 'cache\n' > "$idle/cache"
  busy=$(scratch_for task-c1)
  printf 'cache\n' > "$busy/cache"
  held=$(scratch_for task-f1)
  printf 'log\n' > "$held/held.log"
  writer=$(scratch_for task-wr)
  printf 'cache\n' > "$writer/cache"
  # A process rooted in one area, one with its working directory elsewhere
  # holding a file open in another, and a writer that commits new work in
  # its area once released, exactly as a straggler left by a crash would.
  stray "$busy" 'exec sleep 60'
  stray "$TMP_ROOT" "exec 3>>'$held/held.log'; exec sleep 60"
  stray "$writer" "n=0; while [ ! -e '$TMP_ROOT/orphan-proc/go' ] && [ \$n -lt 600 ]; do sleep .1; n=\$((n+1)); done
    git -c init.defaultBranch=main init -q late && printf unique > late/unique.txt &&
    git -C late add unique.txt && git -C late -c user.email=t@example.invalid -c user.name=t commit -qm late"
  age 3 "$idle" "$busy" "$held" "$writer"
  out=$(fp sweep)
  assert_absent "$idle" "an idle orphan must still be removed"
  assert_contains "$out" "Removed 1 orphaned scratch area(s)" "only the idle orphan may be removed"
  assert_present "$busy/cache" "an orphan a process works in must be kept"
  assert_present "$held/held.log" "an orphan holding a file a process has open must be kept"
  assert_present "$writer/cache" "an orphan whose writer still runs must be kept"
  assert_contains "$out" "Kept 3 orphaned scratch area(s) a running process still works in or holds open" "the pass must report the kept areas"
  assert_contains "$out" "finding: 3 orphaned scratch area(s) kept because a process still uses them" "the kept areas must be a finding"
  : > "$TMP_ROOT/orphan-proc/go"
  n=0
  until [ -f "$writer/late/unique.txt" ] && git -C "$writer/late" rev-parse -q --verify HEAD >/dev/null 2>&1 || [ "$n" -ge 100 ]; do
    sleep .1; n=$((n + 1))
  done
  assert_present "$writer/late/unique.txt" "the writer's new work must land in the kept area"
  git -C "$writer/late" rev-parse -q --verify HEAD >/dev/null || fail "the writer's commit must exist"
  stop_strays
  # Once the processes are gone, the daily pass removes what holds no work
  # and still keeps the writer's repository.
  age 3 "$busy" "$held" "$writer"
  out=$(fp sweep)
  assert_absent "$busy" "an orphan must be removed once its process is gone"
  assert_absent "$held" "an orphan must be removed once its open file is closed"
  assert_present "$writer/late/unique.txt" "the writer's repository keeps its area whole"
  assert_contains "$out" "Removed 2 orphaned scratch area(s)" "the idle areas must now be removed"
  pass "an orphaned area a running process works in or holds open is kept, and removed once idle"
}

test_an_unreadable_process_table_removes_nothing() {
  local s s2 out empty real_lsof real_readlink
  new_home proc-unknown
  s=$(scratch_for task-x1)
  printf 'cache\n' > "$s/cache"
  age 3 "$s"
  # macOS lists working directories with lsof; Linux reads /proc. Both are
  # made unreadable here.
  printf '#!/usr/bin/env bash\nexit 2\n' > "$FB/lsof"
  chmod +x "$FB/lsof"
  empty="$TMP_ROOT/proc-unknown/no-proc"
  mkdir -p "$empty"
  out=$(FM_PROC_ROOT_OVERRIDE="$empty" fp sweep)
  assert_present "$s/cache" "without a process table, an orphan must be kept"
  assert_contains "$out" "Kept 1 orphaned scratch area(s) because the running processes could not be listed" "the pass must say why"
  s2=$(scratch_for task-x2)
  printf 'cache\n' > "$s2/cache"
  out=$(FM_PROC_ROOT_OVERRIDE="$empty" fp task-close task-x2 "$s2")
  assert_present "$s2/cache" "without a process table, a closing area must be kept"
  assert_contains "$out" "the running processes could not be listed" "close must say why"
  rm -f "$FB/lsof"
  # Working directories readable, but the open-file listing refused, as an
  # lsof that rejects its options does: exit 1, which also means "none".
  real_lsof=$(command -v lsof || true)
  real_readlink=$(command -v readlink)
  cat > "$FB/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in *" cwd "*) exec "$real_lsof" "\$@" ;; esac
echo "usage: lsof" >&2
exit 1
SH
  cat > "$FB/readlink" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in */fd/*) exit 1 ;; esac; done
exec "$real_readlink" "\$@"
SH
  chmod +x "$FB/lsof" "$FB/readlink"
  out=$(fp sweep)
  assert_present "$s/cache" "an open-file listing that was refused must keep the orphan"
  assert_contains "$out" "because the running processes could not be listed" "a refused open-file listing must be reported"
  rm -f "$FB/lsof" "$FB/readlink"
  out=$(fp sweep)
  assert_absent "$s" "with the process table readable again, the orphan is removed"
  pass "a process table or open-file listing that cannot be read keeps every area"
}

test_a_surviving_process_keeps_a_closing_area() {
  local s out
  new_home close-proc
  s=$(scratch_for task-k1)
  printf 'cache\n' > "$s/cache"
  stray "$s" 'exec sleep 60'
  out=$(fp task-close task-k1 "$s")
  assert_present "$s/cache" "an area a surviving process works in must be kept at close"
  assert_contains "$out" "kept whole" "close must report the kept area"
  assert_contains "$out" "a running process still works in it" "close must name the reason"
  stop_strays
  out=$(fp task-close task-k1 "$s")
  assert_absent "$s" "with the process gone, close removes the area"
  pass "close keeps an area a process that survived teardown still uses"
}

# at_step <step> <writer-pid> <go-file> <dir> [tool...]: makes one removal
# step, the first time it starts after <dir> was set aside, release the
# writer and wait for it to finish and exit before the step goes on. Steps:
# freeze (the engine's freeze), procs (the tools that read the process
# table: lsof and ps on macOS, find, readlink and cat on /proc on Linux),
# delete (the engine's removal, once it has made the copy's top directory
# writable again for its own entries, through FM_FOOTPRINT_TEST_REMOVE_HOOK).
at_step() {
  local step=$1 tool real match
  shift
  local pid=$1 go=$2 dir=$3
  shift 3
  local wait_for="[ ! -e '$go.fired' ] && [ ! -e '$dir' ]"
  local release
  # Written through a file: bash 3.2 cannot parse a case inside a here
  # document inside a command substitution.
  cat > "$FB/release.part" <<SH
      : > "$go.fired"
      : > "$go"
      n=0
      [ "$pid" != 0 ] || while [ ! -e "$go.result" ] && [ "\$n" -lt 200 ]; do sleep .05; n=\$((n + 1)); done
      while [ "$pid" != 0 ] && kill -0 "$pid" 2>/dev/null && [ "\$n" -lt 200 ]; do
        case "\$("$(command -v ps)" -o stat= -p "$pid" 2>/dev/null)" in *Z*) break ;; esac
        sleep .05; n=\$((n + 1))
      done
SH
  release=$(cat "$FB/release.part")
  if [ "$step" = delete ]; then
    cat > "$FB/remove-hook" <<SH
#!/usr/bin/env bash
if [ "\$2" = . ] && $wait_for; then
$release
fi
exit 0
SH
    chmod +x "$FB/remove-hook"
    export FM_FOOTPRINT_TEST_REMOVE_HOOK="$FB/remove-hook" FM_FOOTPRINT_TEST_SEAMS=1
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    case "$step" in
      freeze) set -- python3 ;;
      procs) set -- lsof ps find readlink cat ;;
    esac
  fi
  for tool in "$@"; do
    real=$(command -v "$tool") || continue
    case "$step" in
      freeze) match="python3*fm-footprint-fs.py*freeze*" ;;
      procs) match="lsof*|ps*|*/proc/*" ;;
    esac
    cat > "$FB/$tool" <<SH
#!/usr/bin/env bash
case "$tool \$*" in
  $match)
    if $wait_for; then
$release
    fi
    ;;
esac
exec "$real" "\$@"
SH
    chmod +x "$FB/$tool"
  done
}

unhook() {
  command rm -f "$FB/lsof" "$FB/ps" "$FB/find" "$FB/readlink" "$FB/cat" "$FB/chmod" "$FB/rm" "$FB/python3" "$FB/remove-hook" "$FB/hidden-pids" "$FB/release.part"
  unset FM_FOOTPRINT_TEST_REMOVE_HOOK FM_FOOTPRINT_TEST_SEAMS
}

# writer_in <dir> <go-file> <subdir>: a stray process rooted in <dir> that,
# once <go-file> appears, tries to commit new work in <subdir> of its working
# directory (which follows <dir> when it is set aside), records "ok" or
# "failed" in <go-file>.result, and exits.
writer_in() {
  # It waits without starting any process (a read with a timeout on a FIFO
  # nobody writes), so it has no short-lived children while it waits.
  mkfifo "$2.fifo"
  stray "$1" "exec 9<>'$2.fifo'; n=0; while [ ! -e '$2' ] && [ \$n -lt 60 ]; do read -t 1 -u 9 x || :; n=\$((n+1)); done
    if mkdir -p '$3' && git -c init.defaultBranch=main init -q '$3' && printf unique > '$3/unique.txt' &&
      git -C '$3' add unique.txt && git -C '$3' -c user.email=t@example.invalid -c user.name=t commit -qm late 2>/dev/null; then
      echo ok > '$2.result'
    else
      echo failed > '$2.result'
    fi"
}

# no_lost_commit <go-file> <path>: a commit the writer reported made must
# still exist at <path> (or under its put-back area).
no_lost_commit() {
  [ -e "$1.result" ] || fail "the writer never reported"
  if [ "$(cat "$1.result")" = ok ]; then
    [ -f "$2" ] || fail "a commit the writer made was removed: $2"
  fi
}

test_work_finished_before_the_freeze_is_caught() {
  local s out go entry id
  new_home quiet-writer
  go="$TMP_ROOT/quiet-writer/go"
  # The daily pass: the writer commits and exits just before the freeze.
  s=$(scratch_for task-q1)
  printf 'cache\n' > "$s/cache"
  writer_in "$s" "$go" late
  age 3 "$s"
  at_step freeze "${STRAYS[${#STRAYS[@]}-1]}" "$go" "$s"
  out=$(fp sweep)
  unhook
  assert_present "$go.fired" "the writer must have been released at the freeze"
  assert_equals ok "$(cat "$go.result")" "the writer's commit must succeed before the freeze"
  assert_present "$s/late/unique.txt" "work committed just before the freeze must survive the daily pass"
  assert_contains "$out" "Kept 1 orphaned scratch area(s) whole because they hold version-controlled work" "the pass must keep the area for its work"
  stop_strays
  # Close: the same interleaving.
  rm -f "$go" "$go.fired" "$go.result" "$go.fifo"
  s=$(scratch_for task-q2)
  printf 'cache\n' > "$s/cache"
  writer_in "$s" "$go" late
  at_step freeze "${STRAYS[${#STRAYS[@]}-1]}" "$go" "$s"
  out=$(fp task-close task-q2 "$s")
  unhook
  assert_equals ok "$(cat "$go.result")" "the writer's commit must succeed before close's freeze"
  assert_present "$s/late/unique.txt" "work committed just before close's freeze must survive"
  assert_contains "$out" "is version-controlled work" "close must keep the area for its work"
  stop_strays
  # Old-folder apply: the writer turns a previewed entry into a repository.
  rm -f "$go" "$go.fired" "$go.result" "$go.fifo"
  finished_folder old-q3
  entry="$H/data/old-q3/node_modules"
  mkdir -p "$entry/pkg"
  printf 'module\n' > "$entry/pkg/index.js"
  age 40 "$H/data/old-q3"
  fp old-tasks >/dev/null
  id=$(preview_id)
  [ -n "$id" ] || fail "the preview must offer the entry"
  writer_in "$entry" "$go" late
  at_step freeze "${STRAYS[${#STRAYS[@]}-1]}" "$go" "$entry"
  out=$(fp old-tasks --apply "$id")
  unhook
  assert_equals ok "$(cat "$go.result")" "the writer's commit must succeed before apply's freeze"
  assert_present "$entry/late/unique.txt" "work committed just before apply's freeze must survive"
  assert_contains "$out" "nothing removed" "apply must remove nothing"
  stop_strays
  # Positive control: an idle area is still removed by the daily pass.
  s=$(scratch_for task-q4)
  printf 'cache\n' > "$s/cache"
  age 3 "$s"
  out=$(fp sweep)
  assert_absent "$s" "an idle orphan must still be removed"
  pass "work a writer finishes just before the freeze is caught by the content check at the end"
}

test_a_frozen_area_refuses_new_work() {
  local s out go step kept_copy
  new_home frozen-writer
  go="$TMP_ROOT/frozen-writer/go"
  # Released after the freeze, at the process check: the writer's work
  # cannot be made at all. Released during the final removal, once the
  # directories are writable again: its work can be made, but only the
  # entries the verified snapshot listed are removed, so the work and the
  # area around it stay.
  for step in procs delete; do
    rm -f "$go" "$go.fired" "$go.result" "$go.fifo"
    s=$(scratch_for "task-f-$step")
    printf 'cache\n' > "$s/cache"
    writer_in "$s" "$go" late
    age 3 "$s"
    at_step "$step" "${STRAYS[${#STRAYS[@]}-1]}" "$go" "$s"
    # At the removal step the writer is one the process check cannot see,
    # the worst case; otherwise the check would keep the area for it.
    [ "$step" = procs ] || hide_from_listing "${STRAYS[${#STRAYS[@]}-1]}"
    out=$(fp sweep)
    unhook
    assert_present "$go.fired" "the writer must have been released at the $step step"
    if [ "$step" = procs ]; then
      assert_equals failed "$(cat "$go.result")" "a frozen area must refuse new work at the $step step"
      no_lost_commit "$go" "$s/late/unique.txt"
    else
      assert_equals ok "$(cat "$go.result")" "the writer must manage to commit during the removal"
      kept_copy=$(find "${s%/*}" -maxdepth 3 -path "*/.fm-reclaim-task-f-$step.*/late/unique.txt" | head -n 1)
      [ -n "$kept_copy" ] || fail "work made during the removal must stay in the set-aside copy"
      assert_contains "$out" "Left 1 set-aside scratch folder(s)" "what is left must be reported"
      git -C "${kept_copy%/unique.txt}" rev-parse -q --verify HEAD >/dev/null || fail "the commit made during the removal must be intact"
    fi
    stop_strays
  done
  pass "a frozen area refuses new work, and work made during the removal itself is never removed"
}

# A process rooted in the area forks while the removal runs and then exits;
# its child is hidden from every listing (the gap the fifth review
# found on Linux), so the area goes on to removal, and the child is released
# to commit during the final removal itself. Only the entries the verified
# snapshot listed are removed, so its commit and the folder around it stay.
test_a_child_born_after_the_listing_loses_nothing() {
  local s out go mode entry id kept_copy
  new_home fork-child
  go="$TMP_ROOT/fork-child/go"
  for mode in sweep close apply; do
    rm -f "$go" "$go.fired" "$go.result" "$go.fork" "$go.fork.fired" "$go.fifo" "$go.child" "$TMP_ROOT/hidden.extra"
    if [ "$mode" = apply ]; then
      finished_folder old-fk
      entry="$H/data/old-fk/node_modules"
      mkdir -p "$entry/pkg"
      printf 'module\n' > "$entry/pkg/index.js"
      age 40 "$H/data/old-fk"
      fp old-tasks >/dev/null
      id=$(preview_id)
      [ -n "$id" ] || fail "the preview must offer the entry"
      s=$entry
    else
      s=$(scratch_for "task-fk-$mode")
      printf 'cache\n' > "$s/cache"
      age 3 "$s"
    fi
    mkfifo "$go.fifo"
    # The parent waits without children, forks the child once released, waits
    # until the child has recorded itself as hidden, and exits.
    stray "$s" "exec 9<>'$go.fifo'; n=0; while [ ! -e '$go.fork' ] && [ \$n -lt 60 ]; do read -t 1 -u 9 x || :; n=\$((n+1)); done
      bash -c 'echo \$\$ >> \"$TMP_ROOT/hidden.extra\"; echo \$\$ > \"$go.child\"; exec 8<>\"$go.fifo\"; n=0
        while [ ! -e \"$go\" ] && [ \$n -lt 60 ]; do read -t 1 -u 8 x || :; n=\$((n+1)); done
        if mkdir -p late && git -c init.defaultBranch=main init -q late && printf unique > late/unique.txt &&
          git -C late add unique.txt && git -C late -c user.email=t@example.invalid -c user.name=t commit -qm late 2>/dev/null; then
          echo ok > \"$go.result\"
        else
          echo failed > \"$go.result\"
        fi' </dev/null >/dev/null 2>&1 &
      n=0; while [ ! -s '$go.child' ] && [ \$n -lt 100 ]; do read -t 1 -u 9 x || :; n=\$((n+1)); done
      exit 0"
    # The parent forks as the area is frozen and exits; the child is hidden
    # from the process check; the final removal releases the child.
    at_step freeze "${STRAYS[${#STRAYS[@]}-1]}" "$go.fork" "$s"
    hide_from_listing "${STRAYS[${#STRAYS[@]}-1]}"
    at_step delete 0 "$go" "$s"
    case "$mode" in
      sweep) out=$(fp sweep) ;;
      close) out=$(fp task-close "task-fk-$mode" "$s") ;;
      apply) out=$(fp old-tasks --apply "$id") ;;
    esac
    unhook
    assert_present "$go.fork.fired" "the parent must have forked during the $mode removal"
    n=0; until [ -e "$go.result" ] || [ "$n" -ge 100 ]; do : > "$go"; sleep .05; n=$((n + 1)); done
    [ -e "$go.result" ] || fail "the child never reported in $mode"
    if [ "$(cat "$go.result")" = ok ]; then
      kept_copy=$(find "${s%/*}" -maxdepth 3 -path '*/late/unique.txt' | head -n 1)
      [ -n "$kept_copy" ] || fail "the child's commit made during the $mode removal was removed"
      git -C "${kept_copy%/unique.txt}" rev-parse -q --verify HEAD >/dev/null || fail "the child's commit must be intact after $mode"
    fi
    kill "$(cat "$go.child" 2>/dev/null)" 2>/dev/null || true
    stop_strays
  done
  pass "a child born after the process listing, hidden from it, loses nothing during the removal"
}

# hide_from_listing <pid>: the process check runs but this process and all
# of its descendants are left out of every source consistently, so the
# listing looks complete and idle, as processes the check cannot see would.
hide_from_listing() {
  local pid=$1 real_ps real_lsof real_find
  real_ps=$(command -v ps)
  real_lsof=$(command -v lsof || true)
  real_find=$(command -v find)
  cat > "$FB/hidden-pids" <<SH
#!/usr/bin/env bash
{ echo "$pid"; cat "$TMP_ROOT/hidden.extra" 2>/dev/null; } > "$TMP_ROOT/hidden.roots"
"$real_ps" -A -o pid= -o ppid= | awk 'FILENAME == ARGV[1] { root[\$1] = 1; next } { parent[\$1] = \$2 }
  END { for (p in parent) { q = p; while (q != "" && q != 0) { if (q in root) { print p; break }; if (q == 1) break; q = parent[q] } } }' "$TMP_ROOT/hidden.roots" -
SH
  cat > "$FB/ps" <<SH
#!/usr/bin/env bash
"$FB/hidden-pids" > "$TMP_ROOT/hidden.pids"
"$real_ps" "\$@" | awk 'FILENAME == ARGV[1] { h[\$1] = 1; next } !(\$1 in h)' "$TMP_ROOT/hidden.pids" -
SH
  cat > "$FB/lsof" <<SH
#!/usr/bin/env bash
"$FB/hidden-pids" > "$TMP_ROOT/hidden.pids.lsof"
"$real_lsof" "\$@" > "$TMP_ROOT/hidden.lsof"
rc=\$?
awk 'FILENAME == ARGV[1] { h[\$1] = 1; next } /^p/ { skip = (substr(\$0, 2) in h) } !skip' "$TMP_ROOT/hidden.pids.lsof" "$TMP_ROOT/hidden.lsof"
exit \$rc
SH
  cat > "$FB/find" <<SH
#!/usr/bin/env bash
case "\$*" in
  *-user*)
    "$FB/hidden-pids" > "$TMP_ROOT/hidden.pids.find"
    "$real_find" "\$@" | awk 'FILENAME == ARGV[1] { h[\$1] = 1; next } { n = \$0; sub(/.*\//, "", n) } !(n in h)' "$TMP_ROOT/hidden.pids.find" - ;;
  *) exec "$real_find" "\$@" ;;
esac
SH
  chmod +x "$FB/hidden-pids" "$FB/ps" "$FB/lsof" "$FB/find"
}

test_a_write_during_the_grace_window_keeps_the_area() {
  local s out holder
  new_home grace-writer
  printf 'scratch-root %s\nremoval-grace-seconds 3\n' "$SHORT/grace-writer" > "$H/config/footprint"
  s=$(scratch_for task-g1)
  printf 'log\n' > "$s/out.log"
  # A writer outside the area that opened its file before the freeze and is
  # invisible to the process check appends during the grace window.
  stray "$TMP_ROOT" "exec 3>>'$s/out.log'; n=0; while [ ! -e '$TMP_ROOT/grace-writer/go' ] && [ \$n -lt 600 ]; do sleep .05; n=\$((n+1)); done
    sleep 1; echo 'unique output' >&3; exec sleep 30"
  holder=${STRAYS[${#STRAYS[@]}-1]}
  age 3 "$s"
  hide_from_listing "$holder"
  # Release it once the area is frozen.
  local real_python
  real_python=$(command -v python3)
  cat > "$FB/python3" <<SH
#!/usr/bin/env bash
"$real_python" "\$@"; rc=\$?
case "\$*" in *fm-footprint-fs.py*freeze*) : > "$TMP_ROOT/grace-writer/go" ;; esac
exit \$rc
SH
  chmod +x "$FB/python3"
  out=$(FM_FOOTPRINT_REMOVAL_GRACE_OVERRIDE='' fp sweep)
  unhook
  assert_grep "unique output" "$s/out.log" "output written during the grace window must survive"
  assert_contains "$out" "Kept 1 orphaned scratch area(s) that changed while they waited to be removed" "the pass must keep the changed area"
  [ -w "$s/out.log" ] || fail "a kept area must get its write permission back"
  stop_strays
  out=$(fp sweep)
  assert_absent "$s" "with the writer gone, the area is removed"
  pass "a write during the grace window, by a process the check cannot see, keeps the area"
}

test_a_writable_memory_mapping_keeps_the_area() {
  local s out py
  py=$(command -v python3 || true)
  if [ -z "$py" ] || ! "$py" -c 'import mmap' 2>/dev/null; then
    printf 'ok - # SKIP python3 with mmap is not available\n'
    return 0
  fi
  new_home mmap-writer
  s=$(scratch_for task-m1)
  # A process outside the area maps a file in it, closes the descriptor,
  # and keeps the writable mapping.
  stray "$TMP_ROOT" "exec '$py' -c 'import mmap,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); os.ftruncate(fd,4096)
m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE); os.close(fd)
open(sys.argv[2],\"w\").close(); time.sleep(60)' '$s/result.bin' '$TMP_ROOT/mmap-writer/ready'"
  n=0; until [ -e "$TMP_ROOT/mmap-writer/ready" ] || [ "$n" -ge 100 ]; do sleep .05; n=$((n + 1)); done
  age 3 "$s"
  out=$(fp sweep)
  assert_present "$s/result.bin" "a file a live process has mapped for writing must survive"
  assert_contains "$out" "a running process still works in or holds open" "the pass must name the mapping"
  out=$(fp task-close task-m1 "$s")
  assert_present "$s/result.bin" "close must keep a mapped file"
  stop_strays
  out=$(fp task-close task-m1 "$s")
  assert_absent "$s" "with the mapping gone, the area is removed"
  pass "a writable memory mapping whose descriptor is closed keeps the area"
}

test_a_partial_open_file_listing_keeps_everything() {
  local s out holder real_lsof real_readlink
  new_home partial-listing
  s=$(scratch_for task-p1)
  mkdir -p "$s/inner"
  printf 'log\n' > "$s/inner/held.log"
  stray "$TMP_ROOT" "exec 3>>'$s/inner/held.log'; exec sleep 60"
  holder=${STRAYS[${#STRAYS[@]}-1]}
  age 3 "$s"
  # The listing runs, names the probe, and silently leaves out the process
  # that holds a file open in the area, as a listing that could not read one
  # process or one directory would.
  real_lsof=$(command -v lsof || true)
  real_readlink=$(command -v readlink)
  cat > "$FB/lsof" <<SH
#!/usr/bin/env bash
"$real_lsof" "\$@" > "$TMP_ROOT/partial-listing/lsof.out"
rc=\$?
awk -v drop="$holder" '/^p/ { skip = (substr(\$0, 2) == drop) } !skip' "$TMP_ROOT/partial-listing/lsof.out" |
  grep -v "inner/held.log\$"
exit \$rc
SH
  cat > "$FB/readlink" <<SH
#!/usr/bin/env bash
keep=()
for a in "\$@"; do
  case "\$a" in */proc/$holder/fd/*) echo "readlink: \$a: Permission denied" >&2 ;; *) keep+=("\$a") ;; esac
done
[ "\${#keep[@]}" -eq 0 ] || exec "$real_readlink" "\${keep[@]}"
SH
  chmod +x "$FB/lsof" "$FB/readlink"
  out=$(fp sweep)
  rm -f "$FB/lsof" "$FB/readlink"
  assert_present "$s/inner/held.log" "an area must be kept when the listing left out a process"
  assert_contains "$out" "because the running processes could not be listed" "the pass must say the listing was incomplete"
  if [ "$(uname -s)" = Linux ]; then
    # A process caught part-way through an exec refuses its fd directory only
    # for a moment: it is read again, and the holder it then shows keeps the
    # area for its own reason rather than an incomplete listing.
    cat > "$FB/readlink" <<SH
#!/usr/bin/env bash
keep=()
for a in "\$@"; do
  case "\$a" in
    */proc/$holder/fd/*)
      if [ ! -e "$TMP_ROOT/partial-listing/refused" ]; then
        echo "readlink: \$a: Permission denied" >&2
        continue
      fi ;;
  esac
  keep+=("\$a")
done
: > "$TMP_ROOT/partial-listing/refused"
[ "\${#keep[@]}" -eq 0 ] || exec "$real_readlink" "\${keep[@]}"
SH
    chmod +x "$FB/readlink"
    out=$(fp sweep)
    rm -f "$FB/readlink"
    assert_present "$s/inner/held.log" "an area must be kept for a holder found on the second read"
    assert_contains "$out" "a running process still works in or holds open" "a refusal that clears must lead to the holder"
  fi
  # Control: the full listing finds the holder and keeps the area for it.
  out=$(fp sweep)
  assert_present "$s/inner/held.log" "the full listing must find the open file"
  assert_contains "$out" "a running process still works in or holds open" "the full listing must name the use"
  stop_strays
  out=$(fp sweep)
  assert_absent "$s" "with the holder gone, the area is removed"
  pass "an open-file listing that leaves out any live process keeps every area"
}

# --- the removal is bound to what was verified -----------------------------
#
# Each case runs for close, the daily pass and old-folder apply;
# FOOTPRINT_TEST_MODES selects a subset (to show one path failing alone).

# target <mode> <id>: makes a removal target for close, sweep or apply and
# prints its path: a closing task's area, an orphaned area, or an old task
# folder's rebuildable entry. run_target <mode> <id> <path> removes it the
# way that mode does and prints the output.
target() {
  case "$1" in
    close|sweep) scratch_for "$2" ;;
    apply)
      finished_folder "$2"
      mkdir -p "$H/data/$2/node_modules"
      printf '%s\n' "$H/data/$2/node_modules"
      ;;
  esac
}

run_target() {
  local id
  case "$1" in
    close) fp task-close "$2" "$3" ;;
    sweep) age 3 "$3"; fp sweep ;;
    apply)
      age 40 "$H/data/$2"
      fp old-tasks >/dev/null
      id=$(preview_id)
      [ -n "$id" ] || { echo "no preview offered"; return 0; }
      fp old-tasks --apply "$id"
      ;;
  esac
}

# claims_removed <mode> <output>: 0 when the output reports the target removed.
claims_removed() {
  case "$1" in
    close) case "$2" in *"scratch removed"*) return 0 ;; esac ;;
    sweep) case "$2" in *"Removed 1 orphaned"*) return 0 ;; esac ;;
    apply) case "$2" in *"removed rebuildable"*) return 0 ;; esac ;;
  esac
  return 1
}

# during_removal <action> [<rel-dir>]: runs "<action> <set-aside copy>"
# once, at the moment the removal starts on the entries of <rel-dir> (the
# copy's top directory by default): through the engine's test hook once it
# has made that directory writable, or through rm when a removal deletes by
# path. The action only changes the copy; the removal then goes on with its
# own arguments.
during_removal() {
  local real_rm
  real_rm=$(command -v rm)
  cat > "$FB/remove-hook" <<SH
#!/usr/bin/env bash
[ "\$2" = "${2:-.}" ] && [ ! -e "$TMP_ROOT/during.done" ] || exit 0
: > "$TMP_ROOT/during.done"
"$1" "\$1"
exit 0
SH
  cat > "$FB/rm" <<SH
#!/usr/bin/env bash
if [ ! -e "$TMP_ROOT/during.done" ]; then
  for a in "\$@"; do
    case "\$a" in
      */.fm-closing-*/*|*/.fm-reclaim-*/*)
        pre=\${a%%/.fm-*}
        rest=\${a#"\$pre"/}
        : > "$TMP_ROOT/during.done"
        "$1" "\$pre/\${rest%%/*}"
        break
        ;;
    esac
  done
fi
exec "$real_rm" "\$@"
SH
  chmod +x "$FB/remove-hook" "$FB/rm"
  command rm -f "$TMP_ROOT/during.done"
  export FM_FOOTPRINT_TEST_REMOVE_HOOK="$FB/remove-hook" FM_FOOTPRINT_TEST_SEAMS=1
}

test_a_directory_swapped_for_a_link_during_removal_removes_nothing_outside() {
  local mode t out victim sub
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "swap-$mode"
    victim="$TMP_ROOT/swap-$mode/outside/victim"
    mkdir -p "$victim"
    printf 'precious\n' > "$victim/index.js"
    printf 'precious\n' > "$victim/README.md"
    t=$(target "$mode" task-s1)
    # The review's shape: node_modules/pkg (the apply entry is node_modules
    # itself).
    if [ "$mode" = apply ]; then sub=.; else sub=node_modules; fi
    mkdir -p "$t/$sub/pkg"
    printf 'x\n' > "$t/$sub/pkg/index.js"
    printf 'x\n' > "$t/$sub/pkg/README.md"
    # A process the checks cannot see runs a package link at the worst
    # moment: the package directory is renamed and a link to a checkout put
    # in its place.
    cat > "$FB/swap" <<SH
#!/usr/bin/env bash
"$(command -v mv)" "\$1/$sub/pkg" "\$1/$sub/pkg.old" && "$(command -v ln)" -s "$victim" "\$1/$sub/pkg" && : > "$TMP_ROOT/swap-$mode/swapped"
SH
    chmod +x "$FB/swap"
    during_removal "$FB/swap" "$sub"
    out=$(run_target "$mode" task-s1 "$t")
    unhook
    assert_present "$TMP_ROOT/swap-$mode/swapped" "the swap must have happened during the $mode removal"
    assert_present "$victim/index.js" "$mode must never remove a file outside the copy through a swapped link"
    assert_present "$victim/README.md" "$mode must never remove a file outside the copy through a swapped link"
    ! claims_removed "$mode" "$out" || fail "$mode must not report a copy it could not remove whole as removed: $out"
  done
  pass "a directory swapped for a link during removal removes nothing outside the copy, in close, the daily pass and apply"
}

test_a_file_saved_over_during_removal_is_kept() {
  local mode t out
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "save-$mode"
    t=$(target "$mode" task-v1)
    printf 'draft\n' > "$t/out.txt"
    # An atomic save lands once the copy is writable again: a new file is
    # renamed over the checked one.
    cat > "$FB/save" <<'SH'
#!/usr/bin/env bash
printf 'final result, written after the check\n' > "$1/.out.tmp" && mv -f "$1/.out.tmp" "$1/out.txt"
SH
    chmod +x "$FB/save"
    during_removal "$FB/save"
    out=$(run_target "$mode" task-v1 "$t")
    unhook
    grep -rqs 'final result, written after the check' "${t%/*}" ||
      fail "$mode must keep a file saved over the checked one during removal: $out"
    ! claims_removed "$mode" "$out" || fail "$mode must not report the copy removed: $out"
  done
  pass "a file saved over a checked one during removal is kept, in close, the daily pass and apply"
}

file_mode() { if [ "$(uname -s)" = Darwin ]; then /usr/bin/stat -f %Lp "$1"; else stat -c %a "$1"; fi; }

link_count() { if [ "$(uname -s)" = Darwin ]; then /usr/bin/stat -f %l "$1"; else stat -c %h "$1"; fi; }

# store_files <store>: a pnpm-style and a uv-style package store outside
# every copy, each file mode 644.
store_files() {
  mkdir -p "$1/pnpm/files/ab" "$1/uv/archive-v0/x1/pkg"
  printf 'module.exports=1\n' > "$1/pnpm/files/ab/c0"
  printf '{"name":"pkg"}\n' > "$1/pnpm/files/ab/c1"
  printf 'x = 1\n' > "$1/uv/archive-v0/x1/pkg/__init__.py"
  chmod 644 "$1/pnpm/files/ab/c0" "$1/pnpm/files/ab/c1" "$1/uv/archive-v0/x1/pkg/__init__.py"
}

test_hard_linked_names_go_and_their_store_keeps_its_data() {
  local mode t out store f
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "link-$mode"
    store="$TMP_ROOT/link-$mode/store"
    store_files "$store"
    t=$(target "$mode" task-h1)
    # pnpm: node_modules/.pnpm/<pkg>/node_modules/<pkg>/* hard-linked from the store.
    mkdir -p "$t/node_modules/.pnpm/pkg@1.0.0/node_modules/pkg" "$t/.venv/lib/python3.12/site-packages/pkg"
    ln "$store/pnpm/files/ab/c0" "$t/node_modules/.pnpm/pkg@1.0.0/node_modules/pkg/index.js"
    ln "$store/pnpm/files/ab/c1" "$t/node_modules/.pnpm/pkg@1.0.0/node_modules/pkg/package.json"
    # uv: site-packages files hard-linked from its cache.
    ln "$store/uv/archive-v0/x1/pkg/__init__.py" "$t/.venv/lib/python3.12/site-packages/pkg/__init__.py"
    # A file whose two names are both inside the copy.
    printf 'own\n' > "$t/own.txt"
    ln "$t/own.txt" "$t/own-again.txt"
    out=$(run_target "$mode" task-h1 "$t")
    claims_removed "$mode" "$out" || fail "$mode must remove a copy whose hard-linked names still match: $out"
    assert_absent "$t" "$mode must remove the whole copy"
    for f in "$store/pnpm/files/ab/c0" "$store/pnpm/files/ab/c1" "$store/uv/archive-v0/x1/pkg/__init__.py"; do
      assert_present "$f" "$mode must leave the store's own name"
      assert_equals 644 "$(file_mode "$f")" "$mode must never change a store file's mode"
      assert_equals 1 "$(link_count "$f")" "$mode must leave the store file as its only name"
      printf 'edit\n' >> "$f" || fail "$mode must leave the store file writable"
    done
    assert_equals 'module.exports=1' "$(head -n 1 "$store/pnpm/files/ab/c0")" "$mode must never touch the shared data"
  done
  # A link to a file outside is never followed: the outside file keeps its
  # mode and the copy is removed.
  new_home link-static
  store="$TMP_ROOT/link-static/outside"
  mkdir -p "$store"
  printf 'user source\n' > "$store/other.txt"
  chmod 644 "$store/other.txt"
  t=$(scratch_for task-h2)
  ln -s "$store/other.txt" "$t/link"
  out=$(fp task-close task-h2 "$t")
  assert_absent "$t" "a copy holding only a link to an outside file is removed"
  assert_equals 644 "$(file_mode "$store/other.txt")" "the link's target must keep its mode"
  pass "hard-linked names from pnpm and uv stores are removed and the stores keep their data and modes, in close, the daily pass and apply"
}

test_a_hard_linked_name_that_changes_before_its_unlink_is_kept() {
  local mode t out store how r
  for how in count swap; do
    for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
      new_home "linkchg-$how-$mode"
      store="$TMP_ROOT/linkchg-$how-$mode/store"
      store_files "$store"
      t=$(target "$mode" task-h3)
      mkdir -p "$t/pkg"
      ln "$store/pnpm/files/ab/c0" "$t/pkg/index.js"
      if [ "$how" = count ]; then
        # The store's own name goes once the copy is writable again: the
        # name in the copy is now the data's only name.
        printf '#!/usr/bin/env bash\nrm -f "%s"\n' "$store/pnpm/files/ab/c0" > "$FB/change"
      else
        # The name is swapped for another file.
        printf '#!/usr/bin/env bash\nprintf "a different file\\n" > "$1/pkg/.n" && mv -f "$1/pkg/.n" "$1/pkg/index.js"\n' > "$FB/change"
      fi
      chmod +x "$FB/change"
      during_removal "$FB/change" pkg
      out=$(run_target "$mode" task-h3 "$t")
      unhook
      ! claims_removed "$mode" "$out" || fail "$how/$mode: a hard-linked name that changed must not be reported removed: $out"
      if [ "$how" = count ]; then
        grep -rqs 'module.exports=1' "${t%/*}" || fail "$how/$mode: data whose other name went must be kept: $out"
      else
        grep -rqs 'a different file' "${t%/*}" || fail "$how/$mode: the file swapped in must be kept: $out"
        assert_equals 'module.exports=1' "$(cat "$store/pnpm/files/ab/c0")" "$how/$mode: the store's data must be untouched"
      fi
    done
  done
  # A link that changes after the last snapshot but before removal starts
  # keeps the whole copy: the engine checks every hard-linked name first.
  new_home linkchg-before
  store="$TMP_ROOT/linkchg-before/store"
  store_files "$store"
  r="$TMP_ROOT/linkchg-before/copy"
  mkdir -p "$r/a"
  printf 'own\n' > "$r/a/own.txt"
  ln "$store/pnpm/files/ab/c0" "$r/linked.js"
  python3 -I -B "$ROOT/bin/fm-footprint-fs.py" snapshot "$r" > "$TMP_ROOT/linkchg-before/snap"
  : > "$TMP_ROOT/linkchg-before/modes"
  rm -f "$store/pnpm/files/ab/c0"
  out=$(python3 -I -B "$ROOT/bin/fm-footprint-fs.py" remove "$TMP_ROOT/linkchg-before/snap" "$TMP_ROOT/linkchg-before/modes" "$r")
  assert_contains "$out" "partial	0" "a link changed before removal must keep the whole copy"
  assert_present "$r/a/own.txt" "the copy's other files must stay"
  assert_present "$r/linked.js" "the changed name must stay"
  pass "a hard-linked name whose link count drops or that is swapped is kept, and one changed before removal keeps the whole copy"
}

# outside_link_shim <outside> <keydir>: a sync on PATH that, during the
# flush step after the freeze, links data.txt of the set-aside copy in
# <keydir> from <outside>/linked.txt, as another process could.
outside_link_shim() {  # <outside> <keydir>
  local real_sync
  real_sync=$(command -v sync)
  cat > "$FB/sync" <<SH
#!/usr/bin/env bash
for a in "$2"/.fm-*; do
  [ -f "\$a/lib/data.txt" ] && [ ! -e "$1/linked.txt" ] && ln "\$a/lib/data.txt" "$1/linked.txt"
done
exec "$real_sync" "\$@"
SH
  chmod +x "$FB/sync"
}

test_a_name_made_outside_during_the_close_keeps_its_permissions() {
  local mode t out outside n
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "linkout-$mode"
    outside="$TMP_ROOT/linkout-$mode/outside"
    mkdir -p "$outside"
    t=$(target "$mode" task-h5)
    mkdir -p "$t/lib"
    printf 'precious\n' > "$t/lib/data.txt"
    printf 'x\n' > "$t/lib/other.txt"
    chmod 644 "$t/lib/data.txt"
    outside_link_shim "$outside" "${t%/*}"
    out=$(run_target "$mode" task-h5 "$t")
    rm -f "$FB/sync"
    assert_present "$outside/linked.txt" "$mode: the probe must have linked the file from outside: $out"
    assert_equals precious "$(cat "$outside/linked.txt")" "$mode: the outside name must keep its data"
    assert_equals 644 "$(file_mode "$outside/linked.txt")" "$mode: a name made outside after the freeze must keep its permissions: $out"
    [ -z "$(ls "$H/state/footprint-stopped" 2>/dev/null)" ] || fail "$mode: a finished run must drop its record"
  done
  # The same name made between the freeze's two walks, of a file whose
  # every name was inside when it was counted.
  new_home linkout-walks
  outside="$TMP_ROOT/linkout-walks/outside"
  mkdir -p "$outside"
  t=$(scratch_for task-h6)
  mkdir -p "$t/z"
  printf 'pair\n' > "$t/a1"
  chmod 644 "$t/a1"
  ln "$t/a1" "$t/a2"
  n=0
  while [ "$n" -lt 40 ]; do printf '%s\n' "$n" > "$t/z/f$n"; n=$((n + 1)); done
  export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER=10 FM_FOOTPRINT_TEST_PAUSED_FILE="$FB/engine.pid"
  fp task-close task-h6 "$t" > "$TMP_ROOT/linkout-walks/out" 2>&1 &
  n=0
  until [ -s "$FB/engine.pid" ] || [ "$n" -ge 400 ]; do sleep .05; n=$((n + 1)); done
  unset FM_FOOTPRINT_TEST_SEAMS FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER FM_FOOTPRINT_TEST_PAUSED_FILE
  [ "$n" -lt 400 ] || fail "the freeze never paused"
  ln "$(find "${t%/*}" -maxdepth 1 -name '.fm-closing-*' | head -n 1)/a1" "$outside/linked"
  kill -CONT "$(cat "$FB/engine.pid")"
  wait
  assert_equals pair "$(cat "$outside/linked")" "the outside name must keep its data: $(cat "$TMP_ROOT/linkout-walks/out")"
  assert_equals 644 "$(file_mode "$outside/linked")" "a name made outside between the freeze's walks must keep its permissions: $(cat "$TMP_ROOT/linkout-walks/out")"
  pass "a file that gains a name outside the copy during the close keeps its permissions there, in close, the daily pass and apply"
}

test_orphans_sharing_a_store_file_all_go_in_one_pass() {
  local store t id out
  new_home linkmany
  store="$TMP_ROOT/linkmany/store"
  store_files "$store"
  for id in task-s1 task-s2 task-s3; do
    t=$(scratch_for "$id")
    mkdir -p "$t/node_modules/pkg"
    ln "$store/pnpm/files/ab/c0" "$t/node_modules/pkg/index.js"
    printf 'own\n' > "$t/node_modules/pkg/own.js"
    age 3 "$t"
  done
  out=$(fp sweep)
  assert_contains "$out" "Removed 3 orphaned" "three orphans sharing one store file must all go in one pass: $out"
  [ -z "$(ls -d "${t%/*}"/.fm-reclaim-* "${t%/*}"/task-s* 2>/dev/null)" ] || fail "no orphan may be left: $(ls -A "${t%/*}")"
  assert_equals 'module.exports=1' "$(cat "$store/pnpm/files/ab/c0")" "the store's data must be untouched"
  assert_equals 644 "$(file_mode "$store/pnpm/files/ab/c0")" "the store file must keep its permissions"
  assert_equals 1 "$(link_count "$store/pnpm/files/ab/c0")" "only the store's own name must be left"
  pass "orphaned areas sharing a store file all go in one daily pass, and the store keeps its data"
}

test_a_thaw_restores_only_the_write_bits_it_took() {
  local r id
  new_home thawbits
  r="$TMP_ROOT/thawbits/copy"
  mkdir -p "$r"
  printf 'x\n' > "$r/f"
  chmod 644 "$r/f"
  id=$(python3 -I -B -c 'import os, sys; s = os.lstat(sys.argv[1]); print(s.st_dev, s.st_ino)' "$r/f")
  printf '%s 644\n' "$id" > "$TMP_ROOT/thawbits/modes"
  # An object whose other bits differ is not the one recorded (a reused
  # inode): it is left alone.
  chmod 400 "$r/f"
  python3 -I -B "$ROOT/bin/fm-footprint-fs.py" thaw "$TMP_ROOT/thawbits/modes" "$r" || true
  assert_equals 400 "$(file_mode "$r/f")" "a thaw must not give a different object the recorded mode"
  chmod 444 "$r/f"
  python3 -I -B "$ROOT/bin/fm-footprint-fs.py" thaw "$TMP_ROOT/thawbits/modes" "$r" || fail "the thaw must succeed"
  assert_equals 644 "$(file_mode "$r/f")" "a thaw must give the frozen object its write bits back"
  pass "a thaw gives back only the write bits the freeze took, never another object's mode"
}

test_a_check_that_cannot_record_keeps_the_copy() {
  local mode t out d
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "full-$mode"
    t=$(target "$mode" task-f1)
    printf 'work\n' > "$t/out.txt"
    [ "$mode" != apply ] || { age 40 "$H/data/task-f1"; fp old-tasks >/dev/null; }
    # No write can land anywhere, as on a full disk: every record the check
    # makes fails.
    case "$mode" in
      close) out=$(trap '' XFSZ; ulimit -f 0; fp task-close task-f1 "$t") ;;
      sweep) age 3 "$t"; out=$(trap '' XFSZ; ulimit -f 0; fp sweep) ;;
      apply) out=$(trap '' XFSZ; ulimit -f 0; fp old-tasks --apply "$(preview_id)") ;;
    esac
    assert_present "$t/out.txt" "$mode must put the copy back under its name when its check cannot be recorded: $out"
    ! claims_removed "$mode" "$out" || fail "$mode must not report removal when its check could not be recorded: $out"
    # Positive control: with writes working again, the copy goes.
    out=$(run_target "$mode" task-f1 "$t")
    assert_absent "$t" "$mode must remove the copy once its check can be recorded: $out"
  done
  # An empty or missing snapshot is never success.
  d="$TMP_ROOT/full-close/lonely"
  mkdir -p "$d/inner"
  out=$(python3 "$ROOT/bin/fm-footprint-fs.py" remove /dev/null /dev/null "$d" 2>&1)
  assert_contains "$out" "$d	partial" "a copy with no snapshot must be reported partial"
  assert_present "$d/inner" "a copy with no snapshot must be left whole"
  pass "a check that cannot record its result, or an empty snapshot, keeps the copy, in close, the daily pass and apply"
}

test_close_removes_docker_before_scratch_and_the_pass_measures_nothing_after_its_check() {
  local s dir out o real_du
  new_home order
  dir="$TMP_ROOT/order/docker"
  s=$(scratch_for task-o1)
  printf 'cache\n' > "$s/cache"
  docker_standin "$dir"
  printf 'c1\t%s\n' "$(env_of task-o1 FM_DOCKER_LABEL)" > "$dir/objects"
  mv "$FB/docker" "$FB/docker.standin"
  cat > "$FB/docker" <<SH
#!/usr/bin/env bash
case "\$1" in rm) if [ -d "$s" ]; then echo present; else echo gone; fi >> "$dir/area-at-rm" ;; esac
exec "$FB/docker.standin" "\$@"
SH
  chmod +x "$FB/docker"
  out=$(fp task-close task-o1 "$s")
  assert_contains "$out" "scratch removed" "close must remove the area"
  assert_equals present "$(head -n 1 "$dir/area-at-rm" 2>/dev/null)" "the task's containers must be removed while its area is still there"
  command rm -f "$FB/docker" "$FB/docker.standin"
  export FM_FOOTPRINT_DOCKER=
  # The daily pass reads each removed area's size from its verified
  # snapshot; nothing measures a copy between its check and its removal.
  o=$(scratch_for task-o2)
  printf 'cache\n' > "$o/cache"
  age 3 "$o"
  real_du=$(command -v du)
  cat > "$FB/du" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/order/du.log"
exec "$real_du" "\$@"
SH
  chmod +x "$FB/du"
  out=$(fp sweep)
  command rm -f "$FB/du"
  printf '%s\n' "$out" | grep -Eq 'Removed 1 orphaned scratch area\(s\), [1-9][0-9]* KB' || fail "the pass must report the size it removed: $out"
  ! grep -q '\.fm-reclaim-' "$TMP_ROOT/order/du.log" 2>/dev/null || fail "the pass must not measure a set-aside copy after its check"
  pass "close removes Docker objects before the area, and the pass measures nothing between its check and its removal"
}

# start_in <dir> <socket> <program> [args]: starts <program> with its working
# directory <dir>, waits until <socket> exists (or 5 s), and sets SI_PID.
start_in() {  # <dir> <socket> <program> [args...]
  local dir=$1 sock=$2 n=0 pid
  shift 2
  ( cd "$dir" && exec "$@" ) >/dev/null 2>&1 </dev/null &
  pid=$!
  while [ -n "$sock" ] && [ ! -S "$sock" ] && [ "$n" -lt 100 ]; do sleep .05; n=$((n + 1)); done
  [ -n "$sock" ] || sleep .3
  kill -0 "$pid" 2>/dev/null || fail "$1 must be running in $dir"
  SI_PID=$pid
}

test_a_key_helper_started_in_an_area_does_not_keep_it() {
  local s out agent other pids='' outside p
  agent=$(command -v ssh-agent) || { printf 'ok - # SKIP no ssh-agent\n'; return 0; }
  new_home helper
  # Socket paths must stay short (104 bytes on macOS).
  outside="$SHORT/helper-out"
  mkdir -p "$outside"
  # Its only tie is the working directory it started in: the area goes.
  s=$(scratch_for task-k1)
  printf 'cache\n' > "$s/cache"
  start_in "$s" "$outside/sock1" "$agent" -D -a "$outside/sock1"; p=$SI_PID
  pids="$pids $p"
  out=$(fp task-close task-k1 "$s")
  assert_contains "$out" "scratch removed" "an ssh-agent whose only tie is its working directory must not keep the area: $out"
  assert_absent "$s" "the area must be gone"
  # Its socket is inside the area: the area stays.
  s=$(scratch_for task-k2)
  printf 'cache\n' > "$s/cache"
  start_in "$outside" "$s/agent.sock" "$agent" -D -a "$s/agent.sock"; p=$SI_PID
  pids="$pids $p"
  out=$(fp task-close task-k2 "$s")
  assert_present "$s/cache" "an ssh-agent with its socket inside must keep the area: $out"
  ! claims_removed close "$out" || fail "a helper's open socket must keep the area: $out"
  # A different program with its working directory there: the area stays.
  s=$(scratch_for task-k3)
  printf 'cache\n' > "$s/cache"
  start_in "$s" '' perl -e 'sleep 300' "$outside/other"; p=$SI_PID
  pids="$pids $p"
  out=$(fp task-close task-k3 "$s")
  assert_present "$s/cache" "another program working there must keep the area: $out"
  kill "$p" 2>/dev/null || true
  if [ "$(uname -s)" = Linux ]; then
    # On Linux, the agent's own binary under another name cannot be
    # inspected either, and is no key helper: the area stays and it is named.
    other="$FB/other-agent"
    cp "$agent" "$other"
    start_in "$s" "$outside/sock3" "$other" -D -a "$outside/sock3"; p=$SI_PID
    pids="$pids $p"
    out=$(fp task-close task-k3 "$s")
    assert_present "$s/cache" "a program that cannot be inspected must keep the area: $out"
    assert_contains "$out" "other-agent (pid $p) cannot be inspected" "on Linux a program that cannot be inspected is named"
    age 3 "$s"
    out=$(fp sweep)
    assert_contains "$out" "Linux cleanup removes nothing while such a process runs" "the daily finding must say so plainly"
  fi
  # shellcheck disable=SC2086 # one pid per word
  kill $pids 2>/dev/null || true
  wait 2>/dev/null || true
  out=$(fp task-close task-k3 "$s")
  assert_absent "$s" "with those programs gone, the area is removed"
  pass "a key helper whose only tie is its working directory no longer keeps an area; its open socket or another program there still does"
}

# all_writable <dir>: 0 when every directory and file under <dir> has its
# owner write bit, as before any freeze.
all_writable() { [ -z "$(find "$1" \( -type d -o -type f \) ! -perm -u+w -print 2>/dev/null | head -n 1)" ]; }

test_an_interrupted_freeze_leaves_a_writable_copy() {
  local mode t out i
  for mode in ${FOOTPRINT_TEST_MODES:-close sweep apply}; do
    new_home "halt-$mode"
    t=$(target "$mode" task-z1)
    mkdir -p "$t/d"
    i=1
    while [ "$i" -le 20 ]; do printf 'w\n' > "$t/d/f$i"; i=$((i + 1)); done
    # The freeze is killed (SIGKILL) part way, after five mode changes.
    export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_FREEZE_KILL_AFTER=5
    out=$(run_target "$mode" task-z1 "$t")
    unset FM_FOOTPRINT_TEST_SEAMS FM_FOOTPRINT_TEST_FREEZE_KILL_AFTER
    assert_present "$t/d/f20" "$mode must keep the copy under its name after a stopped freeze: $out"
    all_writable "$t" || fail "$mode must give a copy whose freeze stopped its permissions back: $(find "$t" ! -perm -u+w | head -n 3)"
    ! claims_removed "$mode" "$out" || fail "$mode must not report removal after a stopped freeze: $out"
    [ "$mode" != close ] || assert_contains "$out" "its check did not finish" "close must say the check did not finish"
    out=$(run_target "$mode" task-z1 "$t")
    assert_absent "$t" "$mode must remove the copy once a check finishes: $out"
  done
  # A tree deeper than any recursion limit is frozen, checked and removed.
  new_home halt-deep
  t=$(scratch_for task-z2)
  python3 - "$t" 1100 <<'PY2'
import os, sys
d = os.open(sys.argv[1], os.O_RDONLY)
for _ in range(int(sys.argv[2])):
    os.mkdir("d", dir_fd=d)
    n = os.open("d", os.O_RDONLY, dir_fd=d)
    os.close(d)
    d = n
fd = os.open("leaf", os.O_WRONLY | os.O_CREAT, 0o644, dir_fd=d)
os.write(fd, b"x\n")
os.close(fd)
PY2
  out=$(fp task-close task-z2 "$t")
  assert_contains "$out" "scratch removed" "a 1100-level tree must be removed"
  assert_absent "$t" "a 1100-level tree must be gone"
  # A tree deeper than the open-file limit allows is kept, and left writable.
  t=$(scratch_for task-z3)
  python3 - "$t" 120 <<'PY2'
import os, sys
d = os.open(sys.argv[1], os.O_RDONLY)
for _ in range(int(sys.argv[2])):
    os.mkdir("d", dir_fd=d)
    n = os.open("d", os.O_RDONLY, dir_fd=d)
    os.close(d)
    d = n
PY2
  out=$(ulimit -n 64 && fp task-close task-z3 "$t")
  assert_contains "$out" "kept whole" "a tree deeper than the open-file limit must be kept: $out"
  all_writable "$t" || fail "a tree too deep to freeze must be left writable"
  pass "a freeze stopped part way leaves a writable copy under its name, and a deep tree meets no recursion limit"
}

# engine_gone <pid>: 0 once <pid> no longer runs (gone, or a reaped zombie).
engine_gone() {
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  case "$st" in ''|Z*) return 0 ;; esac
  return 1
}

# stopped_mid <step> <name>: runs a close whose engine is paused (SIGSTOP)
# part way through <step> (freeze or remove), then stops the close with TERM
# as a timed-out caller does; sets SM_PID to the paused engine's pid. Under
# GNU timeout the engine is in its own process group, out of the signal's
# reach, so only the close itself can stop it.
stopped_mid() {  # <step> <name>
  local step=$1 name=$2 s n i pids
  new_home "$name"
  s=$(scratch_for task-m1)
  mkdir -p "$s/a" "$s/d"
  i=1
  while [ "$i" -le 40 ]; do printf 'w\n' > "$s/a/f$i"; printf 'w\n' > "$s/d/f$i"; i=$((i + 1)); done
  SM_AREA=$s
  if [ "$step" = freeze ]; then
    # The engine stops itself (SIGSTOP) after five mode changes.
    export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER=5 FM_FOOTPRINT_TEST_PAUSED_FILE="$FB/engine.pid"
  else
    # Pauses the remove engine once it reaches the second directory.
    cat > "$FB/remove-hook" <<HOOK
#!/bin/bash
[ "\$2" = d ] || exit 0
printf '%s\n' "\$PPID" > "$FB/engine.pid"
kill -STOP "\$PPID"
HOOK
    chmod +x "$FB/remove-hook"
    export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_REMOVE_HOOK="$FB/remove-hook"
  fi
  fp task-close task-m1 "$s" > "$TMP_ROOT/$name/out" 2>&1 &
  n=0
  until [ -s "$FB/engine.pid" ] || [ "$n" -ge 400 ]; do sleep .05; n=$((n + 1)); done
  [ "$n" -lt 400 ] || fail "$step: the engine never paused"
  SM_PID=$(cat "$FB/engine.pid")
  sleep .2
  pids=$(pgrep -f "fm-footprint.sh task-close task-m1 $s" || true)
  [ -n "$pids" ] || fail "$step: the close must still be running"
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids
  wait
  unset FM_FOOTPRINT_TEST_SEAMS FM_FOOTPRINT_TEST_REMOVE_HOOK FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER FM_FOOTPRINT_TEST_PAUSED_FILE
}

test_a_close_stopped_mid_step_stops_its_engine_first() {
  local step alive n
  for step in remove freeze; do
    stopped_mid "$step" "mid-$step"
    alive=0
    engine_gone "$SM_PID" || alive=1
    # Let a still-running engine go on, as it would have, before looking.
    kill -CONT "$SM_PID" 2>/dev/null || true
    n=0
    until engine_gone "$SM_PID" || [ "$n" -ge 100 ]; do sleep .05; n=$((n + 1)); done
    kill -KILL "$SM_PID" 2>/dev/null || true
    [ "$alive" = 0 ] || fail "$step: a stopped close must stop its engine before it undoes the run"
    assert_present "$SM_AREA" "$step: the stopped close must put the copy back under its name"
    all_writable "$SM_AREA" || fail "$step: the copy put back must be writable: $(find "$SM_AREA" ! -perm -u+w | head -n 3)"
    [ -z "$(ls "$H/state/footprint-stopped" 2>/dev/null)" ] || fail "$step: a finished stop must drop its record"
  done
  pass "a close stopped mid-freeze or mid-removal stops its engine, then puts the copy back writable"
}

test_a_close_stopped_as_its_engine_starts_changes_nothing() {
  local s i n pids real_py out
  new_home startstop
  s=$(scratch_for task-m2)
  mkdir -p "$s/d"
  i=1
  while [ "$i" -le 40 ]; do printf 'w\n' > "$s/d/f$i"; i=$((i + 1)); done
  # The freeze engine starts slowly and, once it has changed five modes,
  # pauses itself; the thaw that undoes the stop starts slower still.
  real_py=$(command -v python3)
  cat > "$FB/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" freeze "*) : > "$FB/freeze-starting"; sleep .3 ;;
  *" thaw "*) sleep 1 ;;
esac
exec "$real_py" "\$@"
SH
  chmod +x "$FB/python3"
  export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER=5 FM_FOOTPRINT_TEST_PAUSED_FILE="$FB/engine.pid"
  fp task-close task-m2 "$s" > "$TMP_ROOT/startstop/out" 2>&1 &
  n=0
  until [ -e "$FB/freeze-starting" ] || [ "$n" -ge 400 ]; do sleep .05; n=$((n + 1)); done
  [ "$n" -lt 400 ] || fail "the freeze never started"
  pids=$(pgrep -f "fm-footprint.sh task-close task-m2 $s" || true)
  [ -n "$pids" ] || fail "the close must still be running"
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids
  wait
  unset FM_FOOTPRINT_TEST_SEAMS FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER FM_FOOTPRINT_TEST_PAUSED_FILE
  rm -f "$FB/python3"
  # An engine that went on would have paused; let it finish, as it would.
  if [ -s "$FB/engine.pid" ]; then
    kill -CONT "$(cat "$FB/engine.pid")" 2>/dev/null || true
    n=0
    until engine_gone "$(cat "$FB/engine.pid")" || [ "$n" -ge 200 ]; do sleep .05; n=$((n + 1)); done
  fi
  out=$(cat "$TMP_ROOT/startstop/out")
  assert_present "$s/d/f40" "the stopped close must put the copy back under its name: $out"
  all_writable "$s" || fail "an engine starting as the close stops must not freeze the copy put back: $(find "$s" ! -perm -u+w | head -n 3)"
  [ -z "$(ls "$H/state/footprint-stopped" 2>/dev/null)" ] || fail "a finished stop must drop its record"
  pass "a close stopped while its engine is still starting leaves that engine nothing to do"
}

test_a_killed_close_is_repaired_only_after_its_engine_ends() {
  local s i n pids epid out aside
  new_home killmid
  s=$(scratch_for task-m3)
  mkdir -p "$s/a" "$s/d"
  i=1
  while [ "$i" -le 40 ]; do printf 'w\n' > "$s/a/f$i"; printf 'w\n' > "$s/d/f$i"; i=$((i + 1)); done
  export FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER=5 FM_FOOTPRINT_TEST_PAUSED_FILE="$FB/engine.pid"
  fp task-close task-m3 "$s" > "$TMP_ROOT/killmid/out" 2>&1 &
  n=0
  until [ -s "$FB/engine.pid" ] || [ "$n" -ge 400 ]; do sleep .05; n=$((n + 1)); done
  unset FM_FOOTPRINT_TEST_SEAMS FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER FM_FOOTPRINT_TEST_PAUSED_FILE
  [ "$n" -lt 400 ] || fail "the freeze never paused"
  epid=$(cat "$FB/engine.pid")
  pids=$(pgrep -f "fm-footprint.sh task-close task-m3 $s" || true)
  [ -n "$pids" ] || fail "the close must still be running"
  # The close is killed outright; its engine, under its timer, lives on.
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $pids
  wait
  engine_gone "$epid" && fail "the engine must outlive a close killed outright"
  out=$(fp sweep)
  [ -n "$(ls "$H/state/footprint-stopped" 2>/dev/null)" ] || fail "a pass must not undo a run whose engine still runs: $out"
  kill -CONT "$epid" 2>/dev/null || true
  n=0
  until engine_gone "$epid" || [ "$n" -ge 200 ]; do sleep .05; n=$((n + 1)); done
  out=$(fp sweep)
  aside=$(find "${s%/*}" -maxdepth 1 -name '.fm-closing-*' 2>/dev/null | head -n 1)
  [ -n "$aside" ] || aside=$s
  all_writable "$aside" || fail "the next pass must give the copy its permissions back: $(find "$aside" ! -perm -u+w | head -n 3)"
  [ -z "$(ls "$H/state/footprint-stopped" 2>/dev/null)" ] || fail "the next pass must drop the record once it is repaired: $out"
  pass "a close killed outright is repaired by the next pass, only once its engine has ended"
}

test_an_engine_that_dies_during_removal_leaves_a_writable_copy() {
  local s out left rec
  new_home engine-dies
  s=$(scratch_for task-k1)
  mkdir -p "$s/a" "$s/d"
  printf 'w\n' > "$s/a/f1"
  printf 'w\n' > "$s/d/f1"
  cat > "$FB/remove-hook" <<'HOOK'
#!/bin/bash
[ "$2" = d ] || exit 0
kill -KILL "$PPID"
HOOK
  chmod +x "$FB/remove-hook"
  out=$(FM_FOOTPRINT_TEST_SEAMS=1 FM_FOOTPRINT_TEST_REMOVE_HOOK="$FB/remove-hook" fp task-close task-k1 "$s")
  ! claims_removed close "$out" || fail "a removal whose engine died must not report removal: $out"
  left=$(find "${s%/*}" -maxdepth 1 -name '.fm-closing-task-k1.*' | head -n 1)
  [ -n "$left" ] || fail "what is left must stay set aside: $out"
  all_writable "$left" || fail "what is left must be writable: $(find "$left" ! -perm -u+w | head -n 3)"
  # A record whose last line was cut short by a full disk still thaws.
  mkdir -p "$TMP_ROOT/engine-dies/rec/x"
  chmod 500 "$TMP_ROOT/engine-dies/rec/x"
  rec="$TMP_ROOT/engine-dies/rec.modes"
  python3 - "$TMP_ROOT/engine-dies/rec/x" "$rec" <<'PY2'
import os, sys
st = os.stat(sys.argv[1])
with open(sys.argv[2], "w") as f:
    f.write(f"{st.st_dev} {st.st_ino} 755\n{st.st_dev} 12")
PY2
  python3 -I -B "$ROOT/bin/fm-footprint-fs.py" thaw "$rec" "$TMP_ROOT/engine-dies/rec" ||
    fail "a record with a cut-short last line must still thaw"
  [ "$(file_mode "$TMP_ROOT/engine-dies/rec/x")" = 755 ] || fail "the thaw must restore the recorded mode"
  pass "an engine that dies part way through removal leaves a writable copy, and a cut-short record still thaws"
}

test_an_interrupted_close_leaves_its_copy_writable() {
  local s pids n left out
  new_home halt-term
  printf 'scratch-root %s\nremoval-grace-seconds 3\n' "$SHORT/halt-term" > "$H/config/footprint"
  s=$(scratch_for task-t1)
  mkdir -p "$s/d"
  printf 'w\n' > "$s/d/f1"
  # A caller that times out stops task close while the copy is frozen and
  # waiting out its grace window.
  FM_FOOTPRINT_REMOVAL_GRACE_OVERRIDE='' fp task-close task-t1 "$s" > "$TMP_ROOT/halt-term/out" 2>&1 &
  n=0
  until [ -n "$(find "${s%/*}" -maxdepth 3 -path '*/.fm-closing-task-t1.*/d/f1' ! -perm -u+w 2>/dev/null | head -n 1)" ] || [ "$n" -ge 200 ]; do
    sleep .05; n=$((n + 1))
  done
  [ "$n" -lt 200 ] || fail "the copy was never frozen"
  pids=$(pgrep -f "fm-footprint.sh task-close task-t1 $s" || true)
  [ -n "$pids" ] || fail "the close must still be running"
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids
  wait
  assert_present "$s/d/f1" "an interrupted close must put the copy back under its name"
  all_writable "$s" || fail "an interrupted close must give the copy its permissions back"
  [ -z "$(find "${s%/*}" -maxdepth 1 -name '.fm-closing-task-t1.*' | head -n 1)" ] || fail "no frozen set-aside copy may be left behind"
  # Killed outright (SIGKILL), the close cannot clean up; the next daily
  # pass gives the copy it left frozen its permissions back and reports it.
  new_home halt-kill
  printf 'scratch-root %s\nremoval-grace-seconds 5\n' "$SHORT/halt-kill" > "$H/config/footprint"
  s=$(scratch_for task-t2)
  mkdir -p "$s/d"
  printf 'w\n' > "$s/d/f1"
  FM_FOOTPRINT_REMOVAL_GRACE_OVERRIDE='' fp task-close task-t2 "$s" > "$TMP_ROOT/halt-kill/out" 2>&1 &
  n=0
  until [ -n "$(find "${s%/*}" -maxdepth 3 -path '*/.fm-closing-task-t2.*/d/f1' ! -perm -u+w 2>/dev/null | head -n 1)" ] || [ "$n" -ge 200 ]; do
    sleep .05; n=$((n + 1))
  done
  [ "$n" -lt 200 ] || fail "the copy was never frozen"
  pids=$(pgrep -f "fm-footprint.sh task-close task-t2 $s" || true)
  [ -n "$pids" ] || fail "the second close must still be running"
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $pids
  wait
  left=$(find "${s%/*}" -maxdepth 1 -name '.fm-closing-task-t2.*' | head -n 1)
  [ -n "$left" ] || fail "a killed close leaves its copy set aside"
  ! all_writable "$left" || fail "the killed close's copy must still be frozen before the next pass"
  out=$(fp sweep)
  all_writable "$left" || fail "the next pass must give a killed close's copy its permissions back: $(find "$left" ! -perm -u+w | head -n 3)"
  assert_present "$left/d/f1" "the next pass must not remove a set-aside copy"
  assert_contains "$out" "${left##*/}" "the next pass must report the set-aside copy"
  pass "a close stopped while its copy is frozen puts the copy back, writable, under its name; one killed outright is made writable by the next pass"
}

# --- the Docker retry queue under concurrent closes -------------------------

test_a_close_during_the_daily_retry_keeps_its_queue_entry() {
  local a b c d gen dir out real_mv n
  new_home retry-append
  dir="$TMP_ROOT/retry-append/docker"
  a=$(scratch_for task-a)
  b=$(scratch_for task-b)
  c=$(scratch_for task-c)
  gen=$(lib 'fm_footprint_task_generation '"$a")
  docker_standin "$dir"
  # task-a's retry can finish; task-c is live again, so it stays queued and
  # the pass rewrites the queue rather than deleting it.
  printf 'worktree=/live/c\n' > "$H/state/task-c.meta"
  printf 'task-a\t1\t%s\ntask-c\t1\t0123456789abcdef\n' "$gen" > "$H/state/footprint-docker-retry"
  # Window 1, while the pass does its Docker work without the queue lock:
  # task-b closes with Docker not answering and queues its cleanup.
  cat > "$dir/on-info" <<SH
#!/usr/bin/env bash
[ -e "$dir/raced" ] && exit 0
: > "$dir/raced"
: > "$dir/down"
HOME="$U" FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \\
  "$FOOTPRINT" task-close task-b "$b" > "$dir/close-b.log" 2>&1
rm -f "$dir/down"
SH
  chmod +x "$dir/on-info"
  # Window 2, while the pass replaces the queue: task-d closes at the same
  # moment, concurrently, and queues its cleanup too.
  real_mv=$(command -v mv)
  d=$(scratch_for task-d)
  cat > "$FB/mv" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.lock*) ;;
  *footprint-docker-retry*)
    if [ ! -e "$dir/raced2" ]; then
      : > "$dir/raced2"
      : > "$dir/down"
      ( HOME="$U" FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \\
        PATH="$BASE_PATH" "$FOOTPRINT" task-close task-d "$d" > "$dir/close-d.log" 2>&1; : > "$dir/close-d.done" ) &
      sleep 2
    fi
    ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$FB/mv"
  out=$(fp sweep)
  n=0
  until [ -e "$dir/close-d.done" ] || [ "$n" -ge 600 ]; do sleep .1; n=$((n + 1)); done
  rm -f "$FB/mv" "$dir/down"
  assert_contains "$(cat "$dir/close-b.log")" "its cleanup is queued for the daily pass" "task-b's close must queue its cleanup"
  assert_present "$dir/raced2" "the queue replacement must have raced a close"
  assert_contains "$(cat "$dir/close-d.log")" "its cleanup is queued for the daily pass" "task-d's close must queue its cleanup"
  grep -Eq "^task-b	[0-9]+	[0-9a-f]{16}\$" "$H/state/footprint-docker-retry" || fail "a close during the Docker work must keep its queue entry"
  grep -Eq "^task-d	[0-9]+	[0-9a-f]{16}\$" "$H/state/footprint-docker-retry" || fail "a close during the queue replacement must keep its queue entry"
  grep -Eq "^task-c	1	0123456789abcdef\$" "$H/state/footprint-docker-retry" || fail "a pending entry stays"
  if grep -q '^task-a	' "$H/state/footprint-docker-retry"; then fail "the finished retry must leave the queue"; fi
  [ "$(find "$H/state" -name '.footprint-docker-retry.*' ! -name '*.lock' | wc -l | tr -d ' ')" = 0 ] || fail "no staging file may be left"
  # The next pass retires both closed tasks and keeps the live one.
  rm -f "$dir/on-info"
  out=$(fp sweep)
  assert_equals "task-c	1	0123456789abcdef" "$(cat "$H/state/footprint-docker-retry")" "both closed tasks' retries finish; the live one stays"
  pass "a close that queues a Docker retry while the daily pass works or rewrites the queue keeps its entry"
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
  assert_contains "$out" "changed while it was being set aside or waiting to be removed; nothing removed" "apply must refuse"
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
  test_a_close_during_the_daily_retry_keeps_its_queue_entry \
  test_a_process_still_using_an_orphan_keeps_it \
  test_an_unreadable_process_table_removes_nothing \
  test_a_surviving_process_keeps_a_closing_area \
  test_work_finished_before_the_freeze_is_caught \
  test_a_frozen_area_refuses_new_work \
  test_a_child_born_after_the_listing_loses_nothing \
  test_a_write_during_the_grace_window_keeps_the_area \
  test_a_writable_memory_mapping_keeps_the_area \
  test_a_partial_open_file_listing_keeps_everything \
  test_a_directory_swapped_for_a_link_during_removal_removes_nothing_outside \
  test_a_file_saved_over_during_removal_is_kept \
  test_hard_linked_names_go_and_their_store_keeps_its_data \
  test_a_hard_linked_name_that_changes_before_its_unlink_is_kept \
  test_a_name_made_outside_during_the_close_keeps_its_permissions \
  test_orphans_sharing_a_store_file_all_go_in_one_pass \
  test_a_thaw_restores_only_the_write_bits_it_took \
  test_a_check_that_cannot_record_keeps_the_copy \
  test_close_removes_docker_before_scratch_and_the_pass_measures_nothing_after_its_check \
  test_a_key_helper_started_in_an_area_does_not_keep_it \
  test_an_interrupted_freeze_leaves_a_writable_copy \
  test_an_interrupted_close_leaves_its_copy_writable \
  test_a_close_stopped_mid_step_stops_its_engine_first \
  test_a_close_stopped_as_its_engine_starts_changes_nothing \
  test_a_killed_close_is_repaired_only_after_its_engine_ends \
  test_an_engine_that_dies_during_removal_leaves_a_writable_copy \
  test_control_character_names_hide_the_whole_folder \
  test_only_rebuildable_directories_free_of_work_are_offered \
  test_preview_binds_contents_and_identity \
  test_unknown_flags_and_help_remove_nothing \
  test_docker_listing_failure_is_unknown_and_retried
