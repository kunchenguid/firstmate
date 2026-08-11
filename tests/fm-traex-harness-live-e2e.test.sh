#!/usr/bin/env bash
# Opt-in real TraeX/Herdr drift guard for the ordinary Firstmate worker path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
REAL_HERDR=$(command -v herdr 2>/dev/null || true)
LAB=
PROBE=
REPO=
WT=
CLEAN_PATH=$PATH

teardown_lab_checked() {
  [ -z "$LAB" ] && return 0
  PATH="$CLEAN_PATH" "$HELPER" teardown "$LAB" || return 1
  LAB=
}

cleanup() {
  local dirty=0 pool
  if ! teardown_lab_checked >/dev/null 2>&1; then
    printf 'warning: guarded TraeX lab teardown failed for %s\n' "$LAB" >&2
  fi
  if [ -n "$WT" ] && [ -d "$WT" ] && [ -n "$REPO" ] && [ -d "$REPO/.git" ]; then
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
      printf 'warning: preserving unexpectedly dirty TraeX probe copy at %s\n' "$WT" >&2
      dirty=1
    else
      if git -C "$REPO" worktree remove "$WT" >/dev/null 2>&1; then
        # treehouse leaves its now-empty per-repository pool journal behind
        # when a disposable source repository disappears in the same cleanup.
        # Remove only this guard's exact demo-*/1/demo pool after the worktree
        # itself is gone and its numbered slot is observably empty.
        case "$WT" in
          */.treehouse/demo-*/1/demo)
            pool=${WT%/1/demo}
            if [ ! -e "$WT" ] && [ -d "$pool/1" ] \
               && [ -z "$(find "$pool/1" -mindepth 1 -print -quit 2>/dev/null)" ]; then
              rm -rf -- "$pool"
            fi
            ;;
        esac
      else
        dirty=1
      fi
    fi
  fi
  if [ "$dirty" -eq 0 ] && [ -n "$PROBE" ]; then
    rm -rf -- "$PROBE"
  fi
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${1:-}" = --verify-lab-teardown ]; then
  [ "$#" -eq 2 ] || fail "--verify-lab-teardown requires one lab name"
  LAB=$2
  teardown_lab_checked || fail "guarded TraeX lab teardown failed for $LAB"
  exit 0
fi

