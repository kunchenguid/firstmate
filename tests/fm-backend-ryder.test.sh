#!/usr/bin/env bash
# tests/fm-backend-ryder.test.sh - tests for the Ryder session-provider adapter
# (bin/backends/ryder.sh), verified against a real protocol-v1 `ryder` binary
# (docs/ryder-backend.md).
#
# Unlike every other backend, this is ONE file rather than a mocked suite plus a
# separate real-binary smoke test. The split exists for herdr, zellij, and cmux
# because their real backends are shared, long-lived servers or GUI apps, so a
# real-binary test has to be quarantined behind its own safety helper and can
# never be the default path. Ryder has no shared instance at all: `RYDER_HOME`
# relocates the entire registry, and each session is its own detached process,
# so the real-host half runs in a throwaway home that cannot see, touch, or be
# seen by a real fleet. Keeping both halves together means the structural
# expectations and the behaviour they stand in for cannot drift apart.
#
# Structural half: a LOG-based canned-response fake `ryder` plus real `jq` (jq
# is a real required tool for this backend, not faked), mirroring
# tests/fm-backend-cmux.test.sh's fakebin/command-log convention. It pins the
# argv the adapter builds and the branches a real host cannot be made to
# produce on demand.
#
# Real-host half: drives the actual binary end to end. Skips cleanly when
# `ryder` is not installed, so machines without it are unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the ryder adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-ryder-tests)

# make_ryder_fakebin: a `ryder` stub that logs every invocation (one line,
# unit-separated args, to $FM_RYDER_LOG) and returns the canned response for
# that call from $FM_RYDER_RESPONSES/<n>.out, consumed IN ORDER, with an
# optional <n>.exit. A missing response file means "succeed with empty stdout".
# `--version` is handled specially and is neither call-counted nor consuming
# the ordered queue, since the version gate runs at points a test may not want
# to hand-count - exactly mirroring the cmux fake's `version`/`ping` handling.
make_ryder_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ryder" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_RYDER_LOG:?}"
RESP="${FM_RYDER_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'ryder'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_RYDER_FAKE_VERSION:-ryder 0.1.0 (protocol v1)}"
  exit 0
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
if [ -f "$RESP/$next.exit" ]; then
  exit "$(cat "$RESP/$next.exit")"
fi
exit 0
SH
  chmod +x "$fb/ryder"
  printf '%s' "$fb"
}

# new_case: a fresh adapter environment - own fake-CLI response queue, own log,
# own FM_ROOT (so the derived home-scoped session id is stable per case).
new_case() {  # <name>
  # Declared separately: stock macOS bash 3.2 refuses to reference an earlier
  # name from the same `local` statement under `set -u`.
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses" "$dir/home"
  : > "$dir/log"
  export FM_RYDER_LOG="$dir/log"
  export FM_RYDER_RESPONSES="$dir/responses"
  export FM_ROOT_OVERRIDE="$dir/home"
  local fakebin
  fakebin=$(make_ryder_fakebin "$dir")
  export PATH="$fakebin:$PATH_ORIG"
  unset _FM_BACKEND_RYDER_SOURCED
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source ryder
}

respond() {  # <n> <body>
  printf '%s' "$2" > "$FM_RYDER_RESPONSES/$1.out"
}

respond_fail() {  # <n> <body> <exit>
  printf '%s' "$2" > "$FM_RYDER_RESPONSES/$1.out"
  printf '%s' "$3" > "$FM_RYDER_RESPONSES/$1.exit"
}

# log_has: does any logged invocation contain this exact unit-separated
# argument run? Pins argv without asserting on the adapter's source text.
log_has() {  # <arg>...
  local want=""
  for a in "$@"; do want="$want"$'\x1f'"$a"; done
  grep -qF "$want" "$FM_RYDER_LOG"
}

PATH_ORIG=$PATH
STATE_JSON_ALIVE='{"id":"s","alive":true,"agent_pid":10,"fg_pgrp":10,"fg_comm":"bash","fg_argv0":"/bin/bash","tty":"/dev/ttys999","cwd":"/w","label":"s","protocol":1}'

# --- target shape ------------------------------------------------------------

test_target_is_a_single_id_with_no_colon() {
  new_case target_shape
  local sid
  sid=$(fm_backend_ryder_session_id fm-task1)
  case "$sid" in
    *:*) fail "a ryder target must never contain a colon: $sid" ;;
  esac
  fm_backend_endpoint_atom_valid "$sid" \
    || fail "the derived session id must satisfy the endpoint alphabet: $sid"
  case "$sid" in
    fm-*-task1) ;;
    *) fail "the derived id must be the home-scoped label, got $sid" ;;
  esac
  pass "ryder: the endpoint target is one home-scoped session id, colon-free and endpoint-alphabet valid"
}

test_session_id_is_home_scoped() {
  new_case home_scope_a
  local a b
  a=$(fm_backend_ryder_session_id fm-same-task)
  new_case home_scope_b
  b=$(fm_backend_ryder_session_id fm-same-task)
  [ "$a" != "$b" ] \
    || fail "two firstmate homes derived the SAME ryder session id ($a); one machine-global RYDER_HOME would let them address each other's sessions"
  pass "ryder: two homes with the same task id derive different session ids"
}

