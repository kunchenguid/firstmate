#!/usr/bin/env bash
# fm-behavior-shards.sh - duration-balanced behavior-test planning, execution,
# timing refresh, and executed-manifest completeness verification.
#
# Usage:
#   bin/fm-behavior-shards.sh --check <shard-count>
#   bin/fm-behavior-shards.sh --plan <shard-count>
#   bin/fm-behavior-shards.sh --run <shard> <shard-count> <manifest.tsv>
#   bin/fm-behavior-shards.sh --verify <shard-count> <manifest-dir>
#   bin/fm-behavior-shards.sh --record <durations.tsv>
#
# The checked-in duration file defaults to tests/behavior-test-durations.tsv.
# Override it with FM_BEHAVIOR_DURATIONS_FILE for fixture tests only.
# Planning uses deterministic longest-processing-time assignment: descending
# duration, path as the stable secondary key, and lowest shard number for load
# ties. Each shard runs its assigned files serially. CI supplies one isolated
# runner, TMPDIR, and TMUX_TMPDIR per shard.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DURATIONS=${FM_BEHAVIOR_DURATIONS_FILE:-$ROOT/tests/behavior-test-durations.tsv}
TAB=$(printf '\t')
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-behavior-shards.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

usage() {
  sed -n '2,18s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-behavior-shards: %s\n' "$*" >&2
  exit 2
}

validate_positive_integer() {
  local value=$1 label=$2
  case "$value" in
    ''|*[!0-9]*) die "$label must be a positive integer (got '$value')" ;;
  esac
  [ "$value" -gt 0 ] || die "$label must be greater than zero"
}

inventory() {
  find "$ROOT/tests" -maxdepth 1 -type f -name '*.test.sh' -print \
    | sed "s#^$ROOT/##" \
    | LC_ALL=C sort
}

normalize_durations() {
  local normalized=$1
  [ -f "$DURATIONS" ] || die "duration file not found: $DURATIONS"
  if ! awk -F '\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 2 {
      printf "duration row %d must be: <positive-ms><TAB>tests/<name>.test.sh\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    $1 !~ /^[1-9][0-9]*$/ {
      printf "duration row %d has invalid milliseconds: %s\n", NR, $1 > "/dev/stderr"
      bad = 1
      next
    }
    $2 !~ /^tests\/[A-Za-z0-9._-]+\.test\.sh$/ {
      printf "duration row %d has invalid test path: %s\n", NR, $2 > "/dev/stderr"
      bad = 1
      next
    }
    { print $1 "\t" $2 }
    END { exit bad ? 1 : 0 }
  ' "$DURATIONS" > "$normalized"; then
    die "invalid duration file: $DURATIONS"
  fi
  [ -s "$normalized" ] || die "duration file has no test rows: $DURATIONS"
}

validate_inventory() {
  local normalized=$1 inventory_file=$2 paths_file=$3 duplicates
  inventory > "$inventory_file"
  cut -f2 "$normalized" | LC_ALL=C sort > "$paths_file"
  duplicates=$(cut -f2 "$normalized" | LC_ALL=C sort | uniq -d)
  if [ -n "$duplicates" ]; then
    printf 'fm-behavior-shards: duplicate duration paths:\n%s\n' "$duplicates" >&2
    return 1
  fi
  if ! diff -u "$inventory_file" "$paths_file" >&2; then
    printf 'fm-behavior-shards: duration inventory does not exactly match tests/*.test.sh\n' >&2
    return 1
  fi
}

make_plan() {
  local shard_count=$1 destination=$2 normalized inventory_file paths_file
  validate_positive_integer "$shard_count" "shard count"
  normalized="$WORK/durations.tsv"
  inventory_file="$WORK/inventory.txt"
  paths_file="$WORK/duration-paths.txt"
  normalize_durations "$normalized"
  validate_inventory "$normalized" "$inventory_file" "$paths_file" \
    || die "coverage guard failed"

  LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2 "$normalized" \
    | awk -F '\t' -v OFS='\t' -v shard_count="$shard_count" '
      BEGIN {
        for (i = 1; i <= shard_count; i++) load[i] = 0
      }
      {
        target = 1
        for (i = 2; i <= shard_count; i++) {
          if (load[i] < load[target]) target = i
        }
        print target, $1, $2
        load[target] += $1
      }
    ' > "$destination"

  [ "$(wc -l < "$destination" | tr -d ' ')" -eq "$(wc -l < "$inventory_file" | tr -d ' ')" ] \
    || die "planner did not assign every test exactly once"
}

