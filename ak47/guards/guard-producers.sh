#!/usr/bin/env bash
# ak47/guards/guard-producers.sh - the guard on each producer.
#
# Without this the source fix rots and the sweeper becomes load-bearing again.
# Three independent checks, each of which fails on its own:
#
#   static   every file in cleanup-patterns.conf that creates temp state must
#            also contain a cleanup call. A file that makes temp dirs and never
#            removes them is the producer; this is the check that catches a
#            regression the moment it is written.
#   systemic the per-task TMPDIR export in bin/fm-spawn.sh must still be there.
#            That one line is what keeps a leak inside the task's own scratch
#            root, which teardown already removes. If it disappears, every
#            Python and shell test on the box goes back to leaking into /tmp.
#   dynamic  no producer's /tmp count may grow past its census baseline. This is
#            the check that catches a producer nobody has written a static row
#            for yet, and the one that proves the fix actually worked.
#
# Usage: guard-producers.sh [--projects DIR] [--static|--systemic|--dynamic]
#                           [--json]
#   --projects  where the project clones live (default $FM_HOME/projects)
#   --static / --systemic / --dynamic  run only that check (default: all three)
#   --json      machine-readable result
#
# Exit: 0 all checks pass, 1 a check failed, 2 a malformed table.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=../lib/common.sh
. "$AK47_ROOT/lib/common.sh"

PROJECTS=${AK47_PROJECTS:-$FM_HOME/projects}
PATTERNS=$AK47_ROOT/guards/cleanup-patterns.conf
RUN_STATIC=1; RUN_SYSTEMIC=1; RUN_DYNAMIC=1; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --projects) PROJECTS=${2:?--projects needs a directory}; shift 2 ;;
    --static) RUN_SYSTEMIC=0; RUN_DYNAMIC=0; shift ;;
    --systemic) RUN_STATIC=0; RUN_DYNAMIC=0; shift ;;
    --dynamic) RUN_STATIC=0; RUN_SYSTEMIC=0; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "guard-producers.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

fails=0; passes=0; skips=0
declare -a results=()
record() { results+=("$1|$2|$3"); }   # status|check|detail

# ---- static --------------------------------------------------------------------
static_check() {
  [ -r "$PATTERNS" ] || { echo "guard-producers.sh: missing $PATTERNS" >&2; exit 2; }
  local line id file create cleanup path
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r id file create cleanup <<<"$line"
    if [ -z "${id:-}" ] || [ -z "${file:-}" ] || [ -z "${create:-}" ] || [ -z "${cleanup:-}" ]; then
      echo "guard-producers.sh: $PATTERNS: malformed row: $line" >&2
      exit 2
    fi
    path="$PROJECTS/$file"
    if [ ! -f "$path" ]; then
      skips=$((skips + 1))
      record skip "static:$id" "not cloned at $path"
      continue
    fi
    if ! grep -Eq -- "$create" "$path"; then
      skips=$((skips + 1))
      record skip "static:$id" "no temp creation in $file any more"
      continue
    fi
    if grep -Eq -- "$cleanup" "$path"; then
      passes=$((passes + 1))
      record pass "static:$id" "$file creates and cleans up"
    else
      fails=$((fails + 1))
      record fail "static:$id" "$file creates temp state and matches no cleanup pattern ($cleanup)"
    fi
  done <"$PATTERNS"
}

# ---- systemic ------------------------------------------------------------------
# The one line that keeps a leak inside the task's own scratch root. The guard
# checks the checkout it lives in, not the running home, so it also works in CI
# on a branch that has not been deployed yet.
systemic_check() {
  local spawn="$AK47_ROOT/../bin/fm-spawn.sh"
  [ -f "$spawn" ] || spawn="$FM_HOME/bin/fm-spawn.sh"
  if [ ! -f "$spawn" ]; then
    skips=$((skips + 1))
    record skip "systemic:per-task-tmpdir" "no $spawn"
    return
  fi
  if grep -Eq '^[^#]*export TMPDIR=' "$spawn"; then
    passes=$((passes + 1))
    record pass "systemic:per-task-tmpdir" "bin/fm-spawn.sh exports a per-task TMPDIR"
  else
    fails=$((fails + 1))
    record fail "systemic:per-task-tmpdir" "bin/fm-spawn.sh no longer exports TMPDIR; every test suite leaks into /tmp again"
  fi
}

# ---- dynamic -------------------------------------------------------------------
# The census baseline is written by `census.sh --check --write-baseline`. A
# producer that grew past it is a producer whose fix has not landed or has rotted.
dynamic_check() {
  local out rc=0
  out=$("$AK47_ROOT/census.sh" --check 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    passes=$((passes + 1))
    record pass "dynamic:census" "no producer grew past its baseline"
  elif [ "$rc" -eq 1 ]; then
    fails=$((fails + 1))
    record fail "dynamic:census" "$(printf '%s' "$out" | tr '\n' ';' | cut -c1-400)"
  else
    skips=$((skips + 1))
    record skip "dynamic:census" "census could not run (rc=$rc): $(printf '%s' "$out" | head -1)"
  fi
}

[ "$RUN_STATIC" = 1 ] && static_check
[ "$RUN_SYSTEMIC" = 1 ] && systemic_check
[ "$RUN_DYNAMIC" = 1 ] && dynamic_check

if [ "$JSON" = 1 ]; then
  printf '{"pass":%d,"fail":%d,"skip":%d,"results":[' "$passes" "$fails" "$skips"
  first=1
  for r in "${results[@]}"; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"status":"%s","check":"%s","detail":"%s"}' \
      "${r%%|*}" "$(printf '%s' "${r#*|}" | cut -d'|' -f1)" \
      "$(printf '%s' "${r#*|*|}" | sed 's/["\\]/ /g')"
  done
  printf ']}\n'
else
  for r in "${results[@]}"; do
    printf '%-4s %-28s %s\n' "${r%%|*}" "$(printf '%s' "${r#*|}" | cut -d'|' -f1)" "${r#*|*|}"
  done
  printf '\n%d passed, %d failed, %d skipped\n' "$passes" "$fails" "$skips"
fi

[ "$fails" -eq 0 ] || exit 1
exit 0
