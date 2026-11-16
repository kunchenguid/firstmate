#!/usr/bin/env bash
# Safety regressions for bin/fm-footprint.sh, one per way a removal could
# reach material it does not own or that has not landed, each driven through
# the script's public commands with real files, real git, and the real
# deletion code; only Docker is a stand-in client.
#   - a checkout inside a task's scratch area whose work has not landed keeps
#     the whole area, at close and in the daily pass; a landed one does not;
#   - the landing proof does not count the local validation gate
#     (refs/remotes/no-mistakes/*) as a published copy;
#   - scratch ownership needs the key directory's recorded home identity, so
#     a key directory that is a link, has no identity, or names another home
#     is never trusted;
#   - the daily pass removes an orphan only under the task's spawn lock, with
#     the record rechecked, and gives a reused task id a fresh area;
#   - two task ids that lowercase alike never share a compose project;
#   - the old-folder preview never offers anything from a folder holding a
#     name with a control character, never offers a rebuildable-named
#     directory that holds a repository or a record, and refuses an apply
#     after a same-size edit or a replaced entry;
#   - an unknown flag or --help on a destructive command removes nothing;
#   - a Docker listing that fails is recorded as unknown, queued, and retried
#     by the daily pass instead of being reported as removed.
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

# --- 1: unpublished work inside a scratch area ---------------------------------

test_scratch_with_unlanded_checkout_is_kept_whole() {
  local s out
  new_home unlanded-scratch
  s=$(scratch_for task-u1)
  local_repo "$s/extra-checkout"
  printf 'cache\n' > "$s/tmp/cache.bin"
  out=$(fp task-close task-u1 "$s")
  assert_present "$s/extra-checkout/unique.txt" "an unpublished checkout in scratch must survive close"
  assert_present "$s/tmp/cache.bin" "the whole area must be kept while it holds unlanded work"
  assert_contains "$out" "kept whole" "close must say the area was kept"
  assert_contains "$out" "$s/extra-checkout holds work that has not landed" "close must name the checkout"
  assert_contains "$(awk -F '\t' '{print $8}' "$H/data/footprint-ledger.tsv")" "kept-unlanded" "the ledger must record the kept area"
  # The daily pass keeps it too, and reports it.
  age 3 "$s"
  out=$(fp sweep)
  assert_present "$s/extra-checkout/unique.txt" "the daily pass must keep an orphan holding unlanded work"
  assert_contains "$out" "finding: 1 orphaned scratch area(s) hold work that has not landed (task-u1)" "the daily pass must report it"
  pass "a scratch area holding a checkout whose work has not landed is kept whole at close and by the daily pass"
}

test_scratch_with_landed_checkout_is_removed() {
  local s out
  new_home landed-scratch
  s=$(scratch_for task-l1)
  published_repo "$s/extra" "$TMP_ROOT/landed-scratch/origin.git"
  out=$(fp task-close task-l1 "$s")
  assert_absent "$s" "a scratch area whose only checkout has landed must be removed"
  assert_contains "$out" "scratch removed" "close must report the removal"
  pass "a scratch area whose checkouts have all landed is removed"
}

test_validation_gate_is_not_a_published_copy() {
  local s out gate
  new_home gate-scratch
  s=$(scratch_for task-g1)
  local_repo "$s/extra"
  gate="$TMP_ROOT/gate-scratch/gate.git"
  git init -q --bare "$gate"
  git_q -C "$s/extra" remote add no-mistakes "$gate"
  git_q -C "$s/extra" push -q no-mistakes HEAD:task
  git_q -C "$s/extra" fetch -q no-mistakes
  out=$(fp task-close task-g1 "$s")
  assert_present "$s/extra/unique.txt" "work pushed only to the local validation gate must be kept"
  assert_contains "$out" "kept whole" "close must keep the area"
  # The old-folder preview applies the same proof.
  finished_folder old-g2
  local_repo "$H/data/old-g2/extra"
  git_q -C "$H/data/old-g2/extra" remote add no-mistakes "$gate"
  git_q -C "$H/data/old-g2/extra" push -q no-mistakes HEAD:task2
  git_q -C "$H/data/old-g2/extra" fetch -q no-mistakes
  age 40 "$H/data/old-g2"
  out=$(fp old-tasks)
  assert_not_contains "$out" "$H/data/old-g2/extra" "a gate-only checkout must never be offered"
  pass "a commit present only in the local validation gate is not treated as landed"
}

