#!/usr/bin/env bash
# Tests for bin/fm-deploy-check.sh and its merge-path wiring in
# bin/fm-pr-check.sh. A merge is not shipped until its deploy goes Live; these
# tests exercise service resolution, deploy classification, the --once watcher
# check contract, the --arm handoff, the blocking poll, and the merge poll's
# automatic transition to deploy verification. The Render CLI and gh are mocked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPLOY_CHECK="$ROOT/bin/fm-deploy-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-deploy-check-tests)
mkdir -p "$TMP_ROOT"

# A deploys fixture reproducing the real silent-failure shape: commit LIVESHA
# has both a live deploy and an older update_failed one; FAILSHA has only a
# failed deploy; PENDSHA is still building; no deploy exists for any other sha.
DEPLOYS_JSON="$TMP_ROOT/deploys.json"
cat > "$DEPLOYS_JSON" <<'JSON'
[
  {"commit":{"id":"1111111111111111"},"status":"update_failed","id":"dep-oldfail","createdAt":"2026-07-06T13:32:49Z"},
  {"commit":{"id":"1111111111111111"},"status":"live","id":"dep-livewin","createdAt":"2026-07-06T13:46:56Z"},
  {"commit":{"id":"2222222222222222"},"status":"update_failed","id":"dep-fail","createdAt":"2026-07-05T23:37:34Z"},
  {"commit":{"id":"3333333333333333"},"status":"build_in_progress","id":"dep-pending","createdAt":"2026-07-07T10:00:00Z"}
]
JSON

# A services fixture in Render's real wrapped shape (name/id under .service).
SERVICES_JSON="$TMP_ROOT/services.json"
cat > "$SERVICES_JSON" <<'JSON'
[
  {"postgres":{"id":"dpg-x","name":"astrology_insights"}},
  {"service":{"name":"mtmccarthy","id":"srv-realmtm","type":"web_service"}},
  {"service":{"name":"astroai","id":"srv-realastro","type":"web_service"}}
]
JSON

LOGS_TXT="$TMP_ROOT/logs.txt"
printf 'boot: SECRET_KEY environment variable is not set\n' > "$LOGS_TXT"

# Fake render CLI: branches on the subcommand and echoes the fixtures. Reads the
# fixture paths from the environment so tests can vary them per case.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/render" <<'SH'
#!/usr/bin/env bash
case "$1" in
  deploys) cat "${RENDER_DEPLOYS_JSON:-/dev/null}" ;;
  services) cat "${RENDER_SERVICES_JSON:-/dev/null}" ;;
  logs) cat "${RENDER_LOGS_TXT:-/dev/null}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/render"
export PATH="$FAKEBIN:$PATH"
export RENDER_DEPLOYS_JSON="$DEPLOYS_JSON" RENDER_SERVICES_JSON="$SERVICES_JSON" RENDER_LOGS_TXT="$LOGS_TXT"

# run <expected-exit> <label> -- <cmd...>: run cmd, capture stdout, check exit.
# Sets OUT to captured stdout for follow-up assertions.
run() {
  local expected=$1 label=$2 code
  shift 3  # drop expected, label, and the literal --
  OUT=$("$@" 2>/dev/null) && code=0 || code=$?
  expect_code "$expected" "$code" "$label"
}

# --- service resolution -----------------------------------------------------

run 0 "resolve: srv- id passes through" -- "$DEPLOY_CHECK" --resolve srv-abc123
[ "$OUT" = "srv-abc123" ] || fail "srv- passthrough: got '$OUT'"
pass "resolve: srv- id passes through"

MAP="$TMP_ROOT/map.txt"
printf '# comment\n\nmtmccarthy srv-frommap\n' > "$MAP"
FM_RENDER_SERVICES_MAP="$MAP" run 0 "resolve: map file wins" -- "$DEPLOY_CHECK" --resolve mtmccarthy
[ "$OUT" = "srv-frommap" ] || fail "map resolve: got '$OUT'"
pass "resolve: map file wins"

# Empty map -> runtime `render services` fallback by name.
FM_RENDER_SERVICES_MAP=/dev/null run 0 "resolve: runtime services fallback" -- "$DEPLOY_CHECK" --resolve astroai
[ "$OUT" = "srv-realastro" ] || fail "runtime resolve: got '$OUT'"
pass "resolve: runtime services fallback"

FM_RENDER_SERVICES_MAP=/dev/null run 4 "resolve: unknown project errors" -- "$DEPLOY_CHECK" --resolve nosuchproj
pass "resolve: unknown project errors"

# --- --once classification (watcher check contract) -------------------------

run 0 "once: live wins over a same-sha failure" -- "$DEPLOY_CHECK" --once srv-x 1111111111111111
assert_contains "$OUT" "deploy live" "once live output"
pass "once: live wins over a same-sha failure"

LOGOUT="$TMP_ROOT/task.deploy-log"
FM_DEPLOY_LOG_OUT="$LOGOUT" run 0 "once: failed emits one line + boot log" -- "$DEPLOY_CHECK" --once srv-x 2222222222222222
assert_contains "$OUT" "deploy FAILED" "once failed output"
assert_contains "$OUT" "update_failed" "once failed status"
assert_contains "$OUT" "dep-fail" "once failed deploy id"
[ -s "$LOGOUT" ] || fail "boot log not written"
assert_grep "SECRET_KEY" "$LOGOUT" "boot log content captured"
pass "once: failed emits one line + boot log"