test_target_valid_rejects_malformed() {
  new_case target_valid
  fm_backend_ryder_target_valid "" && fail "empty target must be refused"
  fm_backend_ryder_target_valid "a:b" && fail "a colon target must be refused"
  fm_backend_ryder_target_valid "a b" && fail "a spaced target must be refused"
  fm_backend_ryder_target_valid ".hidden" && fail "a leading-dot target must be refused"
  fm_backend_ryder_target_valid "$(printf 'a%.0s' $(seq 1 129))" && fail "an over-long target must be refused"
  fm_backend_ryder_target_valid "fm-home-task_1.2@x%y+z-w" \
    || fail "the host's full id alphabet must be accepted"
  pass "ryder: target validation matches the host's own id rules"
}

test_target_ready_checks_label_without_a_cli_call() {
  new_case target_ready
  local sid
  sid=$(fm_backend_ryder_session_id fm-task1)
  fm_backend_ryder_target_ready "$sid" fm-task1 \
    || fail "a target derived from its own label must be ready"
  fm_backend_ryder_target_ready "$sid" fm-other-task \
    && fail "a target that does not derive from the expected label must be refused"
  [ ! -s "$FM_RYDER_LOG" ] \
    || fail "target_ready must be a pure check - it invoked the CLI: $(cat "$FM_RYDER_LOG")"
  pass "ryder: target_ready confirms label identity with no CLI round trip"
}

# --- create_task -------------------------------------------------------------

test_create_task_argv_and_env_scrub() {
  new_case create_argv
  respond_fail 1 '{"error":{"code":"no_such_session"},"ok":false}' 3   # the liveness pre-check
  respond 2 '{"id":"x"}'                                              # the create itself
  local sid
  sid=$(fm_backend_ryder_create_task fm-task1 /some/dir claude) || fail "create_task failed"
  [ "$sid" = "$(fm_backend_ryder_session_id fm-task1)" ] \
    || fail "create_task must echo the derived session id, got $sid"
  log_has create --id "$sid" --label "$sid" --cwd /some/dir || fail "create argv wrong: $(cat "$FM_RYDER_LOG")"
  log_has --harness claude || fail "the declared harness must reach the host"
  # Inherited harness markers must be scrubbed, or a worker spawned from inside
  # an agent session silently inherits its parent's child-process markers.
  log_has --env-remove CLAUDE_CODE_CHILD_SESSION || fail "CLAUDE_CODE_CHILD_SESSION must be removed"
  log_has --env-remove CLAUDECODE || fail "CLAUDECODE must be removed"
  log_has --env-remove PI_CODING_AGENT || fail "PI_CODING_AGENT must be removed"
  log_has --env-remove FM_PI_HARNESS || fail "FM_PI_HARNESS must be removed"
  log_has --env-remove GROK_AGENT || fail "GROK_AGENT must be removed"
  # Every ryder flag must precede `--`; everything after it is the agent's argv.
  local line sep_seen=0 flag_after=0 a
  line=$(grep -F "$(printf '\x1f')create" "$FM_RYDER_LOG" | tail -1)
  while IFS= read -r a; do
    [ "$a" = "--" ] && { sep_seen=1; continue; }
    if [ "$sep_seen" = 1 ]; then
      case "$a" in --json|--harness|--label|--cwd|--id|--env-remove) flag_after=1 ;; esac
    fi
    # Octal, not \x1f: BSD tr does not understand hex escapes and would
    # silently pass the line through unsplit.
  done < <(printf '%s' "$line" | tr '\037' '\n')
  [ "$sep_seen" = 1 ] || fail "create must pass a -- separator before the agent argv"
  [ "$flag_after" = 0 ] || fail "a ryder flag appeared AFTER --, where it would reach the agent instead"
  pass "ryder: create_task builds host-correct argv, scrubs inherited harness markers, and keeps flags before --"
}

test_create_task_refuses_a_live_duplicate() {
  new_case create_dup
  respond 1 "$STATE_JSON_ALIVE"   # the liveness pre-check finds a live session
  local out
  out=$(fm_backend_ryder_create_task fm-task1 /some/dir 2>&1) && fail "a live duplicate must be refused"
  case "$out" in
    *"already exists"*) ;;
    *) fail "the duplicate refusal must name the collision, got: $out" ;;
  esac
  log_has create && fail "create must not run once a live duplicate is found"
  pass "ryder: create_task refuses a label whose session is already live"
}

# --- liveness ----------------------------------------------------------------

test_agent_state_missing_on_absent_and_dead_sessions() {
  new_case state_missing
  respond_fail 1 '{"error":{"code":"no_such_session","message":"no session s"},"ok":false}' 3
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = missing ] || fail "no_such_session must map to missing"
  new_case state_dead_dir
  respond_fail 1 '{"error":{"code":"session_dead","message":"not running"},"ok":false}' 3
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = missing ] || fail "session_dead must map to missing"
  pass "ryder: an authoritatively absent endpoint maps to missing"
}

