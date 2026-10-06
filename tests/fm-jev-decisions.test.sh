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
KEYS = {"Bearer test-dummy-key", "Bearer env-file-key"}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        with open(sys.argv[2], "ab") as log:
            log.write(raw + b"\n")
        if self.headers.get("Authorization") not in KEYS:
            self.send_response(401)
            self.end_headers()
            return
        body = json.loads(raw)
        key = body["state"]["key"]
        if key.startswith("noul-rejected"):
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error": "unsupported question type: noul"}')
            return
        answers = {}
        for prefix, (choice, noul) in ANSWERS.items():
            if key.startswith(prefix):
                answers = {"category": {"choice": choice, "confidence": 0.8, "probabilities": {choice: 0.8}},
                           "actionable_now": {"noul": noul}}
                break
        if key.startswith("noul-dropped"):
            answers = {"category": {"choice": "actionable_now", "confidence": 0.8},
                       "actionable_now": {"error": "unsupported question type: noul"}}
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
python3 "$TDIR/stub.py" "$TDIR/port" "$TDIR/requests.log" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
[ -s "$TDIR/port" ] || fail "stub Jev server did not start"

FM_JEV_TS_BASE="http://127.0.0.1:$(cat "$TDIR/port")"
export FM_JEV_TS_BASE
export TYPESAFE_API_KEY=test-dummy-key
FM_CONFIG_OVERRIDE="$TDIR/no-config"
export FM_CONFIG_OVERRIDE

# ledger <state-dir> <task> <key> <verb> <note>... writes an open-decision status file with metadata.
ledger() {
  local dir=$1 task=$2
  shift 2
  mkdir -p "$dir"
  : > "$dir/$task.meta"
  : > "$dir/$task.status"
  while [ "$#" -ge 3 ]; do
    printf '%s [key=%s]: %s\n' "$2" "$1" "$3" >> "$dir/$task.status"
    shift 3
  done
}

# 0. Only the status-record selectors exist.
help=$("$DECISION_SH" --help)
for opt in --task --status-file --all --state-dir --json --resolve-cmds --category --min-noul --limit; do
  assert_contains "$help" "$opt" "help lists $opt"
done
for opt in --input --key --verb --note --max-workers; do
  if printf '%s' "$help" | grep -q -- "$opt\b"; then fail "help must not list $opt: $help"; fi
  if "$DECISION_SH" --all "$opt" x >/dev/null 2>&1; then fail "$opt must be rejected"; fi
done

# 1. A status file with no open decisions exits cleanly without calling Jev.
EMPTY="$TDIR/empty-state"; mkdir -p "$EMPTY"; : > "$EMPTY/none.status"
out=$(FM_STATE_OVERRIDE="$EMPTY" "$DECISION_SH" --task none)
assert_contains "$out" "No open decisions found" "empty ledger emits no decisions message"
[ "$(FM_STATE_OVERRIDE="$EMPTY" "$DECISION_SH" --task none --json)" = "[]" ] || fail "empty ledger must emit an empty json array"

# 2. Classification maps categories to suggestions.
MAIN="$TDIR/main-state"
ledger "$MAIN" test-task \
  pending-reply-abc123 blocked "pending-reply-missed: task=test-task request=CONFIG_REREAD" \
  quota-exceeded needs-decision "Need captain approval to upgrade API tier" \
  net-down blocked "upstream host unreachable" \
  active-fix needs-decision "choose the fix now" \
  bogus-choice needs-decision "server returns an unknown category" \
  missing-answer needs-decision "server returns no category"
run_main() { FM_STATE_OVERRIDE="$MAIN" "$DECISION_SH" --task test-task "$@"; }

json=$(run_main --json)
cat_of() { printf '%s' "$json" | python3 -c 'import json,sys; print({i["key"]: i["category"] for i in json.load(sys.stdin)}[sys.argv[1]])' "$1"; }
[ "$(cat_of pending-reply-abc123)" = stale_historical ] || fail "pending-reply key should be stale_historical"
[ "$(cat_of quota-exceeded)" = policy_spend ] || fail "quota key should be policy_spend"
[ "$(cat_of net-down)" = external_block ] || fail "net key should be external_block"
[ "$(cat_of active-fix)" = actionable_now ] || fail "active key should be actionable_now"
[ "$(cat_of bogus-choice)" = unavailable ] || fail "unknown category choice must be unavailable"
[ "$(cat_of missing-answer)" = unavailable ] || fail "missing category choice must be unavailable"

