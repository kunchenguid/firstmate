#!/usr/bin/env bash
# Real-Herdr regression for the projected-cleanup focus flash (upstream
# ogulcancelik/herdr#1621 family, live on 0.7.5 stable).
# Part A reproduces the OLD path: an explicit last-pane close that empties a
# non-focused workspace steals the focused workspace.
# Part B proves the mitigation: the focus-safe emptying-close plan
# (repositioning move plus pane-death removal) removes the doomed workspace
# with no focus change and no corrective tab focus at all.
# Part C covers the branch Part B structurally cannot reach - a doomed pane
# whose shell holds a persistent child, so the lone-idle-shell proof fails and
# the plan falls back to the plain explicit close - in the geometry where the
# closing workspace's right neighbour is not the anchor. It then checks the
# version floor that decides whether an unconfigured home is projected at all,
# against what Part A measured about this very release.
# On a future release whose explicit close preserves focus, Part A records
# that and Parts B and C keep outcome-only assertions, so no version is guessed.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-focus-flash-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-focus-flash-regression-r1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
SAMPLER_PID=
SAMPLER_STOP=
cleanup() {
  local status=$?
  if [ -n "$SAMPLER_STOP" ]; then
    : > "$SAMPLER_STOP"
  fi
  if [ -n "$SAMPLER_PID" ]; then
    wait "$SAMPLER_PID" 2>/dev/null || true
  fi
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
mkws() {  # <label> -> "<workspace_id> <tab_id> <pane_id>"
  lab workspace create --cwd "$ROOT" --label "$1" --no-focus \
    | jq -er '"\(.result.workspace.workspace_id) \(.result.tab.tab_id) \(.result.root_pane.pane_id)"'
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}
ws_order() { lab workspace list | jq -er '[.result.workspaces[].workspace_id] | join(",")'; }
wait_ws_gone() {  # <workspace_id>
  local i=0
  while [ "$i" -lt 80 ]; do
    lab workspace get "$1" >/dev/null 2>&1 || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- Part A: the OLD path (plain explicit close) steals focus on 0.7.5 -----
# The spacer keeps the focused anchor away from the doomed workspace's right
# neighbor, where the 0.7.5 explicit close would land by coincidence.
read -r A_DOOMED_WS _ A_DOOMED_PANE <<<"$(mkws flash-a-doomed)" || fail 'could not create the Part A doomed workspace'
read -r _ _ _ <<<"$(mkws flash-a-spacer)" || fail 'could not create the Part A spacer workspace'
read -r A_ANCHOR_WS A_ANCHOR_TAB _ <<<"$(mkws flash-a-anchor)" || fail 'could not create the Part A anchor workspace'
read -r _ _ _ <<<"$(mkws flash-a-tail)" || fail 'could not create the Part A tail workspace'
lab tab focus "$A_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part A anchor'
A_BEFORE=$(focus_snapshot) || fail 'could not capture the Part A pre-close focus'
[ "$A_BEFORE" = "$(printf '%s\t%s' "$A_ANCHOR_WS" "$A_ANCHOR_TAB")" ] \
  || fail 'Part A anchor focus does not match the intended workspace and tab'
lab pane close "$A_DOOMED_PANE" >/dev/null || fail 'Part A explicit close failed'
wait_ws_gone "$A_DOOMED_WS" || fail 'Part A doomed workspace survived the explicit close'
A_AFTER=$(focus_snapshot) || fail 'could not capture the Part A post-close focus'
STEAL_LIVE=0
if [ "$A_AFTER" != "$A_BEFORE" ]; then
  STEAL_LIVE=1
  pass "old path: the explicit last-pane close of a non-focused workspace stole focus ($A_BEFORE -> $A_AFTER)"
  lab tab focus "$A_ANCHOR_TAB" >/dev/null || fail 'could not restore the Part A anchor focus'
else
  pass 'old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions'
fi

# --- Part B: the mitigation in the dangerous geometry ----------------------
# The doomed workspace sits BEFORE the focused anchor and the anchor is not
# last, the exact shape where an unrepositioned pane death also steals focus.
read -r B_DOOMED_WS _ B_DOOMED_PANE <<<"$(mkws flash-b-doomed)" || fail 'could not create the Part B doomed workspace'
read -r B_ANCHOR_WS B_ANCHOR_TAB _ <<<"$(mkws flash-b-anchor)" || fail 'could not create the Part B anchor workspace'
read -r _ _ _ <<<"$(mkws flash-b-tail)" || fail 'could not create the Part B tail workspace'
lab tab focus "$B_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part B anchor'
B_BEFORE=$(focus_snapshot) || fail 'could not capture the Part B pre-close focus'
[ "$B_BEFORE" = "$(printf '%s\t%s' "$B_ANCHOR_WS" "$B_ANCHOR_TAB")" ] \
  || fail 'Part B anchor focus does not match the intended workspace and tab'
B_SURVIVOR_ORDER=$(ws_order | tr ',' '\n' | grep -v "^$B_DOOMED_WS\$" | paste -sd, -) \
  || fail 'could not capture the Part B survivor order'

CALL_LOG="$TMP_ROOT/call.log"
B_FOCUS_SAMPLES="$TMP_ROOT/focus.samples"
B_OPERATION_ACTIVE="$TMP_ROOT/operation.active"
B_SAMPLER_READY="$TMP_ROOT/sampler.ready"
SAMPLER_STOP="$TMP_ROOT/sampler.stop"
: > "$CALL_LOG"
: > "$B_FOCUS_SAMPLES"
(
  : > "$B_SAMPLER_READY"
  while [ ! -e "$SAMPLER_STOP" ]; do
    if [ -e "$B_OPERATION_ACTIVE" ]; then
      if B_SAMPLE=$(focus_snapshot); then
        printf '%s\n' "$B_SAMPLE" >> "$B_FOCUS_SAMPLES"
      else
        printf '%s\n' UNREADABLE >> "$B_FOCUS_SAMPLES"
      fi
    fi
  done
) &
SAMPLER_PID=$!
B_READY_ATTEMPT=0
while [ ! -e "$B_SAMPLER_READY" ] && [ "$B_READY_ATTEMPT" -lt 100 ]; do
  sleep 0.01
  B_READY_ATTEMPT=$((B_READY_ATTEMPT + 1))
done
[ -e "$B_SAMPLER_READY" ] || fail 'the Part B focus sampler did not start'
: > "$B_OPERATION_ACTIVE"
B_OUT=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_FLASH_CALL_LOG="$CALL_LOG" bash -c '
  . "$1/bin/backends/herdr.sh"
  fm_backend_herdr_cli() {
    local session=$1
    shift
    printf "%s\n" "$*" >> "$FM_FLASH_CALL_LOG"
    HERDR_SESSION="$session" herdr "$@" --session "$session"
  }
  fm_backend_herdr_projection_close_pane_focus_preserving "$2" "$3"
' _ "$ROOT" "$HERDR_LAB_SESSION" "$B_DOOMED_PANE" 2>&1)
B_STATUS=$?
rm -f "$B_OPERATION_ACTIVE"
: > "$SAMPLER_STOP"
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=
[ "$B_STATUS" -eq 0 ] || fail "the production focus-preserving close failed (status $B_STATUS): $B_OUT"
[ -s "$B_FOCUS_SAMPLES" ] || fail 'the Part B sampler captured no focus sample during the production close'
B_WRONG_SAMPLE=$(grep -Fvx -- "$B_BEFORE" "$B_FOCUS_SAMPLES" | head -1)
if [ -n "$B_WRONG_SAMPLE" ]; then
  fail "the mitigation exposed a wrong or unreadable in-operation focus sample ($B_BEFORE -> $B_WRONG_SAMPLE)"
fi
wait_ws_gone "$B_DOOMED_WS" || fail 'the mitigation left the doomed workspace behind'
if lab pane get "$B_DOOMED_PANE" >/dev/null 2>&1; then
  fail 'the mitigation left the doomed pane behind'
fi
B_AFTER=$(focus_snapshot) || fail 'could not capture the Part B post-close focus'
[ "$B_AFTER" = "$B_BEFORE" ] \
  || fail "the mitigation changed the exact focused workspace or tab ($B_BEFORE -> $B_AFTER)"
[ "$(ws_order)" = "$B_SURVIVOR_ORDER" ] \
  || fail "the mitigation left a lasting workspace order change ($B_SURVIVOR_ORDER -> $(ws_order))"
grep -q '^pane process-info' "$CALL_LOG" || fail 'the idle-shell proof never ran'
pass 'mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed'

if [ "$STEAL_LIVE" = 1 ]; then
  grep -q '^tab focus' "$CALL_LOG" \
    && fail 'the corrective tab focus fired, so a wrong-focus interval existed on the defective release'
  grep -q '^pane close' "$CALL_LOG" \
    && fail 'the focus-unsafe explicit close was used on the defective release'
  pass 'mitigation: no explicit close and no corrective focus were needed on the defective release'
fi

# --- Part C: the plain-close FALLBACK, the case Part B cannot reach ---------
# Part B always hands the adapter a freshly created workspace whose pane is a
# bare idle shell, so its emptying-close plan always takes the focus-preserving
# pane-death route. The reported defect lives on the other branch: a doomed pane
# whose shell holds a PERSISTENT child (a gitstatusd, a zsh-async worker,
# direnv, or anything a crewmate backgrounded) fails the lone-idle-shell proof
# permanently, and the plan falls back to the plain explicit close.
# The geometry puts the doomed workspace AFTER the anchor so the plan performs
# no repositioning at all, and puts a spacer immediately to its right so the
# closing workspace's right neighbour - where a defective release lands focus -
# is not the anchor. That is the exact shape the reporter saw.
read -r C_ANCHOR_WS C_ANCHOR_TAB _ <<<"$(mkws flash-c-anchor)" || fail 'could not create the Part C anchor workspace'
read -r C_DOOMED_WS _ C_DOOMED_PANE <<<"$(mkws flash-c-doomed)" || fail 'could not create the Part C doomed workspace'
read -r C_SPACER_WS _ _ <<<"$(mkws flash-c-spacer)" || fail 'could not create the Part C spacer workspace'
read -r _ _ _ <<<"$(mkws flash-c-tail)" || fail 'could not create the Part C tail workspace'
lab tab focus "$C_ANCHOR_TAB" >/dev/null || fail 'could not focus the Part C anchor'
C_BEFORE=$(focus_snapshot) || fail 'could not capture the Part C pre-close focus'
[ "$C_BEFORE" = "$(printf '%s\t%s' "$C_ANCHOR_WS" "$C_ANCHOR_TAB")" ] \
  || fail 'Part C anchor focus does not match the intended workspace and tab'

# Assert the geometry itself, so the case can never pass vacuously on a layout
# where the plain close would land on the anchor by coincidence.
C_ORDER=$(ws_order) || fail 'could not read the Part C workspace order'
C_RIGHT_NEIGHBOUR=$(printf '%s' "$C_ORDER" | tr ',' '\n' | grep -A1 -Fx "$C_DOOMED_WS" | tail -1)
[ "$C_RIGHT_NEIGHBOUR" = "$C_SPACER_WS" ] \
  || fail "Part C needs the spacer immediately right of the doomed workspace, got '$C_RIGHT_NEIGHBOUR'"
[ "$C_RIGHT_NEIGHBOUR" != "$C_ANCHOR_WS" ] \
  || fail 'Part C geometry is vacuous: the right neighbour of the doomed workspace is the anchor'
C_SURVIVOR_ORDER=$(printf '%s' "$C_ORDER" | tr ',' '\n' | grep -v "^$C_DOOMED_WS\$" | paste -sd, -) \
  || fail 'could not capture the Part C survivor order'

# One persistent background child of the pane's shell, started outside any
# worktree so nothing reaps it, is enough to fail the proof on every sample.
lab pane send-text "$C_DOOMED_PANE" 'cd / && sleep 3000 &' >/dev/null \
  || fail 'could not send the Part C persistent-child command'
lab pane send-keys "$C_DOOMED_PANE" enter >/dev/null \
  || fail 'could not submit the Part C persistent-child command'
C_SHELL_PID=
C_CHILD_ATTEMPT=0
C_CHILD_STABLE=0
while [ "$C_CHILD_ATTEMPT" -lt 100 ]; do
  C_SHELL_PID=$(lab pane process-info --pane "$C_DOOMED_PANE" 2>/dev/null \
    | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null) || C_SHELL_PID=
  if [ -n "$C_SHELL_PID" ] && ps -axo ppid=,comm= | awk -v parent="$C_SHELL_PID" '
    $1 == parent {
      command = $2
      sub(/^.*\//, "", command)
      if (command == "sleep") found = 1
    }
    END { exit(found ? 0 : 1) }
  '; then
    C_CHILD_STABLE=$((C_CHILD_STABLE + 1))
    [ "$C_CHILD_STABLE" -ge 2 ] && break
  else
    C_CHILD_STABLE=0
    C_SHELL_PID=
  fi
  sleep 0.1
  C_CHILD_ATTEMPT=$((C_CHILD_ATTEMPT + 1))
done
[ "$C_CHILD_STABLE" -ge 2 ] || fail 'the Part C doomed pane never acquired a stable persistent sleep child process'

C_CALL_LOG="$TMP_ROOT/call-c.log"
C_FOCUS_SAMPLES="$TMP_ROOT/focus-c.samples"
C_OPERATION_ACTIVE="$TMP_ROOT/operation-c.active"
C_SAMPLER_READY="$TMP_ROOT/sampler-c.ready"
SAMPLER_STOP="$TMP_ROOT/sampler-c.stop"
: > "$C_CALL_LOG"
: > "$C_FOCUS_SAMPLES"
(
  : > "$C_SAMPLER_READY"
  while [ ! -e "$SAMPLER_STOP" ]; do
    if [ -e "$C_OPERATION_ACTIVE" ]; then
      if C_SAMPLE=$(focus_snapshot); then
        printf '%s\n' "$C_SAMPLE" >> "$C_FOCUS_SAMPLES"
      else
        printf '%s\n' UNREADABLE >> "$C_FOCUS_SAMPLES"
      fi
    fi
  done
) &
SAMPLER_PID=$!
C_READY_ATTEMPT=0
while [ ! -e "$C_SAMPLER_READY" ] && [ "$C_READY_ATTEMPT" -lt 100 ]; do
  sleep 0.01
  C_READY_ATTEMPT=$((C_READY_ATTEMPT + 1))
done
[ -e "$C_SAMPLER_READY" ] || fail 'the Part C focus sampler did not start'
: > "$C_OPERATION_ACTIVE"
# A short proof budget keeps the exhausted-proof path fast; the count below is
# what proves the proof was exhausted rather than skipped.
C_PROOF_POLLS=3
C_OUT=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_FLASH_CALL_LOG="$C_CALL_LOG" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS="$C_PROOF_POLLS" bash -c '
  . "$1/bin/backends/herdr.sh"
  fm_backend_herdr_cli() {
    local session=$1
    shift
    printf "%s\n" "$*" >> "$FM_FLASH_CALL_LOG"
    HERDR_SESSION="$session" herdr "$@" --session "$session"
  }
  fm_backend_herdr_projection_close_pane_focus_preserving "$2" "$3"
' _ "$ROOT" "$HERDR_LAB_SESSION" "$C_DOOMED_PANE" 2>&1)
C_STATUS=$?
rm -f "$C_OPERATION_ACTIVE"
: > "$SAMPLER_STOP"
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=
[ "$C_STATUS" -eq 0 ] || fail "the production focus-preserving close failed (status $C_STATUS): $C_OUT"
wait_ws_gone "$C_DOOMED_WS" || fail 'the fallback close left the doomed workspace behind'
if lab pane get "$C_DOOMED_PANE" >/dev/null 2>&1; then
  fail 'the fallback close left the doomed pane behind'
fi
[ "$(ws_order)" = "$C_SURVIVOR_ORDER" ] \
  || fail "the fallback close left a lasting workspace order change ($C_SURVIVOR_ORDER -> $(ws_order))"

# Prove the FALLBACK is what ran, not the pane-death route Part B covers: the
# idle-shell proof must have been attempted and exhausted, and the explicit
# close must have been issued.
C_PROOF_CALLS=$(grep -c '^pane process-info' "$C_CALL_LOG" || true)
[ "$C_PROOF_CALLS" -eq "$C_PROOF_POLLS" ] \
  || fail "Part C did not exhaust the idle-shell proof ($C_PROOF_CALLS of $C_PROOF_POLLS samples); the persistent child did not block it"
grep -q '^pane close' "$C_CALL_LOG" \
  || fail 'Part C never reached the plain explicit close, so the fallback branch was not exercised'
pass 'fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close'

C_AFTER=$(focus_snapshot) || fail 'could not capture the Part C post-close focus'
[ "$C_AFTER" = "$C_BEFORE" ] \
  || fail "the fallback close left focus off the anchor ($C_BEFORE -> $C_AFTER)"
C_WRONG=$(grep -Fvxc -- "$C_BEFORE" "$C_FOCUS_SAMPLES" || true)
if [ "$STEAL_LIVE" = 1 ]; then
  # A defective release cannot make this path focus-safe, which is precisely why
  # default-on projection is floored above it. The wrong-focus window is
  # explicitly accepted here, but only as a BOUNDED one: the restore backstop
  # must have put the anchor back exactly, and the whole exposure must end with
  # the operation rather than parking the captain somewhere else.
  [ "$C_WRONG" -ge 1 ] \
    || fail 'Part C reached the fallback on a defective release but observed no wrong-focus sample at all, so the sampler proved nothing'
  pass "fallback on a defective release: a bounded wrong-focus window of $C_WRONG samples was fully restored to the anchor"
else
  [ "$C_WRONG" -eq 0 ] \
    || fail "a focus-preserving release exposed $C_WRONG wrong-focus samples on the fallback path"
  pass 'fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout'
fi

# The live guard on the version floor itself: Part A measured whether THIS
# release steals focus. Every above-floor release must preserve focus, while a
# below-floor release may conservatively include the known post-fix protocol-18
# preview without weakening the stated 0.8.0 policy floor.
STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
LIVE_VERSION=$(printf '%s' "$STATUS" | jq -r '.client.version')
LIVE_PROTOCOL=$(printf '%s' "$STATUS" | jq -r '.client.protocol')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$LIVE_PROTOCOL" "$LIVE_VERSION")
case "$FLOOR_VERDICT" in
  0)
    [ "$STEAL_LIVE" = 0 ] \
      || fail "herdr $LIVE_VERSION (protocol $LIVE_PROTOCOL) is at or above the floor but steals focus on the explicit close"
    pass "version floor: herdr $LIVE_VERSION protocol $LIVE_PROTOCOL is at or above the floor and preserves focus"
    ;;
  1)
    pass "version floor: herdr $LIVE_VERSION protocol $LIVE_PROTOCOL remains conservatively below the floor with steal_live=$STEAL_LIVE"
    ;;
  *) fail "herdr $LIVE_VERSION (protocol $LIVE_PROTOCOL) could not be classified against the presentation floor" ;;