# --- 3: ownership of the scratch key directory --------------------------------

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
  # A real key directory without this home's identity is refused too.
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
  # And spawn refuses to create an area under it.
  s=$(lib 'fm_footprint_task_env "$H/config" "$H" task-c codex' 2>&1)
  assert_contains "$s" "not a private directory owned by this user" "spawn must refuse a key directory naming another home"
  pass "scratch ownership needs the key directory's recorded home identity"
}

# --- 4: the daily pass and a spawn reusing the task id ---------------------------

test_sweep_respects_the_spawn_lock_and_live_records() {
  local key s holder out
  new_home sweep-lock
  key=$(home_key)
  s=$(scratch_for task-r1)
  printf 'work\n' > "$s/unique.txt"
  s2=$(scratch_for task-r2)
  age 3 "$s" "$s2"
  # A spawn holding task-r1's lock: the pass must leave that area alone.
  ( STATE="$H/state" FM_HOME="$H" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; echo held; sleep 30' _ "$ROOT" "$H/state/.spawn-task-r1.lock" ) > "$TMP_ROOT/sweep-lock/holder.out" &
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$TMP_ROOT/sweep-lock/holder.out" 2>/dev/null && break; sleep 0.3; done
  out=$(fp sweep)
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  assert_present "$s/unique.txt" "an area whose task is being spawned must not be removed"
  assert_contains "$out" "Skipped 1 orphaned scratch area(s) whose task was being spawned" "the pass must say it skipped it"
  assert_absent "$s2" "an ordinary orphan beside it is still removed"
  # A record published before the pass takes the lock keeps the area.
  printf 'worktree=/x\nscratch=%s\n' "$s" > "$H/state/task-r1.meta"
  rm -rf "$H/state/.spawn-task-r1.lock"
  out=$(fp sweep)
  assert_present "$s/unique.txt" "a live task's area must stay"
  # After an orphan is removed, a spawn reusing the id gets a fresh area.
  rm -f "$H/state/task-r1.meta"
  fp sweep >/dev/null
  assert_absent "$s" "the orphan is removed once its task is gone"
  s=$(scratch_for task-r1)
  assert_present "$s/tmp" "a spawn reusing the id must get a fresh area"
  pass "the daily pass removes an orphan only under its spawn lock with the record rechecked"
}

# --- 5: compose project collisions ----------------------------------------------

test_case_and_dot_collisions_never_share_a_compose_project() {
  local key a b out
  new_home compose
  key=$(home_key)
  a=$(lib '. "$LIB_DIR/fm-pr-lib.sh"; fm_task_id_creation_valid Task.A && fm_footprint_compose_project "$(fm_footprint_home_key "$H")" Task.A')
  b=$(lib '. "$LIB_DIR/fm-pr-lib.sh"; fm_task_id_creation_valid task_a && fm_footprint_compose_project "$(fm_footprint_home_key "$H")" task_a')
  [ -n "$a" ] && [ -n "$b" ] || fail "both ids must be valid task ids with a compose project"
  [ "$a" != "$b" ] || fail "Task.A and task_a must not share a compose project ($a)"
  cat > "$FB/docker" <<SH
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "info "*) echo 29 ;;
  "ps "*) for arg in "\$@"; do [ "\$arg" = "label=com.docker.compose.project=$b" ] && [ -f "$TMP_ROOT/compose/live" ] && echo live-container; done ;;
  "rm "*) rm -f "$TMP_ROOT/compose/live" ;;
