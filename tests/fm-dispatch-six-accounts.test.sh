#!/usr/bin/env bash
# Six-account routing guards (rr-synthesis plan, fork PRs A and B):
#   S1  every profile names a registered account once config/accounts.json exists
#   C2  a fallback_only reserve waits until every other seat of its provider is at limit,
#       and its own unknown quota never stalls the choice while it is held
#   S9  with cross-account routing off nothing falls onto the supervisor login
#   S3  a rule's never_providers bans a provider, also inside an ambiguous union
#   C3  an unreadable five-hour window never makes a choice incomplete
#   F5  a known five-hour limit holds a seat until its reset; idle, unreadable, or reset-less never blocks
#   G   worker five-hour guard by working day, and the burst spreader
#   R11 a rate-limited read reuses that store's last good reading under 30 min
#   S4  a credential failure is named as such, never as unknown quota
#   T   seat_tier strict order, per-delivery tiers, and their reserve and class rules
#   U   an unreadable candidate is skipped while another is readable; with none readable a round-robin seat starts quota unknown
#   P   pipeline mode: fixed row per step, pools, per-tier reasoning class, weekly floor, live five-hour window
#   S10 lane 1 resolver: claude3 worker seating and weekly floor, never_models bans
#       inside blended unions, the optional fable_projects allowlist, and their load refusals
#   S12 worker_banned_accounts: claude3 never seats a worker, scout, default or pipeline step; a secondmate charter keeps it
#   S11 lane 3 resolver: the escalation ladder from per-task capability history, Fable limits,
#       bans, lenses, default_ladder, fail-closed history, and the ladder load refusals
#   A   provider-aware, symlink-canonical seat lookup and the one-shot migration
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-six-accounts)
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
ACCOUNTS="$HOME_DIR/config/accounts.json"
STORES="$TMP_ROOT/stores"
QDIR="$TMP_ROOT/quota"
SERVER=''
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
mkdir -p "$STORES"/claude1 "$STORES"/claude2 "$STORES"/claude-reserve "$STORES"/claude3 "$STORES"/codex1 "$STORES"/codex2 "$STORES"/pi "$STORES"/pi2 "$QDIR"
printf '# Task\n## Captain%s intent\nFix the pager.\n## Firstmate spec\nOne page per call.\n' "'" > "$BRIEF"

