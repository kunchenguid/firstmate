#!/usr/bin/env bash
# Debug repro for the fm-remote-job worker startup (mirrors tests/fm-remote-job.test.sh lines 1-174).
set -u
ROOT=/tmp/fmrepro/repo
TMP_ROOT=$(mktemp -d /tmp/fmdebug.XXXXXX)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'probe\n'
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
WORKER=$!
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
if [ -f "$STATE_ROOT/worker.ready" ]; then
  echo "READY OK"
else
  echo "READY MISSING"
fi
echo "--- worker.err:"
cat "$TMP_ROOT/worker.err"
echo "--- worker.out:"
cat "$TMP_ROOT/worker.out"
echo "--- state dir:"
ls -la "$STATE_ROOT" 2>/dev/null || echo "(no state dir)"
kill "$WORKER" 2>/dev/null || true
echo "TMP_ROOT=$TMP_ROOT"
