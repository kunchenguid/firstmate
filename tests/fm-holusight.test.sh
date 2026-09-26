#!/usr/bin/env bash
# Portable tests for the worker-start Holusight evidence owner.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$ROOT/bin/fm-holusight.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-holusight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

home="$TMP/home"
project="$TMP/project"
brief="$TMP/brief.md"
fake="$TMP/fake-holus"
mkdir -p "$home/config" "$project"
printf '%s\n' 'base' > "$brief"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'printf "%s" "$HOLUS_EGRESS|$HOLUSIGHT_EGRESS|$FLEET_HOLUSIGHT_EGRESS|$PWD" > "$FM_FAKE_MARKER"' 'printf "%s" "{coverage: sufficient, egress: {occurred: false}, evidence: [{source: src/main.py, location: line 4}]}"' > "$fake"
chmod +x "$fake"

printf '%s\n' '{"default":{"enabled":true},"projects":{"off":{"enabled":false},"on":{"enabled":true}}}' > "$home/config/holusight.json"
FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_MARKER="$TMP/off.marker" \
  "$HELPER" "$project" off "$brief" >"$TMP/off.out" || fail 'disabled helper failed'
[ ! -e "$TMP/off.marker" ] || fail 'disabled project invoked holus'
grep -q 'not-used: disabled for this project' "$TMP/off.out" || fail 'disabled result was not explicit'
[ ! -e "$project/.holusight" ] || fail 'disabled path wrote application metadata'
pass 'explicitly disabled project does not invoke or write application files'

FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" HOLUS_EXECUTABLE="$fake" FM_FAKE_MARKER="$TMP/on.marker" \
  "$HELPER" "$project" on "$brief" >"$TMP/on.out" || fail 'enabled helper failed'
project_real=$(CDPATH='' cd -- "$project" && pwd -P)
[ "$(cat "$TMP/on.marker")" = "0|0|0|$project_real" ] || fail 'egress deny signals or project cwd were not passed'
grep -q 'used: local evidence lookup completed' "$TMP/on.out" || fail 'enabled invocation was not reported as used'
grep -q 'src/main.py' "$TMP/on.out" || fail 'bounded evidence references were not returned'
pass 'enabled project invokes an existing executable with egress denied and returns bounded evidence'

mkdir -p "$home/.local/bin"
cp "$fake" "$home/.local/bin/holus"
FM_HOME="$home" HOME="$home" FM_CONFIG_OVERRIDE="$home/config" HOLUS_EXECUTABLE= PATH=/usr/bin:/bin FM_FAKE_MARKER="$TMP/path.marker" \
  "$HELPER" "$project" on "$brief" >"$TMP/path.out" || fail 'local executable fallback failed'
grep -q 'used: local evidence lookup completed' "$TMP/path.out" || fail 'home-local executable was not discovered independently of PATH'
pass 'home-local executable fallback works without PATH discovery'

FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" HOLUS_EXECUTABLE="$fake" FM_FAKE_MARKER="$TMP/bench-off.marker" \
  "$HELPER" benchmark "$project" off >"$TMP/bench-off.out" || fail 'disabled benchmark helper failed'
[ ! -e "$TMP/bench-off.marker" ] || fail 'disabled benchmark invoked holus'
grep -q '"enabled":false' "$TMP/bench-off.out" || fail 'disabled benchmark reported enabled'
grep -q '"enabled_result":"not_used"' "$TMP/bench-off.out" || fail 'disabled benchmark reported an enabled result'
pass 'disabled benchmark honors project opt-out without invoking holus'

FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" HOLUS_EXECUTABLE="$fake" FM_FAKE_MARKER="$TMP/bench.marker" \
  "$HELPER" benchmark "$project" on >"$TMP/bench.out" || fail 'benchmark helper failed'
grep -q '"disabled_result":"not_used"' "$TMP/bench.out" || fail 'benchmark did not report disabled baseline'
grep -q '"disabled_elapsed_ms":[0-9]' "$TMP/bench.out" || fail 'benchmark did not measure disabled elapsed time'
grep -q '"enabled_elapsed_ms":[0-9]' "$TMP/bench.out" || fail 'benchmark did not measure enabled elapsed time'
grep -q '"token_delta":"unknown"' "$TMP/bench.out" || fail 'benchmark invented token measurement'
pass 'benchmark compares enabled and disabled elapsed time with unknown token deltas'