if [ "${FM_TRAEX_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_TRAEX_HERDR_LIVE=1 to run the real TraeX/Herdr drift guard"
  exit 0
fi

command -v traex >/dev/null 2>&1 \
  || fail "FM_TRAEX_HERDR_LIVE=1 but no real traex executable is installed on PATH"
[ -x "$REAL_HERDR" ] \
  || fail "FM_TRAEX_HERDR_LIVE=1 but no real herdr executable is installed on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required for the TraeX/Herdr drift guard"
command -v treehouse >/dev/null 2>&1 || fail "treehouse is required for the TraeX/Herdr drift guard"

LAB=$("$HELPER" name traex-drift) || fail "could not allocate a guarded TraeX lab name"
trap cleanup EXIT
trap 'exit 130' INT TERM
"$HELPER" provision "$LAB" || fail "could not provision the guarded TraeX lab"
PROBE=$(mktemp -d "${TMPDIR:-/tmp}/fm-traex-drift.XXXXXX") \
  || fail "could not create the disposable TraeX home"
mkdir -p "$PROBE/home/projects" "$PROBE/home/data/traex-live" \
  "$PROBE/home/state" "$PROBE/home/config" "$PROBE/wrap" \
  || fail "could not scaffold the disposable TraeX home"
printf '%s\n' off > "$PROBE/home/config/herdr-presentation-spaces"

REPO="$PROBE/home/projects/demo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main || fail "could not initialize the disposable source project"
git -C "$REPO" config user.name 'TraeX drift guard'
git -C "$REPO" config user.email 'traex-drift@example.invalid'
printf '%s\n' '# disposable TraeX drift guard' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m init || fail "could not commit the disposable source project"
cat > "$PROBE/home/data/traex-live/brief.md" <<'EOF'
This is a disposable Firstmate lifecycle drift guard in an isolated Git task copy.
Run `sleep 2`, then reply with exactly TRAEX_LIVE_FIRST_OK and wait for more instructions.
Do not edit any file.
EOF

cat > "$PROBE/wrap/herdr" <<EOF
#!/usr/bin/env bash
set -eu
real=$(printf '%q' "$REAL_HERDR")
helper=$(printf '%q' "$HELPER")
lab=$(printf '%q' "$LAB")
log=$(printf '%q' "$PROBE/herdr-wrapper.log")
if [ "\${FM_TRAEX_LAB_ACTIVE:-}" = 1 ]; then
  exec "\$real" "\$@"
fi
printf '%q ' "\$@" >> "\$log"
printf '\n' >> "\$log"
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$lab" ] || exit 97
  unset 'args[n-1]' 'args[n-2]'
fi
FM_TRAEX_LAB_ACTIVE=1 exec "\$helper" run "\$lab" "\${args[@]}"
EOF
chmod +x "$PROBE/wrap/herdr"
: > "$PROBE/herdr-wrapper.log"

export PATH="$PROBE/wrap:$PATH"
export FM_HOME="$PROBE/home" FM_BACKEND=herdr HERDR_SESSION="$LAB" FM_SPAWN_NO_GUARD=1
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH 2>/dev/null || true

SPAWN_OUT=$("$ROOT/bin/fm-spawn.sh" traex-live "$REPO" --scout --harness traex \
  --model Doubao-Seed-2.1-Pro --effort high 2>&1) \
  || fail "real TraeX spawn failed: $SPAWN_OUT"
printf '%s\n' "$SPAWN_OUT" | grep -Fq 'spawned traex-live harness=traex kind=scout' \
  || fail "real TraeX spawn omitted its success identity: $SPAWN_OUT"

META="$PROBE/home/state/traex-live.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
TARGET=$(sed -n 's/^window=//p' "$META")
SESSION=${TARGET%%:*}
PANE=${TARGET#*:}
NATIVE_SESSION=$(sed -n 's/^traex_session_id=//p' "$META")
[ -n "$WT" ] && [ -n "$PANE" ] || fail "spawn metadata omitted the task copy or Herdr pane"
[[ "$NATIVE_SESSION" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail "spawn metadata omitted the exact native TraeX session identity"
grep -qx 'traex_ready=1' "$META" || fail "spawn never published TraeX lifecycle readiness"
grep -q '^agent explain ' "$PROBE/herdr-wrapper.log" \
  || fail "the fresh copy never exercised Herdr's structural TraeX trust rule"
[ "$(grep -c '^pane send-keys .* enter ' "$PROBE/herdr-wrapper.log")" -eq 2 ] \
  || fail "fresh launch did not send exactly one shell Enter and one verified trust Enter"
pass "real TraeX fresh-copy trust reached native working through the guarded Herdr lab"

agent_status() {
  "$HELPER" run "$LAB" agent get "$PANE" \
    | jq -r '.result.agent.agent_status // empty'
}

wait_idle() {
  local i=0 status=
  while [ "$i" -lt 360 ]; do
    status=$(agent_status)
    [ "$status" = idle ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'last native status: %s\n' "$status" >&2
  return 1
}

capture_has() {
  "$HELPER" run "$LAB" pane read "$PANE" --source recent --lines 200 | grep -Fq "$1"
}

# Load the public backend owner so the live native level is folded exactly as
# watcher reconnect recovery folds it.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
wait_idle || fail "the initial real TraeX turn never settled"
if fm_backend_herdr_wait_transition "$SESSION" 1 "$PROBE/home/state" "$TARGET" \
    > "$PROBE/initial-transition.out"; then
  TRANSITION_RC=0
else
  TRANSITION_RC=$?
fi
[ "$TRANSITION_RC" -eq 1 ] \
  || fail "the real Herdr event subscription did not complete a clean idle reconciliation (rc=$TRANSITION_RC)"
[ ! -s "$PROBE/initial-transition.out" ] \
  || fail "the idle completion was misreported as an actionable Herdr transition"
[ "$(fm_busy_classify herdr "$TARGET" traex traex-live "$PROBE/home/state")" = 'idle herdr-traex' ] \
  || fail "the initial real TraeX turn did not classify idle from its bound semantic record"
[ -e "$PROBE/home/state/traex-live.turn-ended" ] \
  || fail "the initial real TraeX completion emitted no durable notification"
capture_has TRAEX_LIVE_FIRST_OK || fail "TraeX did not process the initial task instructions"
pass "real TraeX initial instructions completed with a durable semantic transition"

send_text() {
  local text=$1 out
  touch "$PROBE/home/state/.last-watcher-beat"
  out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" traex-live "$text" 2>&1) \
    || fail "real TraeX steer failed: $out"
}

send_key() {
  local key=$1 out
  touch "$PROBE/home/state/.last-watcher-beat"
  out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" traex-live --key "$key" 2>&1) \
    || fail "real TraeX key '$key' failed: $out"
}

complete_cycle() {
  local token=$1
  rm -f "$PROBE/home/state/traex-live.turn-ended"
  send_text "Run sleep 1, then reply with exactly $token."
  [ "$(fm_busy_classify herdr "$TARGET" traex traex-live "$PROBE/home/state")" = 'busy herdr-traex' ] \
    || fail "$token was acknowledged without persisting native working"
  wait_idle || fail "$token never settled"
  fm_backend_herdr_traex_reconcile_current "$PROBE/home/state" "$SESSION" "$PANE" \
    || fail "idle $token could not be persisted"
  [ "$(fm_busy_classify herdr "$TARGET" traex traex-live "$PROBE/home/state")" = 'idle herdr-traex' ] \
    || fail "$token did not classify idle after settling"
  [ -e "$PROBE/home/state/traex-live.turn-ended" ] \
    || fail "$token emitted no durable completion notification"
  capture_has "$token" || fail "TraeX did not produce $token"
}

complete_cycle TRAEX_LIVE_SECOND_OK
complete_cycle TRAEX_LIVE_THIRD_OK
pass "real TraeX repeated send cycles preserved busy, idle, and completion semantics"

rm -f "$PROBE/home/state/traex-live.turn-ended"
send_text "Run \`sleep 20\`, then reply TRAEX_LIVE_SHOULD_NOT_COMPLETE."
[ "$(fm_busy_classify herdr "$TARGET" traex traex-live "$PROBE/home/state")" = 'busy herdr-traex' ] \
  || fail "the interrupt target was acknowledged without persisting native working"
send_key Escape
wait_idle || fail "TraeX Escape plus composer clear did not return native idle"
fm_backend_herdr_traex_reconcile_current "$PROBE/home/state" "$SESSION" "$PANE" \
  || fail "the interrupted idle level could not be persisted"
[ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] \
  || fail "TraeX Escape left restored input in the composer"
complete_cycle TRAEX_LIVE_RESUME_OK
pass "real TraeX interrupt cleared restored input and the same task resumed"

[ -z "$(git -C "$WT" status --porcelain)" ] \
  || fail "the real TraeX drift guard dirtied its isolated task copy"
printf 'traex=%s\n' "$(traex --version 2>&1 | head -1)"
printf 'herdr=%s\n' "$(PATH="$CLEAN_PATH" "$REAL_HERDR" --version 2>&1 | head -1)"
teardown_lab_checked || fail "guarded TraeX lab teardown failed or the default fleet session changed"
pass "real TraeX lab teardown preserved the default Herdr session"
pass "TraeX/Herdr live drift guard completed"