table=$(run_main)
assert_contains "$table" "Escalate to Captain" "policy_spend suggestion rendered"
assert_contains "$table" "Active blocker" "actionable_now suggestion rendered"
assert_contains "$table" "unavailable: 2" "summary counts invalid answers as unavailable"

# 3. Filters.
active=$(run_main --category actionable_now --json)
[ "$(printf '%s' "$active" | python3 -c 'import json,sys; print(",".join(i["key"] for i in json.load(sys.stdin)))')" = active-fix ] ||
  fail "--category actionable_now must select only the active key: $active"
urgent=$(run_main --min-noul 0.35 --json)
[ "$(printf '%s' "$urgent" | python3 -c 'import json,sys; print(",".join(sorted(i["key"] for i in json.load(sys.stdin))))')" = active-fix,net-down ] ||
  fail "--min-noul must keep only items at or above the threshold: $urgent"

# 4. Resolve commands are shell-safe for a hostile task name.
EVIL_TASK='t;touch pwned-task'
EVIL_STATE="$TDIR/evil-state"
ledger "$EVIL_STATE" "$EVIL_TASK" old-dep blocked superseded
FAKE="$TDIR/fakeroot"; mkdir -p "$FAKE/bin"
cp -R "$ROOT/bin/." "$FAKE/bin/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$TDIR/argv" > "$FAKE/bin/fm-send.sh"; chmod +x "$FAKE/bin/fm-send.sh"
RUNDIR="$TDIR/elsewhere"; mkdir -p "$RUNDIR"
cmds=$(FM_HOME="$FAKE" "$DECISION_SH" --all --state-dir "$EVIL_STATE" --resolve-cmds)
assert_contains "$cmds" "$FAKE/bin/fm-send.sh" "resolve cmd names the home's own fm-send.sh by absolute path"
(cd "$RUNDIR" && bash -c "$cmds")
[ ! -e "$RUNDIR/pwned-task" ] || fail "resolve cmds executed injected shell"
[ "$(sed -n 1p "$TDIR/argv")" = "$EVIL_TASK" ] || fail "resolve cmd must pass the task verbatim"
[ "$(sed -n 3p "$TDIR/argv")" = old-dep ] || fail "resolve cmd must pass the key verbatim"

# 5. Pending replies may still be owed: stale ones get no auto-resolve command.
ledger "$EVIL_STATE" w \
  pending-reply-cfg blocked "pending-reply-missed: task=w request=CONFIG_REREAD" \
  pending-reply-other blocked "pending-reply-missed: task=w request=STATUS_PING" \
  active-now needs-decision "choose now" \
  quota-up needs-decision "approve spend" \
  missing-answer needs-decision "jev gives no category" \
  old-dep blocked "superseded dependency"
wording=$(FM_STATE_OVERRIDE="$EVIL_STATE" "$DECISION_SH" --task w --json)
[ "$(printf '%s' "$wording" | python3 -c 'import json,sys; print(",".join(sorted(i["key"] for i in json.load(sys.stdin) if i["resolve_cmd"])))')" = "old-dep" ] ||
  fail "only non-pending stale items may get a resolve command: $wording"
assert_contains "$wording" "no longer owed" "pending reply suggestion asks to confirm the reply is not owed"

# 6. Status-file extraction: tab-bearing notes keep key/verb intact, --all is read-only.
STATE="$TDIR/state it's"; mkdir -p "$STATE"
printf 'needs-decision [key=active-pick]: choose\tA or B\n' > "$STATE/alpha.status"
one=$(FM_STATE_OVERRIDE="$STATE" "$DECISION_SH" --task alpha --json)
[ "$(printf '%s' "$one" | python3 -c 'import json,sys; i=json.load(sys.stdin)[0]; print(i["task"], i["key"], i["verb"], i["category"])')" = "alpha active-pick needs-decision actionable_now" ] ||
  fail "--task must parse key/verb from the status file: $one"
all=$("$DECISION_SH" --all --state-dir "$STATE" --json </dev/null)
assert_contains "$all" '"key": "active-pick"' "--all scans the state dir"
[ -z "$(find "$STATE" -name '*cursor*')" ] || fail "--all must not write open-decision cursors"

