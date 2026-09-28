#!/usr/bin/env bash
# tests/fm-jev-decisions.test.sh - verify Jev open decision triage behavior
# against a local stub of the Jev System One endpoint (hermetic, no network).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISION_SH="$ROOT/bin/fm-jev-decisions.sh"
DECISION_PY="$ROOT/bin/fm-jev-decisions.py"
[ -x "$DECISION_SH" ] || fail "bin/fm-jev-decisions.sh missing or not executable"
[ -x "$DECISION_PY" ] || fail "bin/fm-jev-decisions.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-decisions-test)

# Stub Jev: the category is chosen from the decision key so every mapping is deterministic.
cat > "$TDIR/stub.py" <<'PY'
import http.server, json, sys
ANSWERS = {
    "pending-reply": ("stale_historical", 0.1),
    "old": ("stale_historical", 0.2),
    "quota": ("policy_spend", 0.3),
    "net": ("external_block", 0.4),
    "active": ("actionable_now", 0.9),
    "bogus": ("not_a_category", 0.9),
}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        key = body["state"]["key"]
        answers = {}
        for prefix, (choice, noul) in ANSWERS.items():
            if key.startswith(prefix):
                answers = {"category": {"choice": choice, "confidence": 0.8, "probabilities": {choice: 0.8}},
                           "actionable_now": {"noul": noul}}
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
python3 "$TDIR/stub.py" "$TDIR/port" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
[ -s "$TDIR/port" ] || fail "stub Jev server did not start"

FM_JEV_TS_BASE="http://127.0.0.1:$(cat "$TDIR/port")"
export FM_JEV_TS_BASE
export TYPESAFE_API_KEY=test-dummy-key

# 1. Empty input exits cleanly without calling Jev.
out=$("$DECISION_SH" --input /dev/null)
assert_contains "$out" "No open decisions found" "empty input emits no decisions message"
[ "$("$DECISION_SH" --input /dev/null --json)" = "[]" ] || fail "empty input must emit an empty json array"

# 2. TSV classification maps categories to suggestions and resolve commands.
TSV="$TDIR/decisions.tsv"
printf '%s\t%s\t%s\t%s\n' \
  test-task pending-reply-abc123 blocked "pending-reply-missed: task=test-task request=CONFIG_REREAD" \
  test-task quota-exceeded needs-decision "Need captain approval to upgrade API tier" \
  test-task net-down blocked "upstream host unreachable" \
  test-task active-fix needs-decision "choose the fix now" \
  test-task bogus-choice needs-decision "server returns an unknown category" \
  test-task missing-answer needs-decision "server returns no category" \
  > "$TSV"

json=$("$DECISION_SH" --input "$TSV" --json)
cat_of() { printf '%s' "$json" | python3 -c 'import json,sys; print({i["key"]: i["category"] for i in json.load(sys.stdin)}[sys.argv[1]])' "$1"; }
[ "$(cat_of pending-reply-abc123)" = stale_historical ] || fail "pending-reply key should be stale_historical"
[ "$(cat_of quota-exceeded)" = policy_spend ] || fail "quota key should be policy_spend"
[ "$(cat_of net-down)" = external_block ] || fail "net key should be external_block"
[ "$(cat_of active-fix)" = actionable_now ] || fail "active key should be actionable_now"
[ "$(cat_of bogus-choice)" = unavailable ] || fail "unknown category choice must be unavailable"
[ "$(cat_of missing-answer)" = unavailable ] || fail "missing category choice must be unavailable"

table=$("$DECISION_SH" --input "$TSV")
assert_contains "$table" "Escalate to Captain" "policy_spend suggestion rendered"
assert_contains "$table" "Active blocker" "actionable_now suggestion rendered"
assert_contains "$table" "unavailable: 2" "summary counts invalid answers as unavailable"

# 3. Filters.
active=$("$DECISION_SH" --input "$TSV" --category actionable_now --json)
[ "$(printf '%s' "$active" | python3 -c 'import json,sys; print(",".join(i["key"] for i in json.load(sys.stdin)))')" = active-fix ] ||
  fail "--category actionable_now must select only the active key: $active"
urgent=$("$DECISION_SH" --input "$TSV" --min-noul 0.35 --json)
[ "$(printf '%s' "$urgent" | python3 -c 'import json,sys; print(",".join(sorted(i["key"] for i in json.load(sys.stdin))))')" = active-fix,net-down ] ||
  fail "--min-noul must keep only items at or above the threshold: $urgent"

