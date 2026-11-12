#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh refusing a fresh spawn that names no project.
#
# A missing <project-dir> must refuse with a message naming that argument, and
# must refuse before any project is resolved. An empty project value would
# resolve to the caller's cwd, so each case runs from inside an isolated
# firstmate home that is itself a git checkout with a complete brief and fake
# launch tools: a spawn that let the empty value through would go on to spawn
# the home as its project, write the task's launch brief, and name the home in
# its output. FM_SPAWN_NO_GUARD=1 keeps the cases off the live watcher guard.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-missing-project-error)
export FM_BACKEND=tmux

# A firstmate-home-shaped git checkout holding a spawnable brief for <id>.
make_home() {
  local home=$1 id=$2
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  git -C "$home" init -q || fail "could not initialize home fixture"
  git -C "$home" commit -q --allow-empty -m init || fail "could not commit home fixture"
}

# Each row: <label>|<id>|<project arg: none or empty>|<extra flags>
test_missing_project_refuses_before_resolution() {
  local label id proj flags home fakebin out status
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
  while IFS='|' read -r label id proj flags; do
    [ -n "$label" ] || continue
    home="$TMP_ROOT/$id"
    make_home "$home" "$id"
    home=$(cd "$home" && pwd -P)
    set -- "$id"
    [ "$proj" = none ] || set -- "$@" ""
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(cd "$home" && FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
      "$SPAWN" "$@" $flags 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn without a project should exit non-zero"
    printf '%s\n' "$out" | grep -F 'error: missing <project-dir> argument' >/dev/null \
      || fail "$label: refusal did not name the missing project argument: $out"
    printf '%s\n' "$out" | grep -F 'unbound variable' >/dev/null \
      && fail "$label: refusal leaked a raw bash unbound-variable error"
    [ ! -e "$home/data/$id/launch-brief.md" ] \
      || fail "$label: spawn went on to launch the task after the missing project"
    [ ! -e "$home/state/$id.meta" ] \
      || fail "$label: spawn recorded the task after the missing project"
    printf '%s\n' "$out" | grep -F "$home" >/dev/null \
      && fail "$label: spawn resolved the missing project to the firstmate home: $out"
  done <<'ROWS'
ship with no project argument|nope-missing-ship-z1|none|--mode no-mistakes --yolo off
ship with an empty project argument|nope-empty-ship-z2|empty|--mode no-mistakes --yolo off
scout with no project argument|nope-missing-scout-z3|none|--scout
ROWS
  pass "a fresh spawn without a project refuses clearly before resolving any project or state"
}

test_missing_project_refuses_before_resolution