# 7. Resolve commands pin the home and state the decisions were read from.
OTHER="$TDIR/other state"; mkdir -p "$OTHER"
printf 'blocked [key=old-dep]: superseded dependency\n' > "$OTHER/beta.status"
: > "$OTHER/beta.meta"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FM_HOME" "$FM_STATE_OVERRIDE" "$@" > %q\n' "$TDIR/argv" > "$FAKE/bin/fm-send.sh"
check_pinned() {
  local label=$1 cmds
  shift
  rm -f "$TDIR/argv"
  cmds=$(FM_HOME="$FAKE" "$DECISION_SH" "$@" --resolve-cmds)
  (cd "$RUNDIR" && env -u FM_STATE_OVERRIDE FM_HOME=/wrong/home bash -c "$cmds")
  [ "$(sed -n 1p "$TDIR/argv")" = "$FAKE" ] || fail "resolve cmd must pin FM_HOME ($label)"
  [ "$(sed -n 2p "$TDIR/argv")" = "$OTHER" ] || fail "resolve cmd must pin the selected state dir ($label)"
  [ "$(sed -n 3p "$TDIR/argv")" = beta ] || fail "resolve cmd must target the selected task ($label)"
}
check_pinned status-file --status-file "$OTHER/beta.status"
check_pinned state-dir --all --state-dir "$OTHER"

# 7b. A torn-down task (no metadata) gets no resolve command fm-send could not target.
GONE="$TDIR/gone state"; mkdir -p "$GONE"
printf 'blocked [key=old-dep]: superseded dependency\n' > "$GONE/gamma.status"
gone=$("$DECISION_SH" --all --state-dir "$GONE" --resolve-cmds)
[ "$gone" = "# No actionable resolve commands generated." ] || fail "torn-down task must not get a resolve cmd: $gone"
assert_contains "$("$DECISION_SH" --all --state-dir "$GONE")" "task metadata gone" "torn-down task is flagged for manual close"

# 7c. A resolve cmd is kept only when fm-send would close the ledger the decision came from.
LEGACY="$TDIR/legacy state"; mkdir -p "$LEGACY"
printf 'blocked [key=old-dep]: superseded dependency\n' > "$LEGACY/fm-delta.status"
printf 'blocked [key=old-dep]: a different decision\n' > "$LEGACY/delta.status"
: > "$LEGACY/delta.meta"
legacy=$("$DECISION_SH" --status-file "$LEGACY/fm-delta.status" --json)
[ "$(printf '%s' "$legacy" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["resolve_cmd"])')" = "" ] ||
  fail "fm-delta.status must not get a cmd fm-send would apply to delta.status: $legacy"
assert_contains "$legacy" "close it by hand" "ledger mismatch is flagged for manual close"
: > "$LEGACY/fm-delta.meta"
rm -f "$TDIR/argv"
(cd "$RUNDIR" && bash -c "$(FM_HOME="$FAKE" "$DECISION_SH" --status-file "$LEGACY/fm-delta.status" --resolve-cmds)")
[ "$(sed -n 3p "$TDIR/argv")" = fm-delta ] || fail "fm-delta.meta makes fm-delta.status resolvable"

# 7d. An endpoint that rejects or drops the noul question leaves the batch unavailable.
ledger "$TDIR/noul-state" n noul-rejected needs-decision x noul-dropped needs-decision y
noul=$(FM_STATE_OVERRIDE="$TDIR/noul-state" "$DECISION_SH" --task n --json)
[ "$(printf '%s' "$noul" | python3 -c 'import json,sys; print(",".join(i["category"] for i in json.load(sys.stdin)))')" = unavailable,unavailable ] ||
  fail "a rejected noul answer must report unavailable: $noul"

# 7e. Only a finite noul within 0..1 is a score; anything else is unavailable to --min-noul.
python3 - "$TDIR" <<'PY'
import sys
p = sys.argv[1] + "/stub.py"
s = open(p).read()
s = s.replace('if key.startswith("noul-dropped"):', '''if key.startswith("noul-raw-"):
            answers = {"category": {"choice": "actionable_now", "confidence": 0.8},
                       "actionable_now": {"noul": json.loads(body["state"]["note"])}}
        if key.startswith("noul-dropped"):''')