# 4. Resolve commands are shell-safe for hostile task and key values.
EVIL="$TDIR/evil.tsv"
printf '%s\t%s\t%s\t%s\n' "t;touch $TDIR/pwned-task" "old-\$(touch $TDIR/pwned-key)" blocked "superseded" > "$EVIL"
cmds=$("$DECISION_SH" --input "$EVIL" --resolve-cmds)
assert_contains "$cmds" "bin/fm-send.sh" "resolve cmd emitted for stale key"
FAKE="$TDIR/fakeroot"; mkdir -p "$FAKE/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$TDIR/argv" > "$FAKE/bin/fm-send.sh"; chmod +x "$FAKE/bin/fm-send.sh"
(cd "$FAKE" && bash -c "$cmds")
[ ! -e "$TDIR/pwned-task" ] && [ ! -e "$TDIR/pwned-key" ] || fail "resolve cmds executed injected shell"
[ "$(sed -n 1p "$TDIR/argv")" = "t;touch $TDIR/pwned-task" ] || fail "resolve cmd must pass the task verbatim"
[ "$(sed -n 3p "$TDIR/argv")" = "old-\$(touch $TDIR/pwned-key)" ] || fail "resolve cmd must pass the key verbatim"

# 5. Config-reread closure wording applies only to CONFIG_REREAD pending replies.
WORDING="$TDIR/wording.tsv"
printf '%s\t%s\t%s\t%s\n' \
  w pending-reply-cfg blocked "pending-reply-missed: task=w request=CONFIG_REREAD" \
  w pending-reply-other blocked "pending-reply-missed: task=w request=STATUS_PING" \
  > "$WORDING"
wording=$("$DECISION_SH" --input "$WORDING" --json)
note_of() { printf '%s' "$wording" | python3 -c 'import json,shlex,sys; print({i["key"]: shlex.split(i["resolve_cmd"])[-1] for i in json.load(sys.stdin)}[sys.argv[1]])' "$1"; }
[ "$(note_of pending-reply-cfg)" = "auto-resolved: expired legacy config reread from previous phase" ] ||
  fail "CONFIG_REREAD pending reply must get the config-reread closure note"
[ "$(note_of pending-reply-other)" = "auto-resolved: superseded historical decision" ] ||
  fail "non-CONFIG_REREAD pending reply must get the generic closure note"
case "$(printf '%s' "$wording" | python3 -c 'import json,sys; i=[i for i in json.load(sys.stdin) if i["key"]=="pending-reply-other"][0]; print(i["resolve_cmd"], i["suggested_action"])')" in
  *"config reread"*) fail "generic closure path must not mention config reread" ;;
esac

# 6. Status-file extraction: tab-bearing notes keep key/verb intact, --all is read-only.
STATE="$TDIR/state it's"; mkdir -p "$STATE"
printf 'needs-decision [key=active-pick]: choose\tA or B\n' > "$STATE/alpha.status"
one=$(FM_STATE_OVERRIDE="$STATE" "$DECISION_SH" --task alpha --json)
[ "$(printf '%s' "$one" | python3 -c 'import json,sys; i=json.load(sys.stdin)[0]; print(i["task"], i["key"], i["verb"], i["category"])')" = "alpha active-pick needs-decision actionable_now" ] ||
  fail "--task must parse key/verb from the status file: $one"
all=$("$DECISION_SH" --all --state-dir "$STATE" --json </dev/null)
assert_contains "$all" '"key": "active-pick"' "--all scans the state dir"
[ -z "$(find "$STATE" -name '*cursor*')" ] || fail "--all must not write open-decision cursors"

# 7. A missing classify lib is an error, not an empty triage.
if FM_HOME="$TDIR/nohome" "$DECISION_SH" --all --state-dir "$STATE" >/dev/null 2>&1; then
  fail "missing fm-classify-lib.sh must exit non-zero"
fi

# 8. A mistyped --input path is an error, and malformed lines are reported.
if "$DECISION_SH" --input "$TDIR/no-such.tsv" >/dev/null 2>&1; then
  fail "missing --input file must exit non-zero"
fi
warn=$(printf 'k\tneeds-decision\tnote\n' | "$DECISION_SH" --input - 2>&1 >/dev/null)
assert_contains "$warn" "skipped 1 malformed line" "3-column stdin without --task warns about skipped lines"

# 9. No selector and non-TTY stdin prints usage instead of scanning.
if printf '' | "$DECISION_SH" >/dev/null 2>&1; then
  fail "no selector must exit non-zero"
fi

pass "all fm-jev-decisions tests passed"