# The fake quota-axi answers per store: the Claude store's name, else the Codex
# store's, else "pi" for the shared Pi agent directory.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -z "${QUOTA_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$QUOTA_CALL_LOG"
key=default
case "${CLAUDE_CONFIG_DIR:-}" in /nonexistent/*|'') ;; *) key=$(basename "$CLAUDE_CONFIG_DIR") ;; esac
if [ "$key" = default ]; then
  case "${CODEX_HOME:-}" in /nonexistent/*|'') ;; *) key=$(basename "$CODEX_HOME") ;; esac
fi
if [ "$key" = default ]; then
  case "${PI_CODING_AGENT_DIR:-}" in /nonexistent/*|'') ;; *) key=pi ;; esac
fi
[ -f "$QUOTA_DIR/$key.json" ] || key=empty
cat "$QUOTA_DIR/$key.json"
SH
chmod +x "$FAKEBIN/quota-axi"
printf '{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[]}\n' > "$QDIR/empty.json"

# snap <provider> <pct-remaining> <spendPriority> [runway] [weekly-reset]
snap() {
  local runway=${4:-through_reset} reset=${5:-2030-01-04T00:00:00Z}
  jq -n --arg p "$1" --argjson pct "$2" --argjson sp "$3" --arg runway "$runway" --arg reset "$reset" '
    {schemaVersion:5, generatedAt:"2030-01-01T00:00:00Z", providers:[{provider:$p, plan:"plan", state:{status:"fresh"},
      windows:[{id:"five_hour",kind:"session",percentRemaining:90,resetsAt:"2030-01-02T00:00:00Z"},
               {id:"seven_day",kind:"weekly",percentRemaining:$pct,resetsAt:$reset}],
      quotaSemantics:{status:"known", effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:$pct,
        boundedBy:["five_hour","seven_day"],runway:{status:$runway},selection:{spendPriority:$sp}}]}}]}'
}
set_quota() { snap "$2" "$3" "$4" "${5:-through_reset}" "${6:-2030-01-04T00:00:00Z}" > "$QDIR/$1.json"; }
reset_quota() {
  set_quota claude1 claude 70 1
  set_quota claude2 claude 60 2
  set_quota claude-reserve claude 95 9
  set_quota claude3 claude 90 4
  set_quota codex1 codex 50 1
  set_quota codex2 codex 50 3
  set_quota pi zai 90 5
  rm -rf "$HOME_DIR/state/quota-last-good"
}
reset_quota

cat > "$ACCOUNTS" <<JSON
{"crossAccount":{"enabled":true},"accounts":{
 "claude1":{"provider":"claude","claude":"$STORES/claude1","plans":{"claude":"Max 20x"}},
 "claude2":{"provider":"claude","claude":"$STORES/claude2","plans":{"claude":"Ultra"}},
 "claude-reserve":{"provider":"claude","claude":"$STORES/claude-reserve","plans":{"claude":"Team premium"}},
 "claude3":{"provider":"claude","claude":"$STORES/claude3","plans":{"claude":"Max 20x"}},
 "codex1":{"provider":"codex","codex":"$STORES/codex1","pi":"$STORES/pi","plans":{"codex":"Pro 5x"}},
 "codex2":{"provider":"codex","codex":"$STORES/codex2","pi":"$STORES/pi2","plans":{"codex":"Business"}},
 "glm":{"provider":"zai","pi":"$STORES/pi","plans":{"zai":"Pro 6x"}}}}
JSON
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "rules":[
  {"when":"Writing and reporting","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":2},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","reasoning_class":2},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude-reserve","fallback_only":true,"reasoning_class":2},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","reasoning_class":2}]},
  {"when":"Front-end design","never_providers":["zai"],"use":[
    {"harness":"claude","model":"opus","effort":"high","account":"claude1","reasoning_class":2},
    {"harness":"claude","model":"opus","effort":"high","account":"claude2","reasoning_class":2}]},
  {"when":"Read-only investigation","use":[
    {"harness":"claude","model":"haiku","effort":"low","account":"claude1","reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude2","reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude-reserve","fallback_only":true,"reasoning_class":1}]}],
 "default":[
  {"harness":"claude","model":"opus","effort":"medium","account":"claude1","reasoning_class":2},
  {"harness":"claude","model":"opus","effort":"medium","account":"claude2","reasoning_class":2}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-original"

export PATH="$FAKEBIN:$PATH" QUOTA_DIR="$QDIR"
unset FM_QUOTA_INTAKE_TEST_BYPASS
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_JEVD_SOCKET="$SOCKET"
export FM_DISPATCH_QUOTA_ATTEMPTS=1 FM_DISPATCH_QUOTA_BACKOFF_MS=250 FM_DISPATCH_QUOTA_WAIT_SECONDS=20
# Sequential resolves would debit each other; section G turns the spreader on.
export FM_DISPATCH_BURST_WINDOW_SECONDS=0
# The supervisor's own login is the home pin store, as on a real home.
export CLAUDE_CONFIG_DIR="$STORES/claude-reserve" PI_CODING_AGENT_DIR="$STORES/pi" CODEX_HOME="$STORES/codex1"
write_response() {
  jq -n --slurpfile rules "$RULES" --arg choice "$1" --argjson confidence "$2" --argjson probabilities "$3" '
    def profiles: if type == "array" then . else [.] end;
    (([$rules[0].rules // [] | to_entries[] | .key as $r | .value.use | profiles | to_entries[] | "rule_\($r + 1)_\(.key + 1)"] +
      [($rules[0].default // [] | profiles) | to_entries[] | "default_\(.key + 1)"])) as $ids |
    {model:"typesafe/jev-1.13",answers:{rule:{choice:$choice,confidence:$confidence,probabilities:$probabilities},
      profile:{choice:$ids[0],confidence:1,probabilities:($ids | map({key:.,value:(if . == $ids[0] then 1 else 0 end)}) | from_entries)}},usage:{input_tokens:10,output_tokens:4}}' > "$RESPONSE"
}
run() { code=0; out=$("$TOOL" "$@" 2>&1) || code=$?; }
latest() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | sort | tail -1; }
chosen() { printf '%s\n' "$out" | sed -n 's/^  profile: //p'; }
python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
SERVER=$!
for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || break; sleep 0.02; done
[ -S "$SOCKET" ] || fail 'stub did not start'

# ---- S1 -----------------------------------------------------------------------
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
jq 'del(.rules[2].use[0].account)' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" "a profile without an account is a configuration error: $out"
assert_contains "$out" 'rule 3 profile claude:haiku/low names no account' 'the missing account is named'
jq '.rules[2].use[0].account = "nobody"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'names unregistered account nobody' 'an unregistered account is named'
jq '.rules[0].use[3].account = "codex1"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'spends provider zai but account codex1 declares provider codex' 'a provider mismatch is named'
jq '.rules[2].use[0].account = "glm"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'runs on claude but account glm owns no claude store' 'a store the seat lacks is named'
# The libraries run in a child shell, so their locals never shadow this file's.
acct() { bash -c '. "$0"; "$@"' "$ROOT/bin/fm-account-lib.sh" "$@"; }
qlib() { bash -c '. "$0"; "$@"' "$ROOT/bin/fm-quota-axi-lib.sh" "$@"; }
assert_contains "$(acct fm_account_dispatch_problems "$ACCOUNTS" "$RULES")" 'owns no claude store' 'bootstrap shares the same check'
assert_equals '' "$(acct fm_account_dispatch_problems "$ACCOUNTS" "$TMP_ROOT/rules-original")" 'the six-account table is clean'
assert_equals '' "$(acct fm_account_dispatch_problems "$TMP_ROOT/absent.json" "$RULES")" 'a home without a registry is unchanged'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S1: every profile names a registered account that owns its store and serves its provider'

# ---- C2 / S9 --------------------------------------------------------------------
reset_quota
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "investigation routes: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the higher spendPriority worker seat wins'
assert_contains "$out" 'not eligible: fallback_only reserve held: non-fallback claude seats not at their limit (claude:haiku@claude1, claude:haiku@claude2)' 'claude-reserve is held while the worker seats have room'
set_quota claude1 claude 70 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" 'one worker seat at limit is not enough'
assert_contains "$out" 'fallback_only reserve held: non-fallback claude seats not at their limit (claude:haiku@claude2)' 'only the seat with room is named'
set_quota claude2 claude 0 2
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "claude-reserve is picked when both worker seats are at limit: $out"
assert_contains "$out" 'reserve pick: every non-fallback claude seat is at its limit' 'the reserve pick is visible'
"$ROOT/bin/fm-account-routing.sh" off >/dev/null
run "$BRIEF" --task six
assert_contains "$out" 'status: captain-pick' 'routing off goes to the captain with a reason, no guessed route'
assert_contains "$out" 'cross-account routing disabled or account not registered' 'the reason is named'
assert_not_contains "$(chosen)" 'claude-reserve' 'routing off never concentrates work on claude-reserve'
"$ROOT/bin/fm-account-routing.sh" on >/dev/null
reset_quota
reset_quota
jq '.providers[0] |= (.state = {status:"rate_limited", error:"Claude quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude-reserve.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude-reserve.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a held reserve with unknown quota does not stall the choice: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the worker seats still decide'
reset_quota
pass 'C2 and S9: the claude-reserve reserve opens only when claude1 and claude2 are both at limit, never with routing off, and never stalls while held'

# ---- T: seat tiers ---------------------------------------------------------------
# The worker order: claude1, claude2, claude-reserve reserve, then other families. A
# stronger or better-funded candidate of a later tier never wins while an
# earlier seat has capacity.
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "seat_tiers_by_delivery":{"no-mistakes":{"claude2":1,"claude1":2,"claude-reserve":3}},
 "rules":[
  {"when":"Multi-file implementation","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":2,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude-reserve","seat_tier":3,"fallback_only":true,"reasoning_class":4},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"xhigh","account":"codex1","seat_tier":4,"reasoning_class":5},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","seat_tier":4,"reasoning_class":3}]},
  {"when":"Orchestration","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude-reserve","seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":2,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","seat_tier":3,"reasoning_class":3}]},
  {"when":"Read-only investigation","use":[
    {"harness":"claude","model":"haiku","effort":"low","account":"claude1","seat_tier":1,"reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude2","seat_tier":2,"reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude-reserve","seat_tier":3,"fallback_only":true,"reasoning_class":1},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6-luna","effort":"xhigh","account":"codex1","seat_tier":4,"reasoning_class":5}]}]}
JSON
reset_quota
worker='{"rule_1":0.95,"rule_2":0.02,"rule_3":0.02,"default":0.01}'
write_response rule_1 0.95 "$worker"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--model 'opus'" "keep-strongest decides inside the open tier: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the first tier wins although claude2 has the higher spendPriority'
assert_contains "$out" 'not eligible: seat_tier held: an earlier seat still has capacity (claude:sonnet@claude1, claude:opus@claude1)' 'a held candidate names the open tier'
assert_not_contains "$(tail -1 "$LOG")" 'seat_tier' 'Jev never sees a seat tier'
set_quota claude-reserve claude 95 9
jq '.providers[0] |= (.state = {status:"rate_limited", error:"limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a held later tier with unknown quota does not stall the choice: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the open tier still decides'
# ---- U: an unreadable seat never blocks a readable one ---------------------------
unreadable() { jq '.providers[0] |= (.state = {status:"rate_limited", error:"limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"; }
reset_quota
unreadable claude1
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an unreadable first seat does not stop the dispatch: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the next readable seat is chosen'
assert_contains "$out" 'not eligible: quota unreadable, skipped: provider claude unmeasured' 'the unreadable seat is marked on its line'
assert_contains "$out" 'windows_missing=' 'the skipped seat still names what is missing'
assert_contains "$out" 'seat_tier held: an earlier seat still has capacity (claude:opus@claude2)' 'only a readable seat holds the later tiers'
assert_contains "$(jq -r .rationale "$(latest)")" 'quota unreadable, skipped: claude:sonnet@claude1, claude:opus@claude1' 'the receipt names the skipped seats'
# Inside one tier the readable seat wins although the unreadable one comes first.
cp "$RULES" "$TMP_ROOT/tier-rules"
jq '(.rules[0].use[] | select(.account == "claude2")).seat_tier = 1' "$TMP_ROOT/tier-rules" > "$RULES"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "a readable seat of the same tier is chosen: $out"
cp "$TMP_ROOT/tier-rules" "$RULES"
# An unreadable seat is no capacity for a reserve to protect.
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "the reserve opens past an unreadable and a full seat: $out"
assert_contains "$out" 'seat is at its limit (weekly window at or above 100% used or runway exhausted_now) or unreadable' 'the reserve says why it opened'
# So is an expired login.
reset_quota
jq '.providers[0] |= (.state = {status:"auth_required", error:"claude_credential_unavailable"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude1.json"
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "the reserve opens past an expired login and a full seat: $out"
# A later unreadable tier stays held, and nothing readable stays incomplete.
reset_quota
unreadable claude1
unreadable claude-reserve
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "the open tier decides: $out"
assert_contains "$out" 'fallback_only reserve held' 'a later unreadable reserve stays held'
reset_quota
for seat in claude1 claude2 claude-reserve codex1 pi; do unreadable "$seat"; done
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "nothing readable still starts: $out"
assert_contains "$out" 'eligible, quota unknown: provider codex unmeasured (unknown, rate limited)' 'the seat says quota unknown and why'
assert_contains "$out" '-> incomplete: provider claude unmeasured' 'every other seat stays listed as unmeasured'
assert_contains "$out" 'receipt: dispatch-' 'the start gets its receipt'
assert_contains "$(chosen)" "--account 'codex1'" "the first seat of the strongest class starts, as a measured choice would: $out"
assert_not_contains "$out" 'seat_tier held' 'no unreadable tier hides a later one'
# Every login bad is known, not unknown: nothing starts.
reset_quota
for seat in claude1 claude2 claude-reserve codex1 pi; do
  jq '.providers[0] |= (.state = {status:"auth_required", error:"signed out"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/$seat.json" > "$TMP_ROOT/seat-auth.json"
  cp "$TMP_ROOT/seat-auth.json" "$QDIR/$seat.json"
done
rm -rf "$HOME_DIR/state/quota-last-good"
run "$BRIEF" --task six
assert_contains "$out" 'status: captain-pick' "every login bad is not an unknown quota: $out"
assert_contains "$out" 'receipt: none' 'nothing starts on a bad login'
# A skipped pool with a named warm-up still gets it once, and can join the choice.
cat > "$FAKEBIN/zai-window-warm" <<SH
#!/usr/bin/env bash
printf 'warm\n' >> "$TMP_ROOT/warm-calls"
cp "$TMP_ROOT/pi-warm.json" "$QDIR/pi.json"
SH
chmod +x "$FAKEBIN/zai-window-warm"
cp "$RULES" "$TMP_ROOT/tier-rules"
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_1 0.95 "$worker"
reset_quota
cp "$QDIR/pi.json" "$TMP_ROOT/pi-warm.json"
unreadable pi
FM_DISPATCH_QUOTA_ATTEMPTS=1 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "the attempt bound stops the warm-up, not the dispatch: $out"
[ ! -e "$TMP_ROOT/warm-calls" ] || fail 'the warm-up ran past the attempt bound'
FM_DISPATCH_QUOTA_ATTEMPTS=3 FM_DISPATCH_QUOTA_WAIT_SECONDS=60 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'glm'" "the warmed pool joins this choice: $out"
assert_equals 1 "$(wc -l < "$TMP_ROOT/warm-calls" | tr -d ' ')" 'the warm-up runs exactly once'
rm -f "$FAKEBIN/zai-window-warm"
reset_quota
unreadable pi
FM_DISPATCH_QUOTA_ATTEMPTS=3 FM_DISPATCH_QUOTA_WAIT_SECONDS=60 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "an absent warm-up never stalls the choice: $out"
cp "$TMP_ROOT/tier-rules" "$RULES"
write_response rule_1 0.95 "$worker"
# Parallel starts read each login once: the same calls as one start, not four times them.
# Isolate the three-login assertion from unrelated provider stores and warm-ups.
cp "$RULES" "$TMP_ROOT/before-flight-rules"
jq '.rules = [.rules[0] | .use |= map(select(.account == "claude1" or .account == "claude2"))] | del(.default)' "$RULES" > "$TMP_ROOT/flight-rules"
mv "$TMP_ROOT/flight-rules" "$RULES"
# The three-login counts below are registry-size dependent: keep the later S10
# accounts (claude3, codex2) out of this one-start flight, as the comment says.
cp "$ACCOUNTS" "$TMP_ROOT/accounts-before-flight"
jq 'del(.accounts.claude3, .accounts.codex2)' "$ACCOUNTS" > "$TMP_ROOT/accounts-flight" && mv "$TMP_ROOT/accounts-flight" "$ACCOUNTS"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
reset_quota
# Earlier cases left attempts here; this one starts cold.
rm -rf "$HOME_DIR/state/quota-single-flight"
QUOTA_CALL_LOG="$TMP_ROOT/one-start" FM_QUOTA_SHARED_READ_TTL=120 run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "one start resolves: $out"
assert_equals 3 "$(grep -c '^--json$' "$TMP_ROOT/one-start")" 'one start reads the home, claude1 and claude2 logins once'
assert_equals 3 "$(grep -c '^--full --json$' "$TMP_ROOT/one-start")" 'its intake reads each login once'
reset_quota
rm -rf "$HOME_DIR/state/quota-single-flight"
starts=()
for i in 1 2 3 4; do
  ( export QUOTA_CALL_LOG="$TMP_ROOT/parallel-starts" FM_QUOTA_SHARED_READ_TTL=120 FM_QUOTA_READ_DEADLINE=300; "$TOOL" "$BRIEF" --task "six$i" > "$TMP_ROOT/parallel-$i" 2>&1 ) &
  starts+=("$!")
done
# Only the starts: a bare wait would also wait on the Jev stub, which never exits.
wait "${starts[@]}"
for i in 1 2 3 4; do
  assert_contains "$(cat "$TMP_ROOT/parallel-$i")" 'receipt: dispatch-' "parallel start $i has its receipt: $(cat "$TMP_ROOT/parallel-$i")"
done
assert_equals 3 "$(grep -c '^--json$' "$TMP_ROOT/parallel-starts")" 'four parallel starts share the three resolver reads'
assert_equals 3 "$(grep -c '^--full --json$' "$TMP_ROOT/parallel-starts")" 'four parallel starts share the three intake reads'
cp "$TMP_ROOT/accounts-before-flight" "$ACCOUNTS"
reset_quota
cp "$TMP_ROOT/before-flight-rules" "$RULES"
write_response rule_1 0.95 "$worker"
pass 'U: an unreadable candidate is skipped while another is readable; none readable rotates; bad logins do not'
reset_quota
set_quota claude1 claude 0 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "claude2 is the first fallback: $out"
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "claude-reserve comes before another family, unlike a tierless reserve: $out"
assert_contains "$out" 'reserve pick: every non-fallback claude seat is at its limit' 'the reserve decision stays visible'
set_quota claude-reserve claude 0 9 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--harness 'pi'" "another family is the last fallback: $out"
assert_contains "$(chosen)" "--model 'openai-codex/gpt-6.1-sol'" 'keep-strongest and spendPriority still decide inside a shared tier'
reset_quota
# Delivery tiers change the order for a no-mistakes ship and nothing else.
{ cat "$BRIEF"; printf '\n# Definition of done\nDelivery contract: mode=no-mistakes\n'; } > "$TMP_ROOT/nm-brief.md"
{ cat "$BRIEF"; printf '\n# Definition of done\nDelivery contract: mode=direct-PR\n'; } > "$TMP_ROOT/pr-brief.md"
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude2'" "a no-mistakes ship defaults to claude2: $out"
assert_not_contains "$(tail -1 "$LOG")" 'no-mistakes' 'Jev never sees the delivery mode'
run "$TMP_ROOT/pr-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude1'" 'a direct-PR ship keeps the worker order'
set_quota claude2 claude 0 2 exhausted_now
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude1'" "a no-mistakes ship falls back to claude1: $out"
set_quota claude1 claude 0 1 exhausted_now
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "and then to the claude-reserve reserve: $out"
reset_quota
# The orchestration row defaults to the supervisor seat, then the worker seats.
write_response rule_2 0.95 '{"rule_1":0.02,"rule_2":0.95,"rule_3":0.02,"default":0.01}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude-reserve'" "orchestration defaults to claude-reserve: $out"
set_quota claude-reserve claude 0 9 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" 'orchestration falls back to claude1'
set_quota claude1 claude 0 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" 'and then to claude2'
reset_quota
# A stronger later tier does not outbid the default seat, also in an ambiguous union.
write_response rule_3 0.95 '{"rule_1":0.02,"rule_2":0.02,"rule_3":0.95,"default":0.01}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" "a class-5 fallback does not outbid the class-1 default seat: $out"
jq '.default = [.rules[2].use[]]' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_3 0.4 '{"rule_1":0.3,"rule_2":0.05,"rule_3":0.4,"default":0.25}'
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an ambiguous union clears: $out"
assert_contains "$(chosen)" "--model 'haiku'" 'the union takes its class from the anchor row first tier'
assert_contains "$(chosen)" "--account 'claude1'" 'and keeps the seat order'
# Under the shared-quota opt-out the declared tiers still order the row.
jq '.shared_quota = true | del(.default)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
jq '.rules[0].use |= reverse' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 "$worker"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" "shared quota honors the tier over declared order: $out"
# Malformed declarations are configuration errors.
jq '.rules[0].use[0].seat_tier = 0' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a non-positive seat_tier is a configuration error'
assert_contains "$out" 'seat_tier must be a positive integer' 'the seat_tier error is actionable'
jq '.default[0].seat_tier = 1.5' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a fractional default seat_tier is a configuration error'
jq '.seat_tiers_by_delivery = {"no-mistakes":{"claude2":"first"}}' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a malformed delivery tier is a configuration error'
assert_contains "$out" 'seat_tiers_by_delivery must map' 'the delivery tier error is actionable'
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
pass 'T: seat tiers hold later candidates, follow per-delivery tiers, and keep the reserve and class rules'

# ---- S3 -------------------------------------------------------------------------
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.02,"rule_3":0.01,"default":0.02}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'glm'" "glm wins writing on spendPriority where it is allowed: $out"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"rule_3":0,"default":0.25}'
run "$BRIEF" --task six
assert_contains "$out" 'ambiguous union >= 0.25' "an ambiguous design-adjacent task unions: $out"
assert_contains "$out" 'provider zai is banned for this work (never_providers)' 'glm is banned in the union'
assert_not_contains "$(chosen)" 'glm' 'glm never runs design-adjacent work'
jq '.rules[1].use += [{"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","reasoning_class":2}]' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a banned provider listed on its own rule is a configuration error'
assert_contains "$out" 'a rule lists a profile of a provider its own never_providers bans: rule 2 pi:zai/glm-5.3' 'the offending profile is named'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S3: never_providers bans a provider in code, including inside an ambiguous union'

# ---- C3 / R11 / S4 --------------------------------------------------------------
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
reset_quota
jq '.providers[0].windows[0] |= del(.resetsAt, .percentRemaining)' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an unreadable five-hour window does not make the choice incomplete: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the seat with the unreadable five-hour window still ranks'
reset_quota
run "$BRIEF" --task six
jq '.providers[0] |= (.state = {status:"rate_limited", error:"Claude quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a rate-limited read with a recent reading keeps the decision going: $out"
assert_contains "$out" 'reading_age=' 'the reused reading states its age'
assert_contains "$(chosen)" "--account 'claude2'" 'the recent reading still ranks claude2'
assert_equals shared.json "$(find "$HOME_DIR/state/quota-last-good" -type f -printf '%f\n')" 'intake and the resolver share one last-good cache'
cache=$HOME_DIR/state/quota-last-good/shared.json
jq '.rows |= map_values(.at -= 90000)' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a reading older than 24 hours only takes that seat out: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the readable seat takes the choice'
assert_contains "$out" 'not eligible: quota unreadable, skipped: provider claude unmeasured' 'the expired reading is marked on its line'
reset_quota
jq '.providers[0] |= (.state = {status:"auth_required", error:"claude_credential_unavailable"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a credential failure does not stall the other seats: $out"
assert_contains "$out" 'credential unusable for provider claude on account claude2' 'the credential failure is named as such'
assert_contains "$(chosen)" "--account 'claude1'" 'the remaining worker seat runs the work'
reset_quota
pass 'C3, R11 and S4: unreadable five-hour windows do not block, recent readings reused under 24 hours, credential failures named'

# ---- F5 -----------------------------------------------------------------------
# five_hour <key> <jq filter over the five-hour window> [row runway]: the row follows the window.
five_hour() {
  jq --arg runway "${3:-through_reset}" ".providers[0] |= (.windows[0] |= ($2) | .quotaSemantics.effectiveAvailability[0] |= (.effectivePercentRemaining = ([\$windows_pct, .effectivePercentRemaining] | min) | .runway = {status:\$runway}))" \
    --argjson windows_pct "$(jq -n "{} | ($2) | .percentRemaining // 100")" "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"
}
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
reset_quota
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" 'divergence check: claude2 outranks claude1 on spendPriority'
for runway in exhausted_now through_reset; do
  reset_quota
  five_hour claude2 '.percentRemaining = 0 | .resetsAt = "2030-01-01T05:00:00Z"' "$runway"
  run "$BRIEF" --task six
  assert_contains "$(chosen)" "--account 'claude1'" "a seat at its known five-hour limit is held ($runway): $out"
  assert_contains "$out" 'at its five-hour limit, held until 2030-01-01T05:00:00Z' "the held line names the reset ($runway): $out"
  assert_contains "$out" 'five_hour:0%@2030-01-01T05:00:00Z' "the held line shows the window ($runway)"
  # The same window with no published reset cannot hold the seat.
  reset_quota
  five_hour claude2 '.percentRemaining = 0 | del(.resetsAt)' "$runway"
  run "$BRIEF" --task six
  assert_contains "$out" 'status: clear' "a five-hour window with no published reset does not block ($runway): $out"
  assert_contains "$out" 'five_hour=100% used, no published reset, does not block' "the line says why ($runway): $out"
  assert_not_contains "$out" 'held until' "no hold is claimed without a reset ($runway)"
done
# Alone on the row, the reset-less seat starts rather than being refused.
jq '.rules[2].use = [.rules[2].use[1]]' "$TMP_ROOT/rules-original" > "$RULES"
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a lone seat with a reset-less five-hour window starts: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the lone reset-less seat is the one started'
# A profile floor reads through the same rule.
jq '.rules[2].use[1].floor = {scope:"all_models",min_percent:10}' "$TMP_ROOT/rules-original" > "$RULES"
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
run "$BRIEF" --task six
assert_not_contains "$out" 'profile floor all_models below' "a reset-less five-hour window does not trip a floor: $out"
assert_contains "$out" 'status: clear' "the floored seat still starts: $out"
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
reset_quota
five_hour claude2 '.percentRemaining = 100 | del(.resetsAt)'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "an idle five-hour window does not block: $out"
assert_contains "$out" 'five_hour=not started (idle window), does not block' 'the idle window is named on its line'
reset_quota
five_hour claude2 'del(.percentRemaining, .resetsAt)'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "an unreadable five-hour window does not block: $out"
assert_contains "$out" 'five_hour=unreadable, does not block' 'the unreadable window is named on its line'
reset_quota
pass 'F5: a known five-hour limit holds a seat until its named reset; idle, unreadable, and reset-less windows never block'

# ---- G: worker five-hour guard and burst spreader ---------------------------------
DAY=1793876520      # Thu 2026-11-05 12:02 CET, inside the working day
EVENING=1793905200  # Thu 2026-11-05 20:00 CET
SATURDAY=1794049200 # Sat 2026-11-07 12:00 CET
LEDGER="$HOME_DIR/state/dispatch-burst-ledger"
qtweak() { jq ".providers[0] |= ($2)" "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"; }
no_five_hour() { qtweak "$1" '.windows |= map(select(.id != "five_hour")) | .quotaSemantics.effectiveAvailability[0].boundedBy = ["seven_day"]'; }
unreadable() { qtweak "$1" '.state = {status:"rate_limited", error:"quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]}'; }
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Writing and reporting","use":[
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":2},
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","reasoning_class":2},
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude-reserve","fallback_only":true,"reasoning_class":2},
   {"harness":"codex","model":"gpt-6.1-sol","effort":"high","account":"codex1","reasoning_class":2}]}],
 "default":[{"harness":"claude","model":"opus","effort":"medium","account":"claude1","reasoning_class":2}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-guard"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
# claude1 and codex1 have no five-hour window, as on the live seats.
guard_quota() { reset_quota; set_quota codex1 codex 50 0.5; no_five_hour claude1; no_five_hour codex1; rm -f "$LEDGER"; }
grun() { FM_DISPATCH_NOW_EPOCH=$1 run "$BRIEF" --task guard; }
brun() { FM_DISPATCH_NOW_EPOCH=$1 FM_DISPATCH_BURST_WINDOW_SECONDS=1800 run "$BRIEF" --task burst; }
line_of() { printf '%s\n' "$out" | grep "account=$1 "; }
guard_quota
grun "$DAY"
assert_contains "$(chosen)" "--account 'claude2'" "divergence check: claude2 outranks claude1 with room in its window: $out"
five_hour claude2 '.percentRemaining = 19 | .resetsAt = "2030-01-01T05:00:00Z"'
grun "$DAY"
assert_contains "$(chosen)" "--account 'claude1'" "19% left in a five-hour window with a reset holds the seat by day: $out"
assert_contains "$(line_of claude2)" 'not eligible: five-hour guard: five_hour 19% left, under 20% while the captain works (Mon-Fri 08-18 Europe/Amsterdam); resets 2030-01-01T05:00:00Z' "the held line says why: $out"
assert_contains "$out" 'five-hour guard held: claude:sonnet@claude2' 'the note names the held seat'
assert_equals 'five-hour guard' "$(jq -r '.candidates[] | select(.account == "claude2") | .reason | .[0:15]' "$(latest)")" 'the receipt records the guard'
grun "$EVENING"
assert_contains "$(chosen)" "--account 'claude2'" "19% is enough after hours: $out"
five_hour claude2 '.percentRemaining = 6 | .resetsAt = "2030-01-01T05:00:00Z"'
grun "$EVENING"
assert_contains "$(chosen)" "--account 'claude2'" "6% is allowed after hours: $out"
assert_not_contains "$out" 'five-hour guard' 'no guard after hours at 6%'
grun "$SATURDAY"
assert_contains "$(chosen)" "--account 'claude2'" "6% is allowed at the weekend: $out"
grun "$DAY"
assert_contains "$(chosen)" "--account 'claude1'" "6% is held by day: $out"
five_hour claude2 '.percentRemaining = 4 | .resetsAt = "2030-01-01T05:00:00Z"'
grun "$EVENING"
assert_contains "$(chosen)" "--account 'claude1'" "under 5% is held after hours: $out"
assert_contains "$(line_of claude2)" 'five_hour 4% left, under 5% outside working hours' 'the after-hours floor is named'
pass 'G: the five-hour guard holds a seat under 20% by day and under 5% after hours and at weekends'

guard_quota
five_hour claude2 '.percentRemaining = 3 | del(.resetsAt)'
grun "$DAY"
assert_contains "$(chosen)" "--account 'claude2'" "a five-hour window without a reset never counts: $out"
assert_contains "$out" 'five_hour=97% used, no published reset, does not block' 'the line says it does not block'
assert_not_contains "$out" 'five-hour guard' 'no guard without a reset'
guard_quota
five_hour claude2 '.percentRemaining = 10 | .resetsAt = "2030-01-01T05:00:00Z"'
set_quota codex1 codex 50 1.5
no_five_hour codex1
grun "$DAY"
assert_contains "$(chosen)" "--account 'codex1'" "codex1 without a five-hour window wins on spendPriority: $out"
assert_contains "$(line_of claude1)" '-> eligible' 'claude1 without a five-hour window is never guarded'
assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'not eligible: five-hour guard')" 'only the seat with a low window is guarded'
pass 'G: the guard ignores a window without a reset and skips seats with no five-hour window'

guard_quota
five_hour claude2 '.percentRemaining = 10 | .resetsAt = "2030-01-01T05:00:00Z"'
jq '.rules[0].use = [.rules[0].use[1]]' "$TMP_ROOT/rules-guard" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
grun "$DAY"
assert_contains "$out" 'status: clear' "the guard never empties a choice: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the lone guarded seat still starts'
assert_contains "$out" 'eligible, five-hour guard waived: five_hour 10% left' 'the waiver is named'
cp "$TMP_ROOT/rules-guard" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
guard_quota
five_hour claude2 '.percentRemaining = 10 | .resetsAt = "2030-01-01T05:00:00Z"'
unreadable claude1
unreadable codex1
grun "$DAY"
assert_contains "$out" 'status: clear' "unreadable seats beside a guarded one still start: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the only known seat starts with the guard waived'
guard_quota
for key in claude1 claude2 claude-reserve codex1; do unreadable "$key"; done
grun "$DAY"
assert_contains "$out" 'status: clear' "unknown quota on every seat still starts by day: $out"
assert_contains "$out" 'quota unknown' 'the start is marked quota unknown'
pass 'G: the guard is waived rather than empty a choice, and an unknown quota never blocks a start'

# Scenario 6 of the routing report: the 11:02Z burst, where 15 of 15 starts went to claude2.
burst_quota() {
  reset_quota
  set_quota claude1 claude 96 1.4632; no_five_hour claude1
  set_quota claude2 claude 24 1.4854
  five_hour claude2 '.percentRemaining = 89 | .resetsAt = "2030-01-01T06:00:00Z"'
  set_quota claude-reserve claude 76 0.322
  set_quota codex1 codex 99 1.1242; no_five_hour codex1
  rm -f "$LEDGER"
}
burst_quota
picks=()
for ((i = 0; i < 20; i++)); do
  brun "$DAY"
  picks+=("$(chosen | sed -n "s/.*--account '\([^']*\)'.*/\1/p")")
  [ "$i" -ne 1 ] || second=$out
