#!/usr/bin/env bash
# Tests the per-surface quota view + model->surface map + failover selector + authed
# override hook. Hermetic: a temp FM_HOME supplies a controlled model map + a stub
# `cursor` quota-source (honoring config/quota-overrides.json), and `quota-axi` is
# stubbed on PATH, so the LOGIC is asserted (not live numbers): grok drained (2%),
# cursor healthy (80% via its authed reader) -> a grok task fails over to cursor.
set -uo pipefail
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

HOMEDIR=$(mktemp -d)
mkdir -p "$HOMEDIR/config" "$HOMEDIR/bin/quota-sources"
cp "$REAL/docs/examples/model-surfaces.json" "$HOMEDIR/config/model-surfaces.json"
# stub cursor source: headroom comes from the override command (mirrors the real reader)
cat > "$HOMEDIR/bin/quota-sources/cursor.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.cursor // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"cursor","status":"logged_in","headroom":%s,"unit":"requests","models":["grok"],"note":"test"}\n' "$hr"
EOF
chmod +x "$HOMEDIR/bin/quota-sources/cursor.sh"
# stub copilot source: same override contract. Mirrors the real one, whose reason for
# existing is that quota-axi's native copilot provider only probes the OLD IDE credential
# path (~/.config/github-copilot/apps.json) and so stays auth_required for a CLI login.
cat > "$HOMEDIR/bin/quota-sources/copilot.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.copilot // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"copilot","status":"logged_in","headroom":%s,"unit":"premium interactions","models":["claude","gpt"],"note":"test"}\n' "$hr"
EOF
chmod +x "$HOMEDIR/bin/quota-sources/copilot.sh"

STUB=$(mktemp -d)
cat > "$STUB/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
 {"provider":"grok","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":2}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":15}]},
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]},
 {"provider":"copilot","source":"unavailable","state":{"status":"auth_required"},"windows":[]},
 {"provider":"codex","source":"cli-rpc","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}
]}
JSON
EOF
chmod +x "$STUB/quota-axi"
export PATH="$STUB:$PATH"
export FM_HOME="$HOMEDIR"
FLEET=$(mktemp -d); export FM_FLEET_DIR="$FLEET"
cd "$REAL"
Q(){ bin/fm-fleet.sh "$@" 2>&1; }

# cursor's authed reader reports 80 -> supersedes quota-axi's 15
printf '{"cursor":"echo 80"}\n' > "$HOMEDIR/config/quota-overrides.json"
[ "$(Q pick grok)"   = cursor ] && ok "pick grok fails over to cursor when grok drained" || no "pick grok -> $(Q pick grok)"
[ "$(Q pick claude)" = claude ] && ok "pick claude -> claude (has headroom)"               || no "pick claude -> $(Q pick claude)"
[ "$(Q pick kimi)"   = kimi   ] && ok "pick kimi -> kimi (only surface; cline unmonitored)" || no "pick kimi -> $(Q pick kimi)"
b=$(Q pick bogus); printf '%s' "$b" | grep -qi unknown && ok "pick unknown family is flagged" || no "pick bogus not flagged (got: $b)"
Q quota  | grep -E '^cursor' | grep -q custom && ok "quota view includes cursor (custom source)" || no "cursor missing from quota view"
Q models | grep -E '^grok'   | grep -q cursor && ok "models view: grok reachable via cursor"    || no "grok->cursor missing in models view"
Q quota  | grep -qE '^cline' && no "cline should be removed from monitoring" || ok "cline is not a monitored surface"
# authed override precedence: cursor reader -> 55 shows as 55%
printf '{"cursor":"echo 55"}\n' > "$HOMEDIR/config/quota-overrides.json"
Q quota | grep -E '^cursor' | grep -q '55%' && ok "authed override: cursor headroom reads 55% from its reader" || no "override not applied ($(Q quota | grep -E '^cursor'))"

# --- copilot surface (GitHub Copilot CLI) -------------------------------------------
# Its custom source must SUPERSEDE quota-axi's native auth_required row (the native probe
# reads the old IDE credential path and can never see a standalone CLI login).
printf '{"cursor":"echo 55","copilot":"echo 88"}\n' > "$HOMEDIR/config/quota-overrides.json"
Q quota | grep -E '^copilot' | grep -q '88%' \
  && ok "copilot custom source supersedes quota-axi auth_required row (88%)" \
  || no "copilot row wrong ($(Q quota | grep -E '^copilot'))"
Q models | grep -E '^claude' | grep -q copilot \
  && ok "models view: claude reachable via copilot" \
  || no "claude->copilot missing in models view"
Q models | grep -E '^gpt' | grep -q copilot \
  && ok "models view: gpt reachable via copilot" \
  || no "gpt->copilot missing in models view"

# Failover INTO copilot: drain claude's native pool, copilot stays healthy.
cat > "$STUB/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":1}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":15}]},
 {"provider":"copilot","source":"unavailable","state":{"status":"auth_required"},"windows":[]},
 {"provider":"codex","source":"cli-rpc","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}
]}
JSON
EOF
chmod +x "$STUB/quota-axi"
[ "$(Q pick claude)" = copilot ] \
  && ok "pick claude fails over to copilot when the claude pool is drained" \
  || no "pick claude -> $(Q pick claude) (expected copilot)"

# --- T3: characterization lock --------------------------------------------------
# Freezes today's (pre-pace) `quota`/`models`/`pick`/`budget` output, captured against
# the hermetic v2-shaped stub+overrides state established above (draining-claude
# scenario, cursor=55/copilot=88 overrides — the state active at this point in the
# script). T6-T8 add assertions that diff FRESH output on the same v2 stub against
# these frozen files and require byte-identical results (G5). Regenerate ONLY with
# FM_TEST_REGEN_GOLDEN=1 (never automatically) so a lib regression can never
# silently re-freeze itself as "expected" by re-running the suite.
GOLDEN_DIR="$REAL/tests/federation/golden"
if [ "${FM_TEST_REGEN_GOLDEN:-}" = 1 ]; then
  mkdir -p "$GOLDEN_DIR"
  Q quota       > "$GOLDEN_DIR/v2-quota.golden"
  Q models      > "$GOLDEN_DIR/v2-models.golden"
  Q pick grok   > "$GOLDEN_DIR/v2-pick-grok.golden"
  Q pick claude > "$GOLDEN_DIR/v2-pick-claude.golden"
  Q pick kimi   > "$GOLDEN_DIR/v2-pick-kimi.golden"
  Q pick bogus  > "$GOLDEN_DIR/v2-pick-bogus.golden"
  { Q budget; echo "exit=$?"; } > "$GOLDEN_DIR/v2-budget.golden"
  echo "golden fixtures regenerated at $GOLDEN_DIR"
fi