print_plan_summary() {
  local plan=$1 shard_count=$2
  awk -F '\t' -v shard_count="$shard_count" '
    { count[$1]++; load[$1] += $2 }
    END {
      for (i = 1; i <= shard_count; i++) {
        printf "FM_BEHAVIOR_SHARD shard=%d tests=%d estimated_ms=%d\n", i, count[i] + 0, load[i] + 0
      }
    }
  ' "$plan"
}

now_ms() {
  local value
  value=$(date +%s%3N 2>/dev/null || true)
  case "$value" in
    *[!0-9]*|'') printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

run_test() {
  local path=$1 begin_ms end_ms duration rc had_errexit=0
  begin_ms=$(now_ms)
  printf 'FM_BEHAVIOR_TEST_BEGIN %s\n' "$path"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::group::%s\n' "$path"
  fi
  case $- in *e*) had_errexit=1 ;; esac
  set +e
  "$ROOT/$path"
  rc=$?
  if [ "$had_errexit" -eq 1 ]; then
    set -e
  fi
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::endgroup::\n'
  fi
  end_ms=$(now_ms)
  duration=$((end_ms - begin_ms))
  [ "$duration" -gt 0 ] || duration=1
  printf 'FM_BEHAVIOR_TEST_END %s exit=%s duration_ms=%s\n' "$path" "$rc" "$duration"
  RUN_TEST_RC=$rc
  RUN_TEST_DURATION=$duration
}

run_shard() {
  local shard=$1 shard_count=$2 manifest=$3 plan path plan_shard _estimate
  local selected=0 failures=0
  validate_positive_integer "$shard" "shard"
  validate_positive_integer "$shard_count" "shard count"
  [ "$shard" -le "$shard_count" ] || die "shard $shard exceeds shard count $shard_count"
  plan="$WORK/plan.tsv"
  make_plan "$shard_count" "$plan"
  mkdir -p "$(dirname "$manifest")"
  : > "$manifest"
  cd "$ROOT" || die "cannot enter repo root: $ROOT"
  while IFS="$TAB" read -r plan_shard _estimate path; do
    [ "$plan_shard" = "$shard" ] || continue
    selected=$((selected + 1))
    run_test "$path"
    printf '%s\t%s\t%s\t%s\n' "$shard" "$path" "$RUN_TEST_RC" "$RUN_TEST_DURATION" >> "$manifest"
    [ "$RUN_TEST_RC" -eq 0 ] || failures=$((failures + 1))
  done < "$plan"
  [ "$selected" -gt 0 ] || die "shard $shard has no assigned tests"
  printf 'FM_BEHAVIOR_SHARD_RESULT shard=%s/%s tests=%s failed=%s manifest=%s\n' \
    "$shard" "$shard_count" "$selected" "$failures" "$manifest"
  [ "$failures" -eq 0 ]
}

record_durations() {
  local destination=$1 staging path failed=0
  [ -n "$destination" ] || die "--record requires an output path"
  staging="$WORK/recorded.tsv"
  : > "$staging"
  cd "$ROOT" || die "cannot enter repo root: $ROOT"
  while IFS= read -r path; do
    run_test "$path"
    printf '%s\t%s\n' "$RUN_TEST_DURATION" "$path" >> "$staging"
    [ "$RUN_TEST_RC" -eq 0 ] || failed=$((failed + 1))
  done < <(inventory)
  if [ "$failed" -ne 0 ]; then
    printf 'fm-behavior-shards: refusing to publish timings because %s tests failed\n' "$failed" >&2
    return 1
  fi
  mkdir -p "$(dirname "$destination")"
  {
    printf '# Behavior test durations in milliseconds.\n'
    printf '# Refresh with: bin/fm-behavior-shards.sh --record tests/behavior-test-durations.tsv\n'
    printf '# Recorded UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    LC_ALL=C sort -t "$TAB" -k2,2 "$staging"
  } > "$destination.tmp.$$"
  mv "$destination.tmp.$$" "$destination"
  printf 'FM_BEHAVIOR_DURATIONS recorded=%s tests=%s\n' "$destination" "$(wc -l < "$staging" | tr -d ' ')"
}

