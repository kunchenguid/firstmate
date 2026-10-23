#!/usr/bin/env bash
# Behavior tests for the main-session permission-prompt alarm
# (bin/fm-main-prompt-alarm.sh), driven through the tracked Claude
# PermissionRequest registration in .claude/settings.json.
#
# Every hook runs as a child of a fake harness (a bash symlink named "claude")
# whose pid is the home's session lock, from a git checkout that passes the
# primary-scope check, exactly as the primary's own hook runs. The fake stays
# alive until the delayed check has decided, because the check requires the
# same live lock holder. Alerts go to a recorder through the wedge-alarm test
# seam, never to a real notifier. The main pane is a fake tmux whose capture is
# a file. The payload is the shape Claude Code 2.1.306 sent for a hook "ask".
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-main-prompt-alarm)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR \
  TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND \
  FM_WEDGE_ALARM_CHANNEL FM_WEDGE_ALARM_EXEC

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) [ -f "${FM_TEST_PANE:-}" ] && cat "$FM_TEST_PANE" ;;
  *) exit 0 ;;
esac
SH
cat > "$FAKEBIN/recorder" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_TEST_ALERTS"
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/recorder"

# A primary checkout: git, AGENTS.md, and this repo's bin.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"

HOOK_CMD=$(jq -r '.hooks.PermissionRequest[].hooks[] | select(.command | contains("fm-main-prompt-alarm.sh")) | .command' \
  "$ROOT/.claude/settings.json")
[ -n "$HOOK_CMD" ] || fail "the tracked settings register no PermissionRequest hook for the alarm"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  : > "$home/alerts"
  : > "$home/transcript.jsonl"
  touch -t 202001010000 "$home/transcript.jsonl"
  printf '%s\n' "$home"
}

# The bottom of the main pane on a Claude permission prompt (Claude Code 2.1.306).
write_prompt_pane() {  # <file>
  printf '%s\n' \
    '────────────────────' \
    ' Bash command' \
    ' Echo the probe marker' \
    '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌' \
    ' echo fm-probe-ask-marker && echo second-line' \
    '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌' \
    ' │ Hook PreToolUse:Bash requires confirmation for this command:' \
    '' \
    ' Do you want to proceed?' \
    ' ❯ 1. Yes' \
    '   2. No' \
    '' \
    ' Esc to cancel · Tab to amend' > "$1"
}

payload() {  # <home> <command> [extra jq object]
  local extra=${3:-}
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg t "$1/transcript.jsonl" --arg c "$2" --argjson x "$extra" '{
    session_id: "s1", transcript_path: $t, cwd: "/tmp", permission_mode: "bypassPermissions",
    hook_event_name: "PermissionRequest", tool_name: "Bash",
    tool_input: {command: $c, description: "Echo the probe marker"}} + $x'
}

# Run <script> as the lock-owning primary session of <home>, with the alarm's
# delay, recorder, and fake pane wired in. Inside it, `fire <payload>` runs the
# tracked registration and appends the hook's stdout to $HOME_DIR/hook.out, and
# `settle` waits for the delayed check to alert or to log the prompt resolved.
as_session() {  # <home> <script> [env assignments...]
  local home=$1 script=$2
  shift 2
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" HOME_DIR="$home" PRIMARY_ROOT="$PRIMARY_ROOT" HOOK_CMD="$HOOK_CMD" \
    FM_TEST_ALERTS="$home/alerts" FM_WEDGE_ALARM_EXEC="$FAKEBIN/recorder" FM_WEDGE_ALARM_CHANNEL=command:unused \
    FM_MAIN_PROMPT_ALARM_SECS=1 "$@" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    fire() { printf "%s" "$1" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" bash -c "cd \"$PRIMARY_ROOT\" && $HOOK_CMD" >> "$HOME_DIR/hook.out"; }
    settle() {
      local i=0
      while [ "$i" -lt 100 ]; do
        { [ -s "$HOME_DIR/alerts" ] || grep -q "resolved: " "$FM_HOME/state/.main-permission-prompt.log" 2>/dev/null; } && return 0
        sleep 0.1; i=$((i + 1))
      done
      return 1
    }
    '"$script"
}

# The payload is staged in a file so the session script stays free of quoting.
run_case() {  # <home> <script> [env assignments...]
  local home=$1
  shift
  as_session "$home" "$@" || fail "the session for $(basename "$home") did not settle: $(cat "$home/state/.main-permission-prompt.log" 2>/dev/null)"
}

