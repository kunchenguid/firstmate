#!/usr/bin/env bash
# Behavior tests for the muse (Muse Code) crewmate adapter: harness detection,
# spawn launch shape and credential preflight, the secondmate refusal, the
# session-log busy source, and teardown cleanup of the busy binding.
#
# The session-log fixtures below reproduce muse 0.1.0-R708.1's real record
# shapes, including the nested "record":{"kind":"terminal"} cleanup payload that
# is NOT a run terminal. That decoy is the whole reason the fold matches an
# anchored structural prefix instead of searching for "kind":"terminal", so a
# fixture without it would let a naive implementation pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Muse is
# markerless, so an inherited Cursor/Claude/Pi/Grok marker would outrank the
# versioned muse-bin ancestor these detection cases launch. Drop the ambient
# markers so the asserted verdict does not depend on which harness launched
# the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-muse-harness)

# --- session-log fixtures ---------------------------------------------------

# muse_log_metadata <workspace-root>: the first record of every session log,
# which is what binds a log to a task worktree.
muse_log_metadata() {
  printf '{"schema_version":1,"id":"d77de583","stream":{"kind":"session","id":"52f21aea"},"sequence":1,"record_type":"event","durability":"durable","payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s","provider_id":"meta","build":{"sha":"427a430436","semver":"0.1.0"}}}}\n' "$1"
}

muse_log_run_started() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"started","prompt":"launch brief"}}}\n' "$1"
}

muse_log_run_terminal() {  # <run-id> <completed|cancelled>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"terminal","terminal":"%s","reason":null,"turn_duration_ms":8152}}}\n' "$1" "$2"
}

# The decoy: a cleanup-effect payload whose NESTED record is "terminal". It is
# not a run lifecycle terminal and must not settle an open run.
muse_log_cleanup_terminal_decoy() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"reminder_cleanup_effect","run_id":"%s","record":{"kind":"terminal","cleanup_effect_id":1,"outcome":{"kind":"applied"}}}}\n' "$1"
}

muse_log_noise() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"context_block_diagnostic","block_id":"rules_file","message":"mentions kind terminal and kind started in prose"}}}\n' "$1"
}

# write_session_log <sessions-root> <yyyy> <mm> <dd> <uuid> <workspace-root>
# Body records are read from stdin. Writes the log at muse's real depth
# (<root>/YYYY/MM/DD/<uuid>/session.jsonl) and echoes the path.
write_session_log() {
  local root=$1 y=$2 m=$3 d=$4 uuid=$5 ws=$6 dir path
  dir="$root/$y/$m/$d/$uuid"
  mkdir -p "$dir"
  path="$dir/session.jsonl"
  muse_log_metadata "$ws" > "$path"
  cat >> "$path"
  printf '%s\n' "$path"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  show-environment)
    [ "${FM_FAKE_WORKER_META_KEY:-}" = present ] || exit 1
    printf 'META_API_KEY=worker-key\n'
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        if [ "${FM_FAKE_EXECUTE_MUSE_LAUNCH:-}" = 1 ]; then
          case "$arg" in
            *"$FM_FAKE_MUSE_EXECUTABLE"*) (cd "$FM_FAKE_PANE_PATH" && bash -c "$arg") ;;
          esac
        fi
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cp "$(command -v bash)" "$fakebin/muse-bin-test-version"
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_MUSE_VERSIONED" -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/muse"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh no-mistakes
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="muse-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/xdgconfig" "$home/xdgdata"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Muse dispatch.

