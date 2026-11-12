#!/usr/bin/env bash
# Opt-in credentialed live guard for the acknowledged hand-back's detached
# retry reaching a real Claude primary running in an isolated Herdr lab
# session (bin/fm-supervision-handoff.sh's herdr transport,
# bin/fm-supervision-host.sh "Acknowledged hand-back").
#
# Proves against the real installed Claude Code and a real Herdr server, in an
# isolated lab copy of this checkout opted into both the supervision host and
# config/supervision-handoff-ack (never a live fleet home and never the live
# fm-remote or default session), that when the Stop hook's exit-2 continuation
# is lost:
#   1. the host still records .supervision-handoff-pending, queues the
#      token-bound check, and verifies a detached hand-off owner holding a
#      replacement watcher;
#   2. no "firstmate watcher wake" banner reaches the primary's transcript;
#   3. the owner's retry delivers the record-backed doorbell into the primary's
#      own inherited pane (target "$HERDR_SESSION:$HERDR_PANE_ID" - the exact
#      form remote homes running under fm-remote inherit);
#   4. the primary reads the record, drains, and runs the sequence-bound
#      acknowledgement, and only that acknowledgement removes the pending
#      marker; submission alone never did;
#   5. the owner exits, leaving its verified arm for the next park to adopt.
# Every deferral guarantee stays a fixture concern
# (tests/fm-supervision-host-hook.test.sh); this guard proves the delivered
# case end to end. Evidence lines start with "# ".
#
#   FM_SUPERVISION_HOST_HERDR_LIVE_E2E=1 tests/fm-supervision-host-herdr-live-e2e.test.sh
#
# FM_SUPERVISION_HOST_HERDR_LIVE_MODEL (default haiku) picks the primary's
# model. Claude keeps its existing managed authentication; the lab path gets a
# project transcript directory in Claude's own store.
# FM_HERDR_LAB_FLEET_SESSION names the live fleet session the lab tripwire
# protects (default: the helper's own default); when this test is launched
# inside a pane, the pane's inherited HERDR_SESSION supplies it.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

FLEET_SESSION=${FM_HERDR_LAB_FLEET_SESSION:-${HERDR_SESSION:-}}
herdr_forget_inherited_pane
fm_live_gate opt-in FM_SUPERVISION_HOST_HERDR_LIVE_E2E claude herdr jq node perl git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
[ -n "$FLEET_SESSION" ] && export FM_HERDR_LAB_FLEET_SESSION=$FLEET_SESSION

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
MODEL=${FM_SUPERVISION_HOST_HERDR_LIVE_MODEL:-haiku}
LAB=$(fm_test_tmproot fm-sh-herdr-live)
LAB=$(cd -P "$LAB" && pwd -P)
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
TURN_POLLS=${FM_SUPERVISION_HOST_HERDR_LIVE_POLLS:-1800}
HERDR_ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-sh-herdr-retry) \
  || fail "could not mint a lab session name"
export HERDR_LAB_SESSION
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
# Claude Code keeps no transcript for a session that inherits another session's
# markers, so the lab primary starts without the invoking session's.
while IFS= read -r name; do
  unset "$name"
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

