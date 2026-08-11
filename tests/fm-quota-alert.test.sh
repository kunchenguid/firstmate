#!/usr/bin/env bash
# Behavior tests for custom quota sources and the switch reminder they feed.
#
# End-user reproduction before the change:
# - Initiating input: an afternoon of dispatch onto a gateway-billed identity
#   whose daily spend cap was already reached (2026-07-23, three walls).
# - Expected: firstmate says which lane is exhausted and which identities are
#   still available, before the next crewmate hits the same wall.
# - Observed: nothing in the fleet could read that lane at all, so every wall
#   was discovered after the fact by reading a crewmate's error.
# - Masking condition: quota-axi reports the SUBSCRIPTION lanes fine, so quota
#   looked covered; the gateway lane it cannot see is billed by a third party.
# - Visible symptom: repeated account-wall failures with the switch target
#   worked out by hand each time.
# - Earliest divergence: no config anywhere declared how to read a launch
#   identity's balance, so no consumer could exist.
# - Smallest counterfactual: the same day's readings were available from a local
#   command the whole time; only the declaration and the consumer were missing.
# - Disconfirming evidence: subscription-lane readings through quota-axi kept
#   working, which is why the blind spot stayed invisible in dispatch.
#
# The load-bearing boundary here is that a reading never routes: quota drives a
# reminder and only the captain's word or an explicit config change switches
# identities (docs/configuration.md "Custom quota sources").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-quota-alert.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-quota-alert-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A stand-in for the captain's local gateway usage reader: one JSON document
# listing every billed lane, matched by a name field rather than by position.
cat > "$FAKEBIN/llm-quota" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "date": "2026-07-23",
  "keys": [
    { "label": "Claude Code", "suffix": "bb3f87", "name": "captain", "cost": 60.31, "limit": 60.0, "used_pct": 100.5, "remain_pct": 0.0 },
    { "label": "Codex", "suffix": "5c58bb", "name": "captain", "cost": 100.11, "limit": 100.0, "used_pct": 100.1, "remain_pct": 0.0 }
  ]
}
JSON
SH
chmod +x "$FAKEBIN/llm-quota"

cat > "$FAKEBIN/llm-quota-healthy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"keys":[{"label":"Claude Code","cost":6.0,"limit":60.0}]}'
SH
chmod +x "$FAKEBIN/llm-quota-healthy"

cat > "$FAKEBIN/llm-quota-broken" <<'SH'
#!/usr/bin/env bash
echo "gateway unreachable" >&2
exit 7
SH
chmod +x "$FAKEBIN/llm-quota-broken"

cat > "$FAKEBIN/llm-quota-garbage" <<'SH'
#!/usr/bin/env bash
echo "<html>login required</html>"
SH
chmod +x "$FAKEBIN/llm-quota-garbage"

cat > "$FAKEBIN/llm-quota-hang" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$FAKEBIN/llm-quota-hang"

# write_home <name> <overrides-json> [dispatch-json] -> echoes the home path
write_home() {
  local name=$1 overrides=$2 dispatch=${3:-}
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s\n' "$overrides" > "$home/config/harness-overrides.json"
  [ -z "$dispatch" ] || printf '%s\n' "$dispatch" > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

run_alert() {  # <home> [args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" "$ALERT" "$@" 2>&1
}

# The real 2026-07-23 shape: claude declares a subscription and a gateway
# identity, only the gateway one is metered by the custom source, and the
# dispatch default names the model and effort the subscription lane would use.
REAL_OVERRIDES='{
  "claude": {
    "command": "/bin/cc",
    "default_variant": "subscription",
    "variants": {
      "subscription": { "command": "/bin/cc" },
      "gateway": {
        "command": "/bin/claude-gw",
        "quota": { "command": "llm-quota", "args": ["--json"], "key": "claude_code" }
      }
    }
  },
  "codex": { "command": "/bin/codex", "default_variant": "api", "variants": { "api": {} } }
}'
REAL_DISPATCH='{"rules":[],"default":{"harness":"claude","model":"claude-opus-4-8[1m]","effort":"high","launch":"subscription"}}'

test_exhausted_lane_names_its_alternatives() {
  local home out
  home=$(write_home exhausted "$REAL_OVERRIDES" "$REAL_DISPATCH")
  out=$(run_alert "$home")
  assert_contains "$out" 'QUOTA_LOW: claude.gateway remaining=0%' \
    "the exhausted gateway lane must be named with its remaining balance"
  assert_contains "$out" 'spend=60.31/60' \
    "the reading that proves the lane is done must be carried with it"
  assert_contains "$out" 'QUOTA_ALT: claude.gateway -> claude.subscription harness=claude model=claude-opus-4-8[1m] effort=high' \
    "the switch target must arrive with the model and effort dispatch would use"
  assert_not_contains "$out" 'QUOTA_ALT: claude.gateway -> claude.gateway' \
    "an exhausted lane must never be offered as its own alternative"
  pass "an exhausted lane is reported with the identities the captain could switch to"
}