run 0 "once: pending is silent" -- "$DEPLOY_CHECK" --once srv-x 3333333333333333
[ -z "$OUT" ] || fail "pending should be silent, got '$OUT'"
pass "once: pending is silent"

run 0 "once: unknown sha is silent" -- "$DEPLOY_CHECK" --once srv-x deadbeef
[ -z "$OUT" ] || fail "no-deploy should be silent, got '$OUT'"
pass "once: unknown sha is silent"

# --- blocking poll ----------------------------------------------------------

FM_DEPLOY_POLL_INTERVAL=0 FM_DEPLOY_TIMEOUT=0 run 0 "poll: live exits 0" -- "$DEPLOY_CHECK" srv-x 1111111111111111
pass "poll: live exits 0"

FM_DEPLOY_POLL_INTERVAL=0 FM_DEPLOY_TIMEOUT=0 run 3 "poll: failed exits 3 with boot log" -- "$DEPLOY_CHECK" srv-x 2222222222222222
assert_contains "$OUT" "SECRET_KEY" "poll failed prints boot log"
pass "poll: failed exits 3 with boot log"

# Unknown sha never reaches Live -> bounded timeout exit 2.
FM_DEPLOY_POLL_INTERVAL=0 FM_DEPLOY_TIMEOUT=0 run 2 "poll: timeout exits 2" -- "$DEPLOY_CHECK" srv-x deadbeef
pass "poll: timeout exits 2"

# --- --arm writes meta + a deploy probe check.sh ----------------------------

STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
printf 'project=/repos/mtmccarthy\n' > "$STATE/armtask.meta"
FM_STATE_OVERRIDE="$STATE" FM_RENDER_SERVICES_MAP="$MAP" \
  run 0 "arm: resolves + writes check.sh" -- "$DEPLOY_CHECK" --arm armtask mtmccarthy 1111111111111111
assert_grep "deploy_service=srv-frommap" "$STATE/armtask.meta" "arm records service"
assert_grep "deploy_sha=1111111111111111" "$STATE/armtask.meta" "arm records sha"
assert_present "$STATE/armtask.check.sh" "arm wrote check.sh"
assert_grep "--once" "$STATE/armtask.check.sh" "armed check.sh is a deploy probe"
# The armed check.sh, run under the watcher contract, reports live for this sha.
ARMOUT=$(FM_STATE_OVERRIDE="$STATE" bash "$STATE/armtask.check.sh" 2>/dev/null)
assert_contains "$ARMOUT" "deploy live" "armed check.sh probes the deploy"
pass "arm: resolves + writes check.sh"

# --- merge-path wiring: fm-pr-check transitions merge -> deploy --------------

# Fake gh: PR is MERGED, merge commit is a Live sha.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"--json state"*) echo MERGED ;;
  *"--json mergeCommit"*) echo 1111111111111111 ;;
  *"--json headRefOid"*) echo 1111111111111111 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

WSTATE="$TMP_ROOT/wstate"
mkdir -p "$WSTATE"
printf 'project=/repos/mtmccarthy\n' > "$WSTATE/wtask.meta"
FM_STATE_OVERRIDE="$WSTATE" run 0 "wiring: pr-check arms merge poll" -- \
  "$PR_CHECK" wtask https://github.com/o/mtmccarthy/pull/7
assert_present "$WSTATE/wtask.check.sh" "merge poll written"

# Run the merge poll with a mapped service: it must hand off to deploy verify.
POLLOUT=$(FM_STATE_OVERRIDE="$WSTATE" FM_RENDER_SERVICES_MAP="$MAP" bash "$WSTATE/wtask.check.sh" 2>/dev/null)
assert_contains "$POLLOUT" "verifying deploy" "merge poll hands off to deploy verify"
assert_grep "--once" "$WSTATE/wtask.check.sh" "check.sh replaced by deploy probe"
pass "wiring: merged PR with a mapped service transitions to deploy verify"

# Same merge, but no service maps (empty map, services fixture lacks the name):
# the poll must fall back to the plain "merged" wake and NOT rewrite check.sh.
NSTATE="$TMP_ROOT/nstate"
mkdir -p "$NSTATE"
printf 'project=/repos/unmappedproj\n' > "$NSTATE/ntask.meta"
FM_STATE_OVERRIDE="$NSTATE" run 0 "wiring: pr-check arms (no service)" -- \
  "$PR_CHECK" ntask https://github.com/o/unmappedproj/pull/9
NPOLLOUT=$(FM_STATE_OVERRIDE="$NSTATE" FM_RENDER_SERVICES_MAP=/dev/null bash "$NSTATE/ntask.check.sh" 2>/dev/null)
[ "$NPOLLOUT" = "merged" ] || fail "no-service poll should emit plain 'merged', got '$NPOLLOUT'"
assert_no_grep "--once" "$NSTATE/ntask.check.sh" "no-service check.sh stays the merge poll"
pass "wiring: merged PR with no mapped service keeps the plain merged wake"

echo "# all fm-deploy-check tests passed"
