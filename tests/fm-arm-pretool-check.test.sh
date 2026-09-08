#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the primary shell PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/fm-arm-command-policy.mjs is the single owner of command classification.
# This suite drives the stable shell transport through all five harness entry
# forms and asserts the per-harness wiring contract without spawning a harness.
# Empirical harness evidence lives in docs/arm-pretool-check.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case A01 allow 'bin/fm-watch-arm.sh'
matrix_case A02 allow './bin/fm-watch-arm.sh --restart'
matrix_case A03 allow 'exec bin/fm-watch-arm.sh'
matrix_case A04 allow 'bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A05 allow 'exec bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A06 allow "$ROOT/bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A07 allow "cd '$ROOT'; exec bin/fm-watch-arm.sh"
matrix_case A08 allow "cd '../firstmate'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A09 allow "export FM_HOME='$ROOT'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A10 allow 'source config/x-mode.env; bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A11 allow "source 'config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A12 allow "source './config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A13 allow "source '$ROOT/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A14 allow "[ -f 'config/x-mode.env' ] && source 'config/x-mode.env'; exec bin/fm-watch-arm.sh"
matrix_case A15 allow "cd $ROOT && exec bin/fm-watch-arm.sh"
matrix_case A16 allow "export FM_HOME=$ROOT && bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A17 allow $'source "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'

matrix_case R01 allow "pgrep -fl '/bin/fm-watch.sh' || true"
matrix_case R02 allow "ps aux | rg '/bin/fm-watch.sh'"
matrix_case R03 allow "rg -n 'fm-watch-arm.sh &' docs tests"
matrix_case R04 allow "rg -n 'bin/fm-watch-arm.sh; echo bad' docs"
matrix_case R05 allow "git grep 'fm-watch-checkpoint.sh && echo bad'"
matrix_case R06 allow "sed -n '/fm-watch-checkpoint.sh/p' docs/arm-pretool-check.md"
matrix_case R07 allow 'assert_contains "$content" '\''fm-watch-arm.sh &'\'''
matrix_case R08 allow "printf '%s\\n' 'bin/fm-watch-checkpoint.sh --seconds 180 >/tmp/out'"
matrix_case R09 allow "tmux send-keys -t isolated-pi-lab 'bin/fm-watch-arm.sh &' Enter"
matrix_case R10 allow "tmux send-keys -t isolated-pi-lab \"printf '%s\\n' 'bin/fm-watch-arm.sh &'\"; tmux send-keys -t isolated-pi-lab Enter"
matrix_case R11 allow "python3 -c 'print(\"bin/fm-watch-arm.sh; echo data\")'"
matrix_case R12 allow "bash -lc \"rg -n 'fm-watch-arm.sh &' docs\""
matrix_case R13 allow "echo 'pkill -f fm-watch'"
matrix_case R14 allow "rg -n 'pkill -f fm-watch' docs tests"
matrix_case R15 allow "echo ok # bin/fm-watch-arm.sh &"
matrix_case R16 allow $'# bin/fm-watch-arm.sh &\necho ok'
matrix_case R17 allow "printf '%s\\n' 'fm-watch.sh; a && b || c > out' | sed -n '1p'"
matrix_case R18 allow "sh -c 'tmux send-keys -t lab \"bin/fm-watch-arm.sh &\" Enter'"
matrix_case R19 allow "eval 'printf \"%s\\n\" \"bin/fm-watch-arm.sh &\"'"

matrix_case D01 deny 'bin/fm-watch-arm.sh &'
matrix_case D02 deny 'nohup bin/fm-watch-arm.sh'
matrix_case D03 deny 'bin/fm-watch-arm.sh & disown'
matrix_case D04 deny '(bin/fm-watch-arm.sh) &'
matrix_case D05 deny "bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case D06 deny '$(bin/fm-watch-arm.sh)'
matrix_case D07 deny 'echo "$(bin/fm-watch-checkpoint.sh --seconds 180)"'
matrix_case D08 deny 'cat <(bin/fm-watch-arm.sh)'
matrix_case D09 deny 'bin/fm-watch-arm.sh >/tmp/out'
matrix_case D10 deny 'bin/fm-watch-checkpoint.sh --seconds 180 </dev/null'
matrix_case D11 deny 'bin/fm-watch-arm.sh 2>&1 | head -2'
matrix_case D12 deny 'bin/fm-watch-arm.sh | cat'
matrix_case D13 deny 'bin/fm-watch-checkpoint.sh --seconds 180 | timeout 1 cat'
matrix_case D14 deny 'echo before; bin/fm-watch-arm.sh'
matrix_case D15 deny 'bin/fm-watch-checkpoint.sh --seconds 180; echo after'
matrix_case D16 deny 'true && bin/fm-watch-arm.sh'
matrix_case D17 deny 'bin/fm-watch-checkpoint.sh --seconds 180 || true'
matrix_case D18 deny $'bin/fm-watch-arm.sh\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case D19 deny "pkill -f '/bin/fm-watch.sh'"
matrix_case D20 deny "command pkill -f '/bin/fm-watch.sh'"
matrix_case D21 deny "/usr/bin/pkill -f '/bin/fm-watch.sh'"
matrix_case D22 deny "sudo pkill -f '/bin/fm-watch.sh'"
matrix_case D23 deny 'kill "$(pgrep -f '\''/bin/fm-watch.sh'\'')"'
matrix_case D24 deny $'bin/fm-watc\\\nh-arm.sh &'
matrix_case D25 deny 'sudo -u root bin/fm-watch-arm.sh &'
matrix_case D26 deny 'env -u PATH bin/fm-watch-arm.sh &'
matrix_case D27 deny "bash -c \$'bin/fm-watch-arm.sh &'"
matrix_case D28 deny $'bash <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
matrix_case D29 deny "WATCHER='bin/fm-watch-arm.sh &' bash -c 'eval \"\$WATCHER\"'"
matrix_case D30 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); kill \"\$p\""
matrix_case D31 deny "env -S 'bin/fm-watch-arm.sh &'"
matrix_case D32 deny "env --split-string='$ROOT/bin/fm-watch-arm.sh &'"
matrix_case D33 deny 'bin/fm-"watch-arm.sh" &'
matrix_case D34 deny "WATCHER='bin/fm-watch-arm.sh'; \"\$WATCHER\" &"
matrix_case D35 deny "bash -c -- 'bin/fm-watch-arm.sh &'"
matrix_case D36 deny 'bash bin/fm-watch-arm.sh &'
matrix_case D37 deny '. bin/fm-watch-arm.sh &'
matrix_case D38 deny "bash <<< 'bin/fm-watch-arm.sh &'"
matrix_case D39 deny "eval 'true;' 'bin/fm-watch-arm.sh &'"
matrix_case D40 deny 'timeout 30 bin/fm-watch-arm.sh &'
matrix_case D41 deny 'gtimeout 30 bin/fm-watch-arm.sh &'
matrix_case D42 deny 'bin/fm-watch-{arm,checkpoint}.sh &'
matrix_case D43 deny 'bin/fm-watch-arm.sh* &'
matrix_case D44 deny "pattern='fm-watch'; pkill -f \"\$pattern\""
matrix_case D45 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); q=\$p; kill \$q"
matrix_case D46 deny '$FM_HOME/bin/fm-watch-arm.sh &'
matrix_case D47 deny '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
matrix_case D48 deny '~/firstmate/bin/fm-watch-arm.sh &'
matrix_case D49 deny 'bin/fm-watch.sh'
matrix_case D50 deny '$FM_HOME/bin/fm-watch.sh'
matrix_case D51 deny '~/firstmate/bin/fm-watch.sh --restart'
matrix_case D52 deny "bin/fm-\$'\x77'atch-arm.sh &"
matrix_case D53 deny 'bin/fm-$"watch"-arm.sh &'
matrix_case D54 deny 'bin/fm-watch-$"arm".sh &'
matrix_case D55 deny 'while true; do pkill -f fm-watch; done'
matrix_case D56 deny 'for x in 1; do pkill -f fm-watch; done'
matrix_case D57 deny 'case x in x) pkill -f fm-watch ;; esac'
matrix_case D58 deny 'until false; do kill $(pgrep -f fm-watch); done'

