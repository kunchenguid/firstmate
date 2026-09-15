#!/usr/bin/env bash
# Behavior tests for bin/fm-review-pin.sh: quota-aware walk of the accepted
# review-agent list, the shared no-mistakes pin write and restore, the pin
# record, and the in-flight and held refusals. Everything runs against fixture
# homes under a temp root; NM_HOME is always redirected so the real
# ~/.no-mistakes is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-review-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-pin)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'skip: sqlite3 not found\n'; exit 0; }

# --- fixtures ---------------------------------------------------------------

# A live-shaped accepted list: Pi Sol, Claude Opus, Pi Grok, then a Cursor
# group carrying the same three models.
write_accepted_list() {  # <path>
  cat > "$1" <<'JSON'
{
  "codexReviewFloorPercent": 20,
  "default": [
    { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "effort": "high" },
    { "harness": "claude", "model": "opus-5", "effort": "high" },
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" },
    {
      "harness": "cursor",
      "use": [
        { "model": "gpt-5.6-sol-high" },
        { "model": "claude-opus-5-thinking-high" },
        { "model": "cursor-grok-4.6-medium" }
      ]
    }
  ]
}
JSON
}

# quota_row <provider> <pct> <runway> prints one known provider entry.
quota_row() {
  jq -n --arg provider "$1" --argjson pct "$2" --arg runway "$3" '{
    provider: $provider,
    windows: [],
    state: {status: "fresh", stale: false},
    quotaSemantics: {
      status: "known",
      effectiveAvailability: [
        {scope: (if $provider == "grok" then "all_products" else "all_models" end),
         status: "known", effectivePercentRemaining: $pct, runway: {status: $runway}}
      ]
    }
  }'
}

# write_quota <path> <codex pct> <codex runway> <claude pct> <claude runway>
#             <grok pct> <grok runway> <cursor pct> <cursor runway>
write_quota() {
  local path=$1
  shift
  jq -n \
    --argjson codex "$(quota_row codex "$1" "$2")" \
    --argjson claude "$(quota_row claude "$3" "$4")" \
    --argjson grok "$(quota_row grok "$5" "$6")" \
    --argjson cursor "$(quota_row cursor "$7" "$8")" \
    '{generatedAt: "2030-01-01T00:00:00Z", schemaVersion: 5, providers: [$codex, $claude, $grok, $cursor]}' \
    > "$path"
}

write_nm_config() {  # <path>
  cat > "$1" <<'EOF'
# no-mistakes global configuration

# Agent to use for code generation
# Options: auto, claude, codex, pi
agent: pi

# Optional path to the user-installed acpx binary
# acpx_path: acpx

ci_timeout: "168h"

# Extra native agent CLI flags (optional, global only)
# Temporary: review via Pi Grok 4.6 while Claude spend is exhausted.
agent_args_override:
  pi:
    - --model
    - xai/grok-4.6
#
# Maximum follow-up auto-fix attempts per step
auto_fix:
  rebase: 3
  review: 0

intent:
  enabled: true
EOF
}

write_nm_db() {  # <path>
  sqlite3 "$1" "
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL DEFAULT 'pending');
    CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
                               step_order INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending');"
}

# add_run <db> <run id> <run status> <review step status> <ci step status>
add_run() {
  sqlite3 "$1" "
    INSERT INTO runs VALUES ('$2', 'repo', 'fm/$2', '$3');
    INSERT INTO step_results VALUES ('$2-review', '$2', 'review', 3, '$4');
    INSERT INTO step_results VALUES ('$2-ci', '$2', 'ci', 9, '$5');"
}

# new_world <name>: builds FM_HOME and NM_HOME fixtures, exporting WORLD, HOME_DIR,
# NM_DIR, and NM_CONFIG for the caller.
new_world() {
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  NM_DIR="$WORLD/nm"
  NM_CONFIG="$NM_DIR/config.yaml"
  mkdir -p "$HOME_DIR/config" "$NM_DIR"
  write_accepted_list "$HOME_DIR/config/review-dispatch.json"
  write_nm_config "$NM_CONFIG"
  write_nm_db "$NM_DIR/state.sqlite"
}

