#!/usr/bin/env bash
# Opt-in real TraeX/Herdr smoke for the thin ordinary worker adapter.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr 2>/dev/null || true)
LAB=
PROBE=
REPO=
WT=
CLEAN_PATH=$PATH

cleanup() {
  local pool
  if [ -n "$LAB" ]; then
    PATH="$CLEAN_PATH" "$HELPER" teardown "$LAB" >/dev/null 2>&1 || true
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

if [ "${FM_TRAEX_HERDR_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_TRAEX_HERDR_LIVE=1 to run the real TraeX/Herdr smoke'
  exit 0
fi

command -v traex >/dev/null 2>&1 || fail 'real traex executable is not installed'
[ -x "$REAL_HERDR" ] || fail 'real herdr executable is not installed'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v treehouse >/dev/null 2>&1 || fail 'treehouse is required'

LAB=$("$HELPER" name traex-thin) || fail 'could not allocate guarded lab name'
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
cat > "$PROBE/home/data/traex-live/brief.md" <<'EOF'
This is a disposable Firstmate TraeX smoke in an isolated Git task copy.
Run `sleep 2`, then reply with exactly TRAEX_THIN_FIRST_OK and wait.
Do not edit any file.
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
  --model Doubao-Seed-2.1-Pro --effort high 2>&1) || fail "real TraeX spawn failed: $SPAWN_OUT"
printf '%s\n' "$SPAWN_OUT" | grep -Fq 'spawned traex-live harness=traex kind=scout' \
  || fail "spawn omitted success identity: $SPAWN_OUT"
META="$PROBE/home/state/traex-live.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
TARGET=$(sed -n 's/^window=//p' "$META")
PANE=${TARGET#*:}
[ -n "$WT" ] && [ -n "$PANE" ] || fail 'spawn metadata omitted task copy or pane'
grep -qx 'harness=traex' "$META" || fail 'metadata omitted TraeX'
! grep -q '^traex_ready=' "$META" || fail 'thin adapter wrote TraeX readiness state'
[ ! -e "$PROBE/home/state/traex-live.busy-gen" ] || fail 'thin adapter armed custom lifecycle state'
grep -q '^agent explain ' "$PROBE/herdr-wrapper.log" || fail 'fresh copy did not exercise structural trust'
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

capture_has() {
  "$HELPER" run "$LAB" pane read "$PANE" --source recent --lines 200 | grep -Fq "$1"
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

wait_status idle || fail 'initial TraeX turn never settled'
capture_has TRAEX_THIN_FIRST_OK || fail 'TraeX did not process initial instructions'
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
[ "$(fm_backend_busy_state herdr "$TARGET")" = idle ] || fail 'generic Herdr idle observation failed'
send_text "Run \`sleep 2\`, then reply with exactly TRAEX_THIN_SECOND_OK."
[ "$(fm_backend_busy_state herdr "$TARGET")" = busy ] || fail 'generic Herdr busy observation failed'
wait_status idle || fail 'steered TraeX turn never settled'
capture_has TRAEX_THIN_SECOND_OK || fail 'TraeX did not process generic steer'
pass 'real TraeX steering and current state use generic Herdr owners'

send_text "Run \`sleep 20\`, then reply TRAEX_THIN_SHOULD_NOT_COMPLETE."
send_key Escape
wait_status idle || fail 'TraeX interrupt did not return native idle'
[ "$(fm_backend_composer_state herdr "$TARGET")" = empty ] \
  || fail 'TraeX interrupt left restored input in the composer'
send_text 'Reply with exactly TRAEX_THIN_AFTER_INTERRUPT_OK.'
wait_status idle || fail 'post-interrupt TraeX turn never settled'
capture_has TRAEX_THIN_AFTER_INTERRUPT_OK || fail 'post-interrupt steer was corrupted'
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
printf 'herdr=%s\n' "$(PATH="$CLEAN_PATH" "$REAL_HERDR" --version 2>&1 | head -1)"
PATH="$CLEAN_PATH" "$HELPER" teardown "$LAB" || fail 'guarded teardown or default-session tripwire failed'
LAB=
pass 'real TraeX lab teardown preserved the default Herdr session'
pass 'thin TraeX/Herdr smoke completed'