test_agent_state_unreadable_never_licenses_recovery() {
  # Only dead and missing license recovery, so a transient read must not be
  # either: an io error and a malformed target both have to stay unreadable.
  new_case state_io
  respond_fail 1 '{"error":{"code":"io","message":"socket blew up"},"ok":false}' 1
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = unreadable ] || fail "an io error must map to unreadable"
  new_case state_garbage
  respond_fail 1 'not json at all' 1
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = unreadable ] || fail "an unparseable reply must map to unreadable"
  new_case state_malformed
  [ "$(fm_backend_ryder_agent_state 'a:b')" = unreadable ] || fail "a malformed target must map to unreadable"
  # The SUCCEEDING-call variants of the same hazard: the CLI exits zero but the
  # body is unparseable, empty, or carries no `.alive` at all. None of the three
  # is the host answering that the agent is gone, so none may reach `dead`.
  new_case state_ok_garbage
  respond 1 'not json at all'
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = unreadable ] \
    || fail "a zero-exit reply with an unparseable body must map to unreadable, never dead"
  new_case state_ok_empty
  respond 1 ''
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = unreadable ] \
    || fail "a zero-exit reply with an empty body must map to unreadable, never dead"
  new_case state_ok_no_alive
  respond 1 '{"id":"s","fg_comm":"bash","tty":"/dev/ttys999"}'
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = unreadable ] \
    || fail "a zero-exit reply carrying no .alive field must map to unreadable, never dead"
  pass "ryder: a transient or unparseable read stays unreadable, never dead or missing"
}

test_busy_state_unknown_on_an_unreadable_reply() {
  # The same reply shapes through busy_state, which shares the one `.alive`
  # reader, so the two verdicts cannot disagree about the same body.
  new_case busy_ok_garbage
  respond 1 'not json at all'
  [ "$(fm_backend_ryder_busy_state fm-h-t)" = unknown ] \
    || fail "a zero-exit reply with an unparseable body must leave busy_state unknown"
  new_case busy_ok_no_alive
  respond 1 '{"id":"s","fg_comm":"cargo","fg_argv0":"/usr/bin/cargo","tty":"/dev/ttys999","fg_pgrp":10}'
  [ "$(fm_backend_ryder_busy_state fm-h-t)" = unknown ] \
    || fail "a reply carrying no .alive field must leave busy_state unknown, never busy"
  pass "ryder: busy_state stays unknown on a reply whose liveness cannot be read"
}

test_agent_state_dead_when_the_agent_is_gone() {
  new_case state_agent_exited
  respond 1 '{"id":"s","alive":false,"exited":{"code":0},"fg_comm":null,"tty":null,"fg_pgrp":null}'
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = dead ] \
    || fail "alive:false is the host's exact answer about the AGENT and must map to dead"
  pass "ryder: alive:false maps to dead while the host still answers"
}

test_agent_state_classifies_the_foreground() {
  new_case state_shell
  respond 1 "$STATE_JSON_ALIVE"
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = dead ] \
    || fail "a shell-only foreground is confidently agent-free"
  new_case state_agent
  respond 1 '{"id":"s","alive":true,"fg_pgrp":10,"fg_comm":"claude","fg_argv0":"/opt/x/claude","tty":"/dev/ttys999"}'
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = alive ] || fail "a harness foreground must be alive"
  new_case state_versioned
  # Claude Code's native installer names the executable by version, so the
  # basename identifies nothing and only the install path does.
  respond 1 '{"id":"s","alive":true,"fg_pgrp":10,"fg_comm":"2.1.224","fg_argv0":"/u/.local/share/claude/versions/2.1.224","tty":"/dev/ttys999"}'
  [ "$(fm_backend_ryder_agent_state fm-h-t)" = alive ] \
    || fail "a version-named harness executable must still be recognized by its install path"
  pass "ryder: the foreground identity separates a harness from an idle shell"
}

test_agent_state_ambiguous_never_collapses_to_dead() {
  # The safety property this backend's design turns on: firstmate runs the
  # harness inside a login shell, so the foreground can be a third process that
  # is neither. Calling that dead would license recovery - a duplicate agent on
  # a live worktree.
  new_case state_other
  local other_state='{"id":"s","alive":true,"fg_pgrp":10,"fg_comm":"cargo","fg_argv0":"/usr/bin/cargo","tty":"/dev/ttys999"}'
  respond 1 "$other_state"
  respond 2 "$other_state"   # the three-state view below reads the state again
  local got
  got=$(fm_backend_ryder_agent_state fm-h-t)
  [ "$got" = ambiguous ] || fail "an unattributable foreground must be ambiguous, got $got"
  case "$(fm_backend_agent_alive ryder fm-h-t)" in
    unknown) ;;
    *) fail "ambiguous must not surface as a recovery-licensing verdict" ;;
  esac
  pass "ryder: an unattributable foreground stays ambiguous and never licenses recovery"
}

