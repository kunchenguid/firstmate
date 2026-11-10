#!/usr/bin/env bash
# tests/fm-launch-env-forward.test.sh - behavior tests for config/launch-env-forward
# (bin/fm-spawn.sh --help "Launch environment forwarding";
# docs/configuration.md "Launch environment forwarding (config/launch-env-forward)").
#
# Measured 08.09.2026: a variable exported into firstmate's own process (e.g. by
# its launcher script) does not reach a freshly spawned worker on its own,
# because a long-lived backend session or daemon keeps its own environment,
# captured once (tests/fm-backend-tmux-smoke.test.sh demonstrates that gap
# against a real tmux server). fm-spawn.sh therefore writes each named,
# caller-exported value into the private launch file the pane sources, never
# into pane input.
#
# The fake tmux below wraps the shared spawn stub. It logs every send-keys
# payload, keeps a copy of the staged launch file with its modes, and on the
# Enter that submits `. '<launch file>'` runs that exact line in a real pane
# shell (sh, bash, zsh, fish), as a pane would: the spawn waits for the pane to
# unlink the file and would otherwise reclaim it. The raw launch command is a
# probe that records what the worker received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-env-forward)
SECRET=fm-forward-secret-7731
# Quote, dollar, backtick, backslashes (single, doubled, trailing), spaces and
# newlines (embedded and trailing): every byte class the launch file quoting
# must carry unchanged through sh, bash, zsh and fish.
VALUE="$SECRET it's \$HOME \`false\` \"dq\" a\\b c\\\\d"$'\n\nend\\\n'

