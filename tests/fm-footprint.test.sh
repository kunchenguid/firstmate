#!/usr/bin/env bash
# Behavior tests for bin/fm-footprint.sh and bin/fm-footprint-lib.sh, driven
# through the script's own commands and the library's public functions:
# config/footprint parsing and refusals, the task scratch area and its
# exports, close-time cleanup (scratch, labelled Docker through a recording
# fake docker, refusals), the shared-cache cap through fake tool commands, the
# old-folder preview and its manifest-bound removal, the daily pass and its
# check gate, and the report (disk kinds, Docker absent, leftover processes,
# allowance per lane from fixture transcripts, Linux and WSL platform lines).
# shellcheck disable=SC2016,SC2129 # snippets are expanded by the child bash; fixtures append line by line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-footprint)
FOOTPRINT="$ROOT/bin/fm-footprint.sh"
unset FM_SCRATCH_ROOT_OVERRIDE
# Scratch roots stay short, as a real one must for the temp-path limit.
SHORT=$(mktemp -d /tmp/fmfp.XXXXXX) || fail "cannot create a short temp root"
SHORT=$(cd -P "$SHORT" && pwd -P) || fail "cannot resolve the short temp root"
FM_TEST_CLEANUP_DIRS+=("$SHORT")


# new_home <name>: a minimal home plus a private user HOME and fake bin.
# Sets H (home), U (user HOME), FB (fake bin).
new_home() {
  H="$TMP_ROOT/$1/home"
  U="$TMP_ROOT/$1/user"
  mkdir -p "$H/data" "$H/state" "$H/config" "$U"
  FB=$(fm_fakebin "$TMP_ROOT/$1")
  ln -sf "$(command -v jq)" "$FB/jq"
}

# fp <args...>: run fm-footprint.sh against H with only FB and the base PATH.
fp() {
  HOME="$U" FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$H/state" \
    FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    CLAUDE_CONFIG_DIR="$U/.claude" CODEX_HOME="$U/.codex" \
    PATH="$FB:$BASE_PATH" "$FOOTPRINT" "$@" 2>&1
}

# lib <snippet>: run a snippet with the library sourced against H.
lib() {
  HOME="$U" H="$H" LIB_DIR="$ROOT/bin" PATH="$FB:$BASE_PATH" \
    bash -c '. "$LIB_DIR/fm-timeout-lib.sh"; . "$LIB_DIR/fm-footprint-lib.sh"; '"$1" 2>&1
}

home_key() {
  lib 'fm_footprint_home_key "$H"'
}

# fake_docker: a docker that answers info and label-filtered listings from
# $FB/docker.objects ("kind<TAB>id<TAB>label") and logs every call.
fake_docker() {
  cat > "$FB/docker" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "$*" >> "$dir/docker.log"
[ -e "$dir/docker.down" ] && exit 1
filter=
for a in "$@"; do case "$a" in label=*) filter=${a#label=} ;; esac; done
list() { awk -F '\t' -v k="$1" -v f="$filter" '$1 == k && $3 == f { print $2 }' "$dir/docker.objects"; }
drop() { awk -F '\t' -v k="$1" -v id="$2" '!($1 == k && $2 == id)' "$dir/docker.objects" > "$dir/o.tmp" && mv "$dir/o.tmp" "$dir/docker.objects"; }
case "$1 ${2:-}" in
  "info "*) echo 29.0.0 ;;
  "ps "*) list container ;;
  "network ls") list network ;;
  "volume ls") list volume ;;
  "image ls") list image ;;
  "rm "*) for a in "$@"; do case "$a" in rm|-f|-v) ;; *) drop container "$a" ;; esac; done ;;
  "network rm") shift 2; for a in "$@"; do drop network "$a"; done ;;
  "volume rm") shift 2; for a in "$@"; do [ "$a" = -f ] || drop volume "$a"; done ;;
  "image rm") shift 2; for a in "$@"; do [ "$a" = -f ] || drop image "$a"; done ;;
  "system df") ;;
esac
exit 0
SH
  chmod +x "$FB/docker"
  : > "$FB/docker.objects"
  : > "$FB/docker.log"
}

# --- config ------------------------------------------------------------------

test_config_defaults_and_refusals() {
  local out
  new_home config
  out=$(lib 'fm_footprint_config_read "$H/config"; echo "$FP_TASK_CLEANUP $FP_TASK_TMPDIR $FP_DOCKER_LABELS [$FP_CACHE_CAP_GB] $FP_ORPHAN_GRACE_HOURS $FP_OLD_TASK_DAYS"; fm_footprint_scratch_root "$H"; echo "$FP_SCRATCH_ROOT"')
  case "$(uname -s)" in
    Darwin) assert_equals "on on on [] 24 30
$U/Library/Caches/firstmate/scratch" "$out" "absent config must give the defaults" ;;
    *) assert_equals "on on on [] 24 30