## Firstmate spec
Verify the Muse harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_muse_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_MUSE_EXECUTABLE="$fakebin/muse" \
    FM_FAKE_MUSE_VERSIONED="$fakebin/muse-bin-test-version" \
    FM_FAKE_HARNESS_PROBE="$HARNESS" \
    FM_FAKE_EXECUTE_MUSE_LAUNCH="${FM_FAKE_EXECUTE_MUSE_LAUNCH:-}" \
    FM_FAKE_HARNESS_RESULT="${FM_FAKE_HARNESS_RESULT:-}" \
    FM_FAKE_WORKER_META_KEY="${FM_TEST_MUSE_WORKER_KEY-present}" \
    META_API_KEY="${FM_TEST_MUSE_KEY-test-key}" \
    XDG_CONFIG_HOME="${FM_TEST_MUSE_CONFIG_HOME-$home/xdgconfig}" \
    XDG_DATA_HOME="${FM_TEST_MUSE_DATA_HOME-$home/xdgdata}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" muse "$@" 2>&1
}

# --- detection --------------------------------------------------------------

# The installed muse launcher execs a VERSION-SUFFIXED binary
# (~/.local/bin/muse-bin-<version>), so the name in the process tree changes on
# every auto-update. Detection must follow a real running process rather than a
# string, so each case launches an actual renamed executable and asks
# fm-harness.sh from a child of it.
#
# The foreign env markers, including Cursor's, are cleared because muse is
# markerless and the marker layer deliberately outranks ancestry: with one
# retained, these cases would assert the marker's verdict instead of the
# ancestry match they exist to pin.
# The command substitution around the probe is load-bearing: a bare `-c <cmd>`
# lets the shell exec the probe in place, which REPLACES the muse-bin-* process
# name the walk is supposed to find. Real muse keeps its TUI process alive and
# runs tools as children, so forcing a fork is what reproduces that shape.
test_detects_versioned_process_ancestor() {
  local dir bin out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  for bin in muse-bin-0.1.0-R708.1 muse-bin-9.9.9-RZZZ.9 muse; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" = muse ] || fail "fm-harness.sh under process '$bin' reported '$out', expected muse"
  done
  pass "muse is detected through any versioned muse-bin ancestor"
}

# The match must be anchored: an unrelated command whose name merely CONTAINS
# muse is a different program and must not be claimed by this adapter.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in musescore amuse notmuse-bin muse-binary muse-bind; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != muse ] || fail "fm-harness.sh misdetected unrelated process '$bin' as muse"
  done
  pass "muse detection does not claim unrelated muse-containing commands"
}

test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id result out status
  rec=$(make_spawn_case inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  result="$case_dir/harness-result"
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    FM_FAKE_EXECUTE_MUSE_LAUNCH=1 FM_FAKE_HARNESS_RESULT="$result" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn from a marked backend should succeed: $out"
  [ -f "$result" ] || fail "the generated muse launch never executed its harness probe"
  [ "$(cat "$result")" = muse ] \
    || fail "muse worker inherited a foreign harness identity: $(cat "$result")"
  pass "muse launch clears foreign harness markers before ancestry detection"
}

# --- spawn ------------------------------------------------------------------

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn should succeed"
  assert_contains "$out" "spawned $id harness=muse" "muse spawn did not report success"

  launch=$(cat "$home/launch.log")
  # --yolo is what makes a crewmate pane viable at all: without it muse holds
  # every tool call for approval and sandboxes the network to proxy-only.
  assert_contains "$launch" ' --yolo ' "muse launch omitted --yolo"
  # The privacy control. Its absence would ship the operator's foreign personal
  # rules to Meta-hosted inference on every crewmate turn.
  assert_contains "$launch" 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on' \
    "muse launch omitted the foreign-personal-context kill"
  # exec-only flag: the interactive TUI exits with "unexpected argument" on it.
  assert_not_contains "$launch" '--no-foreign-personal-context' \
    "muse launch passed the exec-only foreign-context flag to the TUI"
  # The captain accepted muse's self-update risk, so firstmate must not pin it.
  assert_not_contains "$launch" 'MUSE_NO_AUTO_UPDATE' \
    "muse launch pinned auto-update, which the captain declined"
  assert_contains "$launch" "XDG_CONFIG_HOME='$home/xdgconfig'" \
    "muse launch did not forward its non-secret config root"
  assert_contains "$launch" "XDG_DATA_HOME='$home/xdgdata'" \
    "muse launch did not forward its non-secret data root"
  assert_not_contains "$launch" 'META_API_KEY' "muse launch exposed META_API_KEY in worker argv"
  assert_not_contains "$launch" 'test-key' "muse launch exposed the credential value in worker argv"
  assert_contains "$launch" 'encode launch-brief' "muse launch did not deliver the brief positionally"
  assert_grep 'harness=muse' "$home/state/$id.meta" "muse harness was not recorded in meta"
  pass "muse spawn launches with autonomy, privacy control, and a positional brief"
}

