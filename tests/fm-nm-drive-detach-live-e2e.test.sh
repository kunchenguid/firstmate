#!/usr/bin/env bash
# Token-free live guard for the no-mistakes drive detach hole: a Pi worker that
# backgrounds `axi run` with nohup or a trailing `&` gets a pid back before the
# parked gate exists, so ending the turn cannot consume the return.
#
# This does not submit a Pi prompt and does not talk to the shared no-mistakes
# daemon. It runs the same shell shapes the observed Pi/Grok ships used, against
# a stub drive, then checks the generated brief forbids that detach. Limits:
# it proves the detach returns before the gate, not that Pi will rewake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_NM_DRIVE_DETACH_LIVE pi

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-nm-drive-detach)
HOME_DIR="$TMP_ROOT/home"
DRIVE="$TMP_ROOT/fake-axi-run"
OUT="$TMP_ROOT/nm-run.out"
PIDFILE="$TMP_ROOT/nm-run.pid"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config"

cleanup() {
  local pid
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "${pid:-}" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  fm_test_cleanup
}
trap cleanup EXIT

cat >"$DRIVE" <<'EOF'
#!/usr/bin/env bash
sleep 8
printf 'GATE\n'
EOF
chmod +x "$DRIVE"

repro_detach() {
  local label=$1
  local start elapsed
  rm -f "$OUT" "$PIDFILE"
  start=$(date +%s)
  case "$label" in
    nohup)
      nohup "$DRIVE" >"$OUT" 2>&1 &
      echo $! >"$PIDFILE"
      ;;
    ampersand)
      ( "$DRIVE" ) >"$OUT" 2>&1 &
      echo $! >"$PIDFILE"
      ;;
    *)
      fail "unknown detach shape $label"
      ;;
  esac
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 2 ] \
    || fail "$label detach took ${elapsed}s; expected a pid return in under 2s (Pi $PI_VERSION)"
  if grep -q '^GATE$' "$OUT" 2>/dev/null; then
    fail "$label detach already contained GATE when the parent returned (Pi $PI_VERSION)"
  fi
  wait "$(cat "$PIDFILE")" 2>/dev/null || true
  grep -q '^GATE$' "$OUT" \
    || fail "$label child never wrote GATE after wait (Pi $PI_VERSION)"
}

repro_detach nohup
repro_detach ampersand

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-detach some-proj --mode no-mistakes >/dev/null 2>&1 \
  || fail "fm-brief.sh ship scaffold exited non-zero"
brief="$HOME_DIR/data/brief-detach/brief.md"
assert_grep "background it only through the harness mechanism" "$brief" \
  "generated brief dropped the tracked-background path (Pi $PI_VERSION)"
assert_grep "Do not \`nohup\`" "$brief" \
  "generated brief still permits nohup (Pi $PI_VERSION)"
assert_grep "trailing \`&\`" "$brief" \
  "generated brief still permits a trailing ampersand (Pi $PI_VERSION)"
assert_grep "not permission to end the turn" "$brief" \
  "generated brief still treats paused: as end-turn permission (Pi $PI_VERSION)"

: >"$HOME_DIR/config/wait-no-turns"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-fg some-proj --mode no-mistakes >/dev/null 2>&1 \
  || fail "fm-brief.sh wait-no-turns scaffold exited non-zero"
fg_brief="$HOME_DIR/data/brief-fg/brief.md"
assert_grep "Drive the run with ONE foreground" "$fg_brief" \
  "wait-no-turns brief lost the foreground drive (Pi $PI_VERSION)"
assert_no_grep "background it only through the harness mechanism" "$fg_brief" \
  "wait-no-turns brief kept the absent-flag background drive (Pi $PI_VERSION)"

pass "nm-drive-detach: Pi $PI_VERSION nohup/ampersand return before GATE; brief forbids that detach"