# --- T4: dual-schema stub — schemaVersion 3 pace fixtures --------------------
# Hand-written equivalent of upstream's sanitized shape (fa0d85d:
# tests/fixtures/quota-array-dispatch/schema-v3-shape.json) — no live balances, reset
# timestamps, or account identifiers, per that fixture's own rule. Eight synthetic
# surfaces exercise every pace branch this PRD's §5.1/§5.2/§5.5 logic must handle:
#
#   A  80%  ahead    -18   pressured, high headroom
#   B  55%  behind   +20   sustainable, lower headroom
#   C  45%  mixed    -15   aheadWindowIds:[seven_day] -> still pressured
#   D  60%  ahead     -4   pressured, least-negative reserve
#   E  60%  unknown   —    explicit producer uncertainty (+ reason)
#   F  70%  (absent)  —    v3 provider, no pace fields at all
#   G   3%  behind   +50   below FM_FLEET_QUOTA_MIN(5) — floor must exclude it first
#   H  95%  behind   +80   STALE (state.status=stale) — R1: must not be trusted as 1a
V3_FIXTURE="$REAL/tests/federation/golden/v3-pace-fixture.json"
mkdir -p "$(dirname "$V3_FIXTURE")"
cat > "$V3_FIXTURE" <<'V3JSON'
{
  "schemaVersion": 3,
  "generatedAt": "2026-07-28T00:00:00.000Z",
  "providers": [
    {
      "provider": "A", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 80,
         "pace": {"status": "ahead", "timeRemainingPercent": 98, "reservePercentPoints": -18}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 80,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "ahead", "aheadWindowIds": ["five_hour"], "behindWindowIds": [],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": -18, "worstReserveWindowId": "five_hour"}}
      ]}
    },
    {
      "provider": "B", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 55,
         "pace": {"status": "behind", "timeRemainingPercent": 35, "reservePercentPoints": 20}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 55,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "behind", "aheadWindowIds": [], "behindWindowIds": ["five_hour"],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": 20, "worstReserveWindowId": "five_hour"}}
      ]}
    },
    {
      "provider": "C", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 70,
         "pace": {"status": "behind", "timeRemainingPercent": 55, "reservePercentPoints": 15}},
        {"id": "seven_day", "label": "7d", "kind": "rolling", "percentRemaining": 45,
         "pace": {"status": "ahead", "timeRemainingPercent": 60, "reservePercentPoints": -15}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 45,
         "boundedBy": ["five_hour", "seven_day"], "limitingWindowIds": ["seven_day"],
         "pace": {"status": "mixed", "aheadWindowIds": ["seven_day"], "behindWindowIds": ["five_hour"],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": -15, "worstReserveWindowId": "seven_day"}}
      ]}
    },
    {
      "provider": "D", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 60,
         "pace": {"status": "ahead", "timeRemainingPercent": 64, "reservePercentPoints": -4}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 60,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "ahead", "aheadWindowIds": ["five_hour"], "behindWindowIds": [],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": -4, "worstReserveWindowId": "five_hour"}}
      ]}
    },
    {
      "provider": "E", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 60,
         "pace": {"status": "unknown", "reason": "provider window pace undetermined"}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 60,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "unknown", "aheadWindowIds": [], "behindWindowIds": [],
                   "onPaceWindowIds": [], "unknownWindowIds": ["five_hour"]}}
      ]}
    },
    {
      "provider": "F", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 70}
      ]
    },
    {
      "provider": "G", "source": "oauth", "state": {"status": "fresh"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 3,
         "pace": {"status": "behind", "timeRemainingPercent": 20, "reservePercentPoints": 50}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 3,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "behind", "aheadWindowIds": [], "behindWindowIds": ["five_hour"],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": 50, "worstReserveWindowId": "five_hour"}}
      ]}
    },
    {
      "provider": "H", "source": "cache", "state": {"status": "stale", "error": "rate limited"},
      "windows": [
        {"id": "five_hour", "label": "5h", "kind": "rolling", "percentRemaining": 95,
         "pace": {"status": "behind", "timeRemainingPercent": 15, "reservePercentPoints": 80}}
      ],
      "quotaSemantics": {"status": "known", "effectiveAvailability": [
        {"scope": "all_models", "status": "known", "effectivePercentRemaining": 95,
         "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
         "pace": {"status": "behind", "aheadWindowIds": [], "behindWindowIds": ["five_hour"],
                   "onPaceWindowIds": [], "unknownWindowIds": [],
                   "worstReservePercentPoints": 80, "worstReserveWindowId": "five_hour"}}
      ]}
    }
  ]
}
V3JSON

# --- T5: pace extraction primitives (§5.1/§5.2) — unit-level, direct lib calls ---
# Source the lib directly (no fm-fleet.sh CLI plumbing needed) and feed it the v3
# fixture snapshot plus a hand-written v2-shaped snapshot (no schemaVersion, no pace
# anywhere — mirrors the ORIGINAL $STUB/quota-axi payload used above).
# shellcheck source=/dev/null
. "$REAL/bin/fm-fleet-lib.sh"
V3_JSON=$(cat "$V3_FIXTURE")
V2_JSON='{"providers":[{"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}]}'

pace_row() { # surface field(2=headroom 3=state 4=pace 5=reserve) json
  local surf=$1 field=$2 json=$3
  command -v fm_fleet_pace_rows >/dev/null 2>&1 || return 0
  fm_fleet_pace_rows "$json" 2>/dev/null | awk -F'\t' -v s="$surf" -v f="$field" '$1==s{print $f}'
}
provider_json() { printf '%s' "$V3_JSON" | jq -c --arg p "$1" '.providers[]|select(.provider==$p)'; }