test_spawn_maps_effort_and_model() {
  local rec case_dir home proj wt fakebin id launch
  local -a cases=(
    "low|--reasoning-effort 'low'"
    "medium|--reasoning-effort 'medium'"
    "high|--reasoning-effort 'high'"
    "xhigh|--reasoning-effort 'xhigh'"
    "max|--reasoning-effort 'ultra'"
  )
  local entry effort expect
  for entry in "${cases[@]}"; do
    effort=${entry%%|*}
    expect=${entry#*|}
    rec=$(make_spawn_case "effort-$effort")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --model muse-spark-1.2 --effort "$effort" >/dev/null \
      || fail "muse spawn with effort $effort failed"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "$expect" "muse effort $effort did not map to '$expect'"
    assert_contains "$launch" "--model 'muse-spark-1.2'" "muse spawn dropped the model axis"
  done
  # ultra is muse's max-class level and must be reachable ONLY through an
  # explicit max, never as the fallback when no effort was chosen.
  rec=$(make_spawn_case effort-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "muse spawn without an effort axis failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" '--reasoning-effort' "muse spawn invented an effort when none was chosen"
  pass "muse maps the shared effort vocabulary and reaches ultra only via explicit max"
}

# An unauthenticated muse pane does not exit: it sits on an OAuth device-code
# prompt forever, which supervision would read as a wedged worker rather than a
# missing credential. The spawn must refuse before an endpoint exists.
test_spawn_refuses_without_credential() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case no-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$home/xdgconfig/muse"
  out=$(FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "muse spawn succeeded with no credential available"
  assert_contains "$out" "no worker-reachable credential" "muse spawn did not name the missing credential"
  assert_absent "$home/state/$id.meta" "refused muse spawn still published task metadata"
  pass "muse spawn refuses when no credential can reach the provider"
}

test_spawn_refuses_caller_only_environment_credential() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case caller-only-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_TEST_MUSE_KEY='caller-only-secret' FM_TEST_MUSE_WORKER_KEY='' \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "muse spawn accepted a caller-only META_API_KEY"
  assert_contains "$out" "set for fm-spawn but cannot be proven present" \
    "muse spawn did not explain that the caller credential cannot reach the worker"
  assert_contains "$out" "$home/xdgconfig/muse/auth.json" \
    "muse spawn did not name the supported stored credential path"
  assert_absent "$home/launch.log" "caller-only credential refusal created an endpoint"
  pass "muse spawn refuses a META_API_KEY that cannot reach the worker"
}

test_spawn_accepts_stored_credential() {
  local rec case_dir home proj wt fakebin id status
  rec=$(make_spawn_case stored-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$home/xdgconfig/muse"
  printf '{"schema_version":1}\n' > "$home/xdgconfig/muse/auth.json"
  FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off >/dev/null
  status=$?
  expect_code 0 "$status" "muse spawn should accept a stored credential"
  pass "muse spawn accepts a stored credential without META_API_KEY"
}

test_spawn_resolves_relative_xdg_roots() {
  local rec case_dir home proj wt fakebin id caller resolved_caller launch binding out status
  rec=$(make_spawn_case relative-xdg)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  caller="$case_dir/caller"
  mkdir -p "$caller/cfg/muse" "$caller/data"
  resolved_caller=$(cd "$caller" && pwd -P)
  printf '{"schema_version":1}\n' > "$caller/cfg/muse/auth.json"
  out=$(cd "$caller" && FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    FM_TEST_MUSE_CONFIG_HOME=cfg FM_TEST_MUSE_DATA_HOME=data \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn with relative XDG roots should succeed: $out"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "XDG_CONFIG_HOME='$resolved_caller/cfg'" \
    "muse launch did not forward the resolved config root"
  assert_contains "$launch" "XDG_DATA_HOME='$resolved_caller/data'" \
    "muse launch did not forward the resolved data root"
  binding="$home/state/$id.muse-session"
  assert_grep "sessions_root=$resolved_caller/data/muse/sessions" "$binding" \
    "muse busy binding did not use the worker's resolved data root"
  pass "muse resolves relative XDG roots before preflight and launch"
}

# muse has no primary supervision protocol, and its Claude-compatible hook
# dialect rejects the model-reawakening handlers a firstmate primary needs, so a
# secondmate on muse could never arm a supervision cycle.
test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="muse-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$case_dir/muse"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" META_API_KEY=test-key \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" muse --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "muse was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "muse secondmate refusal did not explain the boundary"
  pass "muse is refused as a secondmate harness"
}

test_spawn_writes_busy_binding_and_teardown_removes_it() {
  local rec case_dir home proj wt fakebin id binding prior
  rec=$(make_spawn_case binding)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  prior=$(write_session_log "$case_dir/xdgdata/muse/sessions" 2026 08 05 prior "$wt" </dev/null)
  prior=$(printf '%s\n' "$prior" | sed 's://*:/:g')
  FM_TEST_MUSE_DATA_HOME="$case_dir/xdgdata" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "muse spawn failed"

  binding="$home/state/$id.muse-session"
  assert_present "$binding" "muse spawn did not write the session binding"
  assert_grep "sessions_root=$case_dir/xdgdata/muse/sessions" "$binding" \
    "muse binding did not record the resolved sessions root"
  assert_grep "workspace_root=$wt" "$binding" "muse binding did not record the task worktree"
  assert_grep "prior_log=$prior" "$binding" \
    "muse binding did not exclude the pre-existing session: $(tr '\n' ';' < "$binding")"
  # No busy record is armed for muse: the source is pull-only with no writer, so
  # a seeded busy record could never be settled.
  assert_absent "$home/state/$id.busy-gen" "muse spawn armed a busy record it can never clear"
  printf 'binding_id=retired\nsession_log=%s\n' "$prior" > "$home/state/$id.muse-session-current"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "muse teardown failed"
  assert_absent "$binding" "muse session binding survived teardown"
  assert_absent "$home/state/$id.muse-session-current" "muse session cache survived teardown"
  pass "muse spawn writes a session binding that teardown removes"
}

# --- interrupt --------------------------------------------------------------

# muse RESTORES the interrupted prompt into the composer after Escape, as real
# bright text. Left there, the next steer types onto the end of it and submits
# both as one garbled message, so the interrupt is not complete until the
# composer is cleared.
make_send_case() {  # <name> <harness>
  local name=$1 harness=$2 case_dir home fakebin id
  case_dir="$TMP_ROOT/send-$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  id="send-$name"
  mkdir -p "$home/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'fakepane\n'; exit 0 ;;
  has-session) exit 0 ;;
  list-panes|list-windows) printf 'fm-send:0\n'; exit 0 ;;
  send-keys)
    shift
    printf '%s\n' "$*" >> "$FM_FAKE_KEY_LOG"
    [ "${FM_FAKE_KEY_FAIL:-}" = "$*" ] && exit 1
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-send:0" "endpoint_task_id=$id" "worktree=$case_dir" \
    "project=$case_dir" "harness=$harness" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$case_dir|$home|$fakebin|$id"
}