stop_lab() {  # <lab>
  local lab=$1 fm=$1/fm pid
  for pid in \
    "$(cut -f1 "$fm/state/.supervision-handoff-owner" 2>/dev/null)" \
    "$(awk -F '\t' '$1 == "host" { print $2; exit }' "$fm/state/.supervision-host" 2>/dev/null)" \
    "$(cat "$fm/state/.watch.lock/pid" 2>/dev/null)"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  FM_HOME="$fm" FM_PROCEVENT_CLAIM_ROOT="$lab/claims" "$fm/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  rm -rf "${PROJECTS:?}/$(printf '%s' "$fm" | sed 's/[^A-Za-z0-9]/-/g')"
}
cleanup() {
  local status=$? lab
  for lab in "$LAB"/*/; do
    [ -d "$lab/fm" ] && stop_lab "${lab%/}"
  done
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Non-lifecycle Herdr calls go through the helper so every one carries
# --session <lab>. The fakebin herdr lets backend functions under test use
# their ordinary ambient binary while the helper still owns isolation.
FAKEBIN=$LAB/fakebin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
last=\$((\${#args[@]} - 1))
flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] \
  && [ "\${args[\$flag]}" = --session ] \
  && [ "\${args[\$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do
  case "\$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
# Backend functions as the owner calls them, routed at the lab session through
# the fakebin. $1 must be the full "<session>:<pane>" target.
backend() {
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    shift
    "$@"
  ' _ "$ROOT" "$@"
}

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

# --- one lab ------------------------------------------------------------------

make_lab() {  # <name>
  local lab="$LAB/$1" fm
  fm="$lab/fm"
  mkdir -p "$fm" "$lab/bin" "$lab/claims"
  git -C "$ROOT" ls-files -z -co --exclude-standard \
    | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$fm" && tar -xf -)
  git -C "$fm" init -q -b main
  git -C "$fm" add -A >/dev/null
  git -C "$fm" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
  mkdir -p "$fm/state" "$fm/config" "$fm/data"
  : > "$fm/config/supervision-host"
  : > "$fm/config/supervision-handoff-ack"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$fm/state/demo.meta"
  : > "$fm/state/demo.status"
  # Unreachable tmux and ssh: no endpoint read succeeds, so the only wakes are
  # the events this guard appends. herdr is deliberately NOT stubbed - the
  # owner must reach the real lab session's server.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$lab/bin/tmux"
  printf '#!/usr/bin/env bash\nexit 255\n' > "$lab/bin/ssh"
  chmod +x "$lab/bin/tmux" "$lab/bin/ssh"
  cat > "$lab/env" <<ENV
export FM_HOME='$fm'
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_PROCEVENT_CLAIM_ROOT='$lab/claims'
export FM_SUPERVISION_HANDOFF_RETRY_SECONDS=8
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
export PATH='$(dirname "$(command -v herdr)")':'$lab/bin':"\$PATH"
ENV
  cat > "$lab/launch.sh" <<ENV
#!/usr/bin/env bash
set -u
. '$lab/env'
printf '%s\n' "\$\$" > "\$FM_HOME/state/.lock"
exec claude --model $MODEL --effort low --dangerously-skip-permissions
ENV
  chmod +x "$lab/launch.sh"
  printf '%s\n' "$lab"
}

# Claude's own project transcript for the lab checkout.
transcript() {  # <lab>
  local dir
  dir="$PROJECTS/$(printf '%s' "$1/fm" | sed 's/[^A-Za-z0-9]/-/g')"
  find "$dir" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | head -n 1
}
# Epochs of rewake deliveries (Claude's queued "Stop hook feedback") at or after <epoch>.
rewakes_since() {  # <lab> <epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 0
  jq -r --argjson since "$2" '
    select(.type == "queue-operation" and .operation == "enqueue")
    | select((.content // "" | tostring) | contains("firstmate watcher wake"))
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since) | $at' "$t" 2>/dev/null
}
# Epochs of user messages carrying the record-backed operational doorbell.
doorbells_since() {  # <lab> <epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 0
  jq -r --argjson since "$2" '
    select(.type == "user")
    | select((.message.content // "" | tostring) | contains("Firstmate operational input waiting"))
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since) | $at' "$t" 2>/dev/null
}
# Bash commands the primary ran at or after <epoch>.
commands_since() {  # <lab> <epoch>
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 0
  jq -r --argjson since "$2" '
    select(.type == "assistant")
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since)
    | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command' "$t" 2>/dev/null
}
drained_since() { commands_since "$1" "$2" | grep -q 'fm-wake-drain\.sh'; }
acked_since() { commands_since "$1" "$2" | grep -q 'fm-wake-drain\.sh --ack-through [0-9]* --recovery-generation'; }
turn_idle() {  # <lab> <after-epoch>: a turn ended at or after the epoch
  local t
  t=$(transcript "$1")
  [ -n "$t" ] || return 1
  jq -e --argjson since "$2" '
    select(.type == "system" and .subtype == "turn_duration")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
host_log_since() {  # <lab> <epoch> <regex>
  awk -F '\t' -v t="$2" '$1 >= t' "$1/fm/state/.supervision-host.log" 2>/dev/null | grep -E -- "$3"
}
host_live() {
  local pid
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$1/fm/state/.supervision-host" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
watcher_pid() { cat "$1/fm/state/.watch.lock/pid" 2>/dev/null; }
watcher_live() { local pid; pid=$(watcher_pid "$1") && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
ledger() { head -n 1 "$1/fm/state/.claude-autoarm-epoch" 2>/dev/null; }
marker() { cat "$1/fm/state/.watcher-down" 2>/dev/null; }
hook_pid() {  # <lab>: the auto-arm generation's recorded owner pid
  sed -n '1s/.*owner_pid=\([0-9][0-9]*\).*/\1/p' "$1/fm/state/.claude-autoarm-epoch" 2>/dev/null
}
handoff_owner_pid() { cut -f1 "$1/fm/state/.supervision-handoff-owner" 2>/dev/null; }
pending_token() { cat "$1/fm/state/.supervision-handoff-pending" 2>/dev/null; }
diagnose() {  # <lab>
  local pane
  pane=$(cat "$1/pane-id" 2>/dev/null)
  printf -- '--- host log\n%s\n--- handoff log\n%s\n--- cycle exits\n%s\n--- queue\n%s\n--- ledger: %s\n--- marker: %s\n--- screen\n%s\n' \
    "$(tail -n 8 "$1/fm/state/.supervision-host.log" 2>/dev/null)" \
    "$(tail -n 8 "$1/fm/state/.supervision-handoff.log" 2>/dev/null)" \
    "$(tail -n 4 "$1/fm/state/.watch-cycle-exits.log" 2>/dev/null | cut -f1-8)" \
    "$(cat "$1/fm/state/.wake-queue" 2>/dev/null)" "$(ledger "$1")" "$(marker "$1")" \
    "$([ -n "$pane" ] && lab pane read "$pane" --source visible 2>/dev/null | tail -n 25)"
}
# A .supervision-handoff.log retry row for <token> carrying a confirmed
# delivery verdict (empty = composer proved clear after Enter; queued-enter =
# Enter confirmed queued behind a generating turn).
retry_confirmed() {  # <lab> <token>
  awk -F '\t' -v t="$2" '$2 == "retry" && $3 == t && ($4 == "empty" || $4 == "queued-enter") { found=1 } END { exit !found }' \
    "$1/fm/state/.supervision-handoff.log" 2>/dev/null
}
doorbell_seen() { [ -n "$(doorbells_since "$1" "$2")" ]; }
pending_gone() { [ ! -e "$1/fm/state/.supervision-handoff-pending" ]; }
pid_dead() { ! kill -0 "$1" 2>/dev/null; }