make_forward_fakebin() {
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$1")
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_TEST_CASE_DIR:?}
if [ "${1:-}" = send-keys ]; then
  printf '%s\n' "$*" >> "$dir/sent.log"
  prev=
  for a in "$@"; do
    if [ "$prev" = -l ]; then
      case "$a" in
        ". '"*"/launch."*".sh'")
          [ "${FM_TEST_SEND_FAIL:-0}" != 1 ] || exit 1
          f=${a#". '"}; f=${f%"'"}
          printf '%s\n' "$f" > "$dir/staged-path"
          cp "$f" "$dir/staged.copy"
          { stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f"; } > "$dir/staged.mode"
          { stat -c '%a' "${f%/*}" 2>/dev/null || stat -f '%Lp' "${f%/*}"; } > "$dir/staged.dirmode"
          printf '%s\n' "$a" > "$dir/pending"
          ;;
      esac
    fi
    prev=$a
  done
  last=${!#}
  # FM_TEST_SOURCE_AT_LITERAL models hc, whose literal send already submits.
  if { [ "$last" = Enter ] || [ "${FM_TEST_SOURCE_AT_LITERAL:-0}" = 1 ]; } &&
    [ -f "$dir/pending" ] && [ "${FM_TEST_PANE:-none}" != none ]; then
    line=$(cat "$dir/pending")
    rm -f "$dir/pending"
    # shellcheck disable=SC2086 # FM_TEST_PANE_ENV is a list of plain assignments.
    (cd "$dir" && env -i HOME="$dir/pane-home" XDG_CONFIG_HOME="$dir/pane-home" \
      XDG_DATA_HOME="$dir/pane-home" ZDOTDIR="$dir/pane-home" ENV= BASH_ENV= TERM=xterm \
      PATH="${FM_TEST_PANE_PATH:-/usr/bin:/bin}" ${FM_TEST_PANE_ENV:-} \
      "$FM_TEST_PANE" -c "$line; echo SHELL-STILL-ALIVE") > "$dir/pane.out" 2>&1
  fi
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_forward_case <name>: fresh home, project, worktree, fakebin and probe.
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID.
make_forward_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  CASE_ID="$1-z1"
  mkdir -p "$CASE_DIR/pane-home"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$CASE_ID" "Exercise launch-env-forward for $CASE_ID."
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  FAKEBIN_DIR=$(make_forward_fakebin "$CASE_DIR/fake")
  cat > "$CASE_DIR/probe.sh" <<'SH'
#!/bin/sh
dir=$1
if [ -e "$(cat "$dir/staged-path")" ]; then echo present; else echo gone; fi > "$dir/worker-file"
printf '%s' "${FWD_TEST_FORWARD-unset}" > "$dir/worker-forward"
printf '%s' "${FWD_TEST_GONE-unset}" > "$dir/worker-gone"
printf '%s' "${ID-unset}" > "$dir/worker-id"
SH
}

# run_forward_spawn: a raw-command ship spawn whose
# worker is the probe. Callers set FM_TEST_PANE and the caller variables.
run_forward_spawn() {
  : > "$CASE_DIR/sent.log"
  FM_TEST_CASE_DIR="$CASE_DIR" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --harness "/bin/sh '$CASE_DIR/probe.sh' '$CASE_DIR'"
}

file_is() {  # <file> <expected>: exact contents, trailing newlines included
  local text
  text=$(cat "$1"; printf x)
  [ "${text%x}" = "$2" ]
}

pane_shells() {
  local shell
  for shell in /bin/sh /bin/bash /bin/zsh; do
    [ -x "$shell" ] && printf '%s\n' "$shell"
  done
  command -v fish || true
}

test_forward_value_reaches_worker_only_through_private_file() {
  local shell name out status
  while IFS= read -r shell; do
    name=forward-${shell##*/}
    make_forward_case "$name"
    printf 'FWD_TEST_FORWARD\nFWD_TEST_GONE\nID\n' > "$HOME_DIR/config/launch-env-forward"
    out=$(unset FWD_TEST_GONE ID; FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE="$shell" \
      FM_TEST_PANE_ENV="FWD_TEST_GONE=stale-pane-value" run_forward_spawn)
    status=$?
    expect_code 0 "$status" "$shell: forward-enabled spawn should succeed"$'\n'"$out"$'\n'"$(cat "$CASE_DIR/pane.out" 2>/dev/null)"
    file_is "$CASE_DIR/worker-forward" "$VALUE" \
      || fail "$shell: the worker did not receive the caller's exact value: $(cat "$CASE_DIR/worker-forward")"
    # Without the allowlist a name the caller left unset is not touched: the
    # launch command stays as it was, so the pane's own value, if any, remains.
    [ "$(cat "$CASE_DIR/worker-gone")" = stale-pane-value ] || fail "$shell: a name the caller left unset changed the pane's value"
    [ "$(cat "$CASE_DIR/worker-id")" = unset ] || fail "$shell: fm-spawn's own ID variable (or the pane's) was forwarded"
    [ "$(cat "$CASE_DIR/worker-file")" = gone ] || fail "$shell: the launch file still existed when the worker started"
    [ ! -e "$(cat "$CASE_DIR/staged-path")" ] || fail "$shell: the launch file survived the launch"
    [ "$(cat "$CASE_DIR/staged.mode")" = 600 ] || fail "$shell: the launch file is not 0600"
    [ "$(cat "$CASE_DIR/staged.dirmode")" = 700 ] || fail "$shell: the launch directory is not 0700"
    assert_not_contains "$(cat "$CASE_DIR/sent.log")" "$SECRET" "$shell: the forwarded value reached pane input"
    assert_not_contains "$out" "$SECRET" "$shell: the forwarded value reached spawn output"
    assert_contains "$(cat "$CASE_DIR/staged.copy")" "$SECRET" "$shell: the value did not travel in the launch file"
    assert_contains "$(cat "$CASE_DIR/pane.out")" SHELL-STILL-ALIVE "$shell: sourcing the launch file ended the pane shell"
  done < <(pane_shells)
  command -v fish >/dev/null 2>&1 || echo "skip: fish not found; the static syntax check below covers it"
  pass "a forwarded value reaches the worker byte for byte through the private launch file only, in $(pane_shells | sed 's#.*/##' | tr '\n' ' ')"
}

# fish rejects POSIX-only syntax; without fish, check the launch file statically.
test_forward_launch_file_is_fish_syntax() {
  local text
  # Everything ahead of the launch line: the unlink line and the exports.
  text=$(sed '$d' "$TMP_ROOT/forward-bash/staged.copy")
  # shellcheck disable=SC2016 # These are literal shell tokens fish rejects.
  case "$text" in
    *'$('* | *'${'* | *'{ '* | *'if ['* | *'unset '*)
      fail "the forward part of the launch file uses syntax fish cannot parse: $text" ;;
  esac
  case "$text" in
    "command rm -- '"*) ;;
    *) fail "the forward launch file does not unlink itself first: $text" ;;
  esac
  assert_contains "$text" "$SECRET" "the exports are not ahead of the launch line"
  assert_not_contains "$(tail -n 1 "$TMP_ROOT/forward-bash/staged.copy")" "$SECRET" "the launch line carries a value"
  assert_not_contains "$(cat "$TMP_ROOT/forward-bash/staged.copy")" "env -u" "an unset forwarded name changed the launch command"
  pass "the forward part of the launch file stays within syntax fish parses"
}