[ "$(pace_row A 4 "$V3_JSON")" = ahead ]   && ok "pace_rows: A (v3, ahead) -> pace=ahead"   || no "pace_rows A pace: $(pace_row A 4 "$V3_JSON")"
[ "$(pace_row A 5 "$V3_JSON")" = -18 ]     && ok "pace_rows: A reserve=-18"                 || no "pace_rows A reserve: $(pace_row A 5 "$V3_JSON")"
[ "$(pace_row B 4 "$V3_JSON")" = behind ]  && ok "pace_rows: B (v3, behind) -> pace=behind" || no "pace_rows B pace: $(pace_row B 4 "$V3_JSON")"
[ "$(pace_row B 5 "$V3_JSON")" = 20 ]      && ok "pace_rows: B reserve=+20 (unsigned in row, caller signs it)" || no "pace_rows B reserve: $(pace_row B 5 "$V3_JSON")"
[ "$(pace_row C 4 "$V3_JSON")" = mixed ]   && ok "pace_rows: C -> pace=mixed"               || no "pace_rows C pace: $(pace_row C 4 "$V3_JSON")"
[ "$(pace_row C 5 "$V3_JSON")" = -15 ]     && ok "pace_rows: C worstReserve=-15 (prefers effective summary over per-window min)" || no "pace_rows C reserve: $(pace_row C 5 "$V3_JSON")"
[ "$(pace_row E 4 "$V3_JSON")" = unknown ] && ok "pace_rows: E -> pace=unknown (explicit, not absent)" || no "pace_rows E pace: $(pace_row E 4 "$V3_JSON")"
[ -z "$(pace_row E 5 "$V3_JSON")" ]        && ok "pace_rows: E reserve is absent (no worstReservePercentPoints)" || no "pace_rows E reserve should be absent: $(pace_row E 5 "$V3_JSON")"
[ -z "$(pace_row F 4 "$V3_JSON")" ]        && ok "pace_rows: F -> pace absent (v3, no pace fields) — never 'on_pace'" || no "pace_rows F pace should be absent: $(pace_row F 4 "$V3_JSON")"
[ -z "$(pace_row F 5 "$V3_JSON")" ]        && ok "pace_rows: F reserve absent"               || no "pace_rows F reserve should be absent: $(pace_row F 5 "$V3_JSON")"
[ -z "$(pace_row claude 4 "$V2_JSON")" ]   && ok "pace_rows: v2 payload -> pace absent (never fabricated)" || no "pace_rows v2 pace should be absent: $(pace_row claude 4 "$V2_JSON")"
[ -z "$(pace_row claude 5 "$V2_JSON")" ]   && ok "pace_rows: v2 payload -> reserve absent"  || no "pace_rows v2 reserve should be absent: $(pace_row claude 5 "$V2_JSON")"

if command -v fm_fleet_pressured >/dev/null 2>&1; then
  fm_fleet_pressured "$(provider_json A)" && ok "pressured: A (ahead) -> pressured"                       || no "pressured A should be true"
  fm_fleet_pressured "$(provider_json C)" && ok "pressured: C (mixed + aheadWindowIds non-empty) -> pressured" || no "pressured C should be true"
  fm_fleet_pressured "$(provider_json B)" && no "pressured B should be false" || ok "pressured: B (behind) -> not pressured"
  fm_fleet_pressured "$(provider_json F)" && no "pressured F (absent pace) should be false, not true" || ok "pressured: F (absent pace) -> not pressured"
else
  no "fm_fleet_pressured not defined yet"
fi

rm -rf "$STUB" "$FLEET" "$HOMEDIR"

# --- T6/T7/T8: CLI-level pace assertions against the v3 fixture ---------------
# A second, independent hermetic environment: quota-axi stubbed to the full A-H
# v3 fixture, and a purpose-built model-surfaces map (self-contained — no
# dependency on the real claude/grok/gpt families) so `pick` can isolate exactly
# the candidate pairs each upstream acceptance scenario names.
STUB2=$(mktemp -d)
cat > "$STUB2/quota-axi" <<EOF2
#!/usr/bin/env bash
cat <<'JSON2'
$(cat "$V3_FIXTURE")
JSON2
EOF2
chmod +x "$STUB2/quota-axi"
HOMEDIR2=$(mktemp -d)
mkdir -p "$HOMEDIR2/config" "$HOMEDIR2/bin/quota-sources"
cat > "$HOMEDIR2/config/model-surfaces.json" <<'MAP2'
{
  "_comment": "test-only families for T6-T8 pace acceptance scenarios",
  "avb": ["A", "B"],
  "cvb": ["C", "B"],
  "acd": ["A", "D"],
  "bve": ["B", "E"],
  "gvb": ["G", "B"],
  "hvb": ["H", "B"]
}
MAP2
FLEET2=$(mktemp -d)
Q2(){ FM_HOME="$HOMEDIR2" FM_FLEET_DIR="$FLEET2" PATH="$STUB2:$PATH" "$REAL/bin/fm-fleet.sh" "$@" 2>&1; }

# --- T6 (§5.3): `quota` renders PACE + RESERVE -------------------------------
Q2OUT=$(Q2 quota)
echo "$Q2OUT" | head -1 | grep -qE '^SURFACE\s+HEADROOM\s+PACE\s+RESERVE\s+STATUS\s+SOURCE\s+NOTE' \
  && ok "quota header: SURFACE HEADROOM PACE RESERVE STATUS SOURCE NOTE" \
  || no "quota header wrong: $(echo "$Q2OUT" | head -1)"
