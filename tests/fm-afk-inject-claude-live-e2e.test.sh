#!/usr/bin/env bash
# Live Claude-on-Herdr away delivery guard. An unknown daemon ancestry must
# still select a record-backed doorbell from the target pane's native identity.
# The same run checks that a fresh away scan skips statuses already presented
# to main and keeps new completions in the saved digest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AFK_INJECT_CLAUDE_LIVE herdr jq claude

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "not ok - missing guarded Herdr lab helper" >&2; exit 1; }
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afk-inject-flicker)
ORIGINAL_PATH=$PATH
LAB_DIR=$(mktemp -d "$ROOT/.afk-claude-live.XXXXXX")
DAEMON_PID=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$LAB_DIR"
  exit "$rc"
}
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$LAB_DIR/bin" "$LAB_DIR/home/state" "$LAB_DIR/project/.claude"
cat > "$LAB_DIR/bin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  exit 98
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-keys ]; then
  printf '%s\n' "\${args[3]:-}" >> "$LAB_DIR/keys.log"
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
EOF
chmod +x "$LAB_DIR/bin/herdr"
cat > "$LAB_DIR/project/.claude/settings.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"FM_HOME=$LAB_DIR/home $ROOT/bin/fm-turnend-guard.sh --claude"}]}]}}
EOF

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab"
export PATH="$LAB_DIR/bin:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
ws=$(lab workspace create --cwd "$LAB_DIR/project" --label afk-claude-live --no-focus) \
  || fail "could not create lab workspace"
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "no pane id"
target="$HERDR_LAB_SESSION:$pane"
lab pane run "$pane" "FM_HOME='$LAB_DIR/home' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not start Claude in the lab pane"

idle=0
for _ in $(seq 1 60); do
  st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  if [ "$st" = blocked ]; then
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'Allow external CLAUDE.md file imports?'*) lab pane send-keys "$pane" enter >/dev/null ;;
      *'Yes, I trust this folder'*) lab pane send-keys "$pane" down enter >/dev/null ;;
    esac
  fi
  case "$st" in idle|done) idle=1; break ;; esac
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude did not reach an idle composer"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
fm_backend_source herdr || fail "Herdr backend did not load"
[ "$(fm_backend_composer_state herdr "$target")" = empty ] \
  || fail "Claude composer was not positively empty before injection"
state="$LAB_DIR/home/state"
: > "$state/.status-presentation-cursor"
for n in $(seq 1 6); do
  f="$state/old-$n.status"
  printf 'done: old completion %s already presented\n' "$n" > "$f"
  ident=$(_fm_open_decisions_file_ident "$f")
  size=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  printf 'old-%s\t%s\t%s\t0\n' "$n" "$ident" "$size" >> "$state/.status-presentation-cursor"
done
for n in $(seq 1 24); do
  printf 'done: new completion %s, transport stress %096d\n' "$n" "$n" > "$state/new-$n.status"
done
touch "$state/.afk"

FM_HOME="$LAB_DIR/home" FM_STATE_OVERRIDE="$state" FM_DAEMON_PRIMARY_HARNESS=unknown \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$target" \
  FM_HEARTBEAT_SCAN_SECS=1 FM_ESCALATE_BATCH_SECS=3 FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  FM_MAX_DEFER_SECS=30 FM_INJECT_CONFIRM_RETRIES=3 FM_INJECT_CONFIRM_SLEEP=0.4 \
  "$ROOT/bin/fm-supervise-daemon.sh" > "$LAB_DIR/daemon.out" 2> "$LAB_DIR/daemon.err" &
DAEMON_PID=$!

record=
for _ in $(seq 1 120); do
  record=$(find "$state/operational-inbox" -type f -name '*.msg' -print -quit 2>/dev/null || true)
  [ -z "$record" ] || break
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon exited before delivery"
  sleep 0.5
done
[ -n "$record" ] || fail "long escalation never became a Claude operational record"
grep -Fq 'new-1.status: done: new completion' "$record" || fail "new completion missing from digest"
! grep -Fq 'old-1.status: done: old completion' "$record" \
  || fail "already presented completion replayed in digest"

delivered=0
for _ in $(seq 1 120); do
  screen=$(lab pane read "$pane" --source recent --lines 200 2>/dev/null || true)
  case "$screen" in
    *'Firstmate operational input waiting'*'Read 1 file'*) delivered=1; break ;;
  esac
  sleep 0.5
done
[ "$delivered" = 1 ] || fail "Claude did not start a turn and read the delivered record"
! grep -q 'ctrl+u' "$LAB_DIR/keys.log" 2>/dev/null \
  || fail "Herdr cleared the composer before a turn started"
pass "Claude on named Herdr lab receives a long away digest as one turn; old statuses stay out"