run_send_key() {  # <home> <fakebin> <id> <key> <keylog>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_FAKE_KEY_LOG="$5" PATH="$2:$PATH" \
    "$ROOT/bin/fm-send.sh" "$3" --key "$4" 2>&1
}

test_muse_escape_aliases_clear_the_composer() {
  local entry name key rec case_dir home fakebin id keylog out status
  for entry in exact:Escape lower:escape short:Esc short-lower:esc; do
    name=${entry%%:*}
    key=${entry#*:}
    rec=$(make_send_case "muse-$name" muse)
    IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
    keylog="$case_dir/keys.log"
    : > "$keylog"
    out=$(run_send_key "$home" "$fakebin" "$id" "$key" "$keylog")
    status=$?
    expect_code 0 "$status" "muse $key send should succeed: $out"
    assert_grep "$key" "$keylog" "$key never reached the muse pane"
    assert_grep 'C-u' "$keylog" "muse $key did not clear the restored composer"
    [ "$(grep -c . "$keylog")" -ge 2 ] || fail "expected both the interrupt and the clear for $key"
    head -1 "$keylog" | grep -q "$key" || fail "the clear was sent before the $key interrupt"
  done
  pass "every accepted muse Escape alias clears the restored composer"
}

test_non_muse_escape_does_not_clear() {
  local rec case_dir home fakebin id keylog
  rec=$(make_send_case codex codex)
  IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
  keylog="$case_dir/keys.log"
  : > "$keylog"
  run_send_key "$home" "$fakebin" "$id" Escape "$keylog" >/dev/null
  assert_grep 'Escape' "$keylog" "Escape never reached the codex pane"
  assert_no_grep 'C-u' "$keylog" "a non-muse interrupt sent a composer clear it does not need"
  pass "the composer clear is scoped to muse and does not touch other adapters"
}

# A silent clear failure would leave the restored prompt in place and corrupt
# the next steer, so the failure has to be loud.
test_failed_clear_is_reported() {
  local rec case_dir home fakebin id keylog out status
  rec=$(make_send_case clearfail muse)
  IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
  keylog="$case_dir/keys.log"
  : > "$keylog"
  out=$(FM_FAKE_KEY_FAIL='-t fm-send:0 C-u' run_send_key "$home" "$fakebin" "$id" Escape "$keylog")
  status=$?
  [ "$status" -ne 0 ] || fail "a failed muse composer clear was reported as success"
  assert_contains "$out" "could not be cleared" "the failed clear did not explain the pane state"
  pass "a failed muse composer clear fails loudly instead of leaving stale input"
}

# --- busy source ------------------------------------------------------------

classify_muse() {  # <state-dir> <id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux fake:0 muse "$2" "$1"
  )
}

