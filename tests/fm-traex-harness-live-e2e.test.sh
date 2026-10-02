#!/usr/bin/env bash
# Opt-in real TraeX/Herdr smoke for the thin ordinary worker adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_TRAEX_HERDR_LIVE traex herdr jq treehouse

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
REAL_HERDR=$(command -v herdr 2>/dev/null || true)
LAB=
PROBE=
REPO=
WT=
CLEAN_PATH=$PATH

cleanup() {
  local pool
  if [ -n "$LAB" ]; then
    PATH="$CLEAN_PATH" "$HELPER" teardown "$LAB" || { echo "not ok - default-session isolation tripwire failed" >&2; exit 1; }
  fi
  if [ -n "$WT" ] && [ -d "$WT" ] && [ -n "$REPO" ] && [ -d "$REPO/.git" ] \
     && [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    if git -C "$REPO" worktree remove "$WT" >/dev/null 2>&1; then
      case "$WT" in
        */.treehouse/demo-*/1/demo)
          pool=${WT%/1/demo}
          if [ ! -e "$WT" ] && [ -d "$pool/1" ] \
             && [ -z "$(find "$pool/1" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            rm -rf -- "$pool"
          fi
          ;;
      esac
    fi
  fi
  [ -z "$PROBE" ] || rm -rf -- "$PROBE"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v traex >/dev/null 2>&1 || fail 'real traex executable is not installed'
[ -x "$REAL_HERDR" ] || fail 'real herdr executable is not installed'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v treehouse >/dev/null 2>&1 || fail 'treehouse is required'

LAB=$("$HELPER" name "${FM_TRAEX_HERDR_LAB_TASK:-traex-thin}") || fail 'could not allocate guarded lab name'
trap cleanup EXIT
trap 'exit 130' INT TERM
"$HELPER" provision "$LAB" || fail 'could not provision guarded Herdr lab'
PROBE=$(mktemp -d "${TMPDIR:-/tmp}/fm-traex-thin.XXXXXX") || fail 'could not create disposable home'
mkdir -p "$PROBE/home/projects" "$PROBE/home/data/traex-live" \
  "$PROBE/home/state" "$PROBE/home/config" "$PROBE/wrap" || fail 'could not scaffold disposable home'
printf '%s\n' off > "$PROBE/home/config/herdr-presentation-spaces"

REPO="$PROBE/home/projects/demo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main || fail 'could not initialize disposable project'
git -C "$REPO" config user.name 'TraeX thin smoke'
git -C "$REPO" config user.email 'traex-thin@example.invalid'
printf '%s\n' '# disposable TraeX thin smoke' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m init || fail 'could not commit disposable project'
FIRST_ACTED="$PROBE/first-acted"
SECOND_ACTED="$PROBE/second-acted"
AFTER_ACTED="$PROBE/after-interrupt-acted"
cat > "$PROBE/home/data/traex-live/brief.md" <<EOF
# Task

## Captain's intent

This is a disposable Firstmate TraeX smoke in an isolated Git task copy.
Run sleep 2, then touch $FIRST_ACTED, then reply with exactly TRAEX_THIN_FIRST_OK and wait.
Do not edit project files. The named external marker files are the only permitted test writes.

## Firstmate spec

Exercise only the guarded TraeX/Herdr launch, steering, interrupt, state, and cleanup paths in this disposable lab.
EOF

cat > "$PROBE/wrap/herdr" <<EOF
#!/usr/bin/env bash
set -eu
real=$(printf '%q' "$REAL_HERDR")
helper=$(printf '%q' "$HELPER")
lab=$(printf '%q' "$LAB")
log=$(printf '%q' "$PROBE/herdr-wrapper.log")
if [ "\${FM_TRAEX_LAB_ACTIVE:-}" = 1 ]; then exec "\$real" "\$@"; fi
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
  --model Seed-Evolving --effort high 2>&1) || fail "real TraeX spawn failed: $SPAWN_OUT"
printf '%s\n' "$SPAWN_OUT" | grep -Fq 'spawned traex-live harness=traex kind=scout' \
  || fail "spawn omitted success identity: $SPAWN_OUT"
META="$PROBE/home/state/traex-live.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
TARGET=$(sed -n 's/^window=//p' "$META")
PANE=${TARGET#*:}
[ -n "$WT" ] && [ -n "$PANE" ] || fail 'spawn metadata omitted task copy or pane'
grep -qx 'harness=traex' "$META" || fail 'metadata omitted TraeX'
! grep -q '^traex_ready=' "$META" || fail 'thin adapter wrote TraeX readiness state'
[ -e "$PROBE/home/state/traex-live.busy-session" ] || fail 'missing transcript task binding'
grep -q '^pane read ' "$PROBE/herdr-wrapper.log" || fail 'fresh copy did not exercise rendered trust recognition'
[ "$(grep -c '^pane send-keys .* enter ' "$PROBE/herdr-wrapper.log")" -eq 2 ] \
  || fail 'fresh launch did not send one shell Enter and one verified trust Enter'
pass 'real TraeX fresh-copy trust reached native working through generic Herdr'

agent_status() {
  "$HELPER" run "$LAB" agent get "$PANE" | jq -r '.result.agent.agent_status // empty'
}

wait_status() {  # <status> [polls]
  local want=$1 polls=${2:-360} i=0 got=
  while [ "$i" -lt "$polls" ]; do
    got=$(agent_status)
    [ "$got" = "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'last native status: %s\n' "$got" >&2
  return 1
}

wait_nonworking_status() {  # [polls]
  local polls=${1:-360} i=0 got=
  while [ "$i" -lt "$polls" ]; do
    got=$(agent_status)
    case "$got" in
      working|'') ;;
      *) printf '%s\n' "$got"; return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  printf 'last native status: %s\n' "$got" >&2
  return 1
}

capture_has() {
  "$HELPER" run "$LAB" pane read "$PANE" --source recent --lines 200 | grep -Fq "$1"
}

wait_capture() {  # <text> [polls]
  local want=$1 polls=${2:-360} i=0
  while [ "$i" -lt "$polls" ]; do
    capture_has "$want" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  "$HELPER" run "$LAB" pane read "$PANE" --source recent --lines 200 >&2 || true
  return 1
}

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

wait_acted() {
  local file=$1 i=0 polls=${FM_TRAEX_LIVE_WAIT_POLLS:-720}
  while [ "$i" -lt "$polls" ]; do
    [ ! -f "$file" ] || return 0
    sleep 0.5
    i=$((i + 1))
  done
  "$HELPER" run "$LAB" pane read "$PANE" --source recent --lines 80 | tail -40 >&2 || true
  return 1
}
wait_acted "$FIRST_ACTED" || fail 'TraeX did not execute the initial marker command'

INITIAL_STATUS=$(wait_nonworking_status) || fail 'initial TraeX turn never left native working'
case "$INITIAL_STATUS" in
  idle) ;;
  unknown) printf '%s\n' 'note: Herdr kept native status unknown after the completed TraeX turn' ;;
  *) fail "completed initial TraeX turn had unexpected native status '$INITIAL_STATUS'" ;;
