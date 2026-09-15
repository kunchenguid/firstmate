#!/usr/bin/env bash
# The D5 pipeline-state watch must be armed in repeat mode with the FM_HOME
# action-env, or a no-mistakes ship worker stalls forever after its first
# pipeline-state change: bin/fm-dod-lib.sh's Definition of done tells the
# worker to end its turn on the watch's ring instead of polling, and a
# single-fire watch only rings once. This drives the real bin/fm-spawn.sh
# and inspects the watch's own on-disk spec (bin/fm-procevent-when.sh's
# "fm-when-spec-v1" format) rather than reading fm-spawn.sh's source, so a
# future edit that drops --repeat, --edge, or --action-env fails here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-state-watch-arm)

home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" wt-nm-state-arm
id=watch-arm-check-1
fm_test_spawn_brief "$home" "$id"

out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
status=$?
[ "$status" -eq 0 ] || fail "ship+no-mistakes spawn failed (exit $status): $out"
assert_contains "$out" "armed: when-nm-state-$id (pipeline-state watch)" \
  "fm-spawn.sh did not report arming the pipeline-state watch: $out"

SPEC="$home/state/when/when-nm-state-$id.spec"
assert_present "$SPEC" "the pipeline-state watch's on-disk spec was not written"
assert_grep "repeat=1" "$SPEC" \
  "fm-spawn.sh must arm the pipeline-state watch with --repeat, or a worker stalls after its first pipeline-state change"
assert_grep "edge=1" "$SPEC" \
  "fm-spawn.sh must arm the pipeline-state watch with --edge, or the generic repeat dedup can swallow a real transition observed after a restart (the condition is itself edge-detecting)"
assert_grep "env_argc=1" "$SPEC" \
  "fm-spawn.sh must arm the pipeline-state watch with exactly one --action-env assignment (FM_HOME)"
assert_grep "FM_HOME=$home" "$SPEC" \
  "fm-spawn.sh must pass FM_HOME=<home> as the watch's action-env, or fm-send.sh cannot resolve the ring target"

pass "fm-spawn.sh arms the D5 pipeline-state watch with --repeat, --edge, and FM_HOME"