test_busy_state_is_honest() {
  new_case busy_other
  respond 1 '{"id":"s","alive":true,"agent_pid":10,"fg_pgrp":77,"fg_comm":"cargo","fg_argv0":"/usr/bin/cargo","tty":"/dev/ttys999"}'
  [ "$(fm_backend_ryder_busy_state fm-h-t)" = busy ] || fail "a concrete foreground command proves busy"
  # A harness in the foreground is the regression that matters: it is a
  # foreground CHILD of the session's login shell for the whole life of a task,
  # so any rule keyed on "the foreground is not the agent's own pid" reports
  # busy forever. Identity, not pid comparison, is what keeps this honest.
  new_case busy_harness
  respond 1 '{"id":"s","alive":true,"agent_pid":10,"fg_pgrp":77,"fg_comm":"claude","fg_argv0":"/opt/x/claude","tty":"/dev/ttys999"}'
  [ "$(fm_backend_ryder_busy_state fm-h-t)" = unknown ] \
    || fail "a harness at its prompt and mid-turn are indistinguishable by process identity; busy_state must say unknown"
  new_case busy_dead
  respond 1 '{"id":"s","alive":false}'
  [ "$(fm_backend_ryder_busy_state fm-h-t)" = unknown ] || fail "a session with no agent has no busy answer"
  pass "ryder: busy_state proves busy or says unknown, and never claims idle"
}

# --- composer ----------------------------------------------------------------

# snapshot_reply: a host snapshot reply. cursor_line is VIEWPORT-relative, so
# the cursor's index in .text is scrollback + cursor_line.
snapshot_reply() {  # <cursor_line> <scrollback> <line>...
  local cl=$1 sb=$2
  shift 2
  local text=""
  for l in "$@"; do text="$text$l"$'\n'; done
  printf '%s' "$text" | jq -Rs --argjson cl "$cl" --argjson sb "$sb" \
    '{text: ., cols: 120, rows: 40, cursor_line: $cl, cursor_col: 0, alt_screen: false, scrollback: $sb, seq: 1}'
}

test_composer_empty_pending_and_unknown() {
  new_case composer_empty
  respond 1 "$(snapshot_reply 0 0 '❯ ')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = empty ] || fail "a bare agent prompt is an empty composer"
  new_case composer_pending
  respond 1 "$(snapshot_reply 0 0 '❯ some typed text')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = pending ] || fail "real typed text is pending"
  new_case composer_bordered
  respond 1 "$(snapshot_reply 0 0 '│ hello │')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = pending ] || fail "a bordered row with text is pending"
  new_case composer_none
  respond 1 "$(snapshot_reply 0 0 'just some output' 'and more')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = unknown ] || fail "no composer row must be unknown"
  new_case composer_read_fail
  respond_fail 1 '{"error":{"code":"session_dead"},"ok":false}' 3
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = unknown ] || fail "an unreadable session must be unknown"
  pass "ryder: composer rows classify as empty, pending, or unknown"
}

test_composer_dead_shell_prompt_is_never_empty() {
  # The fleet-wide safety rule bin/fm-composer-lib.sh exists to hold: a bare
  # shell prompt is what a pane shows once its agent has EXITED, and reading it
  # as an empty agent composer means an away-mode escalation gets typed into -
  # and possibly run by - that shell.
  new_case composer_shell
  local g
  for g in '>' '$' '%' '#'; do
    new_case "composer_shell_$(printf '%s' "$g" | od -An -tx1 | tr -d ' ')"
    respond 1 "$(snapshot_reply 0 0 "$g ")"
    [ "$(fm_backend_ryder_composer_state fm-h-t)" != empty ] \
      || fail "a bare '$g' shell prompt must never classify as an empty agent composer"
  done
  pass "ryder: a bare dead-shell prompt is never a safe injection target"
}

test_composer_strips_ghost_text_via_the_style_channel() {
  # The reason the ANSI snapshot is used at all. In plain text this row reads
  # as unsubmitted input; only the style channel shows it is a placeholder.
  new_case composer_ghost
  respond 1 "$(snapshot_reply 0 0 "$(printf '\033[0;1m›\033[0m \033[0;2mWrite tests for @filename\033[0m')")"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = empty ] \
    || fail "a dim ghost placeholder must read as an empty composer, not as typed text"
  new_case composer_ghost_real
  respond 1 "$(snapshot_reply 0 0 "$(printf '\033[0;1m›\033[0m \033[0mREAL TYPED TEXT\033[0m')")"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = pending ] \
    || fail "normal-intensity text on the same row shape must stay pending"
  pass "ryder: the style channel separates a harness placeholder from real typed text"
}