esac

# The end-user gate: an unconfigured home must project only at or above the
# floor, and an explicit opt-in must survive either way.
FLOOR_CONFIG="$TMP_ROOT/floor-config"
FLOOR_STATE="$TMP_ROOT/floor-state"
mkdir -p "$FLOOR_CONFIG" "$FLOOR_STATE"
gate_verdict() {  # <config-dir> -> on|off, warnings on stderr
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    if fm_backend_herdr_presentation_enabled "$1" "$2"; then printf "on\n"; else printf "off\n"; fi
  ' "$ROOT" "$1" "$FLOOR_STATE"
}
GATE_ERR="$TMP_ROOT/gate.err"
GATE_DEFAULT=$(gate_verdict "$FLOOR_CONFIG" 2>"$GATE_ERR")
printf 'on\n' > "$FLOOR_CONFIG/herdr-presentation-spaces"
GATE_OPT_IN=$(gate_verdict "$FLOOR_CONFIG" 2>/dev/null)
[ "$GATE_OPT_IN" = on ] \
  || fail "an explicit opt-in must stay on for herdr $LIVE_VERSION, got '$GATE_OPT_IN'"
if [ "$FLOOR_VERDICT" = 1 ]; then
  [ "$GATE_DEFAULT" = off ] \
    || fail "an unconfigured home must not be projected on below-floor herdr $LIVE_VERSION, got '$GATE_DEFAULT'"
  grep -q "$LIVE_VERSION" "$GATE_ERR" \
    || fail "the below-floor fallback must name herdr $LIVE_VERSION: $(cat "$GATE_ERR")"
  pass "version floor: an unconfigured home falls back flat on herdr $LIVE_VERSION and the explicit opt-in still projects"
else
  [ "$GATE_DEFAULT" = on ] \
    || fail "an unconfigured home must stay projected on herdr $LIVE_VERSION, got '$GATE_DEFAULT'"
  [ ! -s "$GATE_ERR" ] \
    || fail "a supported release must warn about nothing: $(cat "$GATE_ERR")"
  pass "version floor: an unconfigured home stays projected on herdr $LIVE_VERSION and the explicit opt-in agrees"
fi

printf 'evidence: herdr=%s protocol=%s steal_live=%s floor_verdict=%s default-session-tripwire=armed\n' \
  "$LIVE_VERSION" "$LIVE_PROTOCOL" "$STEAL_LIVE" "$FLOOR_VERDICT"
