#!/usr/bin/env bash
# tests/fm-spawn-worker-path.test.sh - worker PATH handoff regressions through
# the real fm-spawn interface and a stateful fake tmux task shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-path)

make_fake_node_install() { # <versioned-bin>
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/node" <<'SH'
#!/bin/sh
case "${1:-}" in
  */npx) printf 'npx-env-node-ok\n' ;;
  '') printf 'node-direct-ok\n' ;;
  *) printf 'node-args-ok:%s\n' "$1" ;;
esac
SH
  cat > "$bin/npx" <<'JS'
#!/usr/bin/env node
// The fake node executable reports this script's path as npx-env-node-ok.
JS
  chmod +x "$bin/node" "$bin/npx"
}

make_fake_tmux() { # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_CWD"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'sh\n'; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_ENDPOINT_EXISTS:-0}" = 1 ]; then
      case "$*" in *'#{window_name}'*) printf 'fm-%s\n' "$FM_FAKE_TASK_ID" ;; esac
    fi
    exit 0
    ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  send-keys)
    shift
    literal=0
    payload=
    enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2; continue ;;
        -l) literal=1; shift; continue ;;
        Enter|C-m) enter=1; shift; continue ;;
        *)
          if [ -z "$payload" ]; then payload=$1; else payload="$payload $1"; fi
          shift
          ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf '%s' "$payload" > "$FM_FAKE_PANE_LAUNCH"
      exit 0
    fi
    case "$payload" in
      'export PATH='*)
        pane_path=$(cat "$FM_FAKE_PANE_PATH_FILE")
        next=$(PANE_PATH="$pane_path" PAYLOAD="$payload" /bin/sh -c '
          PATH=$PANE_PATH
          export PATH
          eval "$PAYLOAD"
          printf "%s" "$PATH"
        ') || exit 1
        printf '%s' "$next" > "$FM_FAKE_PANE_PATH_FILE"
        ;;
    esac
    if [ "$enter" -eq 1 ] && [ -z "$payload" ] && [ -s "$FM_FAKE_PANE_LAUNCH" ]; then
      pane_path=$(cat "$FM_FAKE_PANE_PATH_FILE")
      launch=$(cat "$FM_FAKE_PANE_LAUNCH")
      env -i HOME="$FM_FAKE_PANE_HOME" PATH="$pane_path" /bin/sh -c "$launch"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

make_spawn_case() { # <name> [provider-path]
  local name=$1 provider_path=${2:-/usr/bin:/bin:/usr/sbin:/sbin} base home project worktree fakebin id
  base="$TMP_ROOT/$name"
  home="$base/home"
  project="$base/project"
  worktree="$base/worktree"
  fakebin=$(fm_fakebin "$base/controller")
  id="$name-z1"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$base/pane-home"
  printf 'Delivery contract: mode=no-mistakes\n' > "$home/data/$id/brief.md"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  : > "$base/tmux.log"
  : > "$base/pane.launch"
  printf '%s' "$provider_path" > "$base/pane.path"
  make_fake_tmux "$fakebin"
  printf '%s\n' "$base|$home|$project|$worktree|$fakebin|$id"
}

read_spawn_case() {
  IFS='|' read -r CASE_BASE HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR CASE_ID <<EOF_CASE
$1
EOF_CASE
}

run_spawn() { # <caller-path> [extra env NAME=value ...]
  local caller_path=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_CWD="$WORKTREE_DIR" \
    FM_FAKE_PANE_HOME="$CASE_BASE/pane-home" FM_FAKE_TASK_ID="$CASE_ID" FM_FAKE_ENDPOINT_EXISTS=0 \
    FM_FAKE_PANE_PATH_FILE="$CASE_BASE/pane.path" \
    FM_FAKE_PANE_LAUNCH="$CASE_BASE/pane.launch" \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    PATH="$caller_path" \
    "$SPAWN" "$CASE_ID" "$PROJECT_DIR" "sh '$CASE_BASE/probe.sh'" \
      --backend tmux --mode no-mistakes --yolo off 2>&1
}

test_versioned_homebrew_path_reaches_worker_and_env_shebang() {
  local record versioned quoted caller_path out status result
  record=$(make_spawn_case versioned-homebrew)
  read_spawn_case "$record"
  versioned="$CASE_BASE/homebrew/opt/node@24/bin"
  quoted="$CASE_BASE/user path 'quoted' \$(literal);still-data/bin"
  make_fake_node_install "$versioned"
  mkdir -p "$quoted"
  cat > "$quoted/quoted-tool" <<'SH'
#!/bin/sh
printf 'quoted-path-ok\n'
SH
  chmod +x "$quoted/quoted-tool"
  cat > "$CASE_BASE/probe.sh" <<SH
#!/bin/sh
{
  printf 'path=%s\\n' "\$PATH"
  printf 'node=%s\\n' "\$(command -v node 2>/dev/null || printf MISSING)"
  node
  printf 'npx=%s\\n' "\$(command -v npx 2>/dev/null || printf MISSING)"
  npx
  quoted-tool
} > '$CASE_BASE/result'
SH
  chmod +x "$CASE_BASE/probe.sh"

  if PATH='/usr/bin:/bin:/usr/sbin:/sbin' command -v node >/dev/null 2>&1 \
     || PATH='/usr/bin:/bin:/usr/sbin:/sbin' command -v npx >/dev/null 2>&1; then
    fail "the fake provider baseline unexpectedly resolves node or npx"
  fi
  caller_path="$versioned:$quoted:$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  out=$(run_spawn "$caller_path")
  status=$?
  expect_code 0 "$status" "spawn with a versioned Homebrew-style caller PATH should succeed: $out"
  assert_contains "$out" "spawned $CASE_ID" "spawn did not report success"
  result=$(cat "$CASE_BASE/result" 2>/dev/null || true)
  assert_contains "$result" "path=$caller_path" "worker did not receive the caller PATH byte-for-byte"
  assert_contains "$result" "node=$versioned/node" "worker did not resolve node from the versioned formula bin"
  assert_contains "$result" "node-direct-ok" "resolved node executable did not run"
  assert_contains "$result" "npx=$versioned/npx" "worker did not resolve npx from the versioned formula bin"
  assert_contains "$result" "npx-env-node-ok" "the #!/usr/bin/env node npx executable did not run through worker PATH"
  assert_contains "$result" "quoted-path-ok" "a quoted/metacharacter PATH entry was not preserved as data"
  [ ! -e "$CASE_BASE/literal" ] || fail "PATH shell metacharacters executed instead of remaining quoted data"
  pass "fm-spawn: a provider shell missing node receives the exact caller PATH, resolves a versioned formula's node/npx, runs env-node, and preserves quoted entries"
}

test_fresh_spawn_and_relaunch_replace_provider_path_idempotently() {
  local record caller_path out status result
  caller_path="$TMP_ROOT/relaunch-command-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "${caller_path%%:*}"
  record=$(make_spawn_case relaunch-idempotent "/provider/old:/usr/bin:/bin")
  read_spawn_case "$record"
  cat > "$CASE_BASE/probe.sh" <<SH
#!/bin/sh
printf '%s\\n' "\$PATH" > '$CASE_BASE/result'
SH
  chmod +x "$CASE_BASE/probe.sh"

  cat > "$CASE_BASE/fake-harness" <<SH
#!/bin/sh
sh '$CASE_BASE/probe.sh'
SH
  chmod +x "$CASE_BASE/fake-harness"
  out=$(run_spawn "$FAKEBIN_DIR:$caller_path")
  status=$?
  expect_code 0 "$status" "fresh spawn PATH handoff should succeed"
  result=$(cat "$CASE_BASE/result" 2>/dev/null || true)
  [ "$result" = "$FAKEBIN_DIR:$caller_path" ] \
    || fail "fresh spawn did not replace the provider PATH exactly (got '$result')"
  case "$result" in *'/provider/old'*) fail "fresh spawn appended to the provider PATH instead of replacing it" ;; esac

  # Recreate a provider-shaped path before driving the public relaunch path.
  # The task record and worktree come from the successful fresh spawn above.
  printf '/provider/relaunch:/usr/bin:/bin' > "$CASE_BASE/pane.path"
  : > "$CASE_BASE/result"
  : > "$CASE_BASE/pane.launch"
  : > "$CASE_BASE/tmux.log"
  out=$(env \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_CWD="$WORKTREE_DIR" \
    FM_FAKE_PANE_HOME="$CASE_BASE/pane-home" FM_FAKE_TASK_ID="$CASE_ID" FM_FAKE_ENDPOINT_EXISTS=1 FM_FAKE_PANE_PATH_FILE="$CASE_BASE/pane.path" \
    FM_FAKE_PANE_LAUNCH="$CASE_BASE/pane.launch" FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    PATH="$FAKEBIN_DIR:$caller_path" "$SPAWN" "$CASE_ID" --relaunch --harness "sh '$CASE_BASE/fake-harness'" 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch PATH handoff should succeed: $out"
  assert_contains "$out" "spawned $CASE_ID" "relaunch did not report success"
  result=$(cat "$CASE_BASE/result" 2>/dev/null || true)
  [ "$result" = "$FAKEBIN_DIR:$caller_path" ] \
    || fail "relaunch did not replace the provider PATH with the same snapshot (got '$result')"
  case "$result" in
    *'/provider/relaunch'*) fail "relaunch appended to the provider PATH instead of replacing it" ;;
    *"$FAKEBIN_DIR:$FAKEBIN_DIR"*) fail "relaunch duplicated the caller PATH instead of replacing it idempotently" ;;
  esac
  pass "fm-spawn: fresh spawn and public relaunch both replace provider PATH with one deterministic caller snapshot"
}