# Answer one first-run dialog by moving its cursor to <option> and confirming,
# whether the options are numbered or not.
choose() {  # <pane> <screen> <option>
  local cursor target moves key
  cursor=$(printf '%s\n' "$2" | grep -n '❯' | head -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$2" | grep -nF -- "$3" | head -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor))
  key=down
  [ "$moves" -ge 0 ] || { key=up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do
    lab pane send-keys "$1" "$key" >/dev/null 2>&1
    sleep 0.3
    moves=$((moves - 1))
  done
  lab pane send-keys "$1" enter >/dev/null 2>&1
  sleep 3
}

# The pane's native registration must name Claude and read idle, the rendered
# footer must read idle, and the shared composer classifier must see an empty
# input surface - the same readers the retry's guards use.
claude_ready_state() {  # <target> -> diagnostic state; success when ready
  local target=$1 kind status busy composer
  kind=$(lab agent get "${target#*:}" 2>/dev/null | jq -r '.result.agent.agent // empty')
  status=$(lab agent get "${target#*:}" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  busy=$(backend fm_backend_herdr_rendered_busy_state "$target" claude)
  composer=$(backend fm_backend_herdr_composer_state "$target")
  printf 'agent=%s status=%s busy=%s composer=%s' "$kind" "$status" "$busy" "$composer"
  [ "$kind" = claude ] && [ "$status" = idle ] && [ "$busy" = idle ] && [ "$composer" = empty ]
}

# Start the primary interactively in the lab session's only pane, answer the
# lab's first-run dialogs, submit the one setup prompt, and wait until it sits
# idle with the host parked on a live watcher.
start_primary() {  # <lab>
  local lab=$1 create pane screen i started prompt readiness=unknown last_seen=none
  create=$(lab workspace create --cwd "$lab/fm" --label herdr-primary --no-focus) \
    || fail "$(basename "$lab"): the lab workspace did not create"
  pane=$(printf '%s' "$create" | jq -er '.result.root_pane.pane_id') \
    || fail "$(basename "$lab"): could not read the primary pane id"
  printf '%s\n' "$pane" > "$lab/pane-id"
  lab pane run "$pane" "bash '$lab/launch.sh'" >/dev/null \
    || fail "$(basename "$lab"): the primary's launch command was not sent"
  i=0
  while [ "$i" -lt 120 ]; do
    screen=$(lab pane read "$pane" --source visible 2>/dev/null)
    last_seen=$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 6)
    [ -n "$last_seen" ] || last_seen='empty screen'
    case "$screen" in
      *'Yes, I trust this folder'*) choose "$pane" "$screen" 'Yes, I trust this folder' ;;
      *'Yes, I accept'*) choose "$pane" "$screen" 'Yes, I accept' ;;
      *'external CLAUDE.md'*|*'external imports'*) choose "$pane" "$screen" 'Yes, allow external imports' ;;
      *) readiness=$(claude_ready_state "$HERDR_LAB_SESSION:$pane") && break ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  [ "$i" -lt 120 ] || fail "$(basename "$lab"): Claude never reached an idle empty composer (last readiness: $readiness; last screen: $last_seen)"$'\n'"$(diagnose "$lab")"
  prompt='This is an isolated Firstmate test lab, not a real fleet. Reply with exactly READY now and use no tools. Later, whenever a "Stop hook feedback" message wakes you, or whenever a message says Firstmate operational input waiting and names a record file, do exactly this and nothing else: if a file is named, read it first and follow it; run `bin/fm-wake-drain.sh` once with the Bash tool, then run the exact `bin/fm-wake-drain.sh --ack-through ...` command that its WAKE_ACK_REQUIRED line prints, then reply with exactly ACKED. Never run any other command, never run bin/fm-watch-arm.sh, and never use any other tool.'
  sleep 2
  started=$(date +%s)
  lab pane send-text "$pane" "$prompt" >/dev/null
  sleep 1
  lab pane send-keys "$pane" enter >/dev/null
  wait_until "$TURN_POLLS" host_live "$lab" \
    || fail "$(basename "$lab"): the setup turn's Stop hook never started the supervision host"$'\n'"$(diagnose "$lab")"
  wait_until 300 watcher_live "$lab" || fail "$(basename "$lab"): the host never started a watcher"$'\n'"$(diagnose "$lab")"
  wait_until "$TURN_POLLS" turn_idle "$lab" "$started" || fail "$(basename "$lab"): the setup turn never ended"$'\n'"$(diagnose "$lab")"
  jq -e '[.hooks.Stop[]?.hooks[]? | select(.type == "command" and .asyncRewake == true and (.command | endswith("/bin/fm-claude-stop-autoarm.sh") or endswith("/bin/fm-claude-stop-autoarm.sh\"")))] | length == 1' \
    "$lab/fm/.claude/settings.json" >/dev/null \
    || fail "$(basename "$lab"): the lab lacks the tracked Stop hook registration"
  evidence "$(basename "$lab") step 1: primary idle (claude pid $(cat "$lab/fm/state/.lock" 2>/dev/null), $CLAUDE_VERSION, model $MODEL) in pane $HERDR_LAB_SESSION:$pane; tracked Stop hook registered; config/supervision-host and config/supervision-handoff-ack present; host pid $(awk -F '\t' '$1 == "host" { print $2; exit }' "$lab/fm/state/.supervision-host") parked on watcher $(watcher_pid "$lab")"
  evidence "$(basename "$lab") transcript: $(transcript "$lab")"
}

