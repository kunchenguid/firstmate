#!/usr/bin/env bash
# Contract and deterministic fixture tests for quota-array-dispatch.
#
# The skill owns the agent-facing decision procedure.
# This test encodes the same inspectable comparison rules against sanitized
# fixtures so acceptance cases stay deterministic without introducing a
# production routing wrapper.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"
ARCHITECTURE="$ROOT/docs/architecture.md"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
AUDIENCES="$ROOT/docs/documentation-audiences.json"
CASES="$ROOT/tests/fixtures/quota-array-dispatch/cases.json"
SHAPE="$ROOT/tests/fixtures/quota-array-dispatch/schema-v3-shape.json"

intake_boundary() {
  awk '
    /^## 4\. Harness and runtime dispatch$/ { found = 1; next }
    found && /^## 5\. Recovery$/ { exit }
    found { print }
  ' "$AGENTS"
}

select_candidate_py() {
  python3 - "$@" <<'PY'
import json, sys

def conservation_pressure(c):
    if not c.get("paceAvailable", True):
        return False
    status = c.get("paceStatus")
    ahead_ids = c.get("aheadWindowIds") or []
    bounding_windows = c.get("boundingWindows") or []
    if status == "ahead":
        return True
    if status == "mixed" and ahead_ids:
        return True
    if any(window.get("paceStatus") == "ahead" for window in bounding_windows):
        return True
    return False

def select(case):
    required = case.get("requiredReasoningClass")
    cands = list(case["candidates"])
    if required:
        matching = [c for c in cands if c.get("reasoningClass") == required]
        if not matching:
            return {"error": "required reasoning class unavailable"}
        # Strongest-reasoning rule: never drop to a weaker class for quota.
        cands = matching

    # Fit filter: fixtures mark comparable; keep only comparable for these cases.
    cands = [c for c in cands if c.get("fit") == "comparable"]
    if not cands:
        return {"error": "no comparable candidates"}

    def sort_key(c):
        pressured = conservation_pressure(c)
        unknown = bool(c.get("unknownPace")) or c.get("paceStatus") == "unknown"
        pace_available = bool(c.get("paceAvailable", True))
        reserve = c.get("worstReserve")
        if reserve is None:
            reserve_key = float("-inf")
        else:
            reserve_key = float(reserve)
        raw = float(c.get("rawHeadroom") or 0)
        # Sort ascending by preference rank components that python min understands
        # via a tuple where lower is better only for pressure/unknown flags.
        return (
            1 if pressured else 0,
            1 if (unknown and pace_available) else 0,
            0 if pace_available else 1,  # when pace absent, still comparable via raw only
            # Among pressured: least-negative reserve => higher reserve first => negate
            (-reserve_key if pressured else 0),
            # Among sustainable with pace: prefer higher reserve then higher raw
            (-reserve_key if (not pressured and pace_available and not unknown) else 0),
            -raw,
        )

    # Special-case all-tight already constrained to required class above.
    best_key = min(sort_key(c) for c in cands)
    winners = [c for c in cands if sort_key(c) == best_key]
    if len(winners) > 1:
        return {
            "error": "genuine tie requires captain choice",
            "candidates": sorted(c["id"] for c in winners),
        }
    winner = winners[0]
    return {
        "id": winner["id"],
        "pressured": conservation_pressure(winner),
    }

case = json.loads(sys.argv[1])
print(json.dumps(select(case)))
PY
}

