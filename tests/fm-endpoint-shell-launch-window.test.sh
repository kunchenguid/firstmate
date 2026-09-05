#!/usr/bin/env bash
# tests/fm-endpoint-shell-launch-window.test.sh - spawn-path regression for the
# endpoint-shell marker's launch window (task fm-endpoint-shell-backends).
#
# The marker is a PS1 assignment firstmate plants on the task pane's own shell,
# and a BARE marked prompt is the fleet-wide proof that the agent exited
# (bin/fm-busy-lib.sh's `dead endpoint-shell`). A healthy endpoint that is
# merely still launching must not look like that.
#
# The property asserted here is NOT "zero bare marked prompts": the marker is
# planted on a line of its own (chaining it onto the launch command would be a
# parse error on a non-POSIX pane shell and would stop the agent launching at
# all), so the pane necessarily draws one bare marked prompt when that line
# completes. What must hold is that this prompt appears ONLY immediately
# before the launch text, with no pre-launch command sent after it - so the
# window is bounded by two adjacent sends instead of by the whole pre-launch
# sequence, and no bare marked prompt can linger across an export, a
# meta-lock wait, or a settle sleep. The residual race is real and accepted:
# a capture landing in the exact instant between those two sends still reads
# `dead endpoint-shell` for a live endpoint.
#
# This drives the REAL bin/fm-spawn.sh against a fake `zellij` CLI that
# simulates the pane's shell (a PS1, an input buffer, a rendered screen), snaps
# the screen after every draw with the pane event that caused it, and then
# classifies every one of those snapshots through the real fm_busy_classify.
# Nothing here reads spawn's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-shell-launch-window)
SNAP_SEP='---fm-snapshot---'

# A fake `zellij` that is a small pane simulator, not just a command log. It
# keeps the pane's PS1, its unsubmitted paste buffer, and its rendered rows in
# $FM_FAKE_ZJ_STATE, and appends the whole screen to `snapshots` every time the
# screen changes - which is what lets the assertions below ask "was there EVER
# a moment during this spawn when the pane read as a dead endpoint shell?".
#
# The simulated shell models exactly the three behaviors that matter here:
# a submitted line echoes behind the current prompt, a leading `PS1='...'`
# assignment changes the prompt from then on, and a command that starts the
# harness keeps the shell busy so no new prompt is drawn (every other command
# returns and the shell draws its prompt again).
make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_ZJ_STATE:?}"
SEP="${FM_FAKE_ZJ_SNAP_SEP:?}"

# Every snapshot is paired with the pane event that produced it, so the
# assertions can say WHERE in the send order a screen appeared, not just that
# it appeared: "echo <line>" for a submitted line landing at the prompt,
# "prompt" for the shell drawing its prompt again, "output" for command output.
snapshot() {  # <event>
  printf '%s\n' "$1" >> "$S/events"
  { cat "$S/screen"; printf '%s\n' "$SEP"; } >> "$S/snapshots"
}

draw_prompt() { printf '%s\n' "$(cat "$S/ps1")" >> "$S/screen"; snapshot prompt; }

