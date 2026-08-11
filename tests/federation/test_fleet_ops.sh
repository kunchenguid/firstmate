#!/usr/bin/env bash
# Operator-lifecycle + token-economy tests (fleet-ops). Run from ~/firstmate:
#   bash tests/federation/test_fleet_ops.sh
# Exercises the per-operator lifecycle that makes each user's own firstmate joinable,
# in-sync, and token-cheap:
#   register (self-onboard, upsert, own-home-only), heartbeat (refresh seen+quota),
#   leave (offline), online = status:online AND heartbeat-fresh AND quota>=floor,
#   quota-aware routing (published headroom, no cross-user auth), and fm_fleet_budget_ok.
#
# operators.md row schema (backward-compatible superset of the 5-col form):
#   | <op> | <scopes> | <home> | <accounts> | <status> | <seen-iso> | <quota%|-> |
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
CLI="bin/fm-fleet.sh"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. bin/fm-fleet-lib.sh

now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
old_iso(){ echo "2000-01-01T00:00:00Z"; }

# macOS is a declared supported platform and bin/fm-fleet-lib.sh is already
# BSD-first, but these tests were not. BSD `sed -i` REQUIRES a backup-suffix
# argument; the GNU form `sed -i EXPR FILE` makes BSD read EXPR as the suffix and
# FILE as the script, so it errors to stderr and leaves the file UNTOUCHED. Every
# such call here silently did nothing, and because the mutation is what sets up
# the scenario, the assertions that followed tested the unmutated state - the
# stale-heartbeat and quota-ceiling cases were vacuous on macOS, not failing
# honestly. Ported via the same shim shape tests/fm-admiral-optin.test.sh uses.
fm_portable_sed_i(){ # <expr> <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then sed -i '' "$1" "$2"
  else sed -i "$1" "$2"; fi
}
# `date -u -d` is GNU-only. BSD parses with `-j -f <fmt>`. Mirrors the BSD-first,
# GNU-fallback order bin/fm-fleet-lib.sh:46 already uses.
iso_parses(){ # <iso-8601>
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" >/dev/null 2>&1 \
    || date -u -d "$1" >/dev/null 2>&1
}

quota_col() { # operators.md op -> quota column, trimmed
  awk -F'|' -v op="$2" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    trim($2)==op { print trim($8) }
  ' "$1"
}
seen_col() { # operators.md op -> seen column, trimmed
  awk -F'|' -v op="$2" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    trim($2)==op { print trim($7) }
  ' "$1"
}
operator_count() { # operators.md op -> exact row count
  awk -F'|' -v op="$2" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    trim($2)==op { n++ }
    END { print n + 0 }
  ' "$1"
}
backlog_line_for_id() { # backlog.md id -> exact item line
  awk -v id="$2" '
    function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
    item_id($0)==id { print; exit }
  ' "$1"
}

# --- Hermeticity (Fable #3): stub quota-axi so register/heartbeat/route never
# depend on the operator's real, wall-clock-varying quota-axi state. Cases below
# drive bin/fm-fleet.sh and bin/fm-fleet-join.sh as SUBPROCESSES, so the stub must
# be exported on PATH (inherited), not just prefixed per-command. ORIG_PATH is
# captured before the export so the retained live-integration case (bottom of this
# file) can restore the real environment. Rewritable mid-suite via FAKE_QUOTA_JSON
# (same idiom case 6 below already uses), so the quota-floor assertions can flip
# headroom without rebuilding the stub file. Named SUITE_STUB, distinct from case
# 6's own local $STUB var, whose per-command PATH prefix must keep taking priority
# over this suite-level export (prepend wins; case 6 is untouched).
command -v jq >/dev/null 2>&1 || { echo "fm-fleet-ops tests require jq to decode the hermetic stub; install jq." >&2; exit 2; }
ORIG_PATH="$PATH"
SUITE_STUB=$(mktemp -d)
cat > "$SUITE_STUB/quota-axi" <<'Q'
#!/usr/bin/env bash
echo "$FAKE_QUOTA_JSON"
Q
chmod +x "$SUITE_STUB/quota-axi"
export FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":42}]}]}'
export PATH="$SUITE_STUB:$PATH"