open(sys.argv[1] + "/stub-range.py", "w").write(s)
PY
python3 "$TDIR/stub-range.py" "$TDIR/port-range" "$TDIR/requests-range.log" &
RANGE_PID=$!
trap 'kill "$STUB_PID" "$RANGE_PID" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 50); do [ -s "$TDIR/port-range" ] && break; sleep 0.1; done
[ -s "$TDIR/port-range" ] || fail "range stub Jev server did not start"
range_args=()
for v in NaN Infinity -Infinity -0.5 1.5 0 0.5 1; do range_args+=("noul-raw-$v" needs-decision "$v"); done
ledger "$TDIR/range-state" r "${range_args[@]}"
range_run() { FM_JEV_TS_BASE="http://127.0.0.1:$(cat "$TDIR/port-range")" FM_STATE_OVERRIDE="$TDIR/range-state" "$DECISION_SH" --task r --json "$@"; }
range_keys() { python3 -c 'import json,sys; print(",".join(i["key"] + "=" + i["category"] for i in json.load(sys.stdin)))'; }
[ "$(range_run | range_keys)" = "noul-raw-NaN=unavailable,noul-raw-Infinity=unavailable,noul-raw--Infinity=unavailable,noul-raw--0.5=unavailable,noul-raw-1.5=unavailable,noul-raw-0=actionable_now,noul-raw-0.5=actionable_now,noul-raw-1=actionable_now" ] ||
  fail "only finite noul within 0..1 may be valid: $(range_run)"
[ "$(range_run --min-noul 0.01 | range_keys)" = "noul-raw-0.5=actionable_now,noul-raw-1=actionable_now" ] ||
  fail "--min-noul must see only valid scores: $(range_run --min-noul 0.01)"

# 8. A key configured only in the home's .env is used.
ENVHOME="$TDIR/envhome"; mkdir -p "$ENVHOME"; ln -s "$ROOT/bin" "$ENVHOME/bin"
printf 'TYPESAFE_API_KEY="env-file-key"\n' > "$ENVHOME/.env"
envkey=$(env -u TYPESAFE_API_KEY FM_HOME="$ENVHOME" FM_STATE_OVERRIDE="$MAIN" "$DECISION_SH" --task test-task --category actionable_now --json)
assert_contains "$envkey" '"key": "active-fix"' ".env TYPESAFE_API_KEY classifies decisions"

# 9. Never-send values are withheld from every Jev request and from all local output.
mkdir -p "$TDIR/ns-config"
printf '# client names\n  Example   Client  \nGlobex\n' > "$TDIR/ns-config/dispatch-never-send"
NS="$TDIR/ns-state"
ledger "$NS" ns active-ns needs-decision "decide for EXAMPLE    client Ltd now"
ledger "$NS" globex-ops old-ns blocked "superseded"
ledger "$NS" plain old-plain blocked "superseded"
run_ns() { FM_HOME="$FAKE" FM_CONFIG_OVERRIDE="$TDIR/ns-config" "$DECISION_SH" --all --state-dir "$NS" "$@"; }
: > "$TDIR/requests.log"
ns=$(run_ns --json)
assert_contains "$ns" '"category": "actionable_now"' "withheld note is still classified"
if grep -qiE "example|globex" "$TDIR/requests.log"; then
  fail "never-send value reached the Jev request"
fi
assert_contains "$(cat "$TDIR/requests.log")" "[withheld]" "never-send value is replaced in the request"
ns_table=$(run_ns)
ns_cmds=$(run_ns --resolve-cmds)
for out in "$ns" "$ns_table" "$ns_cmds"; do
  if printf '%s' "$out" | grep -qiE "example|globex"; then fail "never-send value printed locally: $out"; fi
done
assert_contains "$ns" '"note": "decide for [withheld] Ltd now"' "--json note carries the request's redaction"
assert_contains "$ns" '"task": "[withheld]-ops"' "--json task carries the redaction"
assert_contains "$ns_table" "[withheld]-ops" "table task carries the redaction"
printf '%s' "$ns" | python3 -c '
import json, sys
rows = {i["key"]: i for i in json.load(sys.stdin)}
assert rows["old-ns"]["category"] == "stale_historical", rows
assert rows["old-ns"]["resolve_cmd"] == "", rows["old-ns"]
assert rows["old-plain"]["task"] == "plain" and rows["old-plain"]["resolve_cmd"], rows["old-plain"]
' || fail "a never-send row must lose its resolve cmd while an ordinary row keeps it: $ns"
rm -f "$TDIR/argv"
(cd "$RUNDIR" && bash -c "$ns_cmds")
[ "$(sed -n 3p "$TDIR/argv")" = plain ] && [ "$(sed -n 5p "$TDIR/argv")" = old-plain ] ||
  fail "the ordinary row's resolve cmd must still work: $ns_cmds"
