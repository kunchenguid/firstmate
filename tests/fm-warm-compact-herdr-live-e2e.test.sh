#!/usr/bin/env bash
# Opt-in credentialed live guard for warm-cache compaction
# (bin/fm-warm-compact-lib.sh, bin/fm-supervision-host.sh,
# docs/configuration.md "Warm-cache compaction").
#
# Proves against the real installed Claude Code and Herdr, in an isolated Herdr
# lab session and a lab copy of this checkout opted in to the supervision host
# and to warm-cache compaction (never a live fleet home or session):
#   1. an idle interactive Claude primary in a Herdr pane, with the tracked Stop
#      hook registered, is compacted once through the backend's submit
#      primitive after its idle window, and never a second time in that episode;
#   2. the supervision host's headless engine conversation, after one handled
#      away-posture wake, is compacted once by a resumed /compact turn;
#   3. neither compaction reaches the captain (no wake, no outcome, no close);
#   4. a main-only wake that was queued on disk after both compactions is
#      picked up by the compacted primary, which drains and acknowledges it.
# The lab opts in with short windows (60s idle, 5000 tokens) so the guard
# finishes in minutes. Evidence lines start with "# ".
#
#   FM_WARM_COMPACT_LIVE_E2E=1 tests/fm-warm-compact-herdr-live-e2e.test.sh
#
# FM_WARM_COMPACT_LIVE_MODEL (default haiku) picks the primary's and engine's
# model. Every Herdr call goes through bin/fm-herdr-lab.sh.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_WARM_COMPACT_LIVE_E2E claude herdr jq node perl git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -n 1)
MODEL=${FM_WARM_COMPACT_LIVE_MODEL:-haiku}
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-warm-compact)
LAB=$(fm_test_tmproot fm-warm-compact-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/fm"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
POLLS=${FM_WARM_COMPACT_LIVE_POLLS:-3000}
ORIGINAL_PATH=$PATH
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
while IFS= read -r name; do
  unset "$name"
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

cleanup() {
  local rc=$? pid
  trap - EXIT
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  [ -z "${FM_WARM_COMPACT_LIVE_TRACE:-}" ] || cp "$LAB/screens.log" /tmp/wc-screens.log 2>/dev/null
  rm -rf "${PROJECTS:?}/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }

transcript() {
  local sid
  sid=$(lab pane list 2>/dev/null | jq -r --arg pane "$PANE" '.result.panes[]? | select(.pane_id == $pane) | .agent_session.value // empty' 2>/dev/null | head -n 1)
  [ -n "$sid" ] || return 0
  find "$PROJECTS/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')" -maxdepth 1 -name "$sid.jsonl" -print 2>/dev/null | head -n 1
}
compact_boundaries() {
  local t
  t=$(transcript)
  [ -n "$t" ] || { echo 0; return; }
  jq -r 'select(.type == "system" and .subtype == "compact_boundary") | .uuid' "$t" 2>/dev/null | wc -l | tr -d ' '
}
host_log() { cut -f2- "$FM/state/.supervision-host.log" 2>/dev/null; }
host_log_has() { host_log | grep -qE -- "$1"; }
host_live() {
  local pid
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
watcher_live() { local pid; pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
turn_idle() {  # <after-epoch>
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -e --argjson since "$1" '
    select(.type == "system" and .subtype == "turn_duration")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
settled_at_least() { [ "$(grep -cE '	handled	' "$FM/state/.supervision-host.log" 2>/dev/null || true)" -ge "$1" ]; }
diagnose() {
  lab pane list 2>&1 | head -c 700; echo
  printf -- '--- host log\n%s\n--- queue\n%s\n--- screen\n%s\n' "$(tail -n 12 "$FM/state/.supervision-host.log" 2>/dev/null)" \
    "$(cat "$FM/state/.wake-queue" 2>/dev/null)" "$(screen | tail -n 25)"
}

# --- the lab home ---------------------------------------------------------------

mkdir -p "$FM" "$LAB/bin"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config" "$FM/data"
: > "$FM/config/supervision-host"
printf 'idle-seconds=60\nmin-context-tokens=5000\n' > "$FM/config/warm-compact"
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$FM/state/demo.meta"
: > "$FM/state/demo.status"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/tmux"
cat > "$LAB/bin/herdr" <<SH
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = '$SESSION' ] || { echo 'wrapper requires the lab session' >&2; exit 98; }
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
SH
chmod +x "$LAB/bin/tmux" "$LAB/bin/herdr"
cat > "$LAB/env" <<ENV
export FM_HOME='$FM'
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_WARM_COMPACT_TICK=5
export HERDR_SESSION='$SESSION'
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
export PATH='$LAB/bin':"\$PATH"
ENV

"$LAB_HELPER" provision "$SESSION"
OUT=$(lab workspace create --cwd "$FM" --label warm-compact-primary --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "the lab workspace has no pane"

# --- the primary ----------------------------------------------------------------

lab pane run "$PANE" 'echo MARK_$((6*7))' >/dev/null
shell_ready() { screen | grep -q MARK_42; }
wait_until 600 shell_ready || fail "the lab pane's shell never answered"

PROMPT='This is an isolated Firstmate test lab, not a real fleet. Reply with exactly READY now and use no tools. Later, whenever a "Stop hook feedback" message wakes you, do exactly this and nothing else: run `bin/fm-wake-drain.sh` once with the Bash tool, then run the exact `bin/fm-wake-drain.sh --ack-through ...` command that its WAKE_ACK_REQUIRED line prints, then reply with exactly ACKED. Never run any other command, never run bin/fm-watch-arm.sh, and never use any other tool.'
lab pane run "$PANE" ". '$LAB/env'; printf '%s\\n' \"\$\$\" > state/.lock; exec claude --model $MODEL --effort low --dangerously-skip-permissions" >/dev/null
FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. Merge nothing and dispatch nothing.' >/dev/null \
  || fail "could not record the lab's away posture"

choose() {  # <screen> <option>: move the dialog cursor to <option> and confirm
  local cursor target moves key
  cursor=$(printf '%s\n' "$1" | grep -n '❯' | tail -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$1" | grep -nF -- "$2" | tail -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor))
  key=Down
  [ "$moves" -ge 0 ] || { key=Up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do
    lab pane send-keys "$PANE" "$key" >/dev/null
    sleep 0.3
    moves=$((moves - 1))
  done
  lab pane send-keys "$PANE" Enter >/dev/null
  sleep 3
}
ready_composer() {
  local state
  state=$(FM_BACKEND_HERDR_SESSION=$SESSION bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2:$3"' _ "$ROOT" "$SESSION" "$PANE" 2>/dev/null)
  [ "$state" = empty ]
}
started=$(date +%s)
i=0
while [ "$i" -lt 90 ]; do
  s=$(screen)
  [ -z "${FM_WARM_COMPACT_LIVE_TRACE:-}" ] || printf "%s\n=====\n" "$s" >> "$LAB/screens.log"
  case "$s" in
    *'Yes, I trust this folder'*) choose "$s" 'Yes, I trust this folder' ;;
    *'Yes, I accept'*) choose "$s" 'Yes, I accept' ;;
    *'external CLAUDE.md'*|*'external imports'*) choose "$s" 'Yes, allow external imports' ;;
    *) ready_composer && break ;;
  esac
  sleep 1
  i=$((i + 1))
done
[ "$i" -lt 90 ] || fail "Claude never reached an idle empty composer"$'\n'"$(diagnose)"
sleep 2
lab pane send-text "$PANE" "$PROMPT" >/dev/null
sleep 1
lab pane send-keys "$PANE" Enter >/dev/null
wait_until "$POLLS" host_live || fail "the setup turn's Stop hook never started the supervision host"$'\n'"$(diagnose)"
wait_until 300 watcher_live || fail "the host never started a watcher"$'\n'"$(diagnose)"
wait_until "$POLLS" turn_idle "$started" || fail "the setup turn never ended"$'\n'"$(diagnose)"
evidence "primary idle in Herdr pane $PANE ($CLAUDE_VERSION, $HERDR_VERSION, model $MODEL); host pid $(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")"

# --- the engine conversation ------------------------------------------------------

printf 'done [at=%s]: the demo cleanup finished; nothing else is needed\n' "$(date +%s)" >> "$FM/state/demo.status"
wait_until "$POLLS" settled_at_least 1 || fail "the engine never handled the away wake"$'\n'"$(diagnose)"
engine_session=$(sed -n 's/^session=//p' "$FM/state/.supervision-host-engine")
evidence "engine conversation $engine_session handled one away wake"
FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "could not end the lab's away posture"

# --- both compactions, once -------------------------------------------------------

wait_until "$POLLS" host_log_has 'warm-compact	primary	sent' || fail "the idle primary was never compacted"$'\n'"$(diagnose)"
evidence "primary: $(host_log | grep 'warm-compact	primary')"
wait_until "$POLLS" host_log_has 'warm-compact	engine	compacted' || fail "the idle engine conversation was never compacted"$'\n'"$(diagnose)"
evidence "engine: $(host_log | grep 'warm-compact	engine')"
wait_until 600 test "$(compact_boundaries)" -ge 1 || fail "the primary transcript has no compaction boundary"$'\n'"$(diagnose)"
evidence "primary transcript compaction boundaries: $(compact_boundaries)"
sleep 20
[ "$(host_log | grep -c 'warm-compact	primary')" = 1 ] || fail "the primary was compacted more than once in one idle episode"
[ "$(host_log | grep -c 'warm-compact	engine')" = 1 ] || fail "the engine conversation was compacted more than once in one idle episode"
[ "$(compact_boundaries)" = 1 ] || fail "the primary transcript shows more than one compaction"
[ ! -s "$FM/state/.wake-queue" ] || fail "a compaction left a wake for main"$'\n'"$(diagnose)"
engine_tokens=$(bash -c '. "$1/bin/fm-warm-compact-lib.sh"; fm_warm_compact_context_tokens "$(fm_warm_compact_engine_transcript "$2")"' _ "$ROOT" "$engine_session")
evidence "engine context after compaction: ${engine_tokens:-unreadable} tokens"

# --- a pending wake after compaction ----------------------------------------------

after=$(date +%s)
printf 'needs-decision [at=%s] [key=lab-after-compact]: pick export format A or B\n' "$after" >> "$FM/state/demo.status"
acked() {
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -r --argjson since "$after" '
    select(.type == "assistant")
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since)
    | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command' "$t" 2>/dev/null \
    | grep -q 'fm-wake-drain.sh --ack-through [0-9]* --recovery-generation'
}
wait_until "$POLLS" acked || fail "the compacted primary never drained and acknowledged the pending wake"$'\n'"$(diagnose)"
evidence "compacted primary drained and acknowledged the wake queued after compaction"
echo "ok - warm-cache compaction: primary and engine compacted once each, pending wake picked up from disk"