# 1. register self-onboards a fresh online row that route finds
D=$(mktemp -d); export FM_FLEET_DIR="$D/fleet"; unset FM_FLEET_HEARTBEAT_TTL FM_FLEET_QUOTA_MIN
"$CLI" init >/dev/null
"$CLI" register alice backend,infra "$HOME/firstmate" claude-default >/dev/null 2>&1
grep -qE "^\| *alice *\|" "$FM_FLEET_DIR/operators.md" && ok "register writes an operator row" || bad "register writes row"
q=$(quota_col "$FM_FLEET_DIR/operators.md" alice)
[ "$q" = 42 ] && ok "register writes the stubbed quota value into the quota column" || bad "register quota column (got '$q', want 42)"
[ "$("$CLI" route backend)" = alice ] && ok "route finds a freshly-registered operator" || bad "route fresh register (got '$("$CLI" route backend)')"

# 2. register is idempotent (upsert, not duplicate)
"$CLI" register alice backend,infra "$HOME/firstmate" claude-default >/dev/null 2>&1
n=$(grep -cE "^\| *alice *\|" "$FM_FLEET_DIR/operators.md")
[ "$n" -eq 1 ] && ok "register is idempotent (one row)" || bad "register duplicated (n=$n)"

# 2b. punctuated identifiers are compared literally, never as regex fragments
DREG=$(mktemp -d); export FM_FLEET_DIR="$DREG/fleet"; "$CLI" init >/dev/null
"$CLI" register john.doe backend "$HOME/firstmate" claude-default >/dev/null 2>&1
"$CLI" register johnXdoe overflow "$HOME/firstmate" claude-default >/dev/null 2>&1
"$CLI" register john.doe backend "$HOME/firstmate" claude-default >/dev/null 2>&1
[ "$(operator_count "$FM_FLEET_DIR/operators.md" john.doe)" -eq 1 ] \
  && [ "$(operator_count "$FM_FLEET_DIR/operators.md" johnXdoe)" -eq 1 ] \
  && ok "register treats punctuated operator ids literally" \
  || bad "register regex-matched a neighboring operator id"
"$CLI" queue A21 backend "neighbor id" >/dev/null 2>&1
"$CLI" queue A.1 backend "punctuated id" >/dev/null 2>&1 \
  || bad "queue treated A.1 as a duplicate of A21"
"$CLI" claim A.1 john.doe >/dev/null 2>&1 \
  || bad "claim failed for punctuated task id"
line_dot=$(backlog_line_for_id "$FM_FLEET_DIR/backlog.md" A.1)
line_plain=$(backlog_line_for_id "$FM_FLEET_DIR/backlog.md" A21)
case "$line_dot" in *"claimed-by:john.doe@"*"status:claimed"*) dot_ok=1 ;; *) dot_ok=0 ;; esac
case "$line_plain" in *"status:queued"*) plain_ok=1 ;; *) plain_ok=0 ;; esac
[ "$dot_ok" -eq 1 ] && [ "$plain_ok" -eq 1 ] \
  && ok "claim treats punctuated task ids literally" \
  || bad "claim regex-matched neighboring task ids (A.1='$line_dot' A21='$line_plain')"
"$CLI" claim A21 johnXdoe >/dev/null 2>&1 \
  || bad "claim failed for neighboring operator id"
wait_out=$(bin/fm-fleet-wait.sh john.doe --once --no-heartbeat 2>/dev/null || true)
[ "$wait_out" = "[id:A.1]" ] \
  && ok "wait treats punctuated operator ids literally" \
  || bad "wait regex-matched neighboring operator ids (got '$wait_out')"
"$CLI" register scopeX apiXv2 "$HOME/firstmate" claude-default >/dev/null 2>&1
"$CLI" register scope.dot api.v2 "$HOME/firstmate" claude-default >/dev/null 2>&1
r=$("$CLI" route api.v2)
[ "$r" = scope.dot ] \
  && ok "route treats punctuated scopes literally" \
  || bad "route regex-matched a neighboring scope (got '$r')"
export FM_FLEET_DIR="$D/fleet"