${XDG_CACHE_HOME:-$U/.cache}/firstmate/scratch" "$out" "absent config must give the defaults" ;;
  esac
  printf '# local choices\ncache-cap-gb 50\ntask-tmpdir off   # trailing comment\n\nold-task-days 7\n' > "$H/config/footprint"
  out=$(lib 'fm_footprint_config_read "$H/config" && echo "$FP_CACHE_CAP_GB $FP_TASK_TMPDIR $FP_OLD_TASK_DAYS"')
  assert_equals "50 off 7" "$out" "valid keys must be read"
  for bad in 'cache-cap-gb lots' 'task-cleanup maybe' 'frobnicate 1' 'old-task-days 1.5' 'cache-cap-gb 1 2' 'scratch-root'; do
    printf '%s\n' "$bad" > "$H/config/footprint"
    out=$(lib 'fm_footprint_config_read "$H/config" && echo accepted || echo "refused: $FP_CONFIG_ERROR"')
    assert_contains "$out" "refused: $H/config/footprint line 1" "malformed '$bad' must be refused naming its line"
  done
  printf 'cache-cap-gb 5\ncache-cap-gb 6\n' > "$H/config/footprint"
  out=$(lib 'fm_footprint_config_read "$H/config" || echo "$FP_CONFIG_ERROR"')
  assert_contains "$out" "line 2: 'cache-cap-gb' is set more than once" "a repeated key must be refused"
  for root in relative/path "/$(printf 'x%.0s' $(seq 1 70))" "$H/data/scratch" "/tmp/a/../b"; do
    printf 'scratch-root %s\n' "$root" > "$H/config/footprint"
    out=$(lib 'fm_footprint_config_read "$H/config"; fm_footprint_scratch_root "$H" && echo accepted || echo "refused: $FP_CONFIG_ERROR"')
    assert_contains "$out" "refused: scratch-root" "scratch-root '$root' must be refused with its reason"
  done
  rm -f "$H/config/footprint"
  ln -s /etc/hosts "$H/config/footprint"
  out=$(lib 'fm_footprint_config_read "$H/config" || echo "$FP_CONFIG_ERROR"')
  assert_contains "$out" "is not a readable regular file" "a symlinked config must be refused"
  rm -f "$H/config/footprint"
  pass "config/footprint defaults, valid keys, and every refusal"
}

# --- scratch area and exports ---------------------------------------------------

test_task_env_creates_private_area_and_exports() {
  local out key root mode
  new_home env
  root="$SHORT/env"
  printf 'scratch-root %s\n' "$root" > "$H/config/footprint"
  key=$(home_key)
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" task-a1 claude')
  assert_equals "FM_TASK_SCRATCH=$root/$key/task-a1
FM_DOCKER_LABEL=firstmate.task=$key/task-a1
COMPOSE_PROJECT_NAME=fm-$key-task-a1
TMPDIR=$root/$key/task-a1/tmp
TMP=$root/$key/task-a1/tmp
TEMP=$root/$key/task-a1/tmp" "$out" "a covered tool must receive the scratch area, labels, and temp"
  for d in "$root" "$root/$key" "$root/$key/task-a1" "$root/$key/task-a1/tmp"; do
    mode=$(stat -f %Lp "$d" 2>/dev/null || stat -c %a "$d")
    assert_equals 700 "$mode" "$d must be private"
  done
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" Task.B2 pi')
  assert_contains "$out" "COMPOSE_PROJECT_NAME=fm-$key-task_b2" "a compose name must be lowercase with dots as underscores"
  assert_contains "$out" "# pi is not verified with a redirected TMPDIR" "an unverified tool must be named as not covered"
  assert_not_contains "$out" "TMPDIR=" "an unverified tool must keep its inherited temp"
  printf 'scratch-root %s\ntask-tmpdir off\ndocker-labels off\n' "$root" > "$H/config/footprint"
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" task-c3 codex')
  assert_equals "FM_TASK_SCRATCH=$root/$key/task-c3
# task-tmpdir off: temp stays where the worker inherits it" "$out" "switches must turn off temp and labels"
  printf 'scratch-root %s\n' "$root" > "$H/config/footprint"
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" "$(printf "l%.0s" $(seq 1 60))" codex')
  assert_contains "$out" "bytes, over 90" "a temp path past the socket-safe length must not be exported"
  assert_not_contains "$out" "TMPDIR=" "an over-long temp path must not be exported"
  mkdir -p "$root/$key/shared-d4"
  chmod 777 "$root/$key/shared-d4"
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" shared-d4 codex && echo accepted')
  assert_contains "$out" "is not a private directory owned by this user" "a writable-by-others area must be refused"
  assert_not_contains "$out" accepted "a writable-by-others area must not be used"
  ln -s /tmp "$root/$key/linked-e5"
  out=$(lib 'fm_footprint_task_env "$H/config" "$H" linked-e5 codex && echo accepted')
  assert_not_contains "$out" accepted "a symlinked area must be refused"
  pass "the scratch area is private and exports follow the tool, length, and switches"
}