# Append one main-only event and return its epoch.
fire() {  # <lab> <status-file> <key> <text>
  local at
  at=$(date +%s)
  printf 'needs-decision [at=%s] [key=%s]: %s\n' "$at" "$3" "$4" >> "$2"
  printf '%s\n' "$at"
}

# --- scenario ------------------------------------------------------------------

LAB_PRIMARY=$(make_lab primary)
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision lab session $HERDR_LAB_SESSION"
evidence "lab session $HERDR_LAB_SESSION provisioned (fleet tripwire: ${FM_HERDR_LAB_FLEET_SESSION:-default})"
start_primary "$LAB_PRIMARY"
PANE=$(cat "$LAB_PRIMARY/pane-id")

e1=$(fire "$LAB_PRIMARY" "$LAB_PRIMARY/fm/state/demo.status" lab-e1 'pick export format A or B')
evidence "step 2: needs-decision appended at $e1; the attended pass-through hands back and queues the acknowledged check"
wait_until "$TURN_POLLS" bash -c '[ -s "$1" ]' _ "$LAB_PRIMARY/fm/state/.supervision-handoff-pending" \
  || fail "the hand-back never recorded its pending token"$'\n'"$(diagnose "$LAB_PRIMARY")"
TOKEN=$(pending_token "$LAB_PRIMARY")
evidence "step 2: pending token $TOKEN recorded; ledger: $(ledger "$LAB_PRIMARY")"