run_pin() {  # <args...>; sets OUT, ERR, STATUS
  STATUS=0
  OUT=$(FM_HOME="$HOME_DIR" NM_HOME="$NM_DIR" "$PIN" "$@" 2>"$WORLD/err") || STATUS=$?
  ERR=$(cat "$WORLD/err")
}

# --- resolve ----------------------------------------------------------------

test_resolve_walks_the_accepted_order() {
  new_world resolve
  local q="$WORLD/q.json"

  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  expect_code 0 "$STATUS" "healthy codex picks Sol"
  assert_equals "pi openai-codex/gpt-5.6-sol high" "$OUT" "Sol is first when codex is healthy"
  assert_contains "$ERR" "pick pi openai-codex/gpt-5.6-sol high: codex all_models 60% through_reset" "pick reason names the codex row"

  write_quota "$q" 15 through_reset 50 through_reset 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  expect_code 0 "$STATUS" "codex under the floor still resolves"
  assert_equals "claude opus-5 high" "$OUT" "codex under 20% skips Sol for Opus"
  assert_contains "$ERR" "skip pi openai-codex/gpt-5.6-sol high: codex all_models 15% is under the review floor 20%" "skip reason names the floor"

  write_quota "$q" 60 projected_exhaustion 50 through_reset 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  assert_equals "claude opus-5 high" "$OUT" "codex that will run out before reset skips Sol even at 60%"
  assert_contains "$ERR" "will run out before reset" "projected exhaustion is the stated reason"

  write_quota "$q" 60 through_reset 50 projected_exhaustion 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  assert_equals "pi openai-codex/gpt-5.6-sol high" "$OUT" "projected exhaustion is codex-only; Sol still picked"

  write_quota "$q" 10 through_reset 50 projected_exhaustion 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  assert_equals "claude opus-5 high" "$OUT" "claude at 50% with projected exhaustion stays out of the band"

  write_quota "$q" 10 through_reset 10 through_reset 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  assert_equals "pi xai/grok-4.6 medium" "$OUT" "Sol and Opus low falls to Pi Grok"
  assert_contains "$ERR" "skip claude opus-5 high: claude all_models 10% is in the low-tank band (under 20%)" "band reason names the default band edge"

  write_quota "$q" 10 through_reset 0 exhausted_now 5 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  assert_equals "cursor gpt-5.6-sol-high -" "$OUT" "all three low reaches the Cursor group's first model"
  assert_contains "$ERR" "skip claude opus-5 high: claude all_models exhausted" "exhausted_now is reported as exhausted"
  assert_contains "$ERR" "pick cursor gpt-5.6-sol-high -: cursor all_models 80% through_reset" "group member is judged on the cursor row"

  write_quota "$q" 10 through_reset 10 through_reset 5 through_reset 0 exhausted_now
  run_pin resolve --snapshot "$q"
  expect_code 1 "$STATUS" "nothing eligible exits 1"
  assert_equals "none" "$OUT" "nothing eligible prints none"
  assert_contains "$ERR" "skip cursor cursor-grok-4.6-medium -: cursor all_models exhausted" "every group member is accounted for"

  pass "resolve walks the accepted order with the codex floor, the band, and the group"
}

test_resolve_treats_unknown_quota_as_eligible() {
  new_world unknown
  local q="$WORLD/q.json"
  jq -n \
    --argjson codex "$(quota_row codex 10 through_reset)" \
    --argjson claude "$(quota_row claude 10 through_reset)" \
    '{generatedAt: "2030-01-01T00:00:00Z", schemaVersion: 5, providers: [$codex, $claude]}' > "$q"
  run_pin resolve --snapshot "$q"
  expect_code 0 "$STATUS" "unknown grok quota resolves"
  assert_equals "pi xai/grok-4.6 medium" "$OUT" "a candidate with no quota row stays eligible"
  assert_contains "$ERR" "quota unknown (quota-axi has no row for provider grok); eligible with disclosed uncertainty" "uncertainty is disclosed"

  jq -n \
    --argjson codex "$(quota_row codex 10 through_reset)" \
    --argjson claude "$(quota_row claude 10 through_reset)" \
    --argjson grok "$(quota_row grok 5 through_reset)" \
    '{generatedAt: "2030-01-01T00:00:00Z", schemaVersion: 5,
      providers: [$codex, $claude, $grok,
        {provider: "cursor", windows: [], state: {status: "auth_required", stale: false, error: "Cursor sign-in required"},
         quotaSemantics: {status: "unknown", effectiveAvailability: []}}]}' > "$q"
  run_pin resolve --snapshot "$q"
  assert_equals "cursor gpt-5.6-sol-high -" "$OUT" "an unmeasured provider stays eligible"
  assert_contains "$ERR" "quota-axi state auth_required: Cursor sign-in required" "the provider state is disclosed"

  pass "unknown quota keeps a candidate eligible with the uncertainty stated"
}

