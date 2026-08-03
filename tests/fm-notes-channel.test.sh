#!/usr/bin/env bash
# Behavior-level offline tests for the guarded Apple Notes channel owner.
# Every Notes interaction uses the deterministic fake provider through the public
# CLI.  No live Notes, Apple Event, TCC, iCloud, login item, or runtime pointer is
# accessed or changed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-notes-channel.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
CHANNEL="$ROOT/bin/fm-notes-channel.sh"
FIXTURE_TOOL="$TMP/fixture.py"
cat > "$FIXTURE_TOOL" <<'PY'
import argparse,html,json,sys,uuid
from pathlib import Path

NAMES={
 "root":"Firstmate","guide":"00 Guide","inbox":"10 Inbox",
 "acknowledgments":"20 Acknowledgments","outbox":"30 Outbox","archive":"90 Archive",
 "archive_inbound":"Inbound","archive_acknowledgments":"Acknowledgments","archive_outbound":"Outbound",
}
def binding():
 out={"account":{"id":"acc-icloud","name":"iCloud"}}
 ids={k:"folder-"+k for k in NAMES}
 for key,name in NAMES.items():
  parent="acc-icloud" if key=="root" else (ids["archive"] if key.startswith("archive_") else ids["root"])
  out[key]={"id":ids[key],"name":name,"parent_id":parent,"shared":False}
 return out
def load(path): return json.loads(Path(path).read_text())
def save(path,value): Path(path).write_text(json.dumps(value,sort_keys=True),encoding="utf-8")
def envelope(title,intent="status",client="auto",body="Please report status.",created="1970-01-01T00:01:40Z",extra="",kind="command",reply="-"):
 fields=["direction: inbound","sender: captain",f"kind: {kind}"]
 if kind in {"command","query"}: fields.append(f"command: {intent}")
 fields += [f"client_id: {client}",f"reply_to: {reply}",f"created_at: {created}","final: yes"]
 if extra: fields.append(extra)
 return title+"\n\nFIRSTMATE-NOTE/1\n"+"\n".join(fields)+"\n---\n"+body
def note(note_id,title="Check status",intent="status",client="auto",body="Please report status.",created="1970-01-01T00:01:40Z",modified=None,extra="",kind="command",reply="-",attachments=0,locked=False,shared=False,html_mode="safe"):
 text=envelope(title,intent,client,body,created,extra,kind,reply)
 if html_mode=="safe": h="<div>"+html.escape(text).replace("\n","<br>")+"</div>"
 elif html_mode=="hidden": h="<div style=\"display:none\">"+html.escape(text)+"</div>"
 elif html_mode=="image": h="<div>"+html.escape(text)+"<img src=\"https://example.invalid/x\"></div>"
 else: h=html_mode
 return {"id":note_id,"title":title,"plaintext":text,"html":h,"creation_date":created,"modification_date":modified or created,"shared":shared,"password_protected":locked,"attachment_count":attachments}

p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="cmd",required=True)
a=sub.add_parser("init"); a.add_argument("path")
a=sub.add_parser("add"); a.add_argument("path"); a.add_argument("id"); a.add_argument("--bucket",default="inbox"); a.add_argument("--title",default="Check status"); a.add_argument("--intent",default="status"); a.add_argument("--client",default="auto"); a.add_argument("--body",default="Please report status."); a.add_argument("--created",default="1970-01-01T00:01:40Z"); a.add_argument("--modified"); a.add_argument("--extra",default=""); a.add_argument("--kind",default="command"); a.add_argument("--reply",default="-"); a.add_argument("--attachments",type=int,default=0); a.add_argument("--locked",action="store_true"); a.add_argument("--shared",action="store_true"); a.add_argument("--html-mode",default="safe")
a=sub.add_parser("modify"); a.add_argument("path"); a.add_argument("id"); a.add_argument("--body",required=True); a.add_argument("--modified",required=True)
a=sub.add_parser("fault"); a.add_argument("path"); a.add_argument("key"); a.add_argument("value")
a=sub.add_parser("drift"); a.add_argument("path"); a.add_argument("key"); a.add_argument("field"); a.add_argument("value")
a=sub.add_parser("bulk"); a.add_argument("path"); a.add_argument("count",type=int)
args=p.parse_args()
if args.cmd=="init": save(args.path,{"schema":"firstmate.apple-notes.fake-provider/v1","binding":binding(),"notes":{"inbox":[],"acknowledgments":[],"outbox":[]},"faults":{}})
elif args.cmd=="add":
 v=load(args.path); v["notes"].setdefault(args.bucket,[]).append(note(args.id,args.title,args.intent,args.client,args.body,args.created,args.modified,args.extra,args.kind,args.reply,args.attachments,args.locked,args.shared,args.html_mode)); save(args.path,v)
