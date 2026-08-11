#!/usr/bin/env bash
# Behavior tests for crew dispatch validation, Mission Control rendering, and
# bounded board edits through the shared request parser.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-dispatch)
DISPATCH="$ROOT/bin/fm-crew-dispatch.sh"
BOARD="$ROOT/bin/fm-mission-control.sh"
REPLY="$ROOT/bin/fm-procevent-board-reply.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
CONFIG="$HOME_DIR/config/crew-dispatch.json"
SNAPSHOT="$TMP_ROOT/snapshot.json"
cat > "$SNAPSHOT" <<JSON
{"schema":"fm-fleet-snapshot.v1","generated":"2026-08-10T12:00:00Z","fm_home":"$HOME_DIR",
 "roots":{"state":"$HOME_DIR/state","data":"$HOME_DIR/data","projects":"$HOME_DIR/projects"},
 "backlog":{"present":true,"records":[]},"tasks":[],
 "secondmate_current":{"registry":{"available":true,"complete":true,
   "input_truncated":false,"records_truncated":false,"records":[]},"records":[]}}
JSON

write_dispatch_fixture() {
  cat > "$CONFIG" <<'JSON'
{
  "rules": [
    {
      "id": "visual-ui",
      "when": "visual browser work with a deliberately long task type that must wrap without hiding its assignment at phone width",
      "use": [
        {"id":"visual-codex","harness":"codex","model":"gpt-5.5","effort":"high","provider":"openai"},
        {"id":"visual-claude","harness":"claude","model":"claude-sonnet-5","effort":"xhigh","provider":"anthropic"}
      ],
      "fallback": {"id":"visual-pi-fallback","harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},
      "independent": true,
      "why": "Browser verification benefits from the isolated visual tool session."
    },
    {
      "id": "small-docs",
      "when": "small documentation corrections",
      "use": {"id":"small-docs-claude","harness":"claude","model":"claude-haiku-4-5","effort":"low"}
    }
  ],
  "default": [
    {"id":"default-pi","harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},
    {"id":"default-grok","harness":"grok","model":"grok-4.5","effort":"high"}
  ],
  "default_fallback": {"id":"default-claude-fallback","harness":"claude","model":"claude-sonnet-5","effort":"high"}
}
JSON
}

capture_request() {  # <path> <wire>
  local path=$1 wire=$2
  {
    printf 'schema=fm-board-delta.v1\nstatus=delta\nsource=board-fixture\nrequests=1\n\n'
    printf 'prompts[1]{received,attempt,prompt}:\n'
    printf '  "2026-08-10T12:00:00Z","fm-board:fixture",'
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$wire"
    printf 'board-delta-end=1\n'
  } > "$path"
}

write_dispatch_fixture
status=$($DISPATCH status "$CONFIG") || fail "a valid multi-rule fixture must have readable status"
[ "$(printf '%s' "$status" | jq -r '.status')" = valid ] \
  || fail "a valid dispatch fixture was not reported valid"
[ "$(printf '%s' "$status" | jq -r '.config.rules | length')" = 2 ] \
  || fail "the status read dropped a dispatch rule"
[ "$(printf '%s' "$status" | jq -r '.config.rules[0].use | length')" = 2 ] \
  || fail "the status read flattened a profile array"
[ "$(printf '%s' "$status" | jq -r '.config.default | length')" = 2 ] \
  || fail "the status read flattened the default profile array"
[ "$(printf '%s' "$status" | jq -r '.revisions.rules[0].revision | length')" = 64 ] \
  || fail "the status read did not revision each rule"
[ "$(printf '%s' "$status" | jq -r '.revisions.rules[0].profiles[1].revision | length')" = 64 ] \
  || fail "the status read did not revision each profile"
pass "dispatch status preserves multi-rule and quota-array fixtures"

READ_ONLY="$TMP_ROOT/read-only.html"
CONTROLLED="$TMP_ROOT/controlled.html"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$READ_ONLY" >/dev/null || fail "the view-only board must render dispatch config"
assert_grep '>Dispatch</h2>' "$READ_ONLY" "the System view must carry Dispatch"
assert_grep 'Active and valid' "$READ_ONLY" "the board must state the current validation verdict"
assert_grep '2-profile quota array' "$READ_ONLY" "profile arrays must be labelled as quota arrays"
assert_grep '<dt>Harness</dt><dd>codex</dd>' "$READ_ONLY" "a rule must show its harness"
assert_grep '<dt>Model</dt><dd>gpt-5.5</dd>' "$READ_ONLY" "a rule must show its model"
assert_grep '<dt>Effort</dt><dd>high</dd>' "$READ_ONLY" "a rule must show its effort"
assert_grep '<dt>Provider</dt><dd>openai</dd>' "$READ_ONLY" "a rule must show its provider when set"
assert_grep '<h4>small documentation corrections</h4>' "$READ_ONLY" \
  "the rule heading must carry the complete task type"
assert_no_grep 'class="dispatch-when"' "$READ_ONLY" \
  "a rule must not repeat its task type below the heading"
assert_grep '>Why this rule exists</summary>' "$READ_ONLY" "a rationale must stay collapsed"
assert_grep '<h5>Configured fallback</h5>' "$READ_ONLY" "a rule fallback must remain visible"
assert_grep '<dt>Model</dt><dd>anthropic/claude-sonnet-5</dd>' "$READ_ONLY" \
  "a configured fallback model must be visible"
assert_grep '<h5>Configured default fallback</h5>' "$READ_ONLY" \
  "the default fallback must remain visible"
assert_grep 'Model-provider allowance and pace appear below.' "$READ_ONLY" \
  "dispatch must link to its related provider allowance surface"
assert_grep 'Dispatch assignments above use these provider budgets.' "$READ_ONLY" \
  "provider allowance must link back to dispatch"
assert_grep '>Raw crew-dispatch.json</summary>' "$READ_ONLY" "raw JSON must be expandable rather than primary"
assert_grep 'Secondmate homes receive this same file when it is pushed.' "$READ_ONLY" \
  "the board must state the inherited-file relationship"
assert_no_grep 'data-intent="dispatch"' "$READ_ONLY" \
  "a board rendered without controls must remain view-only"

FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the controls board must render dispatch editors"
editors=$(grep -o 'data-intent="dispatch"' "$CONTROLLED" | wc -l | tr -d ' ')
[ "$editors" = 3 ] || fail "two rules and the default must each get one bounded editor, got $editors"
assert_grep 'data-dispatch-profile' "$CONTROLLED" "an array editor must identify a selected existing profile"
assert_grep 'data-dispatch-rule-id="visual-ui"' "$CONTROLLED" \
  "a rule editor must carry its stable rule identity"
assert_grep 'data-profile-id="visual-codex"' "$CONTROLLED" \
  "a profile option must carry its stable profile identity"
assert_grep 'return {ruleId:target.ruleId,profileId:target.profileId' "$CONTROLLED" \
  "a persisted dispatch draft must retain stable identities"
assert_grep 'values.ruleRevision !== (block.getAttribute("data-dispatch-rule-revision")' "$CONTROLLED" \
  "a persisted dispatch draft must refuse a changed rule revision"
assert_grep 'request.expected_rule_revision = dispatch.ruleRevision' "$CONTROLLED" \
  "dispatch submission must use the draft-bound rule revision"
rendered_rule_revision=$(sed -n 's/.*data-dispatch-rule-revision="\([0-9a-f]*\)".*/\1/p' "$CONTROLLED" | head -1)
[ "${#rendered_rule_revision}" -eq 64 ] || fail "an editor must carry the rendered rule revision"
rendered_profile_revision=$(sed -n 's/.*data-revision="\([0-9a-f]*\)".*/\1/p' "$CONTROLLED" | head -1)
[ "${#rendered_profile_revision}" -eq 64 ] || fail "each profile option must carry its rendered revision"
assert_grep 'data-dispatch-model' "$CONTROLLED" "the bounded editor must expose model"
assert_grep 'data-dispatch-effort' "$CONTROLLED" "the bounded editor must expose effort"
assert_grep 'body.lavish .dispatch-editor{display:none' "$CONTROLLED" \
  "the legacy bridge must not reveal dispatch edits"
pass "dispatch is readable with controls off and bounded editors appear with controls on"

MISSING_HOME="$TMP_ROOT/missing"
mkdir -p "$MISSING_HOME/config" "$MISSING_HOME/state" "$MISSING_HOME/data" "$MISSING_HOME/projects"
missing_status=$($DISPATCH status "$MISSING_HOME/config/crew-dispatch.json") \
  || fail "an absent dispatch file must be a normal status result"
[ "$(printf '%s' "$missing_status" | jq -r '.status')" = absent ] \
  || fail "an absent dispatch file was not reported absent"
FM_CONFIG_OVERRIDE="$MISSING_HOME/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$TMP_ROOT/missing.html" >/dev/null || fail "a board with no dispatch file must render"
assert_grep 'No crew dispatch file is active in this home.' "$TMP_ROOT/missing.html" \
  "the missing-file state must be explicit"
pass "a missing crew dispatch file renders an explicit inactive state"

cp "$CONFIG" "$TMP_ROOT/valid-dispatch.json"
printf '%s\n' '{"rules":[{"id":"broken","when":"broken quota choice","use":[]}]}' > "$CONFIG"
invalid_status=$($DISPATCH status "$CONFIG") || fail "an invalid profile array must still return board status"
[ "$(printf '%s' "$invalid_status" | jq -r '.status')" = invalid ] \
  || fail "an empty profile array was not reported invalid"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$TMP_ROOT/invalid.html" >/dev/null || fail "an invalid dispatch file must still render"
assert_grep 'each rule needs at least one use profile' "$TMP_ROOT/invalid.html" \
  "the board must show the shared validator refusal"
assert_grep '>Raw crew-dispatch.json</summary>' "$TMP_ROOT/invalid.html" \
  "an invalid file must keep raw JSON behind an expandable view"
mv "$TMP_ROOT/valid-dispatch.json" "$CONFIG"
pass "a malformed profile array renders the existing validator refusal without becoming board logic"

VALID_RESULT="$TMP_ROOT/valid.result"
valid_request=$(printf '%s' "$status" | jq -c \
  '{v:1,intent:"dispatch",home:"main",scope:"rule",rule_id:.config.rules[0].id,
    profile_id:.config.rules[0].use[1].id,model:"claude-opus-5",effort:"max",request_id:"dispatch-valid-one",
    expected_rule_revision:.revisions.rules[0].revision,
    expected_profile_revision:.revisions.rules[0].profiles[1].revision}') \
  || fail "could not build a revision-bound valid request"
capture_request "$VALID_RESULT" "FM-BOARD-REQUEST $valid_request"
FM_HOME="$HOME_DIR" "$REPLY" apply "$VALID_RESULT" > "$TMP_ROOT/valid.out" \
  || fail "a valid dispatch intent must apply through the board collector"
[ "$(jq -r '.rules[0].use[1].model' "$CONFIG")" = claude-opus-5 ] \
  || fail "the selected array profile model did not change"
[ "$(jq -r '.rules[0].use[0].model' "$CONFIG")" = gpt-5.5 ] \
  || fail "editing one array profile changed its neighbour"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the board must regenerate after a valid edit"
assert_grep 'Assignment updated: claude / claude-opus-5 / max.' "$CONTROLLED" \
  "a successful write must surface the new assignment"
pass "a board dispatch request updates one existing array profile and regenerates confirmation"

cp "$CONFIG" "$TMP_ROOT/before-replay.json"
FM_HOME="$HOME_DIR" "$REPLY" apply "$VALID_RESULT" > "$TMP_ROOT/replay.out" \
  || fail "a replayed successful dispatch intent must be accepted as a no-op"
cmp -s "$TMP_ROOT/before-replay.json" "$CONFIG" \
  || fail "a replayed successful dispatch intent rewrote the source"
pass "a replayed applied request is idempotent"

jq '(.rules[] | select(.id == "visual-ui").use[] | select(.id == "visual-claude"))
  |= (.harness = "pi" | .provider = "changed-provider")' "$CONFIG" > "$TMP_ROOT/changed-target.json" \
  || fail "could not stage the changed replay target"
mv "$TMP_ROOT/changed-target.json" "$CONFIG"
cp "$CONFIG" "$TMP_ROOT/before-changed-replay.json"
FM_HOME="$HOME_DIR" "$REPLY" apply "$VALID_RESULT" > "$TMP_ROOT/changed-replay.out" \
  || fail "a recorded successful request must replay without applying again"
cmp -s "$TMP_ROOT/before-changed-replay.json" "$CONFIG" \
  || fail "a successful replay changed the later stable target"
assert_grep 'Assignment updated: claude / claude-opus-5 / max.' "$TMP_ROOT/changed-replay.out" \
  "a successful replay must return its recorded result rather than a changed assignment"
cp "$TMP_ROOT/before-replay.json" "$CONFIG"

collision_request=$(printf '%s' "$status" | jq -c \
  '{v:1,intent:"dispatch",home:"main",scope:"rule",rule_id:.config.rules[0].id,
    profile_id:.config.rules[0].use[1].id,model:"different-model",effort:"max",request_id:"dispatch-valid-one",
    expected_rule_revision:.revisions.rules[0].revision,
    expected_profile_revision:.revisions.rules[0].profiles[1].revision}') \
  || fail "could not build a request-identity collision"
COLLISION_RESULT="$TMP_ROOT/collision.result"
capture_request "$COLLISION_RESULT" "FM-BOARD-REQUEST $collision_request"
cp "$CONFIG" "$TMP_ROOT/before-collision.json"
if FM_HOME="$HOME_DIR" "$REPLY" apply "$COLLISION_RESULT" > "$TMP_ROOT/collision.out" 2> "$TMP_ROOT/collision.err"; then
  fail "a successful request identity reused for another payload must be rejected"
fi
cmp -s "$TMP_ROOT/before-collision.json" "$CONFIG" \
  || fail "a request-identity collision changed the source"
assert_grep 'request identity was already used' "$TMP_ROOT/collision.err" \
  "a request-identity collision must explain its refusal"
pass "replay requires the prior successful stable target payload"

reorder_status=$($DISPATCH status "$CONFIG") || fail "could not read revisions before rule-reorder coverage"
reorder_request=$(printf '%s' "$reorder_status" | jq -c \
  '{v:1,intent:"dispatch",home:"main",scope:"rule",rule_id:.config.rules[1].id,
    profile_id:.config.rules[1].use.id,model:"claude-haiku-4-6",effort:"low",request_id:"dispatch-reordered-rule",
    expected_rule_revision:.revisions.rules[1].revision,
    expected_profile_revision:.revisions.rules[1].profiles[0].revision}') \
  || fail "could not build a stable rule-reorder request"
REORDER_RESULT="$TMP_ROOT/reorder.result"
capture_request "$REORDER_RESULT" "FM-BOARD-REQUEST $reorder_request"
jq '.rules |= reverse' "$CONFIG" > "$TMP_ROOT/reordered-rules.json" \
  || fail "could not stage reordered rules"
mv "$TMP_ROOT/reordered-rules.json" "$CONFIG"
FM_HOME="$HOME_DIR" "$REPLY" apply "$REORDER_RESULT" > "$TMP_ROOT/reorder.out" \
  || fail "stable identities must survive rule reordering"
[ "$(jq -r '.rules[] | select(.id == "small-docs").use.model' "$CONFIG")" = claude-haiku-4-6 ] \
  || fail "rule reordering redirected the stable-id edit"
jq '.rules |= reverse' "$CONFIG" > "$TMP_ROOT/restored-rules.json" \
  || fail "could not restore rule order"
mv "$TMP_ROOT/restored-rules.json" "$CONFIG"
pass "stable identities target the same rule after reordering"

race_status=$($DISPATCH status "$CONFIG") || fail "could not read revisions before concurrent-edit coverage"
race_request=$(printf '%s' "$race_status" | jq -c \
  '{intent:"dispatch",scope:"rule",rule_id:.config.rules[0].id,
    profile_id:.config.rules[0].use[0].id,model:"gpt-5.7",effort:"high",
    expected_rule_revision:.revisions.rules[0].revision,
    expected_profile_revision:.revisions.rules[0].profiles[0].revision}') \
  || fail "could not build a concurrent-edit request"
RACE_REQUEST="$TMP_ROOT/race-request.json"
printf '%s\n' "$race_request" > "$RACE_REQUEST"
RACE_BIN="$TMP_ROOT/race-bin"
mkdir -p "$RACE_BIN"
REAL_JQ=$(command -v jq)
cat > "$RACE_BIN/jq" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_RACE_MARKER" ]; then
  for arg in "$@"; do
    case "$arg" in
      *.source.*)
        : > "$FM_RACE_MARKER"
        "$FM_REAL_JQ" '.rules |= reverse' "$FM_RACE_CONFIG" > "$FM_RACE_NEXT" || exit 1
        mv "$FM_RACE_NEXT" "$FM_RACE_CONFIG" || exit 1
        break
        ;;
    esac
  done
fi
exec "$FM_REAL_JQ" "$@"
SH
chmod +x "$RACE_BIN/jq"
if PATH="$RACE_BIN:$PATH" FM_REAL_JQ="$REAL_JQ" FM_RACE_CONFIG="$CONFIG" \
    FM_RACE_NEXT="$TMP_ROOT/race-live.json" FM_RACE_MARKER="$TMP_ROOT/race-triggered" \
    "$DISPATCH" apply "$CONFIG" "$RACE_REQUEST" > "$TMP_ROOT/race.out" 2> "$TMP_ROOT/race.err"; then
  fail "a live config change during candidate construction must be rejected"
fi
assert_present "$TMP_ROOT/race-triggered" "the concurrent-edit fixture did not change the live source"
assert_grep 'dispatch config changed while applying' "$TMP_ROOT/race.err" \
  "a concurrent live change must explain its refusal"
[ "$(jq -r '.rules[0].id' "$CONFIG")" = small-docs ] \
  || fail "a refused concurrent edit overwrote the live rule reorder"
[ "$(jq -r '.rules[] | select(.id == "visual-ui").use[0].model' "$CONFIG")" = gpt-5.5 ] \
  || fail "a refused concurrent edit changed the stable target"
jq '.rules |= reverse' "$CONFIG" > "$TMP_ROOT/restored-race-order.json" \
  || fail "could not restore the post-race rule order"
mv "$TMP_ROOT/restored-race-order.json" "$CONFIG"
pass "a concurrent live reorder cannot cross the stable-id apply boundary"

lock_status=$($DISPATCH status "$CONFIG") || fail "could not read revisions before lock coverage"
lock_request=$(printf '%s' "$lock_status" | jq -c \
  '{intent:"dispatch",scope:"rule",rule_id:.config.rules[0].id,
    profile_id:.config.rules[0].use[0].id,model:"gpt-5.8",effort:"high",
    expected_rule_revision:.revisions.rules[0].revision,
    expected_profile_revision:.revisions.rules[0].profiles[0].revision}') \
  || fail "could not build a lock-bound request"
LOCK_REQUEST="$TMP_ROOT/lock-request.json"
printf '%s\n' "$lock_request" > "$LOCK_REQUEST"
LOCK_PATH="$HOME_DIR/config/.fm-inherit-crew-dispatch.json.lock"
LOCK_READY="$TMP_ROOT/dispatch-lock.ready"
LOCK_RELEASE="$TMP_ROOT/dispatch-lock.release"
(
  FM_HOME="$HOME_DIR"
  FM_STATE_OVERRIDE="$HOME_DIR/state"
  export FM_HOME FM_STATE_OVERRIDE
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LOCK_PATH"
  : > "$LOCK_READY"
  while [ ! -e "$LOCK_RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK_PATH"
) &
LOCK_HOLDER=$!
LOCK_POLLS=0
while [ ! -e "$LOCK_READY" ] && [ "$LOCK_POLLS" -lt 100 ]; do
  sleep 0.05
  LOCK_POLLS=$((LOCK_POLLS + 1))
done
[ -e "$LOCK_READY" ] || fail "dispatch lock holder did not become ready"
cp "$CONFIG" "$TMP_ROOT/before-locked-apply.json"
"$DISPATCH" apply "$CONFIG" "$LOCK_REQUEST" > "$TMP_ROOT/lock.out" 2> "$TMP_ROOT/lock.err" &
LOCK_APPLY_PID=$!
sleep 0.2
kill -0 "$LOCK_APPLY_PID" 2>/dev/null || fail "dispatch apply did not wait for the shared lock"
cmp -s "$TMP_ROOT/before-locked-apply.json" "$CONFIG" \
  || fail "dispatch apply changed the config while another writer held its lock"
: > "$LOCK_RELEASE"
wait "$LOCK_HOLDER" || fail "dispatch lock holder failed"
wait "$LOCK_APPLY_PID" || fail "dispatch apply failed after the shared lock was released"
[ "$(jq -r '.rules[0].use[0].model' "$CONFIG")" = gpt-5.8 ] \
  || fail "dispatch apply did not publish after the shared lock was released"
pass "dispatch apply serializes publication through the shared crew-dispatch lock"

stale_status=$($DISPATCH status "$CONFIG") || fail "could not read revisions before stale-edit coverage"
stale_request=$(printf '%s' "$stale_status" | jq -c \
  '{v:1,intent:"dispatch",home:"main",scope:"rule",rule_id:.config.rules[0].id,
    profile_id:.config.rules[0].use[0].id,model:"gpt-5.6",effort:"high",request_id:"dispatch-stale-one",
    expected_rule_revision:.revisions.rules[0].revision,
    expected_profile_revision:.revisions.rules[0].profiles[0].revision}') \
  || fail "could not build a revision-bound stale request"
STALE_RESULT="$TMP_ROOT/stale.result"
capture_request "$STALE_RESULT" "FM-BOARD-REQUEST $stale_request"
jq '.rules[0].use |= reverse' "$CONFIG" > "$TMP_ROOT/reordered.json" \
  || fail "could not stage the reordered profile fixture"
mv "$TMP_ROOT/reordered.json" "$CONFIG"
cp "$CONFIG" "$TMP_ROOT/before-stale.json"
if FM_HOME="$HOME_DIR" "$REPLY" apply "$STALE_RESULT" > "$TMP_ROOT/stale.out" 2> "$TMP_ROOT/stale.err"; then
  fail "a request captured before profile reordering must be rejected"
fi
cmp -s "$TMP_ROOT/before-stale.json" "$CONFIG" \
  || fail "a stale revision-bound request changed the reordered source"
assert_grep 'dispatch rule or profile changed' "$TMP_ROOT/stale.err" \
  "a stale revision refusal must explain that the target changed"
jq '.rules[0].use |= reverse' "$CONFIG" > "$TMP_ROOT/restored-order.json" \
  || fail "could not restore the profile order"
mv "$TMP_ROOT/restored-order.json" "$CONFIG"
pass "rule and profile revisions reject reordered stale targets"

BAD_RESULT="$TMP_ROOT/bad.result"
bad_status=$($DISPATCH status "$CONFIG") || fail "could not read revisions before invalid-edit coverage"
bad_request=$(printf '%s' "$bad_status" | jq -c \
  '{v:1,intent:"dispatch",home:"main",scope:"default",profile_id:.config.default[1].id,
    model:"grok-4.5",effort:"max",request_id:"dispatch-invalid-one",
    expected_rule_revision:.revisions.default.revision,
    expected_profile_revision:.revisions.default.profiles[1].revision}') \
  || fail "could not build a revision-bound invalid request"
capture_request "$BAD_RESULT" "FM-BOARD-REQUEST $bad_request"
cp "$CONFIG" "$TMP_ROOT/before-invalid.json"
if FM_HOME="$HOME_DIR" "$REPLY" apply "$BAD_RESULT" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
  fail "an effort unsupported by the configured harness must be rejected"
fi
cmp -s "$TMP_ROOT/before-invalid.json" "$CONFIG" \
  || fail "a rejected dispatch candidate changed the source file"
assert_grep 'invalid effort: grok:max' "$TMP_ROOT/bad.err" \
  "the shared dispatch validator must explain an invalid effort"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the board must regenerate after a refused edit"
assert_grep 'Assignment rejected' "$CONTROLLED" "a refused edit must surface a clear rejection"
assert_grep 'Crew dispatch unchanged - invalid effort: grok:max' "$CONTROLLED" \
  "a refused edit must say the file was left unchanged"
pass "an invalid board edit fails closed, leaves the file byte-identical, and renders its refusal"

fm_test_cleanup