# Drop the continuation entirely by superseding the owning hook's generation:
# record a completed newer generation in the auto-arm ledger, exactly what a
# concurrent firing that claimed and finished would leave. The parked hook
# re-verifies ownership before emitting (fm_autoarm_still_owner), sees the
# supersession, and exits 0 - no exit-2, no banner, no killed-hook failure
# notice; the loss is silent, so no drain, acknowledgement, or Stop follows.
# A completed (non-arming) outcome opens no claim, so the next Stop claims
# and parks normally once the doorbell turn ends.
HOOK_PID=$(hook_pid "$LAB_PRIMARY")
case "$HOOK_PID" in ''|*[!0-9]*) fail "no auto-arm owner pid recorded"$'\n'"$(diagnose "$LAB_PRIMARY")" ;; esac
supersede_generation() {  # <lab>: write a completed epoch=N+1 owned by this shell
  local state="$1/fm/state" epoch tmp session identity lock_identity
  epoch="$state/.claude-autoarm-epoch"
  session=$(sed -n '1s/.*owner_session_id=\([^ ]*\).*/\1/p' "$epoch" 2>/dev/null)
  identity=$(PATH="$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$" 2>/dev/null)
  lock_identity=$(sed -n '3p' "$epoch" 2>/dev/null)
  tmp=$(mktemp "$epoch.XXXXXX") || return 1
  { printf 'epoch=2 owner_pid=%s outcome=clean updated_at=%s' "$$" "$(date +%s)"
    [ -z "$session" ] || printf ' owner_session_id=%s' "$session"
    printf '\n%s\n' "${identity:-none}"
    [ -z "$lock_identity" ] || printf '%s\n' "$lock_identity"
  } > "$tmp" && mv -f "$tmp" "$epoch"
}
supersede_generation "$LAB_PRIMARY" || fail "could not supersede the owning generation"$'\n'"$(diagnose "$LAB_PRIMARY")"
evidence "step 3: recorded completed epoch=2 over the hook's claim (pid $HOOK_PID); ledger: $(ledger "$LAB_PRIMARY")"
wait_until 300 bash -c '[ -s "$1" ]' _ "$LAB_PRIMARY/fm/state/.supervision-handoff-owner" \
  || fail "the detached owner never started"$'\n'"$(diagnose "$LAB_PRIMARY")"
