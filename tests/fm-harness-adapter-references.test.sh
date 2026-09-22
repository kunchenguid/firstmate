#!/usr/bin/env bash
# Portable structural validation for the harness-adapters routing artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER="$ROOT/.agents/skills/harness-adapters/SKILL.md"
PATH_CHECK="$ROOT/bin/fm-harness-adapter-path-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-references)
ROUTING_JSON="$TMP_ROOT/routing.json"

awk '
  /^```json harness-adapter-routing-v1$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$ROUTER" > "$ROUTING_JSON"

jq -e '
  (.operations | type == "object") and
  (.harnesses | type == "object") and
  ([.operations[][] | select(type != "array")] | length == 0) and
  ([.operations[][][] | select(type != "string")] | length == 0) and
  ([.harnesses[] | select(type != "string")] | length == 0)
' "$ROUTING_JSON" >/dev/null || fail "harness adapter routing artifact is not a normalized operation and harness map"

jq -r '.operations[][][], .harnesses[]' "$ROUTING_JSON" | sort -u | while IFS= read -r path; do
  [ -r "$ROOT/.agents/skills/harness-adapters/$path" ] \
    || fail "harness adapter routing target is unreadable: $path"
done
pass "harness adapter routing artifact is normalized and every target is readable"

CURRENT_OUT="$TMP_ROOT/current.out"
"$PATH_CHECK" >"$CURRENT_OUT" 2>&1 \
  || fail "tracked harness adapter owner paths failed validation: $(cat "$CURRENT_OUT")"
assert_contains "$(cat "$CURRENT_OUT")" "fm-harness-adapter-path-check: ok" \
  "owner-path validator did not report success"
pass "tracked nested harness adapter owner paths resolve"

FIXTURE_REPO="$TMP_ROOT/repo"
FIXTURE_SKILL="$FIXTURE_REPO/.agents/skills/harness-adapters"
mkdir -p \
  "$FIXTURE_SKILL/references/common" \
  "$FIXTURE_SKILL/references/harness" \
  "$FIXTURE_REPO/.agents/skills/peer" \
  "$FIXTURE_REPO/bin"
printf '# peer\n' >"$FIXTURE_REPO/.agents/skills/peer/SKILL.md"
printf '#!/usr/bin/env bash\n' >"$FIXTURE_REPO/bin/tool.sh"
cat >"$FIXTURE_SKILL/references/common/dispatch.md" <<'EOF'
Load `references/harness/example.md`.
Follow `../peer/SKILL.md`.
EOF
cat >"$FIXTURE_SKILL/references/harness/example.md" <<'EOF'
Run `FM_CHECK=1 ../../../bin/tool.sh --check`.
EOF

VALID_OUT="$TMP_ROOT/valid.out"
"$PATH_CHECK" --skill-dir "$FIXTURE_SKILL" >"$VALID_OUT" 2>&1 \
  || fail "owner-path validator rejected valid nested references: $(cat "$VALID_OUT")"
assert_contains "$(cat "$VALID_OUT")" "references=2 owner_paths=3" \
  "owner-path validator did not inspect both nested reference groups"
pass "owner-path validator accepts both supported relative path forms"

cat >>"$FIXTURE_SKILL/references/harness/example.md" <<'EOF'
Missing `references/common/missing.md`.
Missing `../missing/SKILL.md`.
EOF
INVALID_OUT="$TMP_ROOT/invalid.out"
if "$PATH_CHECK" --skill-dir "$FIXTURE_SKILL" >"$INVALID_OUT" 2>&1; then
  fail "owner-path validator accepted missing nested targets"
fi
invalid=$(cat "$INVALID_OUT")
assert_contains "$invalid" "references/harness/example.md:2: unresolved owner path: references/common/missing.md" \
  "missing skill-relative target lacked a source diagnostic"
assert_contains "$invalid" "references/harness/example.md:3: unresolved owner path: ../missing/SKILL.md" \
  "missing sibling-skill target lacked a source diagnostic"
pass "owner-path validator rejects every missing nested target"