matrix_case E01 allow "bin/fm-watch-checkpoint.sh --seconds '180;still-one-arg'"
matrix_case E02 allow "bin/fm-watch-checkpoint.sh --label 'fm-watch-arm.sh; literal argument'"
matrix_case E03 allow 'bin/fm-watch-arm.sh # output > file &'
matrix_case E04 allow $'# setup comment with fm-watch.sh; && >\nsource "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E05 deny "FM_HOME=$ROOT bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E06 deny "env FM_HOME=$ROOT bin/fm-watch-arm.sh"
matrix_case E07 deny "source '/tmp/not-firstmate/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E08 deny "bash -lc 'bin/fm-watch-checkpoint.sh --seconds 180'"
matrix_case E09 deny '(bin/fm-watch-checkpoint.sh --seconds 180)'
matrix_case E10 deny "eval 'bin/fm-watch-arm.sh &'"
matrix_case E11 deny "exec bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case E12 allow 'bash -lc "$WATCHER_COMMAND" # fm-watch-arm.sh'
matrix_case E13 allow "printf '%s\\n' 'argument has ; and fm-watch-arm.sh and &&'"
matrix_case E14 allow '$FM_HOME/bin/fm-teardown.sh &'
matrix_case E15 allow '$FM_HOME/bin/fm-watch-arm.sh'
matrix_case E16 allow '~/firstmate/bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E17 allow 'for f in 1; do echo fm-watch; done'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap fm_test_cleanup EXIT

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(watcher-(background|pipeline|redirection|bundled|nested|direct)|broad-watcher-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a stable reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through all five entry forms"
  done
}

assert_policy() {
  local id=$1 expected=$2 command=$3 output
  output=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$command") \
    || fail "$id direct policy invocation failed"
  case "$output" in
    "$expected"|"$expected"$'\t'*) : ;;
    *) fail "$id direct policy expected $expected, got: $output" ;;
  esac
  pass "direct policy $id: $expected"
}

test_direct_policy_contract() {
  local heredoc_data heredoc_watcher
  assert_policy direct-data-pkill allow "echo 'pkill -f fm-watch'"
  assert_policy direct-broad-pkill $'deny\tbroad-watcher-kill' "pkill -f '/bin/fm-watch.sh'"
  assert_policy direct-loop-broad-pkill $'deny\tbroad-watcher-kill' 'while true; do pkill -f fm-watch; done'
  assert_policy direct-loop-broad-kill-pgrep $'deny\tbroad-watcher-kill' 'until false; do kill $(pgrep -f fm-watch); done'
  assert_policy direct-loop-no-kill-allowed allow 'for f in 1; do echo fm-watch; done'
  assert_policy direct-pipeline $'deny\twatcher-pipeline' 'bin/fm-watch-arm.sh | cat'
  assert_policy direct-leading-redirection $'deny\twatcher-redirection' '>/tmp/out bin/fm-watch-arm.sh'
  assert_policy direct-unclassifiable $'deny\tunclassifiable-protected-command' "bin/fm-watch-arm.sh 'unterminated"
  assert_policy direct-unsupported $'deny\tunclassifiable-protected-command' 'if true; then bin/fm-watch-arm.sh; fi'
  assert_policy direct-constructed-payload $'deny\twatcher-nested' "WATCHER='bin/fm-watch-arm.sh &'; bash -lc \"\$WATCHER\""
  assert_policy direct-parameter-export allow 'export FM_HOME=${HOME}; bin/fm-watch-checkpoint.sh --seconds 180'
  assert_policy direct-expanded-arm-blessed allow '$FM_HOME/bin/fm-watch-arm.sh'
  assert_policy direct-expanded-arm-background $'deny\twatcher-background' '$FM_HOME/bin/fm-watch-arm.sh &'
  assert_policy direct-expanded-arm-pipeline $'deny\twatcher-pipeline' '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
  assert_policy direct-watch-not-blessed $'deny\twatcher-direct' 'bin/fm-watch.sh'
  assert_policy direct-watch-expanded $'deny\twatcher-direct' '$FM_HOME/bin/fm-watch.sh'
  assert_policy direct-watch-safe-shape $'deny\twatcher-direct' 'cd /tmp; bin/fm-watch.sh'
  heredoc_data=$'cat <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
  heredoc_watcher=$'bin/fm-watch-arm.sh <<\'EOF\'\ndata only\nEOF'
  assert_policy direct-heredoc-data allow "$heredoc_data"
  assert_policy direct-heredoc-watcher $'deny\twatcher-redirection' "$heredoc_watcher"
}

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/fm-watch-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/fm-watch-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/fm-watch-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/fm-watch-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

