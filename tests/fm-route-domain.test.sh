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
mkdir -p "$FAKE/bin" "$FAKE/data"
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
EOF

# Stub Jev: the answer is chosen from a keyword in the task so every mapping is deterministic.
cat > "$TDIR/stub.py" <<'PY'
import http.server, json, sys
ANSWERS = [
    ("seller", "seller-outreach", 0.1),
    ("morning", "captain_direct", 0.0),
    ("drone", "new_domain", 0.9),
    ("emr-overflow", "portal-ops", 0.8),
    ("bogus", "not-a-secondmate", 0.0),
]
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
        out = json.dumps({"answers": answers}).encode()
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
[ "$crit" = "captain_direct,new_domain,portal-ops,seller-outreach,websites" ] || fail "registry parse sent wrong criteria: $crit"

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
[ "$(sed -n 3p "$TDIR/argv")" = "[fm-from-firstmate] $EVIL" ] || fail "dispatch_cmd message altered: $(sed -n 3p "$TDIR/argv")"

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

rm "$CFG/dispatch-never-send"; mkdir "$CFG/dispatch-never-send"
before=$(requests)
out=$(FM_CONFIG_OVERRIDE="$CFG" "$ROUTER" --task "seller leads")
assert_contains "$out" "action=unavailable" "unreadable never-send list fails closed"
[ "$(requests)" -eq "$before" ] || fail "nothing may be sent when the never-send list is unreadable"

# 9. Dispatcher branches.
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
[ "$(sed -n 3p "$TDIR/argv")" = "[fm-from-firstmate] $EVIL" ] || fail "dispatcher command message altered"

rm -f "$TDIR/argv"
"$DISPATCH" --task "seller leads" --execute >/dev/null
[ "$(sed -n 1p "$TDIR/argv")" = "FM_HOME=$FAKE" ] || fail "--execute must export FM_HOME to fm-send.sh"
[ "$(sed -n 2p "$TDIR/argv")" = "seller-outreach" ] || fail "--execute must dispatch to the route"

rm -f "$TDIR/argv"
json=$("$DISPATCH" --task "seller leads" --json --execute 2>/dev/null)
[ "$(printf '%s' "$json" | field action)" = dispatch ] || fail "--json --execute must emit json: $json"
[ -e "$TDIR/argv" ] || fail "--json --execute must still dispatch"

pass "all fm-route-domain tests passed"
