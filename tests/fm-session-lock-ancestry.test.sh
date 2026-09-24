#!/usr/bin/env bash
# Maintained session ancestry and historical lock exclusion, via process evidence.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"
trap 'rm -rf "$TMP_ROOT"' EXIT
cat > "$TMP_ROOT/bin/ps" <<'PS'
#!/usr/bin/env bash
field= pid=
while [ $# -gt 0 ]; do
 case "$1" in -o) field=$2; shift 2 ;; -p) pid=$2; shift 2 ;; *) shift ;; esac
done
case "$field" in
 comm=) [ "$pid" = 700 ] && printf '%s\n' "$FM_TEST_COMM" || echo bash ;;
 args=) [ "$pid" = 700 ] && printf '%s\n' "$FM_TEST_ARGS" || echo bash ;;
 ppid=) [ "$pid" = 700 ] && echo 1 || echo 700 ;;
esac
PS
chmod +x "$TMP_ROOT/bin/ps"
probe() {
 PATH="$TMP_ROOT/bin:$PATH" FM_TEST_COMM="$1" FM_TEST_ARGS="$2" bash -c '
 . "$1"
 kill() { return 0; }
 eval "$2"
 ' _ "$ROOT/bin/fm-session-lock-lib.sh" "$3"
}
for harness in pi codex pi-launcher; do
 got=$(probe "$harness" "/bin/$harness" fm_harness_ancestry_pid)
 [ "$got" = 700 ] || fail "$harness did not own its ancestry: $got"
 probe "$harness" "/bin/$harness" 'fm_harness_pid_alive 700' || fail "$harness lock not live"
done
pass 'Pi and Codex session ancestry and lock liveness agree'
for harness in claude opencode grok kimi cursor gemini muse rovo omp agy pi-signed; do
 probe "$harness" "/bin/$harness" fm_harness_ancestry_pid >/dev/null && fail "removed $harness acquired a new session identity"
 probe "$harness" "/bin/$harness" 'fm_harness_pid_alive 700' || fail "live historical $harness lock could be stolen"
done
probe 2.1.220 /opt/claude/versions/2.1.220 'fm_harness_pid_alive 700' || fail 'versioned historical lock was lost'
probe sleep '/bin/sleep 60' 'fm_harness_pid_alive 700' && fail 'unrelated process became a lock owner'
probe node '/usr/bin/node /tmp/project/codex-provider.js' 'fm_harness_path_name /tmp/project/codex-provider.js' >/dev/null && fail 'provider path became harness component'
pass 'historical lock owners block takeover without becoming supported session identities'
