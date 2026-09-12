#!/usr/bin/env bash
# Priority-pool regression: a pool named in top-level "priority" reserves
# the first viable candidate in config order every time, with no
# weighted rotation. Runs on PATH wrapper fakes; no harness or backend.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-pool-priority)
mkdir -p "$TMP_ROOT/wbin" "$TMP_ROOT/state"
pool() { PATH="$TMP_ROOT/wbin:$PATH" "$ROOT/bin/fm-dispatch-pool.sh" "$1" "$TMP_ROOT/config.json" "$TMP_ROOT/state" "${@:2}"; }
refused() { if "$@" >"$TMP_ROOT/refusal" 2>&1; then fail 'expected refusal'; fi; }
cat > "$TMP_ROOT/wbin/wrap-a" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'alpha Alpha model' 'beta Beta model'; exit 0; fi
exit 0
SH
cat > "$TMP_ROOT/wbin/wrap-b" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'alpha Alpha model' 'beta Beta model'; exit 0; fi
exit 0
SH
chmod +x "$TMP_ROOT/wbin"/wrap-a "$TMP_ROOT/wbin"/wrap-b
cat > "$TMP_ROOT/config.json" <<'JSON'
{"schemaVersion":1,"defaults":{},"priority":["pri"],"pools":{"pri":[
{"id":"first","harness":"wrap-a","model":"alpha","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1},
{"id":"second","harness":"wrap-b","model":"beta","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":4}
],"skipped":[
{"id":"gone","harness":"wrap-missing","model":"default","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1},
{"id":"fallback","harness":"wrap-b","model":"beta","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1}
]}}
JSON
pool validate >/dev/null
seq=
for n in 1 2 3; do seq="$seq$(pool reserve "p$n" pri | jq -r .candidate.id)"; done
[ "$seq" = firstfirstfirst ] || fail "priority pool rotated: $seq"
pass 'priority pool reserves first viable every time despite lower weight'
[ "$(pool reserve s1 skipped | jq -r .candidate.id)" = fallback ] || fail 'priority pool did not skip non-viable first'
[ "$(pool reserve s2 skipped | jq -r .candidate.id)" = fallback ] || fail 'priority skip did not hold'
pass 'priority pool skips non-viable first candidate for the next viable'
printf '%s' '{"schemaVersion":1,"defaults":{},"priority":["nope"],"pools":{"pri":[]}}' > "$TMP_ROOT/wbad.json"
refused "$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/wbad.json" "$TMP_ROOT/state"
printf '%s' '{"schemaVersion":1,"defaults":{},"priority":"pri","pools":{"pri":[]}}' > "$TMP_ROOT/wbad.json"
refused "$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/wbad.json" "$TMP_ROOT/state"
pass 'unknown pool and non-array priority refuse'
