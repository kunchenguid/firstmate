#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
cat > "$d/log" <<'EOF'
2026-01-01 https://example.test/pull/1 x pass
2026-01-02 https://example.test/pull/1 x card
2026-01-01 https://example.test/pull/2 x fail
2026-01-02 https://example.test/pull/2 x card
2026-01-01 https://example.test/pull/3 x pass
2026-01-02 https://example.test/pull/3 x fail
2026-01-03 https://example.test/pull/3 x card
2026-01-01 https://example.test/pull/4 x card
2026-01-01 5 x pass
EOF
cat > "$d/expected" <<'EOF'
https://example.test/pull/1 pass
https://example.test/pull/2 bypass
https://example.test/pull/3 bypass
https://example.test/pull/4 bypass
https://example.test/pull/99 bypass
https://example.test/pull/5 pass
EOF
"$root/fleet-pulse/bin/gate-audit.sh" "$d/log" \
  https://example.test/pull/1 https://example.test/pull/2 \
  https://example.test/pull/3 https://example.test/pull/4 \
  https://example.test/pull/99 https://example.test/pull/5 > "$d/actual"
diff -u "$d/expected" "$d/actual"
