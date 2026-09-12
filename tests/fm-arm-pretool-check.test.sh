#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the watcher-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
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

# K-series: the general broad-process-kill class, driven through the full
# transport (prefilter + all five harness renderings) so the widened prefilter
# is proven to delegate these to the classifier rather than fast-allowing them.
# K01/K02 are the exact shape of the 2026-09-10 cross-lane incident: a kill fed
# by an unscoped `pgrep -f <phrase>` that matched a sibling lane's argv.
matrix_case K01 deny 'pkill -f "lavish-axi poll"'
matrix_case K02 deny 'kill $(pgrep -f "lavish-axi poll")'
matrix_case K03 deny 'pgrep -f "lavish-axi poll" | xargs kill'
matrix_case K04 deny 'killall claude'
matrix_case K05 deny 'pkill node'
matrix_case K06 allow 'pkill -P 12345'
matrix_case K07 allow 'kill $(pgrep -P $$)'
matrix_case K08 allow 'pgrep -f "lavish-axi poll" | head'
matrix_case K09 allow 'kill 76803'
# K10-K17: signal names are not scope flags; separated-value xargs options; and
# discovery by ps/lsof feeding a kill through a pipe, substitution, or variable.
matrix_case K10 deny 'pkill -HUP node'
matrix_case K11 deny 'pkill -STOP -f "lavish-axi poll"'
matrix_case K12 deny 'pgrep -f node | xargs -n 1 kill'
matrix_case K13 deny 'ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"' | xargs kill'
matrix_case K14 deny 'kill $(ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"')'
matrix_case K15 deny 'lsof -ti :3000 | xargs kill -9'
matrix_case K16 deny 'p=$(ps aux | grep node | awk '"'"'{print $2}'"'"'); kill $p'
matrix_case K17 deny 'while true; do pkill -f node; done'
# K18-K23: caller-owned pid sources, a scoped producer with a separated-value
# xargs option, the scoped cleanup idiom inside a loop, and a kill -0 probe.
matrix_case K18 allow 'kill $(cat pidfile)'
matrix_case K19 allow 'echo 123 | xargs kill'
matrix_case K20 allow 'kill $(jobs -p)'
matrix_case K21 allow 'pgrep -P $$ | xargs -n 1 kill'
matrix_case K22 allow 'for p in $(pgrep -P $$); do kill $p; done'
matrix_case K23 allow 'kill -0 $(pgrep -f "lavish-axi poll")'
# K24-K28: fuser -k is itself a kill; a complete discovery pipe or substitution
# inside loop/if grammar fails closed; attached-value scope flags stay allowed.
matrix_case K24 deny 'fuser -k 3000/tcp'
matrix_case K25 deny 'while true; do ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"' | xargs kill; sleep 1; done'
matrix_case K26 deny 'if true; then lsof -ti :3000 | xargs kill -9; fi'
matrix_case K27 allow 'fuser 3000/tcp'
matrix_case K28 allow 'pkill -P$$'
# K29-K36: kill-all via pid -1, a discovery wrapped in the producer node, an
# xargs pkill by name and a wrapped xargs kill utility; and the query/help
# forms plus the negative process-group form that must stay allowed.
matrix_case K29 deny 'kill -9 -1'
matrix_case K30 deny '(pgrep -f node) | xargs kill'
matrix_case K31 deny 'echo node | xargs pkill -f'
matrix_case K32 deny 'pgrep -f node | xargs -n1 sudo kill'
matrix_case K33 allow 'kill -- -$pgid'
matrix_case K34 allow 'kill -1 1234'
matrix_case K35 allow 'command -v pkill'
matrix_case K36 allow 'pkill --help'
# K37-K40: kill-all inside loop grammar fails closed; the portable probe idiom
# inside if grammar and an xargs kill -0 probe stay allowed.
matrix_case K37 deny 'while true; do kill -9 -1; done'
matrix_case K38 deny 'pgrep -f node | xargs --max-lines kill'
matrix_case K39 allow 'if command -v pkill >/dev/null 2>&1; then echo y; fi'
matrix_case K40 allow 'pgrep -f node | xargs kill -0'
# K41-K43: a scope-looking flag inside a quoted pattern is not scope, and any
# lsof invocation feeding a kill is discovery, like ps.
matrix_case K41 deny 'while true; do pkill -f "node server.js -P 3000"; done'
matrix_case K42 deny 'lsof -i :3000 | awk '"'"'NR>1{print $2}'"'"' | xargs kill -9'
matrix_case K43 allow 'for p in $(pgrep -P "$$"); do kill $p; done'
# K44-K48: a negation or builtin prefix does not hide the kill, a kill-all on
# the xargs tail is broad, and the kill -0 wait loop with a later -1 argument
# to another command is allowed.
matrix_case K44 deny '! pkill -f node'
matrix_case K45 deny 'builtin kill -- -1'
matrix_case K46 deny 'echo x | xargs kill -- -1'
matrix_case K47 allow 'while kill -0 "$pid" 2>/dev/null; do tail -1 "$log"; sleep 1; done'
matrix_case K48 allow '! pkill -P $$'

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
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(watcher-(background|pipeline|redirection|bundled|nested|direct)|broad-watcher-kill|broad-process-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
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
  assert_policy direct-watcher-pgrep-xargs-kill $'deny\tbroad-watcher-kill' 'pgrep -f fm-watch | xargs kill'
  assert_policy direct-watcher-subshell-pgrep-xargs-kill $'deny\tbroad-watcher-kill' '(pgrep -f fm-watch) | xargs kill'
  assert_policy direct-watcher-negated-pkill $'deny\tbroad-watcher-kill' '! pkill -f fm-watch'
  assert_policy direct-watcher-negated-arm $'deny\twatcher-nested' '! bin/fm-watch-arm.sh'
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

# The general broad-process-kill class (docs/arm-pretool-check.md). A kill that
# selects processes by command line or name reaches every match on the shared
# process table, not just the caller's own tree, so it can hit a sibling lane -
# the 2026-09-10 cross-lane incident. This is the class-closing generalization of
# the watcher-only broad-kill rule, and these paired allow/deny assertions are
# its regression: each asserts the exact verdict and fails if the guard stops
# refusing the unscoped shape OR starts refusing a caller-scoped one.
test_broad_process_kill_contract() {
  # The exact 2026-09-10 incident shape: a kill fed by an unscoped `pgrep -f
  # <phrase>` (and the equivalent pipe and pkill forms) that matched a sibling
  # lane's argv rather than the fixture stub it meant to reap.
  assert_policy incident-kill-cmdsub $'deny\tbroad-process-kill' 'kill $(pgrep -f "lavish-axi poll")'
  assert_policy incident-pkill-f $'deny\tbroad-process-kill' 'pkill -f "lavish-axi poll"'
  assert_policy incident-pgrep-xargs-kill $'deny\tbroad-process-kill' 'pgrep -f "lavish-axi poll" | xargs kill'
  # Selecting by process name (default, or -x) is machine-wide too.
  assert_policy bpk-pkill-name $'deny\tbroad-process-kill' 'pkill node'
  assert_policy bpk-pkill-exact-name $'deny\tbroad-process-kill' 'pkill -x claude'
  assert_policy bpk-killall $'deny\tbroad-process-kill' 'killall claude'
  # -G is a real unix group id, not a process group, so it is still broad.
  assert_policy bpk-pkill-gid $'deny\tbroad-process-kill' 'pkill -G staff -f node'
  # Via a wrapper and via a variable holding the unscoped match.
  assert_policy bpk-sudo-pkill $'deny\tbroad-process-kill' 'sudo pkill -f node'
  assert_policy bpk-var-unscoped $'deny\tbroad-process-kill' 'p=$(pgrep -f node); kill $p'
  # Unsupported grammar carrying a broad kill fails closed, like the watcher case.
  assert_policy bpk-loop $'deny\tbroad-process-kill' 'while true; do pkill -f node; done'
  # A signal name is not a scope flag, even when it contains P, g, or s.
  assert_policy bpk-signal-hup $'deny\tbroad-process-kill' 'pkill -HUP node'
  assert_policy bpk-signal-sighup $'deny\tbroad-process-kill' 'pkill -SIGHUP node'
  assert_policy bpk-signal-stop $'deny\tbroad-process-kill' 'pkill -STOP -f "lavish-axi poll"'
  assert_policy bpk-signal-pipe $'deny\tbroad-process-kill' 'pkill -PIPE node'
  assert_policy bpk-signal-tstp $'deny\tbroad-process-kill' 'pkill -TSTP -f "lavish-axi poll"'
  assert_policy bpk-signal-numeric $'deny\tbroad-process-kill' 'pkill -9 -f node'
  # xargs options with a separated value must not hide the kill utility.
  assert_policy bpk-xargs-n-sep $'deny\tbroad-process-kill' 'pgrep -f node | xargs -n 1 kill'
  assert_policy bpk-xargs-I-sep $'deny\tbroad-process-kill' 'pgrep -f node | xargs -I {} kill'
  assert_policy bpk-xargs-L-sep $'deny\tbroad-process-kill' 'pgrep -f node | xargs -L 1 kill'
  assert_policy bpk-xargs-end-of-options $'deny\tbroad-process-kill' 'pgrep -f node | xargs -- kill'
  # Discovery by ps/lsof/pidof/fuser feeding a kill is the same class as pgrep.
  assert_policy bpk-ps-awk-xargs $'deny\tbroad-process-kill' 'ps aux | grep "lavish-axi poll" | grep -v grep | awk '"'"'{print $2}'"'"' | xargs kill'
  assert_policy bpk-ps-cmdsub $'deny\tbroad-process-kill' 'kill $(ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"')'
  assert_policy bpk-lsof-xargs $'deny\tbroad-process-kill' 'lsof -ti :3000 | xargs kill -9'
  assert_policy bpk-lsof-cmdsub $'deny\tbroad-process-kill' 'kill -9 $(lsof -t -i :3000)'
  assert_policy bpk-pidof-cmdsub $'deny\tbroad-process-kill' 'kill $(pidof node)'
  assert_policy bpk-fuser-xargs $'deny\tbroad-process-kill' 'fuser 3000/tcp 2>/dev/null | xargs kill'
  assert_policy bpk-ps-var $'deny\tbroad-process-kill' 'p=$(ps aux | grep node | awk '"'"'{print $2}'"'"'); kill $p'
  # fuser -k kills every process on the port itself; it is a kill, not a feed.
  assert_policy bpk-fuser-k $'deny\tbroad-process-kill' 'fuser -k 3000/tcp'
  assert_policy bpk-fuser-k-namespace $'deny\tbroad-process-kill' 'fuser -k -n tcp 3000'
  assert_policy bpk-fuser-k-signal $'deny\tbroad-process-kill' 'fuser -KILL -k 3000/tcp'
  assert_policy bpk-fuser-kill-long $'deny\tbroad-process-kill' 'fuser --kill 3000/tcp'
  assert_policy bpk-loop-fuser-k $'deny\tbroad-process-kill' 'for x in 1; do fuser -k 3000/tcp; done'
  # A complete discovery pipe or substitution inside unsupported loop/if grammar
  # fails closed for ps/lsof/pidof exactly as it does for pgrep.
  assert_policy bpk-loop-ps-xargs $'deny\tbroad-process-kill' 'while true; do ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"' | xargs kill; sleep 1; done'
  assert_policy bpk-if-lsof-xargs $'deny\tbroad-process-kill' 'if true; then lsof -ti :3000 | xargs kill -9; fi'
  assert_policy bpk-loop-pidof-cmdsub $'deny\tbroad-process-kill' 'for x in 1; do kill $(pidof node); done'
  assert_policy bpk-loop-ps-cmdsub $'deny\tbroad-process-kill' 'until false; do kill $(ps aux | grep "lavish-axi poll" | awk '"'"'{print $2}'"'"'); done'
  # kill targeting pid -1 signals every process the caller may reach.
  assert_policy bpk-kill-all-signal $'deny\tbroad-process-kill' 'kill -9 -1'
  assert_policy bpk-kill-all-dashdash $'deny\tbroad-process-kill' 'kill -- -1'
  assert_policy bpk-kill-all-named-signal $'deny\tbroad-process-kill' 'kill -s TERM -1'
  assert_policy bpk-kill-all-signal-dashdash $'deny\tbroad-process-kill' 'kill -TERM -- -1'
  # The kill-all form fails closed inside unsupported grammar too.
  assert_policy bpk-loop-kill-all $'deny\tbroad-process-kill' 'while true; do kill -9 -1; done'
  assert_policy bpk-if-kill-all-dashdash $'deny\tbroad-process-kill' 'if true; then kill -- -1; fi'
  assert_policy bpk-case-kill-all $'deny\tbroad-process-kill' 'case x in x) kill -9 -1 ;; esac'
  # A discovery wrapped in the producer node's subshell, group, or substitution
  # still feeds the xargs kill.
  assert_policy bpk-subshell-pgrep-xargs $'deny\tbroad-process-kill' '(pgrep -f node) | xargs kill'
  assert_policy bpk-group-pgrep-xargs $'deny\tbroad-process-kill' '{ pgrep -f a; pgrep -f b; } | xargs kill'
  assert_policy bpk-cmdsub-pgrep-echo-xargs $'deny\tbroad-process-kill' 'echo $(pgrep -f node) | xargs kill'
  assert_policy bpk-subshell-ps-xargs $'deny\tbroad-process-kill' '(ps aux | grep node | awk '"'"'{print $2}'"'"') | xargs kill'
  # xargs pkill/killall is broad by name whatever feeds it; a kill utility
  # behind a known wrapper or a separated long xargs option is still found.
  assert_policy bpk-xargs-pkill-by-name $'deny\tbroad-process-kill' 'echo node | xargs pkill -f'
  assert_policy bpk-xargs-pkill-n1 $'deny\tbroad-process-kill' 'cat names | xargs -n1 pkill -f'
  assert_policy bpk-xargs-killall $'deny\tbroad-process-kill' 'cat names | xargs killall'
  assert_policy bpk-xargs-sudo-kill $'deny\tbroad-process-kill' 'pgrep -f node | xargs -n1 sudo kill'
  assert_policy bpk-xargs-command-kill $'deny\tbroad-process-kill' 'pgrep -f node | xargs -n1 command kill'
  assert_policy bpk-xargs-env-kill $'deny\tbroad-process-kill' 'pgrep -f node | xargs -n1 env kill'
  assert_policy bpk-xargs-long-option-kill $'deny\tbroad-process-kill' 'pgrep -f node | xargs --max-args 1 kill'
  # --max-lines and --eof take an optional attached value only, so unattached
  # they consume nothing and the next word is the utility.
  assert_policy bpk-xargs-max-lines-bare $'deny\tbroad-process-kill' 'pgrep -f node | xargs --max-lines kill'
  assert_policy bpk-xargs-eof-bare $'deny\tbroad-process-kill' 'pgrep -f node | xargs --eof kill'
  assert_policy bpk-xargs-max-lines-attached $'deny\tbroad-process-kill' 'pgrep -f node | xargs --max-lines=1 kill'
  assert_policy bpk-xargs-kill-signal $'deny\tbroad-process-kill' 'pgrep -f node | xargs kill -9'
  # Query forms inside unsupported grammar are still queries; an executed kill
  # in the same grammar is still denied.
  assert_policy bpk-if-pkill-executed $'deny\tbroad-process-kill' 'if true; then pkill -f node; fi'
  assert_policy bpk-if-killall-list-then-kill $'deny\tbroad-process-kill' 'if true; then killall -l; killall node; fi'
  # A scope-looking flag inside a quoted -f pattern is pattern text, not scope.
  assert_policy bpk-loop-quoted-pattern-P $'deny\tbroad-process-kill' 'while true; do pkill -f "node server.js -P 3000"; done'
  assert_policy bpk-loop-quoted-pattern-g $'deny\tbroad-process-kill' "while true; do pkill -f 'gunicorn -g 2'; done"
  assert_policy bpk-loop-quoted-pattern-pgrep $'deny\tbroad-process-kill' 'for p in $(pgrep -f "node -s 5"); do kill $p; done'
  # Any lsof invocation feeding a kill is discovery, exactly like ps.
  assert_policy bpk-lsof-table-awk-xargs $'deny\tbroad-process-kill' 'lsof -i :3000 | awk '"'"'NR>1{print $2}'"'"' | xargs kill -9'
  assert_policy bpk-lsof-table-awk-cmdsub $'deny\tbroad-process-kill' 'kill -9 $(lsof -i :3000 | awk '"'"'NR>1{print $2}'"'"')'
  assert_policy bpk-if-lsof-table-awk $'deny\tbroad-process-kill' 'if true; then lsof -i :3000 | awk '"'"'NR>1{print $2}'"'"' | xargs kill -9; fi'
  # A leading negation or builtin prefix is unwrapped, so the real command is
  # classified; time is routed to the raw fallback.
  assert_policy bpk-negated-pkill $'deny\tbroad-process-kill' '! pkill -f node'
  assert_policy bpk-double-negated-pkill $'deny\tbroad-process-kill' '! ! pkill -f node'
  assert_policy bpk-negated-kill-all $'deny\tbroad-process-kill' '! kill -9 -1'
  assert_policy bpk-builtin-kill-all $'deny\tbroad-process-kill' 'builtin kill -- -1'
  assert_policy bpk-time-pkill $'deny\tbroad-process-kill' 'time pkill -f node'
  assert_policy bpk-negated-time-pkill $'deny\tbroad-process-kill' '! time pkill -f node'
  assert_policy bpk-negated-time-kill-all $'deny\tbroad-process-kill' '! time kill -9 -1'
  # A kill-all target on the xargs tail is broad whatever feeds the pipe.
  assert_policy bpk-xargs-kill-all-dashdash $'deny\tbroad-process-kill' 'echo x | xargs kill -- -1'
  assert_policy bpk-xargs-kill-all-signal $'deny\tbroad-process-kill' 'echo x | xargs kill -9 -1'
  # The kill-all raw check stays bound to one simple command.
  assert_policy bpk-loop-kill-all-dashdash $'deny\tbroad-process-kill' 'while true; do kill -- -1; done'
  assert_policy bpk-for-kill-all-signal $'deny\tbroad-process-kill' 'for x in 1; do kill -9 -1; done'
  assert_policy bpk-if-kill-all-named $'deny\tbroad-process-kill' 'if true; then kill -s KILL -1; fi'

  # Caller-scoped kills - the safe forms the guard must NOT refuse - selecting by
  # parent, process group, or session, or by a specific pid the caller chose.
  assert_policy bpk-allow-parent allow 'pkill -P 12345'
  assert_policy bpk-allow-pgroup allow 'pkill -g 0'
  assert_policy bpk-allow-parent-long allow 'pkill --parent 12345 -f node'
  assert_policy bpk-allow-session allow 'pkill -s 4242'
  assert_policy bpk-allow-kill-parent-pgrep allow 'kill $(pgrep -P $$)'
  assert_policy bpk-allow-var-scoped allow 'p=$(pgrep -P $$); kill $p'
  assert_policy bpk-allow-pgrep-scoped-xargs allow 'pgrep -P $$ | xargs kill'
  assert_policy bpk-allow-pgrep-scoped-xargs-sep allow 'pgrep -P $$ | xargs -n 1 kill'
  assert_policy bpk-allow-literal-pid allow 'kill 76803'
  # A negative process-group target, a variable group, or -1 as the SIGHUP
  # signal spec are not the kill-all form.
  assert_policy bpk-allow-kill-pgroup-var allow 'kill -- -$pgid'
  assert_policy bpk-allow-kill-pgroup-literal allow 'kill -- -12345'
  assert_policy bpk-allow-kill-pgroup-attached allow 'kill -12345'
  assert_policy bpk-allow-kill-sighup-pid allow 'kill -1 1234'
  assert_policy bpk-allow-kill-plain-pid allow 'kill 1234'
  assert_policy bpk-allow-loop-kill-sighup-pid allow 'for x in 1; do kill -1 1234; done'
  assert_policy bpk-allow-loop-kill-pgroup allow 'for x in 1; do kill -- -$pgid; done'
  # A -1 argument to a later command in the same loop is not a kill-all target.
  assert_policy bpk-allow-wait-loop-tail allow 'while kill -0 "$pid" 2>/dev/null; do tail -1 "$log"; sleep 1; done'
  assert_policy bpk-allow-wait-loop-head allow 'until ! kill -0 $pid; do sleep 1; done; head -1 out.log'
  assert_policy bpk-allow-if-kill-git-log allow 'if kill -TERM $pid; then git log -1; fi'
  assert_policy bpk-allow-loop-kill-sleep allow 'for x in 1; do kill -9 $pid; sleep -1; done'
  # Negated safe forms stay allowed.
  assert_policy bpk-allow-negated-scoped-pkill allow '! pkill -P $$'
  assert_policy bpk-allow-negated-kill-probe allow '! kill -0 "$pid"'
  assert_policy bpk-allow-negated-pgrep allow '! pgrep -f node'
  assert_policy bpk-allow-negated-test allow '! test -f x'
  assert_policy bpk-allow-negated-time-sleep allow '! time sleep 1'
  assert_policy bpk-allow-negated-time-scoped-pkill allow '! time pkill -P $$'
  # Query and help forms of the kill tools execute no kill.
  assert_policy bpk-allow-command-v-pkill allow 'command -v pkill'
  assert_policy bpk-allow-command-v-pkill-redirected allow 'command -v pkill >/dev/null 2>&1'
  assert_policy bpk-allow-command-v-killall allow 'command -v killall'
  assert_policy bpk-allow-command-v-pgrep allow 'command -v pgrep'
  assert_policy bpk-allow-command-v-lsof allow 'command -v lsof'
  assert_policy bpk-allow-pkill-help allow 'pkill --help'
  assert_policy bpk-allow-pkill-version allow 'pkill -V'
  assert_policy bpk-allow-killall-list allow 'killall -l'
  assert_policy bpk-allow-if-command-v-pkill allow 'if command -v pkill >/dev/null 2>&1; then echo y; fi'
  assert_policy bpk-allow-if-command-v-killall allow 'if command -v killall; then :; fi'
  assert_policy bpk-allow-if-which-pkill allow 'if which pkill; then :; fi'
  assert_policy bpk-allow-if-pkill-help allow 'if true; then pkill --help; fi'
  assert_policy bpk-allow-xargs-kill-zero-probe allow 'pgrep -f node | xargs kill -0'
  assert_policy bpk-allow-xargs-n1-kill-zero-probe allow 'pgrep -f node | xargs -n1 kill -0'
  assert_policy bpk-allow-xargs-pkill-scoped allow 'echo node | xargs pkill -P $$'
  assert_policy bpk-allow-xargs-kill-signal-only allow 'echo 123 | xargs kill -TERM'
  assert_policy bpk-allow-xargs-kill-pgroup-var allow 'pgrep -P $$ | xargs kill -- -$pgid'
  assert_policy bpk-allow-literal-signal allow 'kill -9 "$pid"'
  assert_policy bpk-allow-parent-attached allow 'pkill -P12345'
  assert_policy bpk-allow-parent-attached-self allow 'pkill -P$$'
  assert_policy bpk-allow-parent-attached-var allow 'pkill -P$pid -f node'
  assert_policy bpk-allow-pgrep-attached-xargs allow 'pgrep -P$$ | xargs kill'
  assert_policy bpk-allow-kill-pgrep-attached allow 'kill $(pgrep -P$$)'
  assert_policy bpk-allow-loop-scoped-attached allow 'for p in $(pgrep -P$$); do kill $p; done'
  assert_policy bpk-allow-loop-scoped-quoted-value allow 'for p in $(pgrep -P "$$"); do kill $p; done'
  assert_policy bpk-allow-loop-pkill-quoted-value allow 'for x in 1; do pkill -P "$pid"; done'
  assert_policy bpk-allow-session-signal allow 'pkill -HUP -s 4242'
  # The scoped cleanup idiom inside loop grammar the classifier cannot model is
  # still recognized as scoped by the raw fallback and allowed.
  assert_policy bpk-allow-loop-scoped allow 'for p in $(pgrep -P $$); do kill $p; done'
  assert_policy bpk-allow-loop-scoped-pkill allow 'for x in 1; do pkill -P $$; done'
  # Caller-owned pid sources are not attribute-selection discovery.
  assert_policy bpk-allow-kill-pidfile allow 'kill $(cat pidfile)'
  assert_policy bpk-allow-echo-xargs allow 'echo 123 | xargs kill'
  assert_policy bpk-allow-cat-xargs allow 'cat pids | xargs kill'
  assert_policy bpk-allow-kill-jobs allow 'kill $(jobs -p)'
  # kill -0 sends no signal; it is a liveness probe.
  assert_policy bpk-allow-kill-zero-probe allow 'kill -0 $(pgrep -f "lavish-axi poll")'
  # Read-only discovery and quoted data are never kills.
  assert_policy bpk-allow-readonly-pgrep allow 'pgrep -f "lavish-axi poll" | head'
  assert_policy bpk-allow-ps-grep allow 'ps aux | grep node'
  assert_policy bpk-allow-lsof-readonly allow 'lsof -i :3000'
  assert_policy bpk-allow-fuser-readonly allow 'fuser 3000/tcp'
  assert_policy bpk-allow-loop-ps-readonly allow 'while true; do ps aux | grep node; sleep 1; done'
  assert_policy bpk-allow-data-mention allow "echo 'pkill -f node'"
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

test_prefilter_is_strict_superset() {
  local rc
  # A command with no fm-watch substring is fast-allowed by the transport
  # prefilter without ever invoking the classifier.
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
  # The widened trigger set: a general broad process kill carries no fm-watch
  # bytes, so the prefilter must delegate on the pkill/killall/pgrep substrings
  # or it would fast-allow the very shape the classifier now denies.
  "$CHECK" --command 'pkill -f node' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a non-watcher pkill, not fast-allow it, got exit $rc"
  "$CHECK" --command 'killall node' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a killall, not fast-allow it, got exit $rc"
  "$CHECK" --command 'kill $(pgrep -f node)' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill fed by an unscoped pgrep, not fast-allow it, got exit $rc"
  # Discovery by ps/lsof/pidof/fuser and the xargs pipe tail carry none of the
  # pkill/killall/pgrep bytes, so they are their own trigger substrings.
  "$CHECK" --command 'kill $(ps aux | grep node | awk '"'"'{print $2}'"'"')' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill fed by ps, not fast-allow it, got exit $rc"
  "$CHECK" --command 'lsof -ti :3000 | xargs kill -9' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill fed by lsof, not fast-allow it, got exit $rc"
  "$CHECK" --command 'kill $(pidof node)' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill fed by pidof, not fast-allow it, got exit $rc"
  "$CHECK" --command 'kill $(fuser 3000/tcp 2>/dev/null)' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill fed by fuser, not fast-allow it, got exit $rc"
  # A kill of pid -1 carries only the bare "kill" bytes, so "kill" itself is a
  # trigger substring rather than only pkill/killall.
  "$CHECK" --command 'kill -9 -1' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a kill of pid -1, not fast-allow it, got exit $rc"
  # Obfuscation across a quote split loses the literal pkill bytes; the prefilter
  # normalizes quotes first, so it still delegates and the classifier still denies.
  "$CHECK" --command 'pk"ill" -f node' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split pkill, not fast-allow it, got exit $rc"
  # A benign command that only mentions a trigger word as data still reaches the
  # classifier and is allowed there.
  "$CHECK" --command "echo 'run pgrep then kill by hand'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign pgrep-substring data command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: only trigger-free commands fast-allow; every fm-watch, broad-kill, and quoting-decoder-marker command reaches the classifier"
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
test_broad_process_kill_contract
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