echo "$Q2OUT" | grep -E '^A ' | grep -qE 'ahead.*-18'   && ok "quota: A shows pace=ahead reserve=-18 (signed)" || no "quota A row: $(echo "$Q2OUT" | grep -E '^A ')"
echo "$Q2OUT" | grep -E '^B ' | grep -qE 'behind.*\+20' && ok "quota: B shows pace=behind reserve=+20 (explicit +)" || no "quota B row: $(echo "$Q2OUT" | grep -E '^B ')"
echo "$Q2OUT" | grep -E '^C ' | grep -qE 'mixed.*-15'   && ok "quota: C shows pace=mixed reserve=-15" || no "quota C row: $(echo "$Q2OUT" | grep -E '^C ')"
echo "$Q2OUT" | grep -E '^E ' | grep -qE 'unknown.*—'   && ok "quota: E shows pace=unknown reserve=— (unknown != absent)" || no "quota E row: $(echo "$Q2OUT" | grep -E '^E ')"
echo "$Q2OUT" | grep -E '^F ' | grep -qE '—\s+—'         && ok "quota: F (v3, no pace) shows —/— (absent, never fabricated)" || no "quota F row: $(echo "$Q2OUT" | grep -E '^F ')"
echo "$Q2OUT" | grep -E '^H ' | grep -qE 'behind.*\+80'  && ok "quota: stale H still DISPLAYS its pace (R1: visible, but STATUS marks it stale)" || no "quota H row: $(echo "$Q2OUT" | grep -E '^H ')"
echo "$Q2OUT" | grep -E '^H ' | grep -q 'stale' && ok "quota: H STATUS column marks it stale (R1 visual marker)" || no "quota H status: $(echo "$Q2OUT" | grep -E '^H ')"

# Custom-source masking advisory: a bare-int custom source superseding a native
# row that DOES carry pace must gain the advisory note (R7); precedence itself
# is unchanged in this work item (T10 phase A).
HOMEDIR3=$(mktemp -d)
mkdir -p "$HOMEDIR3/config" "$HOMEDIR3/bin/quota-sources"
cp "$HOMEDIR2/config/model-surfaces.json" "$HOMEDIR3/config/model-surfaces.json"
cat > "$HOMEDIR3/bin/quota-sources/A.sh" <<'SRC'
#!/usr/bin/env bash
printf '{"surface":"A","status":"logged_in","headroom":50,"unit":"requests","models":["x"],"note":"authed reader"}\n'
SRC
chmod +x "$HOMEDIR3/bin/quota-sources/A.sh"
Q3OUT=$(FM_HOME="$HOMEDIR3" FM_FLEET_DIR="$FLEET2" PATH="$STUB2:$PATH" "$REAL/bin/fm-fleet.sh" quota)
echo "$Q3OUT" | grep -E '^A ' | grep -q 'custom int masks native pace' \
  && ok "quota: custom source masking a paced native row gets the advisory NOTE" \
  || no "masking advisory missing: $(echo "$Q3OUT" | grep -E '^A ')"
echo "$Q3OUT" | grep -E '^A ' | grep -qE '^A\s+50%\s+—\s+—' \
  && ok "quota: custom-source row itself renders —/— for PACE/RESERVE (never 'unknown')" \
  || no "custom row pace/reserve wrong: $(echo "$Q3OUT" | grep -E '^A ')"
rm -rf "$HOMEDIR3"

# --- T7 (§5.4): `fm_fleet_budget_ok` considers conservation pressure ----------
# fm_fleet_budget_ok/fm_fleet_pace_rows/fm_fleet_pressured are already sourced into
# THIS shell (T5), so call fm_fleet_budget_ok directly against minimal, purpose-built
# quota-axi stubs (budget's headroom is a GLOBAL min across every window of every
# provider, so a shared multi-surface fixture like $V3_FIXTURE would trip the raw
# floor on G's 3% before any pace branch could be exercised).
STUB4=$(mktemp -d)
budget_case() { # json -> sets BC_RC, BC_REASON
  cat > "$STUB4/quota-axi" <<EOF4
#!/usr/bin/env bash
cat <<'JSON4'
$1
JSON4
EOF4
  chmod +x "$STUB4/quota-axi"
  PATH="$STUB4:$PATH" fm_fleet_budget_ok; BC_RC=$?
  BC_REASON=$fm_fleet_budget_reason
}

