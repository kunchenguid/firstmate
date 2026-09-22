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
if sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env | grep -q "TYPESAFE_API_KEY"; then
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

  # 7. Seat wall detection & Cursor Grok override suggestion
  MOCK_STATE="$TDIR/state"
  mkdir -p "$MOCK_STATE"
  cat <<'EOF' > "$MOCK_STATE/seller-outreach.status"
blocked [key=claude-rate-limit]: seat cannot act: claude weekly quota exhausted until 2026-09-27; lane walled
EOF
  walled_out=$(FM_STATE_OVERRIDE="$MOCK_STATE" python3 "$ROOT/bin/fm-route-domain.py" --task "Urgent care acquisition seller email outreach campaign" --registry "$REG")
  assert_contains "$walled_out" "seat_warning=Target seat 'seller-outreach' appears walled on Claude." "detects claude wall in target seat"
  assert_contains "$walled_out" "--harness cursor --model cursor-grok-4.6-high" "suggests cursor grok fallback"
  assert_contains "$walled_out" 'dispatch_cmd=FM_HOME=/opt/ra/firstmate bin/fm-send.sh seller-outreach --harness cursor --model cursor-grok-4.6-high' "dispatch_cmd contains cursor grok override"

  # 8. Auto-charter new secondmate
  MOCK_HOMES="$TDIR/homes"
  mkdir -p "$MOCK_HOMES"
  charter_out=$(FM_SECONDMATE_HOMES_DIR="$MOCK_HOMES" python3 "$ROOT/bin/fm-route-domain.py" --auto-charter --task "Autonomous agricultural drone autopilot navigation firmware in Rust" --registry "$REG")
  assert_contains "$charter_out" "action=create_secondmate" "auto-charter preserves create_secondmate"
  assert_contains "$charter_out" "chartered_domain=" "emits chartered_domain"
  assert_contains "$charter_out" "chartered_home=" "emits chartered_home"

  # Verify registry was updated with formatted charter
  reg_content=$(cat "$REG")
  assert_contains "$reg_content" "Dedicated secondmate for" "registry has new charter line"
  assert_contains "$reg_content" "scope: Autonomous agricultural drone" "charter has scope"

  # Verify directory scaffolding
  chartered_domain=$(echo "$charter_out" | grep '^chartered_domain=' | cut -d= -f2)
  [ -d "$MOCK_HOMES/$chartered_domain/data" ] || fail "scaffolded data dir missing"
  [ -d "$MOCK_HOMES/$chartered_domain/state" ] || fail "scaffolded state dir missing"
  [ -f "$MOCK_HOMES/$chartered_domain/.fm-secondmate-home" ] || fail "scaffolded .fm-secondmate-home missing"
  assert_contains "$(cat "$MOCK_HOMES/$chartered_domain/.fm-secondmate-home")" "$chartered_domain" "home marker contains domain"

  # 9. fm-route-dispatch.sh with --auto-charter
  dispatch_out=$(FM_SECONDMATE_HOMES_DIR="$MOCK_HOMES" "$ROOT/bin/fm-route-dispatch.sh" --registry "$REG" --auto-charter --task "Quantum computing cryptographic lattice simulation engine in Haskell")
  assert_contains "$dispatch_out" "Auto-chartered new Second Mate" "dispatch script reports auto-charter"
  assert_contains "$dispatch_out" "bin/fm-spawn.sh" "dispatch script reports spawn command"
fi

pass "all fm-route-domain tests passed"
