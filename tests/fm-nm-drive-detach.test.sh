#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  local start elapsed pid
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
  pid=$(cat "$PIDFILE")
  kill -0 "$pid" 2>/dev/null \
    || fail "$label child was not running when its PID returned"
  [ "$elapsed" -le 2 ] \
    || fail "$label detach took ${elapsed}s; expected a pid return in under 2s"
  if grep -q '^GATE$' "$OUT" 2>/dev/null; then
    fail "$label detach already contained GATE when the parent returned"
  fi
  printf '%s: pid=%s returned after %ss; child running; GATE absent\n' "$label" "$pid" "$elapsed"
  wait "$pid" || fail "$label child exited unsuccessfully"
  grep -q '^GATE$' "$OUT" \
    || fail "$label child never wrote GATE after wait"
  printf '%s: child completed after %ss; GATE present\n' "$label" "$(( $(date +%s) - start ))"
  rm -f "$PIDFILE"
}

repro_detach nohup
repro_detach ampersand

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-detach some-proj --mode no-mistakes >/dev/null 2>&1 \
  || fail "fm-brief.sh ship scaffold exited non-zero"
brief="$HOME_DIR/data/brief-detach/brief.md"
assert_grep "background it only through the harness mechanism" "$brief" \
  "generated brief dropped the tracked-background path"
assert_grep "Do not \`nohup\`" "$brief" \
  "generated brief still permits nohup"
assert_grep "trailing \`&\`" "$brief" \
  "generated brief still permits a trailing ampersand"
assert_grep "not permission to end the turn" "$brief" \
  "generated brief still treats paused: as end-turn permission"

: >"$HOME_DIR/config/wait-no-turns"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-fg some-proj --mode no-mistakes >/dev/null 2>&1 \
  || fail "fm-brief.sh wait-no-turns scaffold exited non-zero"
fg_brief="$HOME_DIR/data/brief-fg/brief.md"
assert_grep "Drive the run with ONE foreground" "$fg_brief" \
  "wait-no-turns brief lost the foreground drive"
assert_no_grep "background it only through the harness mechanism" "$fg_brief" \
  "wait-no-turns brief kept the absent-flag background drive"

pass "nm-drive-detach: Bash detach returns before GATE; generated instruction contract checked"
