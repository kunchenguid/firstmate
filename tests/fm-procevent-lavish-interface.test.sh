#!/usr/bin/env bash
# Executable-interface tests for Lavish poll transport selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-lavish-interface)
HOME_FIXTURE="$TMP_ROOT/home"
OVERRIDE_BIN="$TMP_ROOT/operator-bin"
ARTIFACT="$TMP_ROOT/review.html"
CALL_LOG="$TMP_ROOT/calls.log"
mkdir -p "$HOME_FIXTURE/.local/bin" "$OVERRIDE_BIN"
printf '<h1>review</h1>\n' > "$ARTIFACT"

make_poll_stub() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$0" "${1-}" "${2-}" >> "${CALL_LOG:?}"
printf 'session:\n  status: waiting\n'
SH
  chmod +x "$1"
}

make_poll_stub "$HOME_FIXTURE/.local/bin/lavish-axi"
make_poll_stub "$HOME_FIXTURE/.local/bin/lavish-wsl"
make_poll_stub "$OVERRIDE_BIN/lavish-axi"

run_poll() {
  HOME="$HOME_FIXTURE" CALL_LOG="$CALL_LOG" FM_LAVISH_POLL_RETRY_DELAY=0 \
    PATH="$1:$PATH" WSL_DISTRO_NAME="${2-}" \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$ARTIFACT" >/dev/null
}

: > "$CALL_LOG"
run_poll "$HOME_FIXTURE/.local/bin" Ubuntu
row=$(cat "$CALL_LOG")
assert_contains "$row" "$HOME_FIXTURE/.local/bin/lavish-wsl" "WSL canonical install selects the Windows bridge"
assert_contains "$row" $'\tpoll\t' "WSL bridge receives the published poll interface"
assert_contains "$row" "$ARTIFACT" "WSL bridge receives the physical artifact path"
pass "WSL canonical Lavish polling uses the executable bridge"

: > "$CALL_LOG"
run_poll "$OVERRIDE_BIN:$HOME_FIXTURE/.local/bin" Ubuntu
row=$(cat "$CALL_LOG")
assert_contains "$row" "$OVERRIDE_BIN/lavish-axi" "a PATH-selected operator override stays native under WSL"
assert_not_contains "$row" "lavish-wsl" "the WSL bridge does not replace an operator override"
pass "WSL operator override remains native"

: > "$CALL_LOG"
run_poll "$HOME_FIXTURE/.local/bin" ""
row=$(cat "$CALL_LOG")
assert_contains "$row" "$HOME_FIXTURE/.local/bin/lavish-axi" "native polling uses the resolved Lavish executable"
assert_not_contains "$row" "lavish-wsl" "native polling does not select the WSL bridge"
pass "native polling uses the resolved Lavish executable"
