#!/usr/bin/env bash
# Behavioral contract for per-Firstmate-home no-mistakes custody.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot nm-home-isolation)
HOME_A="$TMP_ROOT/firstmate-a"
HOME_B="$TMP_ROOT/firstmate-b"
mkdir -p "$HOME_A" "$HOME_B"

# The owner must bind each home deterministically and keep an explicit operator
# NM_HOME override authoritative.
home_a_root=$(FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_home' _ "$ROOT/bin/fm-nm-run-lib.sh")
home_b_root=$(FM_HOME="$HOME_B" NM_HOME='' bash -c '. "$1"; fm_nm_home' _ "$ROOT/bin/fm-nm-run-lib.sh")
[ "$home_a_root" != "$home_b_root" ] || fail "different Firstmate homes share a no-mistakes root"
[ "$home_a_root" = "$(FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_home' _ "$ROOT/bin/fm-nm-run-lib.sh")" ] || fail "home A root is not stable"
[ "$home_a_root" = "$HOME_A/.no-mistakes" ] || fail "home A root is not the documented private root"
override_root="$TMP_ROOT/operator-no-mistakes"
[ "$(FM_HOME="$HOME_A" NM_HOME="$override_root" bash -c '. "$1"; fm_nm_home' _ "$ROOT/bin/fm-nm-run-lib.sh")" = "$override_root" ] || fail "explicit NM_HOME override lost"

isolated_config=$(FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home; cat "$FM_HOME/.no-mistakes/config.yaml"' _ "$ROOT/bin/fm-nm-run-lib.sh")
[ "$isolated_config" = 'agent: [codex]' ] || fail "isolated root is not configured for Codex"

cat > "$HOME_A/.no-mistakes/config.yaml" <<'EOF'
agent: [claude, codex]
session_reuse: true
EOF
before_config=$(sha256sum "$HOME_A/.no-mistakes/config.yaml" | cut -d' ' -f1)
FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
grep -Fx 'agent: [codex]' "$HOME_A/.no-mistakes/config.yaml" >/dev/null || fail "reread did not converge the pipeline agent to Codex"
grep -Fx 'session_reuse: true' "$HOME_A/.no-mistakes/config.yaml" >/dev/null || fail "reread discarded unrelated configuration"
! grep -F 'claude' "$HOME_A/.no-mistakes/config.yaml" >/dev/null || fail "reread left Claude in the home-owned agent configuration"
FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
after_config=$(sha256sum "$HOME_A/.no-mistakes/config.yaml" | cut -d' ' -f1)
[ "$before_config" != "$after_config" ] || fail "reread/convergence test did not exercise a stale agent configuration"
FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
stable_config=$(sha256sum "$HOME_A/.no-mistakes/config.yaml" | cut -d' ' -f1)
[ "$after_config" = "$stable_config" ] || fail "repeated preparation was not stable"

# A real bounded owner call must carry the resolved root to the executable.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CALLS="$TMP_ROOT/calls"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${NM_HOME:-}" "$*" >> "$NM_CALLS"
printf 'status: awaiting_approval\n'
SH
chmod +x "$FAKEBIN/no-mistakes"
mkdir -p "$HOME_A/worktree"
PATH="$FAKEBIN:$PATH" NM_CALLS="$CALLS" FM_HOME="$HOME_A" NM_HOME='' \
  bash -c '. "$1"; fm_nm_run_bounded "$2" 5 axi status >/dev/null' _ "$ROOT/bin/fm-nm-run-lib.sh" "$HOME_A/worktree"
grep -F "$home_a_root" "$CALLS" >/dev/null || fail "bounded run did not use the home root"
! grep -F "$HOME/.no-mistakes" "$CALLS" >/dev/null || fail "bounded run reached the legacy default root"
! grep -E 'TOKEN|SECRET|PASSWORD|Authorization' "$CALLS" >/dev/null || fail "credential material reached the emitted command record"

pass "no-mistakes root is deterministic, overrideable, and propagated without legacy-root access"