done
assert_equals 'claude1=15 claude2=4 codex1=1' "$(printf '%s\n' "${picks[@]}" | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " }')" "a burst of 20 spreads over the furthest-behind seats: ${picks[*]}"
assert_equals claude2 "${picks[0]}" 'the first start of the burst takes the furthest-behind seat'
assert_contains "$second" 'burst_debit=2pt/1start(s) ranks=1.3855' "the debited seat shows its adjusted score: $second"
assert_contains "$second" 'burst debit: claude:sonnet@claude2 1.4854 -> 1.3855 after 1 recent start(s)' 'the note names the debit'
assert_equals 1.4854 "$(jq -r '.candidates[] | select(.account == "claude2") | .spendPriority' "$(latest)")" 'the receipt keeps the published spendPriority'
assert_equals 20 "$(wc -l < "$LEDGER" | tr -d ' ')" 'every clear start is debited once'
brun "$((DAY + 1800))"
assert_contains "$(chosen)" "--account 'claude2'" "a debit is gone once its window has passed: $out"
assert_not_contains "$out" 'burst_debit=' 'no faded debit is shown'
assert_equals "$((DAY + 1800)) claude2 2.0" "$(cat "$LEDGER")" 'a ledger of faded debits starts fresh'
printf '%s claude2 1.3\n' "$DAY" > "$LEDGER"
brun "$((DAY + 900))"
assert_contains "$out" 'burst_debit=0.65pt/1start(s)' "a debit fades linearly inside its window: $out"
burst_quota
printf '%s claude2 50\n' "$DAY" > "$LEDGER"
FM_DISPATCH_NOW_EPOCH=$DAY run "$BRIEF" --task burst
assert_contains "$(chosen)" "--account 'claude2'" "a zero window turns the spreader off: $out"
rm -f "$LEDGER"
FM_DISPATCH_BURST_COST=0.5 brun "$DAY"
assert_equals "$DAY claude2 0.5" "$(tail -n 1 "$LEDGER")" 'the uniform cost is overridable'
rm -f "$LEDGER"
reset_quota
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'G: a burst of worker starts spreads over the furthest-behind seats and the debit fades with its window'