printf 'Acme\nAcme Health Partners\nHealth Partners Group\n' > "$TDIR/ns-config/dispatch-never-send"
ledger "$TDIR/overlap-state" ns active-overlap needs-decision "acme health partners group owes X"
: > "$TDIR/requests.log"
FM_CONFIG_OVERRIDE="$TDIR/ns-config" FM_STATE_OVERRIDE="$TDIR/overlap-state" "$DECISION_SH" --task ns --json >/dev/null
sent_note=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["state"]["note"])' "$TDIR/requests.log")
[ "$sent_note" = "[withheld] owes X" ] || fail "overlapping never-send values must leave no fragment: $sent_note"
# 9b. A never-send value that shell quoting would respell (apostrophe, double quote, backslash)
# leaves no recoverable trace when it sits in a task name or in the home path.
no_trace() {
  python3 - "$1" "$2" "$3" <<'PY' || fail "never-send value recoverable via $3: $2"
import json, shlex, sys
value, out = sys.argv[1].lower(), sys.argv[2]
words = [out]
for line in out.splitlines():
    if not line.startswith("#"):
        words += shlex.split(line)
try:
    words += [str(v) for row in json.loads(out) for v in row.values()]
except ValueError:
    pass
assert not any(value in w.lower() for w in words)
PY
}
i=0
for v in "o'brien" 'say "hi"' 'back\slash'; do
  i=$((i + 1))
  printf '%s\n' "$v" > "$TDIR/ns-config/dispatch-never-send"
  QS="$TDIR/quoted-state-$i"
  ledger "$QS" "t-$v-ops" old-q blocked "superseded"
  QHOME="$TDIR/home-$v"; mkdir -p "$QHOME"; ln -s "$ROOT/bin" "$QHOME/bin"
  ledger "$TDIR/quoted-home-state-$i" plain old-q blocked "superseded"
  for case in task home; do
    if [ "$case" = task ]; then home=$FAKE; st=$QS; else home=$QHOME; st="$TDIR/quoted-home-state-$i"; fi
    q() { FM_HOME="$home" FM_CONFIG_OVERRIDE="$TDIR/ns-config" "$DECISION_SH" --all --state-dir "$st" "$@"; }
    qcmds=$(q --resolve-cmds)
    [ "$qcmds" = "# No actionable resolve commands generated." ] || fail "quoted never-send value in $case kept a resolve cmd: $qcmds"
    no_trace "$v" "$qcmds" "--resolve-cmds ($case)"
    no_trace "$v" "$(q --json)" "--json ($case)"
  done
done
mkdir -p "$TDIR/bad-config/dispatch-never-send"
: > "$TDIR/requests.log"
bad=$(FM_CONFIG_OVERRIDE="$TDIR/bad-config" FM_STATE_OVERRIDE="$TDIR/overlap-state" "$DECISION_SH" --task ns --json 2>/dev/null)
assert_contains "$bad" '"category": "unavailable"' "unreadable never-send list sends nothing"
assert_contains "$bad" '"note": "[withheld]"' "unreadable never-send list withholds the --json note"
if printf '%s' "$bad" | grep -qi "acme"; then fail "unreadable never-send list must withhold all local text: $bad"; fi
[ ! -s "$TDIR/requests.log" ] || fail "unreadable never-send list must not reach Jev"

# 10. A missing classify lib is an error, not an empty triage.
if FM_HOME="$TDIR/nohome" "$DECISION_SH" --all --state-dir "$STATE" >/dev/null 2>&1; then
  fail "missing fm-classify-lib.sh must exit non-zero"
fi

# 11. A missing --task ledger is an error.
if FM_STATE_OVERRIDE="$EMPTY" "$DECISION_SH" --task no-such-task >/dev/null 2>&1; then
  fail "missing --task ledger must exit non-zero"
fi

# 12. No selector and non-TTY stdin prints usage instead of scanning.
if printf '' | "$DECISION_SH" >/dev/null 2>&1; then
  fail "no selector must exit non-zero"
fi

pass "all fm-jev-decisions tests passed"