esac
exit 0
SH
  chmod +x "$FB/docker"
  export FM_FOOTPRINT_DOCKER="$FB/docker"
  : > "$TMP_ROOT/compose/live"
  printf 'worktree=/x\n' > "$H/state/task_a.meta"
  out=$(fp task-close Task.A "")
  assert_present "$TMP_ROOT/compose/live" "closing Task.A must not remove task_a's container"
  assert_contains "$out" "Docker: 0 labelled object(s) removed" "nothing of another task may be removed"
  pass "two task ids that lowercase alike never share a compose project"
}

# --- 2, 6, 9: the old-folder preview -------------------------------------------

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
  age 40 "$H/data/old-n1"
  out=$(fp old-tasks)
  assert_not_contains "$out" "$victim" "a path outside the folder must never be offered"
  assert_not_contains "$out" "$H/data/old-n1" "nothing in a folder holding a control-character name may be offered"
  id=$(preview_id)
  [ -z "$id" ] || fp old-tasks --apply "$id" >/dev/null
  assert_present "$victim/.cache/must-survive" "the outside directory must survive"
  pass "a task folder holding a name with a control character is never offered from"
}

test_rebuildable_names_do_not_prove_disposability() {
  local out
  new_home named
  finished_folder old-m1
  local_repo "$H/data/old-m1/node_modules/local-package"
  local_repo "$H/data/old-m1/.cache"
  mkdir -p "$H/data/old-m1/sub/.venv"
  printf 'report\n' > "$H/data/old-m1/sub/.venv/report.md"
  mkdir -p "$H/data/old-m1/plain/node_modules/p"
  printf 'x\n' > "$H/data/old-m1/plain/node_modules/p/i.js"
  age 40 "$H/data/old-m1"
  out=$(fp old-tasks)
  assert_not_contains "$out" "$H/data/old-m1/node_modules" "a rebuildable-named directory holding a repository must not be offered"
  assert_not_contains "$out" "$H/data/old-m1/.cache" "a repository whose root has a rebuildable name must not be offered"
  assert_not_contains "$out" "$H/data/old-m1/sub/.venv" "a rebuildable-named directory holding a record must not be offered"
  assert_contains "$out" "$H/data/old-m1/plain/node_modules" "an ordinary rebuildable directory is still offered"
  fp old-tasks --apply "$(preview_id)" >/dev/null
  assert_present "$H/data/old-m1/node_modules/local-package/unique.txt" "the nested repository must survive apply"
  assert_present "$H/data/old-m1/.cache/unique.txt" "the .cache repository must survive apply"
  assert_present "$H/data/old-m1/sub/.venv/report.md" "the record must survive apply"
  assert_absent "$H/data/old-m1/plain/node_modules" "the ordinary rebuildable directory is removed"
  pass "a rebuildable name is a candidate only; repositories and records inside keep it"
}

test_preview_binds_contents_and_identity() {
  local id out
  new_home preview-id
  finished_folder old-p1
  mkdir -p "$H/data/old-p1/node_modules"
  printf 'before' > "$H/data/old-p1/node_modules/data"
  age 40 "$H/data/old-p1"
  fp old-tasks >/dev/null
  id=$(preview_id)
  printf 'after!' > "$H/data/old-p1/node_modules/data"
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "changed since preview" "a same-size edit after the preview must refuse"
  assert_present "$H/data/old-p1/node_modules/data" "a refused apply must remove nothing"
  fp old-tasks >/dev/null
  id=$(preview_id)
  mv "$H/data/old-p1/node_modules" "$H/data/old-p1/was"
  mkdir -p "$H/data/old-p1/node_modules"
  cp -p "$H/data/old-p1/was/data" "$H/data/old-p1/node_modules/data"
  age 40 "$H/data/old-p1"
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "changed since preview" "a replaced entry after the preview must refuse"
  assert_present "$H/data/old-p1/node_modules/data" "a refused apply must remove nothing"
  pass "the preview id binds every offered file's contents and identity"
}