test_composer_uses_the_cursor_row_with_the_scrollback_offset() {
  # cursor_line is viewport-relative while .text carries scrollback above it,
  # so the cursor's text index is scrollback + cursor_line. Getting this wrong
  # classifies a different row. Here the two candidate rows disagree, so only
  # the correct offset produces the correct verdict.
  new_case composer_cursor_offset
  respond 1 "$(snapshot_reply 1 2 '❯ stale scrollback row' 'noise' '❯ ' 'trailing noise')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = empty ] \
    || fail "the cursor row (index scrollback+cursor_line = 3) is the empty composer; a wrong offset would read the stale row as pending"
  new_case composer_cursor_offset_pending
  respond 1 "$(snapshot_reply 1 2 '❯ ' 'noise' '❯ live typed text' 'trailing noise')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = pending ] \
    || fail "the same offset must find typed text on the cursor row"
  pass "ryder: the composer row is anchored at scrollback + cursor_line, not at cursor_line"
}

test_composer_falls_back_to_the_bottom_most_row() {
  # When the cursor is not on a composer shape, the bottom-most match wins, so
  # a decorative box earlier on screen can never outrank the live composer.
  new_case composer_bottom_most
  # The cursor (index 1) is parked on a plain row, so it carries no shape and
  # the fallback decides. The banner above is a genuine bordered shape, so only
  # bottom-most-wins keeps the live composer below it from being outranked.
  respond 1 "$(snapshot_reply 1 0 '│ stale banner text │' 'noise' '❯ ')"
  [ "$(fm_backend_ryder_composer_state fm-h-t)" = empty ] \
    || fail "the bottom-most composer row must outrank an earlier decorative box"
  pass "ryder: with no composer under the cursor, the bottom-most row wins"
}

# --- submit ------------------------------------------------------------------

test_send_text_submit_retries_enter_without_retyping() {
  new_case submit_retry
  respond 1 ''                                                  # write --literal
  respond 2 ''                                                  # key Enter (swallowed)
  respond 3 "$(snapshot_reply 0 0 '❯ my message')"              # still pending
  respond 4 ''                                                  # key Enter (lands)
  respond 5 "$(snapshot_reply 0 0 '❯ ')"                        # empty
  local verdict
  verdict=$(fm_backend_ryder_send_text_submit "$(fm_backend_ryder_session_id fm-t)" "my message" 3 0 0 fm-t)
  [ "$verdict" = empty ] || fail "a landed submit must report empty, got $verdict"
  local writes
  writes=$(grep -cF "$(printf '\x1f')write" "$FM_RYDER_LOG")
  [ "$writes" = 1 ] \
    || fail "text must be typed exactly ONCE - retyping a swallowed Enter's text duplicates it; saw $writes writes"
  pass "ryder: submit retries Enter only and never retypes the message"
}

test_send_text_submit_reports_a_swallowed_enter() {
  new_case submit_swallowed
  respond 1 ''
  respond 2 ''
  respond 3 "$(snapshot_reply 0 0 '❯ my message')"
  respond 4 ''
  respond 5 "$(snapshot_reply 0 0 '❯ my message')"
  local verdict
  verdict=$(fm_backend_ryder_send_text_submit "$(fm_backend_ryder_session_id fm-t)" "my message" 2 0 0 fm-t)
  [ "$verdict" = pending ] \
    || fail "an unconfirmed submit must stay pending so the caller does not treat it as delivered, got $verdict"
  pass "ryder: an unconfirmed submit reports pending rather than claiming delivery"
}

test_send_text_submit_send_failed_when_the_write_fails() {
  new_case submit_send_failed
  respond_fail 1 '{"error":{"code":"session_dead"},"ok":false}' 3
  local verdict
  verdict=$(fm_backend_ryder_send_text_submit "$(fm_backend_ryder_session_id fm-t)" "msg" 2 0 0 fm-t)
  [ "$verdict" = send-failed ] || fail "a failed write must report send-failed, got $verdict"
  pass "ryder: a failed write reports send-failed"
}

# --- capture, keys, kill, list_live -----------------------------------------

test_capture_is_a_tmux_capture_pane_drop_in() {
  new_case capture
  # `lines` is scrollback ABOVE the viewport, exactly as `tmux capture-pane -p
  # -S -N` means it, so the reply is legitimately longer than `lines`. The
  # herdr and cmux adapters `tail -n` their captures to work around their own
  # CLIs returning less than requested; doing that here would hand callers less
  # than the tmux path gives them, so the reply must pass through whole.
  respond 1 "$(snapshot_reply 0 0 'r1' 'r2' 'r3' 'r4' 'r5')"
  local out
  out=$(fm_backend_ryder_capture "$(fm_backend_ryder_session_id fm-t)" 2 fm-t) || fail "capture failed"
  log_has snapshot "$(fm_backend_ryder_session_id fm-t)" --lines 2 --json \
    || fail "capture must pass the requested scrollback straight through: $(cat "$FM_RYDER_LOG")"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] \
    || fail "capture must not trim the reply to the requested line count, got: $out"
  case "$out" in
    r1*) ;;
    *) fail "capture must keep the whole reply, starting at its first row; got: $out" ;;
  esac
  pass "ryder: capture passes scrollback through and returns the host's reply untrimmed"
}