# fish cannot parse the allowlist's ${NAME+...} launch line. Its parse error
# quotes only that line, so no exported value may share it.
test_forward_fish_parse_error_never_shows_a_value() {
  local fish out status
  fish=$(command -v fish) || { echo "skip: fish not found; the static syntax check above covers the export lines"; return 0; }
  make_forward_case forward-fish-allowlist
  printf 'FWD_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
  printf 'FWD_TEST_GONE\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE="$fish" FM_ORCA_LAUNCH_CONSUME_POLLS=2 run_forward_spawn)
  status=$?
  expect_code 1 "$status" "fish cannot run the allowlist launch line, so the spawn must fail"$'\n'"$out"
  # shellcheck disable=SC2016 # The literal token fish rejects.
  assert_contains "$(cat "$CASE_DIR/pane.out")" '${' "fish did not report the launch line it rejected"
  assert_not_contains "$(cat "$CASE_DIR/pane.out")" "$SECRET" "fish's parse error printed a forwarded value"
  assert_not_contains "$out" "$SECRET" "the forwarded value reached spawn output"
  [ ! -e "$(cat "$CASE_DIR/staged-path")" ] || fail "the launch file fish never ran survived"
  pass "a fish parse error on the allowlist launch line shows no forwarded value, and the unsourced file is removed"
}

# hc pastes and submits the source line in one step, so the pane runs it before
# the spawn's Enter; the wait for the unlink must hold for that order too.
test_forward_source_at_literal_send() {
  local out status
  make_forward_case forward-literal-run
  printf 'FWD_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
  out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=/bin/bash FM_TEST_SOURCE_AT_LITERAL=1 run_forward_spawn)
  status=$?
  expect_code 0 "$status" "a pane that sources at the literal send should launch"$'\n'"$out"
  file_is "$CASE_DIR/worker-forward" "$VALUE" || fail "the worker did not receive the value when sourced at the literal send"
  [ ! -e "$(cat "$CASE_DIR/staged-path")" ] || fail "the launch file survived"
  assert_not_contains "$(cat "$CASE_DIR/sent.log")" "$SECRET" "the forwarded value reached pane input"
  pass "a pane that sources the launch file at the literal send, as hc does, gets the value and consumes the file"
}

# Names fm-spawn sets, pins or removes itself, and its caller snapshot, would
# silently lose to or override that value, so they are refused up front.
test_forward_reserved_names_refuse() {
  local out status name
  make_forward_case forward-reserved
  for name in FM_TASK_ID FM_HOME GOTMPDIR TRACEPARENT COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST SPAWN_CALLER_ENV; do
    printf 'FWD_TEST_FORWARD\n%s\n' "$name" > "$HOME_DIR/config/launch-env-forward"
    out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=none run_forward_spawn)
    status=$?
    expect_code 1 "$status" "launch-env-forward naming $name must refuse the spawn"
    assert_contains "$out" "config/launch-env-forward names $name" "the refusal must name $name"
    [ ! -s "$CASE_DIR/sent.log" ] || fail "the refusal for $name must come before any pane send"
  done
  pass "config/launch-env-forward refuses names firstmate sets for the worker itself before any pane exists"
}

test_forward_survives_allowlist_filter() {
  local out status
  make_forward_case forward-allowlist
  printf 'FWD_TEST_FORWARD\nFWD_TEST_GONE\n' > "$HOME_DIR/config/launch-env-forward"
  printf 'FWD_TEST_GONE\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(unset FWD_TEST_GONE; FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=/bin/bash \
    FM_TEST_PANE_ENV="FWD_TEST_GONE=stale-pane-value" run_forward_spawn)
  status=$?
  expect_code 0 "$status" "forward+allowlist spawn should succeed"$'\n'"$out"
  file_is "$CASE_DIR/worker-forward" "$VALUE" || fail "the forwarded value did not survive the allowlist's env -i"
  [ "$(cat "$CASE_DIR/worker-gone")" = unset ] || fail "an allowlisted name the caller left unset kept the pane's old value"
  assert_not_contains "$(cat "$CASE_DIR/sent.log")" "$SECRET" "the forwarded value reached pane input"
  pass "a forwarded value survives launch-env-allowlist, and an unset forwarded name stays out even when allowlisted"
}

