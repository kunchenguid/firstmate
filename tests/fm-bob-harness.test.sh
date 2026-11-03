#!/usr/bin/env bash
# Behavior tests for the Bob (IBM Bob CLI) crewmate/scout adapter spawn path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS BOB_SESSION

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-bob-harness)

# A stateful fake tmux for bob's launch-then-send shape: bob chat has no
# positional prompt, so bob launches bare and receives its brief pointer only
# after a readiness gate, then a delivery gate.
make_bob_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_BOB_STATE" 2>/dev/null || true)
# The frame is what bob 2.0.9 draws (captured live with tmux capture-pane -e):
# a `❯` composer between two `─` rules, an SGR 7 cursor cell and the placeholder
# as a 256-colour grey run (38;5;243) when empty, typed text at the default
# foreground, and the mode line below. Bob parks its hidden terminal cursor on
# the last pane row, so #{cursor_y} never names the composer.
fake_rule() { printf '\033[38;5;57m%s\033[39m\n' "$(printf '─%.0s' $(seq 1 60))"; }
fake_composer() {  # <row-content-after-glyph>
  fake_rule
  printf '  \033[1m\033[38;5;57m❯ %b\n' "$1"
  fake_rule
  printf '  \033[38;5;57mAgent\033[38;5;243m Mode\033[38;5;160m (auto-approve)\033[39m\n'
}
fake_screen() {
  case "$state" in
    ready)
      printf 'Logged in as test@example.com\n\n'
      fake_composer '\033[0;7m \033[0m\033[38;5;243m Build Anything, @ for context, / for commands, $ for skills\033[39m'
      ;;
    pointer-typed)
      printf 'Logged in as test@example.com\n\n'
      fake_composer '\033[0mRead the brief and follow it\033[7m \033[0m'
      ;;
    delivered)
      printf 'Read the brief at %s and follow it exactly.\n\n' "$FM_FAKE_BRIEF_REAL"
      fake_composer '\033[0;7m \033[0m\033[38;5;243m Build Anything, @ for context, / for commands, $ for skills\033[39m'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() { printf '38\n'; }
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$FM_FAKE_BOB_STATE.window" ] || cat "$FM_FAKE_BOB_STATE.window"
    exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$FM_FAKE_BOB_STATE.window"
    exit 0 ;;
  kill-window) : > "$FM_FAKE_BOB_STATE.window"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *'chat --auto-approve'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_BOB_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_BOB_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_BOB_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_BOB_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_BOB_DELIVERY:-yes}" = yes ]; then
              printf 'delivered\n' > "$FM_FAKE_BOB_STATE"
            else
              printf 'ready\n' > "$FM_FAKE_BOB_STATE"
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
  fm_fake_exit0 "$fakebin" bob
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_bob_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Bob dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'bob\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/bob.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_BOB_STATE="$case_dir/bob.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_FAKE_BOB_READY="${FM_FAKE_BOB_READY:-yes}" \
    FM_FAKE_BOB_DELIVERY="${FM_FAKE_BOB_DELIVERY:-yes}" \
    FM_BOB_READY_POLLS=3 FM_BOB_DELIVERY_POLLS=3 FM_BOB_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness bob ${SPAWN_FLAGS---mode no-mistakes --yolo off} "$@" 2>&1
}