test_capture_fails_when_the_session_is_gone() {
  new_case capture_fail
  respond_fail 1 '{"error":{"code":"session_dead"},"ok":false}' 3
  fm_backend_ryder_capture "$(fm_backend_ryder_session_id fm-t)" 5 fm-t && fail "capture must fail on a dead session"
  pass "ryder: capture fails rather than returning empty content for a dead session"
}

test_send_key_normalizes_the_shared_vocabulary() {
  new_case send_key
  local sid
  sid=$(fm_backend_ryder_session_id fm-t)
  fm_backend_ryder_send_key "$sid" Enter fm-t
  fm_backend_ryder_send_key "$sid" Escape fm-t
  fm_backend_ryder_send_key "$sid" C-c fm-t
  log_has key "$sid" Enter || fail "Enter must reach the host"
  log_has key "$sid" Escape || fail "Escape must reach the host"
  log_has key "$sid" C-c || fail "C-c must reach the host"
  [ "$(fm_backend_ryder_normalize_key ctrl-c)" = C-c ] || fail "ctrl-c must normalize to C-c"
  [ "$(fm_backend_ryder_normalize_key esc)" = Escape ] || fail "esc must normalize to Escape"
  pass "ryder: firstmate's key vocabulary normalizes onto the host's key names"
}

test_send_literal_does_not_submit() {
  new_case send_literal
  local sid
  sid=$(fm_backend_ryder_session_id fm-t)
  fm_backend_ryder_send_literal "$sid" "some --json shaped text" fm-t
  log_has write "$sid" --literal "some --json shaped text" \
    || fail "literal text must reach the host unchanged as --literal's value: $(cat "$FM_RYDER_LOG")"
  log_has key "$sid" Enter && fail "send_literal must not submit"
  pass "ryder: send_literal writes unsubmitted bytes, even for option-shaped text"
}

test_kill_refuses_malformed_targets_before_invoking_the_cli() {
  new_case kill_guard
  fm_backend_ryder_kill "" && fail "an empty kill target must be refused"
  fm_backend_ryder_kill "a:b" && fail "a malformed kill target must be refused"
  fm_backend_ryder_kill "$(fm_backend_ryder_session_id fm-t)" "" fm-other && fail "a label mismatch must be refused"
  [ ! -s "$FM_RYDER_LOG" ] \
    || fail "a refused kill must never reach the CLI: $(cat "$FM_RYDER_LOG")"
  pass "ryder: kill refuses empty, malformed, and label-mismatched targets before invoking the CLI"
}

test_kill_is_best_effort() {
  new_case kill_best_effort
  respond_fail 1 '{"error":{"code":"no_such_session"},"ok":false}' 3
  fm_backend_ryder_kill "$(fm_backend_ryder_session_id fm-t)" "" fm-t \
    || fail "an already-gone target is not an error for kill"
  pass "ryder: kill treats an already-gone session as success"
}

test_list_live_is_home_scoped_and_alive_only() {
  new_case list_live
  local mine other
  mine=$(fm_backend_ryder_session_id fm-mine)
  other=$(FM_ROOT_OVERRIDE="$TMP_ROOT/list_live/otherhome" bash -c \
    "mkdir -p '$TMP_ROOT/list_live/otherhome'; . '$ROOT/bin/fm-backend.sh'; fm_backend_source ryder; fm_backend_ryder_session_id fm-theirs")
  respond 1 "$(jq -n --arg mine "$mine" --arg other "$other" '{sessions:[
      {id:$mine, alive:true, label:$mine},
      {id:($mine + "-dead"), alive:false, label:($mine + "-dead")},
      {id:$other, alive:true, label:$other},
      {id:"handmade-session", alive:true, label:"handmade-session"}
    ], archived:[]}')"
  local out
  out=$(fm_backend_ryder_list_live)
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] \
    || fail "list_live must report exactly this home's one live task, got: $out"
  [ "$out" = "$mine	fm-mine" ] \
    || fail "list_live must emit '<session-id>\\tfm-<task-id>', got: $out"
  pass "ryder: list_live reports only this home's live task sessions, in the shared recovery shape"
}

# --- registration and dispatch ----------------------------------------------

test_registration_and_dispatch() {
  new_case registration
  fm_backend_is_known ryder || fail "ryder must be a known backend"
  fm_backend_validate_spawn ryder || fail "ryder must be spawn-capable"
  [ "$(fm_backend_required_tools ryder)" = "ryder jq treehouse" ] \
    || fail "ryder requires its own CLI, jq, and the treehouse worktree provider"
  fm_backend_has_push ryder \
    && fail "ryder ships PULL-ONLY, so the watcher's poll loop stays the backstop"
  pass "ryder: registered, spawn-capable, pull-only, and declaring its own tool delta"
}

