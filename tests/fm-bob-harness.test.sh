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
      tail -n 1 "$FM_FAKE_POINTER_LOG"
      printf '\n'
      fake_composer '\033[0;7m \033[0m\033[38;5;243m Build Anything, @ for context, / for commands, $ for skills\033[39m'
      ;;
    stale-pointer)
      printf 'Brief g1.1.1: read %s and follow it exactly.\n\n' "$FM_FAKE_BRIEF_REAL"
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
  *"#{cursor_flag}"*) printf '%s\n' "${FM_FAKE_BOB_CURSOR:-0}"; exit 0 ;;
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
            case "${FM_FAKE_BOB_DELIVERY:-yes}" in
              yes) printf 'delivered\n' > "$FM_FAKE_BOB_STATE" ;;
              stale) printf 'stale-pointer\n' > "$FM_FAKE_BOB_STATE" ;;
              *) printf 'ready\n' > "$FM_FAKE_BOB_STATE" ;;
            esac
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
  local -a spawn_flags
  read -r -a spawn_flags <<<"${SPAWN_FLAGS---harness bob --mode no-mistakes --yolo off}"
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
    FM_FAKE_BOB_CURSOR="${FM_FAKE_BOB_CURSOR:-0}" \
    FM_BOB_READY_POLLS=3 FM_BOB_DELIVERY_POLLS=3 FM_BOB_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" ${spawn_flags[@]+"${spawn_flags[@]}"} "$@" 2>&1
}

