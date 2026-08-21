#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
KIMI_HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
# Every spawn that reaches its launch line creates /tmp/fm-<id>/gotmp, which is
# outside TMP_ROOT and so survives the trap unless it is registered. One list
# rather than one slot, because more than one test now spawns successfully.
KIMI_RUNTIME_TASK_TMPS=()
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_kimi_harness() {
  local task_tmp
  for task_tmp in ${KIMI_RUNTIME_TASK_TMPS[@]+"${KIMI_RUNTIME_TASK_TMPS[@]}"}; do
    rm -rf "$task_tmp"
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup_kimi_harness EXIT

# Claim /tmp/fm-<id> for the trap and start it clean. read_spawn_record is the
# single call site, because it is the one helper every spawn case runs in the
# test body itself: make_spawn_case runs in a command substitution, so anything
# it appended to the list would be lost with its subshell.
claim_task_tmp() {  # <task-id>
  KIMI_RUNTIME_TASK_TMPS+=("/tmp/fm-$1")
  rm -rf "/tmp/fm-$1"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    pointer-typed)
      printf 'context: 0%% (0/256k)\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    trust-dialog)
      printf '%s\n' \
        '  Trust this folder?' \
        '  ↑↓ navigate · Enter select · Esc exit' \
        '' \
        '  /tmp/fake-wt' \
        '' \
        '  Project-level MCP servers are disabled until you explicitly choose Trust.' \
        '  Trust starts the listed project MCP targets and remembers this folder.' \
        '' \
        '     Trust this folder' \
        '     Enable project MCP servers. Remembered for this folder.' \
        '' \
        "   ❯ Don't trust" \
        '     Exit Kimi Code. Asked again next launch.'
      ;;
    trust-selected)
      printf '%s\n' \
        '  Trust this folder?' \
        '  ↑↓ navigate · Enter select · Esc exit' \
        '' \
        '  /tmp/fake-wt' \
        '' \
        '  Project-level MCP servers are disabled until you explicitly choose Trust.' \
        '  Trust starts the listed project MCP targets and remembers this folder.' \
        '' \
        '   ❯ Trust this folder' \
        '     Enable project MCP servers. Remembered for this folder.' \
        '' \
        "     Don't trust" \
        '     Exit Kimi Code. Asked again next launch.'
      ;;
    rejected)
      printf 'Exit Kimi Code. Asked again next launch.\n$ \n'
      ;;
    # A broken launch echoing the dialog it already fell out of: two of the
    # three required strings AND a selected-row marker, but no live dialog and
    # no ready signal. Only the full three-string AND keeps a key off this
    # screen - a detector loosened to any one of them would send Up into it.
    trust-chatter)
      printf '%s\n' \
        'kimi: restoring the previous session failed' \
        '  last screen was:' \
        '  Trust this folder?' \
        "   ❯ Don't trust" \
        'kimi: retrying the provider handshake' \
        '$ '
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '3\n' ;;
    ready|delivered) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *' --auto')
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_KIMI_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_KIMI_STATE"
          ;;
      esac
      exit 0
    fi
    # Refuse KEY the way a backend that cannot carry it does. Scoped to the
    # dialog screens so the launch Enter still lands, and capped by
    # FM_FAKE_KIMI_KEY_REFUSE_MAX so a single refusal can stand in for a
    # one-poll transient rather than a missing key.
    maybe_refuse() {  # <key>
      local so_far
      [ "${FM_FAKE_KIMI_KEY_REFUSE:-no}" = "$1" ] || return 1
      case "$state" in trust-dialog|trust-selected) ;; *) return 1 ;; esac
      so_far=$(grep -c "^$1-refused " "$FM_FAKE_KEY_LOG" 2>/dev/null || true)
      [ "${so_far:-0}" -lt "${FM_FAKE_KIMI_KEY_REFUSE_MAX:-99}" ] || return 1
      printf '%s-refused %s\n' "$1" "$state" >> "$FM_FAKE_KEY_LOG"
      echo "error: unsupported key '$1'" >&2
      return 0
    }
    # Log the screen each key landed on, not just the key name, so a test can
    # assert that nothing was sent while a given screen was showing.
    case " $* " in
      *' Up '*)
        maybe_refuse Up && exit 1
        printf 'Up %s\n' "${state:-none}" >> "$FM_FAKE_KEY_LOG"
        case "$state" in
          trust-dialog) printf 'trust-selected\n' > "$FM_FAKE_KIMI_STATE" ;;
        esac
        ;;
      *' Enter '*)
        maybe_refuse Enter && exit 1
        printf 'Enter %s\n' "${state:-none}" >> "$FM_FAKE_KEY_LOG"
        case "$state" in
          launched)
            case "${FM_FAKE_KIMI_TRUST:-no}" in
              yes) printf 'trust-dialog\n' > "$FM_FAKE_KIMI_STATE" ;;
              selected) printf 'trust-selected\n' > "$FM_FAKE_KIMI_STATE" ;;
              chatter) printf 'trust-chatter\n' > "$FM_FAKE_KIMI_STATE" ;;
              *)
                if [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
                  printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
                fi
                ;;
            esac
            ;;
          trust-dialog)
            printf 'rejected\n' > "$FM_FAKE_KIMI_STATE"
            ;;
          trust-selected)
            if [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_KIMI_DELIVERY:-yes}" = yes ]; then
              if [ "${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" = yes ] \
                 && [ ! -f "$FM_FAKE_KIMI_SWALLOWED" ]; then
                : > "$FM_FAKE_KIMI_SWALLOWED"
              else
                printf 'delivered\n' > "$FM_FAKE_KIMI_STATE"
              fi
            else
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" kimi
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  printf 'brief for kimi\n' > "$home/data/$id/brief.md"
  printf 'kimi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/key.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_KIMI_SWALLOWED="$case_dir/kimi.swallowed" \
    FM_FAKE_KIMI_SWALLOW_FIRST="${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" \
    FM_FAKE_KIMI_TRUST="${FM_FAKE_KIMI_TRUST:-no}" \
    FM_FAKE_KIMI_KEY_REFUSE="${FM_FAKE_KIMI_KEY_REFUSE:-no}" \
    FM_FAKE_KIMI_KEY_REFUSE_MAX="${FM_FAKE_KIMI_KEY_REFUSE_MAX:-99}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_KEY_LOG="$case_dir/key.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_KIMI_READY_POLLS="${FM_KIMI_READY_POLLS:-2}" \
    FM_KIMI_DELIVERY_POLLS="${FM_KIMI_DELIVERY_POLLS:-2}" \
    FM_KIMI_POLL_INTERVAL="${FM_KIMI_POLL_INTERVAL:-0}" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kimi --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$1
