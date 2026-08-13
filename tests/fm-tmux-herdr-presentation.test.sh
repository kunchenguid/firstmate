#!/usr/bin/env bash
# Portable regression for the optional native Herdr view of a tmux atelier
# task. Real tmux runs on a private named socket; a Herdr CLI fixture pins the
# documented protocol-19 command/response boundary without touching any live
# Herdr session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-herdr-presentation.XXXXXX")
SOCKET="fm-tmux-herdr-$$"
SESSION=atelier
ID=showcase
TARGET="tmux+$SOCKET/$SESSION:fm-$ID"
PROXY="fmh-$ID"

fail() { echo "not ok - $*" >&2; cleanup; exit 1; }
pass() { echo "ok - $*"; }
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

mkdir -p "$FIXTURE/bin" "$FIXTURE/home/config" "$FIXTURE/home/state" \
  "$FIXTURE/atelier/bin" "$FIXTURE/worktree" "$FIXTURE/project"
touch "$FIXTURE/atelier/bin/atelier"
chmod +x "$FIXTURE/atelier/bin/atelier"
HERDR_FAKE_LOG="$FIXTURE/herdr.log"
HERDR_FAKE_PRESENT="$FIXTURE/herdr-present"
HERDR_FAKE_WORKSPACE="$FIXTURE/herdr-workspace"
export HERDR_FAKE_LOG HERDR_FAKE_PRESENT HERDR_FAKE_WORKSPACE
export HERDR_FAKE_TASK="fm-$ID" HERDR_FAKE_PROXY="$PROXY"
export HERDR_FAKE_SOCKET="$SOCKET" HERDR_FAKE_PANE=w1:p1

cat > "$FIXTURE/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
argc=${#args[@]}
[ "$argc" -ge 3 ] || exit 2
penultimate=${args[$((argc - 2))]}
last=${args[$((argc - 1))]}
[ "$penultimate" = --session ] && [ "$last" = lab-view ] || exit 2
printf '%s\n' "$*" >> "$HERDR_FAKE_LOG"
case "${1:-} ${2:-}" in
  'status --json')
    [ "${HERDR_FAKE_DOWN:-0}" = 0 ] || exit 1
    printf '%s\n' '{"client":{"protocol":19},"server":{"running":true,"session":"lab-view","compatible":true,"protocol":19}}'
    ;;
  'pane list')
    if [ -e "$HERDR_FAKE_PRESENT" ]; then
      IFS=$'\t' read -r task proxy pane < "$HERDR_FAKE_PRESENT"
      jq -cn --arg task "$task" --arg proxy "$proxy" --arg pane "$pane" \
        '{result:{panes:[{pane_id:$pane,workspace_id:"w1",tokens:{task_id:$task,tmux_proxy:$proxy}}]}}'
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    ;;
  'workspace list')
    if [ -e "$HERDR_FAKE_WORKSPACE" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate-atelier","tokens":{"atelier_id":"firstmate-atelier"}}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[]}}'
    fi
    ;;
  'workspace create')
    jq -cn --arg pane "$HERDR_FAKE_PANE" \
      '{result:{workspace:{workspace_id:"w1"},tab:{tab_id:"w1:t1"},root_pane:{pane_id:$pane}}}'
    ;;
  'workspace report-metadata')
    case "$*" in *'--token atelier_id=firstmate-atelier'*) : > "$HERDR_FAKE_WORKSPACE" ;; esac
    printf '%s\n' '{"result":{"type":"workspace_metadata_reported"}}'
    ;;
  'tab rename')
    printf '%s\n' '{"result":{"type":"tab_info"}}'
    ;;
  'tab create')
    jq -cn --arg pane "$HERDR_FAKE_PANE" \
      '{result:{tab:{tab_id:"w1:t2"},root_pane:{pane_id:$pane}}}'
    ;;
  'pane report-metadata')
    case "$*" in
      *"--token task_id=$HERDR_FAKE_TASK"*)
        printf '%s\t%s\t%s\n' "$HERDR_FAKE_TASK" "$HERDR_FAKE_PROXY" "$HERDR_FAKE_PANE" > "$HERDR_FAKE_PRESENT"
        ;;
    esac
    printf '%s\n' '{"result":{"type":"pane_metadata_reported"}}'
    ;;
  'pane run')
    printf '%s\n' '{"result":{"type":"input_sent"}}'
    ;;
  'pane process-info')
    if [ "${HERDR_FAKE_PROCESS_MISMATCH:-0}" = 1 ]; then
      argv='["zsh"]'
    else
      argv=$(jq -cn --arg socket "$HERDR_FAKE_SOCKET" --arg proxy "$HERDR_FAKE_PROXY" \
        '["tmux","-L",$socket,"attach-session","-t",$proxy]')
    fi
    jq -cn --arg pane "$HERDR_FAKE_PANE" --argjson argv "$argv" \
      '{result:{process_info:{pane_id:$pane,foreground_processes:[{argv:$argv}]}}}'
    ;;
  'pane report-agent')
    printf '%s\n' '{"result":{"type":"agent_reported"}}'
    ;;
  'pane close')
    rm -f "$HERDR_FAKE_PRESENT"
    printf '%s\n' '{"result":{"type":"pane_closed"}}'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FIXTURE/bin/herdr"