test_owner_and_always_loaded_boundary() {
  local boundary trigger_count
  boundary=$(intake_boundary)

  assert_present "$OWNER" "quota-array-dispatch owner is missing"
  assert_grep 'name: quota-array-dispatch' "$OWNER" "quota-array-dispatch skill has the wrong name"
  assert_grep 'user-invocable: false' "$OWNER" "quota-array-dispatch skill must be agent-only"
  assert_grep 'single owner of the pace-aware profile-array selection procedure' "$OWNER" \
    "quota-array-dispatch skill does not declare ownership"

  assert_contains "$boundary" 'Firstmate alone resolves a matched profile array' \
    "intake boundary lost agent-owned array resolution"
  assert_contains "$boundary" 'run `quota-axi --json` at that intake' \
    "intake boundary lost quota-axi intake read"
  assert_contains "$boundary" 'evaluate every configured candidate against that current output' \
    "intake boundary lost full-candidate accounting"
  assert_contains "$boundary" 'inspectable real headroom including quota-window pace' \
    "intake boundary lost pace-aware headroom wording"
  assert_contains "$boundary" 'if any harness/model/provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate' \
    "intake boundary lost unresolved-candidate refusal"
  assert_contains "$boundary" 'instead of omitting it, guessing, falling back, or calling the result quota-informed' \
    "intake boundary lost no-guess wording"
  assert_contains "$boundary" 'Preserve malformed profile configuration as an actionable error' \
    "intake boundary lost malformed-config refusal"
  assert_contains "$boundary" "preserve the captain's strongest-reasoning class rather than silently downgrading it" \
    "intake boundary lost strongest-reasoning rule"
  assert_contains "$boundary" 'Break genuine headroom ties without array-order or harness bias' \
    "intake boundary lost genuine-tie rule"
  assert_contains "$boundary" '`quota-axi` owns how model or product windows relate to bounding account windows' \
    "intake boundary lost quota-axi window ownership"
  assert_contains "$boundary" 'remains data-only' \
    "intake boundary lost data-only producer boundary"
  assert_contains "$boundary" 'Load `quota-array-dispatch` before choosing among a matched profile array' \
    "intake boundary lost quota-array-dispatch load trigger"

  trigger_count=$(grep -Fc -- '- `quota-array-dispatch` -' "$AGENTS")
  [ "$trigger_count" -eq 1 ] || fail "quota-array-dispatch must have exactly one section 13 trigger, found $trigger_count"

  # Full pace procedure stays out of AGENTS.md.
  if printf '%s\n' "$boundary" | grep -q 'reservePercentPoints'; then
    fail "AGENTS.md intake boundary duplicated pace formula detail"
  fi
  if printf '%s\n' "$boundary" | grep -q 'aheadWindowIds'; then
    fail "AGENTS.md intake boundary duplicated aheadWindowIds detail"
  fi

  pass "quota-array-dispatch has one conditional owner and a concise always-loaded boundary"
}

test_owner_contains_selection_procedure() {
  local phrase lines words bytes
  for phrase in \
    'reservePercentPoints = percentRemaining - timeRemainingPercent' \
    'Negative reserve means usage is ahead of reset pace and creates conservation pressure' \
    'Positive reserve means usage is behind reset pace' \
    '`on_pace` is neutral' \
    'effective pace status is `mixed` and any `aheadWindowIds` remain' \
    'prefer a candidate without ahead-of-reset conservation pressure over one with conservation pressure' \
    'even when the pressured candidate has somewhat higher raw remaining percentage' \
    'prefer the least-negative worst applicable reserve' \
    'use known behind/on-pace evidence plus raw headroom transparently' \
    'Do not collapse those facts into an opaque composite score' \
    '`unknown` is valid explicit uncertainty from quota-axi' \
    'Prefer known sustainable evidence over `unknown` pace when otherwise comparable' \
    'If the dispatch choice materially hinges on unresolved pace, report the uncertainty' \
    'do not crash, fabricate pace, or silently reinterpret absence as healthy' \
    'stop and report every tied candidate for captain choice' \
    'Do not select by array order, harness name, or another arbitrary identity ordering' \
    'Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy' \
    'Report duplicate concrete profiles as a configuration error' \
    'Name the inspectable facts used for every candidate'; do
    assert_grep "$phrase" "$OWNER" "quota-array-dispatch procedure lost '$phrase'"
  done

  # Expanded acceptance scenarios live in deterministic fixtures, not runtime prose.
  for phrase in \
    'Higher raw quota but materially ahead vs lower raw quota on/behind pace' \
    'Sanitized producer shape' \
    '## When to load' \
    '## Intake boundary this skill does not relax'; do
    if grep -Fq -- "$phrase" "$OWNER"; then
      fail "quota-array-dispatch should not keep removed runtime prose: $phrase"
    fi
  done

  lines=$(wc -l < "$OWNER" | tr -d ' ')
  words=$(wc -w < "$OWNER" | tr -d ' ')
  bytes=$(wc -c < "$OWNER" | tr -d ' ')
  [ "$lines" -le 65 ] || fail "quota-array-dispatch skill is too long: $lines lines (want <= 65)"
  [ "$words" -le 600 ] || fail "quota-array-dispatch skill is too wordy: $words words (want <= 600)"
  [ "$bytes" -le 4600 ] || fail "quota-array-dispatch skill is too large: $bytes bytes (want <= 4600)"
  pass "quota-array-dispatch owns the compact pace procedure ($lines lines, $words words, $bytes bytes)"
}