EOF
  claim_task_tmp "$CASE_ID"
}

test_kimi_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta task_tmp
  id="kimi-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_KIMI_SWALLOW_FIRST=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model kimi-code/k3 --effort high)
  rc=$?
  expect_code 0 "$rc" "verified kimi launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS '$FAKEBIN_DIR/kimi' --model 'kimi-code/k3' --auto" ] \
    || fail "kimi launch did not use the absolute binary, model, and --auto only: $launch"
  assert_not_contains "$launch" "--effort" "kimi launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "turn-ended" "kimi launch embedded a turn-end path"
  assert_not_contains "$launch" "__TURNEND__" "kimi launch retained a turn-end placeholder"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "kimi pointer was not the exact absolute-path-only instruction: $pointer"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=kimi-code/k3' "$meta" "kimi meta lost the requested model"
  assert_grep 'effort=high' "$meta" "kimi meta did not retain the unsupported effort axis"
  assert_grep "tasktmp=$task_tmp" "$meta" "kimi meta did not record its task temp root"
  assert_present "$task_tmp/gotmp" "kimi spawn did not create its Go temp directory"
  assert_grep "export GOTMPDIR=$task_tmp/gotmp" "$CASE_DIR/tmux-calls.log" \
    "kimi spawn did not export its Go temp directory into the pane"
  assert_grep 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$HOME_DIR/.kimi-code/config.toml" \
    "kimi spawn did not install its guarded global hook region"
  assert_grep 'token=' "$WT_DIR/.fm-kimi-turnend" "kimi spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.kimi-turnend-token" "kimi spawn did not record its token"
  pass "fm-spawn: kimi launches, delivers its brief, and registers a guarded turn-end token"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable() {
  local home config original once stripped count
  home="$TMP_ROOT/config-surgery"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  once="$home/once.toml"
  stripped="$home/stripped.toml"
  mkdir -p "$home/.kimi-code"
  cat > "$config" <<'EOF'
# Captain's leading comment stays exactly here.

[ui]
theme = "night" # inline comment
show_usage = true

# Foreign hook with intentionally unusual key ordering.
[[hooks]]
timeout=17
command = "printf foreign"
matcher=""
event = "Stop"

[providers.example]
model = "some/model"
# Final comment and blank line follow.

EOF
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused a realistic config"
  cp "$config" "$once"
  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install failed"
  cmp -s "$once" "$config" || fail "second Kimi hook install changed config bytes"
  count=$(grep -c '^# BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config")
  [ "$count" -eq 1 ] || fail "idempotent install left $count Firstmate regions"

  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed"
  cp "$config" "$stripped"
  cmp -s "$original" "$stripped" \
    || fail "config with the Firstmate region excised was not byte-identical to the original"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "removal left the Firstmate hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "removal left the Firstmate registry"
  pass "Kimi hook install is idempotent and removal restores every foreign config byte"
}

test_kimi_hook_remove_preserves_owned_newline_boundary() {
  local appended config expected home original
  home="$TMP_ROOT/config-owned-newline"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  expected="$home/expected.toml"
  appended="$home/appended.toml"
  mkdir -p "$home/.kimi-code"
  printf 'default_model = "test"' > "$config"
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused config without a final newline"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed without appended config"
  cmp -s "$original" "$config" \
    || fail "pristine removal did not restore the absent final newline byte-identically"

  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install refused config without a final newline"
  printf '[captain]\nenabled = true\n' > "$appended"
  cat "$appended" >> "$config"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal joined config appended after its region"
  {
    cat "$original"
    printf '\n'
    cat "$appended"
  } > "$expected"
  cmp -s "$expected" "$config" \
    || fail "removal did not preserve appended captain config on its own line"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "config with appended captain TOML did not parse after removal"
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    tomllib.load(stream)
PY
  pass "Kimi hook removal preserves owned newline boundaries and pristine bytes"
}

test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config() {
  local missing malformed partial out rc
  missing="$TMP_ROOT/config-missing"
  malformed="$TMP_ROOT/config-malformed"
  partial="$TMP_ROOT/config-partial"
  mkdir -p "$missing/.kimi-code" "$malformed/.kimi-code" "$partial/.kimi-code"

  rc=0
  out=$(HOME="$missing" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi config was accepted"
  assert_contains "$out" "Kimi config is missing" "missing config refusal lacked its concrete reason"
  assert_absent "$missing/.kimi-code/fm-turn-end.sh" "missing config refusal wrote the hook script"

  printf '[broken\n' > "$malformed/.kimi-code/config.toml"
  cp "$malformed/.kimi-code/config.toml" "$malformed/before"
  rc=0
  out=$(HOME="$malformed" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed Kimi config was accepted"
  assert_contains "$out" "malformed TOML" "malformed config refusal lacked its concrete reason"
  cmp -s "$malformed/before" "$malformed/.kimi-code/config.toml" \
    || fail "malformed config refusal changed config bytes"
  assert_absent "$malformed/.kimi-code/fm-turn-end.sh" "malformed config refusal wrote the hook script"

  printf '# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$partial/.kimi-code/config.toml"
  cp "$partial/.kimi-code/config.toml" "$partial/before"
  rc=0
  out=$(HOME="$partial" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "partial Firstmate marker was accepted"
  assert_contains "$out" "partial, duplicated, or altered" "partial marker refusal lacked its concrete reason"
  cmp -s "$partial/before" "$partial/.kimi-code/config.toml" \
    || fail "partial marker refusal changed config bytes"
  pass "Kimi hook install refuses missing, malformed, and surprising config without writing"
}

test_kimi_hook_install_refuses_without_jq() {
  local home config before fakebin out rc
  home="$TMP_ROOT/config-no-jq"
  config="$home/.kimi-code/config.toml"
  before="$home/config-before.toml"
  fakebin=$(fm_fakebin "$home/no-jq")
  mkdir -p "$home/.kimi-code"
  printf '# Captain config\nmodel = "test"\n' > "$config"
  cp "$config" "$before"
  ln -s "$(command -v bash)" "$fakebin/bash"
  ln -s "$(command -v python3)" "$fakebin/python3"

  rc=0
  out=$(HOME="$home" PATH="$fakebin" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi hook install succeeded without jq"
  assert_contains "$out" "jq is required" "missing-jq refusal did not name jq"
  cmp -s "$before" "$config" || fail "missing-jq refusal changed config bytes"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "missing-jq refusal wrote the hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "missing-jq refusal wrote the registry"
  pass "Kimi hook install refuses without jq before any config write"
}

test_kimi_hook_is_silent_and_requires_registered_workspace_token() {
  local id rec out rc hook target token no_token snapshot_before snapshot_after fakebin
  id=kimi-hook-auth-z6
  rec=$(make_spawn_case hook-auth "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before hook authentication checks"
  hook="$HOME_DIR/.kimi-code/fm-turn-end.sh"
  target="$HOME_DIR/state/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")
  assert_present "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token is missing"

  no_token="$CASE_DIR/no-token-workspace"
  mkdir -p "$no_token"
  snapshot_before=$(find "$no_token" -mindepth 1 -print)
  out=$(printf '{"hook_event_name":"Stop","session_id":"ordinary","cwd":"%s","stop_hook_active":false}\n' "$no_token" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook must never block a tokenless session"
  [ -z "$out" ] || fail "Kimi hook printed into a tokenless session: $out"
  snapshot_after=$(find "$no_token" -mindepth 1 -print)
  [ "$snapshot_before" = "$snapshot_after" ] || fail "Kimi hook wrote inside a tokenless workspace"
  assert_absent "$target" "tokenless Kimi hook invocation touched a task marker"

  printf 'token=%s\n' "$token" > "$WT_DIR/.fm-kimi-turnend"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "registered Kimi hook invocation did not exit zero"
  [ -z "$out" ] || fail "registered Kimi hook invocation printed output: $out"
  assert_present "$target" "registered Kimi hook invocation did not touch the turn-end marker"

  rm "$target"
  fakebin=$(fm_fakebin "$CASE_DIR/no-jq")
  ln -s "$(command -v bash)" "$fakebin/bash"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" PATH="$fakebin" "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook without jq must still exit zero"
  [ -z "$out" ] || fail "Kimi hook without jq printed output: $out"
  assert_absent "$target" "Kimi hook without jq touched the turn-end marker"
  pass "Kimi hook stays silent and inert without a Firstmate registry token"
}

test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation() {
  local id rec out rc
  id=kimi-config-refuse-z7
  rec=$(make_spawn_case config-refuse "$id")
  read_spawn_record "$rec"
  printf '[malformed\n' > "$HOME_DIR/.kimi-code/config.toml"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi spawn accepted malformed global config"
  assert_contains "$out" "malformed TOML" "Kimi spawn omitted the concrete config refusal"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "unsafe Kimi config refusal created a tmux container or pane"
  fi
  pass "fm-spawn: unsafe Kimi global config refuses before pane creation"
}

test_kimi_teardown_removes_pointer_and_registry_token() {
  local id rec out rc token
  id=kimi-teardown-z8
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")

  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "Kimi teardown failed"
  assert_absent "$WT_DIR/.fm-kimi-turnend" "Kimi token pointer survived teardown"
  assert_absent "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.kimi-turnend-token" "Kimi token state survived teardown"
  pass "fm-teardown: Kimi task pointer and registry token are removed"
}

test_kimi_falls_back_to_expanded_home_binary() {
  local id rec out rc launch fallback
  id=kimi-fallback-z4
  rec=$(make_spawn_case fallback "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  mkdir -p "$(dirname "$fallback")"
  fm_fake_exit0 "$(dirname "$fallback")" kimi
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi HOME fallback spawn should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS '$fallback' --auto" ] \
    || fail "Kimi fallback did not expand HOME into an absolute executable: $launch"
  pass "fm-spawn: Kimi fallback expands the active HOME"
}

test_kimi_missing_binary_refuses_before_pane_creation() {
  local id rec out rc fallback
  id=kimi-missing-z5
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'kimi'" "missing Kimi diagnostic omitted PATH"
  assert_contains "$out" "fallback '$fallback'" "missing Kimi diagnostic omitted expanded fallback"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "missing Kimi executable created a tmux container or pane"
  fi
  pass "fm-spawn: missing Kimi executable refuses before pane creation"
}

test_kimi_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id=kimi-drop-z2
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed kimi delivery should fail"
  assert_contains "$out" "kimi brief pointer delivery was not confirmed" \
    "unconfirmed kimi delivery lacked a loud diagnostic"
  assert_grep 'failed: kimi brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "unconfirmed kimi delivery did not leave a supervisor-visible failure"
  pass "fm-spawn: kimi treats a silent pointer drop as a failed spawn"
}

test_kimi_readiness_gate_precedes_pointer() {
  local id rec out rc
  id=kimi-not-ready-z3
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "kimi spawn without a ready signal should fail"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "kimi readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent before readiness"
  pass "fm-spawn: kimi never sends the brief pointer before an observable ready signal"
}

test_kimi_accepts_folder_trust_dialog_then_delivers() {
  local id rec out rc keys
  id=kimi-trust-z4-$$
  rec=$(make_spawn_case trust-accept "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_KIMI_TRUST=yes FM_KIMI_READY_POLLS=6 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "kimi spawn should accept the folder-trust dialog and continue"
  assert_contains "$out" "spawned $id harness=kimi" \
    "kimi spawn that saw a trust dialog did not report success"
  keys=$(cat "$CASE_DIR/key.log")
  printf '%s\n' "$keys" | grep -qx 'Up trust-dialog' \
    || fail "the preselected Don't trust row was not advanced with Up: $keys"
  printf '%s\n' "$keys" | grep -qx 'Enter trust-selected' \
    || fail "Enter was not sent while Trust this folder was the selected row: $keys"
  [ -s "$CASE_DIR/pointer.log" ] || fail "brief pointer was not sent after the dialog was accepted"
  pass "fm-spawn: kimi accepts Trust this folder via Up then Enter, then delivers the brief"
}

test_kimi_unrecognized_screen_is_not_treated_as_trust_dialog() {
  local id rec out rc keys
  id=kimi-not-trust-z5
  rec=$(make_spawn_case not-trust "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unrecognized non-ready screen should still fail"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "unrecognized-screen failure lacked the existing loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent without a ready signal"
  keys=$(cat "$CASE_DIR/key.log")
  printf '%s\n' "$keys" | grep -q '^Up ' \
    && fail "an unrecognized screen was advanced with Up as if it were a trust dialog: $keys"
  pass "fm-spawn: an unrecognized screen still fails loudly and is not accepted as trust"
}

# The discriminating case: a broken launch whose chatter quotes `Trust this
# folder?` and `Don't trust` but is not the dialog and never becomes ready. A
# detector loosened to any one of its three required strings would accept this
# screen, send keys into a dead launch, and hide the real failure.
test_kimi_trust_wording_without_the_dialog_is_not_accepted() {
  local id rec out rc keys
  id=kimi-trust-chatter-z6
  rec=$(make_spawn_case trust-chatter "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=chatter run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "chatter quoting the trust dialog should still fail readiness"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "chatter that merely quotes the dialog lost the existing loud diagnostic"
  assert_not_contains "$out" "refused the Up key" \
    "chatter that is not the dialog was blamed on the backend's key support"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent without a ready signal"
  keys=$(cat "$CASE_DIR/key.log")
  printf '%s\n' "$keys" | grep -q '^Up ' \
    && fail "chatter quoting the dialog was advanced with Up: $keys"
  printf '%s\n' "$keys" | grep -q ' trust-chatter$' \
    && fail "a key was sent into a screen that is not the trust dialog: $keys"
  pass "fm-spawn: dialog wording without the whole dialog is neither accepted nor keyed"
}

# A backend that cannot deliver Up must not report the dialog accepted and then
# burn the whole readiness window on the generic error - and it must be asked
# twice, not once per poll, so its own refusal does not fill the spawn output.
test_kimi_backend_that_cannot_send_up_fails_by_name() {
  local id rec out rc attempts
  id=kimi-trust-nokey-z7
  rec=$(make_spawn_case trust-nokey "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=yes FM_FAKE_KIMI_KEY_REFUSE=Up FM_KIMI_READY_POLLS=6 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a backend that cannot select Trust this folder must not report success"
  assert_contains "$out" "failed twice in a row to deliver the Up key" \
    "an undeliverable acceptance key was not named as the cause"
  assert_not_contains "$out" "did not show a verified ready signal" \
    "an undeliverable acceptance key was reported as a plain readiness timeout"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "brief pointer was sent into an unaccepted trust dialog"
  attempts=$(grep -c '^Up-refused ' "$CASE_DIR/key.log" || true)
  [ "$attempts" = 2 ] \
    || fail "the refusing backend was asked for Up $attempts times, not the two that prove a real gap"
  pass "fm-spawn: a backend that cannot deliver Up fails by name after two refusals"
}

# One failed send is a transient (a herdr socket hiccup, a tmux
# display-message race), not a missing key: the next poll must retry it and the
# spawn must still come up, exactly as it did before acceptance could abort.
test_kimi_transient_key_failure_is_retried_not_blamed_on_the_backend() {
  local id rec out rc keys
  id=kimi-trust-flaky-z8
  rec=$(make_spawn_case trust-flaky "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=yes FM_FAKE_KIMI_KEY_REFUSE=Up FM_FAKE_KIMI_KEY_REFUSE_MAX=1 \
    FM_KIMI_READY_POLLS=6 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a single transient key failure should be retried, not fail the spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "a spawn that survived one failed key send did not report success"
  assert_not_contains "$out" "failed twice in a row" \
    "one transient key failure was blamed on the backend's key support"
  keys=$(cat "$CASE_DIR/key.log")
  [ "$(grep -c '^Up-refused ' "$CASE_DIR/key.log" || true)" = 1 ] \
    || fail "the transient was not exercised exactly once: $keys"
  printf '%s\n' "$keys" | grep -qx 'Up trust-dialog' \
    || fail "the retry after a transient never delivered Up: $keys"
  [ -s "$CASE_DIR/pointer.log" ] || fail "brief pointer was not delivered after the retry"
  pass "fm-spawn: one failed acceptance key send is retried and the spawn still comes up"
}

# The accept branch for an already-selected Trust row sends Enter, not Up. The
# diagnostic must name the key that was actually tried.
test_kimi_undeliverable_enter_is_not_reported_as_up() {
  local id rec out rc
  id=kimi-trust-noenter-z9
  rec=$(make_spawn_case trust-noenter "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=selected FM_FAKE_KIMI_KEY_REFUSE=Enter FM_KIMI_READY_POLLS=6 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an undeliverable Enter on a selected Trust row must not report success"
  assert_contains "$out" "failed twice in a row to deliver the Enter key" \
    "the failing key was not the one the diagnostic named"
  assert_not_contains "$out" "deliver the Up key" \
    "an Enter failure was misreported as an Up refusal"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "brief pointer was sent into an unaccepted trust dialog"
  pass "fm-spawn: an undeliverable Enter is named as Enter, not as an Up refusal"
}

test_kimi_detection_uses_ancestry_after_markers() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/opt/kimi/bin/kimi\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "kimi ancestry detection returned '$out'"
  out=$(CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: markerless kimi is detected by ancestry after env-marker precedence"
}

test_kimi_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/kimi/bin/kimi'; exit 0 ;;
  *"args="*) printf '%s\n' 'kimi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from Kimi ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the Kimi harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize Kimi as a live holder"
  pass "fm-lock recognizes Kimi ancestry and live lock holders"
}

test_kimi_busy_signature_is_scoped_to_spinner_lines() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  # These fixtures reproduce the observed spinner shape rather than byte-exact
  # transcriptions. Leading whitespace is deliberately varied; separator whitespace
  # follows the captured contract.
  local phase
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    printf '  %s · Tip: Kimi is working\n│ > │\n' "$phase" > "$capture"
    fm_pane_is_busy fake kimi || fail "Kimi spinner phase $phase was not recognized as busy"
  done
  printf 'ordinary response ending with 🌕\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "a moon outside Kimi's spinner-line shape was misread as busy"
  fi
  printf '🌕 Full moon details\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "moon-led Kimi output without the middot separator was misread as busy"
  fi
  printf '  🌗 · Tip: /plugins: manage plugins ...\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "Kimi's real spinner signature leaked into another harness"
  fi
  printf 'tip: ctrl+c: cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "kimi's independently rotating idle tip was misread as busy"
  fi
  printf 'Ctrl+c:cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Grok's exact busy token leaked into Kimi's harness-scoped matcher"
  fi
  printf 'auto  K2.7 Coding thinking  /some/path\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Kimi's idle thinking-effort status label was misread as busy"
  fi
  pass "busy detection: real Kimi moon-plus-middot captures require its harness while idle labels stay idle"
}

test_watcher_never_classifies_kimi_from_its_spinner() (
  local state="$TMP_ROOT/watch-state" busy_capture='  🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'
  mkdir -p "$state"
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  # Standalone Kimi has no verified semantic busy source, so it classifies
  # unknown - and unknown is never working. Its moon-phase spinner is
  # deliberately not a state source: the approved redesign forbids inventing a
  # Kimi UI signature, and that glyph set is locale- and emoji-font-sensitive.
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch classified a Kimi task busy from its spinner instead of unknown"
  fi
  [ "$(fm_busy_classify tmux fake kimi kimi-watch "$state" "$busy_capture")" = "unknown kimi-unverified" ] \
    || fail "a Kimi task must classify unknown kimi-unverified"
  printf 'window=fake\nharness=codex\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch applied Kimi's spinner to a recorded Codex task"
  fi
  printf 'window=fake\nharness=grok\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "Kimi's spinner classified a recorded Grok task through its isolated fallback"
  fi
  window_is_busy fake 'Ctrl+c:cancel' \
    || fail "Grok's own verified token must still classify a recorded Grok task busy"
  pass "fm-watch classifies Kimi as unknown rather than from its spinner, and Grok's fallback stays isolated"
)

test_kimi_bordered_prompt_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "kimi's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  pass "composer classifier: kimi's existing bordered > shape is already safe without an override"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable
test_kimi_hook_remove_preserves_owned_newline_boundary
test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config
test_kimi_hook_install_refuses_without_jq
test_kimi_launch_then_send_is_verified
test_kimi_hook_is_silent_and_requires_registered_workspace_token
test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation
test_kimi_teardown_removes_pointer_and_registry_token
test_kimi_falls_back_to_expanded_home_binary
test_kimi_missing_binary_refuses_before_pane_creation
test_kimi_unconfirmed_delivery_fails_loudly
test_kimi_readiness_gate_precedes_pointer
test_kimi_accepts_folder_trust_dialog_then_delivers
test_kimi_unrecognized_screen_is_not_treated_as_trust_dialog
test_kimi_trust_wording_without_the_dialog_is_not_accepted
test_kimi_backend_that_cannot_send_up_fails_by_name
test_kimi_transient_key_failure_is_retried_not_blamed_on_the_backend
test_kimi_undeliverable_enter_is_not_reported_as_up
test_kimi_detection_uses_ancestry_after_markers
test_kimi_session_lock_identity
test_kimi_busy_signature_is_scoped_to_spinner_lines
test_watcher_never_classifies_kimi_from_its_spinner
test_kimi_bordered_prompt_needs_no_override