# The codex gateway lane really is billed and really is invisible: the captain
# has not yet said how codex launches through the gateway, so no variant may be
# invented for it. The unclaimed reading is how that gap stays visible instead
# of being papered over with a fabricated identity.
test_billed_but_undeclared_lane_is_surfaced() {
  local home out
  home=$(write_home unclaimed "$REAL_OVERRIDES" "$REAL_DISPATCH")
  out=$(run_alert "$home")
  assert_contains "$out" 'QUOTA_UNCLAIMED: llm-quota Codex remaining=0%' \
    "a metered lane that no launch identity declares must be surfaced, not dropped"
  pass "a billed lane with no declared launch identity is reported as unclaimed"
}

test_healthy_lane_is_quiet_and_visible_on_demand() {
  local home out
  home=$(write_home healthy \
    '{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-healthy","key":"Claude Code"}}}}}')
  out=$(run_alert "$home")
  assert_not_contains "$out" QUOTA_LOW "a lane with 90% left must not be reported as low"
  out=$(run_alert "$home" --all)
  assert_contains "$out" 'QUOTA_OK: claude.gateway remaining=90%' \
    "--all must show the healthy reading"
  out=$(run_alert "$home" --threshold 95)
  assert_contains "$out" 'QUOTA_LOW: claude.gateway remaining=90% threshold=95%' \
    "the threshold must be the one the caller asked for"
  pass "a healthy lane stays quiet, and the threshold is the caller's"
}

# A quota read that fails must degrade explicitly. The dangerous failure is not
# noise, it is a lane that silently reads as fine: absence of QUOTA_LOW would
# otherwise be indistinguishable from a healthy balance.
test_read_failures_degrade_explicitly_and_never_claim_health() {
  local label overrides timeout expect home out n=0
  while IFS='^' read -r label overrides timeout expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    home=$(write_home "degrade-$n" "$overrides")
    # Only the hung-command row runs against a short deadline; the others keep a
    # generous one so a loaded machine cannot turn a fast failure into a timeout.
    out=$(FM_QUOTA_TIMEOUT="$timeout" run_alert "$home")
    assert_contains "$out" "$expect" "$label"
    assert_not_contains "$out" QUOTA_OK "$label: a failed read must not read as a healthy lane"
    assert_not_contains "$out" QUOTA_LOW "$label: a failed read is not a threshold crossing"
  done <<ROWS
missing command is named^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-absent","key":"claude_code"}}}}}^30^QUOTA_UNREADABLE: claude.gateway quota command not found: llm-quota-absent
non-zero exit is named^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-broken","key":"claude_code"}}}}}^30^QUOTA_UNREADABLE: claude.gateway quota command exited 7
non-JSON output is named^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-garbage","key":"claude_code"}}}}}^30^QUOTA_UNREADABLE: claude.gateway quota command did not print JSON
a hung command is bounded^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-hang","key":"claude_code"}}}}}^2^QUOTA_UNREADABLE: claude.gateway quota command timed out after 2s
an unmatched key is named^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota","args":["--json"],"key":"no-such-lane"}}}}}^30^QUOTA_UNREADABLE: claude.gateway no entry matches key "no-such-lane"
an ambiguous key is refused^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota","args":["--json"],"key":"captain"}}}}}^30^QUOTA_UNREADABLE: claude.gateway key "captain" matches 2 entries
ROWS
  [ "$n" -gt 0 ] || fail "no degradation rows ran"
  pass "every read failure degrades to an explicit reason, never to an implied healthy lane"
}

test_read_failure_exits_zero_so_it_cannot_block_work() {
  local home status
  home=$(write_home nonblocking \
    '{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota-broken","key":"claude_code"}}}}}')
  set +e
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" "$ALERT" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "a failed quota read"
  pass "a failed quota read exits 0 so it can never become a reason to hold up work"
}