commit_line() {
  local line ps1 rest
  line=$(cat "$S/pending"); : > "$S/pending"
  ps1=$(cat "$S/ps1")
  printf '%s%s\n' "$ps1" "$line" >> "$S/screen"
  snapshot "echo $line"
  rest=$line
  # A leading PS1 assignment takes effect for every later prompt, exactly as a
  # real shell applies it; the rest of the line still runs.
  if [[ $rest == PS1=\'*\'* ]]; then
    ps1=${rest#PS1=\'}
    ps1=${ps1%%\'*}
    printf '%s' "$ps1" > "$S/ps1"
    rest=${rest#PS1=\'*\'}
    rest=${rest#;}
    rest=${rest# }
  fi
  case "$rest" in
    *__FM_ZELLIJ_CWD_BEGIN__*)
      printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n' \
        "${FM_FAKE_PANE_PATH:-/}" >> "$S/screen"
      snapshot output
      ;;
  esac
  case "$rest" in
    *"${FM_FAKE_ZJ_LAUNCH_MATCH:-__never__}"*)
      # The harness is now the shell's foreground job: no prompt is drawn
      # again until it exits.
      printf '1\n' > "$S/launched"
      return 0
      ;;
  esac
  draw_prompt
}

case "${1:-}" in
  --version) printf 'zellij %s\n' "${FM_FAKE_ZJ_VERSION:-0.44.0}"; exit 0 ;;
  list-sessions) [ -f "$S/session" ] && cat "$S/session"; exit 0 ;;
  attach) printf '%s\n' "${3:-}" > "$S/session"; exit 0 ;;
esac

# `zellij --session <name> action <subcommand> ...`
[ "${1:-}" = --session ] || exit 0
shift 2
[ "${1:-}" = action ] || exit 0
shift
sub=${1:-}
shift
case "$sub" in
  list-tabs)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | to_entries | map({tab_id: (.value[0]|tonumber), name: .value[1], active: (.key == 0)})'
    ;;
  new-tab)
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=${2:-}; shift 2 ;;
        --cwd) shift 2 ;;
        *) shift ;;
      esac
    done
    id=$(( $(cat "$S/nextid" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$id" > "$S/nextid"
    printf '%s\t%s\n' "$id" "$name" >> "$S/tabs"
    printf '%s\n' "$id"
    ;;
  list-panes)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | map({id: (.[0]|tonumber), tab_id: (.[0]|tonumber), is_plugin: false})'
    ;;
  paste)
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
    shift
    printf '%s' "${1:-}" >> "$S/pending"
    ;;
  send-keys)
    key=
    while [ $# -gt 0 ]; do
      case "$1" in
        --pane-id) shift 2 ;;
        *) key=$1; shift ;;
      esac
    done
    pending=$(cat "$S/pending")
    # Failure injection, modelling the real adapter's rc=2 path: while the
    # pane's uncommitted input matches FM_FAKE_ZJ_SUBMIT_FAIL_ON, neither the
    # Enter submit nor the clearing Ctrl-c lands, so send_text_line returns 2
    # with the pasted text still sitting on the input line.
    if [ -n "${FM_FAKE_ZJ_SUBMIT_FAIL_ON:-}" ] && [ -n "$pending" ]; then
      case "$pending" in
        *"$FM_FAKE_ZJ_SUBMIT_FAIL_ON"*)
          # FM_FAKE_ZJ_SUBMIT_FAIL_COUNT bounds how many submit/clear attempts
          # fail (0 = never recovers). A bounded count models a TRANSIENT
          # glitch: the marker send still returns 2 with its text stranded on
          # the input line, but keys work again afterwards - which is what lets
          # a launch pasted on top of that residue actually get submitted.
          budget=${FM_FAKE_ZJ_SUBMIT_FAIL_COUNT:-0}
          used=$(cat "$S/submitfails" 2>/dev/null || echo 0)
          if [ "$budget" -eq 0 ] || [ "$used" -lt "$budget" ]; then
            case "$key" in
              Enter|'Ctrl c') printf '%s\n' "$((used + 1))" > "$S/submitfails"; exit 1 ;;
            esac
          fi
          case "$key" in
            'Ctrl u') [ "${FM_FAKE_ZJ_CLEAR_FAIL:-0}" = 1 ] && exit 1 ;;
          esac
          ;;
      esac
    fi
    case "$key" in
      Enter) commit_line ;;
      # Ctrl-u discards the uncommitted input line, exactly as a shell does.
      'Ctrl u') : > "$S/pending" ;;
    esac
    ;;
  # A capture shows the pane's committed rows plus, when the input line holds
  # uncommitted pasted text, that live row too - which is how residue left by
  # a failed send is visible to a reader at all. With FM_FAKE_ZJ_WIDTH set the
  # dump is folded at that width, exactly as a terminal grid wraps a long line
  # across several rows and dumps them one per line.
  dump-screen)
    {
      cat "$S/screen"
      pending=$(cat "$S/pending")
      [ -z "$pending" ] || printf '%s%s\n' "$(cat "$S/ps1")" "$pending"
    } | if [ -n "${FM_FAKE_ZJ_WIDTH:-}" ]; then
          # Wrap like a terminal grid: split any row wider than the pane. The
          # adapter's own cwd-probe markers are passed through whole, because
          # wrapping those would break worktree discovery rather than model a
          # narrow pane.
          awk -v w="$FM_FAKE_ZJ_WIDTH" '
            index($0, "__FM_ZELLIJ_CWD_") { print; next }
            { while (length($0) > w) { print substr($0, 1, w); $0 = substr($0, w + 1) } print }
          '
        else cat; fi \
      | if [ "${FM_FAKE_ZJ_TRIM_ROWS:-0}" = 1 ]; then sed 's/[[:space:]]*$//'; else cat; fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/zellij"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# Run one real spawn onto the simulated zellij pane. Echoes the state dir the
