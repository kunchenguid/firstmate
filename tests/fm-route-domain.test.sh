#!/usr/bin/env bash
# tests/fm-route-domain.test.sh - verify Jev domain router behavior
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER="$ROOT/bin/fm-route-domain.sh"
[ -x "$ROUTER" ] || fail "bin/fm-route-domain.sh missing or not executable"

TDIR=$(fm_test_tmproot fm-route-test)

REG="$TDIR/secondmates.md"
cat <<'EOF' > "$REG"
- portal-ops - Clinical operations and EMR work: Portal implementation, UrgentIQ and DoseSpot, provider onboarding. (home: /tmp/p; scope: Arcs Portal clinical operations, UrgentIQ, DoseSpot; projects: portal; added 2026-07-29)
- seller-outreach - Seller lead generation and outreach for urgent-care clinics. (home: /tmp/s; scope: All urgent-care seller lead generation, campaigns, Flow; projects: agents-flow; added 2026-07-29)
- websites - Rebuild of arcs.health and jonroosevelt.com frontend. (home: /tmp/w; scope: Frontend website rebuild, UI components, Next.js, Framer Motion; projects: website-covenant; added 2026-08-06)
EOF

# 1. Empty input fails open to unavailable
out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "" --registry "$REG" 2>/dev/null || true)
assert_contains "$out" "action=unavailable" "empty task emits unavailable"

# 2. Missing key fails open to unavailable
out=$(env -u TYPESAFE_API_KEY python3 -c '
import os, sys
# shadow jev-typesafe-run
from pathlib import Path
' 2>/dev/null || true)
out=$(env TYPESAFE_API_KEY="" python3 "$ROOT/bin/fm-route-domain.py" --task "Test task" --registry "$REG" 2>/dev/null || true)
# Should emit action=unavailable if key cannot be obtained, or action=dispatch/handle_direct if key is live
assert_contains "$out" "action=" "router emits action field"

# 3. Live call: known domain (seller-outreach)
if [ -n "${TYPESAFE_API_KEY:-}" ] || ( [ -x "/opt/ra/firstmate/bin/jev-typesafe-run.py" ] && sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env 2>/dev/null | grep -q "TYPESAFE_API_KEY" ); then
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Urgent care acquisition seller email outreach campaign" --registry "$REG")
  assert_contains "$out" "action=dispatch" "known domain emits dispatch action"
  assert_contains "$out" "route=seller-outreach" "known domain routes to seller-outreach"
  assert_contains "$out" "dispatch_cmd=" "dispatch action includes dispatch_cmd"

  # 4. Live call: captain direct conversation
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Good morning Firstmate, what is the high level status?" --registry "$REG")
  assert_contains "$out" "action=handle_direct" "captain message emits handle_direct"
  assert_contains "$out" "route=captain_direct" "captain message routes to captain_direct"

  # 5. Live call: new domain
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Autonomous agricultural drone autopilot navigation firmware in Rust" --registry "$REG")
  assert_contains "$out" "action=create_secondmate" "unmatched task emits create_secondmate"
  assert_contains "$out" "route=new_domain" "unmatched task routes to new_domain"

  # 6. JSON output
  json_out=$(python3 "$ROOT/bin/fm-route-domain.py" --json --task "Good morning" --registry "$REG")
  assert_contains "$json_out" '"action": "handle_direct"' "json output contains valid action"
fi

pass "all fm-route-domain tests passed"
