#!/usr/bin/env bash
# Portable real-process identity proof, without a terminal or model service.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
LAB=$(fm_test_tmproot fm-agent-process)
PIDS=()
cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/codex" "$LAB/decoy"
CC=$(command -v cc || command -v gcc || true)
[ -n "$CC" ] || { echo 'skip: C compiler absent; real version-name divergence not checked'; exit 0; }
printf '%s\n' '#include <unistd.h>' 'int main(void){for(;;)sleep(60);return 0;}' > "$LAB/spin.c"
"$CC" -o "$LAB/codex/2.1.220" "$LAB/spin.c"
"$CC" -o "$LAB/decoy/2.1.220" "$LAB/spin.c"
read_identity() { # <pid>
  local pid=$1
  KERNEL=$(ps -p "$pid" -o comm= | sed 's/^[[:space:]]*//')
  KERNEL=${KERNEL##*/}
  ARGS=$(ps -p "$pid" -o args= | sed 's/^[[:space:]]*//')
  ARGV0=${ARGS%% *}
  kill -0 "$pid" || fail 'identity process exited before observation'
}
"$LAB/codex/2.1.220" &
pid=$!; PIDS+=("$pid")
read_identity "$pid"
[ "$(fm_agent_process_classify_name "$KERNEL")" = other ] || fail 'kernel version-name divergence was not established on this platform'
[ "$(fm_agent_process_classify_name "$ARGV0")" = agent ] || fail 'argv executable path did not retain its exact harness component'
[ "$(fm_agent_process_classify "$KERNEL" "$ARGV0" "$ARGS" "$pid")" = agent ] || fail 'argv evidence did not preserve liveness after losing the kernel name'
pass 'real version-named process has divergent kernel/argv evidence and remains an agent'
"$LAB/decoy/2.1.220" &
pid=$!; PIDS+=("$pid")
read_identity "$pid"
[ "$(fm_agent_process_classify "$KERNEL" "$ARGV0" "$ARGS" "$pid")" = other ] || fail 'decoy executable path became an agent'
pass 'the same real version name under a decoy path never becomes an agent'
for name in pi traex traecli; do
  [ "$(fm_agent_process_classify sleep "$name" "$name 900")" = agent ] || fail 'retained argv identity lost'
done
for name in extraex notaharness claude; do
  [ "$(fm_agent_process_classify sleep "$name" "$name 900")" = other ] || fail 'unrecognized executable became an agent'
done
[ "$(fm_agent_process_classify sh -sh sh)" = shell ] || fail 'matching shell evidence lost'
[ "$(fm_agent_process_classify sh unknown unknown)" = other ] || fail 'conflicting process evidence became a dead shell'
pass 'retained identities, decoys and conflicting shell evidence remain distinct'