# simulator wrote (screen, ps1, snapshots).
run_zellij_spawn() {  # <name> -> echoes sim-state dir
  local name=$1 case_dir home proj wt fakebin sim id prompt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sim="$case_dir/sim"
  fakebin=$(make_zellij_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$sim"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'zellij\n' > "$home/config/backend"
  touch "$home/state/.last-watcher-beat"
  # Trace context ON on purpose: it makes spawn send an `export TRACEPARENT=`
  # line (and take the meta lock) in the pre-launch sequence. Without a
  # pre-launch send after the marker line there is nothing for a lingering
  # bare marked prompt to linger ACROSS, and the assertion below would hold
  # for any placement of the marker line.
  : > "$home/config/trace-context"
  printf '%s\n' "$$" > "$home/state/.lock"
  FM_TRACE_CONTEXT=on FM_CONFIG_OVERRIDE="$home/config" \
    fm_trace_context_session_start "$home/config" "$home/state/.trace-context-effective"
  : > "$sim/tabs"; : > "$sim/pending"; : > "$sim/screen"; : > "$sim/snapshots"
  : > "$sim/events"
  printf 'fm-sim-%s\n' "$name" > "$sim/session"
  prompt=${FM_FAKE_ZJ_PROMPT:-}
  [ -n "$prompt" ] || prompt='captain@ship:~$ '
  printf '%s' "$prompt" > "$sim/ps1"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  env -u TMUX FM_TRACE_CONTEXT=on \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_ZELLIJ_SESSION="fm-sim-$name" \
    FM_FAKE_ZJ_STATE="$sim" FM_FAKE_ZJ_SNAP_SEP="$SNAP_SEP" \
    FM_FAKE_ZJ_LAUNCH_MATCH='--dangerously-skip-permissions' \
    FM_FAKE_ZJ_SUBMIT_FAIL_ON="${FM_FAKE_ZJ_SUBMIT_FAIL_ON:-}" \
    FM_FAKE_ZJ_SUBMIT_FAIL_COUNT="${FM_FAKE_ZJ_SUBMIT_FAIL_COUNT:-0}" \
    FM_FAKE_ZJ_CLEAR_FAIL="${FM_FAKE_ZJ_CLEAR_FAIL:-0}" \
    FM_FAKE_ZJ_WIDTH="${FM_FAKE_ZJ_WIDTH:-}" \
    FM_FAKE_ZJ_TRIM_ROWS="${FM_FAKE_ZJ_TRIM_ROWS:-0}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --backend zellij --mode no-mistakes --yolo off \
    > "$case_dir/spawn.out" 2>&1 || true
  cp "$case_dir/spawn.out" "$sim/spawn.out"
  printf '%s\n' "$sim"
}

# Every line the pane actually submitted, in order, as the simulator committed
# them - the record of what the shell was really asked to run.
committed_lines() {  # <sim-dir>
  sed -n 's/^echo //p' "$1/events"
}

# Classify one captured screen exactly as a concurrent supervisor would: no
# busy record for the task yet (the pane is still launching), so classification
# falls through to the endpoint-shell arm.
classify_screen() {  # <state-dir> <screen>
  fm_busy_classify zellij "sim:1" claude sim-task "$1" "$2"
}

test_marked_prompt_appears_only_immediately_before_the_launch_text() {
  local sim state snap line n=0 verdict launched
  local -a verdicts=() events=()
  sim=$(run_zellij_spawn launchwindow)
  state="$sim/norecord"
  mkdir -p "$state"

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" = 1 ] \
    || fail "the fixture never reached the launch command; the simulated spawn did not run to launch"
  [ -s "$sim/snapshots" ] || fail "the simulated pane recorded no screen at all"

  while IFS= read -r line; do events+=("$line"); done < "$sim/events"

  snap=
  while IFS= read -r line; do
    if [ "$line" = "$SNAP_SEP" ]; then
      verdict=$(classify_screen "$state" "$snap")
      verdicts+=("$verdict")
      n=$((n + 1))
      snap=
      continue
    fi
    snap="$snap$line"$'\n'
  done < "$sim/snapshots"

  [ "$n" -gt 2 ] || fail "expected the simulated pane to be drawn repeatedly during spawn, saw only $n screens"
  [ "${#events[@]}" -eq "$n" ] \
    || fail "the simulator recorded ${#events[@]} events for $n screens; they must pair one to one"

  # The launch text is the last thing the pane is sent, so its echo is the last
  # screen. Every screen before it must be safe EXCEPT the one immediately
  # preceding it, which is the accepted residual window described above.
  local last=$((n - 1)) i launch_line first_word
  case "${events[$last]}" in
    "echo "*--dangerously-skip-permissions*) : ;;
    *) fail "expected the final screen to be the launch text landing, got event '${events[$last]}'" ;;
  esac

  # The launch text the pane actually receives must stay a plain command. A
  # leading `NAME=value` is a PARSE error on a pane shell that is not
  # POSIX-compatible (fish, nushell), and those shells reject the whole input
  # line on a parse error - so chaining the marker onto the launch command
  # would not merely lose the marker, it would stop the agent from launching.
  # A `NAME=value` further along (the harness template's own env prefix after
  # `env`) is an argument, not an assignment, and is fine.
  launch_line=${events[$last]#echo }
  first_word=${launch_line%% *}
  case "$first_word" in
    *=*) fail "the launch text begins with the assignment '$first_word'; a non-POSIX pane shell rejects the whole line and never starts the agent" ;;
  esac
  case "$launch_line" in
    *"$FM_COMPOSER_ENDPOINT_SHELL_MARKER"*)
      fail "the endpoint-shell marker rode along on the launch text; it must arrive as a line of its own"
      ;;
  esac

  i=0
  while [ "$i" -lt "$last" ]; do
    if [ "${verdicts[$i]}" = "dead endpoint-shell" ]; then
      [ "$i" -eq $((last - 1)) ] \
        || fail "screen #$((i + 1)) (event '${events[$i]}') read as a dead endpoint shell, but only the screen immediately before the launch text may: a bare marked prompt must never linger across another pre-launch send"
      [ "${events[$i]}" = prompt ] \
        || fail "the one permitted dead-reading screen must be the shell drawing its marked prompt, got event '${events[$i]}'"
    fi
    i=$((i + 1))
  done

  # ... and nothing sent after the marker line may be a pre-launch command:
  # the marker line and the launch text must be adjacent in the send order.
  case "${events[$((last - 1))]}" in
    prompt|"echo PS1="*) : ;;
    *) fail "a pre-launch command was sent between the marker line and the launch text (event '${events[$((last - 1))]}'); the window must be bounded by two adjacent sends" ;;
  esac

  pass "the bare marked prompt appears only immediately before the launch text, never lingering across another pre-launch send ($n screens)"
}

