#!/usr/bin/env bash
# Token-free live-harness guard for the generated Pi worker stream extension.
# Uses the REAL installed Pi SDK with synthetic transport and isolated homes.
# No external provider, credentials, live fleet, or primary extension is used.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_PI_WORKER_STREAM_LIVE node pi jq

PI_EXECUTABLE=$(command -v pi)
PI_PACKAGE_DIR=$(node -e 'const fs=require("node:fs"),p=require("node:path"); console.log(p.resolve(p.dirname(fs.realpathSync(process.argv[1])),"../.."));' "$PI_EXECUTABLE")
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json") || fail "Pi package version unavailable"
[ "$PI_VERSION" = 1.2.0 ] || fail "Pi $PI_VERSION: worker stream contract verified only on 1.2.0"
TMP_ROOT=$(fm_test_tmproot fm-pi-worker-stream-live)
sdk_env=(env -i)
for name in NO_MISTAKES_GATE CODEX_MANAGED_BY_NPM CODEX_MANAGED_PACKAGE_ROOT; do
  [ "${!name+x}" != x ] || sdk_env+=("$name=${!name}")
done

for case_label in enabled disabled stalled; do
  enabled=300
  [ "$case_label" != disabled ] || enabled=0
  home="$TMP_ROOT/home-$case_label"
  project="$TMP_ROOT/project-$case_label"
  wt="$TMP_ROOT/wt-$case_label"
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$project" "$wt" "stream-$case_label"
  fm_test_spawn_brief "$home" stream
  # Each case gets its own spawn world, like every other spawn suite here. A
  # shared fake tmux records the window it created, so the next case's spawn of
  # the same task id would be refused as a duplicate window instead of running.
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake-$case_label")
  spawn_root=$ROOT fault_dir=''
  if [ "$case_label" = stalled ]; then
    fault_dir="$home/fault"
    spawn_root="$home/toolkit"
    mkdir -p "$fault_dir" "$spawn_root"
    cp -R "$ROOT/bin" "$spawn_root/bin"
    # The publication guard must be able to establish that this disposable
    # toolkit and the fixture project have unrelated histories.
    fm_git_init_commit "$spawn_root"
    mv "$spawn_root/bin/fm-busy-event.sh" "$spawn_root/bin/fm-busy-event-real.sh"
    # Inject one command stall at the generated extension's executable boundary.
    # The SDK, extension, deadline owner, and subsequent writer calls remain real.
    cat > "$spawn_root/bin/fm-busy-event.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stream ] && [ "\${4:-}" = progress ] && [ ! -e "$fault_dir/once" ]; then
  touch "$fault_dir/once"
  trap '' TERM
  sleep 300 &
  printf '%s\n%s\n' "\$\$" "\$!" > "$fault_dir/pids"
  wait
fi
exec "$spawn_root/bin/fm-busy-event-real.sh" "\$@"
SH
    chmod +x "$spawn_root/bin/fm-busy-event.sh"
  fi
  out=$(ROOT="$spawn_root" FM_STREAM_SILENT_MAX_SECS="$enabled" fm_test_run_spawn "$home" "$wt" "$fakebin" stream "$project" pi --mode no-mistakes --yolo off) \
    || fail "Pi $PI_VERSION: could not generate worker extension: $out"
  mkdir -p "$home/agent"
  cat > "$home/agent/models.json" <<'JSON'
{"providers":{"fm-worker-stream":{"baseUrl":"https://fm-worker-stream.invalid/v1","api":"openai-completions","apiKey":"synthetic-local-only","models":[{"id":"stream","name":"stream","contextWindow":8192,"maxTokens":512}]}}}
JSON
  # Preserve gate identity while excluding ambient credentials and discovery.
  "${sdk_env[@]}" PATH="$PATH" HOME="$home/user-home" NODE_NO_WARNINGS=1 \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$home/agent" \
    STREAM_STATE="$home/state" STREAM_EXTENSION="$home/state/stream.pi-ext.ts" \
    STREAM_CWD="$wt" STREAM_ENABLED="$enabled" STREAM_FAULT_DIR="$fault_dir" \
    node "$ROOT/tests/fm-pi-worker-stream-live.mjs" || fail "Pi $PI_VERSION: real worker stream guard failed ($case_label)"
done
if ! command -v pi-signed >/dev/null 2>&1; then
  printf '# pi-signed unavailable: signed executable not exercised\n'
fi
pass "real Pi 1.2.0 worker stream lifecycle, background exclusion, and default-off behavior"
