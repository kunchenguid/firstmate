#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code supervision-branch mod
# (.claude/mods/fm-branch-mod, docs/claude-supervision-branch.md): one real
# Claude Code primary in tmux, launched exactly as the docs page prescribes,
# supervising one stand-in task in a temporary scratch home. It proves, on the
# pinned Claude Code version only:
#   1. the module loads (enabled by state/.branch-mod-mode) and main takes the
#      home's session lock;
#   2. the first watcher wake on a routine status line passes the classifier
#      and is routed to a freshly spawned branch agent, which handles it and
#      reports a routine outcome without a main turn;
#   3. the next wake, carrying a captain-class `done:` line, is passed to main
#      by the classifier with a covering captain outcome row, main drains it,
#      and the routine wake after it reaches the same agent through
#      SendMessage;
#   4. across that run: one spawn, every send successful, no dropped hand-back,
#      no backstop delivery;
#   5. a wake arriving after Claude Code's in-memory transcript window, with
#      transcript persistence on, still reaches the same agent: the send
#      succeeds and nothing new spawns;
#   6. the same minutes-later gap on a session that inherited
#      CLAUDE_CODE_CHILD_SESSION=1 (transcript saving off, the production
#      defect's launch shape) rotates to a fresh agent (agent.rotated
#      why=unresumable, a second agent.spawn) and keeps the wake instead of
#      passing it to main.
# The pin is the module's own refusal gate: on any other Claude Code version the
# test skips, because the module would refuse to load and the assertions would
# be meaningless. A pin bump is landed by running this test on the new version
# (docs/claude-supervision-branch.md "Updating the pin").
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Sonnet turns are
# submitted (about six minutes across the two labs). FM_BRANCH_MOD_LIVE_KEEP=1
# copies each lab's logs (module events, Claude debug, watcher triage, status)
# to a fresh temporary directory named on stdout, for a post-mortem.
# shellcheck disable=SC2016 # prompt text is read by the model, not this test shell, and settle conditions are re-evaluated, not expanded
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_BRANCH_MOD_LIVE claude tmux

MOD="$ROOT/.claude/mods/fm-branch-mod"
PIN=$(sed -n "s/^export const CLAUDE_CODE_PIN = '\([0-9.]*\)'$/\1/p" "$MOD/hooks/branch.ts")
[ -n "$PIN" ] || fail "the module declares no CLAUDE_CODE_PIN"
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk '{ print $1 }')
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
if [ "$CLAUDE_VERSION" != "$PIN" ]; then
  echo "skip: Claude Code $CLAUDE_VERSION installed, the supervision-branch mod is pinned to $PIN"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SESSION="fm-branch-e2e"
SOCKET1="fm-branch-claude-$$"
SOCKET2="fm-branch-claude-child-$$"
LAB1='' LAB2='' # every lab root, so cleanup reaches both
SOCKET='' LAB='' HOME_DIR='' STATE='' EVENTS='' SHIM='' # the lab under setup
GAP_BASELINE=0 SENDS_BEFORE_GAP=0 # where the production gap left the branch

teardown_lab() { # <socket> <lab>
  local socket=$1 lab=$2 i=0
  [ -n "$lab" ] || return 0
  "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || true
  # The watcher and Claude's debug logger may still be winding down in the lab.
  while [ "$i" -lt 20 ] && pgrep -f "$lab/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  pkill -f "$lab/" 2>/dev/null || true
}