# The companion half: the marker must still MEAN what it meant. The PS1 line
# lands before the launch text, so by the time the harness is running the
# pane's prompt is the marked one - and the first prompt it draws after the
# harness exits is the bare marked prompt the recovery path reads as dead.
test_marker_still_proves_a_dead_endpoint_shell_after_the_agent_exits() {
  local sim state ps1 screen verdict
  sim=$(run_zellij_spawn afterexit)
  state="$sim/norecord"
  mkdir -p "$state"

  ps1=$(cat "$sim/ps1")
  [ "$ps1" = "$FM_COMPOSER_ENDPOINT_SHELL_MARKER " ] \
    || fail "after launch the pane's prompt must be the endpoint-shell marker, got '$ps1'"

  # The harness exits: that same shell prints its own prompt again.
  screen=$(cat "$sim/screen")$'\n'"$ps1"
  verdict=$(classify_screen "$state" "$screen")
  [ "$verdict" = "dead endpoint-shell" ] \
    || fail "the prompt the pane draws after the agent exits must classify dead endpoint-shell, got '$verdict'"
  pass "the marker still proves a dead endpoint shell once the agent exits"
}

# rc=2 from the marker send is the one outcome that is NOT "the marker simply
# did not take": the text was pasted and neither the Enter submit nor the
# clearing Ctrl-c landed, so it is still sitting uncommitted on the pane's
# input line. Pasting the launch command on top of that residue would submit
# one concatenated line and the agent would never start. Spawn must either
# clear the line and prove it clean before continuing, or refuse outright -
# never silently corrupt the launch.
test_marker_send_residue_is_cleared_before_the_launch_text() {
  local sim launched line
  # Two failed attempts (the Enter submit and the clearing Ctrl-c of the marker
  # send), then keys work again - a transient glitch, so anything pasted onto
  # the stranded residue really would be submitted.
  sim=$(FM_FAKE_ZJ_SUBMIT_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    FM_FAKE_ZJ_SUBMIT_FAIL_COUNT=2 run_zellij_spawn markerresidue)

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" = 1 ] \
    || fail "spawn cleared the residue but never launched; recovery must proceed to the launch:"$'\n'"$(cat "$sim/spawn.out")"

  while IFS= read -r line; do
    case "$line" in
      *"$FM_COMPOSER_ENDPOINT_SHELL_MARKER"*--dangerously-skip-permissions*)
        fail "the launch text was submitted concatenated onto the marker residue: $line"
        ;;
    esac
  done < <(committed_lines "$sim")
  pass "a marker send that leaves residue is cleared before the launch text, never pasted over"
}