normalized_launch() {  # <case-dir> <id>
  sed -e "s#$1#<case>#g" -e "s#/tmp/fm-$2+[^/']*#<launch-dir>#g" -e 's#launch\.[0-9A-Za-z.-]*\.sh#launch.<gen>.sh#g' \
    -e 's#git-config\.[0-9A-Za-z.-]*\.sh#git-config.<gen>.sh#g' -e "s#$2#<id>#g" "$1/staged.copy"
}

test_forward_absent_or_empty_config_changes_nothing() {
  local setting out status absent
  for setting in absent empty unset; do
    make_forward_case "forward-$setting"
    case "$setting" in
      empty) printf '# nothing forwarded\n' > "$HOME_DIR/config/launch-env-forward" ;;
      unset) printf 'FWD_TEST_GONE\n' > "$HOME_DIR/config/launch-env-forward" ;;
    esac
    out=$(unset FWD_TEST_GONE; FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=none FM_ORCA_LAUNCH_CONSUME_POLLS=0 run_forward_spawn)
    status=$?
    expect_code 0 "$status" "spawn with $setting launch-env-forward should succeed without waiting on the pane"$'\n'"$out"
    assert_not_contains "$(cat "$CASE_DIR/staged.copy")" "$SECRET" "$setting config forwarded a value"
    assert_not_contains "$(cat "$CASE_DIR/staged.copy")" "command rm" "$setting config made the launch file self-deleting"
    if [ "$setting" = absent ]; then
      absent=$(normalized_launch "$CASE_DIR" "$CASE_ID" | sed 's#forward-absent#forward-X#g')
    else
      [ "$(normalized_launch "$CASE_DIR" "$CASE_ID" | sed "s#forward-$setting#forward-X#g")" = "$absent" ] \
        || fail "an $setting launch-env-forward changed the launch file"
    fi
  done
  pass "an absent, empty, or only-unset config/launch-env-forward leaves the launch file and its handling unchanged"
}

test_forward_invalid_config_refuses() {
  local out status bad
  make_forward_case forward-invalid
  for bad in 'FM_TEST=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-forward"
    out=$(FM_TEST_PANE=none run_forward_spawn)
    status=$?
    expect_code 1 "$status" "invalid launch-env-forward content '$bad' must refuse the spawn"
    assert_contains "$out" 'launch-env-forward' "refusal must identify the config file for '$bad'"
    [ ! -s "$CASE_DIR/sent.log" ] || fail "an invalid config must refuse before any pane send for '$bad'"
  done
  pass "malformed config/launch-env-forward content refuses the spawn before any pane exists"
}

test_forward_unsourced_or_undelivered_file_is_removed() {
  local setting out status staged
  for setting in unsourced rmfail sendfail; do
    make_forward_case "forward-$setting"
    printf 'FWD_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
    mkdir -p "$CASE_DIR/rmfail"
    printf '#!/bin/sh\nexit 1\n' > "$CASE_DIR/rmfail/rm"
    chmod +x "$CASE_DIR/rmfail/rm"
    case "$setting" in
      unsourced) out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=none FM_ORCA_LAUNCH_CONSUME_POLLS=2 run_forward_spawn) ;;
      rmfail) out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=/bin/bash FM_TEST_PANE_PATH="$CASE_DIR/rmfail:/usr/bin:/bin" \
        FM_ORCA_LAUNCH_CONSUME_POLLS=2 run_forward_spawn) ;;
      sendfail) out=$(FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=/bin/bash FM_TEST_SEND_FAIL=1 run_forward_spawn) ;;
    esac
    status=$?
    expect_code 1 "$status" "$setting: the spawn must fail"$'\n'"$out"
    staged=$(ls /tmp/fm-"$CASE_ID"+*/launch.*.sh /tmp/fm-"$CASE_ID"+*/.launch.*.tmp 2>/dev/null)
    [ -z "$staged" ] || fail "$setting: the launch file carrying the value survived: $staged"
    [ ! -e "$CASE_DIR/worker-forward" ] || fail "$setting: the worker ran"
    assert_not_contains "$(cat "$CASE_DIR/sent.log")" "$SECRET" "$setting: the value reached pane input"
    case "$setting" in
      unsourced) assert_contains "$out" "did not run the launch command" "the failure must name the unrun launch" ;;
      rmfail) assert_contains "$(cat "$CASE_DIR/pane.out")" SHELL-STILL-ALIVE "a failed unlink ended the pane shell" ;;
      sendfail) assert_contains "$out" "could not be delivered" "the failure must name the undelivered launch" ;;
    esac
  done
  pass "a launch file the pane never sourced, could not unlink, or never received is removed and the spawn fails"
}

