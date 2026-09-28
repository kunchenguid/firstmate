#!/usr/bin/env bash
# tests/fm-route-domain.test.sh - verify Jev domain router behavior against a
# local stub of the Jev System One endpoint (hermetic, no network).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -x "$ROOT/bin/fm-route-domain.sh" ] || fail "bin/fm-route-domain.sh missing or not executable"
[ -x "$ROOT/bin/fm-route-dispatch.sh" ] || fail "bin/fm-route-dispatch.sh missing or not executable"

TDIR=$(fm_test_tmproot fm-route-test)

# A private copy of bin/ so fm-send.sh can be faked and FM_HOME defaults to it.
FAKE="$TDIR/home"
mkdir -p "$FAKE/bin" "$FAKE/data" "$FAKE/state"
cp -R "$ROOT/bin/." "$FAKE/bin/"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "FM_HOME=$FM_HOME" "$@" > %q\n' "$TDIR/argv" > "$FAKE/bin/fm-send.sh"
chmod +x "$FAKE/bin/fm-send.sh"
ROUTER="$FAKE/bin/fm-route-domain.sh"
DISPATCH="$FAKE/bin/fm-route-dispatch.sh"

REG="$FAKE/data/secondmates.md"
cat <<'EOF' > "$REG"
- portal-ops - Clinical operations and EMR work: Portal implementation, UrgentIQ and DoseSpot, provider onboarding. (home: /tmp/p; scope: Arcs Portal clinical operations, UrgentIQ, DoseSpot; projects: portal; added 2026-07-29)
- seller-outreach - Seller lead generation and outreach for urgent-care clinics. (home: /tmp/s; scope: All urgent-care seller lead generation, campaigns, Flow; projects: agents-flow; added 2026-07-29)
- websites - Rebuild of arcs.health and jonroosevelt.com frontend. (host: box; root: /r; home: /tmp/w; scope: Frontend website rebuild, UI components, Next.js, Framer Motion; projects: website-covenant; added 2026-08-06)
- spaced-ops - Accepted whitespace variation. (home:/tmp/sp;scope:  spaced scope;projects: sp;  added  2026-08-06)
- retired-ops - Registered but with no live task record. (home: /tmp/r; scope: retired work; projects: r; added 2026-08-06)
EOF
# Only secondmates with a live state/<id>.meta record can receive fm-send.sh.
for id in portal-ops seller-outreach websites spaced-ops long-ops zorbex-ops; do
  printf 'kind=secondmate\n' > "$FAKE/state/$id.meta"
done

# Stub Jev: the answer is chosen from a keyword in the task so every mapping is deterministic.
cat > "$TDIR/stub.py" <<'PY'
import http.server, json, sys
ANSWERS = [
    ("seller", "seller-outreach", 0.1),
    ("morning", "captain_direct", 0.0),
    ("drone", "new_domain", 0.9),
    ("emr-overflow", "portal-ops", 0.8),
    ("bogus", "not-a-secondmate", 0.0),
    ("retired", "retired-ops", 0.0),
]
RAW = {
    "null-answers": {"answers": None},
    "not-an-object": [1],
    "null-confidence": {"answers": {"route": {"choice": "portal-ops", "confidence": None}}},
    "null-noul": {"answers": {"route": {"choice": "portal-ops"}, "needs_new_secondmate": {"noul": None}}},
    "no-choice": {"answers": {"route": {"confidence": 0.9}}},
    "weak-signal": {"answers": {"route": {"choice": "seller-outreach", "confidence": 0.34}, "needs_new_secondmate": {"noul": 0.2}}},
    "floor-signal": {"answers": {"route": {"choice": "seller-outreach", "confidence": 0.7}, "needs_new_secondmate": {"noul": 0.2}}},
    "weak-newdomain": {"answers": {"route": {"choice": "new_domain", "confidence": 0.5}, "needs_new_secondmate": {"noul": 0.2}}},
}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        with open(sys.argv[2], "ab") as log:
            log.write(json.dumps({"auth": self.headers.get("Authorization"), "body": json.loads(raw)}).encode() + b"\n")
        task = json.loads(raw)["state"]["task"].lower()
        answers = {}
        for word, choice, noul in ANSWERS:
            if word in task:
                answers = {"route": {"choice": choice, "confidence": 0.8, "probabilities": {choice: 0.8}},
                           "needs_new_secondmate": {"noul": noul}}
                break
        reply = {"answers": answers}
        for word, raw_reply in RAW.items():
            if word in task:
                reply = raw_reply
        out = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