# Same failure, but now nothing can clear the line either. Spawn must refuse
# rather than launch onto a line whose contents it cannot confirm.
test_unclearable_marker_residue_refuses_the_launch() {
  local sim launched line out
  sim=$(FM_FAKE_ZJ_SUBMIT_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" FM_FAKE_ZJ_CLEAR_FAIL=1 \
    run_zellij_spawn markerstuck)

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" != 1 ] \
    || fail "spawn launched onto a pane whose input line could not be confirmed clean"

  while IFS= read -r line; do
    case "$line" in
      *--dangerously-skip-permissions*)
        fail "the launch text was submitted despite unclearable residue: $line"
        ;;
    esac
  done < <(committed_lines "$sim")

  out=$(cat "$sim/spawn.out")
  case "$out" in
    *"refusing to send the launch command"*) : ;;
    *) fail "the refusal must name its cause on stderr, got:"$'\n'"$out" ;;
  esac
  pass "an unclearable marker residue refuses the launch with a named cause instead of corrupting it"
}

# The same unclearable residue, but in a NARROW pane, so the terminal wraps the
# stranded input line across two grid rows and no single captured row contains
# the whole marker text. Checking only the bottom row reads that as clean and
# pastes the launch command onto the residue - the exact silent corruption the
# rc=2 branch exists to prevent - so the check must reassemble the wrapped line
# before deciding.
test_wrapped_marker_residue_is_still_detected_and_refuses_the_launch() {
  local sim launched line out
  # The prompt plus the marker line is wider than the pane, so the stranded
  # input line necessarily occupies two rows.
  sim=$(FM_FAKE_ZJ_SUBMIT_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    FM_FAKE_ZJ_SUBMIT_FAIL_COUNT=2 FM_FAKE_ZJ_CLEAR_FAIL=1 FM_FAKE_ZJ_WIDTH=40 \
    run_zellij_spawn markerwrapped)

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" != 1 ] \
    || fail "spawn launched onto a wrapped residue it failed to detect"

  while IFS= read -r line; do
    case "$line" in
      *--dangerously-skip-permissions*)
        fail "the launch text was submitted despite wrapped residue on the input line: $line"
        ;;
    esac
  done < <(committed_lines "$sim")

  out=$(cat "$sim/spawn.out")
  case "$out" in
    *"refusing to send the launch command"*) : ;;
    *) fail "a wrapped residue must refuse with a named cause, got:"$'\n'"$out" ;;
  esac
  pass "residue wrapped across two rows of a narrow pane is still detected and refuses the launch"
}