elif args.cmd=="modify":
 v=load(args.path)
 for n in v["notes"]["inbox"]:
  if n["id"]==args.id:
   title=n["title"]; client="auto"
   for line in n["plaintext"].splitlines():
    if line.startswith("client_id: "): client=line.split(": ",1)[1]
   replacement=note(args.id,title,"status",client,args.body,n["creation_date"],args.modified)
   n.update(replacement)
 save(args.path,v)
elif args.cmd=="fault":
 v=load(args.path); v["faults"][args.key]=json.loads(args.value); save(args.path,v)
elif args.cmd=="drift":
 v=load(args.path); value=json.loads(args.value); v["binding"][args.key][args.field]=value; save(args.path,v)
elif args.cmd=="bulk":
 v=load(args.path)
 for i in range(args.count):
  client=str(uuid.UUID(int=(i+1) | (4<<76) | (2<<62)))
  title=f"Status {i:03d}"; body=f"Report synthetic status {i:03d}."
  v["notes"]["inbox"].append(note(f"a-{i:03d}",title,"status",client,body))
  v["notes"]["inbox"].append(note(f"b-{i:03d}",title,"status",client,body))
 save(args.path,v)
PY
chmod +x "$FIXTURE_TOOL"

new_home() {
  local name=$1
  local base="$TMP/$name"
  mkdir -p "$base/home"
  python3 "$FIXTURE_TOOL" init "$base/fake.json"
  printf '%s\n' "$base"
}

channel() {
  local now=$1 home=$2
  shift 2
  FM_NOTES_TEST_NOW="$now" "$CHANNEL" --home "$home" "$@"
}

capture_ready() {
  local base=$1
  channel 100 "$base/home" scan >/dev/null || return
  channel 116 "$base/home" scan
}

# --- Strict happy path, containment, immutable claim, ACK and outbound retry --
base=$(new_home happy)
python3 "$FIXTURE_TOOL" add "$base/fake.json" n1
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null || fail "fake init failed"
first=$(channel 100 "$base/home" scan) || fail "first stability scan failed"
[ "$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["captured"]))')" = '[]' ] || fail "first observation must not capture"
second=$(channel 116 "$base/home" scan) || fail "second stability scan failed"
mid=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["captured"][0])')
case "$mid" in ni1_??????????????????????????) : ;; *) fail "stable message ID is malformed: $mid" ;; esac
assert_present "$base/home/data/apple-notes-channel/captures/$mid.json" "capture must exist before offer"
assert_present "$base/home/state/apple-notes-channel/offers/$mid.json" "offer must exist after capture"
pass "Notes capture: two identical observations commit one immutable capture before its offer"

calls=$(channel 116 "$base/home" provider-log) || fail "provider call spy failed"
python3 - "$calls" <<'PY' || fail "provider call-spy containment failed"
import json,sys
calls=json.loads(sys.argv[1])
assert calls
for c in calls:
 op=c["operation"]
 if op in {"list-inbox-metadata","read-inbox-note"}:
  assert c["account_id"]=="acc-icloud"
  assert c["folder_id"]=="folder-inbox"
 assert op in {"probe-binding","list-inbox-metadata","read-inbox-note"}
PY
pass "Notes provider call spy: every read is contained to the bound account and Inbox IDs"

claim=$(channel 116 "$base/home" claim "$mid") || fail "claim failed"
assert_contains "$claim" '"classification":"accepted"' "ordinary status claim must be accepted"
repeat=$(channel 117 "$base/home" claim "$mid") || fail "repeat claim failed"
assert_contains "$repeat" '"repeat":true' "repeat claim must be idempotent"
shown=$(channel 117 "$base/home" show "$mid") || fail "show after claim failed"
assert_contains "$shown" '"work_key":"notes-ni1_' "capture must expose a deterministic work key"
assert_contains "$shown" '"body":"Please report status."' "claimed capture must expose only its normalized untrusted body"
pass "Notes claims: first claim is atomic and replay returns the same deterministic work identity"

ack=$(channel 117 "$base/home" acknowledge "$mid" --classification accepted) || fail "acknowledgment staging failed"
ack_id=$(printf '%s' "$ack" | python3 -c 'import json,sys; print(json.load(sys.stdin)["logical_id"])')
published=$(channel 117 "$base/home" publish "$ack_id") || fail "acknowledgment publish failed"
assert_contains "$published" '"created":true' "first ACK publish must create one note"
replayed=$(channel 118 "$base/home" publish "$ack_id") || fail "ACK replay failed"
assert_contains "$replayed" '"created":false' "ACK replay must bind the existing exact note"
pass "Notes ACK publication: deterministic ID and reconcile-before-create prevent duplicates"

test_intent=$(channel 118 "$base/home" prepare-outbound-test) || fail "test intent staging failed"
test_id=$(printf '%s' "$test_intent" | python3 -c 'import json,sys; print(json.load(sys.stdin)["logical_id"])')
python3 "$FIXTURE_TOOL" fault "$base/fake.json" create-after-commit-once true
pending=$(channel 118 "$base/home" publish "$test_id") || fail "ambiguous create must return a pending reconcile state"
assert_contains "$pending" '"state":"pending-reconcile"' "lost create response must not blindly retry"
reconciled=$(channel 119 "$base/home" publish "$test_id") || fail "outbound reconcile after ambiguous create failed"
assert_contains "$reconciled" '"created":false' "reconcile must bind the already-created outbound test note"
python3 - "$base/fake.json" "$test_id" <<'PY' || fail "ambiguous create produced a duplicate"
import json,sys
v=json.load(open(sys.argv[1]))
notes=[n for n in v["notes"]["outbox"] if n["logical_id"]==sys.argv[2]]
assert len(notes)==1
assert "This is a Firstmate Apple Notes channel test" in notes[0]["plaintext"]
PY
pass "Notes outbound crash seam: response loss reconciles to exactly one harmless test note"

calls=$(channel 119 "$base/home" provider-log)
python3 - "$calls" <<'PY' || fail "outbound call-spy containment failed"
import json,sys
calls=json.loads(sys.argv[1])
for c in calls:
 if c["operation"] in {"find-owned-note","create-owned-note"}:
  expected="folder-acknowledgments" if c["destination"]=="acknowledgments" else "folder-outbox"
  assert c["folder_id"]==expected
  assert c["account_id"]=="acc-icloud"
PY
pass "Notes provider call spy: writes are confined to the bound Acknowledgments or Outbox ID"

# --- Poison fairness and every metadata-before-body rejection ----------------
base=$(new_home rejection)
python3 "$FIXTURE_TOOL" add "$base/fake.json" attach --attachments 1
python3 "$FIXTURE_TOOL" add "$base/fake.json" locked --locked
large=$(python3 -c 'print("x"*17000)')
python3 "$FIXTURE_TOOL" add "$base/fake.json" huge --body "$large"
python3 "$FIXTURE_TOOL" add "$base/fake.json" unknown --extra 'mystery: no'
python3 "$FIXTURE_TOOL" add "$base/fake.json" bidi --body $'status\u202Ehidden'
python3 "$FIXTURE_TOOL" add "$base/fake.json" scheme --body 'Inspect file:///etc/passwd'
python3 "$FIXTURE_TOOL" add "$base/fake.json" hidden --html-mode hidden
python3 "$FIXTURE_TOOL" add "$base/fake.json" valid --title 'Valid after poison'
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
channel 100 "$base/home" scan >/dev/null || fail "first rejection scan failed"
result=$(channel 116 "$base/home" scan) || fail "second rejection scan failed"
assert_contains "$result" 'ni1_' "a valid note after poison notes must still capture"
assert_contains "$result" '"rejected":7' "all seven poison notes must be rejected"
calls=$(channel 116 "$base/home" provider-log)
python3 - "$calls" <<'PY' || fail "pre-body metadata rejection containment failed"
import hashlib,json,sys
calls=json.loads(sys.argv[1])
reads={c["note_id_hash"] for c in calls if c["operation"]=="read-inbox-note"}
for raw in ["attach","locked","huge"]:
 assert hashlib.sha256(raw.encode()).hexdigest() not in reads