# Configuration mistakes are a different class from a failed read: they are
# actionable and stay loud.
test_invalid_quota_blocks_are_configuration_errors() {
  local label overrides expect home out status n=0
  while IFS='^' read -r label overrides expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    home=$(write_home "invalid-$n" "$overrides")
    set +e
    out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" "$ALERT" 2>&1)
    status=$?
    set -e
    expect_code 2 "$status" "$label"
    assert_contains "$out" "$expect" "$label"
  done <<ROWS
a non-object quota is refused^{"claude":{"variants":{"gateway":{"quota":"llm-quota"}}}}^quota must be an object (claude.gateway)
a missing command is refused^{"claude":{"variants":{"gateway":{"quota":{"key":"claude_code"}}}}}^quota needs a non-empty command (claude.gateway)
a missing key is refused^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota"}}}}}^quota needs a non-empty key (claude.gateway)
non-string args are refused^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota","args":[7],"key":"k"}}}}}^quota args must be an array of strings (claude.gateway)
a harness-level quota beside variants is refused^{"claude":{"quota":{"command":"llm-quota","key":"k"},"variants":{"gateway":{}}}}^quota must be declared on each variant, not on claude, which declares variants
ROWS
  [ "$n" -gt 0 ] || fail "no invalid-config rows ran"
  pass "an invalid quota block is a loud configuration error, not a silent degradation"
}

# A harness that declares no variants is one identity, so its quota block sits on
# the harness entry and the lane is named by the harness alone.
test_variantless_harness_declares_its_source_directly() {
  local home out
  home=$(write_home variantless \
    '{"codex":{"command":"/bin/codex","quota":{"command":"llm-quota","args":["--json"],"key":"codex"}}}')
  out=$(run_alert "$home")
  assert_contains "$out" 'QUOTA_LOW: codex remaining=0%' \
    "a variantless harness must be readable as one lane"
  pass "a harness with no variants declares its quota source on the harness entry"
}

test_absent_config_is_silent() {
  local home out status
  home="$TMP_ROOT/no-config"
  mkdir -p "$home/config"
  set +e
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" "$ALERT" 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "a home with no launch identities"
  [ -z "$out" ] || fail "a home that declares nothing must print nothing, got: $out"
  pass "a home with no declared launch identities stays silent"
}

# THE RED LINE. Quota may drive a reminder and must never drive a switch.
#
# The shell selector this used to drive is gone: the 2026-08-11 upstream sync
# removed bin/fm-dispatch-select.sh and made profile-array selection an
# agent-owned procedure. The rule it enforced did not go with it, so the red
# line is asserted where it now lives - the always-loaded instruction in
# AGENTS.md section 4 and the single owner of the selection procedure - plus
# the unchanged mechanical half: this reminder script is not on any dispatch
# path, and no dispatch surface reads a quota source or a launch identity.
test_quota_sources_never_reach_dispatch_selection() {
  local skill=".agents/skills/quota-array-dispatch/SKILL.md" f

  assert_present "$ROOT/$skill" "the profile-array selection owner is missing"
  assert_grep 'never by quota or any other runtime signal' "$ROOT/AGENTS.md" \
    "AGENTS.md must still forbid choosing a launch identity from a runtime signal"
  assert_grep 'resolves to its first element without consulting quota' "$ROOT/AGENTS.md" \
    "AGENTS.md must still make a launch-carrying array skip quota entirely"

  # The mechanical half: nothing on a dispatch surface may read this script or
  # the launch-identity file it reads. fm-spawn passes a launch variant through
  # to the harness launcher; it must never consult a quota source to pick one.
  for f in bin/fm-spawn.sh bin/fm-harness.sh; do
    grep -v '^[[:space:]]*#' "$ROOT/$f" | grep -q 'fm-quota-alert' \
      && fail "$f must not consult the quota reminder while resolving a spawn"
  done
  # The reminder READS config/crew-dispatch.json to know which launch identities
  # exist, which is what lets it name the alternatives. What it must never do is
  # run a spawn or write a dispatch decision back.
  # shellcheck disable=SC2016  # the literal $DISPATCH is the pattern, not a variable
  grep -v '^[[:space:]]*#' "$ROOT/bin/fm-quota-alert.sh" | grep -qE 'fm-spawn|fm-dispatch|> *"?\$DISPATCH' \
    && fail "the quota reminder must not dispatch or rewrite the dispatch config"
  pass "quota readings never reach dispatch selection"
}

test_exhausted_lane_names_its_alternatives
test_billed_but_undeclared_lane_is_surfaced
test_healthy_lane_is_quiet_and_visible_on_demand
test_read_failures_degrade_explicitly_and_never_claim_health
test_read_failure_exits_zero_so_it_cannot_block_work
test_invalid_quota_blocks_are_configuration_errors
test_variantless_harness_declares_its_source_directly
test_absent_config_is_silent
test_quota_sources_never_reach_dispatch_selection

echo "# all fm-quota-alert tests passed"