run_state() {  # <log>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_muse_run_state "$1"
  )
}

test_run_fold_tracks_open_and_settled_turns() {
  local dir log out
  dir="$TMP_ROOT/fold"
  mkdir -p "$dir"

  log=$(write_session_log "$dir/open" 2026 08 05 aaaa "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_noise run-1)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] || fail "an open run folded to '$out', expected busy"

  log=$(write_session_log "$dir/settled" 2026 08 05 bbbb "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 completed)
EOF
)
  out=$(run_state "$log")
  [ "$out" = settled ] || fail "a completed run folded to '$out', expected settled"

  # An Escape interrupt closes its run with terminal=cancelled, so unlike a
  # Stop-hook adapter this source covers the interrupt path itself.
  log=$(write_session_log "$dir/cancelled" 2026 08 05 cccc "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 cancelled)
EOF
)
  out=$(run_state "$log")
  [ "$out" = settled ] || fail "an interrupted run folded to '$out', expected settled"

  # A second turn reopens the fold after the first settled.
  log=$(write_session_log "$dir/second" 2026 08 05 dddd "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 completed)
$(muse_log_run_started run-2)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] || fail "a reopened second turn folded to '$out', expected busy"

  # A log with no run lifecycle at all (an unauthenticated pane stuck on the
  # sign-in prompt produces exactly this) is not a settled turn.
  log=$(write_session_log "$dir/none" 2026 08 05 eeee "$dir/ws" </dev/null)
  out=$(run_state "$log")
  [ "$out" = none ] || fail "a run-free log folded to '$out', expected none"
  pass "the run fold tracks open, settled, interrupted, reopened, and run-free logs"
}

test_nested_terminal_record_does_not_settle_a_run() {
  local dir log out
  dir="$TMP_ROOT/decoy"
  mkdir -p "$dir"
  log=$(write_session_log "$dir/root" 2026 08 05 ffff "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_cleanup_terminal_decoy run-1)
$(muse_log_noise run-1)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] \
    || fail "a nested cleanup 'terminal' record settled an open run (folded '$out', expected busy)"
  pass "a nested terminal record never settles an in-flight run"
}

test_binding_selects_the_matching_main_log() {
  local dir state id verdict root
  dir="$TMP_ROOT/bind"
  state="$dir/state"
  root="$dir/sessions"
  id=bindtask
  mkdir -p "$state"

  # Another task's log lives in the same root and must never be folded here.
  write_session_log "$root" 2026 08 05 other "$dir/other-ws" >/dev/null <<EOF
$(muse_log_run_started other-run)
EOF

  write_session_log "$root" 2026 08 05 mine "$dir/my-ws" >/dev/null <<EOF
$(muse_log_run_started my-run)
$(muse_log_run_terminal my-run completed)
EOF

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/my-ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  # This task's own log is settled; the OTHER task's open run must not leak in
  # as busy. With the idle half verified, this task's settled log reads idle.
  [ "$verdict" = "idle muse-session-log" ] \
    || fail "binding leaked another workspace's run state: got '$verdict'"

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/other-ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "binding did not fold the workspace it was pointed at: got '$verdict'"
  pass "the session binding folds only the log matching this task's worktree"
}

test_workspace_binding_treats_glob_characters_literally() {
  local dir state id root verdict
  dir="$TMP_ROOT/workspace-literal"
  state="$dir/state"
  root="$dir/sessions"
  id=literal-task
  mkdir -p "$state"

  write_session_log "$root" 2026 08 05 own "$dir/ws[1]" >/dev/null <<EOF
$(muse_log_run_started own-run)
$(muse_log_run_terminal own-run completed)
EOF
  write_session_log "$root" 2026 08 05 decoy "$dir/ws1" >/dev/null <<EOF
$(muse_log_run_started decoy-run)
EOF

  printf 'sessions_root=%s\nworkspace_root=%s\n' \
    "$root" "$dir/ws[1]" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "idle muse-session-log" ] \
    || fail "a bracketed workspace imported another session's busy state: got '$verdict'"
  pass "workspace bindings compare decoded paths literally"
}