# 3. heartbeat refreshes seen; a stale operator routes as offline
"$CLI" register bob web,mobile "$HOME/firstmate" claude-default >/dev/null 2>&1
"$CLI" register carol overflow "$HOME/firstmate" claude-default >/dev/null 2>&1
# force bob's seen stale (replace the seen column in bob's row with an old ts)
fm_portable_sed_i "/^| bob /s#| [0-9][0-9TZ:-]\{1,\} |#| $(old_iso) |#" "$FM_FLEET_DIR/operators.md"
# robustness post-condition: the sed must have hit the seen column, not quota (§5.4) —
# with a two-digit stubbed quota the same pattern could also match col 8 if columns
# ever reorder; this would otherwise be a silently-vacuous test.
stale_seen=$(seen_col "$FM_FLEET_DIR/operators.md" bob)
[ "$stale_seen" = "$(old_iso)" ] && ok "stale-forcing sed hit the seen column (robustness check)" || bad "stale sed hit wrong column (seen='$stale_seen')"
export FM_FLEET_HEARTBEAT_TTL=90
r=$("$CLI" route web)
[ "$r" = carol ] && ok "route: stale-heartbeat operator treated offline -> overflow" || bad "route stale->overflow (got '$r')"
# heartbeat bob back to fresh -> seen genuinely advances, and route returns bob
"$CLI" heartbeat bob >/dev/null 2>&1
fresh_seen=$(seen_col "$FM_FLEET_DIR/operators.md" bob)
{ [ -n "$fresh_seen" ] && [ "$fresh_seen" != "$stale_seen" ] && iso_parses "$fresh_seen"; } \
  && ok "heartbeat refreshes seen: advances past the stale value and parses as a timestamp" \
  || bad "heartbeat seen advance (stale='$stale_seen' fresh='$fresh_seen')"
r=$("$CLI" route web)
[ "$r" = bob ] && ok "heartbeat refreshes seen -> operator online again" || bad "heartbeat refresh (got '$r')"

# 4. leave marks offline -> route skips to overflow
"$CLI" leave bob >/dev/null 2>&1
r=$("$CLI" route web)
[ "$r" = carol ] && ok "leave -> offline -> overflow" || bad "leave offline (got '$r')"

# 5. quota-aware routing: publish low headroom for the scope owner -> skip to overflow
D2=$(mktemp -d); export FM_FLEET_DIR="$D2/fleet"
"$CLI" init >/dev/null
ts=$(now_iso)
cat >> "$FM_FLEET_DIR/operators.md" <<OPS
| alice | backend | $HOME/firstmate | claude-default | online | $ts | 3 |
| carol | overflow | $HOME/firstmate | claude-default | online | $ts | 80 |
OPS
export FM_FLEET_QUOTA_MIN=5
r=$("$CLI" route backend)
[ "$r" = carol ] && ok "route: owner below quota floor -> overflow" || bad "route quota floor (got '$r')"
# raise alice's quota -> owner wins again
fm_portable_sed_i "/^| alice /s#| 3 |#| 50 |#" "$FM_FLEET_DIR/operators.md"
r=$("$CLI" route backend)
[ "$r" = alice ] && ok "route: owner above quota floor -> owner" || bad "route quota ok (got '$r')"

# 5b. register -> quota column -> route chain, via the REAL register path (not
# hand-written rows like case 5): flip the stub low then high and re-register,
# proving the whole chain rather than just route's own awk logic. This turns
# today's accidental live-quota failure into the suite's strongest intentional
# assertion (§5.4 item 3) — the case that would catch a regression anywhere in
# register -> quota column -> route.
export FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":2}]}]}'
"$CLI" register alice backend "$HOME/firstmate" claude-default >/dev/null 2>&1
q=$(quota_col "$FM_FLEET_DIR/operators.md" alice)
[ "$q" = 2 ] && ok "re-register with low stub writes quota=2" || bad "re-register low stub quota (got '$q')"
r=$("$CLI" route backend)
[ "$r" = carol ] && ok "register->quota->route: low-headroom re-register falls through to overflow" || bad "register->route low (got '$r')"
export FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":80}]}]}'
"$CLI" register alice backend "$HOME/firstmate" claude-default >/dev/null 2>&1
q=$(quota_col "$FM_FLEET_DIR/operators.md" alice)
[ "$q" = 80 ] && ok "re-register with high stub writes quota=80" || bad "re-register high stub quota (got '$q')"
r=$("$CLI" route backend)
[ "$r" = alice ] && ok "register->quota->route: high-headroom re-register restores the owner" || bad "register->route high (got '$r')"
export FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":42}]}]}'