PY
LOG="$TDIR/requests.log"
: > "$LOG"
python3 "$TDIR/stub.py" "$TDIR/port" "$LOG" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
[ -s "$TDIR/port" ] || fail "stub Jev server did not start"

FM_JEV_TS_BASE="http://127.0.0.1:$(cat "$TDIR/port")"
export FM_JEV_TS_BASE
export TYPESAFE_API_KEY=test-dummy-key
unset FM_HOME FM_ROOT_OVERRIDE
FM_CONFIG_OVERRIDE="$TDIR/no-config"
export FM_CONFIG_OVERRIDE

requests() { wc -l < "$LOG" | tr -d ' '; }
last_request() { tail -n1 "$LOG"; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# 1. Empty input is unavailable, and an empty --task never waits on an open stdin pipe.
out=$(timeout 10 "$ROUTER" --task "" < <(sleep 20)) || fail "empty --task must not block on stdin"
assert_contains "$out" "action=unavailable" "empty task emits unavailable"

# 2. Missing brief file is reported as missing.
code=0; err=$("$ROUTER" --brief "$TDIR/nope.md" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "missing brief must exit 2, got $code"
assert_contains "$err" "brief file not found" "missing brief is named"

# 3. The environment key is used, and the registry is read from the router's own home.
before=$(requests)
out=$("$ROUTER" --task "Seller outreach campaign for clinics")
assert_contains "$out" "action=dispatch" "known domain emits dispatch"
assert_contains "$out" "route=seller-outreach" "known domain routes to seller-outreach"
[ "$(requests)" -eq $((before + 1)) ] || fail "one request expected"
[ "$(last_request | field auth)" = "Bearer test-dummy-key" ] || fail "environment key must be sent"
crit=$(last_request | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin)["body"]["questions"]["route"]["criteria"])))')
[ "$crit" = "captain_direct,new_domain,portal-ops,seller-outreach,spaced-ops,websites" ] || fail "registry parse sent wrong criteria: $crit"
out=$("$ROUTER" --task "retired work")
assert_contains "$out" "action=unavailable" "a registered secondmate with no live record is never a route"

# An empty or missing registry is unavailable and nothing is sent.
before=$(requests)
out=$("$ROUTER" --registry "$TDIR/no-registry.md" --task "seller leads")
assert_contains "$out" "action=unavailable" "missing registry emits unavailable"
: > "$TDIR/empty.md"
out=$("$ROUTER" --registry "$TDIR/empty.md" --task "seller leads")
assert_contains "$out" "action=unavailable" "empty registry emits unavailable"
[ "$(requests)" -eq "$before" ] || fail "no request may be made without a live secondmate"

# 4. The home's .env is the fallback key source.
printf 'TYPESAFE_API_KEY="env-file-key"\n' > "$FAKE/.env"
env -u TYPESAFE_API_KEY "$ROUTER" --task "seller leads" >/dev/null
[ "$(last_request | field auth)" = "Bearer env-file-key" ] || fail ".env key must be sent"
rm "$FAKE/.env"