# The worst wrap: the residue's single space lands exactly ON the wrap column,
# and the capture emits each grid row only up to its last non-blank cell - so
# that genuinely-typed space is eaten as if it were row padding and is absent
# from BOTH captured rows. Rejoining the rows, however carefully, cannot
# recover a character the capture never emitted, so the check has to consider
# that a boundary space may have been swallowed. The 15-column prompt puts the
# residue's space in column 40 of a 40-column pane, which is exactly that case.
test_residue_space_eaten_at_the_wrap_column_is_still_detected() {
  local sim launched line out
  sim=$(FM_FAKE_ZJ_SUBMIT_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    FM_FAKE_ZJ_SUBMIT_FAIL_COUNT=2 FM_FAKE_ZJ_CLEAR_FAIL=1 \
    FM_FAKE_ZJ_WIDTH=40 FM_FAKE_ZJ_TRIM_ROWS=1 FM_FAKE_ZJ_PROMPT='captain@ship:~$' \
    run_zellij_spawn markerboundary)

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" != 1 ] \
    || fail "spawn launched onto residue whose wrap-boundary space the capture had eaten"

  while IFS= read -r line; do
    case "$line" in
      *--dangerously-skip-permissions*)
        fail "the launch text was submitted despite residue split at its own space: $line"
        ;;
    esac
  done < <(committed_lines "$sim")

  out=$(cat "$sim/spawn.out")
  case "$out" in
    *"refusing to send the launch command"*) : ;;
    *) fail "a residue split at its own space must refuse with a named cause, got:"$'\n'"$out" ;;
  esac
  pass "residue whose space is eaten at the wrap column is still detected and refuses the launch"
}

# The same eaten space, but now the residue spans THREE captured rows: a
# 13-column prompt in a 19-column pane puts the residue's only space in the
# last cell of the MIDDLE row, so a right-trimming capture drops it and the
# window has two boundaries rather than one. Any scheme that repairs boundaries
# by enumerating them gets this wrong - at most one boundary is the missing
# space, and repairing the other corrupts what the first restored - so the
# check has to be indifferent to whitespace entirely.
test_residue_wrapped_across_three_rows_is_still_detected() {
  local sim launched line out
  sim=$(FM_FAKE_ZJ_SUBMIT_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    FM_FAKE_ZJ_SUBMIT_FAIL_COUNT=2 FM_FAKE_ZJ_CLEAR_FAIL=1 \
    FM_FAKE_ZJ_WIDTH=19 FM_FAKE_ZJ_TRIM_ROWS=1 FM_FAKE_ZJ_PROMPT='cap@ship:~/p$' \
    run_zellij_spawn markerthreerow)

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" != 1 ] \
    || fail "spawn launched onto residue wrapped across three rows with its space eaten"

  while IFS= read -r line; do
    case "$line" in
      *--dangerously-skip-permissions*)
        fail "the launch text was submitted despite three-row wrapped residue: $line"
        ;;
    esac
  done < <(committed_lines "$sim")

  out=$(cat "$sim/spawn.out")
  case "$out" in
    *"refusing to send the launch command"*) : ;;
    *) fail "a three-row wrapped residue must refuse with a named cause, got:"$'\n'"$out" ;;
  esac
  pass "residue wrapped across three rows with its space eaten is still detected and refuses the launch"
}