test_bob_launch_then_send_is_verified() {
  local id rec out rc launch pointer gen brief_real wt_real settings trust
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
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  [ "$pointer" = "Brief $gen: read $WT_DIR/.bob/launch-brief.md and follow it exactly." ] \
    || fail "bob pointer was not the exact in-workspace instruction for this launch: $pointer"
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

# A relaunch reuses the pane, so the previous Bob's composer is on screen while
# the new process starts, with the shell's cursor still visible below it.
test_bob_stale_composer_frame_is_not_ready() {
  local id rec out rc
  id="bob-staleframe-z1-$$"
  rec=$(make_spawn_case staleframe "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_BOB_CURSOR=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a composer frame under a visible cursor must not pass the ready gate"
  assert_contains "$out" "bob did not show a verified ready signal" "the stale frame failure was not reported"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "bob pointer was typed into a stale frame"
  pass "fm-spawn: a stale Bob composer under a visible cursor is not ready"
}

# The previous incarnation's pointer in the transcript proves nothing about this
# launch's delivery.
test_bob_stale_pointer_is_not_delivery() {
  local id rec out rc
  id="bob-stalepointer-z1-$$"
  rec=$(make_spawn_case stalepointer "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_BOB_DELIVERY=stale run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a previous launch's pointer must not confirm delivery"
  assert_contains "$out" "bob brief pointer delivery was not confirmed" "the stale pointer failure was not reported"
  pass "fm-spawn: a previous launch's pointer does not confirm delivery"
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

test_bob_tracked_brief_refuses_spawn() {
  local id rec out rc
  id="bob-trackedbrief-z1-$$"
  rec=$(make_spawn_case trackedbrief "$id")
  read_spawn_record "$rec"
  mkdir -p "$PROJ_DIR/.bob"
  printf 'project notes\n' >"$PROJ_DIR/.bob/launch-brief.md"
  git -C "$PROJ_DIR" add .bob/launch-brief.md
  git -C "$PROJ_DIR" -c user.name=t -c user.email=t@example.com commit -q -m 'project bob brief'
  git -C "$PROJ_DIR" push -q origin "HEAD:$(git -C "$PROJ_DIR" symbolic-ref --short HEAD)"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob spawn must refuse a worktree that tracks .bob/launch-brief.md"
  assert_contains "$out" "tracks its own .bob/launch-brief.md" "tracked-brief refusal was not reported"
  [ "$(cat "$WT_DIR/.bob/launch-brief.md")" = 'project notes' ] \
    || fail "the project's tracked .bob/launch-brief.md was modified"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob was launched despite the refusal"
  pass "fm-spawn: bob refuses to replace a tracked .bob/launch-brief.md"
}

test_bob_symlinked_dir_refuses_spawn() {
  local id rec out rc outside
  id="bob-symlink-z1-$$"
  rec=$(make_spawn_case symlink "$id")
  read_spawn_record "$rec"
  outside="$CASE_DIR/outside-bob"
  mkdir -p "$outside"
  ln -s "$outside" "$PROJ_DIR/.bob"
  git -C "$PROJ_DIR" add .bob
  git -C "$PROJ_DIR" -c user.name=t -c user.email=t@example.com commit -q -m 'project links .bob'
  git -C "$PROJ_DIR" push -q origin "HEAD:$(git -C "$PROJ_DIR" symbolic-ref --short HEAD)"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob spawn must refuse a worktree whose .bob is a symlink"
  assert_contains "$out" "has .bob as a symlink" "symlinked-.bob refusal was not reported"
  [ -z "$(ls -A "$outside")" ] || fail "firstmate wrote through the .bob symlink to $outside"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob was launched despite the refusal"
  pass "fm-spawn: bob refuses a .bob symlink instead of writing through it"
}

test_bob_concurrent_trust_registrations_all_persist() {
  local home i n=8 count
  home="$TMP_ROOT/trust-home"
  mkdir -p "$home"
  git init -q "$TMP_ROOT/trust-proj"
  git -C "$TMP_ROOT/trust-proj" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  for i in $(seq 1 "$n"); do
    git -C "$TMP_ROOT/trust-proj" worktree add -q "$TMP_ROOT/trust-wt-$i" -b "trust-$i"
  done
  for i in $(seq 1 "$n"); do
    HOME="$home" "$ROOT/bin/fm-bob-trust.sh" "$TMP_ROOT/trust-wt-$i" "$TMP_ROOT/trust-proj" >/dev/null 2>"$TMP_ROOT/trust-err-$i" &
  done
  wait
  count=$(node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).folders;
    process.stdout.write(String(Object.values(f).filter(v=>v==="TRUST_FOLDER").length))' "$home/.bob/trustedFolders.json")
  [ "$count" = "$n" ] || fail "concurrent trust registrations kept $count of $n entries: $(cat "$TMP_ROOT"/trust-err-* 2>/dev/null)"
  pass "fm-bob-trust: concurrent registrations all persist"
}

# Bob truncates and rewrites its store in place, so a parallel spawn can read it
# empty or half-written. That read must wait for the writer, neither aborting the
# spawn nor replacing the entries the writer is about to put back.
test_bob_trust_waits_out_a_truncating_writer() {
  local dir="$TMP_ROOT/trust-writer" midwrite i=0 store writer rc wt_real
  for midwrite in '' '{"version": 1, "fold'; do
    i=$((i + 1))
    fm_git_worktree "$dir/proj-$i" "$dir/wt-$i" "trust-writer-$i"
    mkdir -p "$dir/home-$i/.bob"
    store="$dir/home-$i/.bob/trustedFolders.json"
    printf '%s' "$midwrite" > "$store"
    (sleep 0.6; printf '{"version":1,"folders":{"/prior":"TRUST_FOLDER"}}\n' > "$store") &
    writer=$!
    HOME="$dir/home-$i" "$ROOT/bin/fm-bob-trust.sh" "$dir/wt-$i" "$dir/proj-$i" >/dev/null 2>"$dir/err-$i"
    rc=$?
    wait "$writer"
    expect_code 0 "$rc" "a store read mid-write must be retried: $(cat "$dir/err-$i")"
    wt_real=$(cd "$dir/wt-$i" && pwd -P)
    node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).folders;
      if(f["/prior"]!=="TRUST_FOLDER"||f[process.argv[2]]!=="TRUST_FOLDER") process.exit(1)' "$store" "$wt_real" \
      || fail "the writer's entry and this worktree's entry must both survive: $(cat "$store")"
  done
  pass "fm-bob-trust: a store read mid-write waits for the writer and keeps its entries"
}

test_bob_trust_refuses_a_store_that_stays_broken() {
  local dir="$TMP_ROOT/trust-broken" store rc=0 out
  fm_git_worktree "$dir/proj" "$dir/wt" trust-broken
  mkdir -p "$dir/home/.bob"
  store="$dir/home/.bob/trustedFolders.json"
  printf '{"version": 1, "fold' > "$store"
  out=$(HOME="$dir/home" "$ROOT/bin/fm-bob-trust.sh" "$dir/wt" "$dir/proj" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a store that never becomes readable must be refused"
  assert_contains "$out" "stayed empty or unparsable" "the broken-store refusal was not reported"
  [ "$(cat "$store")" = '{"version": 1, "fold' ] || fail "a broken store must not be overwritten"
  pass "fm-bob-trust: a store that stays broken is refused and left in place"
}

# The matcher runs on every foreign node process, some holding a whole brief in
# argv, so a miss must not fork per word. Any helper a word could reach logs here.
test_bob_matcher_forks_nothing_on_a_foreign_long_argv() {
  local dir fakebin tool args
  dir="$TMP_ROOT/matcher-cost"
  fakebin=$(fm_fakebin "$dir")
  for tool in basename dirname readlink; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "%s/forks.log"\n' "$tool" "$dir" > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  : > "$dir/forks.log"
  args="node /srv/app.js $(printf 'word %.0s' $(seq 1 1000)) /home/bob/notes /tmp/not-bob/bob.js"
  if PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_bob_process_matches MainThread "$2"' _ \
    "$ROOT/bin/fm-bob-process-lib.sh" "$args"; then
    fail "a foreign node process with a long argv matched Bob"
  fi
  [ ! -s "$dir/forks.log" ] || fail "the Bob matcher forked on a miss: $(sort "$dir/forks.log" | uniq -c)"
  pass "fm_bob_process_matches: a miss on a long foreign argv forks nothing"
}

# A /bob word in a brief gets a foreign argv past the matcher's cheap prefilter, so
# the scan itself must stay linear: a quadratic one takes tens of seconds here.
test_bob_matcher_scan_stays_linear_on_a_foreign_long_argv() {
  local args start
  # shellcheck source=bin/fm-bob-process-lib.sh
  . "$ROOT/bin/fm-bob-process-lib.sh"
  args="node /srv/app.js /opt/refs/bob.md $(printf 'word%d ' $(seq 1 30000))"
  start=$SECONDS
  if fm_bob_process_matches MainThread "$args"; then
    fail "a foreign node process naming a bob file matched Bob"
  fi
  [ $((SECONDS - start)) -lt 5 ] || fail "the Bob matcher took $((SECONDS - start))s on a 30000-word argv"
  pass "fm_bob_process_matches: a miss past the prefilter stays linear in argv length"
}

test_bob_secondmate_is_refused() {
  local id rec out rc
  id="bob-second-z1-$$"
  rec=$(make_spawn_case second "$id")
  read_spawn_record "$rec"
  out=$(SPAWN_FLAGS='--harness bob' run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --secondmate)
  rc=$?
  [ "$rc" -ne 0 ] || fail "bob must be refused as a secondmate"
  assert_contains "$out" "bob is a verified crewmate/scout adapter only" "bob secondmate refusal did not come from the crewmate-only guard"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob secondmate was launched despite the refusal"
  pass "fm-spawn: bob is refused as a secondmate"
}

# The positional harness parser must read bob as a harness, not as a home path.
test_bob_positional_secondmate_is_refused() {
  local id rec out rc
  id="bob-secondpos-z1-$$"
  rec=$(make_spawn_case secondpos "$id")
  read_spawn_record "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  out=$(SPAWN_FLAGS='' run_spawn "$CASE_DIR" "$HOME_DIR" bob "$WT_DIR" "$FAKEBIN_DIR" "$id" --secondmate)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a positional bob must be refused as a secondmate"
  assert_contains "$out" "bob is a verified crewmate/scout adapter only" "positional bob did not reach the crewmate-only guard"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "bob secondmate was launched despite the refusal"
  pass "fm-spawn: a positional bob is refused as a secondmate"
}

test_bob_launch_then_send_is_verified
test_bob_readiness_gate_precedes_pointer
test_bob_stale_composer_frame_is_not_ready
test_bob_stale_pointer_is_not_delivery
test_bob_unconfirmed_delivery_fails_loudly
test_bob_tracked_settings_refuses_spawn
test_bob_tracked_brief_refuses_spawn
test_bob_symlinked_dir_refuses_spawn
test_bob_concurrent_trust_registrations_all_persist
test_bob_trust_waits_out_a_truncating_writer
test_bob_trust_refuses_a_store_that_stays_broken
test_bob_matcher_forks_nothing_on_a_foreign_long_argv
test_bob_matcher_scan_stays_linear_on_a_foreign_long_argv
test_bob_secondmate_is_refused
test_bob_positional_secondmate_is_refused