PATH="$FIXTURE/bin:$PATH"
export PATH

cat > "$FIXTURE/home/config/tmux-atelier" <<EOF
root=$FIXTURE/atelier
socket=$SOCKET
session=$SESSION
herdr_session=lab-view
EOF
cat > "$FIXTURE/home/state/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$FIXTURE/worktree
project=$FIXTURE/project
harness=codex
kind=ship
EOF

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n "fm-$ID" -c "$FIXTURE/worktree" \
  || fail "could not create private atelier fixture"
source_wid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-$ID" '#{window_id}')

FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID" "working: implementing adapter" \
  || fail "working presentation sync failed"
proxy_windows=$("$REAL_TMUX" -L "$SOCKET" list-windows -t "=$PROXY" -F '#{window_id}') \
  || fail "one-window proxy session was not created"
[ "$proxy_windows" = "$source_wid" ] || fail "proxy session was not bound only to the authoritative window"
[ "$("$REAL_TMUX" -L "$SOCKET" show-options -v -t "$PROXY:" @firstmate-task-id)" = "$ID" ] \
  || fail "proxy session lost its task identity binding"
[ "$("$REAL_TMUX" -L "$SOCKET" show-options -v -t "$PROXY:" @firstmate-task-target)" = "$TARGET" ] \
  || fail "proxy session lost its endpoint identity binding"
grep -Fq "workspace create" "$HERDR_FAKE_LOG" || fail "native Herdr workspace was not created"
grep -Fq "workspace create --cwd $FIXTURE/worktree --label firstmate-atelier --no-focus" "$HERDR_FAKE_LOG" \
  || fail "native Herdr workspace did not use the shared firstmate-atelier label"
grep -Fq "workspace report-metadata w1 --source firstmate:tmux:workspace --token atelier_id=firstmate-atelier" "$HERDR_FAKE_LOG" \
  || fail "native Herdr workspace did not receive its documented ownership token"
grep -Fq "tab rename w1:t1 fm-$ID" "$HERDR_FAKE_LOG" \
  || fail "the first agent tab did not receive a readable task label"
grep -Fq "pane run w1:p1 exec tmux -L $SOCKET attach-session -t $PROXY" "$HERDR_FAKE_LOG" \
  || fail "Herdr pane did not attach to the exact one-window tmux proxy"
grep -Fq -- "--state working --message implementing adapter" "$HERDR_FAKE_LOG" \
  || fail "working status was not reported semantically"
grep -Fq -- "--display-agent fm-$ID / project" "$HERDR_FAKE_LOG" \
  || fail "the visible agent label did not include task and project context"
pass "tmux atelier: native Herdr pane is bound through one exact linked-window proxy"

calls_before=$(wc -l < "$HERDR_FAKE_LOG")
if FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" ../unsafe "working: invalid id" \
     > "$FIXTURE/invalid.out" 2> "$FIXTURE/invalid.err"; then
  fail "an unsafe task id was accepted by the public presenter"
fi
[ "$(wc -l < "$HERDR_FAKE_LOG")" -eq "$calls_before" ] \
  || fail "an unsafe task id reached the Herdr CLI"
grep -Fq 'usage: fm-tmux-herdr-present.sh' "$FIXTURE/invalid.err" \
  || fail "an unsafe task id refusal was not explicit"
pass "tmux atelier: public presenter rejects unsafe task identity before state access"

FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID" "blocked: waiting for review" \
  || fail "blocked presentation sync failed"
FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID" "done: PR ready" \
  || fail "done presentation sync failed"
[ "$(grep -c 'workspace create' "$HERDR_FAKE_LOG")" -eq 1 ] \
  || fail "status refresh created a duplicate Herdr workspace"
grep -Fq -- "--state blocked --message waiting for review" "$HERDR_FAKE_LOG" \
  || fail "blocked status was not reported semantically"
grep -Fq -- "--state idle --message PR ready" "$HERDR_FAKE_LOG" \
  || fail "done status was not reported as Herdr idle/done"