test_two_homes_never_share_scratch() {
  local a b
  new_home homes-a
  a=$(lib 'FM_SCRATCH_ROOT_OVERRIDE='"$SHORT"'/shared fm_footprint_task_env "$H/config" "$H" same-id codex | head -1')
  new_home homes-b
  b=$(lib 'FM_SCRATCH_ROOT_OVERRIDE='"$SHORT"'/shared fm_footprint_task_env "$H/config" "$H" same-id codex | head -1')
  assert_not_equals "$a" "$b" "two homes reusing a task id must get different scratch areas"
  pass "two homes on one machine that reuse a task id get separate scratch areas"
}

# --- task-close ------------------------------------------------------------------

scratch_for() {  # <id>: creates and prints the task's scratch area under H
  printf 'scratch-root %s\n' "$SHORT/$CASE" > "$H/config/footprint"
  lib 'fm_footprint_task_env "$H/config" "$H" '"$1"' codex' | sed -n 's/^FM_TASK_SCRATCH=//p'
}

test_task_close_removes_scratch_and_labelled_docker_only() {
  local s key out
  CASE=close
  new_home "$CASE"
  fake_docker
  s=$(scratch_for task-x1)
  key=$(home_key)
  mkdir -p "$s/tmp/chrome-profile" "$s/gomod/pkg"
  head -c 200000 /dev/zero > "$s/tmp/chrome-profile/cache.bin"
  printf x > "$s/gomod/pkg/readonly.go"
  chmod 0444 "$s/gomod/pkg/readonly.go"
  chmod 0555 "$s/gomod/pkg"
  mkdir -p "$H/data/task-x1"
  printf 'brief\n' > "$H/data/task-x1/brief.md"
  printf 'container\tc1\tfirstmate.task=%s/task-x1\n' "$key" >> "$FB/docker.objects"
  printf 'container\tc2\tcom.docker.compose.project=fm-%s-task-x1\n' "$key" >> "$FB/docker.objects"
  printf 'volume\tv1\tfirstmate.task=%s/task-x1\n' "$key" >> "$FB/docker.objects"
  printf 'network\tn1\tcom.docker.compose.project=fm-%s-task-x1\n' "$key" >> "$FB/docker.objects"
  printf 'image\ti1\tfirstmate.task=%s/task-x1\n' "$key" >> "$FB/docker.objects"
  printf 'container\tother\tfirstmate.task=%s/task-y2\n' "$key" >> "$FB/docker.objects"
  printf 'volume\tforeign\tfirstmate.task=00000000/task-x1\n' >> "$FB/docker.objects"
  printf 'container\tplain\t\n' >> "$FB/docker.objects"
  out=$(fp task-close task-x1 "$s" projects/demo)
  expect_code 0 $? "task-close must exit 0"
  assert_absent "$s" "the scratch area, including read-only directories, must be removed"
  assert_contains "$out" "scratch removed" "the summary must report the scratch removal"
  assert_contains "$out" "Docker: 5 labelled object(s) removed" "the summary must count the labelled Docker objects"
  assert_equals "container	other	firstmate.task=$key/task-y2
volume	foreign	firstmate.task=00000000/task-x1
container	plain	" "$(cat "$FB/docker.objects")" "only this task's labelled objects may be removed"
  assert_no_grep 'prune' "$FB/docker.log" "close-time cleanup must never prune"
  assert_present "$H/data/task-x1/brief.md" "kept records must stay"
  out=$(awk -F '\t' 'NR == 1 { print $2, $3, $6, $7, $8 }' "$H/data/footprint-ledger.tsv")
  assert_equals "task-x1 projects/demo 5 removed removed" "$out" "one ledger line must record the close"
  case "$(awk -F '\t' '{print $5}' "$H/data/footprint-ledger.tsv")" in ''|*[!0-9]*|0) fail "the ledger must record the scratch bytes removed" ;; esac
  assert_equals "-" "$(awk -F '\t' '{print $9}' "$H/data/footprint-ledger.tsv")" "a small kept folder must not be flagged"
  # A kept folder over keep-warn-mb is flagged and kept whole.
  printf 'scratch-root %s\nkeep-warn-mb 0\n' "$SHORT/$CASE" > "$H/config/footprint"
  head -c 2000000 /dev/zero > "$H/data/task-x1/evidence.bin"
  out=$(fp task-close task-x1 "")
  assert_contains "$out" "Kept folder data/task-x1 is" "an oversized kept folder must be named"
  assert_present "$H/data/task-x1/evidence.bin" "an oversized kept folder must be kept whole"
  assert_equals "oversized" "$(awk -F '\t' 'END {print $9}' "$H/data/footprint-ledger.tsv")" "the ledger must flag the oversized folder"
  mode=$(stat -f %Lp "$H/data/footprint-ledger.tsv" 2>/dev/null || stat -c %a "$H/data/footprint-ledger.tsv")
  assert_equals 600 "$mode" "the ledger must be private"
  pass "task-close removes the scratch area and only the task's labelled Docker material"
}

