#!/usr/bin/env bash
set -u
ROOT=/tmp/fmrepro/repo
T=$(mktemp -d /tmp/fmwx.XXXXXX)
R="$T/remote-root"; A="$T/account"; S="$T/remote-jobs"; RB="$T/rbin"
mkdir -p "$R/bin" "$A" "$RB"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$R/bin/"
printf 'fixture\n' > "$R/AGENTS.md"
printf '#!/bin/bash\nexit 127\n' > "$RB/perl"
chmod +x "$RB/perl" "$R/bin"/*.sh
cd /tmp
HOME="$A" PATH="$RB:/usr/bin:/bin:/usr/sbin:/sbin" FM_ROOT_OVERRIDE="$R" \
  FM_REMOTE_JOB_STATE_ROOT="$S" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  timeout 8 bash -x "$R/bin/fm-remote-job-worker.sh" --serve > "$T/out" 2> "$T/trace"
echo "rc=$?"
echo "=== last 60 trace lines:"
tail -60 "$T/trace"
echo "TRACE=$T/trace"
