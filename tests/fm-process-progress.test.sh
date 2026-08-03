#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-process-progress)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SNAPSHOT="$TMP_ROOT/snapshot"
PROGRESS="$ROOT/bin/fm-process-progress.sh"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-p 42 -o lstart= -o command=')
    printf 'Mon Aug  3 12:00:00 2026 root-process\n'
    ;;
  '-axo pid=,ppid=,lstart=,time=')
    cat "$FM_FAKE_PS_SNAPSHOT"
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/ps"

sample() {
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_PROCESS_PROGRESS_ROOT_PID=42 FM_FAKE_PS_SNAPSHOT="$SNAPSHOT" \
    "$PROGRESS" tmux test:fm-progress
}

mkdir -p "$TMP_ROOT/state"
cat > "$SNAPSHOT" <<'EOF'
 42  1 Mon Aug  3 12:00:00 2026 0:00.20
 43 42 Mon Aug  3 12:00:01 2026 0:00.80
EOF
first=$(sample) || fail "initial cumulative sample failed"
cat > "$SNAPSHOT" <<'EOF'
 42  1 Mon Aug  3 12:00:00 2026 0:00.20
EOF
second=$(sample) || fail "post-child-exit sample failed"
cat > "$SNAPSHOT" <<'EOF'
 42  1 Mon Aug  3 12:00:00 2026 0:00.25
EOF
third=$(sample) || fail "subsequent root-progress sample failed"

first_cpu=${first#*$'\t'}
second_cpu=${second#*$'\t'}
third_cpu=${third#*$'\t'}
[ "$first_cpu" -eq 100 ] || fail "initial descendant total was $first_cpu, expected 100"
[ "$second_cpu" -eq "$first_cpu" ] || fail "exited child made cumulative CPU fall from $first_cpu to $second_cpu"
[ "$third_cpu" -gt "$second_cpu" ] || fail "new CPU after child exit did not advance the cumulative total"
pass "process progress remains monotonic across descendant exit"
