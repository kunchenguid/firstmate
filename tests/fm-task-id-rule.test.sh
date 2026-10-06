#!/usr/bin/env bash
# tests/fm-task-id-rule.test.sh - the shared fm- task-id prefix rule agrees at
# BOTH real entry points: fm-send.sh selector resolution and the
# fm-jev-decisions CLI.
#
# Table-driven over the id-shape classes in bin/fm-task-id-rule.conf (plain,
# fm-plain, already-prefixed, malformed): each row carries one expected
# outcome (accept -> task id, or reject), and both entry points are run for
# the same selector and asserted against that same expectation, so a
# divergence on either side fails the row instead of drifting quietly apart
# again. The final section proves both loaders fail closed on the same
# malformed artifact instead of guessing the rule.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DECISION_SH="$ROOT/bin/fm-jev-decisions.sh"
[ -x "$SEND" ] || fail "bin/fm-send.sh missing or not executable"
[ -x "$DECISION_SH" ] || fail "bin/fm-jev-decisions.sh missing or not executable"

TDIR=$(fm_test_tmproot fm-task-id-rule)
STATE="$TDIR/state"
HOME_DIR="$TDIR/home"
mkdir -p "$STATE" "$HOME_DIR"

# Shared fixture state: one state dir both entry points resolve against.
# alpha.meta exists (strippable selector resolves); fm-gamma.meta exists (an id
# whose own name carries the prefix routes to its own record); fm-alpha has a
# decision origin but no record of its own (the strip candidate must win); fm-
# has a decision origin and no record under any candidate (reject).
fm_write_meta "$STATE/alpha.meta" "window=sess:fm-alpha-w" "kind=ship"
fm_write_meta "$STATE/fm-gamma.meta" "window=sess:fm-gammaw" "kind=ship"
printf 'blocked [key=old-alpha]: plain row origin\n' > "$STATE/alpha.status"
printf 'blocked [key=old-alpha]: prefixed selector origin\n' > "$STATE/fm-alpha.status"
printf 'blocked [key=old-gamma]: already-prefixed row origin\n' > "$STATE/fm-gamma.status"
printf 'blocked [key=old-broken]: malformed row origin\n' > "$STATE/fm-.status"

# --- stubs -------------------------------------------------------------------

# Fake tmux/herdr/sleep so fm-send can deliver end to end with no live backend
# (same stub shape as tests/fm-send-strict.test.sh).
FB="$TDIR/fakebin"
mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'fm-alpha-w\nfm-gammaw\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
chmod +x "$FB/herdr"
cat > "$FB/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FB/sleep"

# Stub Jev: every fixture decision key starts with "old", so every item comes
# back stale_historical (the category whose row carries the resolve command).
cat > "$TDIR/stub.py" <<'PY'
import http.server, json, sys

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != "Bearer test-dummy-key":
            self.send_response(401)
            self.end_headers()
            return
        body = json.loads(raw)
        answers = {
            "category": {"choice": "stale_historical", "confidence": 0.8,
                         "probabilities": {"stale_historical": 0.8}},
            "actionable_now": {"noul": 0.1},
        }
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
FM_CONFIG_OVERRIDE="$TDIR/no-config"
export FM_CONFIG_OVERRIDE

# --- entry point runners -----------------------------------------------------

# send_outcome <selector> <marker> -> echoes the task id fm-send resolved, or
# "reject" when selector resolution refused it. Acceptance is the inbox record
# fm-send wrote: which state/<id>.inbox directory received the marker names the
# resolved task id.
send_outcome() {
  local selector=$1 marker=$2 rc=0 d
  PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE" FM_TMUX_LOG="$TDIR/tmux.log" FM_SEND_SETTLE=0 \
    "$SEND" "$selector" "$marker" >/dev/null 2>"$TDIR/send.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'reject'
    return 0
  fi
  for d in "$STATE"/*.inbox; do
    if grep -qsF -- "$marker" "$d"/*.msg; then
      local name=${d##*/}
      printf '%s' "${name%.inbox}"
      return 0
    fi
  done
  printf 'accepted-but-unrecorded'
}

