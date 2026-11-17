#!/usr/bin/env bash
# Public resolver and receipt gate regressions with a real private stub socket.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
mkdir -p "$TMP_ROOT"
HOME_DIR="$TMP_ROOT/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
SOCKET="$TMP_ROOT/jev.sock"
RESPONSE="$TMP_ROOT/response.json"
LOG="$TMP_ROOT/requests.jsonl"
BRIEF="$HOME_DIR/data/brief.md"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
SERVER=''
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
printf '# Task\n## Captain%s intent\nFix the pager.\n## Firstmate spec\nOne page per call.\n' "'" > "$BRIEF"
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Small fix", "use":{"harness":"claude","model":"sonnet","reasoning_class":1}},{"when":"Hard design", "use":{"harness":"claude","model":"opus","reasoning_class":2}}],"default":{"harness":"claude","model":"sonnet","reasoning_class":1}}
JSON
cat > "$QUOTA" <<'JSON'
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","plan":"Max","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90,"resetsAt":"2030-01-02T00:00:00Z"},{"id":"seven_day","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-04T00:00:00Z"}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["five_hour","seven_day"],"runway":{"status":"through_reset"},"selection":{"spendPriority":1}}]}}]}
JSON
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QUOTA_CALL_LOG"
printf 'claude=%s pi=%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "${PI_CODING_AGENT_DIR:-unset}" >> "$QUOTA_STORE_LOG"
if [ "${1:-}" = --json ] && [ -n "${QUOTA_HANG_READ:-}" ] && [ "$(grep -c '^--json$' "$QUOTA_CALL_LOG")" -ge 2 ]; then
  sleep 20
fi
# An optional JSON map keyed by CLAUDE_CONFIG_DIR lets a test give separate
# accounts separate snapshots; every other read uses $QUOTA_FIXTURE.
if [ -n "${QUOTA_FIXTURE_MAP:-}" ]; then
  mapped=$(printf '%s' "$QUOTA_FIXTURE_MAP" | jq -r --arg c "${CLAUDE_CONFIG_DIR:-}" --arg x "${CODEX_HOME:-}" --arg p "${PI_CODING_AGENT_DIR:-}" '.[$c] // .[$x] // .[$p] // empty' 2>/dev/null) || mapped=''
  if [ -n "$mapped" ] && [ -r "$mapped" ]; then
    cat "$mapped"
    exit 0
  fi
