#!/usr/bin/env bash
# Cross-operator overflow on token drain (Plan 3 Task 18). Run from the repo root:
#   bash tests/federation/test_fleet_drain.sh
# When the operator holding (or scoped to own) an item is drained (published quota
# below FM_FLEET_QUOTA_MIN), the item migrates to an operator whose published quota
# shows headroom, reusing fm_fleet_route's priority (scope-owner >
# overflow-designated > any-with-headroom). A per-item handoff counter
# (handoffs:N) is capped at FM_FLEET_HANDOFF_CAP (default 3) so a fully-drained
# fleet cannot ping-pong an item forever; on exhaustion (cap reached or no
# operator has headroom) the item is left with an explicit status:drained
# ("fleet out of tokens") state rather than silently dropping it.
#
# The live drained-account acceptance (Plan 3 Task 18 Step 5 [USER]) is DEFERRED:
# it needs a genuinely exhausted subscription, which cannot be faked locally.
#
# operators.md row schema:
#   | <op> | <scopes> | <home> | <accounts> | <status> | <seen-iso> | <quota%|-> |
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
CLI="bin/fm-fleet.sh"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

D=$(mktemp -d); export FM_FLEET_DIR="$D/fleet"
# A generous heartbeat TTL keeps the fixed fixture timestamps inside the
# freshness window (the real quota-axi is not consulted - quotas are pinned below).
export FM_FLEET_HEARTBEAT_TTL=3600

# set_quota <op> <scopes> <quota>  - rewrite the operator row with a pinned quota
# and a FRESH seen timestamp (so the operator reads as online+headroom, never
# stale). # is the sed delimiter so the / in $HOME does not clash with the pattern.
set_quota() {
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sed -i "s#^| *$1 *|.*\$#| $1 | $2 | $HOME/kun-agent-workspace | claude-default | online | $now | $3 |#" "$FM_FLEET_DIR/operators.md"
}

"$CLI" init >/dev/null
"$CLI" register adi backend,infra "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
"$CLI" register barf-ai overflow "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1

# 1. Route: scope-owner drained (adi quota=0), another operator with headroom
#    (barf-ai quota=80) -> routes to barf-ai (the any-with-headroom fallback,
#    not only the overflow-designated operator). (Task 18 Step 1.)
set_quota adi backend,infra 0
set_quota barf-ai overflow 80
out=$("$CLI" route backend)
[ "$out" = barf-ai ] && ok "route: drained scope-owner routes to any eligible operator with headroom" || bad "route drained scope-owner (got '$out', expected barf-ai)"

# 2. Drain handoff: item claimed by drained adi -> migrates to barf-ai, stamping
#    claimed-by:barf-ai and incrementing handoffs:1 in the item line.
"$CLI" queue task-1 backend "test task" >/dev/null 2>&1
"$CLI" claim task-1 adi >/dev/null 2>&1
set_quota adi backend,infra 0
out=$("$CLI" drain task-1 2>&1)
[ "$out" = barf-ai ] && ok "drain: claimed-by drained operator migrates to an operator with headroom" || bad "drain handoff (got '$out', expected barf-ai)"
grep -q "\[id:task-1\].*claimed-by:barf-ai@.*handoffs:1" "$FM_FLEET_DIR/backlog.md" \
  && ok "drain: handoff stamps claimed-by:barf-ai + handoffs:1" || bad "drain: handoff stamp missing"

# 3. Handoff cap + exhausted state: with handoffs already at the cap (3) and
#    every operator drained, the next drain leaves the item status:drained
#    ("fleet out of tokens") instead of a fourth handoff.
sed -i 's/\[id:task-1\] claimed-by:barf-ai@[^ ]* /[id:task-1] claimed-by:barf-ai@dummy /' "$FM_FLEET_DIR/backlog.md"
sed -i "s/\[id:task-1\] /[id:task-1] handoffs:3 /" "$FM_FLEET_DIR/backlog.md"
set_quota barf-ai overflow 0
out=$("$CLI" drain task-1 2>&1)
[ "$out" = drained ] && ok "drain: cap reached + all drained -> status:drained (no ping-pong)" || bad "drain exhaustion (got '$out', expected drained)"
grep -q "\[id:task-1\].*status:drained" "$FM_FLEET_DIR/backlog.md" \
  && ok "drain: item line shows status:drained (fleet out of tokens)" || bad "drain: status:drained missing"

# 4. Unchanged: the holder still has headroom -> no migration, reports unchanged.
set_quota barf-ai overflow 80
set_quota adi backend,infra 50
"$CLI" queue task-2 backend "another task" >/dev/null 2>&1
"$CLI" claim task-2 adi >/dev/null 2>&1
out=$("$CLI" drain task-2 2>&1)
[ "$out" = unchanged ] && ok "drain: holder with headroom reports unchanged" || bad "drain unchanged (got '$out', expected unchanged)"

# 5. Absent: a non-existent item returns 1 (loud failure, not silent success).
out=$("$CLI" drain nonexistent 2>&1; echo "rc=$?")
[ "${out##*rc=}" = 1 ] && ok "drain: absent item returns 1" || bad "drain absent (got '$out')"

echo "-----"
[ "$fails" -eq 0 ] && { echo "ALL PASS: fm-fleet-drain"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }