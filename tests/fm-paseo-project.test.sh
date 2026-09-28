#!/usr/bin/env bash
# Contract tests for registering Firstmate project checkouts with Paseo.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-paseo-project-tests)
HOME_ROOT="$TMP_ROOT/home"
PROJECTS="$HOME_ROOT/projects"
DATA="$HOME_ROOT/data"
CONFIG="$HOME_ROOT/config"
FAKEBIN="$TMP_ROOT/bin"
PROJECTS_JSON="$TMP_ROOT/paseo-projects.json"
LOG="$TMP_ROOT/paseo.log"
mkdir -p "$PROJECTS/alpha" "$PROJECTS/orphan" "$DATA" "$CONFIG" "$FAKEBIN"
mkdir -p "$TMP_ROOT/outside"
printf '%s\n' '- alpha - Alpha project (added 2026-01-01)' > "$DATA/projects.md"
printf '[]\n' > "$PROJECTS_JSON"
: > "$LOG"

cat > "$FAKEBIN/paseo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_PASEO_LOG"
case "$1 ${2:-}" in
  'project ls')
    cat "$FM_PASEO_PROJECTS_JSON"
    ;;
  'project create')
    shift 2
    [ "${1:-}" = --json ] && shift
    path=${1:-}
    [ -n "$path" ] || exit 2
    id="project-$(jq 'length' "$FM_PASEO_PROJECTS_JSON")"
    name=$(basename "$path")
    jq --arg id "$id" --arg name "$name" --arg path "$path" \
      '. + [{projectId:$id,name:$name,path:$path}]' "$FM_PASEO_PROJECTS_JSON" > "$FM_PASEO_PROJECTS_JSON.tmp"
    mv "$FM_PASEO_PROJECTS_JSON.tmp" "$FM_PASEO_PROJECTS_JSON"
    printf '{"projectId":"%s"}\n' "$id"
    ;;
  *)
    printf 'unexpected Paseo command: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/paseo"
export PATH="$FAKEBIN:$PATH"
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT"
export FM_PASEO_PROJECTS_JSON="$PROJECTS_JSON" FM_PASEO_LOG="$LOG"
HELPER="$ROOT/bin/fm-paseo-project.sh"

printf 'tmux\n' > "$CONFIG/backend"
export FM_CONFIG_OVERRIDE="$CONFIG"
"$HELPER" alpha > "$TMP_ROOT/create.out"
assert_contains "$(cat "$TMP_ROOT/create.out")" 'created Paseo project alpha' "missing Paseo match was not created by an explicit request"
assert_equals 1 "$(grep -c '^project create ' "$LOG" || true)" "Paseo project creation count after the first explicit request"

"$HELPER" alpha > "$TMP_ROOT/noop.out"
assert_contains "$(cat "$TMP_ROOT/noop.out")" 'already matches registered project alpha' "one existing Paseo match was not a no-op"
assert_equals 1 "$(grep -c '^project create ' "$LOG" || true)" "one existing match caused another Paseo create"

BACKSLASH_PROJECT='foo\bar'
mkdir -p "$PROJECTS/$BACKSLASH_PROJECT"
printf '%s\n' "- $BACKSLASH_PROJECT - Backslash project (added 2026-01-01)" >> "$DATA/projects.md"
backslash_real=$(cd -P "$PROJECTS/$BACKSLASH_PROJECT" && pwd -P)
jq --arg path "$backslash_real" \
  '. + [{projectId:"backslash-existing",name:"backslash-existing",path:$path}]' "$PROJECTS_JSON" > "$PROJECTS_JSON.tmp"
mv "$PROJECTS_JSON.tmp" "$PROJECTS_JSON"
"$HELPER" "$BACKSLASH_PROJECT" > "$TMP_ROOT/backslash-existing.out"
assert_contains "$(cat "$TMP_ROOT/backslash-existing.out")" 'already matches registered project foo\bar' \
  "a matching Paseo project with a backslash path was not reused"
assert_equals 1 "$(grep -c '^project create ' "$LOG" || true)" "a matching backslash path caused another Paseo create"

jq 'map(select(.projectId != "backslash-existing"))' "$PROJECTS_JSON" > "$PROJECTS_JSON.tmp"
mv "$PROJECTS_JSON.tmp" "$PROJECTS_JSON"
"$HELPER" "$BACKSLASH_PROJECT" > "$TMP_ROOT/backslash-create.out"
assert_contains "$(cat "$TMP_ROOT/backslash-create.out")" 'created Paseo project foo\bar' \
  "post-create verification failed for a backslash path"
assert_equals 2 "$(grep -c '^project create ' "$LOG" || true)" "a missing backslash path was not created exactly once"
"$HELPER" "$BACKSLASH_PROJECT" > "$TMP_ROOT/backslash-noop.out"
assert_contains "$(cat "$TMP_ROOT/backslash-noop.out")" 'already matches registered project foo\bar' \
  "a newly created backslash path was not reused"
assert_equals 2 "$(grep -c '^project create ' "$LOG" || true)" "a newly created backslash path caused another Paseo create"

jq --arg path "$(cd -P "$PROJECTS/alpha" && pwd -P)" \
  '. + [{projectId:"duplicate",name:"alpha-copy",path:$path}]' "$PROJECTS_JSON" > "$PROJECTS_JSON.tmp"
mv "$PROJECTS_JSON.tmp" "$PROJECTS_JSON"
if "$HELPER" alpha > /dev/null 2> "$TMP_ROOT/duplicate.err"; then
  fail "multiple Paseo matches were accepted"
fi
assert_contains "$(cat "$TMP_ROOT/duplicate.err")" '2 Paseo projects match' "ambiguous Paseo refusal did not name the duplicate count"
assert_equals 2 "$(grep -c '^project create ' "$LOG" || true)" "ambiguous matches triggered Paseo project creation"

if "$HELPER" orphan > /dev/null 2> "$TMP_ROOT/unregistered.err"; then
  fail "an unregistered local project was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/unregistered.err")" 'not registered' "unregistered project refusal was unclear"

printf '%s\n' '- missing - Missing project (added 2026-01-01)' >> "$DATA/projects.md"
if "$HELPER" missing > /dev/null 2> "$TMP_ROOT/missing.err"; then
  fail "a registered project missing from the active projects directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/missing.err")" 'is missing' "missing checkout refusal was unclear"

ln -s "$TMP_ROOT/outside" "$PROJECTS/external"
printf '%s\n' '- external - External project (added 2026-01-01)' >> "$DATA/projects.md"
if "$HELPER" external > /dev/null 2> "$TMP_ROOT/external.err"; then
  fail "a registered project resolving outside the active projects directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/external.err")" 'resolves outside the active home projects directory' \
  "external checkout refusal did not name the boundary"

printf '[]\n' > "$PROJECTS_JSON"
before=$(wc -l < "$LOG" | tr -d '[:space:]')
"$HELPER" --if-selected alpha > "$TMP_ROOT/tmux-skip.out"
assert_contains "$(cat "$TMP_ROOT/tmux-skip.out")" 'runtime backend for new tasks is tmux' "non-Paseo add path did not report its skip"
assert_equals "$before" "$(wc -l < "$LOG" | tr -d '[:space:]')" "non-Paseo add path called Paseo"

printf 'paseo\n' > "$CONFIG/backend"
"$HELPER" --if-selected alpha > "$TMP_ROOT/paseo-add.out"
assert_contains "$(cat "$TMP_ROOT/paseo-add.out")" 'created Paseo project alpha' "Paseo-selected add path did not create its project"
assert_equals 3 "$(grep -c '^project create ' "$LOG" || true)" "Paseo-selected add path did not create exactly one project"

FM_BACKEND=tmux "$HELPER" --if-selected alpha > "$TMP_ROOT/env-override.out"
assert_contains "$(cat "$TMP_ROOT/env-override.out")" 'runtime backend for new tasks is tmux' "FM_BACKEND did not override config/backend during add"
assert_equals 3 "$(grep -c '^project create ' "$LOG" || true)" "non-Paseo FM_BACKEND override created a Paseo project"

pass "Paseo project registration is idempotent, registry-bound, path-bound, ambiguity-safe, and backend-conditional for add"
