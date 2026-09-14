#!/usr/bin/env bash
# Portable Devin detection, launch argv, preflight and control regressions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-devin-lib.sh
. "$ROOT/bin/fm-devin-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"

# A real native process runs the public detector as a child. No guessed env
# marker or ps stub supplies the answer. Exact basename must be sufficient.
if command -v cc >/dev/null 2>&1; then
  cat > "$TMP_ROOT/parent.c" <<'C'
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  pid_t pid = fork();
  if (pid < 0) return 3;
  if (pid == 0) { execl(argv[1], argv[1], (char *)0); _exit(4); }
  int status; if (waitpid(pid, &status, 0) < 0) return 5;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 6;
}
C
  cc "$TMP_ROOT/parent.c" -o "$TMP_ROOT/bin/devin"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$TMP_ROOT/bin/devin" "$ROOT/bin/fm-harness.sh")
  [ "$out" = devin ] || fail "native Devin ancestry detected as $out"
  cp "$TMP_ROOT/bin/devin" "$TMP_ROOT/bin/not-devin"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$TMP_ROOT/bin/not-devin" "$ROOT/bin/fm-harness.sh")
  [ "$out" != devin ] || fail "lookalike process claimed Devin"
  pass "Devin exact native ancestry identifies; lookalikes do not"
else
  fail "cc is required for the native-process detection regression"
fi

cat > "$TMP_ROOT/bin/devin" <<'SH'
#!/bin/bash
case "$*" in
  --help) echo '--prompt-file --respect-workspace-trust --permission-mode --model' ;;
  'auth status') exit "${DEVIN_TEST_AUTH_RC:-0}" ;;
  'models list --format json') echo '{"families":[{"family_uid":"swe-2","slug":"swe-2","aliases":[],"variants":[{"model_uid":"swe-2-high"}]}]}' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/devin"
fm_devin_preflight "$TMP_ROOT/bin/devin" swe-2-high dangerous || fail "valid profile refused"
! fm_devin_preflight "$TMP_ROOT/bin/devin" invented dangerous 2>/dev/null || fail "unknown model accepted"
! fm_devin_preflight "$TMP_ROOT/bin/devin" default invented 2>/dev/null || fail "unknown permission accepted"
! DEVIN_TEST_AUTH_RC=1 fm_devin_preflight "$TMP_ROOT/bin/devin" default auto 2>/dev/null || fail "auth failure accepted"
for mode in auto accept-edits smart dangerous; do
  fm_devin_preflight "$TMP_ROOT/bin/devin" default "$mode" || fail "documented permission mode refused"
done
pass "Devin preflight validates credentials, model and permission vocabulary"

# Exercise launch construction through its public function and an argv
# recording backend, never by reading implementation source.
fm_backend_herdr_parse_target() {
  FM_BACKEND_HERDR_SESSION=${1%%:*}
  FM_BACKEND_HERDR_PANE=${1#*:}
}
fm_backend_herdr_send_literal() { printf '%s\n' "$2" > "$TMP_ROOT/shell-command"; }
fm_backend_herdr_send_key() { [ "$2" = Enter ] || fail "unexpected launch key"; }
fm_backend_herdr_cli() {
  [ "$*" = 'fm-lab-test agent get w1:p2' ] || fail 'readiness must query exact lab pane'
  printf '%s\n' '{"result":{"agent":{"agent":"devin","pane_id":"w1:p2","interactive_ready":true}}}'
}
fm_devin_start fm-lab-test:w1:p2 "$TMP_ROOT/bin/devin" \
  "/path with 'quotes'/brief.md" swe-2-high smart
# Run the actual generated launch with a recording executable to prove both
# argument boundaries and environment sanitization, not just command text.
cat > "$TMP_ROOT/bin/devin" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$DEVIN_TEST_RECORD/argv"
printf '%s' "${CLAUDECODE-}${PI_CODING_AGENT-}${CURSOR_AGENT-}${GROK_AGENT-}${FM_PI_HARNESS-}${CURSOR_INVOKED_AS-}" > "$DEVIN_TEST_RECORD/markers"
SH
DEVIN_TEST_RECORD="$TMP_ROOT" CLAUDECODE=1 PI_CODING_AGENT=true CURSOR_AGENT=1 \
  GROK_AGENT=1 FM_PI_HARNESS=pi-signed CURSOR_INVOKED_AS=cursor-agent \
  bash "$TMP_ROOT/shell-command"
expected=$(printf '%s\n' --respect-workspace-trust false --permission-mode smart --prompt-file "/path with 'quotes'/brief.md" --model swe-2-high)
[ "$expected" = "$(cat "$TMP_ROOT/argv")" ] || fail "direct launch argv changed"
[ ! -s "$TMP_ROOT/markers" ] || fail "foreign markers survived direct launch"
sleep() { :; }
fm_backend_herdr_cli() { echo '{"result":{"agent":{"agent":"pi","pane_id":"w1:p2","interactive_ready":true}}}'; }
! fm_devin_start fm-lab-test:w1:p2 "$TMP_ROOT/bin/devin" /brief default dangerous 2>/dev/null || fail "wrong native agent identity accepted"
pass "direct launch preserves argv, clears inherited markers and rejects wrong identity"

[ "$(fm_control_interrupt_key devin)" = Escape ] || fail "wrong interrupt key"
[ "$(fm_control_interrupt_repeat devin)" = 2 ] || fail "Devin requires double Escape"
[ "$(fm_control_exit_command devin)" = /exit ] || fail "wrong exit command"
! fm_control_harness_supports_kind devin secondmate || fail "Devin secondmate accepted"
fm_control_harness_supports_kind devin scout || fail "Devin scout refused"
[ "$(fm_composer_classify_content 1 '❭ hello')" = pending ] || fail "Devin real composer text not recognized"
[ "$(fm_composer_classify_content 1 '❭')" = empty ] || fail "Devin empty composer not recognized"
pass "Devin controls and composer classification are executable contracts"