[ "${FM_FLEET_RESERVE_MIN:-__unset__}" != __unset__ ] \
  && no "FM_FLEET_RESERVE_MIN should default via \${VAR:-default}, not be pre-set by the test" \
  || ok "FM_FLEET_RESERVE_MIN is unset in the test shell (library default -25 applies)"

budget_case '{"providers":[{"provider":"X","state":{"status":"fresh"},"windows":[{"percentRemaining":70,"pace":{"status":"behind","reservePercentPoints":20}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"pace":{"status":"behind","behindWindowIds":["w"],"aheadWindowIds":[],"worstReservePercentPoints":20}}]}}]}'
[ "$BC_RC" -eq 0 ] && echo "$BC_REASON" | grep -q '70%' && echo "$BC_REASON" | grep -q behind \
  && ok "budget: not pressured -> ok, names headroom+pace ($BC_REASON)" \
  || no "budget not-pressured case: rc=$BC_RC reason=$BC_REASON"

budget_case '{"providers":[{"provider":"Y","state":{"status":"fresh"},"windows":[{"percentRemaining":45,"pace":{"status":"ahead","reservePercentPoints":-10}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"pace":{"status":"ahead","aheadWindowIds":["w"],"worstReservePercentPoints":-10}}]}}]}'
[ "$BC_RC" -eq 0 ] && echo "$BC_REASON" | grep -q -- '-10' \
  && ok "budget: pressured but reserve -10 >= -25 -> ok ($BC_REASON)" \
  || no "budget pressured-ok case: rc=$BC_RC reason=$BC_REASON"

budget_case '{"providers":[{"provider":"Z","state":{"status":"fresh"},"windows":[{"percentRemaining":45,"pace":{"status":"mixed","reservePercentPoints":-31}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"pace":{"status":"mixed","aheadWindowIds":["w"],"worstReservePercentPoints":-31}}]}}]}'
[ "$BC_RC" -eq 1 ] && echo "$BC_REASON" | grep -q 'below pace floor' && echo "$BC_REASON" | grep -q -- '-31' \
  && ok "budget: pressured, reserve -31 < -25 -> below pace floor ($BC_REASON)" \
  || no "budget below-pace-floor case: rc=$BC_RC reason=$BC_REASON"
FM_FLEET_RESERVE_MIN=-100
budget_case '{"providers":[{"provider":"Z","state":{"status":"fresh"},"windows":[{"percentRemaining":45,"pace":{"status":"mixed","reservePercentPoints":-31}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"pace":{"status":"mixed","aheadWindowIds":["w"],"worstReservePercentPoints":-31}}]}}]}'
[ "$BC_RC" -eq 0 ] && ok "budget: FM_FLEET_RESERVE_MIN=-100 escape hatch disables the pace floor ($BC_REASON)" \
  || no "budget escape hatch failed: rc=$BC_RC reason=$BC_REASON"
unset FM_FLEET_RESERVE_MIN

budget_case '{"providers":[{"provider":"W","state":{"status":"fresh"},"windows":[{"percentRemaining":50,"pace":{"status":"ahead"}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"pace":{"status":"ahead","aheadWindowIds":["w"]}}]}}]}'
[ "$BC_RC" -eq 0 ] && echo "$BC_REASON" | grep -q unmeasurable \
  && ok "budget: pressured but reserve unmeasurable -> ok, fail-open ($BC_REASON)" \
  || no "budget reserve-absent fail-open case: rc=$BC_RC reason=$BC_REASON"

# R1: a STALE provider's terrible pace must not drive a refusal — only its raw
# headroom (unchanged legacy behavior) and DISPLAY (T6) are trusted.
budget_case '{"providers":[{"provider":"H2","state":{"status":"stale"},"windows":[{"percentRemaining":60,"pace":{"status":"ahead","reservePercentPoints":-99}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":60,"pace":{"status":"ahead","aheadWindowIds":["w"],"worstReservePercentPoints":-99}}]}}]}'
[ "$BC_RC" -eq 0 ] && echo "$BC_REASON" | grep -q 'no conservation pressure' \
  && ok "budget: stale provider's ahead pace (R1) is ignored, not a refusal ($BC_REASON)" \
  || no "budget R1 stale case: rc=$BC_RC reason=$BC_REASON"

rm -rf "$STUB4"

