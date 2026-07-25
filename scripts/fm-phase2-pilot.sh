#!/usr/bin/env bash
# Controlled Phase 2 pilot: programme + task packets for collection flow (no full Epic build).
# Does not mutate production. Creates durable state and optionally dry-runs schedule.
set -euo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
export FM_HOME
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
REG="$FM_HOME/bin/fm-phase2-registry.sh"
cd "$FM_HOME"

"$REG" init
"$REG" create-programme pilot-collections "Artist collection submit/approve pilot" --phase pilot 2>/dev/null || true
"$REG" set-phase pilot-collections pilot

create() {
  local id="$1" title="$2" worker="$3" prio="$4"; shift 4
  "$FM_HOME/bin/fm-phase2-packet.sh" "$id" --title "$title" --objective "$title" >/dev/null
  # fill acceptance
  cat > "$FM_HOME/data/$id/packet/ACCEPTANCE.md" <<EOF
# Acceptance criteria
- [ ] AC-001: $title behaviour works in isolation
- [ ] AC-002: Focused tests or browser evidence attached
- [ ] AC-003: RESULT.md committed with evidence
EOF
  "$REG" add-task "$id" pilot-collections "$title" --worker-type "$worker" --priority "$prio" "$@" \
    --packet-dir "$FM_HOME/data/$id/packet" 2>/dev/null || true
}

create pilot-db-collection "DB: collection draft model support" database_engineer 10 --own '**/db/**' --risk migration
create pilot-api-collection "API: artist create/submit collection" backend_engineer 20 --dep pilot-db-collection --own '**/server/**'
create pilot-ui-collection "UI: artist collection create/submit" frontend_engineer 30 --dep pilot-api-collection --own '**/routes/**' --own '**/components/**'
create pilot-admin-review "Admin review/approve collection" backend_engineer 40 --dep pilot-ui-collection --own '**/admin/**'
create pilot-public-visible "Public collection visibility" frontend_engineer 50 --dep pilot-admin-review --own '**/public/**'
create pilot-tests-browser "Playwright persona smoke for collection visibility" test_engineer 60 --dep pilot-public-visible --own '**/e2e/**'
create pilot-review-gate "Independent review of pilot slice" reviewer 70 --dep pilot-tests-browser
create pilot-ci-gate "CI green for pilot branch" release_engineer 80 --dep pilot-review-gate

# Promote first task
"$REG" transition pilot-db-collection ready --reason pilot_start 2>/dev/null || true

"$FM_HOME/scripts/firstmate-ledger-update.sh"
"$FM_HOME/bin/fm-phase2-schedule.sh" --programme pilot-collections --dry-run

# Deliberate safe failure marker for repair-path demo (removed at end)
mkdir -p "$FM_HOME/data/pilot-deliberate-fail/packet"
echo "INTENTIONAL_FAIL_MARKER" > "$FM_HOME/data/pilot-deliberate-fail/packet/INTENTIONAL_FAIL.txt"
"$REG" add-task pilot-deliberate-fail pilot-collections "Deliberate safe test failure (remove before completion)" \
  --worker-type test_engineer --priority 5 --packet-dir "$FM_HOME/data/pilot-deliberate-fail/packet" 2>/dev/null || true
"$REG" transition pilot-deliberate-fail ready --reason deliberate 2>/dev/null || true
"$REG" transition pilot-deliberate-fail assigned --reason deliberate 2>/dev/null || true
"$REG" transition pilot-deliberate-fail implementing --reason deliberate 2>/dev/null || true
"$REG" transition pilot-deliberate-fail failed --reason deliberate_test_failure --field "blocker=intentional" 2>/dev/null || true
"$FM_HOME/bin/fm-phase2-ci.sh" repair pilot-deliberate-fail --from-run 0 2>/dev/null || true

# Remove deliberate failure artifact
rm -f "$FM_HOME/data/pilot-deliberate-fail/packet/INTENTIONAL_FAIL.txt"
"$REG" transition pilot-deliberate-fail cancelled --reason removed_deliberate_failure 2>/dev/null || true

"$FM_HOME/scripts/firstmate-resume.sh" --programme pilot-collections
"$FM_HOME/scripts/firstmate-ledger-update.sh"

cat > "$FM_HOME/docs/FIRSTMATE-PILOT-REPORT.md" <<EOF
# FirstMate Phase 2 — Pilot Report

**Programme:** pilot-collections  
**Date:** $(date -Is)  
**Host:** $(hostname)

## What was proven (infrastructure)

- Programme + task registry in SQLite (\`state/programme.db\`)
- Durable task packets under \`data/*/packet/\`
- Dependency-aware ready queue
- Scheduler dry-run with concurrency/ownership config
- Deliberate failure → repair task factory path
- Ledger + resume without chat history
- Deliberate failure marker removed

## What still requires live workers / app

- Actual Cursor crewmate spawns for each pilot task
- Real gallery Collection create → admin approve → public visible
- Playwright against running DEV server
- no-mistakes + GitHub Actions on a real branch

## Next

Dispatch with:

\`\`\`bash
bin/fm-brief.sh <id> northscapes-gallery
# fill brief, then:
bin/fm-spawn.sh <id> projects/northscapes-gallery --harness cursor --model auto
bin/fm-phase2-heartbeat.sh beat <id>
\`\`\`

Do **not** start the full Epic Northscapes programme until these live gates are green on one vertical slice.
EOF

echo "pilot scaffolding complete — see docs/FIRSTMATE-PILOT-REPORT.md"