test_primary_pipeline_drive_is_denied_without_blocking_workers() {
  local dir primary worker check payload out err rc entry
  dir=$(fm_test_tmproot fm-primary-pipeline-drive)
  primary="$dir/primary"
  worker="$dir/worker"
  mkdir -p "$primary/bin" "$primary/state"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-arm-command-policy.mjs" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-hook-host-lib.sh" "$primary/bin/"
  chmod +x "$primary/bin/fm-arm-pretool-check.sh" "$primary/bin/fm-arm-command-policy.mjs"
  printf '# fixture\n' > "$primary/AGENTS.md"
  printf 'fixture-secondmate\n' > "$primary/.fm-secondmate-home"
  git -C "$primary" init -q
  git -C "$primary" add AGENTS.md .fm-secondmate-home bin
  git -C "$primary" -c user.name=test -c user.email=test@example.com commit -qm fixture
  git -C "$primary" worktree add -q --detach "$worker"
  git -C "$worker" checkout -qb fm/fixture-worker
  mkdir -p "$worker/state"
  check="$primary/bin/fm-arm-pretool-check.sh"

  # This reproduces the incident path through every supported shell-hook
  # transport. OMP and pi-signed share Pi's CLI form, while OpenCode also uses
  # it; Cursor has its distinct successful-deny JSON shape.
  for entry in codex claude grok opencode pi omp pi-signed cursor; do
    out="$dir/$entry.out"
    err="$dir/$entry.err"
    case "$entry" in
      codex)
        payload='{"tool_name":"Bash","tool_input":{"command":"no-mistakes axi respond --action fix"}}'
        printf '%s' "$payload" | FM_HOME="$primary" "$check" >"$out" 2>"$err"; rc=$?
        ;;
      claude)
        payload='{"tool_name":"Bash","tool_input":{"command":"no-mistakes axi respond --action fix"}}'
        printf '%s' "$payload" | FM_HOME="$primary" "$check" --claude >"$out" 2>"$err"; rc=$?
        ;;
      grok)
        payload='{"toolName":"run_terminal_command","toolInput":{"command":"no-mistakes axi respond --action fix"}}'
        printf '%s' "$payload" | FM_HOME="$primary" "$check" >"$out" 2>"$err"; rc=$?
        ;;
      cursor)
        payload='{"tool_name":"Shell","tool_input":{"command":"no-mistakes axi respond --action fix"}}'
        printf '%s' "$payload" | FM_HOME="$primary" "$check" --cursor >"$out" 2>"$err"; rc=$?
        ;;
      *)
        FM_HOME="$primary" "$check" --command 'no-mistakes axi respond --action fix' >"$out" 2>"$err"; rc=$?
        ;;
    esac
    if [ "$entry" = cursor ]; then
      [ "$rc" -eq 0 ] || fail "$entry primary pipeline deny must use its successful response shape, got $rc"
      jq -e '.permission == "deny" and (.user_message | contains("[primary-pipeline-drive]"))' "$out" >/dev/null \
        || fail "$entry primary pipeline deny omitted its reason: $(cat "$out")"
    else
      [ "$rc" -eq 2 ] || fail "$entry primary pipeline drive must deny, got $rc"
      jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[primary-pipeline-drive]"))' "$err" >/dev/null \
        || fail "$entry primary pipeline deny omitted its reason: $(cat "$err")"
    fi
  done

  cat > "$primary/state/fixture-secondmate.meta" <<EOF
