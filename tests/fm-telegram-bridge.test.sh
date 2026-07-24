#!/usr/bin/env bash
# Focused fake-transport tests for authenticated Hermes Telegram intake/replies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-telegram-bridge.py"
TMP=$(fm_test_tmproot fm-telegram)
HOME1="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP")
LOG="$TMP/hermes.log"
mkdir -p "$HOME1/config/telegram-bridge" "$HOME1/state"
chmod 700 "$HOME1/config/telegram-bridge"
printf '%064d\n' 7 >"$HOME1/config/telegram-bridge/secret"
chmod 600 "$HOME1/config/telegram-bridge/secret"

cat >"$FAKEBIN/hermes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = plugins ]; then
  printf 'PLUGIN %s %s\n' "${2:-}" "${3:-}" >>"$FAKE_HERMES_LOG"
  exit 0
fi
[ "${1:-}" = send ] || exit 2
printf 'SEND %s\n' "$*" >>"$FAKE_HERMES_LOG"
cat >>"$FAKE_HERMES_LOG"
printf '\nEND\n' >>"$FAKE_HERMES_LOG"
[ ! -e "${FAKE_HERMES_FAIL_FILE:-/nonexistent}" ]
SH
chmod +x "$FAKEBIN/hermes"
export FAKE_HERMES_LOG="$LOG"

cat >"$HOME1/config/telegram-bridge/settings.json" <<EOF
{"version":1,"enabled":true,"owner_id":"12345","secret_file":"$HOME1/config/telegram-bridge/secret","hermes_home":"$TMP/hermes","hermes_bin":"$FAKEBIN/hermes","plugin_dir":"$TMP/hermes/plugins/firstmate-telegram","fm_home":"$HOME1","fm_root":"$ROOT","reply_max_chars":256}
EOF
chmod 600 "$HOME1/config/telegram-bridge/settings.json"

make_envelope() { # message-id text [owner] [kind]
  python3 - "$HOME1/config/telegram-bridge/secret" "$1" "$2" "${3:-12345}" "${4:-text}" <<'PY'
import hashlib,hmac,json,sys,time
secret=bytes.fromhex(open(sys.argv[1],encoding="ascii").read().strip())
message,text,owner,kind=sys.argv[2:]
identity={"platform":"telegram","chat_id":"-9988","message_id":message,"thread_id":"77"}
request_id="tg-"+hmac.new(secret,b"request-id\0"+json.dumps(identity,sort_keys=True,separators=(",",":")).encode(),hashlib.sha256).hexdigest()[:32]
value={"version":1,"issued_at":int(time.time()),"request_id":request_id,"platform":"telegram","user_id":owner,"chat_id":"-9988","message_id":message,"thread_id":"77","kind":kind,"text":text}
value["signature"]=hmac.new(secret,json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(),hashlib.sha256).hexdigest()
print(json.dumps(value,separators=(",",":")))
PY
}