test_resolve_honors_explicit_provider_floor_and_band() {
  new_world explicit
  local q="$WORLD/q.json"
  cat > "$HOME_DIR/config/review-dispatch.json" <<'JSON'
{
  "codexReviewFloorPercent": 50,
  "lowTankPercent": 30,
  "default": [
    { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "effort": "high" },
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium", "provider": "cursor" },
    { "harness": "claude", "model": "opus-5" }
  ]
}
JSON
  write_quota "$q" 40 through_reset 90 through_reset 90 through_reset 25 through_reset
  run_pin resolve --snapshot "$q"
  expect_code 0 "$STATUS" "explicit floors resolve"
  assert_equals "claude opus-5 -" "$OUT" "configured floor and band skip the first two; effort-less pick prints -"
  assert_contains "$ERR" "codex all_models 40% is under the review floor 50%" "configured codex floor is honored"
  assert_contains "$ERR" "skip pi xai/grok-4.6 medium: cursor all_models 25% is in the low-tank band (under 30%)" "explicit provider and band edge are honored"
  pass "explicit provider, codexReviewFloorPercent, and lowTankPercent are honored"
}

test_resolve_skips_locked_agents_for_a_repo() {
  new_world locked
  local q="$WORLD/q.json" repo="$WORLD/repo"
  mkdir -p "$repo"
  printf 'disable_project_settings: true\n' > "$repo/.no-mistakes.yaml"
  write_quota "$q" 10 through_reset 10 through_reset 5 through_reset 80 through_reset

  run_pin resolve --snapshot "$q"
  assert_equals "cursor gpt-5.6-sol-high -" "$OUT" "without --repo the Cursor group is picked"

  run_pin resolve --snapshot "$q" --repo "$repo"
  expect_code 1 "$STATUS" "a locked repo leaves nothing eligible"
  assert_equals "none" "$OUT" "locked repo prints none"
  assert_contains "$ERR" "skip cursor gpt-5.6-sol-high -: repo sets disable_project_settings: true" "lock reason is stated"

  printf 'disable_project_settings: false\n' > "$repo/.no-mistakes.yaml"
  run_pin resolve --snapshot "$q" --repo "$repo"
  assert_equals "cursor gpt-5.6-sol-high -" "$OUT" "an explicit false does not lock"
  pass "--repo skips agents no-mistakes refuses under disable_project_settings"
}

test_resolve_reads_one_snapshot_from_quota_axi() {
  new_world snapshot
  local fakebin="$WORLD/fakebin" calls="$WORLD/calls"
  mkdir -p "$fakebin"
  write_quota "$WORLD/live.json" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  cat > "$fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
cat '$WORLD/live.json'
EOF
  chmod 0755 "$fakebin/quota-axi"
  STATUS=0
  OUT=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" NM_HOME="$NM_DIR" "$PIN" resolve 2>"$WORLD/err") || STATUS=$?
  expect_code 0 "$STATUS" "resolve without --snapshot"
  assert_equals "pi openai-codex/gpt-5.6-sol high" "$OUT" "live snapshot resolves"
  assert_equals "--json" "$(cat "$calls")" "exactly one quota-axi --json call"
  pass "omitting --snapshot takes exactly one quota-axi --json snapshot"
}