test_binding_excludes_preexisting_log_when_mtimes_tie() {
  local dir state id root old current verdict
  dir="$TMP_ROOT/mtime-tie"
  state="$dir/state"
  root="$dir/sessions"
  id=tietask
  mkdir -p "$state"

  old=$(write_session_log "$root" 2026 08 05 aaaa-old "$dir/ws" <<EOF
$(muse_log_run_started old-run)
$(muse_log_run_terminal old-run completed)
EOF
)
  current=$(write_session_log "$root" 2026 08 05 zzzz-current "$dir/ws" <<EOF
$(muse_log_run_started current-run)
EOF
)
  old=$(printf '%s\n' "$old" | sed 's://*:/:g')
  current=$(printf '%s\n' "$current" | sed 's://*:/:g')
  touch -t 202608050101.01 "$old" "$current"
  { [ ! "$old" -nt "$current" ] && [ ! "$current" -nt "$old" ]; } \
    || fail "the session-selection regression does not reproduce equal mtimes"

  printf 'sessions_root=%s\nworkspace_root=%s\nprior_log=%s\n' \
    "$root" "$dir/ws" "$old" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the current open session lost an mtime tie to the prior settled session: got '$verdict'"
  pass "spawn-time exclusions select the current session across equal mtimes"
}

test_session_log_cache_reuses_and_refreshes_binding() {
  local dir state id root old fresh verdict fakebin
  dir="$TMP_ROOT/cache"
  state="$dir/state"
  root="$dir/sessions"
  id=cachetask
  mkdir -p "$state"

  old=$(write_session_log "$root" 2026 08 05 old "$dir/ws" <<EOF
$(muse_log_run_started old-run)
EOF
)
  old=$(printf '%s\n' "$old" | sed 's://*:/:g')
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=incarnation-one\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the initial session did not resolve before caching: got '$verdict'"

  fakebin=$(fm_fakebin "$dir/fake")
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 97
SH
  chmod +x "$fakebin/node"
  verdict=$(PATH="$fakebin:$PATH" classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "a cached session triggered another tree resolution: got '$verdict'"

  muse_log_run_terminal old-run completed >> "$old"
  fresh=$(write_session_log "$root" 2026 08 05 fresh "$dir/ws" <<EOF
$(muse_log_run_started fresh-run)
EOF
)
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=incarnation-two\nprior_log=%s\n' \
    "$root" "$dir/ws" "$old" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "a fresh session did not supersede the prior cached session: got '$verdict'"

  rm -f "$fresh"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "a missing cached session produced '$verdict' instead of unknown"

  write_session_log "$root" 2026 08 05 ambiguous-a "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started ambiguous-a)
EOF
  write_session_log "$root" 2026 08 05 ambiguous-b "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started ambiguous-b)
EOF
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "ambiguous replacement sessions produced '$verdict' instead of unknown"
  pass "the Muse session cache avoids rescans and refreshes safely across incarnations"
}

test_cached_session_revalidates_after_namespace_change() {
  local dir state id root second_log verdict today year month day
  dir="$TMP_ROOT/cache-ambiguity"
  state="$dir/state"
  root="$dir/sessions"
  id=cacheambiguity
  mkdir -p "$state"
  today=$(date '+%Y/%m/%d')
  year=${today%%/*}
  today=${today#*/}
  month=${today%%/*}
  day=${today#*/}

  write_session_log "$root" "$year" "$month" "$day" first "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started first-run)
EOF
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=cache-ambiguity\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the first session did not resolve before the ambiguity check: got '$verdict'"

  second_log="$root/$year/$month/$day/second/session.jsonl"
  mkdir -p "${second_log%/*}"
  : > "$second_log"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "an uninitialized second session changed the resolved verdict to '$verdict'"

  write_session_log "$root" "$year" "$month" "$day" second "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started second-run)
EOF
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "a second concurrent main session left the cached verdict at '$verdict'"
  pass "a changed Muse namespace revalidates cached session uniqueness"
}

# muse's own native sub-agents write independent run lifecycles one directory
# deeper, under subagent/<child-session-id>/. Folding a child's log would report
# the parent busy long after the parent's turn ended.
test_subagent_logs_are_excluded() {
  local dir state id root verdict child
  dir="$TMP_ROOT/subagent"
  state="$dir/state"
  root="$dir/sessions"
  id=subtask
  mkdir -p "$state"

  write_session_log "$root" 2026 08 05 parent "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started parent-run)
$(muse_log_run_terminal parent-run completed)
EOF

  child="$root/2026/08/05/parent/subagent/child-session"
  mkdir -p "$child"
  {
    muse_log_metadata "$dir/ws"
    muse_log_run_started child-run
  } > "$child/session.jsonl"
  # Make the child log strictly newer, so a depth-blind resolver that also
  # ranks by mtime would pick it.
  touch "$child/session.jsonl"

  # Prove the child fixture really is an open run, so the exclusion below is
  # doing work rather than passing on an inert file.
  [ "$(run_state "$child/session.jsonl")" = busy ] \
    || fail "the sub-agent fixture is not an open run, so the exclusion case would be vacuous"

  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=subagent-incarnation\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" != "busy muse-session-log" ] \
    || fail "a sub-agent's open run was folded as the parent task's busy state"
  # And prove the parent log was genuinely resolved, so the non-busy verdict is
  # the exclusion working rather than the binding silently failing.
  [ "$(run_state "$root/2026/08/05/parent/session.jsonl")" = settled ] \
    || fail "the parent fixture did not fold as settled"
  printf 'binding_id=subagent-incarnation\nsession_log=%s\n' \
    "$child/session.jsonl" > "$state/$id.muse-session-current"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" != "busy muse-session-log" ] \
    || fail "a cached sub-agent log was folded as the parent task's busy state"
  pass "sub-agent session logs are excluded from the parent's busy fold"
}

# Every path with no positive proof of an in-flight turn must be unknown, never
# idle: unknown is not promoted to either boolean pole, while a wrong idle would
# report a working crewmate as finished.
test_missing_and_unreadable_bindings_are_unknown_never_idle() {
  local dir state id verdict root
  dir="$TMP_ROOT/unknowns"
  state="$dir/state"
  root="$dir/sessions"
  id=unk
  mkdir -p "$state"

  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "absent binding classified '$verdict'"

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root/missing" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "missing sessions root classified '$verdict'"

  write_session_log "$root" 2026 08 05 nomatch "$dir/somewhere-else" >/dev/null <<EOF
$(muse_log_run_started r1)
EOF
  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "unmatched workspace classified '$verdict'"

  printf 'garbage\n' > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "malformed binding classified '$verdict'"
  pass "every unproven muse binding classifies unknown rather than idle"
}

# The credentialed multi-step smoke proved one real turn stays inside one run
# pair, so a settled log is a finished turn and reads idle with no opt-in. Both
# terminal shapes settle: a completed turn and an interrupted one.
test_settled_log_reads_idle() {
  local dir state id root verdict terminal
  dir="$TMP_ROOT/idle"
  state="$dir/state"
  root="$dir/sessions"
  mkdir -p "$state"

  for terminal in completed cancelled; do
    id="idle-$terminal"
    write_session_log "$root" 2026 08 05 "settled-$terminal" "$dir/ws-$terminal" >/dev/null <<EOF
$(muse_log_run_started r1)
$(muse_log_run_terminal r1 "$terminal")
EOF
    printf 'sessions_root=%s\nworkspace_root=%s\n' \
      "$root" "$dir/ws-$terminal" > "$state/$id.muse-session"

    verdict=$(classify_muse "$state" "$id")
    [ "$verdict" = "idle muse-session-log" ] \
      || fail "a log settled by a '$terminal' terminal classified '$verdict'"
  done
  pass "a settled session log reads idle for both completed and interrupted turns"
}

# muse records nothing, so it must trust no record source. A trusted source with
# no writer would seed a busy record that nothing could ever settle.
test_muse_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness muse
  )
  [ -z "$out" ] || fail "muse trusts record sources it has no writer for: '$out'"
  pass "muse trusts no busy record source"
}

test_detects_versioned_process_ancestor
test_detection_is_anchored
test_spawn_clears_inherited_foreign_harness_markers
test_spawn_launch_shape
test_spawn_maps_effort_and_model
test_spawn_refuses_without_credential
test_spawn_refuses_caller_only_environment_credential
test_spawn_accepts_stored_credential
test_spawn_resolves_relative_xdg_roots
test_spawn_refuses_secondmate
test_spawn_writes_busy_binding_and_teardown_removes_it
test_muse_escape_aliases_clear_the_composer
test_non_muse_escape_does_not_clear
test_failed_clear_is_reported
test_run_fold_tracks_open_and_settled_turns
test_nested_terminal_record_does_not_settle_a_run
test_binding_selects_the_matching_main_log
test_workspace_binding_treats_glob_characters_literally
test_binding_excludes_preexisting_log_when_mtimes_tie
test_session_log_cache_reuses_and_refreshes_binding
test_cached_session_revalidates_after_namespace_change
test_subagent_logs_are_excluded
test_missing_and_unreadable_bindings_are_unknown_never_idle
test_settled_log_reads_idle
test_muse_trusts_no_record_sources