test_task_close_with_its_own_temp_inside_scratch() {
  local s out
  CASE=close-owntemp
  new_home "$CASE"
  fake_docker
  s=$(scratch_for task-t1)
  mkdir -p "$H/data/task-t1"
  printf 'brief\n' > "$H/data/task-t1/brief.md"
  printf 'container\tc1\tfirstmate.task=%s/task-t1\n' "$(home_key)" >> "$FB/docker.objects"
  # The bash fallback, like GNU timeout on Linux, needs a usable TMPDIR.
  out=$(TMPDIR="$s/tmp" FM_TIMEOUT_MECHANISM_OVERRIDE=bash fp task-close task-t1 "$s")
  assert_absent "$s" "the scratch area must be removed"
  assert_contains "$out" "Docker: 1 labelled object(s) removed" "Docker cleanup must still run after the caller's temp was removed"
  case "$(awk -F '\t' '{print $4}' "$H/data/footprint-ledger.tsv")" in ''|*[!0-9]*) fail "the kept size must still be measured" ;; esac
  pass "task-close still removes Docker material and measures kept size when the caller's temp was inside the area"
}

test_task_close_refusals_remove_nothing() {
  local s out other
  CASE=close-refuse
  new_home "$CASE"
  fake_docker
  s=$(scratch_for task-r1)
  other="$TMP_ROOT/$CASE/elsewhere"
  mkdir -p "$other"
  printf keep > "$other/file"
  out=$(fp task-close task-r1 "$other")
  assert_present "$other/file" "a recorded path outside this home's area must never be removed"
  assert_contains "$out" "is not this home's area for the task" "the refusal must be named"
  out=$(fp task-close task-q9 "$s")
  assert_present "$s" "another task's area must never be removed under a different id"
  printf 'scratch-root %s\ntask-cleanup off\n' "$SHORT/$CASE" > "$H/config/footprint"
  printf 'container\tc1\tfirstmate.task=%s/task-r1\n' "$(home_key)" >> "$FB/docker.objects"
  out=$(fp task-close task-r1 "$s")
  assert_present "$s" "task-cleanup off must keep the scratch area"
  assert_contains "$out" "task-cleanup is off" "task-cleanup off must be reported"
  assert_no_regex '^rm ' "$FB/docker.log" "task-cleanup off must remove no Docker material"
  printf 'cache-cap-gb nope\n' > "$H/config/footprint"
  out=$(fp task-close task-r1 "$s")
  expect_code 0 $? "a malformed config must not fail cleanup"
  assert_present "$s" "a malformed config must remove nothing"
  pass "task-close refuses foreign paths, other ids, cleanup off, and a bad config, removing nothing"
}

test_task_close_docker_absent_or_down() {
  local s out
  CASE=close-nodocker
  new_home "$CASE"
  s=$(scratch_for task-n1)
  out=$(fp task-close task-n1 "$s")
  assert_absent "$s" "scratch must still be removed without Docker"
  assert_contains "$out" "Docker not present" "an absent Docker must be a normal, named case"
  fake_docker
  touch "$FB/docker.down"
  s=$(scratch_for task-n2)
  out=$(fp task-close task-n2 "$s")
  assert_contains "$out" "Docker not present" "a Docker daemon that does not answer must be skipped"
  assert_no_regex '^rm ' "$FB/docker.log" "nothing may be removed when the daemon does not answer"
  pass "task-close skips Docker when it is absent or not running"
}

# --- caches -----------------------------------------------------------------------

# fake_cache_tool <name> <dir> <size-kb> <mtime-epoch> [fail]: a tool whose
# cache-dir command prints <dir> and whose trim command empties it (or fails).
fake_cache_tool() {
  local name=$1 dir=$2 kb=$3 mtime=$4 failing=${5:-}
  mkdir -p "$dir"
  head -c $((kb * 1024)) /dev/zero > "$dir/blob"
  fm_touch_epoch "$mtime" "$dir/blob" "$dir"
  cat > "$FB/$name" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FB/trim.log"
case "\$*" in
  "cache dir"|"config get cache"|"pm cache") printf '%s\n' "$dir" ;;
  "cache prune"|"cache verify"|"cache purge"|"pm cache rm")
    [ -z "$failing" ] || exit 3
    rm -f "$dir/blob" ;;
esac
SH
  chmod +x "$FB/$name"
}

