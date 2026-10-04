#!/usr/bin/env bash
# Token-free live native-discard guard. Only the explicitly version-pinned
# Claude adapter runs; other harnesses are reported as unsupported, not tested.
# All Herdr calls, including fm-control's backend reads, pass through the lab
# helper. FM_NATIVE_CLAUDE_BIN may select an already installed tested binary.
# FM_CLAUDE_NATIVE_BUSY_LIVE=1 explicitly interrupts one tools-disabled model turn through
# the existing authenticated Claude store and trusted task worktree. It must
# fail, not skip, if that store does not admit the early-access hooks module.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "${FM_CLAUDE_NATIVE_BUSY_LIVE:-0}" = 1 ]; then
  fm_live_gate opt-in FM_CLAUDE_NATIVE_BUSY_LIVE claude herdr jq python3
else
  fm_live_gate default-on FM_CLAUDE_NATIVE_LIVE claude herdr jq python3
fi
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-native-live.XXXXXX")
export FM_HOME="$SCRATCH/home"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-6202-discard-draft-design)
cleanup() {
  local status=$? result=0
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || result=1
  "$LAB_HOME_HELPER" teardown "$FM_HOME" || result=1
  if [ "$result" != 0 ]; then exit 1; fi
  if [ "$status" = 0 ] && [ "${FM_NATIVE_KEEP_EVIDENCE:-0}" != 1 ]; then
    rm -rf "$SCRATCH"
  else
    echo "native live evidence: $SCRATCH" >&2
  fi
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
export HERDR_LAB_HELPER HERDR_LAB_SESSION SCRATCH ROOT
export FM_NATIVE_CLAUDE_BIN=${FM_NATIVE_CLAUDE_BIN:-$(command -v claude)}
export HERDR_LAB_REAL_PATH=$PATH
python3 "$ROOT/tests/fixtures/native-control/live.py"