# 5. No key: unavailable, no network call, and no privilege escalation attempted.
SUDOBIN="$TDIR/sudobin"; mkdir -p "$SUDOBIN"
printf '#!/usr/bin/env bash\ntouch %q\nexit 1\n' "$TDIR/sudo-called" > "$SUDOBIN/sudo"
chmod +x "$SUDOBIN/sudo"
printf '#!/usr/bin/env bash\necho TYPESAFE_API_KEY=wrapper-key\n' > "$FAKE/bin/jev-typesafe-run.py"
chmod +x "$FAKE/bin/jev-typesafe-run.py"
before=$(requests)
out=$(env -u TYPESAFE_API_KEY PATH="$SUDOBIN:$PATH" "$ROUTER" --task "seller leads")
assert_contains "$out" "action=unavailable" "missing key emits unavailable"
assert_contains "$out" "TYPESAFE_API_KEY unavailable" "missing key reason"
[ "$(requests)" -eq "$before" ] || fail "no request may be made without a key"
[ ! -e "$TDIR/sudo-called" ] || fail "router must never invoke sudo"
rm "$FAKE/bin/jev-typesafe-run.py"

# 6. Choice and noul map to actions; high noul overrides a matched secondmate.
out=$("$ROUTER" --task "Good morning, status?")
assert_contains "$out" "action=handle_direct" "captain message emits handle_direct"
assert_contains "$out" "route=captain_direct" "captain message routes to captain_direct"
assert_not_contains "$out" "dispatch_cmd=" "handle_direct has no dispatch command"
out=$("$ROUTER" --task "Drone firmware in Rust")
assert_contains "$out" "action=create_secondmate" "new domain emits create_secondmate"
assert_contains "$out" "route=new_domain" "new domain routes to new_domain"
out=$("$ROUTER" --task "emr-overflow of unrelated work")
assert_contains "$out" "action=create_secondmate" "noul >= 0.7 overrides a matched secondmate"
assert_contains "$out" "route=new_domain" "noul override reports new_domain, not the matched id"
out=$("$ROUTER" --task "bogus route please")
assert_contains "$out" "action=unavailable" "unknown route choice is unavailable"
json=$("$ROUTER" --json --task "Good morning")
[ "$(printf '%s' "$json" | field action)" = handle_direct ] || fail "json action wrong: $json"

PREAMBLE="[fm-from-firstmate] Routed intake task. It has no contract yet: before any work starts, settle what to build or learn, how it ships, and how much autonomy the worker has through your normal intake, and ask me for any of those you cannot establish. Task:"

# 7. dispatch_cmd is shell-safe for hostile task text and names the home's fm-send.sh.
# shellcheck disable=SC2016
EVIL='seller $(touch pwned1) `touch pwned2` \ "q" '"'"'s'"'"
out=$("$ROUTER" --task "$EVIL")
cmd=$(printf '%s\n' "$out" | sed -n 's/^dispatch_cmd=//p')
assert_contains "$cmd" "$FAKE/bin/fm-send.sh" "dispatch_cmd names the home's fm-send.sh by absolute path"
RUNDIR="$TDIR/elsewhere"; mkdir -p "$RUNDIR"
rm -f "$TDIR/argv"
(cd "$RUNDIR" && bash -c "$cmd")
[ ! -e "$RUNDIR/pwned1" ] && [ ! -e "$RUNDIR/pwned2" ] || fail "dispatch_cmd executed task text"
[ "$(sed -n 1p "$TDIR/argv")" = "FM_HOME=$FAKE" ] || fail "dispatch_cmd must set FM_HOME to the home"
[ "$(sed -n 2p "$TDIR/argv")" = "seller-outreach" ] || fail "dispatch_cmd route wrong"
[ "$(sed -n 3p "$TDIR/argv")" = "$PREAMBLE $EVIL" ] || fail "dispatch_cmd message altered: $(sed -n 3p "$TDIR/argv")"

# 8. Never-send values are withheld from every request field, including overlapping entries.
CFG="$TDIR/config"; mkdir -p "$CFG"
printf '# comment\nHoldings\nAcme Hold\nHoldings Ltd\nurgentiq\n' > "$CFG/dispatch-never-send"
FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --task "seller outreach to ACME Holdings Ltd today" >/dev/null
body=$(last_request | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["body"]).lower())')
for frag in acme hold ltd urgentiq; do
  assert_not_contains "$body" "$frag" "never-send fragment '$frag' must not leave the box"