test_empty_path_refuses_before_helper_resolution() {
  local out status
  out=$(env -i PATH= HOME="${HOME:-/tmp}" /bin/bash "$SPAWN" empty-path-z1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an empty caller PATH must be refused"
  assert_contains "$out" "caller PATH is empty" "empty PATH refusal was not actionable"
  assert_not_contains "$out" "command not found" "empty PATH reached helper resolution before its validation"
  pass "fm-spawn: an empty PATH refuses before helper resolution or task mutation"
}

test_control_byte_path_refuses_before_endpoint_creation() {
  local record caller_path out status
  record=$(make_spawn_case control-byte)
  read_spawn_case "$record"
  cat > "$CASE_BASE/probe.sh" <<SH
#!/bin/sh
: > '$CASE_BASE/result'
SH
  chmod +x "$CASE_BASE/probe.sh"
  caller_path="$FAKEBIN_DIR:/usr/bin:/bin:"$'\n'"$CASE_BASE/injected"
  out=$(run_spawn "$caller_path")
  status=$?
  [ "$status" -ne 0 ] || fail "a control-byte PATH must be refused"
  assert_contains "$out" "caller PATH contains a control byte" "control-byte refusal was not actionable"
  ! grep -q '^new-window ' "$CASE_BASE/tmux.log" \
    || fail "control-byte PATH refusal occurred after a task endpoint was created"
  [ ! -e "$CASE_BASE/result" ] || fail "control-byte PATH reached the worker launch"
  pass "fm-spawn: a control byte in PATH refuses before endpoint creation and never reaches the worker command channel"
}

test_versioned_homebrew_path_reaches_worker_and_env_shebang
test_fresh_spawn_and_relaunch_replace_provider_path_idempotently
test_empty_path_refuses_before_helper_resolution
test_control_byte_path_refuses_before_endpoint_creation

echo "# all fm-spawn worker PATH tests passed"