test_cross_references_stay_pointers() {
  assert_grep '`quota-array-dispatch` owns the pace-aware profile-array selection procedure' "$CONFIG" \
    "configuration docs do not point to quota-array-dispatch"
  assert_no_grep '`AGENTS.md` section 4 owns the dispatch and array-selection procedure.' "$CONFIG" \
    "configuration docs still claim AGENTS.md owns the full array-selection procedure"
  assert_grep 'quota-array-dispatch' "$ARCHITECTURE" \
    "architecture docs lost the quota-array-dispatch pointer"
  assert_grep 'quota-array-dispatch' "$BOOTSTRAP" \
    "bootstrap header lost the quota-array-dispatch pointer"
  assert_grep 'load `quota-array-dispatch` for the pace-aware candidate choice' "$HARNESS" \
    "harness-adapters lost the array-selection handoff"
  assert_grep '.agents/skills/quota-array-dispatch/SKILL.md' "$AUDIENCES" \
    "documentation audience inventory missing quota-array-dispatch"
  pass "cross-references point at the single procedure owner"
}

test_schema_v3_shape_fixture() {
  python3 - "$SHAPE" <<'PY' || fail "schema v3 shape fixture is invalid"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data.get("schemaVersion") == 3, data.get("schemaVersion")
assert isinstance(data.get("providers"), list) and data["providers"], "providers"
provider = data["providers"][0]
assert "windows" in provider and provider["windows"], "windows"
window = provider["windows"][0]
assert "pace" in window and "status" in window["pace"], window
eff = provider["quotaSemantics"]["effectiveAvailability"][0]
assert "pace" in eff and "status" in eff["pace"], eff
assert "effectivePercentRemaining" in eff
# Privacy: no live account residue markers.
blob = json.dumps(data)
for bad in ("sk-", "@", "Bearer ", "accountId", "organizationId"):
    assert bad not in blob, bad
PY
  pass "sanitized schemaVersion 3 fixture preserves producer pace shape without private details"
}

test_deterministic_acceptance_cases() {
  local raw case_json case_id expect expect_error got reason
  raw=$(cat "$CASES")
  while IFS= read -r case_json; do
    case_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$case_json")
    expect=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("expect", ""))' "$case_json")
    expect_error=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("expectError", ""))' "$case_json")
    reason=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reason"])' "$case_json")
    got=$(select_candidate_py "$case_json")
    python3 -c '
import json,sys
got=json.loads(sys.argv[1])
expect=sys.argv[2]
expect_error=sys.argv[3]
case_id=sys.argv[4]
err=got.get("error")
if expect_error:
    if err != expect_error:
        raise SystemExit("%s: expected error %s, got %s" % (case_id, expect_error, got))
elif err:
    raise SystemExit("%s: selector error: %s" % (case_id, err))
elif got.get("id") != expect:
    raise SystemExit("%s: expected %s, got %s" % (case_id, expect, got))
' "$got" "$expect" "$expect_error" "$case_id" \
      || fail "case $case_id failed ($reason); selector returned $got"
    if [ -n "$expect_error" ]; then
      pass "case $case_id -> $expect_error ($reason)"
    else
      pass "case $case_id -> $expect ($reason)"
    fi
  done < <(python3 -c 'import json,sys; data=json.load(sys.stdin); [print(json.dumps(c, separators=(",", ":"))) for c in data["cases"]]' <<<"$raw")
}