# --- T8 (§5.5): `fm_fleet_pick_surface` prefers sustainable over pressured ----
# Reuses STUB2/HOMEDIR2 (v3 fixture + test-only family map) from T6. One family
# isolates each upstream acceptance scenario so the answer is unambiguous.
[ "$(Q2 pick avb)" = B ] && ok "pick: higher-headroom-ahead (A,80%,-18) loses to lower-headroom-behind (B,55%,+20)" || no "pick avb -> $(Q2 pick avb) (expected B)"
[ "$(Q2 pick cvb)" = B ] && ok "pick: mixed+aheadWindowIds (C) treated as pressured, not healthy, vs B" || no "pick cvb -> $(Q2 pick cvb) (expected B)"
[ "$(Q2 pick acd)" = D ] && ok "pick: among pressured, -4 (D) beats -18 (A)" || no "pick acd -> $(Q2 pick acd) (expected D)"
[ "$(Q2 pick bve)" = B ] && ok "pick: known-sustainable (B) preferred over explicit unknown (E)" || no "pick bve -> $(Q2 pick bve) (expected B)"
[ "$(Q2 pick gvb)" = B ] && ok "pick: surface below FM_FLEET_QUOTA_MIN (G, 3%) excluded before any pace ordering" || no "pick gvb -> $(Q2 pick gvb) (expected B)"
[ "$(Q2 pick hvb)" = B ] && ok "pick: R1 — stale surface's pace (H) not trusted as 1a-sustainable, fresh B wins" || no "pick hvb -> $(Q2 pick hvb) (expected B)"
grep -B30 '^fm_fleet_pick_surface()' "$REAL/bin/fm-fleet-quota-lib.sh" | grep -qi 'OPERATOR-FACING DIAGNOSTIC' \
  && ok "pick: code comment states operator-facing diagnostic, never called from dispatch" \
  || no "pick: missing operator-facing-diagnostic code comment"
grep -B30 '^fm_fleet_pick_surface()' "$REAL/bin/fm-fleet-quota-lib.sh" | grep -qi 'documented OPERATOR preference' \
  && ok "pick: code comment states map order is a documented operator preference" \
  || no "pick: missing map-order-is-operator-preference code comment"

rm -rf "$STUB2" "$FLEET2" "$HOMEDIR2"

# --- G5 degradation proof: v2 stub outputs are byte-identical to the T3 golden -
# Rebuild the EXACT hermetic environment used for the T3 golden capture (same
# draining-claude $STUB payload, same $HOMEDIR/cursor+copilot overrides) and diff
# fresh output from the NOW-PACE-AWARE lib against the frozen pre-change files.
STUB5=$(mktemp -d)
cat > "$STUB5/quota-axi" <<'Q5'
#!/usr/bin/env bash
cat <<'JSON5'
{"providers":[
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":1}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":15}]},
 {"provider":"copilot","source":"unavailable","state":{"status":"auth_required"},"windows":[]},
 {"provider":"codex","source":"cli-rpc","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}
]}
JSON5
Q5
chmod +x "$STUB5/quota-axi"
HOMEDIR5=$(mktemp -d)
mkdir -p "$HOMEDIR5/config" "$HOMEDIR5/bin/quota-sources"
cp "$REAL/docs/examples/model-surfaces.json" "$HOMEDIR5/config/model-surfaces.json"
cat > "$HOMEDIR5/bin/quota-sources/cursor.sh" <<'CUR5'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.cursor // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"cursor","status":"logged_in","headroom":%s,"unit":"requests","models":["grok"],"note":"test"}\n' "$hr"
CUR5
chmod +x "$HOMEDIR5/bin/quota-sources/cursor.sh"
cat > "$HOMEDIR5/bin/quota-sources/copilot.sh" <<'COP5'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.copilot // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"copilot","status":"logged_in","headroom":%s,"unit":"premium interactions","models":["claude","gpt"],"note":"test"}\n' "$hr"
COP5
chmod +x "$HOMEDIR5/bin/quota-sources/copilot.sh"
printf '{"cursor":"echo 55","copilot":"echo 88"}\n' > "$HOMEDIR5/config/quota-overrides.json"
FLEET5=$(mktemp -d)
Q5(){ FM_HOME="$HOMEDIR5" FM_FLEET_DIR="$FLEET5" PATH="$STUB5:$PATH" "$REAL/bin/fm-fleet.sh" "$@" 2>&1; }