OWNER_PID=$(handoff_owner_pid "$LAB_PRIMARY")
wait_until 300 bash -c 'kill -0 "$1" 2>/dev/null' _ "$OWNER_PID" \
  || fail "the detached owner is not running"$'\n'"$(diagnose "$LAB_PRIMARY")"
evidence "step 3: detached owner pid $OWNER_PID verified running on the superseded generation's arm"

wait_until 300 bash -c 'kill -0 "$1" 2>/dev/null' _ "$OWNER_PID" \
  || fail "the detached owner died when the continuation was lost"$'\n'"$(diagnose "$LAB_PRIMARY")"
wait_until 300 watcher_live "$LAB_PRIMARY" || fail "the lost continuation left no verified watcher"$'\n'"$(diagnose "$LAB_PRIMARY")"
sleep 3
[ -z "$(rewakes_since "$LAB_PRIMARY" "$e1")" ] \
  || fail "the killed hook still delivered a rewake; the retry path is not what is being proven"$'\n'"$(diagnose "$LAB_PRIMARY")"
[ "$(pending_token "$LAB_PRIMARY")" = "$TOKEN" ] || fail "the pending token moved without an acknowledgement"
SURVIVING_WATCHER=$(watcher_pid "$LAB_PRIMARY")
SURVIVING_IDENTITY=$(PATH="$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$SURVIVING_WATCHER")
RETRY_ARM=$(cut -f1 "$LAB_PRIMARY/fm/state/.supervision-host-left")
[ -n "$SURVIVING_IDENTITY" ] && [ -n "$RETRY_ARM" ] \
  || fail "the retry owner left no identifiable watcher or recorded arm"
evidence "step 3: no Stop-hook rewake reached the transcript; owner $OWNER_PID alive on watcher $SURVIVING_WATCHER ($SURVIVING_IDENTITY), recorded arm $RETRY_ARM; pending $TOKEN unchanged"

# The detached owner retries the record-backed doorbell into the inherited
# pane only; a confirmed submit verdict is logged but is never acknowledgement.
wait_until "$TURN_POLLS" retry_confirmed "$LAB_PRIMARY" "$TOKEN" \
  || fail "the detached retry never confirmed a submission to the inherited pane"$'\n'"$(diagnose "$LAB_PRIMARY")"
RETRY_ROW=$(awk -F '\t' -v t="$TOKEN" '$2 == "retry" && $3 == t && ($4 == "empty" || $4 == "queued-enter") { print; exit }' "$LAB_PRIMARY/fm/state/.supervision-handoff.log")
evidence "step 4: retry confirmed delivery - handoff log: $RETRY_ROW"
wait_until "$TURN_POLLS" doorbell_seen "$LAB_PRIMARY" "$e1" \
  || fail "the doorbell never reached the primary's transcript"$'\n'"$(diagnose "$LAB_PRIMARY")"
evidence "step 4: doorbell delivered as a primary message at $(doorbells_since "$LAB_PRIMARY" "$e1" | head -n 1)"
[ -e "$LAB_PRIMARY/fm/state/.supervision-handoff-pending" ] \
  || fail "submission alone removed the pending marker - only acknowledgement may do that"