test_resolve_rejects_bad_input() {
  new_world bad
  local q="$WORLD/q.json"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset

  printf '{"default": []}\n' > "$HOME_DIR/config/review-dispatch.json"
  run_pin resolve --snapshot "$q"
  expect_code 2 "$STATUS" "empty accepted list"
  assert_contains "$ERR" "invalid accepted list" "empty list is a configuration error"

  printf '{"default": [{"harness": "pi", "model": "x", "effort": "turbo"}]}\n' > "$HOME_DIR/config/review-dispatch.json"
  run_pin resolve --snapshot "$q"
  expect_code 2 "$STATUS" "unknown effort"

  printf '{"default": [{"harness": "kimi", "model": "k2"}]}\n' > "$HOME_DIR/config/review-dispatch.json"
  run_pin resolve --snapshot "$q"
  expect_code 2 "$STATUS" "harness without a no-mistakes agent"
  assert_contains "$ERR" "harness kimi has no no-mistakes agent" "unmapped harness is named"

  write_accepted_list "$HOME_DIR/config/review-dispatch.json"
  printf 'not json\n' > "$q"
  run_pin resolve --snapshot "$q"
  expect_code 2 "$STATUS" "malformed snapshot"
  assert_contains "$ERR" "invalid quota-axi JSON snapshot" "malformed snapshot is named"

  rm -f "$HOME_DIR/config/review-dispatch.json"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  run_pin resolve --snapshot "$q"
  expect_code 2 "$STATUS" "absent accepted list"
  assert_contains "$ERR" "is absent" "absent list is reported, never invented"

  run_pin pin --snapshot "$q"
  expect_code 2 "$STATUS" "pin without --task"
  run_pin bogus
  expect_code 2 "$STATUS" "unknown command"
  pass "malformed configuration, snapshot, and usage are errors, not selections"
}

# --- pin and restore --------------------------------------------------------

test_pin_writes_the_shared_pin_and_restore_puts_it_back() {
  new_world pin
  local q="$WORLD/q.json" original="$WORLD/original.yaml" record="$NM_DIR/firstmate-review-pin"
  write_quota "$q" 15 through_reset 50 through_reset 70 through_reset 80 through_reset
  cp "$NM_CONFIG" "$original"
  chmod 0644 "$NM_CONFIG"

  run_pin status
  assert_equals "free"$'\n'"in-flight: none" "$OUT" "status starts free"

  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "pin"
  assert_equals "claude opus-5 high" "$OUT" "pin prints the pinned tuple"
  assert_equals 1 "$(grep -c '^agent:' "$NM_CONFIG")" "exactly one top-level agent key"
  assert_grep 'agent: claude' "$NM_CONFIG" "agent is pinned"
  assert_grep '    model: opus-5' "$NM_CONFIG" "model reaches agent_config"
  assert_grep '    effort: high' "$NM_CONFIG" "effort reaches agent_config"
  assert_no_grep 'agent_args_override:' "$NM_CONFIG" "agent_args_override is suspended while pinned"
  assert_no_grep 'xai/grok-4.6' "$NM_CONFIG" "the hand override no longer beats the pin"
  assert_grep 'ci_timeout: "168h"' "$NM_CONFIG" "unrelated keys survive"
  assert_grep '  rebase: 3' "$NM_CONFIG" "nested unrelated blocks survive"
  assert_grep '# Temporary: review via Pi Grok 4.6' "$NM_CONFIG" "comments survive"
  assert_grep 'project workers must not hand-edit' "$NM_CONFIG" "managed block carries the hand-edit warning"
  assert_equals 644 "$(/usr/bin/stat -f %Lp "$NM_CONFIG" 2>/dev/null || stat -c %a "$NM_CONFIG")" "mode is preserved"
  cmp -s "$original" "$record/previous.yaml" || fail "previous.yaml is not the original bytes"
  cmp -s "$NM_CONFIG" "$record/pinned.yaml" || fail "pinned.yaml is not the live bytes"
  assert_grep 'task=t1' "$record/held" "held record names the task"
  assert_grep "home=$HOME_DIR" "$record/held" "held record names the home"
  assert_absent "$record/lock" "lock is released after pin"

  run_pin status
  assert_contains "$OUT" "held task=t1 home=$HOME_DIR agent=claude model=opus-5 effort=high since=" "status reports the holder"

  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "same task re-pin is a no-op success"
  assert_contains "$ERR" "already pinned by task t1" "no-op is stated"

  run_pin pin --task t2 --snapshot "$q"
  expect_code 3 "$STATUS" "another task cannot pin over a held pin"
  assert_contains "$ERR" "pin held by task t1" "holder is named"
  cmp -s "$NM_CONFIG" "$record/pinned.yaml" || fail "refused pin changed the config"

  run_pin restore --task t2
  expect_code 3 "$STATUS" "another task cannot restore"
  assert_contains "$ERR" "pin held by task t1, not t2" "restore names the holder"

  run_pin restore --task t1
  expect_code 0 "$STATUS" "restore"
  assert_equals "restored" "$OUT" "restore prints restored"
  cmp -s "$original" "$NM_CONFIG" || fail "restore did not put the original bytes back"
  assert_absent "$record/held" "held record is cleared"
  assert_absent "$record/previous.yaml" "previous.yaml is cleared"
  assert_absent "$record/pinned.yaml" "pinned.yaml is cleared"
  run_pin status
  assert_contains "$OUT" "free" "status is free after restore"

  run_pin restore --task t1
  expect_code 3 "$STATUS" "restore with no pin held"
  assert_contains "$ERR" "no pin is held" "no-pin restore is a refusal"
  pass "pin writes the shared no-mistakes pin and restore puts the previous bytes back"
}

test_pin_handles_list_agents_and_effortless_candidates() {
  new_world shapes
  local q="$WORLD/q.json"
  cat > "$NM_CONFIG" <<'EOF'
agent:
- codex
- grok
agent_config:
  codex:
    model: gpt-5.4
    effort: low

  claude:
    model: sonnet
log_level: info
EOF
  write_quota "$q" 10 through_reset 0 exhausted_now 5 through_reset 80 through_reset
  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "pin over a list-valued agent"
  assert_equals "cursor gpt-5.6-sol-high -" "$OUT" "cursor pick"
  assert_equals 1 "$(grep -c '^agent:' "$NM_CONFIG")" "exactly one agent key"
  assert_equals 1 "$(grep -c '^agent_config:' "$NM_CONFIG")" "exactly one agent_config key"
  assert_no_grep '- codex' "$NM_CONFIG" "column-0 list items of the old agent are gone"
  assert_no_grep 'sonnet' "$NM_CONFIG" "the old agent_config block is gone, blank line included"
  assert_grep 'log_level: info' "$NM_CONFIG" "following key survives"
  assert_grep 'agent: cursor' "$NM_CONFIG" "cursor is the agent"
  assert_grep '    model: gpt-5.6-sol-high' "$NM_CONFIG" "cursor model is written"
  assert_no_grep 'effort:' "$NM_CONFIG" "no effort line for an effort-less candidate"
  pass "pin strips list-valued and multi-entry blocks and writes an effort-less candidate"
}

test_pin_and_restore_refuse_while_a_review_is_in_flight() {
  new_world inflight
  local q="$WORLD/q.json" original="$WORLD/original.yaml"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  cp "$NM_CONFIG" "$original"

  add_run "$NM_DIR/state.sqlite" live running fixing pending
  run_pin pin --task t1 --snapshot "$q"
  expect_code 3 "$STATUS" "pin while a review is fixing"
  assert_contains "$ERR" "live fm/live review:fixing" "the in-flight run is listed"
  assert_contains "$ERR" "a review is in flight" "refusal reason"
  cmp -s "$original" "$NM_CONFIG" || fail "refused pin changed the config"
  run_pin status
  assert_contains "$OUT" "in-flight:"$'\n'"  live fm/live review:fixing" "status lists the in-flight run"

  sqlite3 "$NM_DIR/state.sqlite" "UPDATE step_results SET status = 'completed' WHERE run_id = 'live';"
  sqlite3 "$NM_DIR/state.sqlite" "UPDATE step_results SET status = 'pending' WHERE id = 'live-ci';"
  add_run "$NM_DIR/state.sqlite" finished completed completed completed
  add_run "$NM_DIR/state.sqlite" dead failed pending pending
  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "pin when only CI monitoring, completed, and failed runs remain"

  add_run "$NM_DIR/state.sqlite" later running awaiting_approval pending
  run_pin restore --task t1
  expect_code 3 "$STATUS" "restore while a review is parked"
  assert_contains "$ERR" "later fm/later review:awaiting_approval" "the parked run is listed"
  assert_grep 'agent: pi' "$NM_CONFIG" "refused restore left the pin"

  sqlite3 "$NM_DIR/state.sqlite" "UPDATE runs SET status = 'aborted' WHERE id = 'later';"
  run_pin restore --task t1
  expect_code 0 "$STATUS" "restore after the run was aborted"
  cmp -s "$original" "$NM_CONFIG" || fail "restore did not put the original bytes back"
  pass "pin and restore refuse while a review is in flight and allow CI-only runs"
}