PY
pass "Notes parser and metadata guard: locks, attachments, oversize, unknown keys, bidi, schemes, and hidden HTML reject without starving a later valid note"

# --- Low authority confirmation-required state -------------------------------
base=$(new_home authority)
python3 "$FIXTURE_TOOL" add "$base/fake.json" high --body 'Please merge and deploy this to production.'
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
result=$(capture_ready "$base") || fail "high-impact capture failed"
mid=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["captured"][0])')
claim=$(channel 116 "$base/home" claim "$mid") || fail "high-impact claim failed"
assert_contains "$claim" '"classification":"decision-required"' "high-impact prose must require stronger confirmation"
ack=$(channel 116 "$base/home" acknowledge "$mid" --classification decision-required) || fail "decision acknowledgment failed"
assert_contains "$ack" '"kind":"DECISION"' "high-impact request must stage a DECISION note, not work"
pass "Notes authority: high-impact prose cannot execute and becomes confirmation-required"

# --- UUID aliases, collision quarantine, modified accepted source, late arrival
base=$(new_home identities)
client='40000000-0000-4000-8000-000000000001'
python3 "$FIXTURE_TOOL" add "$base/fake.json" alias-a --client "$client" --title 'Alias status'
python3 "$FIXTURE_TOOL" add "$base/fake.json" alias-b --client "$client" --title 'Alias status'
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
result=$(capture_ready "$base") || fail "alias scan failed"
count=$(printf '%s' "$result" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["captured"]))')
[ "$count" = 1 ] || fail "same UUID and content must produce one capture, got $count"
python3 "$FIXTURE_TOOL" add "$base/fake.json" collision --client "$client" --title 'Different alias' --body 'Different content.'
channel 117 "$base/home" scan >/dev/null || fail "collision first observation failed"
channel 133 "$base/home" scan >/dev/null || fail "collision second observation failed"
ls "$base/home/state/apple-notes-channel/conflicts"/client-*.json >/dev/null 2>&1 \
  || fail "same UUID with different content must create a collision record"
python3 "$FIXTURE_TOOL" modify "$base/fake.json" alias-a --body 'Changed after acceptance.' --modified '1970-01-01T00:02:13Z'
channel 134 "$base/home" scan >/dev/null || fail "modified-source first observation failed"
channel 150 "$base/home" scan >/dev/null || fail "modified-source second observation failed"
find "$base/home/state/apple-notes-channel/conflicts" -type f -exec grep -l 'modified-source' {} + >/dev/null \
  || fail "changed accepted note must freeze the original and record a conflict"
python3 "$FIXTURE_TOOL" add "$base/fake.json" late --title 'Late older note' --created '1970-01-01T00:01:30Z'
channel 151 "$base/home" scan >/dev/null || fail "late arrival first observation failed"
late=$(channel 167 "$base/home" scan) || fail "late arrival second observation failed"
assert_contains "$late" 'ni1_' "older-created late arrival must not be skipped by a timestamp cursor"
pass "Notes identity reconciliation: aliases dedupe, collisions quarantine, edits freeze, and late arrivals capture"

# --- 100 unique + 100 duplicate aliases produce 100 captures/first claims -----
base=$(new_home bulk)
python3 "$FIXTURE_TOOL" bulk "$base/fake.json" 100
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
channel 100 "$base/home" scan >/dev/null || fail "bulk stability scan failed"
for now in 116 117 118 119 120 121; do
  channel "$now" "$base/home" scan >/dev/null || fail "bulk capture scan failed at $now"
done
captures=("$base/home/data/apple-notes-channel/captures"/ni1_*.json)
[ "${#captures[@]}" = 100 ] || fail "100 unique plus 100 duplicate aliases must produce 100 captures, got ${#captures[@]}"
python3 - "$CHANNEL" "$base/home" "${captures[@]}" <<'PY' || fail "concurrent bulk first claims or audit serialization failed"
import concurrent.futures, os, pathlib, subprocess, sys
channel, home, *paths = sys.argv[1:]
env = dict(os.environ, FM_NOTES_TEST_NOW="122")
def claim(path):
    mid = pathlib.Path(path).stem
    return subprocess.run(
        [channel, "--home", home, "claim", mid],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    results = list(pool.map(claim, paths))
failures = [result.stderr for result in results if result.returncode != 0]
if failures:
    raise SystemExit("".join(failures))
subprocess.run(
    [channel, "--home", home, "verify-audit"],
    env=env,
    stdout=subprocess.DEVNULL,
    check=True,
)
PY
claims=("$base/home/state/apple-notes-channel/claims"/ni1_*.json)
[ "${#claims[@]}" = 100 ] || fail "bulk aliases must produce 100 first claims, got ${#claims[@]}"
rate_limited=$(grep -l 'rate-limited' "${claims[@]}" | wc -l | tr -d '[:space:]')
[ "$rate_limited" -ge 97 ] || fail "accepted-command rate cap did not apply to the bulk claims"
pass "Notes scale/dedupe: 100 unique plus 100 aliases produce 100 atomic concurrent first claims with a valid audit chain"

# --- Capture crash seams: no missing capture event and recoverable offer -------
base=$(new_home crash-before)
python3 "$FIXTURE_TOOL" add "$base/fake.json" crash
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
channel 100 "$base/home" scan >/dev/null
if FM_NOTES_TEST_NOW=116 FM_NOTES_TEST_FAILPOINT=before-capture "$CHANNEL" --home "$base/home" scan >/dev/null 2>&1; then
  fail "before-capture synthetic crash seam must interrupt"
fi
find "$base/home/data/apple-notes-channel/captures" -type f | grep . >/dev/null \
  && fail "before-capture seam must leave no capture"
if FM_NOTES_TEST_NOW=116 FM_NOTES_TEST_FAILPOINT=after-capture-before-offer "$CHANNEL" --home "$base/home" scan >/dev/null 2>&1; then
  fail "after-capture synthetic crash seam must interrupt"
fi
capture=$(find "$base/home/data/apple-notes-channel/captures" -type f -name 'ni1_*.json' | head -1)
[ -n "$capture" ] || fail "after-capture seam must leave one immutable capture"
output=$(channel 117 "$base/home" poll) || fail "restart reconciliation after capture seam failed"
assert_contains "$output" 'apple-notes-channel: 1 captured message(s) ready' "restart must offer committed capture"
pass "Notes capture crash matrix: before capture leaves none and after capture reoffers one committed artifact"

base=$(new_home crash-offer)
python3 "$FIXTURE_TOOL" add "$base/fake.json" crash-offer
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
channel 100 "$base/home" scan >/dev/null
if FM_NOTES_TEST_NOW=116 FM_NOTES_TEST_FAILPOINT=after-offer-before-output "$CHANNEL" --home "$base/home" poll >/dev/null 2>&1; then
  fail "after-offer synthetic crash seam must interrupt"
fi
output=$(channel 117 "$base/home" poll) || fail "unsurfaced offer reconciliation failed"
assert_contains "$output" 'apple-notes-channel: 1 captured message(s) ready' "unsurfaced offer must wake on restart"
pass "Notes offer crash seam: a committed but unsurfaced offer is delivered after restart"

# --- Self-loop separation ----------------------------------------------------
base=$(new_home self-loop)
python3 "$FIXTURE_TOOL" add "$base/fake.json" own-ack --bucket acknowledgments
python3 "$FIXTURE_TOOL" add "$base/fake.json" own-out --bucket outbox
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
result=$(capture_ready "$base") || fail "self-loop scan failed"
assert_contains "$result" '"objects_seen":0' "ACK and Outbox notes must never be parsed as Inbox commands"
assert_contains "$result" '"captured":[]' "self-looking outbound content must not capture"
pass "Notes direction separation: Acknowledgments and Outbox are never command sources"

# --- Audit mutation, private files, authenticated definitions, zero-call kill --
base=$(new_home operations)
python3 "$FIXTURE_TOOL" add "$base/fake.json" ops
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
result=$(capture_ready "$base") || fail "operations fixture capture failed"
mid=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["captured"][0])')
[ "$(stat -f %Lp "$base/home/data/apple-notes-channel" 2>/dev/null || stat -c %a "$base/home/data/apple-notes-channel")" = 700 ] \
  || fail "channel data directory must be mode 0700"
