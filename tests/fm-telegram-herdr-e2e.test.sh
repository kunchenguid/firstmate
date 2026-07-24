#!/usr/bin/env bash
# Real lifecycle smoke for Telegram intake -> Herdr task -> correlated final reply.
# Every direct Herdr operation uses fm-herdr-lab.sh and a generated non-default session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable"; exit 0; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-telegram-herdr.XXXXXX")
HERDR_LAB_SESSION=$(
  "$HERDR_LAB_HELPER" name fm-telegram-bridge-e2e
) || { rm -rf "$TMP_ROOT"; fail "could not name isolated Herdr lab"; }
case "$HERDR_LAB_SESSION" in
  fm-lab-*) ;;
  *) rm -rf "$TMP_ROOT"; fail "lab helper returned unsafe session name" ;;
esac
[ "$HERDR_LAB_SESSION" != default ] || { rm -rf "$TMP_ROOT"; fail "lab helper selected default session"; }
export HERDR_SESSION="$HERDR_LAB_SESSION"
LAB_READY=0
WT=
cleanup_all() {
  local status=0
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    treehouse return --force "$WT" >/dev/null 2>&1 || true
  fi
  if [ "$LAB_READY" -eq 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=$?
  fi
  rm -rf "$TMP_ROOT"
  return "$status"
}
on_exit() {
  local status=$?
  cleanup_all || status=$?
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab"
LAB_READY=1

STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA/tgwork" "$CONFIG/telegram-bridge"
chmod 700 "$CONFIG/telegram-bridge"
printf 'herdr\n' >"$CONFIG/backend"
printf 'lifecycle smoke only\n' >"$DATA/tgwork/brief.md"
printf '%064d\n' 9 >"$CONFIG/telegram-bridge/secret"
chmod 600 "$CONFIG/telegram-bridge/secret"

FAKE_HERMES="$TMP_ROOT/hermes"
SEND_LOG="$TMP_ROOT/send.log"
cat >"$FAKE_HERMES" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = send ] || exit 2
printf '%s\n' "$*" >>"$SEND_LOG"
cat >>"$SEND_LOG"
SH
chmod +x "$FAKE_HERMES"
export SEND_LOG
cat >"$CONFIG/telegram-bridge/settings.json" <<EOF
{"version":1,"enabled":true,"owner_id":"12345","secret_file":"$CONFIG/telegram-bridge/secret","hermes_home":"$TMP_ROOT/hermes-home","hermes_bin":"$FAKE_HERMES","plugin_dir":"$TMP_ROOT/plugin","fm_home":"$TMP_ROOT","fm_root":"$ROOT","reply_max_chars":3800}
EOF
chmod 600 "$CONFIG/telegram-bridge/settings.json"

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Firstmate Tests'
git -C "$PROJECT" config user.email tests@example.invalid
printf '# telegram lifecycle fixture\n' >"$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm initial

ENVELOPE=$(python3 - "$CONFIG/telegram-bridge/secret" <<'PY'
import hashlib,hmac,json,sys,time
secret=bytes.fromhex(open(sys.argv[1],encoding="ascii").read().strip())
identity={"platform":"telegram","chat_id":"-12345","message_id":"501","thread_id":""}
rid="tg-"+hmac.new(secret,b"request-id\0"+json.dumps(identity,sort_keys=True,separators=(",",":")).encode(),hashlib.sha256).hexdigest()[:32]
v={"version":1,"issued_at":int(time.time()),"request_id":rid,"platform":"telegram","user_id":"12345","chat_id":"-12345","message_id":"501","thread_id":"","kind":"text","text":"/firstmate run lifecycle smoke"}
v["signature"]=hmac.new(secret,json.dumps(v,sort_keys=True,separators=(",",":")).encode(),hashlib.sha256).hexdigest()
print(json.dumps(v,separators=(",",":")))
PY
) || fail "could not build signed lifecycle fixture"
RID=$(printf '%s' "$ENVELOPE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
printf '%s' "$ENVELOPE" | FM_HOME="$TMP_ROOT" python3 "$ROOT/bin/fm-telegram-bridge.py" ingest >/dev/null \
  || fail "signed Telegram lifecycle intake failed"
NOTICE=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-telegram-poll.sh") || fail "Telegram watcher check failed"
[ "$NOTICE" = "telegram-request $RID" ] || fail "watcher check did not surface opaque request id"
pass "real lifecycle: authenticated Telegram request reached Firstmate watcher intake"

OUT="$TMP_ROOT/spawn.out"
ERR="$TMP_ROOT/spawn.err"
env -u TMUX HERDR_ENV=1 FM_BACKEND=herdr FM_HOME="$TMP_ROOT" \
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" \
  FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" tgwork "$PROJECT" "sh -c 'echo telegram-herdr-lifecycle-ok; sleep 3'" \
  >"$OUT" 2>"$ERR" || fail "normal Firstmate spawn failed in isolated Herdr lab: $(cat "$ERR")"
META="$STATE/tgwork.meta"
[ -f "$META" ] || fail "spawn did not create task metadata"
grep -Fq "backend=herdr" "$META" || fail "spawn did not use Herdr"
grep -Fq "herdr_session=$HERDR_LAB_SESSION" "$META" || fail "spawn escaped named lab session"
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] && [ -n "$WT" ] || fail "spawn lacked pane or isolated copy"
sleep 1
CAPTURED=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 80) \
  || fail "lab helper could not inspect spawned task"
case "$CAPTURED" in
  *telegram-herdr-lifecycle-ok*) ;;
  *) fail "spawned task did not run in named Herdr lab" ;;
esac
pass "real lifecycle: normal Firstmate task ran only in generated Herdr lab session"

FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-telegram-link.sh" tgwork "$RID" >/dev/null || fail "task correlation failed"
printf 'Lifecycle validation completed in isolated session.\n' | FM_HOME="$TMP_ROOT" \
  "$ROOT/bin/fm-telegram-followup.sh" tgwork --event final --final - >/dev/null \
  || fail "correlated final Telegram delivery failed"
FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-telegram-ack.sh" "$RID" >/dev/null || fail "request acknowledgement failed"
grep -Fq -- '--to telegram:-12345 --file -' "$SEND_LOG" || fail "final reply missed signed Telegram target"
! grep -q '^telegram_request=' "$META" || fail "final reply did not clear Telegram task link"
pass "real lifecycle: task result returned once to correlated Telegram chat"

FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" \
  FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
  "$ROOT/bin/fm-teardown.sh" tgwork >"$TMP_ROOT/teardown.out" 2>&1 \
  || fail "normal task cleanup failed: $(cat "$TMP_ROOT/teardown.out")"
WT=
[ ! -e "$META" ] || fail "task metadata remained after cleanup"
"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null \
  || fail "guarded lab teardown or default-session tripwire failed"
LAB_READY=0
pass "real lifecycle: guarded helper teardown preserved default Herdr session"