REQUEST=$(make_envelope 101 '/firstmate inspect the queue')
RID=$(printf '%s' "$REQUEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
OUT=$(printf '%s' "$REQUEST" | python3 "$BRIDGE" ingest --fm-home "$HOME1") || fail "valid signed request was rejected"
[ "$OUT" = "$RID" ] || fail "accepted request did not return opaque correlation id"
[ "$(stat -c %a "$HOME1/state/telegram-inbox/$RID.json")" = 600 ] || fail "inbox record is not private"
[ "$(stat -c %a "$HOME1/state/telegram-context/$RID.json")" = 600 ] || fail "context record is not private"
! grep -R -F -- '-9988' "$HOME1/state/telegram-inbox" >/dev/null || fail "raw chat id leaked into worker-facing inbox"
pass "signed owner-bound request publishes private opaque inbox and context"

set +e
printf '%s' "$REQUEST" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >"$TMP/replay.out" 2>"$TMP/replay.err"
RC=$?
set -e
[ "$RC" = 3 ] || fail "replay should return duplicate exit 3, got $RC"
[ "$(find "$HOME1/state/telegram-inbox" -type f | wc -l | tr -d ' ')" = 1 ] || fail "replay duplicated inbox work"
pass "same Telegram message is replay-safe"

RESIGNED=$(python3 - "$HOME1/config/telegram-bridge/secret" "$REQUEST" <<'PY'
import hashlib,hmac,json,sys
secret=bytes.fromhex(open(sys.argv[1],encoding="ascii").read().strip())
value=json.loads(sys.argv[2])
value["issued_at"]=int(value["issued_at"])+30
unsigned={k:v for k,v in value.items() if k!="signature"}
value["signature"]=hmac.new(secret,json.dumps(unsigned,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(),hashlib.sha256).hexdigest()
print(json.dumps(value,separators=(",",":")))
PY
)
[ "$RESIGNED" != "$REQUEST" ] || fail "re-signed envelope was byte-identical to the original"
set +e
RESIGNED_OUT=$(printf '%s' "$RESIGNED" | python3 "$BRIDGE" ingest --fm-home "$HOME1")
RC=$?
set -e
[ "$RC" = 3 ] || fail "re-signed replay should return duplicate exit 3, got $RC"
[ "$RESIGNED_OUT" = "$RID" ] || fail "re-signed replay returned an unexpected correlation id"
[ "$(find "$HOME1/state/telegram-inbox" -type f | wc -l | tr -d ' ')" = 1 ] || fail "re-signed replay duplicated inbox work"
pass "same Telegram message re-signed with a later timestamp is replay-safe"

forged=$(printf '%s' "$REQUEST" | python3 -c 'import json,sys; v=json.load(sys.stdin); v["text"]="/firstmate forged"; print(json.dumps(v))')
set +e
printf '%s' "$forged" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >/dev/null 2>"$TMP/forged.err"
RC=$?
set -e
[ "$RC" = 5 ] || fail "forged HMAC was not rejected"
unauthorized=$(make_envelope 102 '/firstmate forbidden' 22222)
set +e
printf '%s' "$unauthorized" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >/dev/null 2>"$TMP/owner.err"
RC=$?
set -e
[ "$RC" = 5 ] || fail "wrong owner was not rejected"
unprefixed=$(make_envelope 103 'ordinary Hermes prompt')
set +e
printf '%s' "$unprefixed" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >/dev/null 2>"$TMP/prefix.err"
RC=$?
set -e
[ "$RC" = 5 ] || fail "unprefixed signed text crossed the command boundary"
pass "forged, wrong-owner, and unprefixed requests fail closed"

POLL1=$(python3 "$BRIDGE" poll --fm-home "$HOME1") || fail "poll failed"
[ "$POLL1" = "telegram-request $RID" ] || fail "poll emitted unexpected notification: $POLL1"
POLL2=$(python3 "$BRIDGE" poll --fm-home "$HOME1") || fail "second poll failed"
[ -z "$POLL2" ] || fail "poll offered the same request twice"
pass "watch intake offers each durable request once"

python3 "$BRIDGE" reply "$RID" 'Acknowledged safely.' --event acknowledgement --fm-home "$HOME1" >/dev/null || fail "reply failed"
SEND_COUNT=$(grep -c '^SEND ' "$LOG")
python3 "$BRIDGE" reply "$RID" 'Acknowledged safely.' --event acknowledgement --fm-home "$HOME1" >/dev/null || fail "idempotent reply retry failed"
[ "$(grep -c '^SEND ' "$LOG")" = "$SEND_COUNT" ] || fail "completed reply was sent twice"
grep -Fq -- '--to telegram:-9988:77 --file -' "$LOG" || fail "reply did not use correlated private chat/thread target"
pass "correlated Hermes reply is delivered once"

set +e
python3 "$BRIDGE" reply "$RID" 'api_key=abcdefghijk' --fm-home "$HOME1" >"$TMP/secret.out" 2>"$TMP/secret.err"
RC=$?
set -e
[ "$RC" = 5 ] || fail "credential-shaped reply was not rejected"
! grep -Fq 'abcdefghijk' "$TMP/secret.err" || fail "rejected credential leaked into diagnostics"
pass "credential-shaped outbound content is rejected without echo"

LONG=$(python3 -c 'print("word "*180)')
python3 "$BRIDGE" reply "$RID" "$LONG" --event milestone --fm-home "$HOME1" >/dev/null || fail "split reply failed"
CHUNKS=$(( $(grep -c '^SEND ' "$LOG") - SEND_COUNT ))
[ "$CHUNKS" -ge 2 ] && [ "$CHUNKS" -le 10 ] || fail "long reply split count is unsafe: $CHUNKS"
pass "long replies split within bounded Telegram delivery count"

FAIL_REQUEST=$(make_envelope 104 '/firstmate fail safely')
FAIL_RID=$(printf '%s' "$FAIL_REQUEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
printf '%s' "$FAIL_REQUEST" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >/dev/null || fail "failure fixture intake failed"
FAIL_FLAG="$TMP/fail-send"
touch "$FAIL_FLAG"
export FAKE_HERMES_FAIL_FILE="$FAIL_FLAG"
set +e
python3 "$BRIDGE" reply "$FAIL_RID" 'One attempt only.' --fm-home "$HOME1" >/dev/null 2>"$TMP/send-fail.err"
RC1=$?
rm -f "$FAIL_FLAG"
BEFORE=$(grep -c '^SEND ' "$LOG")
python3 "$BRIDGE" reply "$FAIL_RID" 'One attempt only.' --fm-home "$HOME1" >/dev/null 2>"$TMP/retry.err"
RC2=$?
set -e
[ "$RC1" = 6 ] && [ "$RC2" = 6 ] || fail "ambiguous delivery did not remain unresolved"
[ "$(grep -c '^SEND ' "$LOG")" = "$BEFORE" ] || fail "unresolved delivery was retried automatically"
pass "failed delivery refuses duplicate-risk retry"

cat >"$HOME1/state/task.meta" <<'EOF'
window=fm-task
worktree=/tmp/example
project=example
harness=pi
kind=ship
mode=direct-pr
yolo=0
EOF
python3 "$BRIDGE" link task "$RID" --fm-home "$HOME1" >/dev/null || fail "task correlation failed"
python3 "$BRIDGE" followup task 'Finished.' --event final --final --fm-home "$HOME1" >/dev/null || fail "final follow-up failed"
! grep -q '^telegram_request=' "$HOME1/state/task.meta" || fail "final follow-up did not clear task correlation"
python3 "$BRIDGE" ack "$RID" --fm-home "$HOME1" >/dev/null || fail "inbox acknowledgement failed"
[ ! -e "$HOME1/state/telegram-inbox/$RID.json" ] || fail "acknowledged inbox remained"
pass "task link, terminal follow-up, and inbox acknowledgement complete lifecycle"

SYMLINK_REQUEST=$(make_envelope 105 '/firstmate symlink attack')
SYMLINK_RID=$(printf '%s' "$SYMLINK_REQUEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
printf x >"$TMP/victim"
ln -s "$TMP/victim" "$HOME1/state/telegram-inbox/$SYMLINK_RID.json"
set +e
printf '%s' "$SYMLINK_REQUEST" | python3 "$BRIDGE" ingest --fm-home "$HOME1" >/dev/null 2>"$TMP/symlink.err"
RC=$?
set -e
[ "$RC" != 0 ] || fail "symlink destination was accepted"
[ "$(cat "$TMP/victim")" = x ] || fail "symlink target was modified"
pass "private spool refuses symlink destinations"

mkdir -p "$TMP/offline/state"
touch -d '10 minutes ago' "$TMP/offline/state/.last-watcher-beat"
set +e
FM_HOME="$TMP/offline" "$ROOT/bin/fm-telegram-ingest.sh" </dev/null >"$TMP/offline.out" 2>"$TMP/offline.err"
RC=$?
set -e
[ "$RC" = 4 ] || fail "offline intake did not return retryable exit 4"
[ ! -s "$TMP/offline.out" ] || fail "offline intake printed payload data"
pass "offline Firstmate refuses intake before reading a request"

INSTALL_HOME="$TMP/install-home"
HERMES_HOME_TEST="$TMP/hermes-home"
mkdir -p "$INSTALL_HOME/state" "$INSTALL_HOME/config" "$HERMES_HOME_TEST"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" install --enable --owner-id 12345 --hermes-home "$HERMES_HOME_TEST" --hermes-bin "$FAKEBIN/hermes" >/dev/null || fail "installer failed"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" install --enable --owner-id 12345 --hermes-home "$HERMES_HOME_TEST" --hermes-bin "$FAKEBIN/hermes" >/dev/null || fail "idempotent reinstall failed"
STATUS=$(FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" status) || fail "installed status failed"
assert_contains "$STATUS" 'enabled: yes' "status did not report enabled"
[ "$(stat -c %a "$INSTALL_HOME/config/telegram-bridge/secret")" = 600 ] || fail "installer secret mode is not 0600"
[ -f "$INSTALL_HOME/state/telegram-bridge.check-trust" ] || fail "watcher check was not trust-registered"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" stop >/dev/null || fail "stop failed"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" stop >/dev/null || fail "idempotent stop failed"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" start >/dev/null || fail "start failed"
pass "install, status, stop, and start are idempotent"

python3 - "$HERMES_HOME_TEST/plugins/firstmate-telegram/__init__.py" <<'PY' || fail "Hermes hook command/auth/voice contract failed"
import importlib.util,sys
path=sys.argv[1]
spec=importlib.util.spec_from_file_location("fmt_plugin",path)
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
seen=[]; mod._submit=lambda config,envelope: seen.append(envelope) or 0
class Source:
    platform="telegram"; chat_id="-9988"; thread_id="77"
    def __init__(self,user): self.user_id=user
class Event:
    def __init__(self,user,text,mid,kind="text"):
        self.source=Source(user); self.text=text; self.message_id=mid; self.message_type=kind; self.media_urls=[]
class Gateway:
    adapters={}
    def _is_user_authorized(self,source): return source.user_id=="12345"
g=Gateway()
assert mod.pre_gateway_dispatch(Event("12345","ordinary Hermes message","201"),g) is None
assert seen==[]
assert mod.pre_gateway_dispatch(Event("22222","/firstmate forbidden","202"),g)["action"]=="skip"
assert seen==[]
assert mod.pre_gateway_dispatch(Event("12345","/firstmate status","203"),g)["action"]=="skip"
assert len(seen)==1 and seen[0]["kind"]=="text" and seen[0]["text"]=="/firstmate status"
mod._transcribe=lambda event: "First mate, inspect queue"
assert mod.pre_gateway_dispatch(Event("12345","","204","voice"),g,session_store=object())["action"]=="skip"
assert len(seen)==2 and seen[1]["kind"]=="voice" and seen[1]["text"]=="/firstmate inspect queue"
assert mod.pre_gateway_dispatch(Event("22222","","205","voice"),g) is None
class Context:
    callback=None
    def register_hook(self,name,callback):
        assert name=="pre_gateway_dispatch"; self.callback=callback
ctx=Context(); mod.register(ctx); assert ctx.callback is mod.pre_gateway_dispatch
PY
pass "Hermes hook gates prefix and authorization and normalizes voice"

FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" uninstall >/dev/null || fail "uninstall failed"
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" uninstall >/dev/null || fail "idempotent uninstall failed"
set +e
FM_HOME="$INSTALL_HOME" "$ROOT/bin/fm-telegram-bridge.sh" status >"$TMP/uninstalled.status"
RC=$?
set -e
[ "$RC" = 1 ] || fail "uninstalled status should be nonzero"
[ ! -e "$HERMES_HOME_TEST/plugins/firstmate-telegram" ] || fail "plugin remained after uninstall"
pass "uninstall is guarded and status-safe"

CONC_HOME="$TMP/conc-home"
mkdir -p "$CONC_HOME/config/telegram-bridge" "$CONC_HOME/state"
chmod 700 "$CONC_HOME/config/telegram-bridge"
cp "$HOME1/config/telegram-bridge/secret" "$CONC_HOME/config/telegram-bridge/secret"
chmod 600 "$CONC_HOME/config/telegram-bridge/secret"
cat >"$CONC_HOME/config/telegram-bridge/settings.json" <<EOF
{"version":1,"enabled":true,"owner_id":"12345","secret_file":"$CONC_HOME/config/telegram-bridge/secret","hermes_home":"$TMP/hermes","hermes_bin":"$FAKEBIN/hermes","plugin_dir":"$TMP/hermes/plugins/firstmate-telegram","fm_home":"$CONC_HOME","fm_root":"$ROOT","reply_max_chars":256}
EOF
chmod 600 "$CONC_HOME/config/telegram-bridge/settings.json"
RACE_REQUEST=$(make_envelope 106 '/firstmate race the inbox')
NATURAL_REQUEST=$(make_envelope 107 '/firstmate natural race')
python3 - "$BRIDGE" "$CONC_HOME" "$RACE_REQUEST" "$NATURAL_REQUEST" <<'PY' || fail "concurrent duplicate intake regressed"
import importlib.util, io, json, sys, types
from contextlib import redirect_stdout
from pathlib import Path

bridge_path, home, race_raw, natural_raw = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fmt_bridge_conc", bridge_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

inbox_dir = Path(home) / "state" / "telegram-inbox"
context_dir = Path(home) / "state" / "telegram-context"

def run_ingest(raw):
    args = types.SimpleNamespace(fm_home=home)
    old_stdin = sys.stdin
    sys.stdin = types.SimpleNamespace(buffer=io.BytesIO(raw.encode()))
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            code = mod.command_ingest(args)
    except mod.BridgeError as exc:
        code = exc.code
    finally:
        sys.stdin = old_stdin
    return code, buf.getvalue().strip()

def count(directory):
    return len(list(directory.glob("*.json"))) if directory.exists() else 0

# Force the reported losing interleaving: caller A wins the inbox write, then a
# concurrent duplicate publishes the identical verified context a hair before
# A's own exclusive context link, so A's link reports the context already exists.
real_atomic_write = mod._atomic_write
raced = {"fired": False}
def racing_atomic_write(path, data, *, exclusive=False):
    if exclusive and path.parent.name == "telegram-context" and not raced["fired"]:
        raced["fired"] = True
        assert real_atomic_write(path, data, exclusive=True) is True
        return False
    return real_atomic_write(path, data, exclusive=exclusive)

mod._atomic_write = racing_atomic_write
code, rid = run_ingest(race_raw)
mod._atomic_write = real_atomic_write

assert raced["fired"], "concurrency injection never triggered"
assert code == mod.EXIT_DUPLICATE, f"racing caller must resolve as duplicate, got {code}"
assert count(inbox_dir) == 1 and count(context_dir) == 1, "race did not leave exactly one inbox and one context"
assert json.loads((inbox_dir / f"{rid}.json").read_text())["request_id"] == rid, "valid inbox correlation was deleted by the loser"

# Two identical signed ingests still resolve as one accepted plus one duplicate.
c1, o1 = run_ingest(natural_raw)
c2, o2 = run_ingest(natural_raw)
assert {c1, c2} == {0, mod.EXIT_DUPLICATE}, f"identical ingests must be one accept + one duplicate, got {c1} and {c2}"
assert o1 == o2, "identical ingests returned different correlation ids"
assert count(inbox_dir) == 2 and count(context_dir) == 2, "natural duplicate created a second inbox or context"
PY
pass "concurrent duplicate intake keeps exactly one inbox and one context"

! grep -R -F "$(cat "$HOME1/config/telegram-bridge/secret")" "$TMP" --exclude=secret --exclude=settings.json --exclude=bridge.json >/dev/null 2>&1 \
  || fail "bridge secret leaked outside private config"
pass "diagnostics and fake transport logs contain no bridge secret"