# A send status of 2 means "pasted but not committed" ONLY on a backend that
# sends text in two phases (zellij, cmux). Orca sends and submits in ONE call
# (`terminal send --enter`), and its 2 comes from its JSON helper rejecting a
# malformed or `ok:false` response - an API-level failure where nothing was
# typed into the terminal at all. Reading that as stranded residue would abort
# a spawn whose pane is perfectly clean, leaving a registered task with a live
# worktree and no agent. The correct reading is the ordinary one: the marker is
# absent, which every reader treats as undetermined, and the launch proceeds.
make_orca_fakebin() {  # <dir> <worktree-path> -> echoes fakebin dir
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/orca" <<SH
#!/usr/bin/env bash
set -u
WT='$2'
SH
  cat >> "$fakebin/orca" <<'SH'
LOG="${FM_FAKE_ORCA_LOG:?}"
{ printf 'orca'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
text=
prev=
for a in "$@"; do
  [ "$prev" = --text ] && text=$a
  prev=$a
done
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  "repo show")   printf '{"ok":false,"error":{"message":"no such repo"}}\n'; exit 1 ;;
  "repo add")    printf '{"ok":true,"result":{"repo":{"id":"repo-1"}}}\n' ;;
  "worktree create")
    printf '{"ok":true,"result":{"worktree":{"id":"wt-1","path":"%s"},"terminal":{"handle":"term-1"}}}\n' "$WT" ;;
  "terminal read")
    printf '{"ok":true,"result":{"terminal":{"tail":["all quiet"]}}}\n' ;;
  "terminal send")
    # The one injected failure: Orca rejects the marker send at the API level,
    # so nothing reached the terminal and fm_backend_orca_send_text_line
    # returns 2.
    if [ -n "${FM_FAKE_ORCA_SEND_FAIL_ON:-}" ]; then
      case "$text" in
        *"$FM_FAKE_ORCA_SEND_FAIL_ON"*)
          printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n'
          exit 0 ;;
      esac
    fi
    printf '{"ok":true}\n'
    printf '%s\n' "$text" >> "$LOG.sent" ;;
  *) printf '{"ok":true}\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/orca"
  fm_fake_exit0 "$fakebin" treehouse claude tmux
  printf '%s\n' "$fakebin"
}

test_single_call_backend_send_failure_does_not_refuse_the_launch() {
  command -v node >/dev/null 2>&1 || { pass "orca marker-send skipped without node"; return; }
  local case_dir home proj wt fakebin log id out status
  case_dir="$TMP_ROOT/orcamarkerfail"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  log="$case_dir/orca.log"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-orcamarkerfail"
  fakebin=$(make_orca_fakebin "$case_dir/fake" "$wt")
  : > "$log"
  id="orcamarkerfail1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  out=$( env -u TMUX FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_ORCA_LOG="$log" \
    FM_FAKE_ORCA_SEND_FAIL_ON="$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude --backend orca --mode no-mistakes --yolo off 2>&1 )
  status=$?

  case "$out" in
    *"refusing to send the launch command"*)
      fail "an Orca send failure - where nothing was typed into the terminal at all - was read as stranded residue and aborted the spawn:"$'\n'"$out"
      ;;
  esac
  [ "$status" -eq 0 ] || fail "spawn must carry on when the marker send fails on a single-call backend, exited $status:"$'\n'"$out"
  assert_contains "$(cat "$log.sent" 2>/dev/null || true)" '--dangerously-skip-permissions' \
    "the harness launch command was never sent after a failed marker send"
  assert_contains "$(cat "$log")" "$FM_COMPOSER_ENDPOINT_SHELL_MARKER" \
    "the fixture never attempted the marker send, so nothing was exercised"
  rm -rf "/tmp/fm-$id"
  pass "a marker send that fails on a single-call backend leaves the marker absent and still launches the agent"
}

test_marked_prompt_appears_only_immediately_before_the_launch_text
test_marker_still_proves_a_dead_endpoint_shell_after_the_agent_exits
test_marker_send_residue_is_cleared_before_the_launch_text
test_unclearable_marker_residue_refuses_the_launch
test_wrapped_marker_residue_is_still_detected_and_refuses_the_launch
test_residue_space_eaten_at_the_wrap_column_is_still_detected
test_residue_wrapped_across_three_rows_is_still_detected
test_single_call_backend_send_failure_does_not_refuse_the_launch