test_cache_cap_trims_least_recently_used_first() {
  local out now
  CASE=caches
  new_home "$CASE"
  now=$(date +%s)
  : > "$FB/trim.log"
  fake_cache_tool uv "$U/c/uv" 3000 $((now - 9 * 86400))
  fake_cache_tool pip3 "$U/c/pip" 1000 $((now - 5 * 86400)) fail
  fake_cache_tool npm "$U/c/npm" 2000 $((now - 1 * 86400))
  fake_cache_tool bun "$U/c/bun" 500 $((now - 60))
  mkdir -p "$U/.cargo/registry"
  head -c $((500 * 1024)) /dev/zero > "$U/.cargo/registry/blob"
  fm_touch_epoch $((now - 30 * 86400)) "$U/.cargo/registry/blob" "$U/.cargo/registry"
  export FM_FOOTPRINT_CACHE_NAMES="uv npm pip bun cargo"
  out=$(fp trim-caches)
  assert_contains "$out" "No cache cap set" "without a cap nothing is trimmed"
  assert_no_regex 'prune|verify|purge|rm' "$FB/trim.log" "no trim command may run without a cap"
  out=$(fp caches --json | jq -c '[.caches[] | [.name, .trim]]')
  assert_equals '[["uv","uv cache prune"],["npm","npm cache verify"],["pip","pip3 cache purge"],["bun","bun pm cache rm"],["cargo",null]]' "$out" "caches must list each tool's own trim command"
  # About 7 MB against a 2.5 MB cap, oldest first: cargo has no trim command,
  # uv is trimmed, pip's command fails, npm is trimmed and brings the total
  # under the cap, so bun, the most recently used, is never touched.
  printf 'cache-cap-gb 0.0025\n' > "$H/config/footprint"
  out=$(fp trim-caches --dry-run)
  assert_contains "$out" "would run: uv cache prune" "dry-run must name the first trim"
  assert_no_regex 'prune|verify|purge|rm' "$FB/trim.log" "dry-run must run nothing"
  out=$(fp trim-caches)
  assert_contains "$out" "cargo: no trim command, skipped" "a cache with no trim command must be skipped and named"
  assert_contains "$out" "ran: uv cache prune" "the least recently used trimmable cache must be trimmed first"
  assert_contains "$out" "pip: pip3 cache purge failed, skipped" "a failing trim must be skipped and named"
  assert_contains "$out" "ran: npm cache verify" "trimming must continue while over the cap"
  assert_equals "cache prune
cache purge
cache verify" "$(grep -v 'dir\|get\|^pm cache$' "$FB/trim.log")" "trims must run least recently used first and stop under the cap"
  assert_absent "$U/c/uv/blob" "uv's own command must have trimmed it"
  assert_present "$U/c/bun/blob" "the most recently used cache must be left once under the cap"
  assert_present "$U/.cargo/registry/blob" "Firstmate must never delete inside a cache itself"
  assert_contains "$out" "finding: trim failed for: pip" "a failed trim must be a finding"
  unset FM_FOOTPRINT_CACHE_NAMES
  pass "the cache cap trims least recently used first with each tool's own command"
}

# --- old task folders --------------------------------------------------------------

make_checkout() {  # <dir> <remote-bare> [unlanded|dirty|untracked|ignored]
  local dir=$1 bare=$2 how=${3:-}
  git init -q --bare "$bare"
  git clone -q "$bare" "$dir" 2>/dev/null
  fm_git_identity "$dir"
  printf 'a\n' > "$dir/a.txt"
  git -C "$dir" add a.txt
  git -C "$dir" commit -q -m a
  git -C "$dir" push -q origin HEAD 2>/dev/null
  printf 'node_modules/\nsecret.env\n' > "$dir/.gitignore"
  git -C "$dir" add .gitignore && git -C "$dir" commit -q -m ignore && git -C "$dir" push -q origin HEAD 2>/dev/null
  mkdir -p "$dir/node_modules/x"
  case "$how" in
    unlanded) printf 'b\n' > "$dir/b.txt"; git -C "$dir" add b.txt; git -C "$dir" commit -q -m local ;;
    dirty) printf 'changed\n' >> "$dir/a.txt" ;;
    untracked) printf 'new\n' > "$dir/new.txt" ;;
    ignored) printf 'k=v\n' > "$dir/secret.env" ;;
  esac
}

make_old_folders() {
  local old now stamp
  now=$(date +%s)
  old=$((now - 60 * 86400))
  mkdir -p "$H/data/old-a1/node_modules/pkg" "$H/data/old-a1/sub/.venv/lib" "$H/data/old-a1/children/c1/node_modules" "$H/data/old-a1/evidence"
  printf 'brief\n' > "$H/data/old-a1/brief.md"
  printf 'report\n' > "$H/data/old-a1/report.md"
  printf 'status\n' > "$H/data/old-a1/status.log"
  printf '{}\n' > "$H/data/old-a1/dispatch-resolution.json"
  printf 'answers\n' > "$H/data/old-a1/captain-answers.md"
  head -c 4096 /dev/zero > "$H/data/old-a1/node_modules/pkg/index.js"
  printf proof > "$H/data/old-a1/evidence/run.log"
  make_checkout "$H/data/old-a1/landed" "$TMP_ROOT/$CASE/r1.git"
  make_checkout "$H/data/old-a1/unlanded" "$TMP_ROOT/$CASE/r2.git" unlanded
  make_checkout "$H/data/old-a1/dirty" "$TMP_ROOT/$CASE/r3.git" dirty
  make_checkout "$H/data/old-a1/untracked" "$TMP_ROOT/$CASE/r4.git" untracked
  make_checkout "$H/data/old-a1/ignored" "$TMP_ROOT/$CASE/r5.git" ignored
  mkdir -p "$H/data/live-b2/node_modules"
  printf 'brief\n' > "$H/data/live-b2/brief.md"
  printf 'worktree=/x\n' > "$H/state/live-b2.meta"
  mkdir -p "$H/data/new-c3/node_modules"
  printf 'brief\n' > "$H/data/new-c3/brief.md"
  mkdir -p "$H/data/notatask/node_modules"
  printf 'backlog\n' > "$H/data/backlog.md"
  stamp=$(TZ=UTC0 date -d "@$old" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -r "$old" +%Y%m%d%H%M.%S)
  TZ=UTC0 find "$H/data" -exec touch -t "$stamp" {} +
  touch "$H/data/new-c3/brief.md"
}