test_pending_prompt_alerts_once_and_never_decides() {
  local home alerts
  home=$(make_home pending)
  write_prompt_pane "$home/pane"
  payload "$home" $'echo fm-probe-ask-marker && echo second-line\necho third-line' > "$home/payload"
  run_case "$home" 'fire "$(cat "$HOME_DIR/payload")"; settle' \
    FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux FM_TEST_PANE="$home/pane"
  [ ! -s "$home/hook.out" ] || fail "the hook printed a decision: $(cat "$home/hook.out")"
  alerts=$(cat "$home/alerts")
  [ "$(printf '%s\n' "$alerts" | grep -c .)" -eq 1 ] || fail "a pending prompt should alert once, got: $alerts; log: $(cat "$home/state/.main-permission-prompt.log" 2>/dev/null)"
  case "$alerts" in
    "command|firstmate's main session has waited "*"s on a permission prompt for Bash: echo fm-probe-ask-marker && echo second-line; supervision is paused until it is answered") ;;
    *) fail "the alert did not name the tool and the command's first line: $alerts" ;;
  esac
  case "$alerts" in *unreadable*) fail "a readable pane was reported unreadable: $alerts" ;; esac
  grep -F 'alert: ' "$home/state/.main-permission-prompt.log" >/dev/null || fail "the alert was not logged"
  pass "a main-session prompt still on screen alerts once through the wedge-alarm channels, and the hook decides nothing"
}

test_answered_prompt_does_not_alert() {
  local home
  home=$(make_home answered)
  write_prompt_pane "$home/pane"
  payload "$home" 'echo fm-probe-ask-marker' > "$home/payload"
  run_case "$home" 'fire "$(cat "$HOME_DIR/payload")"; touch "$HOME_DIR/transcript.jsonl"; settle' \
    FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux FM_TEST_PANE="$home/pane"
  [ ! -s "$home/alerts" ] || fail "an answered prompt alerted: $(cat "$home/alerts")"
  grep -F 'resolved: the session moved on' "$home/state/.main-permission-prompt.log" >/dev/null \
    || fail "an answered prompt was not logged as resolved: $(cat "$home/state/.main-permission-prompt.log")"
  pass "a prompt whose session transcript moved on does not alert"
}

test_approved_command_still_running_does_not_alert() {
  local home
  home=$(make_home approved)
  printf '%s\n' '⏺ Bash(echo fm-probe-ask-marker && sleep 600)' '  ⎿  Running…' > "$home/pane"
  payload "$home" 'echo fm-probe-ask-marker && sleep 600' > "$home/payload"
  run_case "$home" 'fire "$(cat "$HOME_DIR/payload")"; settle' \
    FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux FM_TEST_PANE="$home/pane"
  [ ! -s "$home/alerts" ] || fail "an approved command still running alerted: $(cat "$home/alerts")"
  grep -F 'resolved: the main pane no longer shows the Bash prompt' "$home/state/.main-permission-prompt.log" >/dev/null \
    || fail "an approved command was not logged as resolved: $(cat "$home/state/.main-permission-prompt.log")"
  pass "an approved command still running, with an unchanged transcript, does not alert when the pane shows no prompt"
}

test_unreadable_pane_alerts_with_the_caveat() {
  local home alerts
  home=$(make_home unreadable)
  payload "$home" 'echo fm-probe-ask-marker' > "$home/payload"
  run_case "$home" 'fire "$(cat "$HOME_DIR/payload")"; settle'
  alerts=$(cat "$home/alerts")
  case "$alerts" in
    *'(main pane unreadable; an approved command still running looks the same)') ;;
    *) fail "an unreadable pane should alert on the transcript alone, with the caveat: $alerts" ;;
  esac
  pass "with no readable main pane the transcript decides alone, and the alert says so"
}

test_newer_prompt_supersedes_the_older_check() {
  local home alerts
  home=$(make_home superseded)
  write_prompt_pane "$home/pane"
  payload "$home" 'echo first-prompt' > "$home/payload"
  payload "$home" 'echo second-prompt' > "$home/payload2"
  run_case "$home" 'fire "$(cat "$HOME_DIR/payload")"; fire "$(cat "$HOME_DIR/payload2")"; settle; sleep 1.5' \
    FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux FM_TEST_PANE="$home/pane"
  alerts=$(cat "$home/alerts")
  [ "$(printf '%s\n' "$alerts" | grep -c .)" -eq 1 ] || fail "two prompts in a row should alert once, got: $alerts"
  case "$alerts" in *'echo second-prompt;'*) ;; *) fail "the alert should name the newer prompt: $alerts" ;; esac
  pass "a newer prompt replaces the older one's record, so only the newer prompt's check alerts"
}

