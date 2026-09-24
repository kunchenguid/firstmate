#!/usr/bin/env bash
# Execute detection with independent marker, ancestry and descendant evidence.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-precedence)
mkdir -p "$TMP_ROOT/bin"
trap 'rm -rf "$TMP_ROOT"' EXIT
HARNESS="$ROOT/bin/fm-harness.sh"
cat > "$TMP_ROOT/bin/ps" <<'PS'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -eo ]; then
 printf '100 1\n200 100\n300 200\n400 100\n'
 exit
fi
field= pid=
while [ $# -gt 0 ]; do
 case "$1" in -o) field=$2; shift 2 ;; -p) pid=$2; shift 2 ;; *) shift ;; esac
done
case "${FM_TEST_TREE:-empty}:$pid:$field" in
 empty:*:comm=|empty:*:args=) echo bash ;;
 empty:*:ppid=) echo 1 ;;
 namespace:1:comm=|namespace:1:args=) echo codex ;;
 namespace:*:comm=|namespace:*:args=) echo bash ;;
 namespace:*:ppid=) echo 1 ;;
 tree:100:comm=) echo node ;;
 tree:100:args=) echo '/usr/bin/node /bin/codex' ;;
 tree:200:comm=|tree:200:args=) echo codex ;;
 tree:300:comm=|tree:300:args=) echo bash ;;
 tree:400:comm=|tree:400:args=) echo pi ;;
 tree:300:ppid=) echo 200 ;;
 tree:200:ppid=|tree:400:ppid=) echo 100 ;;
 tree:*:comm=|tree:*:args=) echo bash ;;
 tree:*:ppid=) echo 1 ;;
esac
PS
chmod +x "$TMP_ROOT/bin/ps"
probe() {
 env -u PI_CODING_AGENT -u FM_TRAEX_HARNESS -u FM_PI_HARNESS \
 PATH="$TMP_ROOT/bin:$PATH" "$@" "$HARNESS"
}
[ "$(probe)" = unknown ] || fail 'blind ancestry leaked the test runner identity'
[ "$(probe PI_CODING_AGENT=true)" = pi ] || fail 'Pi marker not recognized'
[ "$(probe FM_TRAEX_HARNESS=traex)" = traex ] || fail 'TraeX marker not recognized'
[ "$(probe PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)" = pi ] || fail 'retired signed marker renamed Pi'
[ "$(probe CLAUDECODE=1 GROK_AGENT=1 CURSOR_AGENT=1 GEMINI_CLI=1 FM_OMP_HARNESS=omp)" = unknown ] || fail 'removed markers selected a harness'
pass 'only retained markers identify a harness in the absence of ancestry'
[ "$(probe FM_TEST_TREE=namespace PI_CODING_AGENT=true)" = codex ] || fail 'namespace pid 1 did not outrank stale Pi marker'
for harness in pi codex; do
 cp "$(command -v bash)" "$TMP_ROOT/$harness"
 # shellcheck disable=SC2016 # The child shell expands its own positional arguments.
 got=$(env -u PI_CODING_AGENT FM_TRAEX_HARNESS=traex "$TMP_ROOT/$harness" -c 'r=$("$1"); printf %s "$r"' _ "$HARNESS")
 [ "$got" = "$harness" ] || fail "real $harness process lost to inherited TraeX marker: $got"
done
pass 'real retained process ancestry and namespace roots outrank stale markers'
for command in 'ancestry 100' 'ancestry-descent 100 300'; do
 # Intentional splitting of fixed test argv, never caller input.
 # shellcheck disable=SC2086
 got=$(FM_TEST_TREE=tree PATH="$TMP_ROOT/bin:$PATH" "$HARNESS" $command)
 case "$command" in
  'ancestry 100') [ "$got" = 'args codex' ] || fail "shim source did not report argument strength: $got" ;;
  *)
   assert_contains "$got" 'comm codex' 'descendant did not expose native executable identity'
   assert_not_contains "$got" 'comm pi' 'unrelated sibling became ancestry evidence'
   ;;
 esac
done
pass 'descent reaches native child evidence without adopting a sibling harness'