kind=secondmate
worktree=$worker
EOF
  FM_HOME="$primary" "$worker/bin/fm-arm-pretool-check.sh" \
    --command 'no-mistakes axi respond --action fix' >"$dir/secondmate.out" 2>"$dir/secondmate.err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "a marker-backed persistent secondmate home must remain primary, got $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[primary-pipeline-drive]"))' \
    "$dir/secondmate.err" >/dev/null \
    || fail "the persistent secondmate-home deny omitted its stable reason"

  rm "$primary/state/fixture-secondmate.meta"
  cat > "$primary/state/fixture-worker.meta" <<EOF
kind=ship
worktree=$worker
EOF
  for payload in \
    'no-mistakes axi respond --action fix' \
    'time no-mistakes axi respond --action fix' \
    'time -p no-mistakes axi respond --action fix' \
    '/usr/bin/time -l no-mistakes axi respond --action fix' \
    'coproc no-mistakes axi respond --action fix' \
    'coproc JOB no-mistakes axi respond --action fix' \
    'coproc JOB MODE=fix no-mistakes axi respond --action fix' \
    'coproc JOB env no-mistakes axi respond --action fix' \
    'coproc JOB { no-mistakes axi respond --action fix; }' \
    "bash -o posix -c 'no-mistakes axi respond --action fix'" \
    "CMD='no-mistakes axi respond --action fix'; bash -c \"\$CMD\"" \
    "CMD='no-mistakes axi respond --action fix'; eval \"\$CMD\"" \
    'NM=no-mistakes; $NM axi respond --action fix' \
    'for NM in no-mistakes; do "$NM" axi respond --action fix; done' \
    'for NM in echo; do NM=no-mistakes; done; "$NM" axi respond --action fix' \
    'NM=no-mistakes; false && NM=echo; "$NM" axi respond --action fix' \
    "bash -c \"\$(printf '%s' 'no-mistakes axi respond --action fix')\"" \
    'bash -c '\''exec "$0" "$@"'\'' no-mistakes axi respond --action fix' \
    'ACTION=$(printf respond); no-mistakes axi "$ACTION" --action fix' \
    'ACTION=$(unknown-action); no-mistakes axi "$ACTION" --action fix' \
    '$(command -v no-mistakes) axi respond --action fix' \
    "SH=bash; \"\$SH\" -c 'no-mistakes axi respond --action fix'" \
    "bash -c -- 'no-mistakes axi respond --action fix'" \
    'CMD=$(echo no-mistakes); "$CMD" axi respond --action fix' \
    'ACTION=respond; for x in; do ACTION=status; done; no-mistakes axi "$ACTION"' \
    'NM=no-mistakes; if false; then NM=echo; fi; "$NM" axi respond --action fix' \
    'ACTION=respond; ! true && ACTION=status; no-mistakes axi "$ACTION"' \
    'NM=no-mistakes; while false; do NM=echo; done; "$NM" axi respond --action fix' \
    'ACTION=respond; case no in yes) ACTION=status;; esac; no-mistakes axi "$ACTION"' \
    'if ! false; then no-mistakes axi respond --action fix; fi' \
    'if false || true; then no-mistakes axi respond --action fix; fi' \
    'if false; true; then no-mistakes axi respond --action fix; fi' \
    'if false; then :; elif true; then no-mistakes axi respond --action fix; fi' \
    'case x in y|x) no-mistakes axi respond --action fix;; esac' \
    'if no-mistakes axi respond --action fix; then echo done; fi' \
    'for x in 1; do no-mistakes axi respond --action fix; done'; do
    FM_HOME="$primary" "$worker/bin/fm-arm-pretool-check.sh" \
      --command "$payload" >"$dir/worker.out" 2>"$dir/worker.err"
    rc=$?
    [ "$rc" -eq 0 ] || fail "an exactly recorded ship worker must retain its pipeline drive call, got $rc for: $payload"
    [ ! -s "$dir/worker.out" ] && [ ! -s "$dir/worker.err" ] \
      || fail "an allowed task-worker pipeline drive must stay silent"
  done

  for payload in \
    'no-mistakes axi run --intent test' \
    'env NO_COLOR=1 no-mistakes axi respond --action fix' \
    "bash -lc 'no-mistakes axi respond --action fix'" \
    'time no-mistakes axi respond --action fix' \
    'time -p no-mistakes axi respond --action fix' \
    '/usr/bin/time -l no-mistakes axi respond --action fix' \
    'coproc no-mistakes axi respond --action fix' \
    'coproc JOB no-mistakes axi respond --action fix' \
    'coproc JOB MODE=fix no-mistakes axi respond --action fix' \
    'coproc JOB env no-mistakes axi respond --action fix' \
    'coproc JOB { no-mistakes axi respond --action fix; }' \
    "bash -o posix -c 'no-mistakes axi respond --action fix'" \
    "CMD='no-mistakes axi respond --action fix'; bash -c \"\$CMD\"" \
    "CMD='no-mistakes axi respond --action fix'; eval \"\$CMD\"" \
    'NM=no-mistakes; $NM axi respond --action fix' \
    'for NM in no-mistakes; do "$NM" axi respond --action fix; done' \
    'for NM in echo; do NM=no-mistakes; done; "$NM" axi respond --action fix' \
    'NM=no-mistakes; false && NM=echo; "$NM" axi respond --action fix' \
    "bash -c \"\$(printf '%s' 'no-mistakes axi respond --action fix')\"" \
    'bash -c '\''exec "$0" "$@"'\'' no-mistakes axi respond --action fix' \
    'ACTION=$(printf respond); no-mistakes axi "$ACTION" --action fix' \
    'ACTION=$(unknown-action); no-mistakes axi "$ACTION" --action fix' \
    '$(command -v no-mistakes) axi respond --action fix' \
    "SH=bash; \"\$SH\" -c 'no-mistakes axi respond --action fix'" \
    "bash -c -- 'no-mistakes axi respond --action fix'" \
    'CMD=$(echo no-mistakes); "$CMD" axi respond --action fix' \
    'ACTION=respond; for x in; do ACTION=status; done; no-mistakes axi "$ACTION"' \
    'NM=no-mistakes; if false; then NM=echo; fi; "$NM" axi respond --action fix' \
    'ACTION=respond; ! true && ACTION=status; no-mistakes axi "$ACTION"' \
    'NM=no-mistakes; while false; do NM=echo; done; "$NM" axi respond --action fix' \
    'ACTION=respond; case no in yes) ACTION=status;; esac; no-mistakes axi "$ACTION"' \
    'if ! false; then no-mistakes axi respond --action fix; fi' \
    'if false || true; then no-mistakes axi respond --action fix; fi' \
    'if false; true; then no-mistakes axi respond --action fix; fi' \
    'if false; then :; elif true; then no-mistakes axi respond --action fix; fi' \
    'case x in y|x) no-mistakes axi respond --action fix;; esac' \
    'if no-mistakes axi respond --action fix; then echo done; fi' \
    'for x in 1; do no-mistakes axi respond --action fix; done'; do
    FM_HOME="$primary" "$check" --command "$payload" >"$dir/run.out" 2>"$dir/run.err"
    rc=$?
    [ "$rc" -eq 2 ] || fail "the primary pipeline drive must deny through recognized execution wrappers, got $rc for: $payload"
    jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[primary-pipeline-drive]"))' "$dir/run.err" >/dev/null \
      || fail "the primary pipeline-run deny omitted its stable reason"
  done
  FM_HOME="$primary" "$check" \
    --command 'case x in *) no-mistakes axi respond --action fix;; esac' >"$dir/case.out" 2>"$dir/case.err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "an executed case-body pipeline drive must be denied, got $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[primary-pipeline-drive]"))' \
    "$dir/case.err" >/dev/null || fail "the case-body pipeline deny omitted its stable reason"
  for payload in \
    "echo 'no-mistakes axi respond --action fix'" \
    "time echo 'no-mistakes axi run --intent data'" \
    "/usr/bin/time -l echo 'no-mistakes axi run --intent data'" \
    "coproc echo 'no-mistakes axi respond --action data'" \
    "CMD='no-mistakes axi respond --action data'; echo \"\$CMD\"" \
    "CMD='no-mistakes axi respond --action data'; \"\$CMD\"" \
    'for NM in no-mistakes; do echo "$NM axi respond --action data"; done' \
    'for NM in no-mistakes echo; do :; done; "$NM" axi respond --action data' \
    'NM=no-mistakes; true && NM=echo; "$NM" axi respond --action data' \
    'NM=no-mistakes; if true; then NM=echo; fi; "$NM" axi respond --action data' \
    "echo \"\$(printf '%s' 'no-mistakes axi respond --action data')\"" \
    'bash -c '\''echo "$0 $@"'\'' no-mistakes axi respond --action data' \
    "if echo 'no-mistakes axi respond --action data'; then echo done; fi" \
    "case \"\$x\" in *) echo 'no-mistakes axi run';; esac"; do
    FM_HOME="$primary" "$check" --command "$payload" >/dev/null 2>&1 \
      || fail "a pipeline command mentioned only as data must remain allowed: $payload"
  done
  FM_HOME="$primary" "$check" --command 'no-mistakes axi status' >/dev/null 2>&1 \
    || fail "the primary must retain read-only pipeline status"
  FM_HOME="$primary" "$check" --command "bash -c -- 'no-mistakes axi status'" >/dev/null 2>&1 \
    || fail "the primary must retain nested read-only pipeline status"
  FM_HOME="$primary" "$check" --command 'ACTION=$(printf status); no-mistakes axi "$ACTION"' >/dev/null 2>&1 \
    || fail "the primary must retain dynamically selected read-only pipeline status"
  FM_HOME="$primary" "$check" --command 'if false; then no-mistakes axi respond --action fix; fi' >/dev/null 2>&1 \
    || fail "an unreachable conditional pipeline drive must remain allowed"
  FM_HOME="$primary" "$check" --command 'while false; do no-mistakes axi respond --action fix; done' >/dev/null 2>&1 \
    || fail "an unreachable while-loop pipeline drive must remain allowed"
  FM_HOME="$primary" "$check" --command 'case no in yes) no-mistakes axi respond --action fix;; esac' >/dev/null 2>&1 \
    || fail "an unreachable case pipeline drive must remain allowed"
  FM_HOME="$primary" "$check" --command 'ACTION=respond; case yes in yes) ACTION=status;; esac; no-mistakes axi "$ACTION"' >/dev/null 2>&1 \
    || fail "a matching case branch must preserve its read-only action"
  FM_HOME="$primary" "$check" --command 'ACTION=status; false && ACTION=respond; no-mistakes axi "$ACTION"' >/dev/null 2>&1 \
    || fail "a skipped driving-action assignment must retain read-only pipeline status"
  FM_HOME="$primary" "$check" --command 'no-mistakes axi abort --run 01RUN' >/dev/null 2>&1 \
    || fail "the primary must retain explicit recovery controls"
  pass "foreground pipeline drives are denied across primary harness transports while workers retain ownership"
}

