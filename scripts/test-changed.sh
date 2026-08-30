#!/bin/bash
# Run the tests related to files changed vs the base branch (+ working tree).
# Usage: test-changed.sh [--dry-run] [explicit files...]
#
# This is the Artemis pre-push Vitest driver: it maps changed files under
# packages/frontend|backend|shared onto that repo's Vitest projects
# (`unit`, `unit-isolated`, `browser`) and `vitest related`. It is not
# Firstmate's behavior-suite runner; that owner is bin/fm-test-run.sh, which
# selects tests/*.test.sh via --all/--family/--changed/--lane.
#
# `vitest related` per package resolves the import graph, so consumer tests run
# too - not just same-name siblings. packages/shared changes also run related in
# frontend+backend; when nothing maps there (consumers import shared's prebuilt
# dist, invisible to the module graph) that package's unit suite runs instead.

set -u
DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true && shift

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo"; exit 1; }
cd "$REPO" || exit

BASE="origin/dev"
git rev-parse --verify -q "$BASE" >/dev/null || BASE="origin/main"
git rev-parse --verify -q "$BASE" >/dev/null || BASE="HEAD"

if [ $# -gt 0 ]; then
  CHANGED="$(printf '%s\n' "$@")"
else
  CHANGED=$( (git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard) | sort -u)
fi

FE_SRC=()
FE_TESTS=()
FE_BROWSER_TESTS=()
BE_SRC=()
BE_TESTS=()
SH_SRC=()
SH_TESTS=()
STRAYS=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  f="${f#"$REPO"/}"
  case "$f" in *.ts|*.tsx|*.js|*.jsx) ;; *) continue ;; esac
  [ -f "$f" ] || continue
  kind="src"
  # Browser-mode files match *.test.* too; classify them first so they are not
  # sent to the happy-dom unit projects, which exclude **/*.browser.test.tsx.
  case "$f" in
    *.browser.test.*|*.browser.spec.*) kind="browser_test" ;;
    *.test.*|*.spec.*|*__tests__*) kind="test" ;;
  esac
  case "$f" in
    packages/frontend/*)
      rel="${f#packages/frontend/}"
      case "$kind" in
        test) FE_TESTS+=("$rel") ;;
        browser_test) FE_BROWSER_TESTS+=("$rel") ;;
        *) FE_SRC+=("$rel") ;;
      esac ;;
    packages/backend/*)
      rel="${f#packages/backend/}"
      if [ "$kind" = "test" ]; then BE_TESTS+=("$rel"); else BE_SRC+=("$rel"); fi ;;
    packages/shared/*)
      if [ "$kind" = "test" ]; then SH_TESTS+=("${f#packages/shared/}"); else SH_SRC+=("$REPO/$f"); fi ;;
    *)
      case "$kind" in test|browser_test) STRAYS+=("$f") ;; esac ;;
  esac
done <<< "$CHANGED"

if [ ${#FE_SRC[@]} -eq 0 ] && [ ${#FE_TESTS[@]} -eq 0 ] && [ ${#FE_BROWSER_TESTS[@]} -eq 0 ] \
  && [ ${#BE_SRC[@]} -eq 0 ] && [ ${#BE_TESTS[@]} -eq 0 ] \
  && [ ${#SH_SRC[@]} -eq 0 ] && [ ${#SH_TESTS[@]} -eq 0 ] && [ ${#STRAYS[@]} -eq 0 ]; then
  echo "No test-runnable changes (frontend/backend/shared .ts/.tsx/.js/.jsx)."
  exit 0
fi

# frontend splits its unit tier into two vitest projects (vitest.isolation.ts
# classifies each file by whether it can share a module registry). A named unit
# test file must be run against both or vitest reports "no test files found" and
# exits 1 whenever that file lives in the isolated tier. Browser-mode files are
# a third project and are excluded from both unit projects, so they must run
# with --project browser or the same discovery failure blocks the push.
# The `related` step stays on `unit` alone: widening its discovery pulls in the
# isolated tier's consumers too, which OOMs node at ~4GB on the store files.
FE_UNIT_PROJECTS=(--project unit --project unit-isolated)

FAIL=0

run() {
  echo "== $*"
  $DRY && return 0
  "$@" || FAIL=1
}

# Returns 99 when vitest reports no related test files, so the caller can fall back.
related_or_fallback() {
  local fallback=$1; shift
  echo "== $*"
  if $DRY; then echo "   (fallback if nothing maps: $fallback)"; return 0; fi
  local out rc
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -qi "no test files found"; then return 99; fi
  [ "$rc" -ne 0 ] && FAIL=1
  return "$rc"
}

if [ ${#FE_SRC[@]} -gt 0 ] || [ ${#SH_SRC[@]} -gt 0 ]; then
  related_or_fallback "pnpm --filter frontend test" \
    pnpm --filter frontend exec vitest related --run --project unit --passWithNoTests \
    ${FE_SRC[@]+"${FE_SRC[@]}"} ${SH_SRC[@]+"${SH_SRC[@]}"}
  if [ $? -eq 99 ]; then
    if [ ${#SH_SRC[@]} -gt 0 ]; then
      echo "-- nothing related in frontend; shared changed -> full frontend unit suite"
      run pnpm --filter frontend test
    else
      echo "-- no tests import the changed frontend files"
    fi
  fi
fi
[ ${#FE_TESTS[@]} -gt 0 ] && run pnpm --filter frontend exec vitest run \
  "${FE_UNIT_PROJECTS[@]}" ${FE_TESTS[@]+"${FE_TESTS[@]}"}
[ ${#FE_BROWSER_TESTS[@]} -gt 0 ] && run pnpm --filter frontend exec vitest run \
  --project browser ${FE_BROWSER_TESTS[@]+"${FE_BROWSER_TESTS[@]}"}

if [ ${#BE_SRC[@]} -gt 0 ] || [ ${#SH_SRC[@]} -gt 0 ]; then
  related_or_fallback "pnpm --filter backend test:unit" \
    pnpm --filter backend exec dotenv -e .env.test -- vitest related --run --passWithNoTests \
    ${BE_SRC[@]+"${BE_SRC[@]}"} ${SH_SRC[@]+"${SH_SRC[@]}"}
  if [ $? -eq 99 ]; then
    if [ ${#SH_SRC[@]} -gt 0 ]; then
      echo "-- nothing related in backend; shared changed -> full backend unit suite"
      run pnpm --filter backend test:unit
    else
      echo "-- no tests import the changed backend files"
    fi
  fi
fi
[ ${#BE_TESTS[@]} -gt 0 ] && run pnpm --filter backend exec dotenv -e .env.test -- vitest run \
  ${BE_TESTS[@]+"${BE_TESTS[@]}"}

# shared runs on frontend's vitest install (its own test script does the same)
if [ ${#SH_SRC[@]} -gt 0 ]; then
  related_or_fallback "pnpm --filter @monalee-engineering/shared test" \
    pnpm --filter @monalee-engineering/shared exec node ../frontend/node_modules/vitest/vitest.mjs related --run --passWithNoTests \
    ${SH_SRC[@]+"${SH_SRC[@]}"}
  if [ $? -eq 99 ]; then
    echo "-- nothing related in shared -> full shared suite"
    run pnpm --filter @monalee-engineering/shared test
  fi
fi
[ ${#SH_TESTS[@]} -gt 0 ] && run pnpm --filter @monalee-engineering/shared test \
  ${SH_TESTS[@]+"${SH_TESTS[@]}"}

if [ ${#STRAYS[@]} -gt 0 ]; then
  echo "NOT RUN (outside frontend/backend/shared, run manually):"
  printf '  %s\n' "${STRAYS[@]}"
fi
exit "$FAIL"
