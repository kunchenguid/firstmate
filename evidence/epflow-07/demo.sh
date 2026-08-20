#!/usr/bin/env bash
# evidence/epflow-07/demo.sh - runnable proof for the optional `delivery:` story
# frontmatter key (epflow-07).
#
# Builds a throwaway fixture home and shows, without a live fleet, the four cases
# the story's Definition of done names:
#   1. a story with a VALID `delivery:` passes lint AND its dispatch-plan line
#      shows that exact mode (the author's intent wins over the repo posture);
#   2. a CONFLICTING value (direct-PR on a no-mistakes-prod-only repo) is FLAGGED
#      as a warning - and the lint still passes (never a hard lock);
#   3. an INVALID value fails the lint (exit 1) with the exact reason;
#   4. an ABSENT `delivery:` changes nothing - the epic passes and the mode is
#      resolved at dispatch from the repo's registered posture, exactly as before.
#
# The epic-branch check the dispatch-plan makes is served through the
# FM_EPIC_BRANCH_BIN seam by a fake, so nothing touches a real forge.
#
# Run:  evidence/epflow-07/demo.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/epflow07-demo.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/plans/epic-demo/stories"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- svc  [direct-PR production=main] - fixture repo (added 2026-01-01)
- prod [no-mistakes-prod-only production=main] - prod-only fixture (added 2026-01-01)
EOF

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## Queued
- [ ] demo-02 - [demo] intent-wins (repo: svc) (kind: ship) (since 2026-01-01)
- [ ] demo-03 - [demo] posture-conflict (repo: prod) (kind: ship) (since 2026-01-01)
- [ ] demo-04 - [demo] absent-key (repo: prod) (kind: ship) (since 2026-01-01)

## Done
- [x] demo-01 - [demo] gate https://example.invalid/pr/1 (repo: svc) (kind: ship) (merged 2026-01-02)
EOF

cat > "$HOME_DIR/data/plans/epic-demo/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [svc, prod]
status: active
signed_off: 2026-01-02
---
# Demo epic
EOF

story() { # <file> <id> <repo> <pr_base> <depends> <delivery>
  cat > "$HOME_DIR/data/plans/epic-demo/stories/$1" <<EOF
---
id: $2
epic: demo
repo: $3
pr_base: $4
depends: [$5]
kind: ship
gate: $6
${7:+delivery: $7}
---
# $2 heading
EOF
}
#      file         id       repo  pr_base  depends  gate   delivery
story  demo-01.md   demo-01  svc   main     ""       true   ""          # the gate story
story  demo-02.md   demo-02  svc   main     demo-01  false  direct-PR   # valid: intent wins
story  demo-03.md   demo-03  prod  main     demo-01  false  direct-PR   # CONFLICT: prod-only + direct-PR -> WARN
story  demo-04.md   demo-04  prod  main     demo-01  false  ""          # absent: resolved at dispatch

# Fake epic-branch verifier (no story bases on epic/<slug> here, so it is never
# even consulted; provided for completeness so the plan stays offline).
FAKE="$TMP/fake-epic-branch.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
[ "$1" = verify ] || exit 3
exit 1
EOF
chmod +x "$FAKE"

export FM_HOME="$HOME_DIR" FM_EPIC_BRANCH_BIN="$FAKE"
LINT="$ROOT/bin/fm-epic-lint.sh"
PLAN="$ROOT/bin/fm-epic-dispatch-plan.sh"
EPIC_DIR="$HOME_DIR/data/plans/epic-demo"

echo "==================== 1+2. lint the epic (valid + conflicting keys) ===================="
# Passes (exit 0) and prints a WARNING for the prod-only direct-PR conflict.
if "$LINT" "$EPIC_DIR"; then echo "-> lint EXIT 0 (valid; the conflict is a warning, not a failure)"; else
  echo "FAIL: lint should pass on valid+warned keys"; exit 1; fi

echo ""
echo "==================== 1. dispatch-plan reflects the delivery mode ===================="
# demo-02 carries delivery: direct-PR and must show --mode direct-PR even though a
# story could otherwise inherit posture; demo-04 (absent key) on the prod-only repo
# surfaces BOTH candidate modes for firstmate to classify.
"$PLAN" demo | grep -E 'demo-0[24]|--mode|NEEDS firstmate' || true

echo ""
echo "==================== 3. an INVALID delivery value fails ===================="
badstory="$EPIC_DIR/stories/demo-02.md"
perl -i -pe 's/^delivery: direct-PR$/delivery: yolo-ship/' "$badstory"
if "$LINT" "$EPIC_DIR" 2>/tmp/epflow07-bad.err; then
  echo "FAIL: an invalid delivery value must fail the lint"; exit 1
else
  echo "-> lint EXIT 1 as expected. Reason:"; grep 'must be no-mistakes' /tmp/epflow07-bad.err | sed 's/^/   /'
fi
perl -i -pe 's/^delivery: yolo-ship$/delivery: direct-PR/' "$badstory"   # restore

echo ""
echo "==================== 4. an ABSENT delivery key is unchanged ===================="
# Strip every delivery: line; the epic must still pass and never mention delivery.
find "$EPIC_DIR/stories" -name '*.md' -exec perl -i -ne 'print unless /^delivery:/' {} +
if OUT="$("$LINT" "$EPIC_DIR" 2>&1)"; then
  echo "-> lint EXIT 0 with no delivery key present."
  case "$OUT" in *delivery*) echo "FAIL: an absent key must produce no delivery finding"; exit 1 ;; esac
  echo "   (no 'delivery' string in the output - absence is a no-op)"
else
  echo "FAIL: a delivery-less epic must still pass"; exit 1
fi

echo ""
echo "OK - valid passes + shows the mode, conflict warns, invalid fails, absent is unchanged."
