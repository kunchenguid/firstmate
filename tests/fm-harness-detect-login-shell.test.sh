#!/usr/bin/env bash
# Behavior tests for harness auto-detection across a login shell in the parent chain.
#
# ps -o comm= reports a login shell as "-zsh" (leading dash). The chain walk used
# to hand that straight to basename(1); BSD basename parses the leading "-z" as an
# option and fails with "illegal option -- z", so every detection run from a login
# shell sprayed stderr. GNU basename accepts it, making this macOS/BSD-only.
#
# The noise never changed a verdict - the walk continues past the failed
# substitution - but it appears alongside spawn's genuine
# "no launch template for harness 'unknown'" refusal and reads as its cause.
# These tests pin both halves: no stderr noise, and verdicts unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness-detect-login-shell)
HARNESS="$ROOT/bin/fm-harness.sh"

# A fake ps driven by FM_FAKE_CHAIN="pid:comm:ppid,...". An unknown pid (the
# script's real $$) resolves to the head of the chain, so a test can describe an
# ancestry without knowing any live pid.
make_fake_ps() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=""; want=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) field="$2"; shift 2 ;;
    -p) want="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() {
  case "$field" in
    comm=) printf '%s\n' "$1" ;;
    args=) printf '%s\n' "$1" ;;
    ppid=) printf '%s\n' "$2" ;;
  esac
}
old=$IFS; IFS=','; set -f; ents=($FM_FAKE_CHAIN); IFS=$old; set +f
for e in "${ents[@]}"; do
  p="${e%%:*}"; rest="${e#*:}"; c="${rest%%:*}"; pp="${rest##*:}"
  [ "$p" = "$want" ] && { emit "$c" "$pp"; exit 0; }
done
e="${ents[0]}"; rest="${e#*:}"; emit "${rest%%:*}" "${rest##*:}"
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

FAKEBIN=$(make_fake_ps)

# detect <chain> -> echoes the verdict; stderr captured in $DETECT_ERR
DETECT_ERR="$TMP_ROOT/stderr.txt"
detect() {
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      PATH="$FAKEBIN:$PATH" FM_FAKE_CHAIN="$1" FM_CONFIG_OVERRIDE="$TMP_ROOT/noconfig" \
      bash "$HARNESS" 2>"$DETECT_ERR"
}

# --- 1. a login shell in the chain must not produce stderr noise -------------

out=$(detect "100:-zsh:1")
[ -s "$DETECT_ERR" ] \
  && fail "login shell '-zsh' in the chain wrote to stderr: $(head -1 "$DETECT_ERR")"
pass "login shell '-zsh' walks silently (no BSD basename 'illegal option' noise)"

# --- 2. verdicts are unchanged ----------------------------------------------

# A plain login shell genuinely has no harness ancestor: 'unknown' is correct.
[ "$out" = "unknown" ] || fail "expected 'unknown' for a bare login shell, got '$out'"
pass "bare login shell still resolves to 'unknown' (no harness in the ancestry)"

# A harness ABOVE the login shell is still found - the dash never blocked the walk.
out=$(detect "100:-zsh:200,200:claude:1")
[ "$out" = "claude" ] || fail "expected 'claude' through a login shell, got '$out'"
[ -s "$DETECT_ERR" ] && fail "detection through a login shell wrote to stderr"
pass "harness above a login shell is still detected, silently"

# --- 3. a directory prefix is still stripped (the basename behaviour kept) ---

out=$(detect "100:/usr/local/bin/codex:1")
[ "$out" = "codex" ] || fail "expected 'codex' from an absolute comm path, got '$out'"
pass "absolute comm path still resolves to its basename"

# The 'pi' arm is an exact match, so stripping must be exact too.
out=$(detect "100:/opt/homebrew/bin/pi:1")
[ "$out" = "pi" ] || fail "expected exact-match 'pi' from a path, got '$out'"
pass "exact-match arm ('pi') still matches after prefix stripping"

# --- 4. a login shell must not be mistaken for a harness --------------------

out=$(detect "100:-bash:1")
[ "$out" = "unknown" ] || fail "expected 'unknown' for '-bash', got '$out'"
pass "login shell '-bash' is not mistaken for a harness"