verify_manifests() {
  local shard_count=$1 manifest_dir=$2 plan all observed expected file file_count shard
  validate_positive_integer "$shard_count" "shard count"
  [ -d "$manifest_dir" ] || die "manifest directory not found: $manifest_dir"
  plan="$WORK/plan.tsv"
  all="$WORK/executed.tsv"
  observed="$WORK/observed.tsv"
  expected="$WORK/expected.tsv"
  make_plan "$shard_count" "$plan"
  : > "$all"

  file_count=$(find "$manifest_dir" -maxdepth 1 -type f -name 'executed-*.tsv' | wc -l | tr -d ' ')
  [ "$file_count" -eq "$shard_count" ] \
    || die "expected $shard_count executed manifests, found $file_count in $manifest_dir"
  shard=1
  while [ "$shard" -le "$shard_count" ]; do
    file="$manifest_dir/executed-$shard.tsv"
    [ -s "$file" ] || die "missing or empty executed manifest for shard $shard: $file"
    if ! awk -F '\t' -v expected_shard="$shard" '
      NF != 4 { printf "invalid manifest row %d in shard %d\n", NR, expected_shard > "/dev/stderr"; bad = 1; next }
      $1 != expected_shard { printf "manifest row %d claims shard %s, expected %d\n", NR, $1, expected_shard > "/dev/stderr"; bad = 1 }
      $2 !~ /^tests\/[A-Za-z0-9._-]+\.test\.sh$/ { printf "invalid executed path at row %d: %s\n", NR, $2 > "/dev/stderr"; bad = 1 }
      $3 !~ /^[0-9]+$/ { printf "invalid exit code at row %d: %s\n", NR, $3 > "/dev/stderr"; bad = 1 }
      $4 !~ /^[0-9]+$/ { printf "invalid duration at row %d: %s\n", NR, $4 > "/dev/stderr"; bad = 1 }
      END { exit bad ? 1 : 0 }
    ' "$file"; then
      die "invalid executed manifest: $file"
    fi
    cat "$file" >> "$all"
    shard=$((shard + 1))
  done

  awk -F '\t' -v OFS='\t' '{ print $1, $3 }' "$plan" | LC_ALL=C sort -t "$TAB" -k1,1n -k2,2 > "$expected"
  awk -F '\t' -v OFS='\t' '{ print $1, $2 }' "$all" | LC_ALL=C sort -t "$TAB" -k1,1n -k2,2 > "$observed"
  if ! diff -u "$expected" "$observed" >&2; then
    die "executed shard union differs from the complete planned test inventory"
  fi
  if ! awk -F '\t' '
    $3 != 0 { printf "failed test: shard=%s path=%s exit=%s duration_ms=%s\n", $1, $2, $3, $4 > "/dev/stderr"; bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$all"; then
    die "one or more behavior tests failed"
  fi
  printf 'FM_BEHAVIOR_COMPLETENESS ok tests=%s shards=%s\n' "$(wc -l < "$all" | tr -d ' ')" "$shard_count"
}

case "${1:-}" in
  --check)
    [ "$#" -eq 2 ] || die "--check requires <shard-count>"
    plan="$WORK/plan.tsv"
    make_plan "$2" "$plan"
    printf 'FM_BEHAVIOR_PLAN ok tests=%s shards=%s\n' "$(wc -l < "$plan" | tr -d ' ')" "$2"
    print_plan_summary "$plan" "$2"
    ;;
  --plan)
    [ "$#" -eq 2 ] || die "--plan requires <shard-count>"
    make_plan "$2" "$WORK/plan.tsv"
    cat "$WORK/plan.tsv"
    ;;
  --run)
    [ "$#" -eq 4 ] || die "--run requires <shard> <shard-count> <manifest.tsv>"
    run_shard "$2" "$3" "$4"
    ;;
  --verify)
    [ "$#" -eq 3 ] || die "--verify requires <shard-count> <manifest-dir>"
    verify_manifests "$2" "$3"
    ;;
  --record)
    [ "$#" -eq 2 ] || die "--record requires <durations.tsv>"
    record_durations "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