# Equal seats on different providers rank identically after a burst: the debit
# counts starts, never the provider, so two equal-quota seats alternate.
rm -f "$LEDGER"
printf '0\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
reset_quota
set_quota claude1 claude 50 1; no_five_hour claude1
set_quota pi zai 50 1; no_five_hour pi
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Any work","label":"Any work label","use":[
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":2},
   {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","reasoning_class":2}]}],
 "default":[{"harness":"claude","model":"opus","effort":"medium","account":"claude1","reasoning_class":2}]}
JSON
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
brun "$DAY"
assert_contains "$(chosen)" "--account 'claude1'" "the first start takes the first of two equal seats: $out"
brun "$DAY"
assert_contains "$(chosen)" "--account 'glm'" "the debited claude seat loses to the equal zai seat: $out"
assert_contains "$(line_of claude1)" 'burst_debit=2pt/1start(s)' "the debit counts the start on any provider: $out"
assert_contains "$(line_of glm)" 'account=glm' "the equal zai seat is listed: $out"
assert_not_contains "$(line_of glm)" 'burst_debit=' "the undebited equal seat keeps its published score: $out"
assert_equals "$(printf '%s claude1 2.0\n%s glm 2.0\n' "$DAY" "$DAY")" "$(cat "$LEDGER")" 'equal starts on claude and zai are debited the same cost'
rm -f "$LEDGER"
reset_quota
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
pass 'G: equal seats on different providers rank identically after a burst'

# ---- P: pipeline seat rows -------------------------------------------------------
# The fixed row per no-mistakes step: pool 1 is claude1 and claude2, pool 2 is
# claude-reserve above its weekly floor and then the Codex seats. A healthy glm seat with
# the most room stays out, because no row may list a banned provider.
cp "$ACCOUNTS" "$TMP_ROOT/accounts-original"
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Any work","label":"Any work label","use":[
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":3}]}],
 "pipeline_rows":[
  {"steps":["review","test","ci","rebase","fixes"],"never_providers":["zai"],"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","pool":1,"seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","pool":1,"seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude-reserve","pool":2,"seat_tier":2,"reasoning_class":4,"weekly_floor_percent":20},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex1","pool":2,"seat_tier":3,"reasoning_class":4},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex2","pool":2,"seat_tier":3,"reasoning_class":4}]},
  {"steps":["document","pr"],"never_providers":["zai"],"use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","pool":1,"seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","pool":1,"seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude-reserve","pool":2,"seat_tier":2,"reasoning_class":3,"weekly_floor_percent":20},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"low","account":"codex1","pool":2,"seat_tier":3,"reasoning_class":3},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"low","account":"codex2","pool":2,"seat_tier":3,"reasoning_class":3}]}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-pipeline"
pipeline_quota() {
  reset_quota
  set_quota claude1 claude 70 1.3
  set_quota claude2 claude 60 1.2
  set_quota claude-reserve claude 80 0.2
  set_quota codex1 codex 90 0.8
  set_quota codex2 codex 90 0.7
}
# tweak <key> <jq filter over the provider's single row and windows>
tweak() { jq ".providers[0] |= ($2)" "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"; }
# A live five-hour window: projected out of room in <seconds>, row bound by five_hour.
short_seat() { tweak "$1" ".quotaSemantics.effectiveAvailability[0].runway = {status:\"projected_exhaustion\",usableRunwaySeconds:$2,limitingWindowId:\"five_hour\"}"; }
# The five-hour window is empty, the weekly window still has room.
five_hour_out() { tweak "$1" ".windows[0].percentRemaining = 0 | .windows[0].resetsAt = \"$2\" | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 0 | .quotaSemantics.effectiveAvailability[0].runway = {status:\"exhausted_now\",limitingWindowId:\"five_hour\"}"; }
rate_limited() { tweak "$1" '.state = {status:"rate_limited", error:"quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]}'; }
# One attempt means no retry wait; the bound must still outlast five reads on a slow host.
pipe() { code=0; pout=$(FM_DISPATCH_QUOTA_WAIT_SECONDS=30 "$TOOL" pipeline --step "$1" 2>"$TMP_ROOT/pipe-err") || code=$?; perr=$(cat "$TMP_ROOT/pipe-err"); }
pfield() { jq -r "$1" <<<"$pout"; }
receipts() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' 2>/dev/null | wc -l | tr -d ' '; }