esac
pass 'real TraeX processed the benign initial instruction after guarded trust acceptance'
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# Native status can remain unknown after a completed turn. Exercise the
# production Herdr status plus exact process-liveness path on that host.
. "$ROOT/bin/fm-busy-lib.sh"
fm_backend_source herdr || fail 'could not load the retained Herdr adapter'
wait_semantic() {
  local want=$1 i=0 verdict
  while [ "$i" -lt 240 ]; do
    verdict=$(fm_busy_classify_meta "$META" traex-live "$PROBE/home/state")
    case "$verdict" in "$want "*) return 0 ;; esac
    sleep 0.5
    i=$((i + 1))
  done
  printf 'last semantic state: %s\n' "$verdict" >&2
  return 1
}
wait_semantic idle || fail 'completed TraeX turn has no verified semantic idle state'
send_text "Run sleep 5, then touch '$SECOND_ACTED', then reply with exactly TRAEX_THIN_SECOND_OK."
wait_semantic busy || fail 'steered TraeX turn never became semantically busy'
wait_acted "$SECOND_ACTED" || fail 'TraeX did not process durable generic steer'
wait_semantic idle || fail 'steered TraeX turn never settled'
pass 'real TraeX durable steering and current state use native Herdr status plus exact process liveness'

send_text 'Run sleep 20, then reply TRAEX_THIN_SHOULD_NOT_COMPLETE.'
wait_semantic busy || fail 'interrupt probe never reached a live TraeX turn'
send_key Escape
wait_semantic idle || fail 'TraeX interrupt did not return semantic idle'
. "$ROOT/bin/fm-control-lib.sh"
send_key "$(fm_control_interrupt_clear_key traex)"
composer=
for _ in $(seq 1 50); do
  composer=$(fm_backend_composer_state herdr "$TARGET")
  [ "$composer" != empty ] || break
  sleep 0.1
done
[ "$composer" = empty ] || fail "TraeX interrupt composer did not settle empty (state=$composer)"
send_text "Run touch '$AFTER_ACTED', then reply with exactly TRAEX_THIN_AFTER_INTERRUPT_OK."
wait_acted "$AFTER_ACTED" || fail 'post-interrupt steer was corrupted'
wait_semantic idle || fail 'post-interrupt TraeX turn never settled'
pass 'real TraeX interrupt clearing stays on generic key and send paths'

[ -z "$(git -C "$WT" status --porcelain)" ] || fail 'smoke dirtied the isolated task copy'
fm_backend_kill herdr "$TARGET"
cleanup_state=
for _ in $(seq 1 50); do
  cleanup_state=$(fm_backend_agent_state herdr "$TARGET")
  case "$cleanup_state" in dead|missing) break ;; esac
  sleep 0.1
done
case "$cleanup_state" in
  dead|missing) ;;
  *) fail "generic Herdr cleanup did not remove the worker pane (state=$cleanup_state)" ;;
esac
pass 'real TraeX exit cleanup uses the generic Herdr owner'
printf 'traex=%s\n' "$(traex --version 2>&1 | head -1)"
PATH="$CLEAN_PATH" "$HELPER" teardown "$LAB" || fail 'guarded teardown or default-session tripwire failed'
LAB=
pass 'real TraeX lab teardown preserved the default Herdr session'
pass 'thin TraeX/Herdr smoke completed'
