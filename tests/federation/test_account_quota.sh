#!/usr/bin/env bash
# Quota-aware account selection test (Phase 4, Task 12). Run from ~/firstmate:
#   bash tests/federation/test_account_quota.sh
# A stub quota-axi returns headroom that DEPENDS on the isolation env it runs
# under (CLAUDE_CONFIG_DIR), so this exercises the full isolate-then-query chain:
# pick highest headroom; tie -> first registered; quota-axi absent -> first;
# harness with no quota coverage (pi) -> first.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FM_HOME="$(pwd)"; export FM_HOME
# shellcheck source=bin/fm-accounts-lib.sh disable=SC1091
. bin/fm-accounts-lib.sh
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d); export FM_ACCOUNTS_FILE="$TMP/accounts.json"

# stub quota-axi: headroom encoded in CLAUDE_CONFIG_DIR (proves isolation is applied)
STUB="$TMP/quota-stub.sh"
cat > "$STUB" <<'S'
#!/usr/bin/env bash
hr=10
case "${CLAUDE_CONFIG_DIR:-}" in
  *high*) hr=90 ;;
  *low*)  hr=20 ;;
esac
printf '{"providers":[{"provider":"claude","windows":[{"percentRemaining":%s}]}]}\n' "$hr"
S
chmod +x "$STUB"
export QUOTA_AXI_BIN="$STUB"

# Case A: highest headroom wins
cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "claude-high": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$TMP/high","scopes":["backend"]},
  "claude-low":  {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$TMP/low","scopes":["backend"]}
}
JSON
p=$(fm_account_pick claude 2>/dev/null)
[ "$p" = "claude-high" ] && ok "pick highest headroom (90 > 20)" || bad "pick highest (got '$p')"

# Case A2: quota-axi absent -> first registered
p=$(QUOTA_AXI_BIN="/nonexistent/quota-axi" fm_account_pick claude 2>/dev/null)
first=$(fm_account_list_by_harness claude | head -1)
[ "$p" = "$first" ] && ok "quota-axi absent -> first registered ($first)" || bad "absent fallback (got '$p' want '$first')"

# Case B: harness with no quota coverage (pi) -> first registered
cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "pi-a": {"provider":"pi","harness":"pi","isolation":"config-dir-env","env":"PI_CODING_AGENT_DIR","config_dir":"$TMP/pa","scopes":["x"]},
  "pi-b": {"provider":"pi","harness":"pi","isolation":"config-dir-env","env":"PI_CODING_AGENT_DIR","config_dir":"$TMP/pb","scopes":["y"]}
}
JSON
p=$(fm_account_pick pi 2>/dev/null)
[ "$p" = "pi-a" ] && ok "no quota provider -> first (pi-a)" || bad "no-provider fallback (got '$p')"

# Case C: tie -> first registered
cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "claude-eqa": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$TMP/eqa","scopes":["backend"]},
  "claude-eqb": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$TMP/eqb","scopes":["backend"]}
}
JSON
p=$(fm_account_pick claude 2>/dev/null)
[ "$p" = "claude-eqa" ] && ok "tie -> first registered (claude-eqa)" || bad "tie-break (got '$p')"

# Case D: single account -> that account (no quota call needed)
cat > "$FM_ACCOUNTS_FILE" <<JSON
{ "solo": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$TMP/solo","scopes":["backend"]} }
JSON
p=$(fm_account_pick claude 2>/dev/null)
[ "$p" = "solo" ] && ok "single account picked directly" || bad "single (got '$p')"

rm -rf "$TMP"
echo "-----"; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