# --- 8: flags on destructive commands -----------------------------------------

test_unknown_flags_and_help_remove_nothing() {
  local s out rc
  new_home flags
  s=$(scratch_for task-f1)
  age 3 "$s"
  out=$(fp sweep --help)
  rc=$?
  expect_code 0 "$rc" "sweep --help must succeed"
  assert_contains "$out" "fm-footprint.sh" "sweep --help must print the help"
  assert_present "$s" "sweep --help must remove nothing"
  for args in "sweep --dryrun" "trim-caches --dryrun" "sweep --dry-run --dry-run" "check now" "caches --jsn"; do
    # shellcheck disable=SC2086 # args is a fixed word list
    out=$(fp $args)
    rc=$?
    expect_code 2 "$rc" "'$args' must be refused"
    assert_contains "$out" "unknown argument" "'$args' must name the problem"
  done
  assert_present "$s" "a refused command must remove nothing"
  pass "an unknown flag or --help on a destructive command removes nothing"
}

# --- 11: Docker inventory failures ------------------------------------------------

test_docker_listing_failure_is_unknown_and_retried() {
  local key out
  new_home docker-fail
  key=$(home_key)
  cat > "$FB/docker" <<SH
#!/usr/bin/env bash
dir="$TMP_ROOT/docker-fail"
case "\$1" in info) echo 29; exit 0 ;; esac
[ -e "\$dir/listing.broken" ] && exit 42
case "\$1 \${2:-}" in
  "ps "*) [ -f "\$dir/obj" ] && for a in "\$@"; do [ "\$a" = "label=firstmate.task=$key/task-d1" ] && echo c1; done ;;
  "rm "*) rm -f "\$dir/obj" ;;
esac
exit 0
SH
  chmod +x "$FB/docker"
  export FM_FOOTPRINT_DOCKER="$FB/docker"
  : > "$TMP_ROOT/docker-fail/obj"
  : > "$TMP_ROOT/docker-fail/listing.broken"
  out=$(fp task-close task-d1 "")
  assert_contains "$out" "Docker did not list the task's objects; its cleanup is queued" "a failed listing must not read as removed"
  assert_equals "unknown" "$(awk -F '\t' 'END {print $7}' "$H/data/footprint-ledger.tsv")" "the ledger must record unknown"
  assert_grep "task-d1	" "$H/state/footprint-docker-retry" "the task must be queued for a retry"
  out=$(fp sweep)
  assert_contains "$out" "finding: Docker cleanup is pending for 1 closed task(s)" "a pending retry must be reported"
  rm -f "$TMP_ROOT/docker-fail/listing.broken"
  out=$(fp sweep)
  assert_absent "$TMP_ROOT/docker-fail/obj" "the daily pass must retry and remove the object"
  assert_absent "$H/state/footprint-docker-retry" "a finished retry must leave the queue"
  assert_equals "docker-retry" "$(awk -F '\t' 'END {print $7}' "$H/data/footprint-ledger.tsv")" "the retry must be in the ledger"
  pass "a Docker listing failure is recorded as unknown, queued, and retried by the daily pass"
}

fm_test_run \
  test_scratch_with_unlanded_checkout_is_kept_whole \
  test_scratch_with_landed_checkout_is_removed \
  test_validation_gate_is_not_a_published_copy \
  test_key_directory_identity_is_required \
  test_sweep_respects_the_spawn_lock_and_live_records \
  test_case_and_dot_collisions_never_share_a_compose_project \
  test_control_character_names_hide_the_whole_folder \
  test_rebuildable_names_do_not_prove_disposability \
  test_preview_binds_contents_and_identity \
  test_unknown_flags_and_help_remove_nothing \
  test_docker_listing_failure_is_unknown_and_retried