fi
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE="$QUOTA" QUOTA_CALL_LOG="$TMP_ROOT/quota-calls" QUOTA_STORE_LOG="$TMP_ROOT/quota-stores"
# The intake is real even though other suites default to a gate bypass.
unset FM_QUOTA_INTAKE_TEST_BYPASS
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_JEVD_SOCKET="$SOCKET"
export FM_DISPATCH_QUOTA_ATTEMPTS=2 FM_DISPATCH_QUOTA_BACKOFF_MS=250 FM_DISPATCH_QUOTA_WAIT_SECONDS=20 FM_JEVD_SOCKET_WAIT_SECONDS=0
# Sequential resolves would otherwise debit each other through the burst spreader.
export FM_DISPATCH_BURST_WINDOW_SECONDS=0
# Captain words come only from these two records; the tests own both.
export FM_LAVISH_STATE="$TMP_ROOT/lavish-state.json" FM_JEVD_AUDIT_JOURNAL=0 FM_JEVD_AUDIT_LOG="$TMP_ROOT/jevd.log"
MIRROR="$HOME_DIR/state/.host-mirror.jsonl"
write_response() {
  jq -n --slurpfile rules "$RULES" --arg choice "$1" --argjson confidence "$2" --argjson probabilities "$3" --arg preferred "${4:-rule_1_1}" '
    def profiles: if type == "array" then . else [.] end;
    (([$rules[0].rules // [] | to_entries[] | .key as $r | .value.use | profiles | to_entries[] | "rule_\($r + 1)_\(.key + 1)"] +
      [($rules[0].default // [] | profiles) | to_entries[] | "default_\(.key + 1)"])) as $ids |
    {model:"typesafe/jev-1.13",answers:{rule:{choice:$choice,confidence:$confidence,probabilities:$probabilities},
      profile:{choice:$preferred,confidence:1,probabilities:($ids | map({key:.,value:(if . == $preferred then 1 else 0 end)}) | from_entries)}},usage:{input_tokens:10,output_tokens:4}}' > "$RESPONSE"
}
run() { code=0; out=$("$TOOL" "$@" 2>&1) || code=$?; }
latest() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | sort | tail -1; }
# claude3 seats a worker row only as a later tier behind tiered claude1 and
# claude2 seats (claude3_policy.worker_rows: later seat tier only), and a
# firstmate row only entirely before them; every other shape is refused by the
# load checks, whatever the harness, the reserve flag, or the row location.
cp "$RULES" "$TMP_ROOT/reservation-rules"
claude3_row() {  # <shape> <rule|default> <reserve flag>
  jq --arg shape "$1" --arg target "$2" --argjson reserve "$3" '
    def seat($n; $tier): {harness:"claude", model:"opus", account:$n, fallback_only:$reserve, seat_tier:$tier};
    (if $target == "rule" then .rules[0].use else .default end) |=
      (if $shape == "worker" then [seat("claude1";1), seat("claude2";1), seat("claude3";2)]
       elif $shape == "firstmate" then [seat("claude3";1), seat("claude1";2), seat("claude2";2)]
       elif $shape == "notier" then [seat("claude1";1), seat("claude2";1), (seat("claude3";2) | del(.seat_tier))]
       elif $shape == "no12" then [seat("claude3";2)]
       elif $shape == "untiered12" then [(seat("claude1";1) | del(.seat_tier)), seat("claude2";1), seat("claude3";2)]
       else [seat("claude1";1), seat("claude2";2), seat("claude3";2)] end)
  ' "$TMP_ROOT/reservation-rules" > "$RULES"
}
for location in rule default; do
  claude3_row worker "$location" false
  run preview --json
  expect_code 0 "$code" "claude3 seated after claude1/claude2 in $location is accepted: $out"
done
claude3_row firstmate rule false
run preview --json
expect_code 0 "$code" "claude3 seated before the worker seats is accepted: $out"
claude3_row worker rule true
run preview --json
expect_code 0 "$code" "the reserve flag does not change the claude3 seating: $out"
claude3_row notier rule false
run preview --json
expect_code 2 "$code" "claude3 without a tier is refused: $out"
assert_contains "$out" 'claude3 profiles must declare seat_tier' 'untiered claude3 names the policy'
claude3_row no12 default false
run preview --json
expect_code 2 "$code" "claude3 without claude1/claude2 is refused: $out"
assert_contains "$out" 'a row using claude3 must also route the claude1 and claude2 worker seats' 'the missing worker seats are named'
claude3_row untiered12 rule false
run preview --json
expect_code 2 "$code" "untiered claude1 beside claude3 is refused: $out"
assert_contains "$out" 'claude1 and claude2 profiles beside claude3 must also declare seat_tier' 'untiered peers are named'
claude3_row overlap rule false
run preview --json
expect_code 2 "$code" "claude3 beside the worker tiers is refused: $out"
assert_contains "$out" 'claude3 seat tiers must sit entirely after' 'the seating order rule is named'
cp "$TMP_ROOT/reservation-rules" "$RULES"
pass 'preview --json seats claude3 only after the worker seats, or entirely before them'
start_stub() {
  python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
  SERVER=$!
  for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || return 0; sleep 0.02; done
  fail 'stub did not start'
}
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'hand-picked launch refused'
assert_contains "$out" 'no dispatch receipt binds' 'missing receipt named'
for command in choose degraded override; do
  run "$command" "$BRIEF" --harness claude
  expect_code 2 "$code" "$command cannot mint a self-service receipt"
done
pass 'hand-picking and self-service receipt producers refused'
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
start_stub
run "$BRIEF" --project pager --task pager
expect_code 0 "$code" "Jev resolution succeeds: $out"
assert_contains "$out" 'source: jev' 'source visibly Jev'
receipt=$(latest)
assert_equals jev "$(jq -r .source "$receipt")" 'receipt source'
assert_equals stub-dispatch-1 "$(jq -r .jev.requestId "$receipt")" 'request id retained'
intake=$(jq -r .quotaIntakeRecord "$receipt")
assert_present "$HOME_DIR/state/quota-intake/$intake" 'receipt names real quota intake'
assert_equals 600 "$(stat -c %a "$receipt")" 'receipt private'
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'hand-picked model differs from routed receipt'
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet --consume
expect_code 0 "$code" "routed launch admitted: $out"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet --consume
expect_code 3 "$code" 'spent receipt refused'
assert_contains "$out" 'already consumed' 'spent named'
pass 'Jev receipt binds profile, quota intake, request id, one launch'
request=$(head -1 "$LOG")
assert_not_contains "$request" 'reasoning_class' 'Jev does not get eligibility metadata'
assert_not_contains "$request" 'spendPriority' 'Jev does not get quota'
assert_contains "$request" 'dispatch_choices' 'typed socket protocol'
# Stale, changed-table, changed-brief, and disabled legacy sources all refuse.
run "$BRIEF" --task pager
receipt=$(latest)
cp "$receipt" "$TMP_ROOT/receipt-backup"
jq '.issuedAtEpoch -= 901' "$TMP_ROOT/receipt-backup" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'stale receipt refused'
cp "$TMP_ROOT/receipt-backup" "$receipt"
jq '.source="override"' "$TMP_ROOT/receipt-backup" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'legacy override receipt refused'
cp "$TMP_ROOT/receipt-backup" "$receipt"
printf '\nChanged deliverable\n' >> "$BRIEF"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'changed brief refused'
pass 'stale, spent, changed brief and legacy override receipts refused'
# Low confidence unions retain the strongest class of the most probable row.
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union >= 0.25' "ambiguous union routed: $out"
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'less probable hard row cannot inflate the required class'
cp "$RULES" "$TMP_ROOT/rules-backup"
# The probability argmax, not Jev choice or confidence, owns the class anchor.
write_response rule_1 0.4 '{"rule_1":0.35,"rule_2":0.4,"default":0.25}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'most probable hard row keeps its strongest class'
write_response rule_1 0.4 '{"rule_1":0.3,"rule_2":0.25,"default":0.45}'
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'default can anchor the union class'
write_response rule_2 0.4 '{"rule_1":0.4,"rule_2":0.4,"default":0.2}'
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'equal top row probabilities use table order'
# A row may offer several classes; retain its strongest, including union peers.
jq '.rules[0].use = [.rules[0].use, .rules[1].use] | .rules[1].use.reasoning_class = 3' "$TMP_ROOT/rules-backup" > "$RULES"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'anchor uses its strongest class, not the union maximum'
cp "$TMP_ROOT/rules-backup" "$RULES"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
jq 'del(.rules[0].use.reasoning_class)' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union needs numeric reasoning_class' 'missing class on the anchor row stops'
assert_contains "$out" 'status: captain-pick' 'a union with a missing anchor class goes to the captain'
jq 'del(.default.reasoning_class)' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'missing class on a non-anchor union row routes clear'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'requires captain approval' 'approval union stops'
cp "$TMP_ROOT/rules-backup" "$RULES"
# No row reaching 0.25 still fails closed rather than inventing a class anchor.
jq '.rules += [.rules[0], .rules[1]]' "$TMP_ROOT/rules-backup" > "$RULES"
write_response rule_1 0.2 '{"rule_1":0.2,"rule_2":0.2,"rule_3":0.2,"rule_4":0.2,"default":0.2}'
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'empty qualifying union waits for the captain'
assert_contains "$out" 'ambiguous union needs numeric reasoning_class' 'empty union has no class anchor'
cp "$TMP_ROOT/rules-backup" "$RULES"
pass 'ambiguous unions keep most-probable-row strongest class; unknown class and approval stop'
write_response rule_2 0.95 '{"rule_1":0.03,"rule_2":0.95,"default":0.02}'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'captain approval stops for the captain to pick'
assert_contains "$out" 'row rule_2 p=0.95 approval=captain' 'the approval row leads the pick, Jev probability shown'
cp "$TMP_ROOT/rules-backup" "$RULES"
# Unknown quota waits within the configured, shorten-only deadline, never guesses.
cp "$QUOTA" "$TMP_ROOT/quota-backup"
jq '.providers[0].quotaSemantics = {status:"unknown", effectiveAvailability:[]}' "$TMP_ROOT/quota-backup" > "$QUOTA"
# No recent good reading exists, so the R11 reuse cannot answer for it.
rm -rf "$HOME_DIR/state/quota-last-good"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "an unknown quota starts without the captain: $out"
assert_contains "$out" 'eligible, quota unknown: provider claude unmeasured' 'the chosen seat is marked quota unknown'
assert_contains "$out" 'by round-robin within its tier and strongest class, without waiting' 'the note says why this seat'
assert_contains "$out" 'receipt: dispatch-' 'the start gets its receipt'
rm -f "$TMP_ROOT/unknown-calls"
FM_DISPATCH_QUOTA_BACKOFF_MS=30000 FM_DISPATCH_QUOTA_WAIT_SECONDS=45 QUOTA_CALL_LOG="$TMP_ROOT/unknown-calls" run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "still clear with a long budget: $out"
assert_equals 1 "$(grep -c '^--json$' "$TMP_ROOT/unknown-calls")" 'an unknown quota is read once for the choice, never retried'
# Approval still belongs to the captain, whatever the quota says.
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' "approval is not bypassed by an unknown quota: $out"
assert_contains "$out" 'receipt: none' 'an approval row launches nothing'
cp "$TMP_ROOT/rules-backup" "$RULES"
# A read that hangs stops at the deadline, and is then the same unknown.
printf -- '--json\n--json\n' > "$TMP_ROOT/hang-calls"
hang_started=$SECONDS
QUOTA_HANG_READ=1 QUOTA_CALL_LOG="$TMP_ROOT/hang-calls" FM_QUOTA_READ_DEADLINE=1 FM_DISPATCH_QUOTA_WAIT_SECONDS=900 run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "a hung read still starts: $out"
[ "$((SECONDS - hang_started))" -lt 12 ] || fail 'a hung quota read escaped the read deadline'
cp "$TMP_ROOT/quota-backup" "$QUOTA"
pass 'escalate goes to a captain pick; an unknown quota starts by round-robin without waiting, including slow reads'
# Exercise quota ranking and fail-closed policies via the socket interface.
cp "$RULES" "$TMP_ROOT/original-rules"
cp "$QUOTA" "$TMP_ROOT/original-quota"
jq '.rules[0].use=[.rules[0].use,.rules[1].use] | .rules[0].use[0].floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'profile floor excludes below-minimum preferred candidate'
# C5: an exact equal-class tie no longer stops dispatch. Equal binding resets
# fall to a fixed round-robin over a stable order, logged, and the next tie rotates.
jq 'del(.rules[0].use[0].floor) | .rules[0].use[0].reasoning_class = .rules[0].use[1].reasoning_class' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' default_1
rm -f "$HOME_DIR/state/dispatch-tie-round-robin"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "an exact tie still dispatches: $out"
assert_contains "$out" 'tie_break: 2 candidates tied at spendPriority 1; sooner binding reset 2030-01-02T00:00:00Z kept 2; round-robin slot 1 of 2' 'tie break is logged'
first_tie=$(jq -r .profile.model "$(latest)")
assert_equals opus "$first_tie" 'same-quota tie starts in stable model order regardless of Jev preference'
run "$BRIEF" --task pager
assert_contains "$out" 'round-robin slot 2 of 2' 'the next tie takes the next slot'
[ "$first_tie" != "$(jq -r .profile.model "$(latest)")" ] || fail 'round-robin must rotate between tied candidates'
# Same provider, account and quota row remains deterministic with reversed input.
jq '.rules[0].use |= reverse' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_2
run "$BRIEF" --task pager
assert_contains "$out" 'round-robin slot 1 of 2' 'same-quota rotation wraps deterministically'
assert_equals "$first_tie" "$(jq -r .profile.model "$(latest)")" 'input order and Jev preference do not alter same-quota tie order'
jq '.rules[0].use |= reverse' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
# The sooner binding reset wins before any rotation.
jq '.rules[0].use[1].model = "haiku"' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
jq '.providers[0].windows += [{id:"model:haiku",kind:"model",percentRemaining:80,resetsAt:"2030-01-01T06:00:00Z"}] | .providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:haiku",status:"known",effectivePercentRemaining:80,boundedBy:["model:haiku"],runway:{status:"through_reset"},selection:{spendPriority:1}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
run "$BRIEF" --task pager
assert_contains "$out" 'sooner binding reset 2030-01-01T06:00:00Z kept 1' "sooner reset breaks the tie: $out"
assert_equals haiku "$(jq -r .profile.model "$(latest)")" 'the candidate whose binding window resets sooner wins'
cp "$TMP_ROOT/original-quota" "$QUOTA"
jq '.rules[0].use=[.rules[0].use,.rules[1].use]' "$TMP_ROOT/original-rules" > "$RULES"
# A model-specific bound must constrain its candidate, not its neighbor.
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:sonnet",status:"known",effectivePercentRemaining:50,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:-1}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'limiting model-specific spendPriority beats Jev preference'
# All unknown candidates remain in the choice, rather than dropping to a known one.
jq 'del(.providers[0].windows[1].resetsAt)' "$TMP_ROOT/original-quota" > "$QUOTA"
run "$BRIEF" --task pager
assert_contains "$out" 'quota unknown: windows without known percent or reset' 'missing reset evidence is an unknown quota'
cp "$TMP_ROOT/original-quota" "$QUOTA"
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[1].floor={scope:"all_models",provider:"claude",min_percent:10}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union >= 0.25' 'measured ambiguous rule floor can route'
write_response rule_2 0.4 '{"rule_1":0.35,"rule_2":0.4,"default":0.25}'
jq '.rules[1].floor.min_percent=99' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'strongest class below rule floor stops rather than downgrading'
assert_contains "$out" 'not eligible: row floor all_models below 99%' 'the floor reason is on the card'
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[0].min_confidence=0.9 | .rules[1].min_confidence=0.4' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.5,"rule_2":0.49,"default":0.01}'
run "$BRIEF" --task pager
assert_contains "$out" 'fallback: rule_2' 'declared confidence runner-up remains deterministic'
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'runner-up row selected'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'quota floors, ties, model bounds, missing resets and declared confidence fallback'
# Keep-strongest classes rank a single matched rule before the spendPriority
# argmax, so an unused weaker pool cannot outbid the strongest declared class.
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:opus",status:"known",effectivePercentRemaining:70,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:0.5}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
jq '.rules[0].use = [.rules[1].use, .rules[0].use]' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'strongest class beats weaker candidate with higher spendPriority'
assert_contains "$out" 'strongest reasoning class 2' 'class narrowing is disclosed'
# Equal declared classes still compete on spendPriority alone.
jq '.rules[0].use[0].reasoning_class = .rules[0].use[1].reasoning_class' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'equal class falls back to spendPriority'
assert_not_contains "$out" 'outranked' 'no class narrowing at equal class'
# A single missing class keeps plain spendPriority ranking, no silent guessing.
jq 'del(.rules[0].use[0].reasoning_class)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'missing class keeps spendPriority ranking'
# The class filter applies after eligibility, so an ineligible strongest
# candidate never blocks a weaker eligible one.
jq '.rules[0].use = [.rules[1].use, .rules[0].use] | .rules[0].use[0].floor = {scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' 'ineligible strongest does not block weaker eligible'
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'eligible weaker class proceeds'
# The default row gets the same keep-strongest ranking.
jq '{default:[.rules[1].use,.rules[0].use]}' "$TMP_ROOT/original-rules" > "$RULES"
write_response default 1 '{"default":1}' default_1
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'default row keeps strongest class too'
assert_contains "$out" 'no rule matched; strongest reasoning class 2' 'default-row narrowing is disclosed'
cp "$TMP_ROOT/original-quota" "$QUOTA"
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'single-rule and default rows keep the strongest declared reasoning class'
mkdir -p "$TMP_ROOT/claude-seat" "$TMP_ROOT/pi-seat"
printf '%s\n' "$TMP_ROOT/claude-seat" > "$HOME_DIR/config/claude-account"
printf '%s\nopenai-codex\n' "$TMP_ROOT/pi-seat" > "$HOME_DIR/config/pi-account"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' 'captain-owned pins can route'
assert_contains "$(<"$QUOTA_STORE_LOG")" "claude=$TMP_ROOT/claude-seat pi=$TMP_ROOT/pi-seat" 'ranking and intake read the launch pins'
rm "$HOME_DIR/config/claude-account" "$HOME_DIR/config/pi-account"
# Invalid candidate ranks stop before sending text, rather than guessing.
jq '.rules[0].use.reasoning_class="weak"' "$TMP_ROOT/original-rules" > "$RULES"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
expect_code 2 "$code" 'nonnumeric reasoning rank is a configuration error'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'invalid table is never sent'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'quota reads honor captain-owned pins; invalid ranks fail before transport'
# Upstream's additive table declarations ride the same socket route:
# preferred_provider narrows the pool, quota_scope binds a named row, and the
# shared-quota opt-out resolves declared order without quota snapshots.
for value in '"Codex"' 42 '""'; do
  jq --argjson value "$value" '.preferred_provider = $value' "$TMP_ROOT/original-rules" > "$RULES"
  run "$BRIEF" --task pager
  expect_code 2 "$code" "invalid preferred_provider $value is a configuration error"
  assert_contains "$out" 'preferred_provider must be a lowercase provider ID' 'preference error is actionable'
done
jq '.preferred_provider = "claude" | .rules[0].use = [.rules[0].use, .rules[1].use]' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'preferred_provider: claude: prefer eligible family candidates' "matched family is preferred: $out"
jq '.preferred_provider = "codex"' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'preferred_provider: codex: not in matched profiles; preserve the selected rule' 'absent family keeps the rule'
pass 'preferred_provider is validated, applied and explained'
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"tier_a",status:"known",effectivePercentRemaining:40,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:0.1}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
jq '.rules[0].use.quota_scope = "tier_a"' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'scope=tier_a  remaining=40%' "a declared quota_scope binds its row: $out"
cp "$TMP_ROOT/original-rules" "$RULES"
run "$BRIEF" --task pager
assert_not_contains "$out" 'scope=tier_a' 'without quota_scope the tier row stays unbound'
jq '.rules[0].use.quota_scope = "tier_b"' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'declared quota_scope tier_b has no quota row for provider claude: not rankable' 'a missing declared row is disclosed uncertainty'
jq '.rules[0].use.quota_scope = ""' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'an empty quota_scope is a configuration error'
cp "$TMP_ROOT/original-quota" "$QUOTA"
pass 'quota_scope binds, discloses, and validates a named quota row'
jq '.shared_quota = "yes"' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'a non-boolean shared_quota is a configuration error'
jq '.shared_quota = true | .rules[0].use = [.rules[1].use, .rules[0].use] | .rules[0].floor = {scope:"all_models",provider:"claude",min_percent:99}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
json_reads_before=$(grep -c '^--json$' "$QUOTA_CALL_LOG" 2>/dev/null || true)
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "shared quota resolves: $out"
assert_contains "$out" 'eligible (quota ranking off: home declares a single shared quota)' 'every candidate states the opt-out'
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'declared order picks, and the unmet rule floor is bypassed'
assert_equals "$json_reads_before" "$(grep -c '^--json$' "$QUOTA_CALL_LOG" 2>/dev/null || true)" 'shared quota takes no quota-axi --json snapshot'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'shared_quota resolves declared order with no quota snapshot, and rejects non-booleans'
# Fallback-only reserve tier: a supervisor-login Claude reserve seat is picked only
# when every non-fallback Claude seat is at its weekly limit, never over a
# healthy same-family seat or another family's candidate. With a registry
# present every profile names a registered account (S1), so with_accounts
# binds the rows this case does not exercise.
mkdir -p "$TMP_ROOT/claude1-seat" "$TMP_ROOT/claude2-seat" "$TMP_ROOT/claude-reserve-seat" "$TMP_ROOT/codex1-pi"
jq -n --arg c1 "$TMP_ROOT/claude1-seat" --arg c2 "$TMP_ROOT/claude2-seat" --arg g "$TMP_ROOT/claude-reserve-seat" --arg pi "$TMP_ROOT/codex1-pi" \
  '{crossAccount:{enabled:true},accounts:{claude1:{claude:$c1},claude2:{claude:$c2},"claude-reserve":{claude:$g},codex1:{pi:$pi}}}' > "$HOME_DIR/config/accounts.json"
with_accounts() { jq '.rules[1].use.account = "claude1" | .default.account = "claude1"'; }
seat_quota() {  # <weekly-remaining> <spend-priority> <runway> <session-remaining>
  jq -cn --argjson r7 "$1" --argjson sp "$2" --arg runway "$3" --argjson r5 "$4" \
    '{schemaVersion:5,generatedAt:"2030-01-01T00:00:00Z",providers:[{provider:"claude",plan:"Team",state:{status:"fresh"},windows:[{id:"five_hour",kind:"session",percentRemaining:$r5,resetsAt:"2030-01-02T00:00:00Z"},{id:"seven_day",kind:"weekly",percentRemaining:$r7,resetsAt:"2030-01-04T00:00:00Z"}],quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:([$r5,$r7]|min),boundedBy:["five_hour","seven_day"],runway:{status:$runway},selection:{spendPriority:$sp}}]}}]}'
}
seat_quota 80 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
seat_quota 70 5 through_reset 90 > "$TMP_ROOT/claude-reserve-quota.json"
QUOTA_FIXTURE_MAP=$(jq -cn --arg c2 "$TMP_ROOT/claude2-seat" --arg g "$TMP_ROOT/claude-reserve-seat" \
  --arg cf "$TMP_ROOT/claude2-quota.json" --arg gf "$TMP_ROOT/claude-reserve-quota.json" '{($c2):$cf,($g):$gf}')
export QUOTA_FIXTURE_MAP
reserve_rules() {  # rule_1 pool: sonnet on the claude2 seat plus haiku on the claude-reserve seat
  jq '.rules[0].use = [{"harness":"claude","model":"sonnet","account":"claude2","reasoning_class":1},{"harness":"claude","model":"haiku","account":"claude-reserve","reasoning_class":1}]' \
    "$TMP_ROOT/original-rules" | with_accounts > "$RULES"
}
reserve_rules
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_2
run "$BRIEF" --task pager
assert_not_contains "$out" 'fallback_only' 'an unset fallback_only changes nothing'
receipt=$(latest)
assert_equals haiku "$(jq -r .profile.model "$receipt")" 'unset flag keeps the spendPriority argmax'
assert_equals claude-reserve "$(jq -r .profile.account "$receipt")" 'unset flag keeps the declared account'
jq '.rules[0].use[1].fallback_only = true' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "a held reserve still clears: $out"
assert_contains "$out" 'not eligible: fallback_only reserve held: non-fallback claude seats not at their limit (claude:sonnet@claude2)' 'held line states the reserve and why'
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'a healthy non-fallback seat beats the reserve despite its higher spendPriority'
request=$(tail -1 "$LOG")
assert_not_contains "$request" 'fallback_only' 'Jev never sees the reserve flag'
seat_quota 0 1 exhausted_now 0 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_contains "$out" 'eligible, reserve pick: every non-fallback claude seat is at its limit' 'picked line states the reserve and why'
receipt=$(latest)
assert_equals haiku "$(jq -r .profile.model "$receipt")" 'a fully used weekly window releases the reserve'
assert_equals claude-reserve "$(jq -r .profile.account "$receipt")" 'the reserve launches on its declared account'
assert_contains "$(jq -r .rationale "$receipt")" 'reserve pick' 'the receipt rationale states the reserve pick'
seat_quota 5 1 exhausted_now 90 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_equals haiku "$(jq -r .profile.model "$(latest)")" 'an exhausted_now runway releases the reserve'
seat_quota 80 1 through_reset 0 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'an exhausted session window alone never releases the reserve'
assert_contains "$out" 'fallback_only reserve held' 'the held reserve is disclosed while asking the captain'
assert_contains "$out" '--account claude-reserve  class=1  remaining=70%  spendPriority=5  -> not eligible: fallback_only reserve held' 'the pick card marks the held reserve'
seat_quota 80 1 exhausted_now 0 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_contains "$out" 'fallback_only reserve held' "a runway exhausted on the session window alone never releases the reserve: $out"
assert_contains "$out" 'at its five-hour limit, held until 2030-01-02T00:00:00Z' 'the seat held on its session window names the reset'
assert_not_contains "$out" 'at its weekly limit' 'a session limit is never reported as a weekly one'
# Another family's candidate still outranks an activated reserve.
jq '.providers += [{provider:"codex",plan:"Plus",state:{status:"fresh"},windows:[{id:"five_hour",kind:"session",percentRemaining:85,resetsAt:"2030-01-02T00:00:00Z"}],quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:85,boundedBy:["five_hour"],runway:{status:"through_reset"},selection:{spendPriority:1}}]}}]' \
  "$TMP_ROOT/original-quota" > "$QUOTA"
seat_quota 0 1 exhausted_now 0 > "$TMP_ROOT/claude2-quota.json"
jq '.rules[0].use += [{"harness":"pi","model":"openai-codex/gpt-6-luna","provider":"codex","account":"codex1","reasoning_class":1}]' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_1
run "$BRIEF" --task pager
assert_equals pi "$(jq -r .profile.harness "$(latest)")" 'another family candidate still outranks the reserve'
assert_contains "$out" 'eligible, reserve pick: every non-fallback claude seat is at its limit' 'the activated reserve stays disclosed when not chosen'
jq '.shared_quota = true | .rules[0].use = [{"harness":"claude","account":"claude-reserve","fallback_only":true,"reasoning_class":1}]' "$TMP_ROOT/original-rules" | with_accounts > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_1
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' 'a lone reserve under the shared-quota opt-out still resolves'
assert_not_contains "$out" '; ok' 'a reserve pick never leaks a placeholder reason'
assert_equals claude-reserve "$(jq -r .profile.account "$(latest)")" 'the shared-quota reserve launches on its declared account'
jq '.rules[0].use = [{"harness":"claude","model":"sonnet","account":"claude2","reasoning_class":1},{"harness":"claude","model":"haiku","account":"claude-reserve","fallback_only":"yes","reasoning_class":1}]' "$TMP_ROOT/original-rules" | with_accounts > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'a non-boolean fallback_only is a configuration error'
assert_contains "$out" 'fallback_only must be true or false when present' 'the fallback_only error is actionable'
rm "$HOME_DIR/config/accounts.json"
unset QUOTA_FIXTURE_MAP
cp "$TMP_ROOT/original-rules" "$RULES"
cp "$TMP_ROOT/original-quota" "$QUOTA"
pass 'fallback_only holds a claude reserve until every non-fallback claude seat is at its limit'
# Weekly start guard counts live per-account workers, not just recent starts.
mkdir -p "$TMP_ROOT/weekly-bin"
# shellcheck disable=SC2016 # The private fake expands its own arguments.
printf '#!/usr/bin/env bash\n[ "$1" = list-windows ] && printf "@77\\n"\n' > "$TMP_ROOT/weekly-bin/tmux"
chmod +x "$TMP_ROOT/weekly-bin/tmux"
printf 'window=@77\nseat=claude2\nharness=claude\nmodel=opus\neffort=max\n' > "$HOME_DIR/state/weekly-live.meta"
printf 'window=@78\nseat=claude2\nharness=claude\n' > "$HOME_DIR/state/weekly-dead.meta"
printf 'window=@77\nseat=claude-reserve\nharness=claude\n' > "$HOME_DIR/state/weekly-other.meta"
jq '.rules[0].use = [{harness:"claude",model:"sonnet",account:"claude2",reasoning_class:1}] |
  .weekly_guard = {max_used_percent:98,reserve_percent:1,reserve_by_plan:{"claude:Team":1.3}}' "$TMP_ROOT/original-rules" | with_accounts > "$RULES"
# Restore the private registry and account snapshots from the reserve fixtures.
jq -n --arg c1 "$TMP_ROOT/claude1-seat" --arg c2 "$TMP_ROOT/claude2-seat" --arg g "$TMP_ROOT/claude-reserve-seat" \
  '{crossAccount:{enabled:true},accounts:{claude1:{claude:$c1},claude2:{claude:$c2},"claude-reserve":{claude:$g}}}' > "$HOME_DIR/config/accounts.json"
QUOTA_FIXTURE_MAP=$(jq -cn --arg c2 "$TMP_ROOT/claude2-seat" --arg cf "$TMP_ROOT/claude2-quota.json" '{($c2):$cf}')
export QUOTA_FIXTURE_MAP
weekly_run() { PATH="$TMP_ROOT/weekly-bin:$PATH" run "$BRIEF" --task weekly-queued; }
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
seat_quota 2.5 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
receipts_before=$(find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | wc -l)
weekly_run
expect_code 3 "$code" "all weekly-gated returns no launch: $out"
assert_contains "$out" 'not eligible: weekly guard: 97.5% used + 1.3% committed (1 running, 0 parked) + 1.3% new >= 98%' 'weekly guard accounts for the live worker and plan reserve'
assert_contains "$out" 'keep queued and resolve again on the next wake or reset' 'all gated remains queued'
assert_not_contains "$out" '  profile: --harness' 'all gated emits no launch flags'
assert_equals "$receipts_before" "$(find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | wc -l)" 'all gated writes no receipt'
assert_present "$HOME_DIR/state/weekly-live.meta" 'running work untouched'
seat_quota 5 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
weekly_run
expect_code 0 "$code" "below threshold starts: $out"
assert_contains "$out" 'weekly_estimate=95%used+1.3%committed+1.3%new/98%' 'configured plan estimate includes live workers'
# At 96% a new worker fits alone; the existing worker tips it over.
seat_quota 4 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
weekly_run
expect_code 3 "$code" 'running demand tips the seat over the weekly start threshold'
assert_contains "$out" '96% used + 1.3% committed' 'running demand is independent of burst debits'
mv "$HOME_DIR/state/weekly-live.meta" "$TMP_ROOT/weekly-live.meta"
weekly_run
expect_code 0 "$code" "same seat fits without running demand: $out"
assert_equals claude2 "$(jq -r .profile.account "$(latest)")" 'below-threshold seat selected'
# Parked committed demand uses the same fixed plan reserve, even without meta.
mkdir -p "$TMP_ROOT/claude2-seat/projects/weekly"
printf '%s\n' "$TMP_ROOT/claude2-seat" > "$HOME_DIR/config/claude-shaped-store"
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{type:"system",sessionId:"weekly-parked",timestamp:$ts,content:"Usage limit reached; continuing automatically"}' > "$TMP_ROOT/claude2-seat/projects/weekly/session.jsonl"
weekly_run
expect_code 3 "$code" "parked committed demand holds a new start: $out"
assert_contains "$out" '(0 running, 1 parked)' 'the existing committed-demand census contributes a worker reserve'
rm "$HOME_DIR/config/claude-shaped-store"
# Exact boundary and configurable ceiling, with no running work.
seat_quota 3.3 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
weekly_run
expect_code 3 "$code" 'reaching exactly 98% is gated'
jq '.providers[0] |= (.windows[1].id = "weekly" | del(.windows[1].kind) | .quotaSemantics.effectiveAvailability[0].boundedBy = ["five_hour","weekly"] | .quotaSemantics.effectiveAvailability[0].selection.spendPriority = null)' "$TMP_ROOT/claude2-quota.json" > "$TMP_ROOT/weekly-alias"
mv "$TMP_ROOT/weekly-alias" "$TMP_ROOT/claude2-quota.json"
weekly_run
expect_code 3 "$code" 'weekly window id is guarded even with no rankable scalar'
assert_contains "$out" 'not eligible: weekly guard:' 'weekly guard does not need spendPriority to establish ineligibility'
seat_quota 4 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
jq '.weekly_guard.max_used_percent = 97' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 3 "$code" 'configured weekly ceiling is enforced'
jq 'del(.weekly_guard.max_used_percent)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 0 "$code" 'the absent ceiling defaults to 98%'
jq '.weekly_guard.reserve_percent = -1' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 2 "$code" 'invalid weekly reserve is a config error'
jq '.weekly_guard.reserve_percent = 1' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
# A seat whose weekly window resets within the reset horizon with enough left waives the committed-demand term.
# Nine running workers at a 2.6% reserve commit 23.4%; the used and new-worker terms still count.
for n in 1 2 3 4 5 6 7 8 9; do printf 'window=@77\nseat=claude2\nharness=claude\n' > "$HOME_DIR/state/weekly-burst-$n.meta"; done
jq '.weekly_guard.reserve_by_plan["claude:Team"] = 2.6 | .ranking = {reset_horizon_hours:12,reset_horizon_min_percent:10}' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
# Pin the clock to the fixture time 2030-01-01T00:00:00Z so reset distances are exact.
export FM_DISPATCH_NOW_EPOCH=1893456000
weekly_reset_quota() {  # <weekly-remaining> <weekly resetsAt, or empty for none>
  seat_quota "$1" 1 through_reset 90 | jq --arg t "$2" '.providers[0].windows[1] |= (if $t == "" then del(.resetsAt) else .resetsAt = $t end)' > "$TMP_ROOT/claude2-quota.json"
}
weekly_reset_quota 25 2030-01-01T08:00:00Z
weekly_run
expect_code 0 "$code" "a seat resetting in 8h with 25% left starts despite 9 committed workers: $out"
assert_equals claude2 "$(jq -r .profile.account "$(latest)")" 'the draining seat is the one selected'
assert_contains "$out" 'weekly_estimate=75%used+0%committed(waived)+2.6%new/98%' 'the waived estimate names the dropped committed term'
weekly_reset_quota 25 2030-01-01T20:00:00Z
weekly_run
expect_code 3 "$code" 'the same seat resetting in 20h is still refused'
assert_contains "$out" 'weekly guard: 75% used + 23.4% committed (9 running, 0 parked) + 2.6% new >= 98%' 'outside the horizon the committed estimate still counts'
assert_not_contains "$out" 'waived' 'outside the horizon nothing is waived'
weekly_reset_quota 8 2030-01-01T08:00:00Z
weekly_run
expect_code 3 "$code" 'a seat with under 10% left is still refused inside the horizon'
assert_contains "$out" '92% used + 23.4% committed (9 running, 0 parked) + 2.6% new >= 98%' 'under the minimum left the committed estimate still counts'
assert_not_contains "$out" 'waived' 'under the minimum left nothing is waived'
weekly_reset_quota 25 ''
weekly_run
expect_code 0 "$code" "a seat with no weekly reset time is unchanged, still the unknown-quota start: $out"
assert_contains "$out" 'quota unknown: windows without known percent or reset: seven_day' 'a window with no reset time is still unknown evidence the guard never reads'
assert_not_contains "$out" 'waived' 'no reset time never waives the committed estimate'
weekly_reset_quota 10 2030-01-01T12:00:00Z
weekly_run
expect_code 0 "$code" "exactly the minimum left, resetting exactly at the horizon, is waived: $out"
jq '.weekly_guard.max_used_percent = 77' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_reset_quota 25 2030-01-01T08:00:00Z
weekly_run
expect_code 3 "$code" 'a waived seat is still held to used plus the new worker against the limit'
assert_contains "$out" 'weekly guard: 75% used + 0% committed (9 running, 0 parked; committed estimate waived: weekly window resets within 12h with at least 10% left' 'the refusal of a waived seat says the estimate was waived and why'
assert_present "$HOME_DIR/state/weekly-burst-1.meta" 'the waiver never stops or moves running work'
# The per-worker committed percent follows the seat's plan size: the 2.6% reserve is the claude1 figure, scaled by claude1 plan_value / seat plan_value.
jq 'del(.weekly_guard.max_used_percent) | .plan_value = {claude1:200,claude2:200}' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_reset_quota 25 2030-01-04T00:00:00Z
weekly_run
assert_contains "$out" '75% used + 23.4% committed (9 running, 0 parked) + 2.6% new >= 98%' 'a seat the size of the reference keeps the 2.6% per-worker figure'
assert_not_contains "$out" 'per-worker' 'an unscaled seat carries no scaling note'
jq '.plan_value.claude2 = 100' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 3 "$code" 'a half-size plan counts each worker as double the share'
assert_contains "$out" '75% used + 46.8% committed (9 running, 0 parked) + 5.2% new (per-worker 5.2% = 2.6% x plan_value 200 / 100) >= 98%' 'the smaller plan commits 5.2% per worker and says why'
jq '.plan_value.claude2 = 125' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
assert_contains "$out" '75% used + 37.44% committed (9 running, 0 parked) + 4.16% new (per-worker 4.16% = 2.6% x plan_value 200 / 125)' 'a plan of 125 commits 4.16% per worker'
jq '.plan_value.claude2 = 400' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 0 "$code" "a double-size plan counts each worker as half the share and fits: $out"
assert_contains "$out" 'weekly_estimate=75%used+11.7%committed+1.3%new/98%' 'the larger plan commits 1.3% per worker'
jq 'del(.plan_value.claude2)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 3 "$code" 'a seat missing from plan_value keeps the flat figure'
assert_contains "$out" '75% used + 23.4% committed (9 running, 0 parked) + 2.6% new >= 98%' 'a missing plan_value falls back to the flat 2.6%'
jq '.plan_value = {claude2:100}' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
assert_contains "$out" '75% used + 23.4% committed (9 running, 0 parked) + 2.6% new >= 98%' 'a missing reference plan_value falls back to the flat 2.6%'
jq 'del(.plan_value)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
rm -f "$HOME_DIR"/state/weekly-burst-*.meta
# Committed demand is only spend the weekly reading does not show yet.
# A fleet of 55 live endpoints whose work is finished, parked or waiting commits nothing, at the default reserve.
jq 'del(.weekly_guard) | del(.ranking)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_fleet() {  # <count> <status line, or empty for none> <spawn epoch, or empty for none> <name>
  local n
  for n in $(seq 1 "$1"); do
    printf 'window=@77\nseat=claude2\nharness=claude\nkind=ship\n%s' "${3:+spawn_gen=s$3.1.1$'\n'}" > "$HOME_DIR/state/weekly-fleet-$4-$n.meta"
    [ -z "$2" ] || printf '%s\n' "$2" > "$HOME_DIR/state/weekly-fleet-$4-$n.status"
  done
}
weekly_fleet 30 'done [at=1893450000]: PR https://example.invalid/pr/1' 1893440000 finished
weekly_fleet 10 'paused [at=1893450000]: waiting on the pipeline run' 1893440000 paused
weekly_fleet 6 'needs-decision [key=pick] [at=1893450000]: A or B' 1893440000 decision
weekly_fleet 5 'blocked [at=1893450000]: no access' 1893440000 blocked
weekly_fleet 4 'captain-held [at=1893450000]: waiting for the captain' 1893440000 held
weekly_reset_quota 87 2030-01-04T00:00:00Z
weekly_run
expect_code 0 "$code" "55 live endpoints with no working worker admit a start at 13% used: $out"
assert_equals claude2 "$(jq -r .profile.account "$(latest)")" 'the low-use seat with 55 idle endpoints is selected'
assert_contains "$out" 'weekly_estimate=13%used+0%committed+1%new/98%' 'idle endpoints commit nothing and the default reserve is 1 point'
# The same fleet near real exhaustion is still refused, and the refusal names the endpoints it left out.
weekly_reset_quota 3 2030-01-04T00:00:00Z
weekly_run
expect_code 3 "$code" "55 idle endpoints at 97% used still refuse a start: $out"
assert_contains "$out" 'weekly guard: 97% used + 0% committed (0 running, 55 idle not counted, 0 parked) + 1% new >= 98%' 'the refusal near exhaustion names the idle endpoints'
# Working workers count, each fading with its age: started now 1, 3h ago 0.5, 30h ago the 0.2 floor, no known start 1.
weekly_fleet 1 'working [at=1893455000]: implementing' 1893456000 fresh
weekly_fleet 1 'working [at=1893455000]: implementing' 1893445200 mid
weekly_fleet 1 'working [at=1893455000]: implementing' 1893348000 old
weekly_fleet 1 '' '' new
weekly_reset_quota 5 2030-01-04T00:00:00Z
weekly_run
expect_code 3 "$code" "working workers tip a seat at 95% used over the limit: $out"
assert_contains "$out" 'weekly guard: 95% used + 2.7% committed (4 running, 55 idle not counted, 0 parked) + 1% new >= 98%' 'working workers commit their faded shares'
weekly_reset_quota 8 2030-01-04T00:00:00Z
weekly_run
expect_code 0 "$code" "the same working workers fit at 92% used: $out"
assert_contains "$out" 'weekly_estimate=92%used+2.7%committed+1%new/98%' 'the estimate shows the faded committed demand'
# A resolved decision returns its worker to the count, and decay_hours sets the fade.
printf 'resolved [key=pick] [at=1893455900]: go with A\n' >> "$HOME_DIR/state/weekly-fleet-decision-1.status"
jq '.weekly_guard = {decay_hours:12}' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
assert_contains "$out" 'weekly_estimate=92%used+3.58%committed+1%new/98%' 'a resolved worker counts again and decay_hours 12 fades the 3h and 4.4h workers to 0.75 and 0.63'
jq '.weekly_guard.decay_hours = 0' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
weekly_run
expect_code 2 "$code" 'a decay_hours of zero is a config error'
rm -f "$HOME_DIR"/state/weekly-fleet-*
jq '.weekly_guard = {max_used_percent:98,reserve_percent:1,reserve_by_plan:{"claude:Team":2.6}}' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
unset FM_DISPATCH_NOW_EPOCH
# Launches under the pinned clock left burst debits stamped 2030; drop them so later pinned-clock tests start clean.
rm -f "$HOME_DIR/state/dispatch-burst-ledger"
jq 'del(.weekly_guard.max_used_percent) | .weekly_guard.reserve_by_plan["claude:Team"] = 1.3 | del(.ranking)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
seat_quota 4 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
# Missing weekly evidence follows the existing first-gate behavior unchanged.
jq '.providers[0].windows[1].percentRemaining = null' "$TMP_ROOT/claude2-quota.json" > "$TMP_ROOT/weekly-unreadable"
mv "$TMP_ROOT/weekly-unreadable" "$TMP_ROOT/claude2-quota.json"
rm -rf "$HOME_DIR/state/quota-last-good"
weekly_run
assert_contains "$out" 'quota unknown' "unreadable weekly retains existing unknown behavior: $out"
assert_not_contains "$out" 'not eligible: weekly guard' 'no weekly guard from partial evidence'
rm "$HOME_DIR/state/weekly-dead.meta" "$HOME_DIR/state/weekly-other.meta" "$HOME_DIR/config/accounts.json"
unset QUOTA_FIXTURE_MAP
cp "$TMP_ROOT/original-rules" "$RULES"
cp "$TMP_ROOT/original-quota" "$QUOTA"
pass 'weekly guard is start-only, counts only working account demand faded by age, waives the committed estimate only inside the reset horizon, and preserves unknown behavior'
# Default-only tables still receive a valid Jev Choice, without degrading.
jq '{default:.default}' "$TMP_ROOT/original-rules" > "$RULES"
write_response default 1 '{"default":1}' default_1
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' "default-only table can route: $out"
cp "$TMP_ROOT/original-rules" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
# The first bad answer gets one retry, and a second valid answer is Jev-sourced.
jq '{_stubResponses:[{},.]}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' 'one retry can recover'
assert_equals 2 "$(( $(wc -l < "$LOG") - requests_before ))" 'exactly one retry after invalid Choice'
# Mutating the brief in-flight must not authorize its new words.
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
jq --arg path "$BRIEF" --arg text "$(<"$BRIEF") new deliverable" '. + {_stubMutate:{path:$path,text:$text}}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
run "$BRIEF" --task pager
expect_code 3 "$code" 'brief changed while Jev answered is refused'
assert_contains "$out" 'brief changed during resolution' 'brief race names binding mismatch'
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
jq --arg path "$RULES" --arg text "$(jq '.rules[0].when="Changed fit"' "$RULES")" '. + {_stubMutate:{path:$path,text:$text}}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
run "$BRIEF" --task pager
expect_code 3 "$code" 'table changed while Jev answered is refused'
assert_contains "$out" 'table changed during resolution' 'table race names binding mismatch'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'default-only tables, one-retry recovery and in-flight input binding'
# Unusable permissions and invalid replies never become a guessed route:
# nothing is receipted and the captain picks from every row.
pick_code() { sed -n 's/^  pick: \([A-HJ-NP-Z2-9]\{4\}\) .*/\1/p' <<<"$out"; }
captain_mirror() {  # <text> [tag]
  jq -cn --arg text "$1" --arg tag "${2:-captain}" --argjson epoch "$(date +%s)" --argjson seq "$((++MIRROR_SEQ))" \
    '{seq:$seq,epoch:$epoch,key:"main-1",id:"p\($seq)",tag:$tag,text:$text}' >> "$MIRROR"
}
captain_lavish() {  # <text> [role] [epoch]
  local at
  at=$(date -u -d "@${3:-$(date +%s)}" +%Y-%m-%dT%H:%M:%S.123Z)
  [ -f "$FM_LAVISH_STATE" ] || printf '{"sessions":{"s1":{"chat":[]}}}\n' > "$FM_LAVISH_STATE"
  jq --arg text "$1" --arg role "${2:-user}" --arg at "$at" '.sessions.s1.chat += [{at:$at,role:$role,text:$text}]' "$FM_LAVISH_STATE" > "$FM_LAVISH_STATE.next"
  mv "$FM_LAVISH_STATE.next" "$FM_LAVISH_STATE"
}
MIRROR_SEQ=0
printf '{}\n' > "$RESPONSE"
requests_before=$(wc -l < "$LOG")
before=$(latest)
run "$BRIEF" --project pager --task pager
assert_contains "$out" 'status: captain-pick' "two invalid answers go to the captain: $out"
assert_contains "$out" 'receipt: none - nothing launches until the captain picks' 'no receipt, no guessed route'
assert_not_contains "$out" 'source: degraded' 'nothing is degraded'
assert_equals "$before" "$(latest)" 'invalid answers write no receipt'
assert_equals 2 "$(( $(wc -l < "$LOG") - requests_before ))" 'invalid answers get exactly two attempts'
chmod 666 "$SOCKET"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'unsafe socket mode goes to the captain'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'unsafe socket never receives task text'
chmod 600 "$SOCKET"
run degraded-recent
expect_code 2 "$code" 'the degraded listing is retired'
pass 'invalid replies and unsafe socket modes fail closed into a captain pick'
# A restarting jevd gets a bounded wait for its socket before any attempt.
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
( sleep 1; exec python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" ) &
SERVER=$!
FM_JEVD_SOCKET_WAIT_SECONDS=8 run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' "a socket that returns within the wait routes through Jev: $out"
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
pass 'a restarting jevd gets a bounded socket wait'
# Jev down: every row is offered, with evidence, and nothing launches.
before=$(latest)
run "$BRIEF" --project pager --task pager
assert_contains "$out" 'status: captain-pick' "Jev down goes to the captain: $out"
assert_contains "$out" 'jev: down - jevd socket' 'the reason names the absent socket'
assert_equals "$before" "$(latest)" 'Jev down writes no receipt'
code_a=$(pick_code)
req="$HOME_DIR/state/dispatch-pick/$code_a.json"
assert_present "$req" 'pick request written'
assert_equals 600 "$(stat -c %a "$req")" 'pick request private'
assert_equals 3 "$(jq '.options | length' "$req")" 'every row and candidate offered'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.options[].row.id] | join(" ")' "$req")" 'table order without Jev'
assert_equals null "$(jq -c .jev "$req")" 'no Jev answer recorded when Jev is down'
assert_contains "$out" 'option 2: --harness claude --model opus  class=2' 'options carry class'
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'nothing launches before the captain picks'
pass 'Jev down offers every row with evidence and writes no receipt'
# The pick needs the captain's own words, newer than the request.
run pick "$code_a"
expect_code 3 "$code" 'no words, no receipt'
assert_contains "$out" "no captain words answer route $code_a" 'missing answer named'
captain_lavish "route $code_a 2" user "$(( $(jq -r .issuedAtEpoch "$req") - 30 ))"
captain_lavish "route $code_a 2" agent
captain_mirror "route $code_a 2" main
run pick "$code_a"
expect_code 3 "$code" 'older captain text and firstmate text never count'
captain_mirror "please route ${code_a,,} 2"
before=$(latest)
run pick "$code_a"
expect_code 0 "$code" "captain chat answer admits the option: $out"
assert_contains "$out" 'source: captain' 'captain source shown'
assert_contains "$out" 'profile: --harness claude --model opus' 'the picked profile is printed'
receipt=$(latest)
[ "$receipt" != "$before" ] || fail 'pick wrote no receipt'
assert_equals captain "$(jq -r .source "$receipt")" 'receipt source'
assert_equals "$code_a 2 mirror false" "$(jq -r '"\(.captainPick.code) \(.captainPick.option) \(.captainPick.channel) \(.captainPick.override)"' "$receipt")" 'pick binding recorded'
assert_equals rule_2 "$(jq -r .row.id "$receipt")" 'row recorded'
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'a different profile than the captain picked is refused'
cp "$receipt" "$TMP_ROOT/captain-receipt"
jq '.captainPick.option = 1' "$TMP_ROOT/captain-receipt" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'a receipt that no longer matches its answered option is refused'
cp "$TMP_ROOT/captain-receipt" "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus --consume
expect_code 0 "$code" "captain receipt admits its launch: $out"
assert_contains "$out" "captain pick $code_a option 2" 'gate names the pick'
run pick "$code_a"
expect_code 3 "$code" 'a pick is answered once'
assert_contains "$out" 'already answered' 'second answer refused'
pass 'captain words in chat become a receipt bound to the pick and its option'
# An option that is not eligible needs the word override, and says so.
jq '.rules[1].use.floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
code_b=$(pick_code)
assert_contains "$out" 'option 2: --harness claude --model opus' 'ineligible option still offered'
assert_contains "$out" 'not eligible: profile floor all_models below 90%' 'ineligibility reason shown'
assert_contains "$out" 'Pi, Codex, Grok and OpenCode: Lavish only' 'pick instructions name the verifiable channel on non-Claude primaries'
# Pi has no disk mirror: the Lavish-only path must work without that file.
mv "$MIRROR" "$MIRROR.saved"
run pick "$code_b"
expect_code 3 "$code" 'without captured words no primary can self-attest a pick'
assert_contains "$out" 'Pi, Codex, Grok and OpenCode require Lavish' 'missing-evidence refusal gives the supported channel'
captain_lavish "route $code_b 2"
run pick "$code_b"
expect_code 3 "$code" 'not eligible without override is refused'
assert_contains "$out" "route $code_b 2 override" 'the refusal names the override words'
captain_lavish "Ok then: route $code_b 2 override"
run pick "$code_b"
expect_code 0 "$code" "override answer on the card admits the option: $out"
assert_equals "lavish true" "$(jq -r '"\(.captainPick.channel) \(.captainPick.override)"' "$(latest)")" 'override recorded without a host mirror'
mv "$MIRROR.saved" "$MIRROR"
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 0 "$code" 'override receipt admits its launch'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'not-eligible options need the captain override words and record them'
# The captain can ask to choose even when Jev routes cleanly.
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
SERVER=$!
for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || break; sleep 0.02; done
before=$(latest)
run "$BRIEF" --task pager --captain-pick
assert_contains "$out" 'status: captain-pick' "captain-requested pick: $out"
assert_contains "$out" 'jev: captain-requested - the captain asked to choose this route; Jev and code would take claude sonnet from rule_1' 'the routed answer is shown beside the pick'
assert_equals "$before" "$(latest)" 'a captain-requested pick writes no Jev receipt'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.options[].row.id] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | join(" ")' "$HOME_DIR/state/dispatch-pick/$(pick_code).json")" 'rows in Jev probability order'
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
pass 'the captain can ask to choose a route Jev would have taken'
# Ambiguous answers, reused evidence, changed briefs, and wait.
run "$BRIEF" --task pager
code_c=$(pick_code)
captain_mirror "route $code_c 1, or maybe route $code_c 3"
run pick "$code_c"
expect_code 3 "$code" 'two answers in one entry are refused'
assert_contains "$out" 'more than one answer' 'ambiguity named'
captain_mirror "route $code_c 1"
rm -rf "$HOME_DIR/state/dispatch-pick/used.keep"; cp -r "$HOME_DIR/state/dispatch-pick/used" "$HOME_DIR/state/dispatch-pick/used.keep"
printf '%s' "mirror:main-1:$MIRROR_SEQ" | sha256sum | awk '{print $1}' | xargs -I{} touch "$HOME_DIR/state/dispatch-pick/used/{}"
run pick "$code_c"
expect_code 3 "$code" 'evidence that admitted another pick is refused'
assert_contains "$out" 'already admitted another pick' 'single use named'
printf '\nAnother deliverable\n' >> "$BRIEF"
run pick "$code_c"
expect_code 3 "$code" 'a brief changed since the card is refused'
assert_contains "$out" 'changed since pick' 'brief change named'
run "$BRIEF" --task pager
code_d=$(pick_code)
captain_mirror "route $code_d wait"
before=$(latest)
run pick "$code_d"
expect_code 3 "$code" 'wait issues nothing'
assert_contains "$out" 'status: wait' 'wait recorded'
assert_equals "$before" "$(latest)" 'wait wrote no receipt'
pass 'ambiguous, reused, stale-brief and wait answers issue nothing'
# The card is self-contained and dark; picks lists pending and answered.
run "$BRIEF" --task pager
code_e=$(pick_code)
run pick-card
expect_code 0 "$code" "card renders: $out"
card="$HOME_DIR/data/dispatch-pick/route-pick.html"
assert_present "$card" 'card written'
assert_contains "$(<"$card")" "data-prompt=\"route $code_e 1\"" 'each option queues its exact words'
assert_contains "$(<"$card")" 'color-scheme:dark' 'card is dark'
assert_contains "$(<"$card")" 'data-lavish-annotate="off"' 'card is a decision page, not an annotation surface'
assert_not_contains "$(<"$card")" 'http' 'card makes no external request'
assert_not_contains "$(<"$card")" "route $code_a" 'answered picks are not on the card'
run picks --recent
assert_contains "$out" "route pick $code_e PENDING" 'pending pick listed'
assert_contains "$out" "route pick $code_a task=pager answered" 'answered pick listed'
assert_contains "$out" 'wait for Jev' 'wait answer listed'
pass 'the card offers exact answers; pending and answered picks are listed'
# Legacy degraded receipts are refused at the gate.
cp "$TMP_ROOT/captain-receipt" "$receipt"
rm -f "$receipt.spent"
jq '.source = "degraded" | .degraded = {reason: "legacy"}' "$TMP_ROOT/captain-receipt" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'a legacy degraded receipt is refused'
rm -f "$receipt"
# The audit matches Jev receipts to jevd's own log and captain receipts to their words.
rm -f "$FM_JEVD_AUDIT_LOG"
run audit --problems
assert_contains "$out" 'unverifiable: no jevd log readable' 'no log is reported as unverifiable, not as clean'
printf 'jevd: listening (mode 0600)\n' > "$FM_JEVD_AUDIT_LOG"
run audit --problems
assert_contains "$out" 'NOT IN JEVD LOG' 'a Jev receipt jevd never logged is flagged'
for f in "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json; do
  jq -r 'select(.source == "jev") | "jevd: dispatch \(.jev.requestId): rule=\(.jev.ruleChoice) profile=x in=1"' "$f" >> "$FM_JEVD_AUDIT_LOG"
done
run audit --problems
assert_equals '' "$out" "every logged Jev receipt and every captain receipt audits clean: $out"
jev_receipt=$(grep -l '"source":"jev"' "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json | tail -1)
jq '.jev.requestId = "forged-1"' "$jev_receipt" > "$jev_receipt.next"; mv "$jev_receipt.next" "$jev_receipt"
captain_receipt=$(grep -l '"source":"captain"' "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json | head -1)
jq '.captainPick.wordsSha256 = ("0" * 64)' "$captain_receipt" > "$captain_receipt.next"; mv "$captain_receipt.next" "$captain_receipt"
run audit
assert_contains "$out" 'request id forged-1 has no jevd dispatch line' 'forged request id flagged'
assert_contains "$out" 'CAPTAIN WORDS: captain words differ' 'forged captain words flagged'
assert_contains "$out" '2 finding(s)' 'finding count'
pass 'audit reconciles Jev receipts with jevd log and captain receipts with their words'
# The criteria export carries every row's text, gates and classes.
run rows --json
expect_code 0 "$code" 'criteria export runs'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.rows[].id] | join(" ")' <<<"$out")" 'every row exported'
assert_equals '1 2 1' "$(jq -r '[.rows[].candidates[].reasoning_class] | join(" ")' <<<"$out")" 'classes exported'
assert_equals 0 "$(jq -r .unclassed <<<"$out")" 'no unclassed candidates'
assert_equals 64 "$(jq -r '.table.sha256 | length' <<<"$out")" 'table hash exported'
pass 'rows --json exports the routing criteria'
# rows runs the same load checks as preview: a bad table is refused before any
# export, so a dump never launders an unshippable table.
cp "$RULES" "$TMP_ROOT/rows-rules"
for bad in '.bogus_key = 1' '.rules[0].bogus_key = 1' '.rules[0].use = [{harness:"claude",model:"opus",account:"claude3",seat_tier:2}]'; do
  jq "$bad" "$TMP_ROOT/rows-rules" > "$RULES"
  run rows --json
  expect_code 2 "$code" "rows refuses an unsafe table ($bad): $out"
done
jq '.bogus_key = 1' "$TMP_ROOT/rows-rules" > "$RULES"
run rows --json
assert_contains "$out" 'unknown top-level key "bogus_key"; known keys:' 'rows names the unknown top-level key'
jq '.rules[0].bogus_key = 1' "$TMP_ROOT/rows-rules" > "$RULES"
run rows --json
assert_contains "$out" 'unknown rule key: rule 1 key "bogus_key"; known keys:' 'rows names the unknown rule key'
jq '.rules[0].use = [{harness:"claude",model:"opus",account:"claude3",seat_tier:2}]' "$TMP_ROOT/rows-rules" > "$RULES"
run rows --json
assert_contains "$out" 'claude3 policy: rule 1:' 'rows refuses a bad claude3 shape'
cp "$TMP_ROOT/rows-rules" "$RULES"
pass 'rows refuses tables the load checks reject, naming the unknown key'
# Preview covers every worker row and default without a socket request, even
# when the only evidence is a read-only last-good snapshot of the home store.
before_requests=$(wc -l < "$LOG")
cp -R "$HOME_DIR/state" "$TMP_ROOT/preview-state"
run preview --json
expect_code 0 "$code" "home-store preview succeeds: $out"
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.workers[].id] | join(" ")' <<< "$out")" 'preview covers every work row and default'
assert_equals 'sonnet opus sonnet' "$(jq -r '[.workers[].pick.model] | join(" ")' <<< "$out")" 'preview evaluates each fixed row, not one guessed row'
assert_equals "$before_requests" "$(wc -l < "$LOG")" 'worker preview never contacts Jev'
diff -r "$TMP_ROOT/preview-state" "$HOME_DIR/state" >/dev/null || fail 'home-store preview changed shared state'
cp "$QUOTA" "$TMP_ROOT/preview-quota"
printf 'invalid quota\n' > "$QUOTA"
run preview --json
expect_code 0 "$code" "preview with failed quota read succeeds: $out"
assert_equals true "$(jq '[.workers[].measured] | all(. == false)' <<< "$out")" 'cached preview evidence is explicitly unmeasured'
diff -r "$TMP_ROOT/preview-state" "$HOME_DIR/state" >/dev/null || fail 'fallback preview changed shared state'
cp "$TMP_ROOT/preview-quota" "$QUOTA"
pass 'preview covers rules and default and reads last-good evidence without any state write'
# Reverse declaration order across providers: neither it nor a preview may
# change the stable rotation, and default rows use the same unknown fallback.
jq '.providers |= map(.state={status:"rate_limited"} | .windows=[] | .quotaSemantics={status:"unknown",effectiveAvailability:[]})' "$QUOTA" > "$TMP_ROOT/neutral-quota"
cp "$TMP_ROOT/neutral-quota" "$QUOTA"
rm -rf "$HOME_DIR/state/quota-last-good"
# Real starts must see this fixture, not a still-fresh single-flight attempt.
export FM_QUOTA_SHARED_READ_TTL=0
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Any work","use":[{"harness":"codex","model":"gpt-5.4","reasoning_class":2},{"harness":"claude","model":"sonnet","reasoning_class":2},{"harness":"claude","model":"haiku","reasoning_class":1}]}],"default":[{"harness":"codex","model":"gpt-5.4","reasoning_class":2},{"harness":"claude","model":"sonnet","reasoning_class":2}]}
JSON
for slot in 0 1; do
  printf '%s\n' "$slot" > "$HOME_DIR/state/dispatch-tie-round-robin"
  cp -R "$HOME_DIR/state" "$TMP_ROOT/neutral-state-$slot"
  run preview --json
  expect_code 0 "$code" "all-unknown preview succeeds: $out"
  expected=claude; [ "$slot" = 0 ] || expected=codex
  assert_equals "$expected $expected" "$(jq -r '[.workers[].pick.harness] | join(" ")' <<< "$out")" 'round-robin chooses across providers, not array order, in rule and default'
  assert_equals true "$(jq '[.workers[] | .quota_unknown and .tie_round_robin] | all' <<< "$out")" 'unknown rotation is logged'
  assert_contains "$(jq -r '.workers[0].tie_break' <<< "$out")" "round-robin slot $((slot + 1)) of 2" 'slot is disclosed'
  diff -r "$TMP_ROOT/neutral-state-$slot" "$HOME_DIR/state" >/dev/null || fail 'unknown preview changed state'
  jq '.rules[0].use |= reverse | .default |= reverse' "$RULES" > "$TMP_ROOT/reversed-rules"
  mv "$TMP_ROOT/reversed-rules" "$RULES"
  run preview --json
  assert_equals "$expected $expected" "$(jq -r '[.workers[].pick.harness] | join(" ")' <<< "$out")" 'reversing arrays does not change the rotation'
done
printf '0\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
# Earlier transport-failure cases stopped the stub. Preview does not need it,
# but this must be a real routed start, not a successful captain-pick response.
start_stub
run "$BRIEF" --task neutral
expect_code 0 "$code" "unknown worker starts: $out"
assert_contains "$out" 'status: clear' 'unknown worker actually starts instead of parking a captain pick'
assert_contains "$out" 'receipt: dispatch-' 'unknown worker writes a launch receipt'
assert_equals 1 "$(< "$HOME_DIR/state/dispatch-tie-round-robin")" 'a real unknown worker start advances rotation'
assert_contains "$out" 'tie_break: quota unknown; round-robin slot 1 of 2' 'real unknown start logs the slot'
pass 'preview --json proves all-unknown worker and default rotation is provider-neutral, order-independent and read-only; real starts advance'
# Phase-1 ranking and the independent fixed-step router, using only fixture
# snapshots and private account stores. No live config or credentials are read.
export FM_DISPATCH_NOW_EPOCH=1893456000 FM_DISPATCH_QUOTA_ATTEMPTS=1
unset QUOTA_FIXTURE_MAP
rm -rf "$HOME_DIR/state/quota-last-good"
cp "$TMP_ROOT/preview-quota" "$QUOTA"
jq -n --arg root "$TMP_ROOT" '{crossAccount:{enabled:true},accounts:{claude1:{claude:($root+"/claude1-seat")},claude2:{claude:($root+"/claude2-seat")},codex1:{codex:($root+"/codex1-seat"),pi:($root+"/codex1-pi")},codex2:{codex:($root+"/codex2-seat"),pi:($root+"/codex2-pi")},glm:{pi:($root+"/glm-seat")}}}' > "$HOME_DIR/config/accounts.json"
for seat in codex1-seat codex2-seat codex2-pi glm-seat; do mkdir -p "$TMP_ROOT/$seat"; done
rank_quota() { # file provider remaining time-percent score reset
  jq --arg p "$2" --argjson left "$3" --argjson time "$4" --argjson score "$5" --arg reset "$6" '
    .providers[0] |= (.provider=$p | .windows[1] |= (.percentRemaining=$left | .resetsAt=$reset | .pace={timeRemainingPercent:$time, reservePercentPoints:($left-$time)}) |
      .quotaSemantics.effectiveAvailability[0] |= (.effectivePercentRemaining=$left | .selection.spendPriority=$score))' "$QUOTA" > "$1"
}
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
rank_quota "$TMP_ROOT/rank-x1" codex 90 10 20 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-x2" codex 80 10 30 2030-01-05T00:00:00Z
rank_quota "$TMP_ROOT/rank-g" zai 90 10 40 2030-01-04T00:00:00Z
QUOTA_FIXTURE_MAP=$(jq -cn --arg r "$TMP_ROOT" '{($r+"/claude1-seat"):($r+"/rank-c1"),($r+"/claude2-seat"):($r+"/rank-c2"),($r+"/codex1-seat"):($r+"/rank-x1"),($r+"/codex1-pi"):($r+"/rank-x1"),($r+"/codex2-seat"):($r+"/rank-x2"),($r+"/codex2-pi"):($r+"/rank-x2"),($r+"/glm-seat"):($r+"/rank-g")}')
export QUOTA_FIXTURE_MAP
# A tiny reserve_percent keeps these ranking cases out of the weekly guard, which would otherwise scale the reserve of the small claude2 plan.
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Any work","use":[{"harness":"claude","model":"opus","effort":"high","account":"claude1","reasoning_class":5},{"harness":"claude","model":"opus","effort":"high","account":"claude2","reasoning_class":5}]}],"plan_value":{"claude1":200,"claude2":25},"weekly_guard":{"reserve_percent":0.01}}
JSON
run preview --json
expect_code 0 "$code" "default ranking preview: $out"
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'default keeps spendPriority'
# Heavy rows opt in explicitly; light and existing rows keep their ranking.
cp "$RULES" "$TMP_ROOT/pre-pace-rules"
rank_quota "$TMP_ROOT/rank-c1" claude 80 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 20 50 9 2030-01-05T00:00:00Z
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'unconfigured light row ignores 1.6x burn'
jq '.rules[0].seat_pacing=true' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
run preview --json
expect_code 0 "$code" "paced preview: $out"
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'equal-class seat replaces 1.6x seat'
assert_equals true "$(jq '.workers[0].candidates[] | select(.profile.account=="claude2") | .pacing_skipped' <<< "$out")" 'preview discloses paced seat'
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task pace-start
expect_code 0 "$code" "paced real start: $out"
assert_contains "$out" "--account 'claude1'" 'real dispatch uses equal-class replacement'
assert_contains "$out" 'weekly pace 1.6x exceeds 1.5x' 'real dispatch explains skip'
# Strictly above the threshold, not equal to it.
rank_quota "$TMP_ROOT/rank-c2" claude 25 50 9 2030-01-05T00:00:00Z
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'exactly 1.5x remains available'
rank_quota "$TMP_ROOT/rank-c2" claude 20 50 9 2030-01-05T00:00:00Z
cp "$RULES" "$TMP_ROOT/pace-rules"
for mutation in '.rules[0].use[0].reasoning_class=4' '.rules[0].use[0].seat_tier=2 | .rules[0].use[1].seat_tier=1' '.rules[0].use[0].floor={scope:"all_models",min_percent:90}' '.rules[0].use[0] |= del(.reasoning_class)'; do
  jq "$mutation" "$TMP_ROOT/pace-rules" > "$RULES"
  run preview --json
  expect_code 0 "$code" "paced row with unavailable replacement: $out"
  assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'pacing never opens later tiers, lowers class or uses an ineligible replacement'
done
cp "$TMP_ROOT/pace-rules" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 10 50 1 2030-01-04T00:00:00Z
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'all seats fast does not empty the row'
rank_quota "$TMP_ROOT/rank-c1" claude 80 50 1 2030-01-04T00:00:00Z
jq 'del(.providers[0].windows[1].pace)' "$TMP_ROOT/rank-c1" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-c1"
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'unknown replacement pace cannot authorize skipping'
# Model-scoped weekly pace can be the binding burn, independently of score.
rank_quota "$TMP_ROOT/rank-c1" claude 80 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 50 9 2030-01-05T00:00:00Z
jq '.providers[0] |= (.windows += [{id:"opus_week",kind:"weekly",percentRemaining:80,resetsAt:"2030-01-04T00:00:00Z",pace:{burnMultiple:2}}] | .quotaSemantics.effectiveAvailability[0].boundedBy += ["opus_week"])' "$TMP_ROOT/rank-c2" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-c2"
run preview --json
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'model weekly burnMultiple also protects capacity'
jq '.rules[0].seat_pacing="yes"' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
run preview --json
expect_code 2 "$code" 'invalid seat pacing flag refused'
cp "$TMP_ROOT/pre-pace-rules" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
pass 'heavy-row pacing preserves class, tier, eligibility, threshold and unknown-pace compatibility'
jq '.ranking={mode:"surplus_value",reset_horizon_hours:12,reset_horizon_min_percent:10}' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
run preview --json
expect_code 0 "$code" "surplus ranking preview: $out"
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" '10 surplus points at price 200 beats 56 at price 25'
assert_equals '10 20 false' "$(jq -r '.workers[0].chosen | [.surplus,.value,.band] | map(tostring) | join(" ")' <<< "$out")" 'surplus, value and band are disclosed'
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-01T10:00:00Z
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'dump band beats higher value'
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-01T08:00:00Z
run preview --json
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'earliest reset wins within band'
rank_quota "$TMP_ROOT/rank-c1" claude 60 70 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'negative surplus loses'
# A low five-hour headroom changes neither weekly surplus nor value. It remains
# a start gate, not a scoring window.
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
jq '.providers[0].windows[0].percentRemaining=25' "$TMP_ROOT/rank-c1" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-c1"
run preview --json
assert_equals 20 "$(jq '.workers[0].chosen.value' <<< "$out")" 'five-hour window never enters value'
# Consecutive real starts use the same fading 2-point debit as legacy mode.
cp "$RULES" "$TMP_ROOT/pre-burst-rules"
jq '.plan_value.claude2=200' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
rank_quota "$TMP_ROOT/rank-c2" claude 59 50 9 2030-01-05T00:00:00Z
export FM_DISPATCH_BURST_WINDOW_SECONDS=1800
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task rank-first
expect_code 0 "$code" "first surplus start: $out"
assert_contains "$out" 'status: clear' "first start is routed: $out"
assert_contains "$out" "--account 'claude1'" "first start takes higher surplus: $out"
run "$BRIEF" --task rank-second
expect_code 0 "$code" "second surplus start: $out"
assert_contains "$out" "--account 'claude2'" "second start moves after burst debit: $out"
assert_contains "$out" 'surplus=8 value=16 band=no' 'debit subtracts weekly points before price multiplication'
export FM_DISPATCH_BURST_WINDOW_SECONDS=0
cp "$TMP_ROOT/pre-burst-rules" "$RULES"
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
# Model-scoped weekly bounds also limit the value.
jq '.providers[0] |= (.windows += [{id:"opus_week",kind:"weekly",percentRemaining:30,resetsAt:"2030-01-04T00:00:00Z",pace:{timeRemainingPercent:29}}] | .quotaSemantics.effectiveAvailability[0].boundedBy += ["opus_week"])' "$TMP_ROOT/rank-c1" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-c1"
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'model weekly minimum limits value'
# Non-full quota-axi --json carries only pace.{status,reservePercentPoints,burnMultiple},
# where reservePercentPoints = percentRemaining - timeRemainingPercent (positive is
# under-spent). The under-spent account must win, and the full-JSON branch must agree.
cp "$RULES" "$TMP_ROOT/pre-reserve-rules"
jq '.plan_value={claude1:200,claude2:200}' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 80 42.32 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 72 91.73 9 2030-01-05T00:00:00Z
run preview --json
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" "full pace JSON: under-spent claude1 wins"
full_surplus=$(jq -c '.workers[0].chosen | [.surplus,.value]' <<< "$out")
for f in rank-c1 rank-c2; do
  jq '.providers[0].windows[1].pace |= {status:(if .reservePercentPoints >= 0 then "behind" else "ahead" end), reservePercentPoints:.reservePercentPoints, burnMultiple:1}' "$TMP_ROOT/$f" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/$f"
  assert_equals null "$(jq -c '.providers[0].windows[1].pace.timeRemainingPercent' "$TMP_ROOT/$f")" "$f fixture drops timeRemainingPercent like non-full quota-axi"
done
run preview --json
expect_code 0 "$code" "non-full pace preview: $out"
assert_equals claude1 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'non-full pace JSON: under-spent claude1 beats over-spent claude2'
assert_equals "$full_surplus" "$(jq -c '.workers[0].chosen | [.surplus,.value]' <<< "$out")" 'fallback surplus and value equal the full-JSON branch'
assert_equals '37.68 75.36' "$(jq -r '.workers[0].chosen | [.surplus,.value] | map(. * 100 | round / 100 | tostring) | join(" ")' <<< "$out")" 'under-spent seat carries positive surplus'
# Swap the roles: with claude1 over-spent and claude2 under-spent, claude2 wins.
nonfull() { jq '.providers[0].windows[1].pace |= {status:(if .reservePercentPoints >= 0 then "behind" else "ahead" end), reservePercentPoints:.reservePercentPoints, burnMultiple:1}' "$1" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$1"; }
rank_quota "$TMP_ROOT/rank-c1" claude 72 91.73 1 2030-01-04T00:00:00Z; nonfull "$TMP_ROOT/rank-c1"
rank_quota "$TMP_ROOT/rank-c2" claude 80 42.32 9 2030-01-05T00:00:00Z; nonfull "$TMP_ROOT/rank-c2"
run preview --json
assert_equals claude2 "$(jq -r '.workers[0].pick.seat' <<< "$out")" 'non-full pace JSON: under-spent claude2 beats over-spent claude1'
assert_equals true "$(jq '.workers[0].chosen.surplus > 0' <<< "$out")" 'winning under-spent seat has positive surplus'
cp "$TMP_ROOT/pre-reserve-rules" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
pass 'surplus_value ranks the under-spent account first from non-full quota-axi pace and agrees with the full-JSON branch'
# reset_first: among same-provider seats the sooner weekly reset goes first; guards,
# equal resets and cross-provider order keep their existing behavior. No pace forecast.
jq '.ranking={mode:"reset_first"}' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
rf_pick() { run preview --json; expect_code 0 "$code" "reset_first preview: $out"; RF_SEAT=$(jq -r '.workers[0].pick.seat' <<< "$out"); }
# claude1 resets sooner but spendPriority prefers claude2 (default mode picks claude2).
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
rf_pick; assert_equals claude1 "$RF_SEAT" 'reset_first: claude1 resets first, so it wins over the higher spendPriority claude2'
assert_contains "$out" 'reset_first' 'reset_first is named in the rationale'
assert_equals '"2030-01-04T00:00:00Z"' "$(jq -c '.workers[0].chosen.binding_reset' <<< "$out")" 'preview exposes the weekly binding_reset'
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task rf-text
expect_code 0 "$code" "reset_first start: $out"
assert_contains "$out" "--account 'claude1'" "reset_first start takes the sooner reset: $out"
assert_contains "$out" 'reset_first binding_reset=2030-01-04T00:00:00Z' 'candidate line shows binding_reset'
assert_contains "$out" 'reset_first: ' 'start note carries the reset_first rationale'
# Monday-style flip: the seat resetting later in the week now resets first.
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 9 2030-01-08T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 1 2030-01-05T00:00:00Z
rf_pick; assert_equals claude2 "$RF_SEAT" 'reset_first: claude2 resets first after the data flip'
# A sooner seat held out by the weekly guard hands over to the other seat.
rank_quota "$TMP_ROOT/rank-c1" claude 1 50 9 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 1 2030-01-05T00:00:00Z
rf_pick; assert_equals claude2 "$RF_SEAT" 'reset_first: the sooner seat at the 98 percent weekly guard drops out'
# Equal resets leave the decision to spendPriority.
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-04T00:00:00Z
rf_pick; assert_equals claude2 "$RF_SEAT" 'reset_first: equal resets fall back to spendPriority'
# The reset ignores a sooner five-hour reset: only the weekly window counts.
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 9 2030-01-08T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 1 2030-01-05T00:00:00Z
jq '.providers[0].windows[0].resetsAt="2030-01-01T02:00:00Z"' "$TMP_ROOT/rank-c1" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-c1"
rf_pick; assert_equals claude2 "$RF_SEAT" 'reset_first: a five-hour reset never counts as the binding reset'
# Cross-provider comparisons keep spendPriority: codex1 resets later but ranks higher.
jq '.rules[0].use += [{"harness":"codex","model":"gpt-5.4","effort":"high","account":"codex1","reasoning_class":5}]' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 2 2030-01-05T00:00:00Z
rank_quota "$TMP_ROOT/rank-x1" codex 90 10 20 2030-01-09T00:00:00Z
rf_pick; assert_equals codex1 "$RF_SEAT" 'reset_first: cross-provider order stays spendPriority'
cp "$TMP_ROOT/pre-reserve-rules" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
rank_quota "$TMP_ROOT/rank-c2" claude 80 24 9 2030-01-05T00:00:00Z
rank_quota "$TMP_ROOT/rank-x1" codex 90 10 20 2030-01-04T00:00:00Z
pass 'reset_first ranks the sooner weekly reset first within a provider and keeps guards, ties and cross-provider order'
# Invalid config and hard policy checks fail before quota/transport.
cp "$RULES" "$TMP_ROOT/rank-rules"
for bad in 'del(.plan_value.claude1)' '.ranking.mode="bogus"' '.ranking.reset_horizon_hours=-1' '.rules[0].use[0].effort="max"' '.rules[0].use[0] |= (.model="sonnet" | .effort="max")' '.rules[0].use[0] |= (.model="fable" | .effort="xhigh")' '.rules[0].use[0] |= (.model="fable" | .effort="max")' '.rules[0].use[0] |= (.harness="pi" | .provider="anthropic" | .model="anthropic/claude-opus")'; do
  jq "$bad" "$TMP_ROOT/rank-rules" > "$RULES"
  run preview --json
  expect_code 2 "$code" "unsafe routing config refused: $bad: $out"
done
cp "$TMP_ROOT/rank-rules" "$RULES"
pass 'surplus-value ranking preserves the default, dump order, weekly bounds, and hard policy checks'
# Load the proposed-config fixture, then prove all eight steps in each tier.
cp "$ROOT/tests/fixtures/routing-phase1-crew-dispatch.json" "$RULES"
rank_quota "$TMP_ROOT/rank-c1" claude 60 50 1 2030-01-04T00:00:00Z
# An unreadable Claude tier must not open GLM for Lavish or a pipeline step.
cp "$TMP_ROOT/rank-c1" "$TMP_ROOT/rank-c1-known"
cp "$TMP_ROOT/rank-c2" "$TMP_ROOT/rank-c2-known"
for seat in c1 c2; do
  jq '.providers[0] |= (.windows=[] | .quotaSemantics={status:"unknown",effectiveAvailability:[]})' "$TMP_ROOT/rank-$seat" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$TMP_ROOT/rank-$seat"
done
run preview --json
expect_code 0 "$code" "unreadable Claude preview: $out"
assert_equals claude "$(jq -r '.workers[] | select(.id=="rule_12") | .pick.harness' <<< "$out")" 'Lavish stays on Claude when its quota is unreadable'
assert_equals true "$(jq '[.noMistakes[] | .tier==1 and .measured==false] | all' <<< "$out")" 'unreadable quota holds pipeline Claude tier'
cp "$TMP_ROOT/rank-c1-known" "$TMP_ROOT/rank-c1"
cp "$TMP_ROOT/rank-c2-known" "$TMP_ROOT/rank-c2"
# A blended row owns its bans: rule_11 bans zai, so the GLM candidate the
# anchor rule_14 offers is out even though rule_14 itself declares no ban:
# the anchor owns the candidates, every blended row owns its bans.
jq 'del(.rules[13].never_providers) | (.rules[3].use[] | select(.provider=="zai")) as $glm | .rules[13].use += [$glm + {reasoning_class:5}]' "$RULES" > "$TMP_ROOT/next"; mv "$TMP_ROOT/next" "$RULES"
write_response rule_14 0.55 "$(jq -c '[(.rules | to_entries[] | {key:("rule_"+((.key+1)|tostring)),value:0})] | from_entries | . + {rule_14:0.55,rule_11:0.4,default:0.05}' "$RULES")"
run "$BRIEF" --task security-union
expect_code 0 "$code" "security union: $out"
assert_contains "$out" 'provider zai is banned for this work (never_providers)' 'security ban survives an ambiguous union'
cp "$ROOT/tests/fixtures/routing-phase1-crew-dispatch.json" "$RULES"
for tier in 1 2 3; do
  if [ "$tier" = 2 ]; then
    rank_quota "$TMP_ROOT/rank-c1" claude 0 50 1 2030-01-04T00:00:00Z
    rank_quota "$TMP_ROOT/rank-c2" claude 0 24 9 2030-01-05T00:00:00Z
  elif [ "$tier" = 3 ]; then
    rank_quota "$TMP_ROOT/rank-x1" codex 0 10 20 2030-01-04T00:00:00Z
    rank_quota "$TMP_ROOT/rank-x2" codex 0 10 30 2030-01-05T00:00:00Z
  fi
  run preview --json
  expect_code 0 "$code" "proposed config loads at tier $tier: $out"
  jq -e . >/dev/null <<< "$out" || fail "proposed preview is not clean JSON: $out"
  assert_equals 8 "$(jq '.noMistakes | length' <<< "$out")" 'all steps are routed'
  assert_equals true "$(jq --argjson tier "$tier" '[.noMistakes[] | .tier == $tier] | all' <<< "$out")" "pool order cannot be outbid by surplus, tier $tier: $(jq -c '[.noMistakes[] | {step,tier,reason}]' <<< "$out")"
  expected='opus:medium opus:medium sonnet:high sonnet:high sonnet:high opus:low sonnet:high sonnet:high'
  [ "$tier" != 2 ] || expected='gpt-6.1-sol:high gpt-6.1-sol:high gpt-6.1-sol:medium gpt-6.1-sol:medium gpt-6.1-sol:medium gpt-6.1-sol:low gpt-6.1-sol:xhigh gpt-6.1-sol:xhigh'
  [ "$tier" != 3 ] || expected='zai/glm-5.3:max zai/glm-5.3:max zai/glm-5.3:max zai/glm-5.3:max zai/glm-5.3:max zai/glm-5.3:low zai/glm-5.3:max zai/glm-5.3:max'
  assert_equals "$expected" "$(jq -r '[.noMistakes[] | .model+":"+.effort] | join(" ")' <<< "$out")" 'every step has its specified model and effort'
done
run rows --json
assert_equals surplus_value "$(jq -r '.ranking.mode' <<< "$out")" 'rows exports configured ranking'
assert_equals 25 "$(jq '.plan_value.codex2' <<< "$out")" 'rows exports plan prices'
pass 'proposed config loads and routes all eight no-mistakes steps through Claude, Codex, then GLM'
# The escalation ladder (lane 3): a relaunch after a recorded capability failure
# resolves on the next rung, and the receipt gate admits that rung's profile.
cp "$RULES" "$TMP_ROOT/rules-before-ladder"
# The ladder profiles name no account, so this home carries no account registry.
if [ -e "$HOME_DIR/config/accounts.json" ]; then mv "$HOME_DIR/config/accounts.json" "$TMP_ROOT/accounts-before-ladder"; fi
cat > "$RULES" <<'JSON'
{"ladder_rungs":[
  {"rung":1,"name":"Small","claude":[{"harness":"claude","model":"sonnet","effort":"low"}]},
  {"rung":2,"name":"Solid","claude":[{"harness":"claude","model":"opus","effort":"medium"}]},
  {"rung":3,"name":"Hard","claude":[{"harness":"claude","model":"opus","effort":"high"}]}],
 "capability":{"claude/sonnet:low":{"index":30,"terminal_bench":30,"gdpval":1100},
  "claude/opus:medium":{"index":48.2,"terminal_bench":52.5,"gdpval":1593},
  "claude/opus:high":{"index":51.8,"terminal_bench":56.6,"gdpval":1714}},
 "rules":[{"when":"Small fix","ladder":{"start":1,"ceiling":3},"use":{"harness":"claude","model":"sonnet","effort":"low","reasoning_class":1}},
  {"when":"Hard design","use":{"harness":"claude","model":"opus","reasoning_class":2}}],
 "default":{"harness":"claude","model":"sonnet","reasoning_class":1}}
JSON
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --project pager --task ladder-gate
expect_code 0 "$code" "a task without history resolves from the rule: $out"
assert_not_contains "$out" 'escalation ladder' 'no capability failure, no ladder'
FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-task-history.sh" append ladder-gate relaunch --reason capability --attempt a1 \
  --profile '{"harness":"claude","model":"sonnet","effort":"low"}' >/dev/null
run "$BRIEF" --project pager --task ladder-gate
expect_code 0 "$code" "the relaunch resolves on rung 2: $out"
assert_contains "$out" 'escalation ladder: 1 capability failure(s), rung 2 (Solid)' 'the note names the rung'
receipt=$(latest)
assert_equals opus "$(jq -r .profile.model "$receipt")" 'the receipt carries the rung-2 model'
assert_equals medium "$(jq -r .profile.effort "$receipt")" 'the receipt carries the rung-2 effort'
run gate --brief "$BRIEF" --task ladder-gate --harness claude --model sonnet --effort low --consume
expect_code 3 "$code" 'the rule profile no longer matches the ladder receipt'
run gate --brief "$BRIEF" --task ladder-gate --harness claude --model haiku --effort low --consume
expect_code 3 "$code" 'a profile outside the rule and its ladder is refused'
run gate --brief "$BRIEF" --task ladder-gate --harness claude --model opus --effort medium --consume
expect_code 0 "$code" "the ladder profile is a member of its row, so the gate admits it: $out"
pass 'the escalation ladder resolves the next rung after a capability failure and the gate admits that rung profile'
# Jev gets a bounded, sanitised task history and the rule question tells it never
# to pick a stronger rule because the task failed before (lane 3b).
: > "$LOG"
run "$BRIEF" --project pager --task fresh-history
expect_code 0 "$code" "a task without history resolves: $out"
request=$(tail -1 "$LOG")
jev_request() { tail -1 "$LOG" | jq -c '.request // .'; }
history_field=$(jev_request | jq -c '.state.task.history // "absent"')
assert_equals '"absent"' "$history_field" 'a task without history sends no history field'
FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-task-history.sh" append ladder-gate relaunch --reason capability --attempt a2 \
  --profile '{"harness":"claude","model":"opus","effort":"medium","account":"claude2"}' >/dev/null
for n in 1 2 3 4 5 6 7 8; do
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-task-history.sh" append ladder-gate relaunch --reason capability --attempt "b$n" \
    --profile "{\"harness\":\"claude\",\"model\":\"model-$n-/home/daan/secret/path/$(printf 'x%.0s' $(seq 1 120))\",\"effort\":\"low\"}" >/dev/null
done
run "$BRIEF" --project pager --task ladder-gate
expect_code 0 "$code" "a long history still resolves: $out"
request=$(jev_request)
history=$(jq -c '.state.task.history' <<<"$request")
[ "${#history}" -le 1200 ] || fail "history is ${#history} characters, over the 1200 bound"
assert_equals 10 "$(jq '.capability_failures' <<<"$history")" 'the history carries the capability failure count'
[ "$(jq '.failed_profiles | length' <<<"$history")" -le 6 ] || fail 'failed_profiles is not capped'
[ "$(jq '.last_outcomes | length' <<<"$history")" -le 3 ] || fail 'last_outcomes is not capped'
assert_not_contains "$history" '/home/daan' 'no path reaches Jev'
assert_not_contains "$history" '/' 'no path separator reaches Jev'
assert_contains "$history" 'model-1-_home_daan_secret_path_' 'a path-like profile string is reduced to an identifier'
assert_not_contains "$history" 'claude2' 'no account reaches Jev'
assert_not_contains "$history" 'receipt' 'no receipt reaches Jev'
assert_not_contains "$history" 'attempt' 'no attempt id key reaches Jev'
assert_equals "$history" "$(jev_request | jq -c '.state.task.history')" 'the same history is sent deterministically' 
assert_contains "$request" 'Never choose a stronger rule because the task failed before; the router climbs the matched rule' 'the rule question carries the no-escalation sentence'
assert_contains "$(jq -r '.questions.rule.instructions' <<<"$request")" "the router climbs the matched rule's ladder by itself." 'the sentence is in the rule instructions'
# A never-send entry matching a history string stops the request before it is sent.
printf '%s\n' 'model-2-' > "$HOME_DIR/config/dispatch-never-send"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --project pager --task ladder-gate
assert_contains "$out" 'dispatch-resolve: off' 'never-send holds for history text'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'nothing is sent when the history matches never-send'
rm -f "$HOME_DIR/config/dispatch-never-send"
pass 'Jev receives a bounded, sanitised task history and the no-escalation rule sentence'
cp "$TMP_ROOT/rules-before-ladder" "$RULES"
if [ -e "$TMP_ROOT/accounts-before-ladder" ]; then mv "$TMP_ROOT/accounts-before-ladder" "$HOME_DIR/config/accounts.json"; fi
echo '# all fm-dispatch-resolve tests passed'