test_old_tasks_preview_offers_only_rebuildable_and_landed() {
  local out id listed
  CASE=old
  new_home "$CASE"
  ln -sf "$(command -v git)" "$FB/git"
  make_old_folders
  out=$(fp old-tasks)
  listed=$(awk -F '\t' 'NR > 2 { print $1, $3 }' "$H/state/footprint-old-tasks.preview" | sort -t ' ' -k2)
  assert_equals "$(printf '%s\n' \
    "landed-checkout $H/data/old-a1/landed" \
    "rebuildable $H/data/old-a1/dirty/node_modules" \
    "rebuildable $H/data/old-a1/ignored/node_modules" \
    "rebuildable $H/data/old-a1/node_modules" \
    "rebuildable $H/data/old-a1/sub/.venv" \
    "rebuildable $H/data/old-a1/unlanded/node_modules" \
    "rebuildable $H/data/old-a1/untracked/node_modules" | sort -t ' ' -k2)" \
    "$listed" "the preview must offer only rebuildable layouts and the landed checkout"
  for never in brief.md report.md status.log dispatch-resolution.json captain-answers.md evidence children unlanded dirty untracked ignored; do
    printf '%s\n' "$listed" | grep -q " $H/data/old-a1/$never\$" && fail "$never must never be offered"
  done
  assert_not_contains "$listed" "live-b2" "a live task's folder must never be offered"
  assert_not_contains "$listed" "new-c3" "a recent task folder must not be offered"
  assert_not_contains "$listed" "notatask" "a directory that is not a task folder must not be offered"
  id=$(awk -F '\t' '$1 == "id" {print $2}' "$H/state/footprint-old-tasks.preview")
  assert_contains "$out" "old-tasks --apply $id" "the preview must print the apply command with its id"
  # A changed tree refuses and removes nothing.
  printf more > "$H/data/old-a1/node_modules/pkg/extra.js"
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "changed since preview" "a tree changed after the preview must refuse"
  assert_present "$H/data/old-a1/node_modules/pkg/index.js" "a refused apply must remove nothing"
  out=$(fp old-tasks --apply deadbeef)
  assert_contains "$out" "is not the current preview" "a wrong preview id must refuse"
  # Re-preview, then apply removes exactly the list.
  fp old-tasks >/dev/null
  id=$(awk -F '\t' '$1 == "id" {print $2}' "$H/state/footprint-old-tasks.preview")
  out=$(fp old-tasks --apply "$id")
  assert_contains "$out" "Removed" "apply must report what it removed"
  for gone in node_modules sub/.venv landed unlanded/node_modules; do
    assert_absent "$H/data/old-a1/$gone" "$gone must be removed by apply"
  done
  for kept in brief.md report.md status.log dispatch-resolution.json captain-answers.md evidence/run.log children/c1/node_modules unlanded/b.txt dirty/a.txt ignored/secret.env; do
    assert_present "$H/data/old-a1/$kept" "$kept must survive apply"
  done
  assert_present "$H/data/live-b2/node_modules" "the live task must be untouched"
  assert_present "$H/data/backlog.md" "the task list must be untouched"
  assert_absent "$H/state/footprint-old-tasks.preview" "an applied preview must be retired"
  pass "old-folder preview offers only rebuildable and landed material and removes exactly the preview"
}

# --- sweep and check -------------------------------------------------------------

test_sweep_removes_only_old_orphaned_scratch() {
  local key root now out
  CASE=sweep
  new_home "$CASE"
  root="$SHORT/$CASE"
  printf 'scratch-root %s\n' "$root" > "$H/config/footprint"
  for id in orphan-old orphan-new live-old; do
    lib 'fm_footprint_task_env "$H/config" "$H" '"$id"' codex' >/dev/null
  done
  key=$(home_key)
  mkdir -p "$root/otherhom/orphan-old"
  now=$(date +%s)
  fm_touch_epoch $((now - 48 * 3600)) "$root/$key/orphan-old" "$root/$key/live-old" "$root/otherhom/orphan-old"
  printf 'worktree=/x\n' > "$H/state/live-old.meta"
  out=$(fp sweep --dry-run)
  assert_contains "$out" "would remove orphaned scratch $root/$key/orphan-old" "dry-run must name the orphan"
  assert_present "$root/$key/orphan-old" "dry-run must remove nothing"
  out=$(fp sweep)
  assert_absent "$root/$key/orphan-old" "an orphan older than the grace period must be removed"
  assert_present "$root/$key/orphan-new" "an orphan inside the grace period must stay"
  assert_present "$root/$key/live-old" "a scratch area with a live task must stay"
  assert_present "$root/otherhom/orphan-old" "another home's scratch must never be removed"
  assert_contains "$out" "Removed 1 orphaned scratch area(s)" "the sweep must count what it removed"
  pass "the daily sweep removes only this home's orphaned scratch past its grace period"
}