test_in_flight_proof_fails_closed() {
  new_world proof
  local q="$WORLD/q.json"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset

  printf 'garbage\n' > "$NM_DIR/state.sqlite"
  run_pin pin --task t1 --snapshot "$q"
  expect_code 3 "$STATUS" "unreadable database refuses"
  assert_contains "$ERR" "cannot prove no review is in flight" "unprovable is a refusal"

  rm -f "$NM_DIR/state.sqlite"
  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "no database means nothing ever ran"

  local sans_sqlite
  sans_sqlite=$(fm_test_base_path_sans "$PATH" sqlite3)
  write_nm_db "$NM_DIR/state.sqlite"
  STATUS=0
  OUT=$(PATH="$sans_sqlite" FM_HOME="$HOME_DIR" NM_HOME="$NM_DIR" "$PIN" restore --task t1 2>"$WORLD/err") || STATUS=$?
  expect_code 3 "$STATUS" "missing sqlite3 refuses"
  assert_contains "$(cat "$WORLD/err")" "sqlite3 is not installed" "missing sqlite3 is named"
  pass "the in-flight proof fails closed on an unreadable database or a missing sqlite3"
}

test_restore_refuses_a_hand_edited_pin() {
  new_world edited
  local q="$WORLD/q.json"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "pin"
  printf 'log_level: debug\n' >> "$NM_CONFIG"
  run_pin restore --task t1
  expect_code 3 "$STATUS" "restore over a hand-edited config"
  assert_contains "$ERR" "changed since the pin was written" "hand edit is named"
  assert_present "$NM_DIR/firstmate-review-pin/held" "record is kept for reconciliation"
  assert_grep 'log_level: debug' "$NM_CONFIG" "the hand edit is left in place"
  run_pin pin --task t1 --snapshot "$q"
  expect_code 3 "$STATUS" "same task cannot silently re-pin over a hand edit"
  pass "restore and re-pin refuse when the live config diverged from the pin"
}

test_pin_lock_is_reclaimed_only_from_a_dead_holder() {
  new_world lock
  local q="$WORLD/q.json" record="$NM_DIR/firstmate-review-pin"
  write_quota "$q" 60 through_reset 50 through_reset 70 through_reset 80 through_reset
  mkdir -p "$record/lock"
  printf '%s\n' "$$" > "$record/lock/pid"
  run_pin pin --task t1 --snapshot "$q"
  expect_code 3 "$STATUS" "live lock holder refuses"
  assert_contains "$ERR" "another pin operation is in progress (pid $$)" "live holder is named"
  assert_present "$record/lock" "live lock is left alone"

  printf '%s\n' 999999 > "$record/lock/pid"
  run_pin pin --task t1 --snapshot "$q"
  expect_code 0 "$STATUS" "dead lock holder is reclaimed"
  assert_absent "$record/lock" "reclaimed lock is released after the operation"
  pass "the pin lock refuses a live holder and reclaims a dead one"
}

test_resolve_walks_the_accepted_order
test_resolve_treats_unknown_quota_as_eligible
test_resolve_honors_explicit_provider_floor_and_band
test_resolve_skips_locked_agents_for_a_repo
test_resolve_reads_one_snapshot_from_quota_axi
test_resolve_rejects_bad_input
test_pin_writes_the_shared_pin_and_restore_puts_it_back
test_pin_handles_list_agents_and_effortless_candidates
test_pin_and_restore_refuse_while_a_review_is_in_flight
test_in_flight_proof_fails_closed
test_restore_refuses_a_hand_edited_pin
test_pin_lock_is_reclaimed_only_from_a_dead_holder