# 6. fm_fleet_budget_ok reflects a stubbed quota-axi min headroom vs floor
STUB=$(mktemp -d)
cat > "$STUB/quota-axi" <<'Q'
#!/usr/bin/env bash
echo "$FAKE_QUOTA_JSON"
Q
chmod +x "$STUB/quota-axi"
export FM_FLEET_QUOTA_MIN=5
FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":40}]}]}' \
  PATH="$STUB:$PATH" fm_fleet_budget_ok && ok "budget_ok: above floor passes" || bad "budget_ok above floor"
FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":2}]}]}' \
  PATH="$STUB:$PATH" fm_fleet_budget_ok && bad "budget_ok below floor should fail" || ok "budget_ok: below floor fails"

# 7. register refuses a foreign home (cross-uid safety)
D3=$(mktemp -d); export FM_FLEET_DIR="$D3/fleet"; "$CLI" init >/dev/null
"$CLI" register evil backend /home/someoneelse/firstmate claude-default >/dev/null 2>&1 \
  && bad "register accepted a foreign home" || ok "register refuses a foreign home"

# 8. fm-fleet-wait.sh (token economy): a fresh claim wakes; nothing else does
D4=$(mktemp -d); export FM_FLEET_DIR="$D4/fleet"; "$CLI" init >/dev/null
"$CLI" register alice backend "$HOME/firstmate" claude-default >/dev/null 2>&1
"$CLI" queue W-1 backend "wake item" >/dev/null; "$CLI" claim W-1 alice >/dev/null
out=$(bin/fm-fleet-wait.sh alice --once --no-heartbeat); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'W-1'; } && ok "wait --once: fresh claim wakes (exit 0 + id)" || bad "wait fresh claim (rc=$rc out='$out')"
bin/fm-fleet-wait.sh bob --once --no-heartbeat >/dev/null 2>&1 && bad "wait woke with no claim" || ok "wait --once: no claim -> exit 1 (LLM stays idle)"
fm_portable_sed_i 's/\(W-1.*\)status:claimed/\1status:in-flight/' "$FM_FLEET_DIR/backlog.md"
bin/fm-fleet-wait.sh alice --once --no-heartbeat >/dev/null 2>&1 && bad "wait woke on in-flight (already started)" || ok "wait --once: in-flight item is not a fresh wake"

# 9. fm-fleet-join.sh: self-onboard writes config/fleet-dir + registers; idempotent.
# HOME is overridden to a temp home so the own-home guard passes for the fixture.
JH=$(mktemp -d)/home; mkdir -p "$JH"; JF=$(mktemp -d)/fleet
FM_FLEET_DIR="$JF" "$CLI" init >/dev/null
out=$(HOME="$JH" FM_HOME="$JH" FM_FLEET_DIR="$JF" bin/fm-fleet-join.sh alice backend claude-default 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$JH/config/fleet-dir" 2>/dev/null)" = "$JF" ] && grep -qE "^\| *alice *\|" "$JF/operators.md"; } \
  && ok "join: writes config/fleet-dir + registers self" || bad "join (rc=$rc)"
HOME="$JH" FM_HOME="$JH" FM_FLEET_DIR="$JF" bin/fm-fleet-join.sh alice backend claude-default >/dev/null 2>&1
n=$(grep -cE "^\| *alice *\|" "$JF/operators.md"); [ "$n" -eq 1 ] && ok "join: idempotent (one row on rejoin)" || bad "join dup (n=$n)"

# 10. LIVE fm_fleet_quota_now: real quota-axi/jq (or their absence), bounded and
# shape-only (G3). This is the suite's only genuine coverage that quota-axi --json
# | jq still produces something fm_fleet_quota_now can parse — never a threshold
# (that is precisely the false red the rest of this file just removed). '-' is a
# pass (quota-axi absent, jq absent, or no provider signed in); so is any
# fractional percentage.
live_q=$(PATH="$ORIG_PATH" timeout 10 bash -c '. bin/fm-fleet-lib.sh; fm_fleet_quota_now'); live_rc=$?
{ [ "$live_rc" -eq 0 ] && printf '%s' "$live_q" | grep -qE '^(-|[0-9]+(\.[0-9]+)?)$'; } \
  && ok "quota_now (LIVE, real quota-axi): returns a percentage or '-', never garbage" \
  || bad "quota_now LIVE (rc=$live_rc got '$live_q')"

echo "-----"
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
