#!/usr/bin/env bash
# Behavior tests for Codex's fresh-directory trust and startup readiness gate.
#
# These tests drive the public fm-spawn.sh interface through a fake tmux pane.
# The fake pane renders the verified Codex trust menu and working row, so the
# tests cover key delivery and readiness without asserting fm-spawn source text.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-trust)

make_codex_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_CODEX_STATE" 2>/dev/null || true)
render() {
  case "$state" in
    dialog)
      printf '  You are in %s\n\n' "$FM_FAKE_PANE_PATH"
      printf '  Do you trust the contents of this directory?\n'
      printf '› 1. Yes, continue\n  2. No, quit\n\n  Press enter to continue\n' ;;
    changed)
      printf '  You are in %s\n\n' "$FM_FAKE_PANE_PATH"
      printf '  Do you trust the contents of this folder?\n'
      printf '› 2. No, quit\n  1. Yes, continue\n' ;;
    unsafe)
      printf '  You are in %s\n\n' "$FM_FAKE_PANE_PATH"
      printf '  Do you trust the contents of this directory?\n'
      printf '› 1. No, quit\n  2. Yes, continue\n' ;;
    working)
      printf '› synthetic launch instructions\n\n• Working (1s • esc to interrupt)\n' ;;
    *)
      printf 'shell starting\n$ \n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{pane_id}"*) printf '%s\n' '%0'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|set-window-option) exit 0 ;;
  kill-window) printf 'kill-window\n' >> "$FM_FAKE_TMUX_CALL_LOG"; exit 0 ;;
  capture-pane) render; exit 0 ;;
  send-keys)
    literal=
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then literal=$arg; break; fi
      previous=$arg
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
      printf 'launched\n' > "$FM_FAKE_CODEX_STATE"
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            case "${FM_FAKE_CODEX_MODE:-success}" in
              success) printf 'dialog\n' > "$FM_FAKE_CODEX_STATE" ;;
              trusted) printf 'working\n' > "$FM_FAKE_CODEX_STATE" ;;
              changed|unsafe) printf '%s\n' "${FM_FAKE_CODEX_MODE}" > "$FM_FAKE_CODEX_STATE" ;;
              persistent) printf 'dialog\n' > "$FM_FAKE_CODEX_STATE" ;;
            esac
            ;;
          dialog)
            [ "${FM_FAKE_CODEX_MODE:-success}" = persistent ] || printf 'working\n' > "$FM_FAKE_CODEX_STATE"
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi codex
  printf '%s\n' "$fakebin"
}

make_codex_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_codex_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise Codex trust startup.

## Firstmate spec
Verify the public spawn gate.
EOF
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/codex.state"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_codex_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_codex_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6 mode=$7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_CODEX_STATE="$case_dir/codex.state" \
    FM_FAKE_CODEX_MODE="$mode" FM_CODEX_READY_POLLS=4 FM_CODEX_POLL_INTERVAL=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness codex --mode no-mistakes --yolo off 2>&1
}

count_bare_enters() {
  grep -c '^send-keys -t [^ ]* Enter$' "$1" || true
}

test_codex_fresh_directory_trust_is_answered_and_processing_is_verified() {
  local id rec out rc
  id="codex-trust-success-$$"
  rec=$(make_codex_spawn_case success "$id")
  read_codex_spawn_record "$rec"
  out=$(run_codex_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" success)
  rc=$?
  expect_code 0 "$rc" "Codex should accept the verified fresh-directory trust prompt"
  assert_contains "$out" "spawned $id harness=codex" "Codex spawn did not report success"
  [ "$(cat "$CASE_DIR/codex.state")" = working ] || fail "Codex spawn reported success before the brief reached the working row"
  [ "$(count_bare_enters "$CASE_DIR/tmux-calls.log")" -eq 2 ] || fail "Codex should receive one launch Enter and one trust Enter"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" kill-window "successful Codex spawn must keep its endpoint"
  pass "fm-spawn: Codex accepts only the verified preselected trust choice and confirms processing"
}

test_codex_changed_or_unsafe_trust_prompt_refuses_without_guessing() {
  local mode id rec out rc
  for mode in changed unsafe; do
    id="codex-trust-$mode-$$"
    rec=$(make_codex_spawn_case "$mode" "$id")
    read_codex_spawn_record "$rec"
    rc=0
    out=$(run_codex_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$mode") || rc=$?
    [ "$rc" -ne 0 ] || fail "Codex $mode trust prompt must refuse the spawn"
    assert_contains "$out" "did not show a verified ready turn for the supplied brief" \
      "Codex $mode refusal lacked its concrete reason"
    assert_not_contains "$out" "spawned $id" "Codex $mode trust prompt reported a successful spawn"
    assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" kill-window "Codex $mode refusal left its endpoint running"
    [ "$(count_bare_enters "$CASE_DIR/tmux-calls.log")" -eq 1 ] || fail "Codex $mode prompt received an unsafe extra Enter"
  done
  pass "fm-spawn: Codex refuses changed and unsafe trust prompts without guessing"
}

test_codex_already_trusted_directory_starts_without_a_trust_answer() {
  local id rec out rc
  id="codex-trust-trusted-$$"
  rec=$(make_codex_spawn_case trusted "$id")
  read_codex_spawn_record "$rec"
  out=$(run_codex_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" trusted)
  rc=$?
  expect_code 0 "$rc" "an already-trusted Codex directory should spawn without a trust prompt"
  assert_contains "$out" "spawned $id harness=codex" "already-trusted Codex spawn did not report success"
  [ "$(count_bare_enters "$CASE_DIR/tmux-calls.log")" -eq 1 ] || fail "an already-trusted Codex pane received an extra Enter"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" kill-window "already-trusted Codex spawn must keep its endpoint"
  pass "fm-spawn: an already-trusted Codex directory reaches its working turn with no trust answer"
}

test_codex_persistent_trust_prompt_refuses_after_one_answer() {
  local id rec out rc
  id="codex-trust-persistent-$$"
  rec=$(make_codex_spawn_case persistent "$id")
  read_codex_spawn_record "$rec"
  rc=0
  out=$(run_codex_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" persistent) || rc=$?
  [ "$rc" -ne 0 ] || fail "a persistent Codex trust prompt must refuse the spawn"
  assert_contains "$out" "did not start processing its brief after the directory-trust choice was accepted" \
    "persistent Codex prompt lacked its readiness failure"
  [ "$(count_bare_enters "$CASE_DIR/tmux-calls.log")" -eq 2 ] || fail "persistent Codex prompt was answered more than once"
  pass "fm-spawn: a persistent Codex trust prompt refuses without looping"
}

test_codex_fresh_directory_trust_is_answered_and_processing_is_verified
test_codex_changed_or_unsafe_trust_prompt_refuses_without_guessing
test_codex_already_trusted_directory_starts_without_a_trust_answer
test_codex_persistent_trust_prompt_refuses_after_one_answer

printf '# all fm-codex-trust tests passed\n'
