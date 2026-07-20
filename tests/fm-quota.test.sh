#!/usr/bin/env bash
# tests/fm-quota.test.sh - bin/fm-quota.sh combine + recommendation logic.
#
# Deterministic and offline: the two live sources are replaced with fixtures via
# the script's env overrides. FM_QUOTA_AXI points at a fake quota-axi that cats a
# fixture on --json; FM_QUOTA_BUN points at a fake `bun` that cats a balancer
# fixture regardless of args; FM_QUOTA_CLAUDE_CLI points at a readable stub so the
# balancer branch is taken. This exercises the non-trivial logic - source merge,
# candidate scoring, hard-exclusion of rate-limited/unavailable providers, and the
# DeepSeek fallback - without touching the network or any real account.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUOTA="$ROOT/bin/fm-quota.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Fake quota-axi: prints $FMQ_QUOTA_FIXTURE on any invocation.
FAKE_QUOTA="$TMP/quota-axi"
cat > "$FAKE_QUOTA" <<'FAKE'
#!/usr/bin/env bash
cat "$FMQ_QUOTA_FIXTURE"
FAKE
chmod +x "$FAKE_QUOTA"

# Fake bun: ignores `run <cli> balance --json`, prints $FMQ_CLAUDE_FIXTURE.
FAKE_BUN="$TMP/bun"
cat > "$FAKE_BUN" <<'FAKE'
#!/usr/bin/env bash
cat "$FMQ_CLAUDE_FIXTURE"
FAKE
chmod +x "$FAKE_BUN"

STUB_CLI="$TMP/cli.ts"  # just needs to be readable
echo "// stub" > "$STUB_CLI"

# quota-axi fixtures
cat > "$TMP/codex-high.json" <<'JSON'
{"providers":[{"provider":"codex","label":"Codex","source":"cli-rpc","windows":[{"percentRemaining":80}],"state":{"status":"fresh"}}]}
JSON
cat > "$TMP/codex-low.json" <<'JSON'
{"providers":[{"provider":"codex","label":"Codex","source":"cli-rpc","windows":[{"percentRemaining":30}],"state":{"status":"fresh"}}]}
JSON
cat > "$TMP/codex-signedout.json" <<'JSON'
{"providers":[{"provider":"codex","label":"Codex","source":"unavailable","windows":[],"state":{"status":"auth_required"}}]}
JSON

# balancer fixtures
cat > "$TMP/claude-mid.json" <<'JSON'
{"account":"arcs","scores":[{"account":"arcs","rollingPct":0.5,"paceStatus":"on-pace","activeSessions":0,"rateLimited":false}],"weeklyPct":0.4,"allRateLimited":false}
JSON
cat > "$TMP/claude-fresh.json" <<'JSON'
{"account":"arcs","scores":[{"account":"arcs","rollingPct":0.1,"paceStatus":"on-pace","activeSessions":0,"rateLimited":false}],"weeklyPct":0.1,"allRateLimited":false}
JSON
cat > "$TMP/claude-ratelimited.json" <<'JSON'
{"account":"arcs","scores":[{"account":"arcs","rollingPct":0.9,"paceStatus":"over-pace","activeSessions":0,"rateLimited":true}],"weeklyPct":0.9,"allRateLimited":true}
JSON

run() { # $1=quota fixture $2=claude fixture -> combined JSON on stdout
  FM_QUOTA_AXI="$FAKE_QUOTA" FM_QUOTA_BUN="$FAKE_BUN" FM_QUOTA_CLAUDE_CLI="$STUB_CLI" \
    FMQ_QUOTA_FIXTURE="$1" FMQ_CLAUDE_FIXTURE="$2" \
    "$QUOTA" --json 2>/dev/null
}

# Case 1: codex (80%) beats claude (min(0.6,0.5)=50%) -> pi-codex.
pick=$(run "$TMP/codex-high.json" "$TMP/claude-mid.json" | jq -r '.recommendation.pick')
[ "$pick" = "pi-codex" ] || fail "codex-high: expected pi-codex, got '$pick'"
[ "$pick" = "pi-codex" ] && pass "codex with more headroom wins"

# Case 2: claude fresh (90%) beats codex (30%) -> claude-opus.
pick=$(run "$TMP/codex-low.json" "$TMP/claude-fresh.json" | jq -r '.recommendation.pick')
case "$pick" in
  claude-opus*) pass "claude with more headroom wins" ;;
  *) fail "claude-fresh: expected claude-opus*, got '$pick'" ;;
esac

# Case 3: claude all rate-limited + codex signed out -> deepseek fallback.
out=$(run "$TMP/codex-signedout.json" "$TMP/claude-ratelimited.json")
pick=$(printf '%s' "$out" | jq -r '.recommendation.pick')
[ "$pick" = "deepseek (ds) fallback" ] || fail "all-exhausted: expected deepseek fallback, got '$pick'"
[ "$pick" = "deepseek (ds) fallback" ] && pass "deepseek fallback when nothing has headroom"

# Case 4: rate-limited seat is excluded from claude candidacy (no claude in alts).
alt=$(printf '%s' "$out" | jq -r '[.recommendation.alternatives[].pick] | join(",")')
case "$alt" in
  *claude*) fail "rate-limited claude leaked into alternatives: '$alt'" ;;
  *) pass "rate-limited claude excluded from candidates" ;;
esac

# Case 5: output is always valid JSON with the documented top-level keys.
if run "$TMP/codex-high.json" "$TMP/claude-mid.json" \
    | jq -e 'has("generatedAt") and has("claude") and has("providers") and has("recommendation")' >/dev/null; then
  pass "combined JSON has documented top-level keys"
else
  fail "combined JSON missing documented keys"
fi

# Case 6: both sources absent -> still valid JSON, deepseek fallback, no crash.
both=$(FM_QUOTA_AXI=/nonexistent FM_QUOTA_CLAUDE_CLI=/nonexistent "$QUOTA" --json 2>/dev/null)
if printf '%s' "$both" | jq -e '.recommendation.pick == "deepseek (ds) fallback" and .claude == null' >/dev/null; then
  pass "both sources absent degrades to valid deepseek fallback"
else
  fail "both absent did not degrade cleanly: '$both'"
fi

exit $FAILED
