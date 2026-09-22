#!/usr/bin/env bash
# tests/fm-jev-dep-harmonizer.test.sh - Test suite for Pattern 25 Dependency Harmonizer
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
HARMONIZER_SH="$FM_ROOT/bin/fm-jev-dep-harmonizer.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-dep-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$HARMONIZER_SH" || fail "shellcheck failed on fm-jev-dep-harmonizer.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$HARMONIZER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock projects
mkdir -p "$TDIR/project-a" "$TDIR/project-b" "$TDIR/project-c"

cat <<'EOF' > "$TDIR/project-a/package.json"
{
  "name": "project-a",
  "dependencies": {
    "@playwright/test": "^1.42.0",
    "typescript": "^5.4.0"
  }
}
EOF

cat <<'EOF' > "$TDIR/project-b/package.json"
{
  "name": "project-b",
  "devDependencies": {
    "@playwright/test": "^1.42.0",
    "typescript": "^5.5.0"
  }
}
EOF

cat <<'EOF' > "$TDIR/project-c/package.json"
{
  "name": "project-c",
  "dependencies": {
    "@playwright/test": "^1.45.0"
  }
}
EOF

cat <<'EOF' > "$TDIR/project-a/pyproject.toml"
[project]
name = "project-a"
dependencies = [
    "pydantic>=2.7.0",
    "pytest>=8.0.0"
]
EOF

cat <<'EOF' > "$TDIR/project-b/pyproject.toml"
[project]
name = "project-b"
dependencies = [
    "pydantic>=2.6.0",
    "pytest>=8.0.0"
]
EOF

# 4. Run test scan
json_out=$("$HARMONIZER_SH" --roots "$TDIR" --json)

scanned=$(echo "$json_out" | jq '.summary.scanned_projects_count')
[ "$scanned" -eq 3 ] || fail "expected 3 scanned projects, got $scanned"
pass "scanned 3 mock projects correctly"

# 5. Verify drift detection
pw_drift=$(echo "$json_out" | jq '.drift_report["@playwright/test"].has_drift')
[ "$pw_drift" = "true" ] || fail "@playwright/test drift not detected"
pass "@playwright/test version drift detected correctly"

ts_drift=$(echo "$json_out" | jq '.drift_report["typescript"].has_drift')
[ "$ts_drift" = "true" ] || fail "typescript drift not detected"
pass "typescript version drift detected correctly"

pytest_drift=$(echo "$json_out" | jq '.drift_report["pytest"].has_drift')
[ "$pytest_drift" = "false" ] || fail "pytest should be aligned, but marked drifted"
pass "pytest correctly reported as aligned"

# 6. Verify --drift-only flag
drift_only_out=$("$HARMONIZER_SH" --roots "$TDIR" --drift-only --json)
has_pytest=$(echo "$drift_only_out" | jq '.drift_report | has("pytest")')
[ "$has_pytest" = "false" ] || fail "--drift-only included aligned package pytest"
pass "--drift-only excludes aligned packages"

pass "all Pattern 25 dependency harmonizer tests passed"
