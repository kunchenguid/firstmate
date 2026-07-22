#!/usr/bin/env bash
# Behavior tests for the traex (TRAE CLI 2.0) crewmate adapter.
#
# The load-bearing risk this suite pins is the NAMING TRAP. On a box that kept the
# TRAE CLI 1.0 install, the names `traecli`, `trae-cli`, `trae-agent`, `coco`, and
# `ta` all resolve to coco 1.0 - a DIFFERENT agent whose supervision facts
# firstmate has never verified. Launching or detecting one of those names would
# leave firstmate supervising the wrong agent while believing it drives TRAE 2.0.
# traex even prints `traecli resume <id>` on its own quit, so the trap is easy to
# walk into by copying the tool's own output.
#
# The tests below therefore assert BOTH directions: traex resolves to traex, and
# the coco-shared signals never do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-traex-harness)

# Detection runs inside whatever harness executes this suite, and layer 1 checks
# CLAUDECODE/PI_CODING_AGENT/GROK_AGENT before the traex marker. Clear them so the
# arm under test is what actually decides, instead of the ambient harness.
detect_with() {  # <env assignments...> -> prints detected harness
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u TRAECLI_SESSION_INBOX \
    "$@" "$HARNESS"
}

test_env_marker_detects_traex() {
  local out
  out=$(detect_with TRAECLI_SESSION_INBOX=/tmp/rollout.artifacts/inbox.d)
  [ "$out" = traex ] || fail "TRAECLI_SESSION_INBOX should detect traex, got '$out'"
  pass "TRAECLI_SESSION_INBOX detects traex"
}

test_traex_marker_beats_codex_fork_env() {
  local out
  # traex is a codex fork and sets CODEX_CI/CODEX_SANDBOX/CODEX_THREAD_ID for its
  # shell children. The traex marker must win, or every traex child reads as codex
  # and firstmate applies codex's facts to a different agent.
  out=$(detect_with TRAECLI_SESSION_INBOX=/tmp/inbox.d CODEX_CI=1 \
    CODEX_SANDBOX=seatbelt CODEX_THREAD_ID=00000000-0000-0000-0000-000000000000)
  [ "$out" = traex ] || fail "traex marker should beat the inherited CODEX_* env, got '$out'"
  pass "traex marker wins over traex's own inherited CODEX_* env"
}

test_coco_shared_session_id_is_not_traex() {
  local out
  # THE TRAP: the coco 1.0 binary carries TRAECLI_SESSION_ID too, so that name
  # cannot tell 2.0 from 1.0 and must never imply traex. Only the INBOX marker
  # (absent from the coco binary entirely) is a valid discriminator.
  out=$(detect_with TRAECLI_SESSION_ID=019f6db1-7ea8-7fd3-ab6b-b5b2edb5965c)
  [ "$out" != traex ] || fail "TRAECLI_SESSION_ID (which coco 1.0 sets too) must not detect traex"
  pass "coco-shared TRAECLI_SESSION_ID does not detect traex"
}

test_coco_process_names_are_not_traex() {
  local fakebin out name
  # A *trae* glob in the ancestry arm would report traex for coco's process names.
  # Pin the exact-match arm by faking each coco name as the parent command.
  fakebin=$(fm_fakebin "$TMP_ROOT/coco-ps")
  for name in traecli trae-cli trae-agent coco ta; do
    cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\n' '/Users/someone/.local/bin/$name'; exit 0 ;;
  *"args="*) printf '%s\n' '$name'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
    chmod +x "$fakebin/ps"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u TRAECLI_SESSION_INBOX \
      PATH="$fakebin:$PATH" "$HARNESS")
    [ "$out" != traex ] || fail "coco 1.0 process name '$name' must not detect as traex"
  done
  pass "coco 1.0 process names (traecli/trae-cli/trae-agent/coco/ta) never detect as traex"
}

test_crew_resolution_accepts_traex() {
  local cfg out
  cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"
  printf 'traex\n' > "$cfg/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$HARNESS" crew)
  [ "$out" = traex ] || fail "config/crew-harness=traex should resolve to traex, got '$out'"
  pass "config/crew-harness=traex resolves to traex"
}

meta_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

# A tmux stub that captures the literal `send-keys -l <cmd>` launch command into
# FM_FAKE_LAUNCH_LOG, so the assertions below run against the command firstmate
# would ACTUALLY execute, not against a re-derivation of it.
make_launch_capturing_fakebin() {
  local dir fakebin
  dir=$1
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Build a spawnable home/project/worktree and echo the pieces.
make_spawn_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_launch_capturing_fakebin "$case_dir/fake")
  id="traex-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_launch_command_is_traex_shaped() {
  local rec case_dir home proj wt fakebin id out status launch launchlog
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  launchlog="$case_dir/launch.log"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" traex --effort high)
  status=$?
  expect_code 0 "$status" "traex spawn should succeed"
  assert_contains "$out" "spawned $id harness=traex" "traex spawn did not report success"

  launch=$(cat "$launchlog")
  case "$launch" in
    'traex '*) : ;;
    *) fail "launch must invoke the traex binary, got: $launch" ;;
  esac
  # THE TRAP, pinned: any of coco 1.0's names here would silently launch a
  # different agent while firstmate believed it was supervising TRAE CLI 2.0.
  case "$launch" in
    *traecli*|*trae-cli*|*trae-agent*|*coco*)
      fail "launch command names a coco 1.0 binary, not traex: $launch" ;;
  esac
  assert_contains "$launch" ' -y ' "traex launch is missing the -y autonomy flag"
  assert_contains "$launch" 'notify=' "traex launch is missing the -c notify= turn-end signal"
  # Match the turn-end BASENAME, not the absolute path: fm-spawn resolves the home
  # through `pwd -P`, so on macOS a /var/... tmpdir legitimately renders as
  # /private/var/... here. The task-scoped filename is the real assertion.
  assert_contains "$launch" "$id.turn-ended" "traex notify does not point at this task's turn-end file"
  assert_contains "$launch" 'model_reasoning_effort="high"' "traex launch did not carry the effort flag"
  [ "$(meta_field "$home/state/$id.meta" harness)" = traex ] || fail "meta did not record harness=traex"
  pass "traex spawn assembles a traex-shaped launch with -y, notify turn-end, and effort"
}

test_spawn_omits_unsupported_max_effort() {
  local rec case_dir home proj wt fakebin id status launch launchlog
  rec=$(make_spawn_case maxeffort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  launchlog="$case_dir/launch.log"
  run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" traex --effort max >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "traex spawn with max effort should still succeed"
  launch=$(cat "$launchlog")
  # traex's own config parser rejects `max` ("unknown variant `max`, expected one
  # of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`"), which aborts the
  # launch outright. Omit it rather than pass a known-bad value.
  assert_not_contains "$launch" 'model_reasoning_effort' "traex must omit the unsupported max effort rather than pass it"
  pass "traex omits max effort (its own config parser rejects the value)"
}

# NOTE: the traex SECONDMATE launch shape (no-notify, codex-style) is verified in
# tests/fm-secondmate-harness.test.sh (test_spawn_traex_secondmate_launches_without_notify),
# which owns the seeded-firstmate-home machinery a --secondmate spawn requires.
# Parity P3 removed the earlier fail-closed refusal that was asserted here.

test_env_marker_detects_traex
test_traex_marker_beats_codex_fork_env
test_coco_shared_session_id_is_not_traex
test_coco_process_names_are_not_traex
test_crew_resolution_accepts_traex
test_spawn_launch_command_is_traex_shaped
test_spawn_omits_unsupported_max_effort
