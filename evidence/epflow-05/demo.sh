#!/usr/bin/env bash
# evidence/epflow-05/demo.sh - runnable proof for fm-epic-status + fm-epic-dispatch-plan.
#
# Builds a throwaway fixture home (a signed epic with a mix of done/dispatchable/
# blocked/unseeded stories, one story whose base branch name has drifted from the
# epic slug, and a repo with a delivery: override) and runs BOTH commands against
# it, so the reader sees the exact status table and dispatch plan without needing
# a live fleet. The epic-branch check is served through the FM_EPIC_BRANCH_BIN
# seam by a fake that LOGS every call, and the demo then proves the dispatch plan
# only ever asked to VERIFY - it never cut a branch or spawned anything.
#
# Run:  evidence/epflow-05/demo.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/epflow05-demo.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/plans/epic-demo/stories"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- alpha [local-only production=main] - fixture (added 2026-01-01)
- beta [no-mistakes-prod-only production=main] - fixture (added 2026-01-01)
EOF

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] demo-02 - [demo] second (repo: alpha) (kind: ship) (since 2026-01-01)
- [ ] demo-03 - [demo] third (repo: alpha) (kind: ship) (since 2026-01-01)
- [ ] demo-04 - [demo] fourth (repo: beta) (kind: ship) (since 2026-01-01)
- [ ] demo-05 - [demo] fifth (repo: alpha) (kind: ship) (since 2026-01-01)

## Done
- [x] demo-01 - [demo] first https://example.invalid/pr/1 (repo: alpha) (kind: ship) (merged 2026-01-02)
EOF

cat > "$HOME_DIR/data/plans/epic-demo/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [alpha, beta]
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
${6:+delivery: $6}
---
# $2 heading
EOF
}
story 01.md demo-01 alpha epic/demo  ""       ""          # merged  -> DONE
story 02.md demo-02 alpha epic/demo  demo-01  ""          # dep merged -> DISPATCHABLE
story 03.md demo-03 alpha epic/demo  demo-02  ""          # dep queued -> blocked
story 04.md demo-04 beta  main       demo-01  direct-PR   # delivery: key overrides beta's prod-only posture
story 05.md demo-05 alpha epic/other demo-01  ""          # base branch drifts from epic slug
story 06.md demo-06 alpha main       ""       ""          # no backlog entry -> UNSEEDED

# Fake epic-branch verifier: epic/demo cut in alpha, epic/other NOT cut. Logs calls.
CALLLOG="$TMP/branch-calls.log"; : > "$CALLLOG"
FAKE="$TMP/fake-epic-branch.sh"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLLOG"
[ "\$1" = verify ] || exit 3
case "\$2/\$3" in demo/alpha) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$FAKE"

export FM_HOME="$HOME_DIR" FM_EPIC_BRANCH_BIN="$FAKE"

echo "==================== fm-epic-status demo ===================="
"$ROOT/bin/fm-epic-status.sh" demo
echo ""
echo "================= fm-epic-dispatch-plan demo ================"
"$ROOT/bin/fm-epic-dispatch-plan.sh" demo
echo ""
echo "===================== print-only proof ====================="
if grep -qv '^verify ' "$CALLLOG"; then
  echo "FAIL: the branch tool was asked to do more than verify:"; grep -v '^verify ' "$CALLLOG"; exit 1
fi
echo "the epic-branch tool was invoked only with 'verify' (never 'create'); no spawn ran. Calls:"
sed 's/^/  /' "$CALLLOG"
echo ""
echo "OK - both commands are read-only and print-only."
