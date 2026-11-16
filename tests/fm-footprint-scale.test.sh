#!/usr/bin/env bash
# Scale behavior for bin/fm-footprint.sh: the same results, and per-task cost
# that does not grow with fleet size, at 5, 100, and 1000 tasks.
#
# For each size N a synthetic home holds N live tasks (records and scratch
# areas), N finished task folders with a rebuildable directory each, N orphaned
# scratch areas, and a fake Docker holding N other tasks' labelled objects;
# each finished folder holds three rebuildable directories at two depths. The
# suite then measures, through the public commands:
#   - spawn-side scratch creation and close-time cleanup of ONE task, which
#     must stay flat: the 1000-task cost may not exceed four times the 5-task
#     cost plus one second, and must leave every other task's material intact;
#   - the daily pass, which must remove exactly the N orphans and nothing live;
#   - the old-folder preview, which must offer exactly the 3N rebuildable
#     directories and no record, at a per-folder cost that grows linearly;
#   - the report, which must count every area and folder.
# Each measurement prints as a "# scale" line so a run's output is the
# evidence of timings and sizes.
# shellcheck disable=SC2016 # snippets are expanded by the child bash that sources the library.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-footprint-scale)
SHORT=$(mktemp -d /tmp/fmsc.XXXXXX) || fail "cannot create a short scratch root"
SHORT=$(cd -P "$SHORT" && pwd -P) || fail "cannot resolve the short scratch root"
FM_TEST_CLEANUP_DIRS+=("$SHORT")
unset FM_SCRATCH_ROOT_OVERRIDE
export FM_FOOTPRINT_CACHE_NAMES='' FM_FOOTPRINT_SYSTEM_TMPDIR=''

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

fp() {
  HOME="$U" FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$H/state" \
    FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    CLAUDE_CONFIG_DIR="$U/.claude" CODEX_HOME="$U/.codex" FM_FOOTPRINT_TMP_ROOT="$TMP_ROOT/$N/tmp" \
    PATH="$FB:$BASE_PATH" "$ROOT/bin/fm-footprint.sh" "$@" 2>&1
}

lib() {
  HOME="$U" H="$H" LIB_DIR="$ROOT/bin" PATH="$FB:$BASE_PATH" \
    bash -c '. "$LIB_DIR/fm-timeout-lib.sh"; . "$LIB_DIR/fm-footprint-lib.sh"; '"$1" 2>&1
}

# build_home <n>: the synthetic home for one fleet size.
build_home() {
  local n=$1 i key root old stamp
  H="$TMP_ROOT/$n/home"
  U="$TMP_ROOT/$n/user"
  mkdir -p "$H/data" "$H/state" "$H/config" "$U" "$TMP_ROOT/$n/tmp"
  FB=$(fm_fakebin "$TMP_ROOT/$n")
  ln -sf "$(command -v jq)" "$FB/jq"
  root="$SHORT/$n"
  printf 'scratch-root %s\n' "$root" > "$H/config/footprint"
  key=$(lib 'fm_footprint_home_key "$H"')
  KEY=$key
  # The key directory and its recorded home identity, exactly as spawn makes them.
  lib 'fm_footprint_task_env "$H/config" "$H" seed codex' >/dev/null || fail "N=$n: cannot create the key directory"
  rm -rf "$root/$key/seed"
  old=$(( $(date +%s) - 60 * 86400 ))
  stamp=$(TZ=UTC0 date -d "@$old" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -r "$old" +%Y%m%d%H%M.%S)
  : > "$FB/docker.objects"
  i=1
  while [ "$i" -le "$n" ]; do
    mkdir -p "$root/$key/live-$i/tmp" "$root/$key/orphan-$i/tmp" "$H/data/live-$i" "$H/data/done-$i/node_modules/p" \
      "$H/data/done-$i/app/.venv/lib" "$H/data/done-$i/app/.next"
    printf 'brief\n' > "$H/data/live-$i/brief.md"
    printf 'worktree=/x\nscratch=%s\n' "$root/$key/live-$i" > "$H/state/live-$i.meta"
    printf 'brief\n' > "$H/data/done-$i/brief.md"
    printf 'report\n' > "$H/data/done-$i/report.md"
    printf 'x' > "$H/data/done-$i/node_modules/p/i.js"
    printf 'container\tc%s\tfirstmate.task=%s/live-%s\n' "$i" "$key" "$i" >> "$FB/docker.objects"
    i=$((i + 1))
  done
  chmod -R go-w "$root"
  chmod 700 "$root" "$root/$key"
  PER_TASK=3
  TZ=UTC0 find "$H/data" -path "$H/data/done-*" -exec touch -t "$stamp" {} +
  TZ=UTC0 find "$root/$key" -maxdepth 1 -name 'orphan-*' -exec touch -t "$stamp" {} +
  cat > "$FB/docker" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
filter=
for a in "$@"; do case "$a" in label=*) filter=${a#label=} ;; esac; done
case "$1 ${2:-}" in
  "info "*) echo 29.0.0 ;;
  "ps "*) awk -F '\t' -v f="$filter" '$1 == "container" && $3 == f { print $2 }' "$dir/docker.objects" ;;
  "rm "*) for a in "$@"; do case "$a" in rm|-f|-v) ;; *) awk -F '\t' -v id="$a" '$2 != id' "$dir/docker.objects" > "$dir/o" && mv "$dir/o" "$dir/docker.objects" ;; esac; done ;;
esac
exit 0
SH
  chmod +x "$FB/docker"
  export FM_FOOTPRINT_DOCKER="$FB/docker"
}

# one_task_cost <n>: spawn-side creation plus close-time cleanup of one task, in ms.
one_task_cost() {
  local n=$1 t0 t1 out
  t0=$(now_ms)
  lib 'fm_footprint_task_env "$H/config" "$H" new-task codex' >/dev/null || fail "N=$n: scratch creation failed"
  printf 'container\tcnew\tfirstmate.task=%s/new-task\n' "$KEY" >> "$FB/docker.objects"
  out=$(fp task-close new-task "$SHORT/$n/$KEY/new-task" projects/demo)
  t1=$(now_ms)
  assert_contains "$out" "scratch removed" "N=$n: the closing task's scratch must be removed"
  assert_contains "$out" "Docker: 1 labelled object(s) removed" "N=$n: only the closing task's container may be removed"
  [ "$(grep -c . "$FB/docker.objects")" = "$n" ] || fail "N=$n: other tasks' Docker objects must stay"
  [ "$(find "$SHORT/$n/$KEY" -mindepth 1 -maxdepth 1 -name 'live-*' | wc -l | tr -d ' ')" = "$n" ] ||
    fail "N=$n: every live task's scratch area must stay"
  printf '%s\n' $((t1 - t0))
}

COST_5=
test_scale() {  # <n>
  local n=$1 cost t0 t1 out kb preview
  N=$n
  build_home "$n"
  cost=$(one_task_cost "$n")
  [ "$n" != 5 ] || COST_5=$cost
  printf '# scale N=%s: create and close one task %s ms\n' "$n" "$cost"
  if [ -n "$COST_5" ] && [ "$cost" -gt $((COST_5 * 4 + 1000)) ]; then
    fail "N=$n: closing one task took $cost ms against $COST_5 ms at N=5; per-task cost must not grow with fleet size"
  fi
  t0=$(now_ms)
  out=$(fp report --json)
  t1=$(now_ms)
  [ "$(printf '%s' "$out" | jq -r '.disk.scratch.areas')" = $((2 * n)) ] || fail "N=$n: the report must count every scratch area: $out"
  [ "$(printf '%s' "$out" | jq -r '.disk.scratch.areas_without_task')" = "$n" ] || fail "N=$n: the report must count the orphans"
  kb=$(printf '%s' "$out" | jq -r '.disk.records_and_evidence_kb')
  printf '# scale N=%s: report %s ms, data %s KB, scratch %s KB\n' "$n" $((t1 - t0)) "$kb" "$(printf '%s' "$out" | jq -r '.disk.scratch.this_home_kb')"
  t0=$(now_ms)
  fp old-tasks >/dev/null
  t1=$(now_ms)
  [ "$(awk -F '\t' 'NR > 2' "$H/state/footprint-old-tasks.preview" | wc -l | tr -d ' ')" = $((n * PER_TASK)) ] ||
    fail "N=$n: the preview must offer exactly the $((n * PER_TASK)) rebuildable directories"
  awk -F '\t' 'NR > 2 { print $3 }' "$H/state/footprint-old-tasks.preview" | grep -Ev '/(node_modules|\.venv|\.next)$' >/dev/null &&
    fail "N=$n: the preview offered something other than rebuildable directories"
  grep -q 'live-' "$H/state/footprint-old-tasks.preview" && fail "N=$n: a live task's folder was offered"
  preview=$((t1 - t0))
  printf '# scale N=%s: old-folder preview %s ms for %s folders, %s candidates\n' "$n" "$preview" "$((2 * n))" "$((n * PER_TASK))"
  # Linear, not quadratic: the cost per task folder at 1000 may not exceed
  # three times the cost per task folder at 100, plus 2 ms.
  [ "$n" != 100 ] || PREVIEW_PER_100=$((preview * 1000 / 100))
  if [ "$n" = 1000 ] && [ -n "${PREVIEW_PER_100:-}" ] && [ $((preview * 1000 / 1000)) -gt $((PREVIEW_PER_100 * 3 + 2000)) ]; then
    fail "N=1000: the preview cost $((preview / 1000)) ms per task folder against $((PREVIEW_PER_100 / 1000)) ms at N=100; it must grow linearly"
  fi
  t0=$(now_ms)
  out=$(fp sweep)
  t1=$(now_ms)
  assert_contains "$out" "Removed $n orphaned scratch area(s)" "N=$n: the sweep must remove exactly the orphans"
  [ "$(find "$SHORT/$n/$KEY" -mindepth 1 -maxdepth 1 -name 'live-*' | wc -l | tr -d ' ')" = "$n" ] ||
    fail "N=$n: the sweep must keep every live task's scratch area"
  printf '# scale N=%s: daily sweep %s ms removing %s orphans\n' "$n" $((t1 - t0)) "$n"
  pass "at $n tasks: one task's create and close cost stays flat, and report, preview, and sweep give exact results"
}

test_scale_5() { test_scale 5; }
test_scale_100() { test_scale 100; }
test_scale_1000() { test_scale 1000; }

fm_test_run test_scale_5 test_scale_100 test_scale_1000