pipeline_quota
before_requests=$(wc -l < "$LOG"); before_receipts=$(receipts)
pipe review
expect_code 0 "$code" "a pipeline step resolves: $pout $perr"
assert_equals 'ok claude1 claude opus medium 1' "$(pfield '"\(.status) \(.seat) \(.harness) \(.model) \(.effort) \(.pool)"')" 'pool 1 best spendPriority wins with its row profile'
assert_contains "$(pfield .reason)" 'pool 1 tier 1' 'the reason names the pool'
assert_equals '5' "$(pfield '.candidates | length')" 'every seat of the row is reported'
assert_equals "$before_requests" "$(wc -l < "$LOG")" 'pipeline mode makes no model call'
assert_equals "$before_receipts" "$(receipts)" 'pipeline mode writes no receipt'
pipe document
assert_equals 'claude1 sonnet high 3' "$(pfield '"\(.seat) \(.model) \(.effort) \(.reasoning_class)"')" 'each step takes its own row'
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task six-p
assert_not_contains "$(tail -1 "$LOG")" 'gpt-6.1-sol' 'worker requests never show the pipeline rows to Jev'
assert_contains "$out" "--account 'claude1'" 'worker resolution ignores the pipeline rows'
pass 'P: a step resolves from its fixed row with no model call and no receipt'
# Preview shares both dispatch evaluators, but cannot spend or rotate state.
pipeline_quota
set_quota claude1 claude 2 9
pipe review
assert_equals claude2 "$(pfield .seat)" '2% weekly left is full for a pipeline start'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude1") | .reason')" 'weekly guard:' 'pipeline reuses the weekly start gate'
set_quota claude1 claude 3 9
pipe review
assert_equals claude2 "$(pfield .seat)" '97% used plus the new start reserve reaches the weekly gate'
set_quota claude2 claude 2 8
pipe review
assert_equals claude-reserve "$(pfield .seat)" 'both pool 1 seats weekly-full open the next tier'
pipeline_quota
# Force a full tie so a real dispatch would advance the rotation.
set_quota claude2 claude 70 1.3
printf '7\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
cp -R "$HOME_DIR/state" "$TMP_ROOT/state-before-preview"
before_requests=$(wc -l < "$LOG")
printf '#!/usr/bin/env bash\nprintf warm >> "%s"\n' "$TMP_ROOT/preview-warmed" > "$FAKEBIN/zai-window-warm"
chmod +x "$FAKEBIN/zai-window-warm"
run preview --json
expect_code 0 "$code" "preview succeeds: $out"
preview=$out
assert_equals 'Any work label' "$(jq -r '.workers[0].label' <<< "$preview")" 'preview exports display-only labels'
run rows --json
expect_code 0 "$code" 'additive criteria export succeeds'
assert_equals 'Any work label' "$(jq -r '.rows[0].label' <<< "$out")" 'rows exports the display label'
assert_equals '1 false null' "$(jq -r '.rows[0].candidates[0] | "\(.seat_tier // 1) \(.fallback_only) \(.pool)"' <<< "$out")" 'rows exports tier, reserve and pool fields'
assert_equals 2 "$(jq '.pipelineRows | length' <<< "$out")" 'rows includes pipeline declarations'
assert_equals 98 "$(jq '.guards.weekly.maxUsedPercent' <<< "$out")" 'rows includes resolved guards'
assert_equals "$before_requests" "$(wc -l < "$LOG")" 'preview never contacts Jev'
diff -r "$TMP_ROOT/state-before-preview" "$HOME_DIR/state" > "$TMP_ROOT/preview-state-diff" || fail "preview changed state: $(cat "$TMP_ROOT/preview-state-diff")"
[ ! -e "$TMP_ROOT/preview-warmed" ] || fail 'preview ran a warm-up'
assert_equals 7 "$(jq '.noMistakes | length' <<< "$preview")" 'preview covers every pipeline step'
pipe review
assert_equals "$(pfield .seat)" "$(jq -r '.noMistakes[] | select(.step == "review") | .pick.seat' <<< "$preview")" 'preview and real pipeline choose the same tied seat'
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task preview-equality
assert_contains "$out" "--account '$(jq -r '.workers[] | select(.id == "rule_1") | .pick.seat' <<< "$preview")'" 'preview and worker dispatch choose the same seat'
# Unreadable Z.ai is deliberately present only in the preview account gather.
tweak pi '.state={status:"rate_limited"} | .windows=[] | .quotaSemantics={status:"unknown",effectiveAvailability:[]}'
run preview --json
expect_code 0 "$code" 'preview tolerates an unreadable provider without warming it'
[ ! -e "$TMP_ROOT/preview-warmed" ] || fail 'preview warmed unreadable Z.ai'
rm "$FAKEBIN/zai-window-warm"
pass 'P: shared weekly gate and read-only preview match dispatch without state changes'

# The worker five-hour guard and spreader never reach a pipeline row: a low five-hour
# window with a reset by day and a heavy burst debit leave the pick as it was.
pipeline_quota
tweak claude1 '.windows[0].percentRemaining = 10 | .windows[0].resetsAt = "2030-01-01T05:00:00Z"'
printf '%s claude1 60\n' "$DAY" > "$LEDGER"
FM_DISPATCH_NOW_EPOCH=$DAY FM_DISPATCH_BURST_WINDOW_SECONDS=1800 pipe review
assert_equals 'ok claude1' "$(pfield '"\(.status) \(.seat)"')" "a pipeline step ignores the five-hour guard and burst debits: $pout $perr"
assert_not_contains "$pout" 'five-hour guard' 'no guard on a pipeline candidate'
assert_equals "$DAY claude1 60" "$(cat "$LEDGER")" 'a pipeline pick writes no burst debit'
rm -f "$LEDGER"
pass 'P: pipeline rows keep their seat order with no five-hour guard or burst debit'

# Tie-break: the shared rule, soonest reset and then the round-robin.
pipeline_quota
set_quota claude1 claude 70 1.3 through_reset 2030-01-05T00:00:00Z
set_quota claude2 claude 70 1.3 through_reset 2030-01-03T00:00:00Z
tweak claude1 '.quotaSemantics.effectiveAvailability[0].boundedBy = ["seven_day"]'
tweak claude2 '.quotaSemantics.effectiveAvailability[0].boundedBy = ["seven_day"]'
pipe review
assert_equals claude2 "$(pfield .seat)" 'an exact tie goes to the sooner binding reset'
assert_contains "$(pfield .tie_break)" 'sooner binding reset' 'the tie-break is logged'
set_quota claude1 claude 70 1.3
set_quota claude2 claude 70 1.3
pipe review; first_tied=$(pfield .seat)
pipe review; second_tied=$(pfield .seat)
assert_not_contains "$first_tied" "$second_tied" 'a full tie rotates between the seats'
pass 'P: ties use the shared reset and round-robin rule'

# Five-hour window: counts for the pipeline, never opens pool 2 while a seat has room.
pipeline_quota
set_quota claude2 claude 60 5
pipe review
assert_equals claude2 "$(pfield .seat)" 'divergence check: claude2 outranks claude1 on spendPriority'
short_seat claude2 3808
pipe review
assert_equals claude1 "$(pfield .seat)" 'a seat that will not last to reset loses to one that does'
assert_contains "$(pfield .reason)" 'claude2 will not last to reset' 'the reason names the seat that lost'
pipeline_quota
set_quota claude2 claude 60 5
short_seat claude2 5400
pipe review
assert_equals claude2 "$(pfield .seat)" 'a runway of 90 minutes is not short'
pipeline_quota
set_quota claude2 claude 60 5
short_seat claude2 3808
tweak claude2 'del(.windows[0].resetsAt)'
pipe review
assert_equals claude2 "$(pfield .seat)" 'a five-hour window with no reset does not count as short'
pipeline_quota
short_seat claude1 600
short_seat claude2 700
pipe review
assert_equals '1 claude1' "$(pfield '"\(.pool) \(.seat)"')" 'short runways alone keep pool 1, ranked as usual'
assert_contains "$(pfield .reason)" 'no open seat lasts to reset' 'that is stated'
pass 'P: a live five-hour window decides inside a tier and does not open pool 2'

# A pipeline seat at a known five-hour limit waits for its reset; one with no published reset never does.
pipeline_quota
set_quota claude2 claude 60 5
five_hour_out claude2 2030-01-01T06:00:00Z
pipe review
assert_equals claude1 "$(pfield .seat)" 'a seat at its known five-hour limit is held'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude2") | .reason')" 'held until 2030-01-01T06:00:00Z' 'the seat view names the reset'
tweak claude2 'del(.windows[0].resetsAt)'
pipe review
assert_equals claude2 "$(pfield .seat)" 'the same limit with no published reset does not hold the seat'
pass 'P: a five-hour limit holds a pipeline seat only when its reset is published'

# Pool 2 opens only when pool 1 has no room, and claude-reserve comes first inside it.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
pipe review
assert_equals '1 claude2' "$(pfield '"\(.pool) \(.seat)"')" 'one pool 1 seat with room keeps pool 1'
five_hour_out claude2 2030-01-01T06:00:00Z
pipe review
assert_equals '2 claude-reserve opus medium' "$(pfield '"\(.pool) \(.seat) \(.model) \(.effort)"')" 'claude-reserve above its floor beats Codex despite a lower spendPriority'
assert_contains "$(pfield .reason)" 'pool 1 has no seat with room' 'opening pool 2 is stated'
pass 'P: pool 2 opens on an empty pool 1, even on five-hour limits, claude-reserve first'

# The claude-reserve weekly floor: weekly room decides, and a low five-hour row does not trip it.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
set_quota claude-reserve claude 21 0.2
pipe review
assert_equals claude-reserve "$(pfield .seat)" 'above the floor claude-reserve still runs'
set_quota claude-reserve claude 20 0.2
pipe review
assert_equals '2 codex1 codex gpt-6.1-sol medium' "$(pfield '"\(.pool) \(.seat) \(.harness) \(.model) \(.effort)"')" 'at the floor claude-reserve stops and Codex runs at the class effort'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude-reserve") | .reason')" 'weekly floor: 20% left, stops at 20%' 'the floor stop is named'
set_quota claude-reserve claude 80 0.2
tweak claude-reserve '.windows[0].percentRemaining = 15 | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 15'
pipe review
assert_equals claude-reserve "$(pfield .seat)" 'a low five-hour row never trips the weekly floor'
set_quota claude-reserve claude 20 0.2
pipe document
assert_equals 'codex1 low 3' "$(pfield '"\(.seat) \(.effort) \(.reasoning_class)"')" 'Codex takes the step class of its row'
pass 'P: claude-reserve stops at its weekly floor, on the weekly window only'

# Both pools empty: one line per seat with its reset, no downgrade, no GLM.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
set_quota claude-reserve claude 10 0.2 through_reset 2030-01-07T00:00:00Z
set_quota codex1 codex 0 0.8 through_reset 2030-01-08T00:00:00Z
set_quota codex2 codex 0 0.7 through_reset 2030-01-09T00:00:00Z
pipe review
expect_code 3 "$code" "both pools empty exits 3: $pout"
assert_equals 'exhausted' "$(pfield .status)" 'the outcome is exhausted'
assert_equals 'null' "$(pfield '.seat // null')" 'no seat is named as chosen'
assert_contains "$(pfield .reason)" 'quota exhausted' 'the outcome uses the recognised limit text'
assert_equals '5' "$(printf '%s\n' "$perr" | wc -l | tr -d ' ')" "one line per seat: $perr"
assert_contains "$perr" 'claude1 (pool 1) has no room, resets 2030-01-01T05:00:00Z' 'a five-hour seat names its five-hour reset'
assert_contains "$perr" 'claude2 (pool 1) has no room, resets 2030-01-01T06:00:00Z' 'each seat names its own reset'
assert_contains "$perr" 'claude-reserve (pool 2) has no room, resets 2030-01-07T00:00:00Z: weekly floor: 10% left' 'a floored seat names its weekly reset'
assert_contains "$perr" 'codex1 (pool 2) has no room, resets 2030-01-08T00:00:00Z' 'a Codex seat names its reset'
assert_contains "$perr" 'codex2 (pool 2) has no room, resets 2030-01-09T00:00:00Z' 'every Codex seat is listed'
assert_not_contains "$pout$perr" 'glm' 'no GLM seat is offered'
pass 'P: both pools empty fail with one line per seat and its reset, and no GLM'

# Unreadable quota waits within its bound and never opens the next pool.
pipeline_quota
rate_limited claude2
pipe review
assert_equals 'claude1 true' "$(pfield '"\(.seat) \(.measured)"')" 'a measured seat of the open tier wins over an unreadable one'
pipeline_quota
rate_limited claude1
rate_limited claude2
printf '1\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
cp "$RULES" "$TMP_ROOT/unknown-pipeline-rules"
# Put the expected winner last: array order must not select the seat.
jq '.pipeline_rows[].use |= sort_by(if .account == "claude2" then 1 else 0 end)' "$RULES" > "$TMP_ROOT/unknown-order"
mv "$TMP_ROOT/unknown-order" "$RULES"
run preview --json
expect_code 0 "$code" "unknown pipeline preview succeeds: $out"
assert_equals claude2 "$(jq -r '.noMistakes[] | select(.step == "review") | .pick.seat' <<< "$out")" 'preview rotates within the open tier, not array order'
assert_equals 1 "$(< "$HOME_DIR/state/dispatch-tie-round-robin")" 'pipeline preview does not advance rotation'
pipe review
expect_code 0 "$code" "both unreadable still resolve: $perr"
assert_equals '1 claude2 false' "$(pfield '"\(.pool) \(.seat) \(.measured)"')" 'both unreadable: round-robin stays in pool 1 and marks unmeasured'
assert_contains "$(pfield .tie_break)" 'quota unknown; round-robin slot 2 of 2' 'the slot is logged'
assert_equals 2 "$(< "$HOME_DIR/state/dispatch-tie-round-robin")" 'unknown pipeline start advances rotation'
pipe review
assert_equals claude1 "$(pfield .seat)" 'the next unknown start rotates to the other seat'
cp "$TMP_ROOT/unknown-pipeline-rules" "$RULES"
assert_contains "$(pfield .reason)" 'quota unreadable' 'the reason says so'
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
rate_limited claude-reserve
pipe review
assert_equals 'codex1' "$(pfield .seat)" 'an unreadable weekly floor never lets claude-reserve fail open'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude-reserve") | .reason')" 'weekly floor 20% is unverifiable' 'that is named'
pipeline_quota
cat > "$FAKEBIN/quota-axi-hung" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$FAKEBIN/quota-axi-hung"
cp "$FAKEBIN/quota-axi" "$FAKEBIN/quota-axi-real"
cp "$FAKEBIN/quota-axi-hung" "$FAKEBIN/quota-axi"
printf '0\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
started=$(date +%s)
code=0; pout=$(FM_DISPATCH_QUOTA_WAIT_SECONDS=900 FM_DISPATCH_QUOTA_ATTEMPTS=1000 "$TOOL" pipeline --step review 2>/dev/null) || code=$?
elapsed=$(( $(date +%s) - started ))
cp "$FAKEBIN/quota-axi-real" "$FAKEBIN/quota-axi"
expect_code 0 "$code" 'a hung quota read still resolves'
[ "$elapsed" -le 40 ] || fail "the quota wait is bounded to 30 seconds, took $elapsed"
assert_equals '1 claude1 false' "$(pfield '"\(.pool) \(.seat) \(.measured)"')" 'a hung read gives the first seat of pool 1 within the bound'
pass 'P: unreadable quota is bounded to 30 seconds and never opens the next pool'

# Shared-quota homes keep the declared order.
pipeline_quota
jq '.shared_quota = true' "$TMP_ROOT/rules-pipeline" > "$RULES"
pipe review
assert_equals 'claude1 true' "$(pfield '"\(.seat) \(.measured)"')" 'a shared-quota home takes the declared order'
cp "$TMP_ROOT/rules-pipeline" "$RULES"
pass 'P: a shared-quota home takes the declared order'

# Usage and configuration errors exit 2 and name the fault.
pipe nosuchstep
expect_code 2 "$code" 'a step with no row is a configuration error'
assert_contains "$perr" 'no pipeline_rows row names step nosuchstep' 'the step is named'
run pipeline
expect_code 2 "$code" 'pipeline needs a step'
run pipeline --step review "$BRIEF"
expect_code 2 "$code" 'pipeline takes no brief'
run "$BRIEF" --step review
expect_code 2 "$code" '--step belongs to pipeline mode'
bad_rows() {  # <jq edit> <expected text> <what>
  jq "$1" "$TMP_ROOT/rules-pipeline" > "$RULES"
  pipe review
  expect_code 2 "$code" "$3 is a configuration error: $pout"
  assert_contains "$perr" "$2" "$3 is named"
  cp "$TMP_ROOT/rules-pipeline" "$RULES"
}
bad_rows '.pipeline_rows[0].use += [{"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","pool":2,"seat_tier":4,"reasoning_class":4}]' 'spends provider zai, which never_providers bans' 'a GLM seat in a row'
bad_rows 'del(.pipeline_rows[0].never_providers)' 'needs never_providers' 'a row without never_providers'
bad_rows '.pipeline_rows[0].use[3].reasoning_class = 3' 'seat_tier 3 must share one reasoning_class' 'a mixed class inside one tier'
bad_rows '.pipeline_rows[0].use[2].seat_tier = 1' 'pool 2 seat_tier values must all follow pool 1' 'a pool 2 seat inside the pool 1 tier'
bad_rows '.pipeline_rows[0].use[2].fallback_only = true' 'must not set fallback_only' 'fallback_only in a row'
bad_rows '.pipeline_rows[0].use[2].weekly_floor_percent = "20"' 'weekly_floor_percent must be a number' 'a malformed floor'
bad_rows '.pipeline_rows[1].steps = ["review"]' 'pipeline step review is named by more than one row' 'a step in two rows'
bad_rows '.pipeline_rows[0].use[0].account = "nobody"' 'names unregistered account nobody' 'an unregistered seat'
bad_rows 'del(.pipeline_rows[0].use[0].account)' 'must name an account' 'a seat without an account'
bad_rows '.pipeline_rows[0].use[0].effort = "ultra"' 'effort must be supported' 'an unsupported effort'
assert_contains "$(acct fm_account_pipeline_problems "$TMP_ROOT/rules-pipeline")$(jq '.pipeline_rows = {}' "$TMP_ROOT/rules-pipeline" > "$RULES"; acct fm_account_pipeline_problems "$RULES")" 'pipeline_rows must be a non-empty array' 'a malformed rows value is named'
cp "$TMP_ROOT/rules-pipeline" "$RULES"
"$ROOT/bin/fm-account-routing.sh" off >/dev/null
pipe review
expect_code 2 "$code" 'routing off is not quota exhaustion'
assert_contains "$perr" 'pipeline seat not routable' 'routing off is named'
"$ROOT/bin/fm-account-routing.sh" on >/dev/null
cp "$TMP_ROOT/accounts-original" "$ACCOUNTS"
cp "$TMP_ROOT/rules-original" "$RULES"
pipeline_quota
reset_quota
pass 'P: malformed rows, unknown steps and unroutable seats are configuration errors'

# The captain's no-mistakes ladder: claude1/claude2 tier 1, codex1/codex2 tier 2,
# glm tier 3 one class below. Classes are checked per seat tier, so the row is
# valid, the GLM tier opens only once every earlier tier is full, and a mixed
# class inside one tier is still refused.
jq '.pipeline_rows = [{"steps":["review"],"never_providers":["anthropic"],"use":[
     {"harness":"claude","model":"opus","effort":"medium","account":"claude1","pool":1,"seat_tier":1,"reasoning_class":4},
     {"harness":"claude","model":"opus","effort":"medium","account":"claude2","pool":1,"seat_tier":1,"reasoning_class":4},
     {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex1","pool":2,"seat_tier":2,"reasoning_class":4},
     {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex2","pool":2,"seat_tier":2,"reasoning_class":4},
     {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","pool":2,"seat_tier":3,"reasoning_class":3}]}]' "$TMP_ROOT/rules-pipeline" > "$RULES"
jq --arg store "$STORES" '.accounts.codex2 = {provider:"codex",codex:"\($store)/codex2",pi:"\($store)/pi",plans:{codex:"Business"}}' "$TMP_ROOT/accounts-original" > "$ACCOUNTS"
pipeline_quota
pipe review
assert_equals 'ok claude1' "$(pfield '"\(.status) \(.seat)"')" 'the ladder starts at tier 1'
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
pipe review
assert_equals 'codex1 4' "$(pfield '"\(.seat) \(.reasoning_class)"')" 'an empty tier 1 opens tier 2, not the GLM tier'
five_hour_out codex1 2030-01-01T07:00:00Z
pipe review
assert_equals 'codex2 2' "$(pfield '"\(.seat) \(.tier)"')" 'a half-full tier 2 stays inside tier 2'
five_hour_out codex2 2030-01-01T08:00:00Z
pipe review
assert_equals 'ok glm pi zai/glm-5.3 high 3 2 3' "$(pfield '"\(.status) \(.seat) \(.harness) \(.model) \(.effort) \(.reasoning_class) \(.pool) \(.tier)"')" 'every earlier tier full runs the class 3 GLM stage'
assert_contains "$(pfield .reason)" 'pool 2 tier 3' 'the reason names the GLM tier'
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
rate_limited codex1
rate_limited codex2
printf '1\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
pipe review
expect_code 0 "$code" "unreadable tier 2 still resolves: $pout $perr"
assert_equals 'codex2 2 false' "$(pfield '"\(.seat) \(.tier) \(.measured)"')" 'unreadable tier 2 quota never opens the GLM tier'
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
five_hour_out codex1 2030-01-01T07:00:00Z
five_hour_out codex2 2030-01-01T08:00:00Z
run preview --json
expect_code 0 "$code" "the ladder preview succeeds: $out"
assert_equals '3 glm 3 3' "$(jq -r '.noMistakes[] | select(.step == "review") | "\(.ladder | length) \(.pick.seat) \(.reasoning_class) \(.tier)"' <<< "$out")" 'preview shows the GLM stage of the three-tier ladder'
assert_equals 'claude1,claude2 codex1,codex2 glm' "$(jq -r '.noMistakes[] | select(.step == "review") | (.ladder | map(.seats | join(",")) | join(" "))' <<< "$out")" 'the preview ladder lists every tier in order'
jq '.pipeline_rows[0].use[3].reasoning_class = 3' "$RULES" > "$TMP_ROOT/ladder-mixed"
cp "$TMP_ROOT/ladder-mixed" "$RULES"
pipe review
expect_code 2 "$code" "a mixed class inside one tier is a configuration error: $pout"
assert_contains "$perr" 'seat_tier 2 must share one reasoning_class' 'the mixed tier is named'
cp "$TMP_ROOT/accounts-original" "$ACCOUNTS"
cp "$TMP_ROOT/rules-original" "$RULES"
pipeline_quota
reset_quota
pass 'P: a class 3 GLM tier follows the class 4 tiers, opened only when they are full'

# ---- S10: lane 1 resolver - claude3 seating, never_models, the optional fable gate ----
# A plan-shaped worker table: claude3 joins rows only as a later seat tier with a
# 25% weekly floor (rule 8-style rows put it first instead), never_models keeps a
# blended rule's bans on the anchor's candidates, and ladder_policy.fable_projects
# stays an optional allowlist - absent it restricts nothing (captain decision
# 2026-11-11, option B: Fable may start and escalate on every repo).
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "claude3_policy":{"worker_rows":"later seat tier only","weekly_floor_percent":25,"note":"claude3 seats follow the worker seats"},
 "ladder_policy":{"fable_projects":["firstmate"]},
 "rules":[
  {"when":"Security review","never_providers":["zai"],"never_models":["fable"],"strict_tiers":true,"use":[
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude1","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude2","seat_tier":1,"reasoning_class":5},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6-astra","effort":"xhigh","account":"codex1","seat_tier":2,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude3","seat_tier":3,"reasoning_class":5}]},
  {"when":"Planning","never_providers":["zai"],"never_models":["fable"],"strict_tiers":true,"use":[
    {"harness":"claude","model":"opus","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"high","account":"claude2","seat_tier":1,"reasoning_class":5},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6-astra","effort":"high","account":"codex1","seat_tier":2,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"high","account":"claude3","seat_tier":3,"reasoning_class":5}]},
  {"when":"Front-end design","never_models":["fable"],"strict_tiers":true,"use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","seat_tier":1,"reasoning_class":3},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","seat_tier":2,"reasoning_class":2},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude3","seat_tier":3,"reasoning_class":3}]},
  {"when":"Read-only research","use":[
    {"harness":"claude","model":"haiku","effort":"low","account":"claude1","seat_tier":1,"reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude2","seat_tier":1,"reasoning_class":1},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6-luna","effort":"xhigh","account":"codex1","seat_tier":2,"reasoning_class":2}]},
  {"when":"Written deliverables","strict_tiers":true,"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":4},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"medium","account":"codex1","seat_tier":2,"reasoning_class":4},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"medium","account":"codex2","seat_tier":2,"reasoning_class":4},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","seat_tier":3,"reasoning_class":2}]},
  {"when":"Hard bugs","strict_tiers":true,"use":[
    {"harness":"claude","model":"fable","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":6},
    {"harness":"claude","model":"fable","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":6},
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude1","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude2","seat_tier":1,"reasoning_class":5},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"max","account":"codex1","seat_tier":2,"reasoning_class":4},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"max","account":"glm","seat_tier":2,"reasoning_class":2},
    {"harness":"claude","model":"opus","effort":"xhigh","account":"claude3","seat_tier":3,"reasoning_class":5}]},
  {"when":"Firstmate orchestration","use":[
    {"harness":"claude","model":"opus","effort":"high","account":"claude3","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"high","account":"claude1","seat_tier":2,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"high","account":"claude2","seat_tier":2,"reasoning_class":5}]}],
 "default":[
  {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":4},
  {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":4},
  {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","seat_tier":2,"reasoning_class":2}]}
JSON
reset_quota
printf '0\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
run rows --json
expect_code 0 "$code" "the plan-shaped table passes the load checks: $out"
assert_equals zai "$(jq -r '.rows[] | select(.id == "rule_1") | .never_providers[0]' <<< "$out")" 'rows --json exports each row never_providers'
assert_equals fable "$(jq -r '.rows[] | select(.id == "rule_1") | .never_models[0]' <<< "$out")" 'rows --json exports each row never_models'
assert_equals true "$(jq -r '.rows[] | select(.id == "rule_4") | (.never_providers == null and .never_models == null)' <<< "$out")" 'rows without bans export null bans'
# A clear pick keeps claude3 and the Codex fallback held behind the open tier.
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.02,"rule_3":0.01,"rule_4":0.01,"rule_5":0.0,"rule_6":0.0,"rule_7":0.0,"default":0.01}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "security spends the higher-priority seat inside the open tier: $out"
assert_contains "$out" 'seat_tier held' 'later tiers stay held while tier 1 has room'
# With every earlier pool out, claude3 starts above its floor but stops below it.
set_quota claude1 claude 0 1 exhausted_now
set_quota claude2 claude 0 2 exhausted_now
set_quota codex1 codex 0 1 exhausted_now
set_quota claude3 claude 30 4
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "claude3 opens when the earlier pools are out: $out"
set_quota claude3 claude 20 4
run "$BRIEF" --task six
assert_contains "$out" 'claude3 weekly floor: 20% left, stops at 25%' "a claude3 start below the floor is stopped: $out"
assert_not_contains "$(chosen)" "claude3" 'the stopped claude3 seat is never the pick'
# A rule that seats claude3 first (the firstmate pattern) skips the worker floor.
reset_quota
set_quota claude3 claude 10 4
write_response rule_7 0.95 '{"rule_1":0.0,"rule_2":0.0,"rule_3":0.0,"rule_4":0.0,"rule_5":0.0,"rule_6":0.0,"rule_7":0.95,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "a tier-1 claude3 seat ignores the worker floor: $out"
# Blends take candidates from the most probable row and bans from every blended row.
# The resolver validates a full probability map, so every blend completes the rest at 0.
blend() { write_response "$1" 0.55 "$(jq -cn --argjson over "$2" '[["rule_1",0],["rule_2",0],["rule_3",0],["rule_4",0],["rule_5",0],["rule_6",0],["rule_7",0],["default",0]] | reduce .[] as [$k, $v] ($over; .[$k] = ($over[$k] // $v))')"; reset_quota; }
blend rule_6 '{"rule_1":0.40,"rule_6":0.55,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "the hard-bug blend clears: $out"
assert_contains "$out" 'model fable is banned for this work (never_models)' "the security row never_models reaches the anchor: $out"
assert_contains "$(chosen)" "--model 'opus'" "the blend starts Opus, never Fable: $out"
assert_not_contains "$(chosen)" "fable" 'no Fable seat wins the blend'
blend rule_6 '{"rule_2":0.40,"rule_6":0.55,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$out" 'model fable is banned for this work (never_models)' "the planning row ban blends the same way: $out"
blend rule_6 '{"rule_3":0.40,"rule_6":0.55,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$out" 'model fable is banned for this work (never_models)' "the design row ban blends without never_providers: $out"
blend rule_5 '{"rule_4":0.40,"rule_5":0.55,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--model 'opus'" "the lavish blend keeps the anchor candidates: $out"
assert_contains "$(chosen)" "--effort 'medium'" "the anchor row sets the effort: $out"
blend rule_1 '{"rule_1":0.55,"rule_6":0.40,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--model 'opus'" "a security anchor never lists Fable: $out"
assert_not_contains "$out" 'fable' 'the anchor pool alone decides, so no Fable line appears'
# ladder_policy.fable_projects is optional: declared, it gates; absent, it restricts nothing.
reset_quota
write_response rule_6 0.95 '{"rule_1":0.0,"rule_2":0.0,"rule_3":0.0,"rule_4":0.0,"rule_5":0.0,"rule_6":0.95,"rule_7":0.0,"default":0.05}'
run "$BRIEF" --task six
assert_contains "$out" 'fable is reserved for projects in ladder_policy.fable_projects; project unset is not one of them' "a declared allowlist gates an unnamed project: $out"
assert_contains "$(chosen)" "--model 'opus'" "the gated Fable seat loses to Opus: $out"
run "$BRIEF" --task six --project geris
assert_contains "$out" 'fable is reserved for projects in ladder_policy.fable_projects; project geris is not one of them' "a client project is named in the gate: $out"
run "$BRIEF" --task six --project firstmate
assert_contains "$(chosen)" "--model 'fable'" "a listed project runs Fable: $out"
jq 'del(.ladder_policy.fable_projects)' "$RULES" > "$TMP_ROOT/rules-lane1"
cp "$TMP_ROOT/rules-lane1" "$RULES"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--model 'fable'" "an absent allowlist never gates (captain option B): $out"
# Malformed declarations are configuration errors.
jq '.rules[5].never_models = ["fable"]' "$TMP_ROOT/rules-lane1" > "$RULES"
run rows --json
expect_code 2 "$code" "a self-banning rule is a configuration error: $out"
assert_contains "$out" 'a rule lists a profile of a model its own never_models bans: rule 6 claude:fable' 'the self-ban error names the rule and model'
jq '.claude3_policy.weekly_floor_percent = 150' "$TMP_ROOT/rules-lane1" > "$RULES"
run rows --json
expect_code 2 "$code" 'an out-of-range claude3 floor is a configuration error'
assert_contains "$out" 'claude3_policy needs worker_rows' 'the claude3_policy error is actionable'
jq '.ladder_policy.fable_projects = []' "$TMP_ROOT/rules-lane1" > "$RULES"
run rows --json
expect_code 2 "$code" 'an empty allowlist is a configuration error'
assert_contains "$out" 'ladder_policy needs fable_projects' 'the ladder_policy error is actionable'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S10: claude3 seats hold behind the worker tiers under their weekly floor, blended never_models bans reach the anchor, and fable_projects stays an optional allowlist'

# ---- S12: worker_banned_accounts - claude3 is never a worker or pipeline seat ----
# Captain 2026-11-12: claude3 is reserved for firstmate and secondmates. The
# orchestration row (rule_7) seats claude3 first, and Jev sometimes picks it for
# an ordinary worker brief. The ban sits on the candidates, not on the row
# choice: whatever row matched, a worker, a scout and every pipeline step skip
# the banned account, and only a secondmate charter may still take it.
jq '.worker_banned_accounts = ["claude3"]
  | .pipeline_rows = [{"steps":["review"],"never_providers":["zai"],"use":[
      {"harness":"claude","model":"opus","effort":"medium","account":"claude3","pool":1,"seat_tier":1,"reasoning_class":4},
      {"harness":"claude","model":"opus","effort":"medium","account":"claude1","pool":2,"seat_tier":2,"reasoning_class":4}]}]' "$TMP_ROOT/rules-lane1" > "$TMP_ROOT/rules-ban"
cp "$TMP_ROOT/rules-ban" "$RULES"
reset_quota
set_quota claude3 claude 95 9
write_response rule_7 0.95 '{"rule_1":0.0,"rule_2":0.0,"rule_3":0.0,"rule_4":0.0,"rule_5":0.0,"rule_6":0.0,"rule_7":0.95,"default":0.05}'
# A worker brief matched to the orchestration row lands on the next tier.
run "$BRIEF" --task six-ban
expect_code 0 "$code" "a worker brief on the orchestration row still dispatches: $out"
assert_not_contains "$(chosen)" 'claude3' "the worker never takes claude3: $out"
assert_contains "$(chosen)" "--account 'claude" 'the worker lands on a claude1 or claude2 seat'
assert_contains "$out" 'account claude3 is banned for worker tasks (worker_banned_accounts)' "the claude3 candidate names the ban: $out"
# A scout brief is a worker too.
printf '# Task\n## Captain%s intent\nLook around.\n## Firstmate spec\nReport only.\nThis is a SCOUT task: the deliverable is a written report, not a PR.\n' "'" > "$HOME_DIR/data/scout-brief.md"
run "$HOME_DIR/data/scout-brief.md" --task six-ban-scout
assert_not_contains "$(chosen)" 'claude3' "a scout never takes claude3: $out"
# A secondmate charter keeps the orchestration seat.
printf 'You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.\n\n# Charter\nOrchestrate.\n' > "$HOME_DIR/data/charter-brief.md"
run "$HOME_DIR/data/charter-brief.md" --task six-ban-sm
expect_code 0 "$code" "a secondmate charter resolves: $out"
assert_contains "$(chosen)" "--account 'claude3'" "a secondmate charter may still take claude3: $out"
# The default row is covered as well as the orchestration row.
jq '.default = [{"harness":"claude","model":"opus","effort":"medium","account":"claude3","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":2,"reasoning_class":4}]' "$TMP_ROOT/rules-ban" > "$RULES"
write_response default 0.95 '{"rule_1":0.0,"rule_2":0.0,"rule_3":0.0,"rule_4":0.0,"rule_5":0.0,"rule_6":0.0,"rule_7":0.0,"default":1.0}'
run "$BRIEF" --task six-ban-default
assert_not_contains "$(chosen)" 'claude3' "the default row never gives a worker claude3: $out"
# A no-mistakes pipeline step never picks claude3, even as the only tier-1 seat.
cp "$TMP_ROOT/rules-ban" "$RULES"
pipe review
expect_code 0 "$code" "the pipeline step resolves: $pout $perr"
assert_equals 'claude1' "$(pfield .seat)" 'the pipeline step skips the banned seat'
assert_contains "$(pfield '[.candidates[] | select(.seat == "claude3") | .reason] | first')" 'worker_banned_accounts' 'the pipeline candidate names the ban'
# Load checks: the key must be a non-empty array of account IDs.
for bad in '[]' '"claude3"' '[3]' '["Claude 3"]'; do
  jq --argjson b "$bad" '.worker_banned_accounts = $b' "$TMP_ROOT/rules-ban" > "$RULES"
  run rows --json
  expect_code 2 "$code" "worker_banned_accounts $bad is a configuration error"
  assert_contains "$out" 'worker_banned_accounts must be a non-empty array of account IDs' "worker_banned_accounts $bad error is actionable: $out"
done
cp "$TMP_ROOT/rules-original" "$RULES"
reset_quota
pass 'S12: worker_banned_accounts keeps claude3 off every worker, scout, default and pipeline seat while a secondmate charter keeps it'

# ---- S11: lane 3 resolver - the escalation ladder with per-task capability history ----
# A task starts on its rule's own use list (k=0) and runs rung start+k of its
# ladder after k recorded capability failures. Unknown attempts, stalls, crashes
# and usage limits never advance it. Fable starts at medium, tops out at high on
# the top rung only, and is gated by no repository unless fable_projects says so.
HIST="$ROOT/bin/fm-task-history.sh"
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "claude3_policy":{"worker_rows":"later seat tier only","weekly_floor_percent":25},
 "ladder_policy":{"counts":"capability_failures","tie_band_points":2,"beyond_ceiling":"escalate","jev_never_escalates":true},
 "ladder_rungs":[
  {"rung":3,"name":"Build","claude":[{"harness":"claude","model":"sonnet","effort":"high"}],
   "codex":[{"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"medium"}],
   "zai":[{"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"max"}]},
  {"rung":4,"name":"Solid","claude":[{"harness":"claude","model":"opus","effort":"medium"}],
   "codex":[{"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"high"}],"zai":[]},
  {"rung":5,"name":"Hard","claude":[{"harness":"claude","model":"fable","effort":"medium"},{"harness":"claude","model":"opus","effort":"high"}],
   "codex":[{"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"max"}],"zai":[],
   "claude_written":[{"harness":"claude","model":"opus","effort":"high"}]},
  {"rung":6,"name":"Top","claude":[{"harness":"claude","model":"fable","effort":"high"}],"codex":[],"zai":[]}],
 "capability":{
  "claude/sonnet:high":{"index":41.5,"terminal_bench":43.9,"gdpval":1557},
  "claude/opus:medium":{"index":48.2,"terminal_bench":52.5,"gdpval":1593},
  "claude/opus:high":{"index":51.8,"terminal_bench":56.6,"gdpval":1714},
  "claude/fable:medium":{"index":56.4,"terminal_bench":55.1,"gdpval":1591},
  "claude/fable:high":{"index":61.8,"terminal_bench":59.6,"gdpval":1718},
  "codex/gpt-6.1-sol:medium":{"index":46.3,"terminal_bench":48.0,"gdpval":1459},
  "codex/gpt-6.1-sol:high":{"index":50.3,"terminal_bench":51.5,"gdpval":1520},
  "codex/gpt-6.1-sol:max":{"index":54.6,"terminal_bench":56.1,"gdpval":1608},
  "zai/glm-5.3:max":{"index":31.7,"terminal_bench":41.9,"gdpval":1657}},
 "default_ladder":{"start":3,"ceiling":4,"lens":"technical","claude_first":false},
 "rules":[
  {"when":"Implement a settled spec","ladder":{"start":3,"ceiling":5,"lens":"technical","claude_first":false},"use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","seat_tier":1,"reasoning_class":4},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"medium","account":"codex1","seat_tier":1,"reasoning_class":4},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"max","account":"glm","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude3","seat_tier":2,"reasoning_class":4}]},
  {"when":"Hard bug","ladder":{"start":4,"ceiling":6,"lens":"technical","claude_first":true},"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":5},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"high","account":"codex1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude3","seat_tier":2,"reasoning_class":5}]},
  {"when":"Security change","never_models":["fable"],"never_providers":["zai"],"ladder":{"start":4,"ceiling":5,"lens":"technical","claude_first":true},"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":5},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":5}]},
  {"when":"Written report","ladder":{"start":4,"ceiling":5,"lens":"written","claude_first":false},"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":1,"reasoning_class":4}]}],
 "default":[
  {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":4},
  {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","seat_tier":1,"reasoning_class":4}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-ladder"
reset_quota
printf '0\n' > "$HOME_DIR/state/dispatch-tie-round-robin"
run rows --json
expect_code 0 "$code" "the ladder table passes the load checks: $out"
P_SONNET='{"harness":"claude","model":"sonnet","effort":"high","account":"claude1"}'
P_OPUS_HIGH='{"harness":"claude","model":"opus","effort":"high","account":"claude1"}'
P_FABLE='{"harness":"claude","model":"fable","effort":"medium","account":"claude1"}'
fail_attempt() { FM_STATE_OVERRIDE="$HOME_DIR/state" "$HIST" append "$1" relaunch --reason "$2" --attempt "$3" --profile "$4" >/dev/null || fail "history append failed for $1"; }
resp_row() { write_response "$1" 0.96 "$(jq -cn --arg r "$1" '["rule_1","rule_2","rule_3","rule_4","default"] | map({(.): (if . == $r then 0.96 else 0.01 end)}) | add')"; }
# k=0: no history, and history made only of unknown attempts and stalls, keep the rule's own use list.
resp_row rule_1
run "$BRIEF" --task lad0
assert_contains "$out" 'status: clear' "no history clears from the rule's own list: $out"
assert_not_contains "$out" 'escalation ladder' 'k=0 never mentions the ladder'
assert_contains "$out" 'candidate: pi:zai/glm-5.3' 'k=0 still lists the rule GLM seat'
fail_attempt lad0 unknown a1 "$P_SONNET"
fail_attempt lad0 infra a2 "$P_SONNET"
fail_attempt lad0 usage-limit a3 "$P_SONNET"
FM_STATE_OVERRIDE="$HOME_DIR/state" "$HIST" append lad0 stall-escalation --attempt a4 >/dev/null
FM_STATE_OVERRIDE="$HOME_DIR/state" "$HIST" append lad0 stall-escalation --attempt a5 >/dev/null
run "$BRIEF" --task lad0
assert_not_contains "$out" 'escalation ladder' 'unknown, infra, usage-limit and stall history never advances the ladder'
assert_contains "$out" 'candidate: pi:zai/glm-5.3' 'the unproven history keeps the rule list'
# One capability failure: rung start+1 for every family the rule lists, no GLM
# (rung 4 has none), accounts and tiers from the rule, the failed profile beaten.
fail_attempt lad1 capability a1 "$P_SONNET"
run "$BRIEF" --task lad1
assert_contains "$out" 'status: clear' "one capability failure clears on the next rung: $out"
assert_contains "$out" 'escalation ladder: 1 capability failure(s), rung 4 (Solid) of the 3-5 ladder' "the note names the rung: $out"
assert_contains "$out" 'candidate: claude:opus' 'the Claude family moves to Opus'
assert_not_contains "$out" 'candidate: claude:sonnet' 'the failed Sonnet is gone'
assert_not_contains "$out" 'candidate: pi:zai/glm-5.3' 'a rung with no GLM profile drops the family'
assert_contains "$out" 'account=claude3  provider=claude' 'claude3 keeps its later pool from the rule'
assert_not_contains "$out" 'account=codex2  provider=codex' 'a rung never adds an account the rule does not list'
assert_equals rule_1 "$(jq -r '.row.id' "$(latest)")" 'the receipt records the matched row, not a ladder row'
assert_equals false "$(jq -r '.profile.model == "sonnet"' "$(latest)")" 'the receipt profile is a rung-4 profile, never the failed Sonnet'
# A second recorded capability failure moves up one more rung.
fail_attempt lad1 capability a2 '{"harness":"claude","model":"opus","effort":"medium","account":"claude2"}'
run "$BRIEF" --task lad1
assert_contains "$out" 'escalation ladder: 2 capability failure(s), rung 5 (Hard)' "two failures reach rung 5: $out"
assert_contains "$out" 'candidate: claude:fable' 'rung 5 offers Fable first on every repository'
assert_not_contains "$out" 'candidate: claude:opus' 'the first allowed Fable preference wins over the Opus fallback'
# Past the ceiling the captain decides.
fail_attempt lad1 capability a3 "$P_FABLE"
run "$BRIEF" --task lad1
assert_contains "$out" 'status: captain-pick' "past the ceiling the resolver hands over: $out"
assert_contains "$out" 'past its ladder ceiling (rung 5)' "the reason names the ceiling: $out"
# Attempts are counted once: a retried attempt id is the same failure.
fail_attempt lad2 capability a1 "$P_SONNET"
fail_attempt lad2 capability a1 "$P_SONNET"
run "$BRIEF" --task lad2
assert_contains "$out" 'escalation ladder: 1 capability failure(s)' "one attempt id is one failure: $out"
# never_models and never_providers drop the Fable and GLM preferences of a rung.
resp_row rule_3
fail_attempt lad3 capability a1 '{"harness":"claude","model":"opus","effort":"medium","account":"claude1"}'
run "$BRIEF" --task lad3
assert_contains "$out" 'escalation ladder: 1 capability failure(s), rung 5' "the security ladder starts at rung 4 and moves to 5: $out"
assert_not_contains "$out" 'candidate: claude:fable' 'a never_models row never gets Fable from the ladder'
assert_contains "$out" 'candidate: claude:opus' 'the Opus high preference runs once Fable is banned'
# A rung whose every allowed profile is the failed one leaves nothing to run: the captain decides.
fail_attempt lad3b capability a1 "$P_OPUS_HIGH"
run "$BRIEF" --task lad3b
assert_contains "$out" 'status: captain-pick' "no profile beats a failed Opus high on a Fable-banned row: $out"
assert_contains "$out" 'beats the 1 failed profile(s)' 'the reason names the capability bar'
# The lens decides which profiles beat the failed one: a failed Opus high (index 51.8)
# is beaten by Fable but not by another Opus high.
resp_row rule_2
fail_attempt lad4 capability a1 '{"harness":"claude","model":"opus","effort":"medium","account":"claude1"}'
run "$BRIEF" --task lad4
assert_contains "$out" 'rung 5' "the claude-first row advances on one failure: $out"
assert_contains "$out" 'candidate: claude:fable' 'Fable beats Opus medium on the technical lens'
assert_contains "$out" 'candidate: pi:openai-codex/gpt-6.1-sol' 'Codex joins at a later seat tier on a claude-first row'
assert_contains "$out" 'seat_tier held' 'claude-first holds the Codex tier behind the Claude seats'
# The written lens uses GDPval and the claude_written list.
resp_row rule_4
fail_attempt lad5 capability a1 '{"harness":"claude","model":"opus","effort":"medium","account":"claude1"}'
run "$BRIEF" --task lad5
assert_contains "$out" 'candidate: claude:opus' "the written lens takes the claude_written Opus list: $out"
assert_not_contains "$out" 'candidate: claude:fable' 'the written lens never takes the technical Fable preference'
# fable_projects stays an optional allowlist: declared, a rung skips Fable for a project outside it.
resp_row rule_2
jq '.ladder_policy.fable_projects = ["firstmate"]' "$TMP_ROOT/rules-ladder" > "$RULES"
run "$BRIEF" --task lad4 --project geris
assert_not_contains "$out" 'candidate: claude:fable' "a declared allowlist keeps Fable off a client repo: $out"
assert_contains "$out" 'candidate: claude:opus' 'the next preference of the rung runs instead'
run "$BRIEF" --task lad4 --project firstmate
assert_contains "$out" 'candidate: claude:fable' "a listed project keeps Fable: $out"
cp "$TMP_ROOT/rules-ladder" "$RULES"
# An unreadable history fails closed to the captain instead of restarting on the lowest rung.
printf 'not json\n' > "$HOME_DIR/state/lad6.history.jsonl"
resp_row rule_1
run "$BRIEF" --task lad6
assert_contains "$out" 'status: captain-pick' "an unreadable history hands over: $out"
assert_contains "$out" 'task routing history for lad6 is unreadable' 'the reason names the task history'
# A row with no ladder of its own runs on default_ladder; the default row too.
resp_row default
fail_attempt lad7 capability a1 "$P_SONNET"
run "$BRIEF" --task lad7
assert_contains "$out" 'escalation ladder: 1 capability failure(s), rung 4 (Solid) of the 3-4 ladder' "the default row uses default_ladder: $out"
fail_attempt lad7 capability a2 '{"harness":"claude","model":"opus","effort":"medium","account":"claude1"}'
run "$BRIEF" --task lad7
assert_contains "$out" 'past its ladder ceiling (rung 4)' "default_ladder has its own ceiling: $out"
# Load refusals: Fable above high, Fable high below the top rung, a ladder on an unknown rung, an unknown ladder key.
jq '.ladder_rungs[2].claude[0].effort = "xhigh"' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'Fable xhigh on a rung is a configuration error'
assert_contains "$out" 'forbidden ladder profile: Fable above high' 'the Fable ceiling is named'
jq '.ladder_rungs[2].claude[0].effort = "high"' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'Fable high below the top rung is a configuration error'
assert_contains "$out" 'Fable high is allowed only on the top ladder rung' 'the top-rung rule is named'
jq '.rules[0].ladder.ceiling = 9' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'a ladder ceiling outside ladder_rungs is a configuration error'
assert_contains "$out" 'start and ceiling must be rungs of ladder_rungs' 'the missing rung is named'
jq '.rules[0].ladder.pace = 1' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'an unknown ladder key is a configuration error'
assert_contains "$out" 'has an unknown key' 'the unknown ladder key is named'
jq '.ladder_policy.counts = "stalls"' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'counting anything but capability failures is a configuration error'
assert_contains "$out" 'counts must be capability_failures' 'the counts rule is named'
jq 'del(.ladder_rungs)' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'a ladder without ladder_rungs is a configuration error'
assert_contains "$out" 'a ladder needs ladder_rungs' 'the missing rungs are named'
jq '.ladder_rungs[3].claude[0].effort = "high" | .rules[1].ladder.start = 6' "$TMP_ROOT/rules-ladder" > "$RULES"
run rows --json
expect_code 2 "$code" 'a ladder may not start on a rung that lists Fable high'
assert_contains "$out" 'Fable starts at medium at most' 'the Fable start rule is named'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S11: the ladder moves only on recorded capability failures, honours bans and lens, fails closed, and loads strictly'

# ---- A: seat lookup and migration ------------------------------------------------
ln -s "$STORES/claude-reserve" "$STORES/claude-reserve-alias"
assert_equals claude-reserve "$(acct fm_account_seat_for_store "$ACCOUNTS" claude "$STORES/claude-reserve-alias")" 'a symlinked alias names its target seat'
assert_equals '' "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi")" 'a shared Pi store names no seat without a provider'
assert_equals glm "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi" zai)" 'the zai provider names the glm seat'
assert_equals codex1 "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi" codex)" 'the codex provider names the codex1 seat'
assert_equals '' "$(acct fm_account_registry_problems "$ACCOUNTS")" 'the six-account registry has no problems'
jq '.accounts.dup = {"provider":"zai","pi":"'"$STORES"'/pi/"}' "$ACCOUNTS" > "$TMP_ROOT/dup.json"
assert_contains "$(acct fm_account_registry_problems "$TMP_ROOT/dup.json")" 'both declare provider zai on pi store' 'two seats on one login are reported'
# The coverage audit is asserted against the original six accounts; the S10
# accounts (claude3, codex2) join the registry only for the resolver sections.
jq 'del(.accounts.claude3, .accounts.codex2)' "$ACCOUNTS" > "$TMP_ROOT/accounts-audit"
cp "$TMP_ROOT/accounts-audit" "$ACCOUNTS"
out=$("$ROOT/bin/fm-account-routing.sh" audit 2>&1); code=$?
expect_code 1 "$code" "the audit fails on a coverage gap: $out"
assert_contains "$out" 'gap: rule 2 claude:opus/high lacks claude account(s) claude-reserve' 'a rung missing a provider account is named'
assert_contains "$out" 'single point: provider zai has one account (glm)' 'a single-account provider is noted'
assert_not_contains "$out" 'gap: rule 1' 'a fully covered rule is not reported'
cp "$TMP_ROOT/accounts-original" "$ACCOUNTS"
RC="$TMP_ROOT/recent.json"
snap claude 40 3 > "$TMP_ROOT/good.json"
qlib fm_quota_recent_save "$RC" "$TMP_ROOT/good.json" "$STORES/claude-reserve" "$STORES/pi" "$STORES/codex1"
jq '.providers[0] |= (.state = {status:"rate_limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$TMP_ROOT/good.json" > "$TMP_ROOT/limited.json"
assert_equals 3 "$(qlib fm_quota_recent_merge "$RC" "$TMP_ROOT/limited.json" "$STORES/claude-reserve" - - | jq '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority')" \
  'a Claude row read through the home default answers for the claude-reserve seat on the same login'
assert_equals null "$(qlib fm_quota_recent_merge "$RC" "$TMP_ROOT/limited.json" "$STORES/claude2" - - | jq '.providers[0].reusedReading')" \
  'another login never borrows that reading'
pass 'A: provider-aware, symlink-canonical seat lookup and registry problems'
pass 'S7: the coverage audit names rungs missing an account and single-account providers'

MIG="$ROOT/bin/fm-account-migrate.sh"
has_line() { grep -qxF -- "$1" "$2" || fail "$3 (no line '$1' in $(basename "$2"): $(tr '\n' ' ' < "$2"))"; }
OLD="$TMP_ROOT/old-stores"
mkdir -p "$OLD/claude-old" "$OLD/codex-old" "$OLD/pi-old/agent"
STATE_DIR="$HOME_DIR/state"
printf 'harness=claude\nmodel=opus\naccount=legacy\nseat=legacy\nclaude_config_dir=%s\n' "$OLD/claude-old" > "$STATE_DIR/m-claude.meta"
printf 'harness=pi\nmodel=openai-codex/gpt-6.1-sol\naccount=legacy\npi_agent_dir=%s\ncodex_home=%s\n' "$OLD/pi-old/agent" "$OLD/codex-old" > "$STATE_DIR/m-codex.meta"
printf 'harness=pi\nmodel=zai/glm-5.3\npi_agent_dir=%s\n' "$STORES/pi" > "$STATE_DIR/m-zai.meta"
printf 'harness=claude\nmodel=sonnet\nclaude_config_dir=%s\n' "$STORES/claude-reserve" > "$STATE_DIR/m-unnamed.meta"
printf '%s\n' "$OLD/pi-old/agent" 'openai-codex' > "$HOME_DIR/config/pi-account"
chmod 600 "$STATE_DIR"/m-*.meta
args=(--id legacy:claude=claude-reserve --id legacy:codex=codex1 --id -:claude=claude1 --id -:zai=glm
      --path "$OLD/codex-old=$STORES/codex1" --path "$OLD/pi-old/agent=$STORES/pi")
before=$(cat "$STATE_DIR/m-claude.meta")
out=$("$MIG" "${args[@]}" 2>&1); code=$?
expect_code 0 "$code" "dry run: $out"
assert_contains "$out" 'dry run, 5 file(s) would change' 'the dry run counts the changes'
assert_equals "$before" "$(cat "$STATE_DIR/m-claude.meta")" 'the dry run writes nothing'
env CODEX_HOME="$OLD/codex-old" sleep 30 &
live=$!
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
expect_code 2 "$code" 'apply refuses while a worker runs on an old store'
assert_contains "$out" 'a live worker still runs on an old store' 'the live worker is named'
assert_equals "$before" "$(cat "$STATE_DIR/m-claude.meta")" 'the refusal writes nothing'
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
expect_code 0 "$code" "apply after the drain: $out"
assert_contains "$out" 'applied 5 file change(s)' 'the apply reports its count'
has_line 'account=claude-reserve' "$STATE_DIR/m-claude.meta" 'the old Claude id becomes claude-reserve'
has_line 'seat=claude-reserve' "$STATE_DIR/m-claude.meta" 'the seat follows'
has_line "claude_config_dir=$STORES/claude-reserve" "$STATE_DIR/m-claude.meta" 'the store follows the new seat'
has_line 'account=codex1' "$STATE_DIR/m-codex.meta" 'the same old id splits by provider'
has_line "pi_agent_dir=$STORES/pi" "$STATE_DIR/m-codex.meta" 'the launch store is the new seat store'
has_line "codex_home=$STORES/codex1" "$STATE_DIR/m-codex.meta" 'other store keys follow the path map'
has_line 'account=glm' "$STATE_DIR/m-zai.meta" 'an unnamed zai record binds to glm'
has_line 'account=claude1' "$STATE_DIR/m-unnamed.meta" 'an unnamed Claude record binds to claude1'
has_line "claude_config_dir=$STORES/claude1" "$STATE_DIR/m-unnamed.meta" 'and relaunches on claude1'
assert_equals "$STORES/pi" "$(sed -n 1p "$HOME_DIR/config/pi-account")" 'the pin file path is rewritten'
assert_equals openai-codex "$(sed -n 2p "$HOME_DIR/config/pi-account")" 'the pin provider line is kept'
assert_equals 600 "$(stat -c %a "$STATE_DIR/m-claude.meta")" 'record modes are kept'
backup=$(find "$STATE_DIR/account-migrate" -mindepth 1 -maxdepth 1 -type d | head -1)
has_line 'account=legacy' "$backup/state/m-claude.meta" 'the original record is backed up'
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
assert_contains "$out" 'nothing to change' 're-running is a no-op'
pass 'A: the one-shot migration splits an old id by provider, follows paths, backs up, refuses live workers, and is idempotent'

echo '# all fm-dispatch-six-accounts tests passed'