test_check_runs_daily_and_reports_changes_once() {
  local now out
  CASE=check
  new_home "$CASE"
  now=$(date +%s)
  fake_cache_tool uv "$U/c/uv" 2000 $((now - 3 * 86400)) fail
  export FM_FOOTPRINT_CACHE_NAMES=uv
  printf 'cache-cap-gb 0.001\nscratch-root %s\n' "$SHORT/$CASE" > "$H/config/footprint"
  out=$(FM_FOOTPRINT_NOW=$now fp check)
  assert_contains "$out" "footprint: shared caches still" "an over-cap result must be reported"
  out=$(FM_FOOTPRINT_NOW=$((now + 3600)) fp check)
  assert_equals "" "$out" "the check must stay silent inside its daily interval"
  out=$(FM_FOOTPRINT_NOW=$((now + 90000)) fp check)
  assert_equals "" "$out" "an unchanged finding must not be reported again"
  printf 'cache-cap-gb 1\nscratch-root %s\n' "$SHORT/$CASE" > "$H/config/footprint"
  out=$(FM_FOOTPRINT_NOW=$((now + 180000)) fp check)
  assert_equals "" "$out" "a cleared finding must be silent"
  unset FM_FOOTPRINT_CACHE_NAMES
  out=$(fp arm)
  assert_contains "$out" "armed: state/footprint.check.sh" "arm must report the shim"
  assert_present "$H/state/footprint.check.sh" "arm must write the shim"
  assert_present "$H/state/footprint.check-trust" "arm must bind the shim"
  out=$(fp disarm)
  assert_absent "$H/state/footprint.check.sh" "disarm must remove the shim"
  assert_absent "$H/state/footprint.check-trust" "disarm must remove the binding"
  pass "the check runs at most daily, reports a finding once, and arms and disarms"
}

# --- report ---------------------------------------------------------------------

write_transcripts() {
  local proj="$U/.claude/projects"
  mkdir -p "$proj/main" "$proj/w/sess1/subagents" "$proj/other" "$U/.codex/sessions/2026/11/16"
  {
    printf '{"type":"user","cwd":"%s","message":{"content":"hi"}}\n' "$H"
    printf '{"type":"assistant","cwd":"%s","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}}}\n' "$H"
    printf '{"type":"assistant","cwd":"%s","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}}}\n' "$H"
    printf '{"type":"assistant","cwd":"%s","message":{"id":"msg_2","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000,"output_tokens":7}}}\n' "$H"
  } > "$proj/main/a.jsonl"
  {
    printf '{"type":"user","cwd":"/gone/worktree","message":{"content":"Firstmate operational input waiting: read x"}}\n'
    printf '{"type":"assistant","cwd":"/gone/worktree","message":{"id":"msg_3","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}\n'
  } > "$proj/w/sess1.jsonl"
  printf '{"type":"assistant","cwd":"/gone/worktree","message":{"id":"msg_4","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}\n' \
    > "$proj/w/sess1/subagents/agent-1.jsonl"
  printf '{"type":"assistant","cwd":"/somewhere","message":{"id":"msg_5","usage":{"input_tokens":9,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}}}\n' \
    > "$proj/other/o.jsonl"
  {
    printf '{"type":"session_meta","payload":{"cwd":"/gone/codex-wt"}}\n'
    printf '{"type":"response_item","payload":{"text":"FIRSTMATE_OP: v1 launch-brief: do it"}}\n'
    printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":10,"total_tokens":110}}}}\n'
    printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":30,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":140,"output_tokens":20,"total_tokens":170}}}}\n'
  } > "$U/.codex/sessions/2026/11/16/rollout-x.jsonl"
}