test_prefilter_is_strict_superset() {
  local rc
  # A command with neither protected substring is fast-allowed by the
  # transport prefilter without ever invoking the classifier.
  "$CHECK" --command 'ls -la /bin && echo done' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a command with no fm-watch substring must be fast-allowed, got exit $rc"
  # A deniable protected execution carries the fm-watch bytes, so the prefilter
  # must delegate to the classifier and the deny must survive.
  "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a deniable fm-watch command, not fast-allow it, got exit $rc"
  # A broad watcher kill also contains the fm-watch bytes and must still deny.
  "$CHECK" --command "pkill -f '/bin/fm-watch.sh'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad watcher kill, not fast-allow it, got exit $rc"
  # Obfuscated protected paths lose the literal fm-watch bytes (a line
  # continuation or a quote splits them), yet the classifier reconstructs them.
  # The prefilter normalizes those bytes first, so both must still delegate and
  # deny rather than slip through as a fast allow.
  "$CHECK" --command "$(printf 'bin/fm-watc\\\nh-arm.sh &')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a line-continuation-split protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-"watch-arm.sh" &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split protected path, not fast-allow it, got exit $rc"
  # A quoting-decoder marker ($' ANSI-C or $" locale) hides the fm-watch bytes
  # from the cheap byte strip but the classifier reconstructs them, so the
  # prefilter must delegate on the marker rather than fast-allow. Without this
  # the byte strip loses the encoded character and slips the command through.
  "$CHECK" --command "bin/fm-\$'\x77'atch-arm.sh &" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate an ANSI-C-encoded protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-$"watch"-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a locale-string-encoded protected path, not fast-allow it, got exit $rc"
  # The marker is specifically $ followed by a quote, not any $ expansion: an
  # ordinary $VAR that is not a watcher reference still takes the fast path.
  "$CHECK" --command '$FM_HOME/bin/fm-teardown.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$VAR non-watcher command must still fast-allow, got exit $rc"
  "$CHECK" --command 'echo "$HOME/scratch" && ls -la' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$HOME command must still fast-allow, got exit $rc"
  # A benign command that only mentions fm-watch as data still reaches the
  # classifier and is allowed there, proving the prefilter owns no verdict.
  "$CHECK" --command "echo 'pkill -f fm-watch'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign fm-watch-substring command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: unrelated commands fast-allow, protected commands reach the classifier"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real
  dir=$(fm_test_tmproot fm-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_failopen_missing_node() {
  local dir fakebin rc real tool
  dir=$(fm_test_tmproot fm-arm-pretool-node)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing node must fail open (exit 0), got exit $rc"
  pass "fail-open: missing classifier runtime"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc stderr_file
  # Keep stderr capture under TMPDIR so concurrent isolation-proof workers do
  # not share a fixed global /tmp path.
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-arm-pretool-check-claude-stderr.XXXXXX")
  out=$("$CHECK" --claude --command 'bin/fm-watch-arm.sh &' 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/fm-watch-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/fm-watch-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/fm-watch-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----
#
# Delegated to bin/fm-lint.sh rather than calling shellcheck directly, because
# that script is the single owner of the lint definition - the file set, the
# pinned version, and the options, including --external-sources. Calling the
# linter directly here would be a second, weaker copy of that definition, and it
# disagreed with the owner the moment this checker sourced a shared library.

test_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$CHECK" 2>&1)     || fail "bin/fm-arm-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-arm-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_direct_policy_contract
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_primary_pipeline_drive_is_denied_without_blocking_workers
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