test_dispatch_identity_and_blocked_report() {
  local reports
  assert_grep '`harness-adapters` owns identity' "$OWNER" \
    "quota-array-dispatch does not point to the adapter identity owner"
  assert_grep "another harness CLI cannot block it" "$OWNER" \
    "quota-array-dispatch does not scope evidence to the concrete tuple"
  assert_grep 'A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence' "$OWNER" \
    "blocked reports do not preserve the minimum identity and evidence fields"
  assert_grep 'The concrete `harness` field owns adapter identity independently of the model provider' "$HARNESS" \
    "harness-adapters lost the anti-conflation owner paragraph"
  assert_grep '`harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`' "$HARNESS" \
    "harness-adapters lost the concrete Pi/xAI versus Grok distinction"
  assert_grep 'does not require Grok CLI login' "$HARNESS" \
    "Pi/xAI guidance incorrectly requires Grok CLI login"
  assert_no_grep '### Dispatch identity mapping' "$HARNESS" \
    "identity guidance grew a separate table instead of one owner paragraph"

  reports=$(python3 - <<'PY'

def auth_surface(harness, model, provider):
    if harness == "pi" and model.startswith("xai/") and provider == "xai":
        return "Pi xAI OAuth"
    if harness == "grok":
        return "Grok Build CLI"
    raise AssertionError("unresolved concrete profile")

def blocked(harness, model, provider, failure):
    surface = auth_surface(harness, model, provider)
    return (f"blocked: harness={harness} model={model} provider={provider} "
            f"authentication surface checked={surface} failure evidence={failure}")

model = "xai/grok-4.5"
provider = "xai"
pi = blocked("pi", model, provider, "Pi xAI OAuth unavailable")
grok = blocked("grok", model, provider, "Grok Build CLI login missing")
assert "Grok Build CLI" not in pi
assert "Pi xAI OAuth" in pi
assert "Grok Build CLI" in grok
print(pi)
print(grok)
PY
) || fail "identity counterfactual fixture failed"
  assert_contains "$reports" 'blocked: harness=pi model=xai/grok-4.5 provider=xai authentication surface checked=Pi xAI OAuth' \
    "Pi/xAI blocked evidence was not scoped to Pi"
  assert_not_contains "$reports" 'harness=pi model=xai/grok-4.5 provider=xai authentication surface checked=Grok Build CLI' \
    "Pi/xAI was reported with the standalone Grok CLI surface"
  assert_contains "$reports" 'blocked: harness=grok model=xai/grok-4.5 provider=xai authentication surface checked=Grok Build CLI' \
    "explicit Grok candidate did not use the Grok Build CLI surface"
  for field in harness=pi model=xai/grok-4.5 provider=xai 'authentication surface checked=Pi xAI OAuth' 'failure evidence=Pi xAI OAuth unavailable'; do
    assert_contains "$reports" "$field" "Pi blocked report lost '$field'"
  done
  pass "dispatch identity stays concrete across the Pi/xAI versus Grok counterfactual"
}

test_no_duplicate_procedure_in_agents() {
  # Guard against re-expanding the full procedure into AGENTS.md.
  local count
  count=$(grep -c 'conservation pressure' "$AGENTS" || true)
  [ "$count" -eq 0 ] || fail "AGENTS.md should not restate conservation-pressure procedure detail"
  count=$(grep -c 'worst applicable reserve' "$AGENTS" || true)
  [ "$count" -eq 0 ] || fail "AGENTS.md should not restate worst-reserve procedure detail"
  pass "AGENTS.md does not duplicate the pace procedure body"
}

test_owner_and_always_loaded_boundary
test_owner_contains_selection_procedure
test_cross_references_stay_pointers
test_schema_v3_shape_fixture
test_deterministic_acceptance_cases
test_dispatch_identity_and_blocked_report
test_no_duplicate_procedure_in_agents