# The primary handles the record's queued check and runs the exact
# sequence-bound acknowledgement; only then does the pending marker clear.
i=0
while ! acked_since "$LAB_PRIMARY" "$e1"; do
  [ -e "$LAB_PRIMARY/fm/state/.supervision-handoff-pending" ] \
    || fail "the pending marker disappeared before the acknowledgement ran"$'\n'"$(diagnose "$LAB_PRIMARY")"
  i=$((i + 1))
  [ "$i" -lt $((TURN_POLLS * 2)) ] || fail "the primary never ran the acknowledgement"$'\n'"$(diagnose "$LAB_PRIMARY")"
  sleep 0.1
done
evidence "step 5: primary drained and acknowledged - commands: $(commands_since "$LAB_PRIMARY" "$e1" | tr '\n' ';' | cut -c1-240)"
wait_until 300 pending_gone "$LAB_PRIMARY" \
  || fail "the exact acknowledgement did not remove the pending marker"$'\n'"$(diagnose "$LAB_PRIMARY")"
evidence "step 5: pending marker removed only after the acknowledgement"
! grep -q "supervision-handoff:$TOKEN" "$LAB_PRIMARY/fm/state/.wake-queue" 2>/dev/null \
  || fail "the acknowledged check row is still queued"
wait_until 300 pid_dead "$OWNER_PID" \
  || fail "the detached owner kept running after acknowledgement"$'\n'"$(diagnose "$LAB_PRIMARY")"
wait_until "$TURN_POLLS" turn_idle "$LAB_PRIMARY" "$e1" || fail "the doorbell turn never ended"$'\n'"$(diagnose "$LAB_PRIMARY")"
evidence "step 5: owner $OWNER_PID exited; queued check consumed; the doorbell turn ended"

# The next park takes over the owner's recorded arm, retiring its watcher
# before starting the replacement cycle (not merely attaching to a live pid).
wait_until "$TURN_POLLS" host_live "$LAB_PRIMARY" || fail "no host parked after the acknowledged turn"$'\n'"$(diagnose "$LAB_PRIMARY")"
wait_until 300 env PATH="$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; [ "$(fm_pid_identity "$2" 2>/dev/null)" != "$3" ]' _ "$ROOT" "$SURVIVING_WATCHER" "$SURVIVING_IDENTITY" \
  || fail "the retry owner's watcher survived as an orphan after takeover"
wait_until 300 watcher_live "$LAB_PRIMARY" || fail "the next park left no watcher"$'\n'"$(diagnose "$LAB_PRIMARY")"
[ ! -e "$LAB_PRIMARY/fm/state/.supervision-handoff-owner" ] \
  || fail "the handoff owner record survived acknowledgement"
host_log_since "$LAB_PRIMARY" "$e1" "$(printf '\ttake-over\tarm=%s$' "$RETRY_ARM")" | grep -q . \
  || fail "the next park did not take over retry arm $RETRY_ARM"$'\n'"$(diagnose "$LAB_PRIMARY")"
NEXT_WATCHER=$(watcher_pid "$LAB_PRIMARY")
NEXT_IDENTITY=$(PATH="$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$NEXT_WATCHER")
[ "$NEXT_WATCHER:$NEXT_IDENTITY" != "$SURVIVING_WATCHER:$SURVIVING_IDENTITY" ] \
  || fail "the next park only attached to the surviving watcher instead of taking over"
evidence "step 6: turn end re-armed: $(host_log_since "$LAB_PRIMARY" "$e1" '	start	gen=' | tail -n 1 | cut -f1-3); watcher $(watcher_pid "$LAB_PRIMARY") under host $(awk -F '\t' '$1 == "host" { print $2; exit }' "$LAB_PRIMARY/fm/state/.supervision-host")"
evidence "proof complete: lost hand-back -> herdr retry delivered to $HERDR_LAB_SESSION:$PANE -> drained -> acknowledged -> pending cleared -> one watcher retained"
pass "herdr live e2e: a lost Claude hand-back is recovered by the detached retry, acknowledged, and supervision retained"
