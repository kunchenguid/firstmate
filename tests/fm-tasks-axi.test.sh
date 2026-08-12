#!/usr/bin/env bash
# Regression coverage for the home-bound routine tasks-axi entry point.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() { # <name> [tracked-config]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config"
  if [ "${2:-}" = tracked-config ]; then
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  fi
  printf '%s\n' "$home"
}

assert_task_in() { # <path> <id> <message>
  local path=$1 id=$2 message=$3
  [ -f "$path" ] && grep -F -- "$id" "$path" >/dev/null 2>&1 || fail "$message"
}

test_split_primary_home() {
  local home decoy
  home=$(make_home split-primary)
  decoy="$TMP_ROOT/primary-code-root"
  mkdir -p "$decoy/data"
  cp "$ROOT/.tasks.toml" "$decoy/.tasks.toml"
  printf 'repo sentinel\n' > "$decoy/data/backlog.md"

  (cd "$decoy" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" add split-primary-task "Primary split-home task" --kind ship >/dev/null) \
    || fail "split primary routine mutation failed"

  assert_task_in "$home/data/backlog.md" split-primary-task \
    "split primary mutation did not reach the explicit operational home"
  [ "$(cat "$decoy/data/backlog.md")" = "repo sentinel" ] \
    || fail "split primary mutation leaked into the code root"
  [ ! -e "$home/backlog.md" ] || fail "split primary mutation used tasks-axi's cwd fallback"
  pass "tasks-axi routine mutations bind a split primary to its explicit FM_HOME"
}

test_split_secondmate_home() {
  local home decoy
  home=$(make_home split-secondmate tracked-config)
  printf 'sample-secondmate\n' > "$home/.fm-secondmate-home"
  decoy="$TMP_ROOT/secondmate-code-root"
  mkdir -p "$decoy/data"
  cp "$ROOT/.tasks.toml" "$decoy/.tasks.toml"
  printf 'repo sentinel\n' > "$decoy/data/backlog.md"

  (cd "$decoy" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" add split-secondmate-task "Secondmate split-home task" --kind ship >/dev/null) \
    || fail "split secondmate routine mutation failed"

  assert_task_in "$home/data/backlog.md" split-secondmate-task \
    "split secondmate mutation did not reach its authoritative home"
  [ "$(cat "$decoy/data/backlog.md")" = "repo sentinel" ] \
    || fail "split secondmate mutation leaked into the code root"
  pass "tasks-axi routine mutations bind a secondmate to its explicit FM_HOME"
}

test_default_home() {
  local home
  home=$(make_home default-home tracked-config)

  (cd "$home" && env -u FM_HOME FM_ROOT_OVERRIDE="$home" \
    "$WRAPPER" add default-home-task "Default-home task" --kind ship >/dev/null) \
    || fail "default-home routine mutation failed"

  assert_task_in "$home/data/backlog.md" default-home-task \
    "default-home mutation did not preserve tracked .tasks.toml behavior"
  [ ! -e "$home/backlog.md" ] || fail "default-home mutation bypassed data/backlog.md"
  pass "tasks-axi routine mutations preserve default-home behavior"
}

test_manual_backend_refuses() {
  local home rc
  home=$(make_home manual-home tracked-config)
  printf 'manual\n' > "$home/config/backlog-backend"

  rc=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$WRAPPER" \
    add refused-task "Must stay manual" --kind ship \
    > "$home/stdout" 2> "$home/stderr" || rc=$?

  [ "$rc" -ne 0 ] || fail "manual backend allowed a routine tasks-axi mutation"
  grep -F 'config/backlog-backend=manual selects manual backlog editing' \
    "$home/stderr" >/dev/null || fail "manual backend refusal was not actionable"
  [ ! -e "$home/data/backlog.md" ] || fail "manual backend created a backlog through tasks-axi"
  pass "config/backlog-backend=manual still prevents routine tasks-axi mutations"
}

test_split_primary_home
test_split_secondmate_home
test_default_home
test_manual_backend_refuses