test_report_json_kinds_docker_absent_and_allowance() {
  local out key pid lanes
  CASE=report
  new_home "$CASE"
  printf 'scratch-root %s\n' "$SHORT/$CASE" > "$H/config/footprint"
  write_transcripts
  mkdir -p "$H/data/t1"
  printf 'brief\n' > "$H/data/t1/brief.md"
  head -c 50000 /dev/zero > "$H/data/t1/evidence.bin"
  lib 'fm_footprint_task_env "$H/config" "$H" gone-task codex' >/dev/null
  lib 'fm_footprint_task_env "$H/config" "$H" live-task codex' >/dev/null
  printf 'worktree=/x\n' > "$H/state/live-task.meta"
  key=$(home_key)
  ( cd "$SHORT/$CASE/$key/gone-task" && exec sleep 300 ) &
  pid=$!
  ( cd "$SHORT/$CASE/$key/live-task" && exec sleep 300 ) &
  local live_pid=$!
  sleep 1
  ln -sf "$(command -v lsof 2>/dev/null || printf /usr/sbin/lsof)" "$FB/lsof" 2>/dev/null || true
  mkdir -p "$TMP_ROOT/$CASE/tmp/fm-old-task" "$TMP_ROOT/$CASE/tmp/fm-x+launch"
  export FM_FOOTPRINT_TMP_ROOT="$TMP_ROOT/$CASE/tmp" FM_FOOTPRINT_SYSTEM_TMPDIR='' FM_FOOTPRINT_CACHE_NAMES=''
  out=$(fp report --json)
  kill "$pid" "$live_pid" 2>/dev/null
  printf '%s\n' "$out" | jq -e . >/dev/null || fail "report --json must be one JSON document: $out"
  assert_equals fm-footprint-report.v1 "$(printf '%s' "$out" | jq -r .schema)" "the report must carry its schema"
  assert_equals "not present" "$(printf '%s' "$out" | jq -r .docker.state)" "an absent Docker must read not present"
  assert_equals "t1" "$(printf '%s' "$out" | jq -r '.disk.largest_task_folders[0].task')" "the largest task folder must be listed"
  assert_equals 1 "$(printf '%s' "$out" | jq -r '.disk.task_temp_roots.count')" "per-task temp roots must be counted, launch namespaces excluded"
  assert_equals "2 1" "$(printf '%s' "$out" | jq -r '"\(.disk.scratch.areas) \(.disk.scratch.areas_without_task)"')" "scratch areas and those without a task must be counted"
  assert_equals "$pid no-task" "$(printf '%s' "$out" | jq -r '.leftover_processes.entries | map("\(.pid) \(.class)") | join(",")')" \
    "only the process in a task-less scratch area is a leftover"
  lanes=$(printf '%s' "$out" | jq -r '.allowance.lanes[] | "\(.lane) \(.tool) \(.sessions) \(.calls) \(.fresh) \(.cache_write) \(.cache_read) \(.output) \(.largest_context)"')
  assert_equals "main claude 1 2 30 100 4000 12 3020
other claude 1 1 9 0 0 9 9
worker claude 2 2 6 2 3 5 6
worker codex 1 2 50 0 200 30 150" "$lanes" "allowance must be summed per lane with duplicate messages counted once"
  out=$(fp report)
  assert_contains "$out" "Docker
  not present" "the text report must say Docker is not present"
  assert_contains "$out" "Allowance used, last 7 days" "the text report must carry the allowance section"
  unset FM_FOOTPRINT_TMP_ROOT FM_FOOTPRINT_SYSTEM_TMPDIR FM_FOOTPRINT_CACHE_NAMES
  pass "the report covers disk kinds, Docker absent, leftover processes, and allowance per lane"
}

test_report_platform_linux_and_wsl() {
  local out proc
  CASE=platform
  new_home "$CASE"
  proc="$TMP_ROOT/$CASE/proc"
  mkdir -p "$proc"
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Linux || /usr/bin/uname "$@"\n' > "$FB/uname"
  chmod +x "$FB/uname"
  printf 'Linux version 6.6.87.2-microsoft-standard-WSL2\n' > "$proc/version"
  export FM_FOOTPRINT_TMP_ROOT="$TMP_ROOT/$CASE" FM_FOOTPRINT_SYSTEM_TMPDIR='' FM_FOOTPRINT_CACHE_NAMES=
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" fp report --json | jq -r .platform)
  assert_equals "Linux (WSL)" "$out" "a WSL kernel must be named"
  printf 'Linux version 6.1.0 (builder@host)\n' > "$proc/version"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" fp report --json | jq -r .platform)
  assert_equals "Linux" "$out" "a plain Linux kernel must be named"
  rm -f "$FB/uname"
  # A home with an empty data/ folder, or none at all, holds no records: 0, not unknown.
  out=$(fp report --json | jq -r .disk.records_and_evidence_kb)
  assert_equals "0" "$out" "an empty data/ folder must report 0"
  rmdir "$H/data"
  out=$(fp report --json | jq -r .disk.records_and_evidence_kb)
  assert_equals "0" "$out" "a home with no data/ folder must report 0"
  mkdir -p "$H/data"
  unset FM_FOOTPRINT_TMP_ROOT FM_FOOTPRINT_SYSTEM_TMPDIR FM_FOOTPRINT_CACHE_NAMES
  pass "the report names Linux and Linux under WSL, and an empty or absent data/ folder as 0"
}

fm_test_run \
  test_config_defaults_and_refusals \
  test_task_env_creates_private_area_and_exports \
  test_two_homes_never_share_scratch \
  test_task_close_removes_scratch_and_labelled_docker_only \
  test_task_close_with_its_own_temp_inside_scratch \
  test_task_close_refusals_remove_nothing \
  test_task_close_docker_absent_or_down \
  test_cache_cap_trims_least_recently_used_first \
  test_old_tasks_preview_offers_only_rebuildable_and_landed \
  test_sweep_removes_only_old_orphaned_scratch \
  test_check_runs_daily_and_reports_changes_once \
  test_report_json_kinds_docker_absent_and_allowance \
  test_report_platform_linux_and_wsl