# py_outcome <selector> -> echoes the task id the fm-jev-decisions CLI derived
# for its ledger, or "reject" when the rule refused the selector.
#   - "task metadata gone"       -> no candidate had a record: reject
#   - "fm-send would close X,.." -> ledger X (the derived id) differs from the
#     decision's origin, and the command is withheld: accept with id basename X
#   - "Archive or resolve..." without either note -> ledger == origin, so the
#     derived id is the selector itself: accept
py_outcome() {
  local selector=$1 out id
  if ! out=$(FM_STATE_OVERRIDE="$STATE" TYPESAFE_API_KEY=test-dummy-key \
    FM_JEV_TS_BASE="$FM_JEV_TS_BASE" FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE" \
    "$DECISION_SH" --task "$selector" 2>/dev/null); then
    printf 'cli-error'
    return 0
  fi
  case "$out" in
  *"task metadata gone"*)
    printf 'reject'
    ;;
  *"would close"*)
    id=$(printf '%s\n' "$out" | sed -n 's/.*would close \(.*\)\.status, not .*/\1/p' | head -1)
    id=${id##*/}
    if [ -n "$id" ]; then
      printf '%s' "$id"
    else
      printf 'unparsed-output'
    fi
    ;;
  *"Archive or resolve superseded"*)
    printf '%s' "$selector"
    ;;
  *)
    printf 'unparsed-output'
    ;;
  esac
}

# --- the agreement table -----------------------------------------------------
#
# row: <name> <selector> <expected outcome: task id | reject>
# Every row runs through both entry points and must produce the expected
# outcome on BOTH sides; either side diverging fails the row.
run_row() { # <name> <selector> <expected>
  local name=$1 selector=$2 expected=$3 got_send got_py
  got_send=$(send_outcome "$selector" "row-$name-marker")
  got_py=$(py_outcome "$selector")
  assert_equals "$expected" "$got_send" "fm-send selector path: row $name ($selector)"
  assert_equals "$expected" "$got_py" "fm-jev-decisions CLI: row $name ($selector)"
  assert_equals "$got_send" "$got_py" "row $name ($selector): both entry points must derive the same outcome"
  pass "agreement row $name ($selector) -> $expected on both entry points"
}

run_row plain alpha alpha
run_row fm-plain fm-alpha alpha
run_row already-prefixed fm-gamma fm-gamma
run_row malformed fm- reject

# The malformed row's refusal is loud on the fm-send side too: a prefixed
# selector without any candidate record names the tried candidates.
rc=0
PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_STATE_OVERRIDE="$STATE" FM_TMUX_LOG="$TDIR/tmux.log" FM_SEND_SETTLE=0 \
  "$SEND" fm- "malformed-again" >/dev/null 2>"$TDIR/send-again.err" || rc=$?
[ "$rc" -ne 0 ] || fail "malformed selector fm- must not deliver"
assert_contains "$(cat "$TDIR/send-again.err")" "no metadata for fm- in $STATE" \
  "malformed selector diagnostic names the selector and state dir"

# --- resolve commands: the accept rows emit them, the withheld rows do not ----
resolve_cmds_for() { # <selector>
  FM_STATE_OVERRIDE="$STATE" TYPESAFE_API_KEY=test-dummy-key \
    FM_JEV_TS_BASE="$FM_JEV_TS_BASE" FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE" \
    "$DECISION_SH" --task "$1" --resolve-cmds 2>/dev/null || true
}
out=$(resolve_cmds_for alpha)
assert_contains "$out" " alpha --resolve-key old-alpha" \
  "plain row emits a resolve command targeting the resolved id alpha"
out=$(resolve_cmds_for fm-gamma)
assert_contains "$out" " fm-gamma --resolve-key old-gamma" \
  "already-prefixed row emits a resolve command targeting the prefixed id fm-gamma"
out=$(resolve_cmds_for fm-alpha)
assert_contains "$out" "# No actionable resolve commands generated." \
  "fm-plain row withholds the command (fm-send would close alpha.status, not the origin fm-alpha.status)"
out=$(resolve_cmds_for fm-)
assert_contains "$out" "# No actionable resolve commands generated." \
  "malformed row generates no resolve command"

# --- both loaders fail closed on the same malformed artifact ------------------
BAD="$TDIR/bad"
mkdir -p "$BAD"
cp "$ROOT/bin/fm-task-id-rule-lib.sh" "$ROOT/bin/fm-jev-decisions.py" "$BAD/"
printf 'prefix=fm-\ncandidates=exact,nope\nreject_contains=:\n' > "$BAD/fm-task-id-rule.conf"

rc=0
# shellcheck source=/dev/null
( . "$BAD/fm-task-id-rule-lib.sh" ) 2>"$BAD/bash.err" || rc=$?
expect_code 1 "$rc" "bash loader refuses a malformed artifact"
assert_contains "$(cat "$BAD/bash.err")" "unknown candidate transform: nope" \
  "bash loader names the malformed candidate transform"

rc=0
python3 "$BAD/fm-jev-decisions.py" --help >"$BAD/py.out" 2>&1 || rc=$?
expect_code 1 "$rc" "python loader refuses the same malformed artifact"
assert_contains "$(cat "$BAD/py.out")" "unknown candidate transform: nope" \
  "python loader refuses with the same diagnostic as the bash loader"

pass "fm-task-id-rule: both entry points agree on every id shape and both loaders fail closed"