# `quota` legitimately GAINS two columns (PACE, RESERVE) even on a v2 payload —
# G5/§5.6 require every OTHER column byte-identical, not the whole line, since
# the two new columns didn't exist in the pre-pace golden at all. Strip them
# (fields 3,4) before comparing, and separately assert they render "—" everywhere.
Q5_QUOTA=$(Q5 quota)
Q5_QUOTA_OTHER=$(printf '%s\n' "$Q5_QUOTA" | awk '{print $1,$2,$5,$6,$7}')
GOLDEN_QUOTA_OTHER=$(awk '{print $1,$2,$3,$4,$5}' "$GOLDEN_DIR/v2-quota.golden")
Q5_QUOTA_ALL_DASH=$(printf '%s\n' "$Q5_QUOTA" | tail -n +2 | awk '$3!="—"||$4!="—"{bad=1} END{print bad+0}')
[ "$Q5_QUOTA_OTHER" = "$GOLDEN_QUOTA_OTHER" ] && [ "$Q5_QUOTA_ALL_DASH" = 0 ] \
  && ok "G5: v2 quota — other 5 columns byte-identical to T3 golden, PACE/RESERVE all —" \
  || no "G5: quota diverged (other-cols-match=$([ "$Q5_QUOTA_OTHER" = "$GOLDEN_QUOTA_OTHER" ] && echo yes || echo no) all-dash=$Q5_QUOTA_ALL_DASH)"
diff -q <(Q5 models)      "$GOLDEN_DIR/v2-models.golden"      >/dev/null 2>&1 && ok "G5: v2 models output byte-identical to T3 golden"      || no "G5: models diverged from golden"
diff -q <(Q5 pick grok)   "$GOLDEN_DIR/v2-pick-grok.golden"   >/dev/null 2>&1 && ok "G5: v2 pick grok byte-identical to T3 golden"           || no "G5: pick grok diverged from golden"
diff -q <(Q5 pick claude) "$GOLDEN_DIR/v2-pick-claude.golden" >/dev/null 2>&1 && ok "G5: v2 pick claude byte-identical to T3 golden"         || no "G5: pick claude diverged from golden"
diff -q <(Q5 pick kimi)   "$GOLDEN_DIR/v2-pick-kimi.golden"   >/dev/null 2>&1 && ok "G5: v2 pick kimi byte-identical to T3 golden"           || no "G5: pick kimi diverged from golden"
diff -q <(Q5 pick bogus)  "$GOLDEN_DIR/v2-pick-bogus.golden"  >/dev/null 2>&1 && ok "G5: v2 pick bogus byte-identical to T3 golden"          || no "G5: pick bogus diverged from golden"
diff -q <({ Q5 budget; echo "exit=$?"; }) "$GOLDEN_DIR/v2-budget.golden" >/dev/null 2>&1 && ok "G5: v2 budget (message+exit) byte-identical to T3 golden" || no "G5: budget diverged from golden"
rm -rf "$STUB5" "$HOMEDIR5" "$FLEET5"

# --- T11: empty bin/quota-sources/ regression (survives Phase-B retirement) ---
# After a future Phase-B deletion (T10/§7), the glob "$base"/bin/quota-sources/*.sh
# matches nothing and (without nullglob) expands to the literal unmatched pattern;
# the existing `[ -f "$f" ] || continue` guard covers this — but it was NEVER
# exercised until now. `quota` must still render native rows and exit 0.
STUB6=$(mktemp -d)
cat > "$STUB6/quota-axi" <<'Q6'
#!/usr/bin/env bash
cat <<'JSON6'
{"providers":[{"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":42}]}]}
JSON6
Q6
chmod +x "$STUB6/quota-axi"
HOMEDIR6=$(mktemp -d)
mkdir -p "$HOMEDIR6/config" "$HOMEDIR6/bin/quota-sources"   # present but EMPTY — no *.sh files
cp "$REAL/docs/examples/model-surfaces.json" "$HOMEDIR6/config/model-surfaces.json"
FLEET6=$(mktemp -d)
Q6OUT=$(FM_HOME="$HOMEDIR6" FM_FLEET_DIR="$FLEET6" PATH="$STUB6:$PATH" "$REAL/bin/fm-fleet.sh" quota); Q6_RC=$?
[ "$Q6_RC" -eq 0 ] && ok "T11: quota exits 0 with an empty bin/quota-sources/ dir" || no "T11: quota exit=$Q6_RC with empty quota-sources/"
echo "$Q6OUT" | grep -qE '^claude\s+42%' && ok "T11: quota still renders the native claude row with quota-sources/ empty" || no "T11: native row missing: $Q6OUT"
rm -rf "$STUB6" "$HOMEDIR6" "$FLEET6"

echo "-----"
[ "$fail" -eq 0 ] && echo "ALL PASS ($pass)" || { echo "$fail FAILED"; exit 1; }
