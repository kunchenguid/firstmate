#!/usr/bin/env bash
# Behavior tests for the codespace delivery mode adapter.
#
# Covers:
#   (a) fm-project-mode.sh parses [codespace]          -> "codespace off"
#   (b) fm-project-mode.sh parses [codespace +yolo]    -> "codespace on"
#   (c) fm-spawn.sh generates check.sh for codespace tasks
#   (d) fm-spawn.sh errors when no Available codespace found
#   (e) fm-spawn.sh errors when >1 Available codespaces found
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE_SCRIPT="$ROOT/bin/fm-project-mode.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codespace-tests.XXXXXX")

# Build a minimal registry file with one project entry and a given mode string.
make_registry() {
  local dir=$1 proj=$2 mode_str=$3
  mkdir -p "$dir"
  printf -- '- %s [%s] - test project (added 2026-06-22)\n' "$proj" "$mode_str" > "$dir/projects.md"
}

# Run fm-project-mode.sh with a temporary registry.
run_mode() {
  local dir=$1 proj=$2
  FM_DATA_OVERRIDE="$dir" "$MODE_SCRIPT" "$proj" 2>/dev/null
}

# ── (a) [codespace] parses to "codespace off" ──────────────────────────────

test_codespace_mode_parses() {
  local reg_dir
  reg_dir="$TMP_ROOT/reg-codespace"
  make_registry "$reg_dir" myproj "codespace"

  local out
  out=$(run_mode "$reg_dir" myproj)
  [ "$out" = "codespace off" ] || fail "codespace mode: expected 'codespace off', got '$out'"
  pass "[codespace] parses to 'codespace off'"
}

# ── (b) [codespace +yolo] parses to "codespace on" ─────────────────────────

test_codespace_yolo_parses() {
  local reg_dir
  reg_dir="$TMP_ROOT/reg-codespace-yolo"
  make_registry "$reg_dir" myproj "codespace +yolo"

  local out
  out=$(run_mode "$reg_dir" myproj)
  [ "$out" = "codespace on" ] || fail "codespace+yolo mode: expected 'codespace on', got '$out'"
  pass "[codespace +yolo] parses to 'codespace on'"
}

# ── Helpers for spawn tests ─────────────────────────────────────────────────

# Create a sandbox for a spawn test. Sets up:
#   $dir/state/            - firstmate state dir (with a fresh watcher beacon)
#   $dir/data/<id>/        - brief directory
#   $dir/fakebin/          - mocked gh, tmux, treehouse, git
#   $dir/projects/<proj>/  - a git repo with an origin remote
# Echoes the sandbox dir.
make_spawn_case() {
  local name=$1 cs_name=${2:-my-codespace} cs_count=${3:-1}
  local dir fakebin proj_dir origin_dir
  dir="$TMP_ROOT/spawn-$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/data/task-cs1" "$dir/mock-data"

  # Fake watcher beacon so fm-guard stays quiet.
  touch "$dir/state/.last-watcher-beat"

  # Bare origin so the project clone has an origin remote.
  origin_dir="$dir/origin.git"
  git init -q --bare "$origin_dir"

  # Project clone.
  proj_dir="$dir/projects/myproj"
  git clone -q "$origin_dir" "$proj_dir" 2>/dev/null || true
  git -C "$proj_dir" remote set-url origin "https://github.com/owner/myproj.git" 2>/dev/null || true

  # Registry with codespace mode and brief.
  printf -- '- myproj [codespace] - test project (added 2026-06-22)\n' > "$dir/data/projects.md"
  printf 'You are a crewmate.\n' > "$dir/data/task-cs1/brief.md"

  # Mock tmux: silently accept all subcommands.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'testsession\n' ;;
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  new-window) exit 0 ;;
  list-windows) printf '\n' ;;
  send-keys) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"

  # Mock gh: handle codespace list, codespace cp, codespace ssh.
  local cs_list_output
  if [ "$cs_count" = "0" ]; then
    cs_list_output=""
  elif [ "$cs_count" = "1" ]; then
    cs_list_output="$cs_name"
  else
    # Two names on separate lines for the >1 case.
    cs_list_output="$(printf '%s\n%s\n' "$cs_name" "${cs_name}-extra")"
  fi

  # Write the expected output into a file so the heredoc doesn't have subshell issues.
  printf '%s\n' "$cs_list_output" > "$dir/mock-data/cs-list-out"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "list" ]; then
  cat "$dir/mock-data/cs-list-out"
  exit 0
fi
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "cp" ]; then
  exit 0
fi
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "ssh" ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"

  # Mock treehouse: not used in codespace path but present for safety.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"

  printf '%s\n' "$dir"
}

# Run fm-spawn.sh in a sandboxed environment.
run_spawn() {
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_PROJECTS_OVERRIDE="$dir/projects" \
  FM_SPAWN_NO_GUARD=1 \
  TMUX=1 \
  PATH="$dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# ── (c) check.sh generated for codespace tasks ─────────────────────────────

test_check_sh_generated() {
  local dir rc out
  dir=$(make_spawn_case "check-gen" "my-codespace" "1")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "check-gen: spawn should succeed (got exit $rc)\noutput: $out"
  [ -f "$dir/state/task-cs1.check.sh" ] || fail "check-gen: state/task-cs1.check.sh not generated"
  grep -q 'gh codespace ssh' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing 'gh codespace ssh'"
  grep -q 'my-codespace' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing codespace name"
  grep -q 'firstmate-state' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing remote state path"
  pass "check.sh generated with codespace polling logic"
}

# ── (d) error when no Available codespace found ────────────────────────────

test_no_codespace_errors() {
  local dir rc out
  dir=$(make_spawn_case "no-cs" "" "0")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "no-cs: spawn should fail when no codespace found"
  printf '%s\n' "$out" | grep -qi 'no Available codespace' \
    || fail "no-cs: error message missing 'no Available codespace'"
  pass "spawn errors when no Available codespace found"
}

# ── (e) error when >1 Available codespaces found ───────────────────────────

test_multiple_codespaces_errors() {
  local dir rc out
  dir=$(make_spawn_case "multi-cs" "cs-one" "2")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "multi-cs: spawn should fail when >1 codespaces found"
  printf '%s\n' "$out" | grep -qiE 'Available codespaces.*expected exactly one|expected exactly one' \
    || fail "multi-cs: error message missing expected-exactly-one wording"
  pass "spawn errors when more than one Available codespace found"
}

test_codespace_mode_parses
test_codespace_yolo_parses
test_check_sh_generated
test_no_codespace_errors
test_multiple_codespaces_errors