[ "$(stat -f %Lp "$base/home/data/apple-notes-channel/captures/$mid.json" 2>/dev/null || stat -c %a "$base/home/data/apple-notes-channel/captures/$mid.json")" = 600 ] \
  || fail "capture must be mode 0600"
pass "Notes private state: channel directories and captures use owner-only modes"

install=$(channel 116 "$base/home" install-definitions --runtime-root "$ROOT") || fail "check definition install failed"
assert_contains "$install" '"cadence_seconds":300' "installed bounded check must declare existing default cadence"
assert_present "$base/home/state/notes-watch.check.sh" "authenticated Notes check shim is missing"
assert_present "$base/home/state/notes-watch.check-trust" "authenticated Notes check trust is missing"
[ -x "$base/home/state/notes-watch.check.sh" ] || fail "Notes check shim must be executable"
pass "Notes authenticated check: exact shim and custom-check trust record install without activation side effects"

before=$(channel 116 "$base/home" provider-log | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
disabled=$(channel 116 "$base/home" disable --emergency) || fail "emergency disable failed"
assert_contains "$disabled" '"provider_calls":0' "emergency disable must make zero provider calls"
assert_absent "$base/home/state/notes-watch.check.sh" "emergency disable must retire marker-owned check definition"
assert_present "$base/home/state/apple-notes-channel/DISABLED" "emergency disable marker is missing"
out=$(FM_HOME="$base/home" "$ROOT/bin/fm-notes-poll.sh") || fail "disabled poll must be a successful no-op"
[ -z "$out" ] || fail "disabled poll must be silent"
after=$(channel 116 "$base/home" provider-log | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$before" = "$after" ] || fail "disabled entrypoint made a provider call"
pass "Notes emergency disable: next entry is silent, makes zero provider calls, and preserves evidence"

# Audit tampering is checked in a separate enabled home because disable above is final.
base=$(new_home audit)
python3 "$FIXTURE_TOOL" add "$base/fake.json" audit
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
capture_ready "$base" >/dev/null || fail "audit fixture capture failed"
channel 116 "$base/home" verify-audit >/dev/null || fail "valid audit chain did not verify"
python3 - "$base/home/data/apple-notes-channel/audit/events.jsonl" <<'PY'
import json,sys
p=sys.argv[1]; lines=open(p).read().splitlines(); v=json.loads(lines[0]); v["type"]="tampered"; lines[0]=json.dumps(v,sort_keys=True,separators=(",",":")); open(p,"w").write("\n".join(lines)+"\n")
PY
chmod 600 "$base/home/data/apple-notes-channel/audit/events.jsonl"
if channel 116 "$base/home" verify-audit >/dev/null 2>&1; then
  fail "mutated audit chain must not verify"
fi
assert_present "$base/home/state/apple-notes-channel/DISABLED" "audit corruption must safe-disable the channel"
pass "Notes audit chain: mutation is detected and disables rather than resetting evidence"

# Hardlink refusal proves single-link file invariants through the public status path.
base=$(new_home hardlink)
channel 100 "$base/home" init-fake --fixture "$base/fake.json" >/dev/null
ln "$base/home/config/apple-notes-channel.json" "$base/home/config/apple-notes-channel.alias"
if channel 100 "$base/home" status >/dev/null 2>&1; then
  fail "hardlinked config must be refused"
fi
assert_present "$base/home/state/apple-notes-channel/DISABLED" "unsafe config identity must safe-disable"
pass "Notes file identity: hardlinked private config is refused and disables the channel"

printf '# fm-notes-channel.test.sh: all assertions passed\n'