test_detection_order_is_innermost_first() {
  new_case detection
  local d
  d=$(env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID RYDER_SESSION_ID=s \
    bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_detect")
  [ "$d" = ryder ] || fail "RYDER_SESSION_ID alone must select ryder, got $d"
  # The host strips an inherited TMUX, so a $TMUX seen inside a ryder session
  # is always a real tmux started in it.
  d=$(env -u HERDR_ENV -u CMUX_WORKSPACE_ID TMUX=/x RYDER_SESSION_ID=s \
    bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_detect")
  [ "$d" = tmux ] || fail "tmux must win over ryder, got $d"
  d=$(env -u TMUX -u CMUX_WORKSPACE_ID HERDR_ENV=1 RYDER_SESSION_ID=s \
    bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_detect")
  [ "$d" = herdr ] || fail "herdr keeps its existing verdict, so no working home's detection changes, got $d"
  d=$(env -u TMUX -u HERDR_ENV CMUX_WORKSPACE_ID=w RYDER_SESSION_ID=s \
    bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_detect")
  [ "$d" = ryder ] || fail "ryder is a session host nested inside a terminal app, so it wins over cmux, got $d"
  pass "ryder: runtime detection resolves innermost-first against every other backend marker"
}

test_endpoint_validation_binds_the_task() {
  new_case endpoint_validation
  local state="$TMP_ROOT/endpoint_validation/state"
  mkdir -p "$state"
  local sid
  sid=$(fm_backend_ryder_session_id fm-task1)
  {
    echo "backend=ryder"
    echo "window=$sid"
    echo "endpoint_task_id=task1"
    echo "worktree=/w"
    echo "project=p"
  } > "$state/task1.meta"
  fm_backend_validate_task_endpoint "$state/task1.meta" task1 \
    || fail "a well-formed ryder endpoint record must validate"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$sid" ] || fail "the validated target must be the session id"
  # Metadata belonging to another task must never be accepted for this one.
  sed -i.bak 's/^endpoint_task_id=.*/endpoint_task_id=othertask/' "$state/task1.meta"
  fm_backend_validate_task_endpoint "$state/task1.meta" task1 2>/dev/null \
    && fail "endpoint metadata bound to another task must be refused"
  sed -i.bak 's/^endpoint_task_id=.*/endpoint_task_id=task1/' "$state/task1.meta"
  sed -i.bak 's/^window=.*/window=bad:target/' "$state/task1.meta"
  fm_backend_validate_task_endpoint "$state/task1.meta" task1 2>/dev/null \
    && fail "a malformed ryder target must be refused"
  pass "ryder: cleanup identity validation binds the exact task and refuses a malformed target"
}

test_secondmate_spawn_refuses_ryder_backend() {
  local out
  out=$("$ROOT/bin/fm-spawn.sh" ryder-sm-test "$TMP_ROOT" --backend ryder --secondmate 2>&1 || true)
  case "$out" in
    *"backend=ryder does not support --secondmate spawns yet"*) ;;
    *) fail "a --secondmate spawn on backend=ryder must refuse; got: $out" ;;
  esac
  pass "ryder: --secondmate spawns are refused until their semantics are verified"
}

# --- real host ---------------------------------------------------------------
#
# Everything above stands in for a real host. This drives the actual binary in a
# throwaway RYDER_HOME so the structural expectations cannot quietly diverge
# from what the host really does.

test_real_host_end_to_end() {
  export PATH=$PATH_ORIG
  command -v ryder >/dev/null 2>&1 || {
    echo "skip: ryder not on PATH - the real-host half of the ryder suite needs the session host binary (docs/ryder-backend.md 'Setup')"
    return 0
  }
  local home="$TMP_ROOT/realhome" rh
  # Session sockets live at $RYDER_HOME/v1/sessions/<id>/sock and are bounded
  # by the platform's ~104-byte sun_path limit, so the throwaway home must be
  # SHORT. $TMPDIR is not: on macOS it is a ~50-byte per-user folder, which
  # alone pushes a home-scoped session id over the limit. /tmp is short and
  # present on every platform this backend is verified on.
  rh=$(mktemp -d /tmp/fmry.XXXXXX) || { echo "skip: could not make a short RYDER_HOME"; return 0; }
  mkdir -p "$home"
  export RYDER_HOME="$rh" FM_ROOT_OVERRIDE="$home"
  unset _FM_BACKEND_RYDER_SOURCED FM_RYDER_LOG FM_RYDER_RESPONSES
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source ryder

  fm_backend_ryder_version_check 2>/dev/null || {
    echo "skip: installed ryder does not speak the protocol version this adapter was verified against"
    rm -rf "$rh"
    return 0
  }

  local label=fm-realtest sid sock
  sid=$(fm_backend_ryder_session_id "$label")
  sock="$RYDER_HOME/v1/sessions/$sid/sock"
  # Skip rather than fail when this machine's paths cannot fit a socket: that
  # is the documented platform limit, not an adapter defect.
  if [ "${#sock}" -gt 100 ]; then
    echo "skip: '$sock' is ${#sock} bytes, over the ~104-byte unix socket limit (docs/ryder-backend.md 'Active limits')"
    rm -rf "$rh"
    return 0
  fi
  sid=$(fm_backend_ryder_create_task "$label" /tmp) || fail "real create_task failed"
  # shellcheck disable=SC2064 # $sid/$rh are intentionally expanded now.
  trap "ryder kill '$sid' >/dev/null 2>&1 || true; rm -rf '$rh'" RETURN

  [ "$sid" = "$(fm_backend_ryder_session_id "$label")" ] || fail "real target must be the derived id"
  fm_backend_target_exists ryder "$sid" "$label" || fail "a freshly created session must exist"
  fm_backend_target_exists ryder "$sid" fm-wrong-label && fail "a mismatched label must not resolve"
  fm_backend_target_exists ryder "fm-absent-session-xyz" && fail "an absent session must not exist"

  # A shell-only session is confidently agent-free; an absent one is missing.
  [ "$(fm_backend_agent_state ryder "$sid")" = dead ] || fail "a real shell-only session must be dead"
  [ "$(fm_backend_agent_state ryder fm-absent-session-xyz)" = missing ] || fail "a real absent session must be missing"

  # cwd live-tracks the foreground process, which is why this backend needs no
  # pwd-marker probe.
  fm_backend_ryder_send_text_line "$sid" "cd /usr/local" "$label" || fail "send_text_line failed"
  local i=0 cwd=""
  while [ "$i" -lt 40 ]; do
    cwd=$(fm_backend_ryder_current_path "$sid" "$label")
    [ "$cwd" = /usr/local ] && break
    sleep 0.25
    i=$((i + 1))
  done
  [ "$cwd" = /usr/local ] || fail "real current_path must follow a live cd, got '$cwd'"

  # Literal text does not submit; a named Enter does.
  fm_backend_ryder_send_literal "$sid" "echo FM_RYDER_REAL_MARKER" "$label" || fail "send_literal failed"
  sleep 0.5
  local cap
  cap=$(fm_backend_ryder_capture "$sid" 0 "$label") || fail "real capture failed"
  case "$cap" in
    *FM_RYDER_REAL_MARKER*) ;;
    *) fail "typed text must appear on the real screen" ;;
  esac
  printf '%s\n' "$cap" | grep -qx 'FM_RYDER_REAL_MARKER' \
    && fail "send_literal must not auto-submit on the real host"
  fm_backend_ryder_send_key "$sid" Enter "$label" || fail "send_key failed"
  i=0
  while [ "$i" -lt 40 ]; do
    fm_backend_ryder_capture "$sid" 0 "$label" | grep -qx 'FM_RYDER_REAL_MARKER' && break
    sleep 0.25
    i=$((i + 1))
  done
  fm_backend_ryder_capture "$sid" 0 "$label" | grep -qx 'FM_RYDER_REAL_MARKER' \
    || fail "a named Enter must submit on the real host"

  # Recovery discovery finds the session by its derived, home-scoped id.
  fm_backend_ryder_list_live | grep -qx "$sid	$label" \
    || fail "real list_live must report the live task: $(fm_backend_ryder_list_live)"

  fm_backend_kill ryder "$sid" "" "$label" || fail "real kill failed"
  i=0
  while [ "$i" -lt 40 ]; do
    [ "$(fm_backend_agent_state ryder "$sid")" = missing ] && break
    sleep 0.25
    i=$((i + 1))
  done
  [ "$(fm_backend_agent_state ryder "$sid")" = missing ] || fail "a killed session must become missing"
  fm_backend_ryder_list_live | grep -q "$label" && fail "a killed session must leave list_live"

  pass "real ryder: create, capture, unsubmitted send, keyed submit, live cwd, liveness, recovery, and kill"
}