cleanup() {
  local lab st keep
  teardown_lab "$SOCKET1" "$LAB1"
  teardown_lab "$SOCKET2" "$LAB2"
  if [ "${FM_BRANCH_MOD_LIVE_KEEP:-}" = 1 ]; then
    for lab in "$LAB1" "$LAB2"; do
      [ -n "$lab" ] || continue
      st="$lab/home/state"
      keep=$(mktemp -d "${TMPDIR:-/tmp}/fm-branch-claude-live-logs.XXXXXX") || continue
      cp "$st/branch-mod-events.jsonl" "$lab/debug.log" "$st/.watch-triage.log" "$st/dummy.status" "$st/.wake-queue" "$keep/" 2>/dev/null || true
      echo "# lab logs kept at $keep (lab $lab)"
    done
  fi
  rm -rf "$LAB1" "$LAB2" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- scratch homes -----------------------------------------------------------
# Each scenario runs in its own throwaway home, so the child-session launch
# starts a genuinely fresh Claude session instead of adopting the first lab's
# lock, counters, and agent. Scripts come from the tracked bin/ through a
# symlink overlay so the home is a genuine primary checkout for the Stop
# hook's scope check; the mod resolves them from its own plugin root either
# way.
make_lab() { # <socket>: build a fresh scratch home; sets the lab globals
  SOCKET=$1
  LAB=$(fm_test_tmproot fm-branch-claude-live)
  HOME_DIR="$LAB/home"
  STATE="$HOME_DIR/state"
  EVENTS="$STATE/branch-mod-events.jsonl"
  SHIM="$LAB/shim"
  mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects/dummy" "$HOME_DIR/bin" "$SHIM"
for f in "$ROOT"/bin/*; do ln -s "$f" "$HOME_DIR/bin/$(basename "$f")"; done
for d in .agents docs .tasks.toml; do ln -s "$ROOT/$d" "$HOME_DIR/$d"; done
git -C "$HOME_DIR" init -q
printf 'tmux\n' > "$HOME_DIR/config/backend"
: > "$STATE/.branch-mod-mode"
cat > "$HOME_DIR/AGENTS.md" <<'MD'
# Scratch primary for the fm-branch-mod live regression

You are the MAIN conversation of a scratch firstmate home used by a regression test. Do exactly what a prompt asks and nothing more.

- First prompt of a session: run `bin/fm-lock.sh` (it takes this home's session lock), then reply `ready` and idle.
- A watcher wake reaches you only when the plugin routed it to you. Handle it: run `bin/fm-wake-drain.sh`, read what it prints, then reply to the captain in one or two plain sentences with the outcome, and finally run the exact `--ack-through` command the drain printed as `WAKE_ACK_REQUIRED`. Do not run `bin/fm-watch-arm.sh`.
- A `STATUS OUTCOME BACKSTOP` section in the drain names a captain-facing status line the supervision branch had marked routine: tell the captain about it in one sentence.
- A supervision processing request (`[seq N] task: summary`) asks you to tell the captain the outcome in one sentence, then call `fm_branch_processed` with `through=N`.
- Otherwise, if a routine operational update needs a reply, answer exactly `Captain, shipshape.`
- Never spawn agents, never edit files, never run anything outside `bin/`.
MD
printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
cat > "$STATE/dummy.meta" <<EOF
window=$SESSION:dummy
worktree=$HOME_DIR/projects/dummy
project=$HOME_DIR/projects/dummy
harness=claude
kind=scout
backend=tmux
EOF
: > "$STATE/dummy.status"

# The stand-in crewmate: a routine `working:` line every <period> seconds, a
# tick so its pane is never idle, and one captain-class `done:` line when the
# test drops the request file.
cat > "$LAB/dummy.sh" <<'DUMMY'
#!/usr/bin/env bash
set -u
STATUS=$1; PERIOD=$2; D=$(dirname "$STATUS")
n=0; last=$(date +%s)
while :; do
  now=$(date +%s)
  if [ -e "$D/dummy.pause" ]; then
    last=$now
    echo "$(date +%T) paused"
  elif [ -e "$D/dummy.done-request" ]; then
    rm -f "$D/dummy.done-request"; n=$((n + 1))
    echo "done: dummy finished step $n; report at data/dummy/report.md" >> "$STATUS"
    echo "$(date +%T) appended done"
  elif [ $((now - last)) -ge "$PERIOD" ]; then
    n=$((n + 1)); last=$now
    echo "working: step $n of the dummy loop, $(date +%T)" >> "$STATUS"
    echo "$(date +%T) appended working step $n"
  else
    echo "$(date +%T) tick"
  fi
  sleep 2
done
DUMMY

# Every bare `tmux` the home's scripts run (watcher, backend reads, the Stop
# hook) lands on this test's private server.
cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
EOF
chmod +x "$SHIM/tmux" "$LAB/dummy.sh"

# The launch settings the docs page prescribes: the Stop-owned watcher auto-arm,
# prompt suggestion off, and no autoCompactWindow.
cat > "$LAB/settings.json" <<EOF
{
  "promptSuggestionEnabled": false,
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' exec '$HOME_DIR/bin/fm-claude-stop-autoarm.sh'",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ]
  }
}
EOF

}

# Start the stand-in crewmate window running the lab's dummy script.
start_dummy() {
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION" -n dummy -c "$HOME_DIR" "bash '$LAB/dummy.sh' '$STATE/dummy.status' 5"
}

# Pausing freezes the stand-in's status appends without killing its pane, so
# no wake can flow while the production gap elapses. A flag file, not
# SIGSTOP: tmux's server SIGCONTs a stopped pane process at once.
pause_dummy() { : > "$STATE/dummy.pause"; }
resume_dummy() { rm -f "$STATE/dummy.pause"; }

# Claude Code refuses to nest inside another Claude session, and the home's
# scripts must not inherit this shell's firstmate environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|FM_[A-Z_]+|HERDR_[A-Z_]+|TMUX|TMUX_PANE)=' | cut -d= -f1 | sort -u)
}

# Launch Claude Code exactly as the docs page prescribes, in a fresh tmux
# session of the current lab. Any arguments become extra environment
# assignments in the pane after the scrub, so the child-session case passes
# CLAUDE_CODE_CHILD_SESSION=1 and the marker survives into Claude's env.
# The lab's tmux server is started scrubbed too: Claude Code keeps transcript
# saving on when `tmux show-environment -g` also carries the marker (an
# ambient marker), so a server inheriting it from a test run inside a Claude
# session would hide the child-session defect.
start_claude_session() { # [extra-env...]
  local extra="${*:+$* }"
  # shellcheck disable=SC2046 # intentional: unset_inherited emits separate -u NAME tokens for env
  env $(unset_inherited) "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n main -x 160 -y 44 -c "$HOME_DIR" \
    "env $(unset_inherited) PATH='$SHIM:$PATH' CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 ${extra}claude --model sonnet --plugin-dir '$MOD' --settings '$LAB/settings.json' --strict-mcp-config --dangerously-skip-permissions --debug-file '$LAB/debug.log'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

screen() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:main" 2>/dev/null || true
}

enter() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Enter
}

# The folder-trust dialog opens with its cursor on "No, exit": move the cursor
# onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Down ;;
  esac
}

events() {  # <kind> -> the matching event lines
  grep -F "\"kind\":\"$1\"" "$EVENTS" 2>/dev/null || true
}

# Wait until at least <min> events (default 1) of <kind> whose lines contain
# <needle> have been logged, answering the folder-trust dialog on the way;
# iteration-counted so it stretches under load.
wait_event() {  # <kind> <needle> <what> [seconds] [min]
  local kind=$1 needle=$2 what=$3 limit=${4:-240} want=${5:-1} i=0 shot
  while [ "$i" -lt "$((limit * 2))" ]; do
    if [ "$(count "$kind" "$needle")" -ge "$want" ]; then return 0; fi
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    answer_trust_dialog "$shot"
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  tail -n 20 "$EVENTS" >&2 2>/dev/null || true
  fail "Claude Code $CLAUDE_VERSION never reached $what"
}

count() {  # <kind> [needle]
  if [ "$#" -gt 1 ]; then events "$1" | grep -cF -- "$2" || true; else events "$1" | wc -l | tr -d ' '; fi
}

# Event lines are appended by one fire-and-forget shell per record, so under
# load a count can lag the events it counts. Count assertions re-read a few
# times before they are allowed to fail.
settle() { # <attempts> <shell condition, evaluated fresh on each try>
  local attempts=$1 i=0
  shift
  while ! eval "$*"; do
    i=$((i + 1))
    [ "$i" -ge "$attempts" ] && return 1
    sleep 2
  done
}

# Successful sends, counted through the escaped-JSON success marker.
success_sends() { count agent.send '\"success\":true'; }

# The composer is up once the trust dialog is gone and the prompt glyph shows.
wait_composer() {
  local i=0 shot
  while [ "$i" -lt 240 ]; do
    shot=$(screen)
    answer_trust_dialog "$shot"
    case "$shot" in *'❯'*) [ "$i" -gt 4 ] && return 0 ;; esac
    sleep 0.5
    i=$((i + 1))
  done
  fail "the composer never came up"
}

# Main's first prompt: take the home's session lock.
take_lock() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" -l "Take this home's session lock with bin/fm-lock.sh, then reply ready."
  sleep 0.5
  enter
  wait_event turn.complete.main '"kind":"turn.complete.main"' "main's lock turn"
  [ -s "$STATE/.lock" ] || fail "main did not take the session lock"
}

# The branch finished every wake already delivered: with the stand-in paused,
# its turn-complete count stops rising.
wait_branch_quiet() {
  local last=-1 stable=0 i=0 n
  while [ "$i" -lt 240 ]; do
    n=$(count turn.complete.branch)
    if [ "$n" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
    [ "$stable" -ge 5 ] && return 0
    last=$n
    answer_trust_dialog "$(screen)"
    sleep 2
    i=$((i + 1))
  done
  fail "the branch never went quiet: $(events turn.complete.branch)"
}

# One more branch turn than <baseline> completed.
wait_branch_turn() { # <baseline> <what>
  local baseline=$1 what=$2 i=0
  while [ "$(count turn.complete.branch)" -le "$baseline" ] && [ "$i" -lt 480 ]; do
    answer_trust_dialog "$(screen)"
    sleep 1
    i=$((i + 1))
  done
  [ "$(count turn.complete.branch)" -gt "$baseline" ] || fail "Claude Code $CLAUDE_VERSION never reached $what"
}

# The production-shaped gap: pause the stand-in, let the branch finish what it
# already has, then hold past Claude Code's in-memory transcript window
# (measured at 30 s plus at most one further 30 s idle window) before the
# stand-in's next line becomes the next wake. Sets GAP_BASELINE to the
# branch-turn count and SENDS_BEFORE_GAP to the send count to wait against
# afterwards; both are captured only once the branch is quiet, so no send is
# in flight.
production_gap() {
  pause_dummy
  wait_branch_quiet
  GAP_BASELINE=$(count turn.complete.branch)
  SENDS_BEFORE_GAP=$(count agent.send)
  sleep 75
  resume_dummy
}

# --- 1. load and lock (lab 1: the scrubbed launch, transcript persistence on)
make_lab "$SOCKET1"
LAB1=$LAB
start_claude_session
wait_event session.start '"enabled":true' 'the module loading enabled'
[ "$(count pin.refused)" = 0 ] || fail "the module refused its own pin"
wait_composer
take_lock
pass "Claude Code $CLAUDE_VERSION loads the supervision-branch mod enabled and main holds the session lock"

# --- 2. routine wake: spawn ----------------------------------------------------
start_dummy
wait_event classifier '"verdict":"routine"' "the classifier's routine verdict on the working line"
wait_event wake.delivered '"via":"spawn"' 'the first wake delivered by spawning the branch'
wait_event report.call '"verdict":"routine"' "the branch's routine outcome"
wait_event turn.complete.branch '"kind":"turn.complete.branch"' "the branch's first turn end"
pass "the first routine wake passes the classifier and spawns the branch agent, which reports it routine"

# --- 3. captain wake: classifier pass to main, then a send -------------------
: > "$STATE/dummy.done-request"
wait_event classifier '"verdict":"captain"' "the classifier's captain verdict on the done line"
wait_event wake.passed '"why":"classifier captain"' 'the done wake passed to main'
wait_event pass.cover '"processed":true' "the covering captain outcome row for main's direct handling"
i=0
while [ "$(count turn.complete.main)" -lt 2 ] && [ "$i" -lt 480 ]; do
  answer_trust_dialog "$(screen)"
  sleep 0.5
  i=$((i + 1))
done
[ "$(count turn.complete.main)" -ge 2 ] || fail "main never finished the turn that drains the done wake: $(events turn.complete.main)"
[ "$(count deliver.captain)" = 0 ] || fail "the branch re-escalated the done line main already handled: $(events deliver.captain)"
wait_event wake.delivered '"via":"send"' 'the next routine wake delivered by SendMessage'
pass "the captain-class wake is passed to main by the classifier with a covering outcome row, and the next routine wake reaches the same agent through SendMessage"

# --- 4. minutes-later wake, persistence on: the same agent resumes -------------
# The scenarios above fire seconds apart, inside the window Claude Code keeps
# a finished background agent's transcript in memory; production wakes arrive
# minutes later. Pause the stand-in, hold past that window, then deliver the
# next wake: the scrubbed launch saves transcripts, so the SAME agent must
# take it - the send succeeds and nothing new spawns.
production_gap
# The turn after the gap proves the wake was delivered and handled: only
# then do the no-rotation and all-sends-succeeded assertions mean anything.
wait_branch_turn "$GAP_BASELINE" "the resumed agent's turn on the minutes-later wake"
[ "$(count agent.rotated)" = 0 ] || fail "the minutes-later wake rotated a persisted agent: $(events agent.rotated)"
settle 10 '[ "$(count agent.spawn)" = 1 ]' || fail "the minutes-later wake spawned a fresh agent: $(events agent.spawn)"
settle 10 '[ "$(count agent.send)" -gt "$SENDS_BEFORE_GAP" ]' || fail "no send reached the branch after the gap"
settle 10 '[ "$(count agent.send)" = "$(success_sends)" ]' || fail "a send failed after the gap: $(events agent.send)"
pass "a wake after the in-memory window reaches the same persisted agent: the send succeeds, no rotation"

# --- 5. the whole run ----------------------------------------------------------
settle 10 '[ "$(count agent.spawn)" = 1 ]' || fail "expected exactly one spawn, got $(count agent.spawn): $(events agent.spawn)"
[ "$(count handback.dropped)" = 0 ] || fail "a branch hand-back was dropped: $(events handback.dropped)"
[ "$(count backstop.delivered)" = 0 ] || fail "the backstop re-presented a covered line: $(events backstop.delivered)"
[ "$(count agent.send)" -ge 1 ] || fail "no send reached the branch: $(events agent.send)"
settle 10 '[ "$(count agent.send)" = "$(success_sends)" ]' || fail "a send was retried or refused: $(events agent.send)"
pass "one spawn, every send successful, no dropped hand-back, no backstop delivery across the run"

# Lab 1 is proven; free its server and panes before the second lab launches.
teardown_lab "$SOCKET" "$LAB"

# --- 6. inherited CLAUDE_CODE_CHILD_SESSION: the unresumable rotation ----------
# The production defect's launch shape: the primary inherited
# CLAUDE_CODE_CHILD_SESSION=1 (a Herdr server started inside a Claude
# session), so background-agent transcripts are never written to disk. The
# same minutes-later gap then finds no transcript and no in-memory agent: the
# mod must rotate to a fresh agent and keep the wake, never pass it to main.
make_lab "$SOCKET2"
LAB2=$LAB
start_claude_session CLAUDE_CODE_CHILD_SESSION=1
wait_event session.start '"enabled":true' 'the module loading enabled in the child-session lab'
[ "$(count pin.refused)" = 0 ] || fail "the module refused its own pin in the child-session lab"
wait_composer
take_lock
start_dummy
wait_event classifier '"verdict":"routine"' "the classifier's routine verdict on the first working line"
wait_event wake.delivered '"via":"spawn"' 'the first wake delivered by spawning the branch'
wait_event turn.complete.branch '"kind":"turn.complete.branch"' "the branch's first turn end"
production_gap
wait_event agent.rotated '"why":"unresumable"' 'the unresumable rotation'
# The defect's signature: the resume failed because no transcript was ever
# written, and the mod still rotated successfully to a fresh agent. Every
# later agent inherits the same launch shape, so once IT evicts the next wake
# rotates again - the invariant is that rotation keeps every wake and main
# never sees one, not a frozen rotation count.
case "$(events agent.rotated)" in
  *'"why":"unresumable"'*) : ;;
  *) fail "no unresumable rotation: $(events agent.rotated)" ;;
esac
if events agent.rotated | grep -v '"ok":true' | grep -q .; then
  fail "a rotation did not succeed: $(events agent.rotated)"
fi
[ "$(count agent.spawn)" -ge 2 ] || fail "the unresumable wake did not spawn a fresh agent: $(events agent.spawn)"
wait_event wake.delivered '"via":"spawn"' 'the unresumable wake delivered to the fresh agent' 240 2
[ "$(count wake.passed)" = 0 ] || fail "the unresumable wake was passed to main instead of rotating: $(events wake.passed)"
[ "$(count handback.dropped)" = 0 ] || fail "a branch hand-back was dropped: $(events handback.dropped)"
settle 10 '[ "$(count agent.send)" -gt "$SENDS_BEFORE_GAP" ]' || fail "no send was attempted after the gap: $(events agent.send)"
wait_branch_turn "$GAP_BASELINE" "the fresh agent's turn on the unresumable wake"
# Every later wake is kept too: with transcripts never written, a resume
# fails even seconds after the agent's turn, so the chain keeps rotating -
# or, on a version that keeps agents warm, the send succeeds. Either way
# main never sees one.
i=0
while [ "$i" -lt 120 ] \
  && [ "$(count wake.passed)" = 0 ] \
  && [ "$(count handback.dropped)" = 0 ] \
  && [ "$(count wake.delivered '"via":"spawn"')" -lt 3 ] \
  && [ "$(count agent.send '\"success\":true')" -le "$SENDS_BEFORE_GAP" ]; do
  sleep 2
  i=$((i + 1))
done
[ "$(count wake.delivered '"via":"spawn"')" -ge 3 ] \
  || [ "$(count agent.send '\"success\":true')" -gt "$SENDS_BEFORE_GAP" ] \
  || fail "the rotation chain stalled: $(events wake.delivered)"
[ "$(count wake.passed)" = 0 ] || fail "a later wake was passed to main: $(events wake.passed)"
[ "$(count handback.dropped)" = 0 ] || fail "a later hand-back was dropped: $(events handback.dropped)"
pass "a minutes-later wake on an inherited CLAUDE_CODE_CHILD_SESSION rotates to a fresh agent (why=unresumable) and keeps the wake"