test_forward_interrupted_spawn_removes_file() {
  local sig pid status want staged i
  for sig in TERM HUP INT; do
    make_forward_case "forward-signal-$sig"
    printf 'FWD_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
    : > "$CASE_DIR/sent.log"
    # A background job ignores SIGINT on entry; restore the default so the
    # spawn receives INT as an interactive caller would deliver it.
    FWD_TEST_FORWARD="$VALUE" FM_TEST_PANE=none FM_TEST_CASE_DIR="$CASE_DIR" \
      python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
      env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR= \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX=fake,1,0 PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off \
      --harness "/bin/sh '$CASE_DIR/probe.sh' '$CASE_DIR'" > "$CASE_DIR/spawn.log" 2>&1 &
    pid=$!
    for ((i = 0; i < 300; i++)); do
      grep -q Enter "$CASE_DIR/sent.log" 2>/dev/null && [ -s "$CASE_DIR/staged-path" ] &&
        tail -1 "$CASE_DIR/sent.log" | grep -q Enter && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    staged=$(cat "$CASE_DIR/staged-path" 2>/dev/null)
    if [ -z "$staged" ] || [ ! -f "$staged" ] || ! kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid"
      fail "$sig: the spawn was not waiting on a delivered launch file: $(cat "$CASE_DIR/spawn.log")"
    fi
    kill -"$sig" "$pid"
    wait "$pid"
    status=$?
    case "$sig" in TERM) want=143 ;; HUP) want=129 ;; INT) want=130 ;; esac
    expect_code "$want" "$status" "$sig: interrupted spawn must exit with the signal status: $(cat "$CASE_DIR/spawn.log")"
    [ ! -e "$staged" ] || fail "$sig: interrupted spawn left the value in $staged"
    assert_contains "$(cat "$HOME_DIR/state/$CASE_ID.status" 2>/dev/null)" "refused the worker launch" "$sig: the reclaim must reach the task status"
  done
  pass "a spawn interrupted while its pane has not sourced the launch file removes it and exits with the signal status"
}

test_forward_meta_api_key_satisfies_muse_preflight() {
  local out status
  make_forward_case forward-muse
  printf 'META_API_KEY\n' > "$HOME_DIR/config/launch-env-forward"
  cp "$(command -v bash)" "$FAKEBIN_DIR/muse-bin-test-version"
  cat > "$FAKEBIN_DIR/muse" <<SH
#!/bin/sh
printf '%s' "\${META_API_KEY-unset}" > '$CASE_DIR/worker-forward'
SH
  chmod +x "$FAKEBIN_DIR/muse"
  : > "$CASE_DIR/sent.log"
  printf '%s\n' "$CASE_DIR/none" > "$CASE_DIR/staged-path"
  out=$(META_API_KEY="$SECRET-muse" FM_TEST_PANE=/bin/bash FM_TEST_CASE_DIR="$CASE_DIR" \
    XDG_CONFIG_HOME="$CASE_DIR/xdgconfig" XDG_DATA_HOME="$CASE_DIR/xdgdata" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR" muse \
    --mode no-mistakes --yolo off)
  status=$?
  assert_not_contains "$out" "no worker-reachable credential" "a forwarded META_API_KEY did not satisfy the muse preflight"
  expect_code 0 "$status" "muse spawn with a forwarded META_API_KEY should start"$'\n'"$out"
  [ "$(cat "$CASE_DIR/worker-forward")" = "$SECRET-muse" ] || fail "muse did not receive the forwarded META_API_KEY"
  assert_not_contains "$(cat "$CASE_DIR/sent.log")" "$SECRET" "the forwarded META_API_KEY reached pane input"
  pass "a forwarded META_API_KEY satisfies the muse credential preflight without a login"
}

test_forward_value_reaches_worker_only_through_private_file
test_forward_launch_file_is_fish_syntax
test_forward_fish_parse_error_never_shows_a_value
test_forward_source_at_literal_send
test_forward_reserved_names_refuse
test_forward_survives_allowlist_filter
test_forward_absent_or_empty_config_changes_nothing
test_forward_invalid_config_refuses
test_forward_unsourced_or_undelivered_file_is_removed
test_forward_interrupted_spawn_removes_file
test_forward_meta_api_key_satisfies_muse_preflight

echo "# all fm-launch-env-forward tests passed"