done
task=$(last_request | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"]["state"]["task"])')
[ "$task" = "seller outreach to [withheld] today" ] || fail "withheld task wrong: $task"

# A value straddling the 140-character scope cut is still withheld.
REG_LONG="$TDIR/long.md"
pad=$(printf 'P%.0s' $(seq 131))
printf -- '- long-ops - Long scope. (home: /tmp/l; scope: %s Zorbex Holdings group; projects: l; added 2026-08-01)\n' "$pad" > "$REG_LONG"
printf 'Zorbex Holdings\n' > "$CFG/dispatch-never-send"
FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --registry "$REG_LONG" --task "seller leads" >/dev/null
body=$(last_request | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["body"]).lower())')
assert_not_contains "$body" "zorbex" "never-send value straddling the scope cut must not leave the box"
scope=$(last_request | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"]["questions"]["route"]["criteria"]["long-ops"])')
[ "${#scope}" -le 140 ] || fail "scope must still be capped at 140 characters: ${#scope}"

# A secondmate id matching the list fails closed with nothing sent.
REG_ID="$TDIR/id.md"
printf -- '- zorbex-ops - Client work. (home: /tmp/z; scope: client work; projects: z; added 2026-08-01)\n' > "$REG_ID"
printf 'zorbex\n' > "$CFG/dispatch-never-send"
before=$(requests)
out=$(FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --registry "$REG_ID" --task "seller leads")
assert_contains "$out" "action=unavailable" "withheld secondmate id fails closed"
assert_contains "$out" "zorbex-ops" "withheld secondmate id is named in the reason"
[ "$(requests)" -eq "$before" ] || fail "nothing may be sent when a secondmate id is withheld"

# Common words matching only the built-in routes do not disable the router.
printf 'new\ndirect\ndomain\n' > "$CFG/dispatch-never-send"
out=$(FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --task "seller leads")
assert_contains "$out" "action=dispatch" "built-in route names are not checked against the never-send list"

rm "$CFG/dispatch-never-send"; mkdir "$CFG/dispatch-never-send"
before=$(requests)
out=$(FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --task "seller leads")
assert_contains "$out" "action=unavailable" "unreadable never-send list fails closed"
[ "$(requests)" -eq "$before" ] || fail "nothing may be sent when the never-send list is unreadable"

# 9. Malformed 200 responses are unavailable, not a crash.
for word in null-answers not-an-object null-confidence null-noul no-choice; do
  out=$("$ROUTER" --task "$word reply") || fail "$word response must not crash the router"
  assert_contains "$out" "action=unavailable" "$word response emits unavailable"
done
out=$("$DISPATCH" --task "null-answers reply") || fail "dispatcher must survive a malformed response"
assert_contains "$out" "Router unavailable" "dispatcher falls back on a malformed response"

# 10. Route confidence shares the noul floor: below it never dispatches.
out=$("$ROUTER" --task "weak-signal seller leads")
assert_contains "$out" "action=handle_direct" "confidence below the floor falls back to handle_direct"
assert_contains "$out" "route=captain_direct" "confidence below the floor routes to the captain"
assert_not_contains "$out" "dispatch_cmd=" "confidence below the floor has no dispatch command"
out=$("$ROUTER" --task "floor-signal seller leads")
assert_contains "$out" "action=dispatch" "confidence exactly at the floor dispatches"
assert_contains "$out" "route=seller-outreach" "confidence at the floor keeps the route"
out=$("$ROUTER" --task "Seller outreach campaign")
assert_contains "$out" "action=dispatch" "confidence above the floor dispatches"
out=$("$ROUTER" --task "weak-newdomain request")
assert_contains "$out" "action=handle_direct" "a weak new_domain choice does not charter a secondmate"
rm -f "$TDIR/argv"
out=$("$DISPATCH" --task "weak-signal seller leads" --execute)
assert_contains "$out" "Status: Direct communication" "dispatcher handles a weak signal directly"
[ ! -e "$TDIR/argv" ] || fail "a weak signal must never be dispatched"

# 11. Dispatcher branches.
out=$("$DISPATCH" --task "Good morning")
assert_contains "$out" "Status: Direct communication" "dispatcher handle_direct branch"
out=$("$DISPATCH" --task "Drone firmware")
assert_contains "$out" "Unmatched domain (new_domain)" "dispatcher create_secondmate branch"
out=$(env -u TYPESAFE_API_KEY "$DISPATCH" --task "seller leads")
assert_contains "$out" "Router unavailable (TYPESAFE_API_KEY unavailable)" "dispatcher unavailable branch"
code=0; err=$("$DISPATCH" --brief "$TDIR/nope.md" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "dispatcher missing brief must exit 2"
assert_contains "$err" "brief file not found" "dispatcher names the missing brief"
out=$("$DISPATCH" --task "-seller leads")
assert_contains "$out" "Route:      seller-outreach" "task text starting with a dash is not parsed as a flag"

out=$("$DISPATCH" --task "$EVIL")
cmd=$(printf '%s\n' "$out" | sed -n '/^Recommended dispatch command:/{n;s/^  //p;}')
rm -f "$TDIR/argv"
(cd "$RUNDIR" && bash -c "$cmd")
[ ! -e "$RUNDIR/pwned1" ] && [ ! -e "$RUNDIR/pwned2" ] || fail "dispatcher command executed task text"
[ "$(sed -n 3p "$TDIR/argv")" = "$PREAMBLE $EVIL" ] || fail "dispatcher command message altered"

rm -f "$TDIR/argv"
"$DISPATCH" --task "seller leads" --execute >/dev/null
[ "$(sed -n 1p "$TDIR/argv")" = "FM_HOME=$FAKE" ] || fail "--execute must export FM_HOME to fm-send.sh"
[ "$(sed -n 2p "$TDIR/argv")" = "seller-outreach" ] || fail "--execute must dispatch to the route"

rm -f "$TDIR/argv"
json=$("$DISPATCH" --task "seller leads" --json --execute 2>/dev/null)
[ "$(printf '%s' "$json" | field action)" = dispatch ] || fail "--json --execute must emit json: $json"
[ -e "$TDIR/argv" ] || fail "--json --execute must still dispatch"
[ "$(printf '%s' "$json" | field dispatched)" = True ] || fail "--json --execute must report the send: $json"

# A failed send in --json --execute still emits JSON reporting the failure.
cp "$FAKE/bin/fm-send.sh" "$TDIR/fm-send.ok"
printf '#!/usr/bin/env bash\nexit 3\n' > "$FAKE/bin/fm-send.sh"
code=0; json=$("$DISPATCH" --task "seller leads" --json --execute 2>/dev/null) || code=$?
cp "$TDIR/fm-send.ok" "$FAKE/bin/fm-send.sh"
[ "$code" -eq 3 ] || fail "a failed send must exit with its status, got $code"
[ "$(printf '%s' "$json" | field dispatched)" = False ] || fail "a failed send must be reported in json: $json"
[ "$(printf '%s' "$json" | field send_exit_code)" = 3 ] || fail "send exit code must be reported: $json"

# A brief larger than one argv string can hold still routes.
HUGE="$TDIR/huge.md"
{ printf 'seller leads\n'; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$HUGE"
out=$("$DISPATCH" --brief "$HUGE") || fail "a brief over 128 KiB must not abort the dispatcher"
assert_contains "$out" "Route:      seller-outreach" "a brief over 128 KiB is classified"

# A long brief reaches the second mate whole, under the contract preamble.
BRIEF="$TDIR/brief.md"
{ printf 'seller leads\n'; printf 'filler %.0s' $(seq 100); printf '\nFINAL-REQUIREMENT keep\n'; } > "$BRIEF"
rm -f "$TDIR/argv"
"$DISPATCH" --brief "$BRIEF" --execute >/dev/null
[ "$(sed -n 3p "$TDIR/argv")" = "$PREAMBLE $(tr -s '\n' ' ' < "$BRIEF" | sed 's/ $//')" ] || fail "--execute must send the whole brief: $(sed -n 3p "$TDIR/argv")"

pass "all fm-route-domain tests passed"