test_out_of_scope_sessions_record_nothing() {
  local home other linked before after
  # A session that does not hold the lock.
  home=$(make_home not-lock-owner)
  payload "$home" 'echo fm-probe-ask-marker' > "$home/payload"
  sleep 30 &
  other=$!
  as_session "$home" 'printf "%s\n" '"$other"' > "$FM_HOME/state/.lock"; fire "$(cat "$HOME_DIR/payload")"; sleep 1.5' || true
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ ! -e "$home/state/.main-permission-prompt" ] || fail "a session without the lock recorded a prompt"
  [ ! -s "$home/alerts" ] || fail "a session without the lock alerted: $(cat "$home/alerts")"
  # A Cursor payload, whose own registration owns the event.
  home=$(make_home cursor)
  payload "$home" 'echo fm-probe-ask-marker' '{"cursor_version":"x"}' > "$home/payload"
  as_session "$home" 'fire "$(cat "$HOME_DIR/payload")"; sleep 1.5' || true
  [ ! -e "$home/state/.main-permission-prompt" ] || fail "a Cursor payload recorded a prompt"
  # A linked task worktree of the primary is not the primary.
  home=$(make_home linked)
  git -C "$PRIMARY_ROOT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  linked="$TMP_ROOT/linked-wt"
  git -C "$PRIMARY_ROOT" worktree add -q --detach "$linked"
  : > "$linked/AGENTS.md"
  ln -s "$ROOT/bin" "$linked/bin"
  payload "$home" 'echo fm-probe-ask-marker' > "$home/payload"
  before=$(find "$home/state" -mindepth 1 ! -name .lock | LC_ALL=C sort)
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_MAIN_PROMPT_ALARM_SECS=1 FM_TEST_ALERTS="$home/alerts" \
    FM_WEDGE_ALARM_EXEC="$FAKEBIN/recorder" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$(cat "$1")" | env CLAUDE_PROJECT_DIR="$2" bash -c "cd \"$2\" && $3"
      sleep 1.5' _ "$home/payload" "$linked" "$HOOK_CMD" > "$home/hook.out" || true
  after=$(find "$home/state" -mindepth 1 ! -name .lock | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "a linked worktree's hook changed the home's state: $after"
  [ ! -s "$home/hook.out" ] || fail "a linked worktree's hook printed: $(cat "$home/hook.out")"
  # A second mate's home, which reaches the captain only through its parent.
  home=$(make_home secondmate)
  mkdir -p "$TMP_ROOT/mate-root"
  printf 'mate-1\n' > "$TMP_ROOT/mate-root/.fm-secondmate-home"
  : > "$TMP_ROOT/mate-root/AGENTS.md"
  ln -s "$ROOT/bin" "$TMP_ROOT/mate-root/bin"
  payload "$home" 'echo fm-probe-ask-marker' > "$home/payload"
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_MAIN_PROMPT_ALARM_SECS=1 FM_TEST_ALERTS="$home/alerts" \
    FM_WEDGE_ALARM_EXEC="$FAKEBIN/recorder" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$(cat "$1")" | env CLAUDE_PROJECT_DIR="$2" bash -c "cd \"$2\" && $3"
      sleep 1.5' _ "$home/payload" "$TMP_ROOT/mate-root" "$HOOK_CMD" > "$home/hook.out" || true
  [ ! -e "$home/state/.main-permission-prompt" ] || fail "a second mate's hook recorded a prompt"
  [ ! -s "$home/alerts" ] || fail "a second mate's hook alerted: $(cat "$home/alerts")"
  pass "a session without the lock, a Cursor payload, a linked worktree, and a second mate's home record and alert nothing"
}

test_pending_prompt_alerts_once_and_never_decides
test_answered_prompt_does_not_alert
test_approved_command_still_running_does_not_alert
test_unreadable_pane_alerts_with_the_caveat
test_newer_prompt_supersedes_the_older_check
test_out_of_scope_sessions_record_nothing