test_target_is_a_single_id_with_no_colon
test_session_id_is_home_scoped
test_target_valid_rejects_malformed
test_target_ready_checks_label_without_a_cli_call
test_create_task_argv_and_env_scrub
test_create_task_refuses_a_live_duplicate
test_agent_state_missing_on_absent_and_dead_sessions
test_agent_state_unreadable_never_licenses_recovery
test_agent_state_dead_when_the_agent_is_gone
test_agent_state_classifies_the_foreground
test_agent_state_ambiguous_never_collapses_to_dead
test_busy_state_is_honest
test_busy_state_unknown_on_an_unreadable_reply
test_composer_empty_pending_and_unknown
test_composer_dead_shell_prompt_is_never_empty
test_composer_strips_ghost_text_via_the_style_channel
test_composer_uses_the_cursor_row_with_the_scrollback_offset
test_composer_falls_back_to_the_bottom_most_row
test_send_text_submit_retries_enter_without_retyping
test_send_text_submit_reports_a_swallowed_enter
test_send_text_submit_send_failed_when_the_write_fails
test_capture_is_a_tmux_capture_pane_drop_in
test_capture_fails_when_the_session_is_gone
test_send_key_normalizes_the_shared_vocabulary
test_send_literal_does_not_submit
test_kill_refuses_malformed_targets_before_invoking_the_cli
test_kill_is_best_effort
test_list_live_is_home_scoped_and_alive_only
test_registration_and_dispatch
test_detection_order_is_innermost_first
test_endpoint_validation_binds_the_task
test_secondmate_spawn_refuses_ryder_backend
test_real_host_end_to_end
