#!/usr/bin/env bash
# tests/fm-merge-local.test.sh - bin/fm-merge-local.sh performs the approved
# local-only landing (a clean fast-forward of the project's default branch to
# the crewmate's fm/<id> branch) and, as a durable ship outcome, pushes that
# landing into this home's fleet memory (memval-04 broadening).
#
# These cases drive the REAL fm-merge-local over a real git project and assert:
#   1. a clean ff lands AND remembers "Shipped <id> (<repo>) to local <branch>";
#   2. brain-axi absent is a silent no-op: the merge still lands, exit 0.
# The memory push reuses the existing fm-remember.sh entry point, which owns
# every fail-open guard, so a missing/slow brain-axi can never affect the merge.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# A brain-axi stub that appends each remembered fact to <log>, one per line.
make_recording_brain() {  # <fakebin-dir> <log-path>
  local fb=$1 log=$2
  mkdir -p "$fb"
  cat > "$fb/brain-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = remember ] || exit 0
printf '%s\n' "\${2:-}" >> "$log"
exit 0
SH
  chmod +x "$fb/brain-axi"
}

# Build a home with a git project whose default branch `main` can fast-forward to
# a crewmate branch fm/<id>. Echoes the home dir; the project lives at <home>/proj.
setup_ready_local_task() {  # <name> <id>
  local name=$1 id=$2 home proj
  home="$TMP_ROOT/$name"
  proj="$home/proj"
  mkdir -p "$home/state"
  git init -q -b main "$proj"
  ( cd "$proj" || exit 1
    printf 'v1\n' > file.txt
    git add file.txt
    git commit -qm "initial on main"
    git checkout -q -b "fm/$id"
    printf 'v2\n' > file.txt
    git commit -qam "crewmate change"
    git checkout -q main
  )
  fm_write_meta "$home/state/$id.meta" \
    "window=sess:fm-$id" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$home"
}

run_merge() {  # <home> <id> [extra-path-dir]
  local home=$1 id=$2 extra=${3:-}
  env PATH="${extra:+$extra:}/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$MERGE" "$id" 2>/dev/null
}

test_ff_landing_is_remembered() {
  local home fb brainlog rc
  home=$(setup_ready_local_task landing land-1)
  fb="$home/fakebin"; brainlog="$home/brain.log"
  make_recording_brain "$fb" "$brainlog"

  run_merge "$home" land-1 "$fb"; rc=$?
  expect_code 0 "$rc" "a clean fast-forward landing should succeed"
  [ "$(git -C "$home/proj" rev-parse main)" = "$(git -C "$home/proj" rev-parse fm/land-1)" ] \
    || fail "main was not fast-forwarded to the crewmate branch"
  assert_present "$brainlog" "an approved local landing should push a ship outcome into fleet memory"
  assert_grep "Shipped land-1 (proj) to local main" "$brainlog" \
    "the remembered fact should name the task, the repo, and the local landing"
  pass "fm-merge-local: a clean local landing is remembered as a ship outcome"
}

test_landing_with_brain_absent_is_silent_noop() {
  local home rc out
  home=$(setup_ready_local_task absent land-2)
  # No brain-axi anywhere on PATH: the landing must still complete, exit 0.
  out=$(run_merge "$home" land-2); rc=$?
  expect_code 0 "$rc" "an absent brain-axi must never fail the landing (fail open)"
  [ "$(git -C "$home/proj" rev-parse main)" = "$(git -C "$home/proj" rev-parse fm/land-2)" ] \
    || fail "the landing did not happen with brain-axi absent"
  assert_contains "$out" "merged fm/land-2 into local main" \
    "the merge should still report its landing with brain-axi absent"
  pass "fm-merge-local: with brain-axi absent the remember is a silent no-op, the landing still happens"
}

test_ff_landing_is_remembered
test_landing_with_brain_absent_is_silent_noop