grep -Fq -- "--token context=PR ready" "$HERDR_FAKE_LOG" \
  || fail "readable context token did not follow the status note"
pass "tmux atelier: working, blocked, and done status events refresh one native Herdr card"

HERDR_FAKE_PROCESS_MISMATCH=1
export HERDR_FAKE_PROCESS_MISMATCH
FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID" "working: should not take over" \
  2> "$FIXTURE/mismatch.err" || fail "a mismatched optional pane should not fail the tmux task"
grep -Fq 'no longer runs its exact tmux proxy' "$FIXTURE/mismatch.err" \
  || fail "a repurposed Herdr pane was not explained"
"$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-$ID" '#{pane_id}' >/dev/null \
  || fail "mismatched Herdr presentation affected the authoritative tmux task"
pass "tmux atelier: a repurposed Herdr pane is preserved and never gains task authority"

unset HERDR_FAKE_PROCESS_MISMATCH
ID_TWO=observer
PROXY_TWO="fmh-$ID_TWO"
TARGET_TWO="tmux+$SOCKET/$SESSION:fm-$ID_TWO"
export HERDR_FAKE_TASK="fm-$ID_TWO" HERDR_FAKE_PROXY="$PROXY_TWO" HERDR_FAKE_PANE=w1:p2
cat > "$FIXTURE/home/state/$ID_TWO.meta" <<EOF
window=$TARGET_TWO
endpoint_task_id=$ID_TWO
worktree=$FIXTURE/worktree
project=$FIXTURE/project
harness=codex
kind=ship
EOF
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "fm-$ID_TWO" -c "$FIXTURE/worktree" \
  || fail "could not create the second private atelier task"
FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID_TWO" "working: observing grouped view" \
  || fail "second grouped presentation sync failed"
[ "$(grep -c 'workspace create' "$HERDR_FAKE_LOG")" -eq 1 ] \
  || fail "a second task created a duplicate firstmate-atelier workspace"
grep -Fq "tab create --workspace w1 --cwd $FIXTURE/worktree --label fm-$ID_TWO --no-focus" "$HERDR_FAKE_LOG" \
  || fail "the second agent did not become a tab in the shared firstmate-atelier workspace"
grep -Fq "pane run w1:p2 exec tmux -L $SOCKET attach-session -t $PROXY_TWO" "$HERDR_FAKE_LOG" \
  || fail "the second grouped agent did not attach through its own exact proxy"
pass "tmux atelier: multiple agents reuse the native firstmate-atelier group"

HERDR_FAKE_DOWN=1
export HERDR_FAKE_DOWN
FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID_TWO" "working: Herdr unavailable" \
  2> "$FIXTURE/unavailable.err" || fail "an unavailable optional Herdr session failed the tmux task"
grep -Fq 'continues without native Herdr presentation' "$FIXTURE/unavailable.err" \
  || fail "an unavailable optional Herdr session was not explained"
"$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-$ID_TWO" '#{pane_id}' >/dev/null \
  || fail "an unavailable optional Herdr session affected the authoritative tmux task"
pass "tmux atelier: unavailable Herdr presentation leaves ordinary tmux control intact"
unset HERDR_FAKE_DOWN

calls_before=$(wc -l < "$HERDR_FAKE_LOG")
cat > "$FIXTURE/home/config/tmux-atelier" <<EOF
root=$FIXTURE/atelier
socket=$SOCKET
session=$SESSION
herdr_session=default
EOF
if FM_HOME="$FIXTURE/home" "$ROOT/bin/fm-tmux-herdr-present.sh" "$ID_TWO" "working: unsafe default" \
     2> "$FIXTURE/default.err"; then
  fail "the default Herdr session was accepted for optional presentation"
fi
[ "$(wc -l < "$HERDR_FAKE_LOG")" -eq "$calls_before" ] \
  || fail "the refused default Herdr session reached the Herdr CLI"
grep -Fq 'must be a named non-default Herdr session' "$FIXTURE/default.err" \
  || fail "the default Herdr session refusal was not explicit"
if grep -Eq '^(server|session)[[:space:]]' "$HERDR_FAKE_LOG"; then
  fail "optional presentation attempted a Herdr lifecycle command"
fi
pass "tmux atelier: default-session and lifecycle boundaries fail closed"

"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:fm-$ID"
if "$REAL_TMUX" -L "$SOCKET" has-session -t "=$PROXY" 2>/dev/null; then
  fail "linked proxy session survived destruction of its authoritative task window"
fi
pass "tmux atelier: authoritative task cleanup also retires the one-window proxy session"

cleanup
trap - EXIT