test_bob_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real wt_real settings trust
  id="bob-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "verified bob launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=bob" "bob spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "bob chat --auto-approve --trust --workspace" "bob launch lost its interactive flags"
  assert_contains "$launch" "env -u BOB_SESSION -u CLAUDECODE" "bob launch did not strip BOB_SESSION and foreign markers"
  assert_not_contains "$launch" "launch-brief" "bob launch carried a brief doorbell as a positional argument"
  assert_not_contains "$launch" "encode launch-brief" "bob launch carried a positional brief"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  # Bob blocks reads outside its workspace, so the pointer names an in-worktree copy.
  [ "$pointer" = "Read the brief at $WT_DIR/.bob/launch-brief.md and follow it exactly." ] \
    || fail "bob pointer was not the exact in-workspace instruction: $pointer"
  cmp -s "$brief_real" "$WT_DIR/.bob/launch-brief.md" \
    || fail "the in-workspace brief copy is missing or differs from the launch brief"
  [ -z "$(git -C "$WT_DIR" status --porcelain --untracked-files=all -- .bob)" ] \
    || fail "the bob brief copy or hook file is visible to git"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful bob spawn must never tear down the endpoint it just delivered into"

  settings="$WT_DIR/.bob/settings.json"
  [ -f "$settings" ] || fail "bob spawn did not write the worktree hook settings"
  node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks;
    if(!h.UserPromptSubmit||!h.Stop||!/bob-hook/.test(JSON.stringify(h))) process.exit(1)' "$settings" \
    || fail "bob hook settings lack the UserPromptSubmit/Stop bob-hook pair"

  wt_real=$(cd "$WT_DIR" && pwd -P)
  trust="$HOME_DIR/.bob/trustedFolders.json"
  node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if(t.folders[process.argv[2]]!=="TRUST_FOLDER") process.exit(1)' "$trust" "$wt_real" \
    || fail "bob worktree was not pre-registered in the trust store"
  pass "fm-spawn: bob launches bare, registers trust and hooks, and delivers its brief pointer"
}

test_bob_readiness_gate_precedes_pointer() {
  local id rec out rc
  id="bob-notready-z1-$$"
  rec=$(make_spawn_case notready "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_BOB_READY=no run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob spawn must fail when no ready signal ever appears"
  assert_contains "$out" "bob did not show a verified ready signal" "bob readiness failure was not reported"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "bob pointer was typed before the composer was ready"
  pass "fm-spawn: bob withholds the pointer until the composer is ready"
}

test_bob_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id="bob-nodeliver-z1-$$"
  rec=$(make_spawn_case nodeliver "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_BOB_DELIVERY=no run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob spawn must fail when delivery is never confirmed"
  assert_contains "$out" "bob brief pointer delivery was not confirmed" "bob delivery failure was not reported"
  pass "fm-spawn: bob fails loudly when the brief pointer delivery is unconfirmed"
}

test_bob_tracked_settings_refuses_spawn() {
  local id rec out rc
  id="bob-tracked-z1-$$"
  rec=$(make_spawn_case tracked "$id")
  read_spawn_record "$rec"
  mkdir -p "$PROJ_DIR/.bob"
  printf '{"project":true}\n' >"$PROJ_DIR/.bob/settings.json"
  git -C "$PROJ_DIR" add .bob/settings.json
  git -C "$PROJ_DIR" -c user.name=t -c user.email=t@example.com commit -q -m 'project bob settings'
  git -C "$PROJ_DIR" push -q origin "HEAD:$(git -C "$PROJ_DIR" symbolic-ref --short HEAD)"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob spawn must refuse a worktree that tracks .bob/settings.json"
  assert_contains "$out" "tracks its own .bob/settings.json" "tracked-settings refusal was not reported"
  [ "$(cat "$WT_DIR/.bob/settings.json")" = '{"project":true}' ] \
    || fail "the project's tracked .bob/settings.json was modified"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob was launched despite the refusal"
  pass "fm-spawn: bob refuses to replace a tracked .bob/settings.json"
}

test_bob_secondmate_is_refused() {
  local id rec out rc
  id="bob-second-z1-$$"
  rec=$(make_spawn_case second "$id")
  read_spawn_record "$rec"
  out=$(SPAWN_FLAGS='' run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --secondmate)
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob must be refused as a secondmate"
  assert_contains "$out" "bob is a verified crewmate/scout adapter only" "bob secondmate refusal did not come from the crewmate-only guard"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob secondmate was launched despite the refusal"
  pass "fm-spawn: bob is refused as a secondmate"
}

test_bob_launch_then_send_is_verified
test_bob_readiness_gate_precedes_pointer
test_bob_unconfirmed_delivery_fails_loudly
test_bob_tracked_settings_refuses_spawn
test_bob_secondmate_is_refused
