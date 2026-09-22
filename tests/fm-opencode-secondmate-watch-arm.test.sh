#!/usr/bin/env bash
# Behavior tests for the armability predicate in
# .opencode/plugins/fm-primary-watch-arm.js, the OpenCode watcher-arm plugin.
#
# Drives the real plugin in a plain Node host against git fixtures and a stub
# bin/fm-watch-arm.sh, so the arm decision - including the effective-home and
# stale-treehouse-marker boundaries - is exercised with no live OpenCode session
# and no model tokens. docs/supervision-protocols/opencode.md owns the contract:
# the plugin applies in the main primary checkout and a secondmate's own home,
# and stays silent in child crewmate and scout worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
TMP_ROOT=$(fm_test_tmproot fm-opencode-secondmate-watch-arm)
fm_git_identity

# write_arm_stub <root>: a worktree/checkout the plugin treats as a home needs
# AGENTS.md, bin/, and an arm script that reports a verified start and then
# parks, recording its pid and a sentinel so the test can observe and reap it.
write_arm_stub() {
  local root=$1
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
printf '%s\n' "$$" > "${ARM_PID_FILE:?}"
: > "${ARM_SENTINEL:?}"
exec sleep 5
SH
  chmod +x "$root/bin/fm-watch-arm.sh"
  : > "$root/AGENTS.md"
}

# drive_plugin <worktree> <state-dir> [env assignment...]: load the real plugin
# in a clean Node host, fire session.idle, and let it decide whether to spawn the
# stub arm script. The driver writes its own pid as the session lock so the
# plugin's lock-ownership check passes.
drive_plugin() {
  local wt=$1 state=$2
  shift 2
  mkdir -p "$state"
  : > "$state/fixture.meta"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    PLUGIN_PATH="$PLUGIN" WORKTREE="$wt" FM_STATE_OVERRIDE="$state" \
    ARM_SENTINEL="$ARM_SENTINEL" ARM_PID_FILE="$ARM_PID_FILE" \
    "$@" \
    node --input-type=module - <<'EOF'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
mkdirSync(process.env.FM_STATE_OVERRIDE, { recursive: true });
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, String(process.pid));
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmPrimaryWatchArm({
  client: { session: { promptAsync: async () => {} } },
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_fixture" } } });
await new Promise((resolve) => setTimeout(resolve, 1500));
EOF
}

reap_sentinel() {
  local pid
  pid=$(cat "$ARM_PID_FILE" 2>/dev/null || true)
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  kill -TERM "$pid" 2>/dev/null || true
}

# expect_arm <label> <expect-armed> <worktree> <state-dir> [env assignment...]
expect_arm() {
  local label=$1 expect=$2 wt=$3 state=$4
  shift 4
  ARM_SENTINEL="$TMP_ROOT/$label.armed"
  ARM_PID_FILE="$TMP_ROOT/$label.pid"
  rm -f "$ARM_SENTINEL" "$ARM_PID_FILE"
  drive_plugin "$wt" "$state" "$@"
  reap_sentinel
  if [ "$expect" = armed ]; then
    [ -e "$ARM_SENTINEL" ] || fail "$label: expected the watcher to arm, but it stayed inert"
  else
    [ ! -e "$ARM_SENTINEL" ] || fail "$label: expected the watcher to stay inert, but it armed"
  fi
  pass "$label"
}

# --- fixtures ---------------------------------------------------------------
# A linked worktree of a firstmate-ish repo stands in for a pooled slot, and the
# main checkout stands in for a genuine primary. Both carry AGENTS.md and bin/.

PLAIN="$TMP_ROOT/plain"
WT="$TMP_ROOT/wt"
OTHER="$TMP_ROOT/other-home"
fm_git_worktree "$PLAIN" "$WT" "wt-fixture"
write_arm_stub "$PLAIN"
write_arm_stub "$WT"
mkdir -p "$OTHER/state"

# --- armable ----------------------------------------------------------------
# A genuine secondmate home: a linked worktree whose valid marker is also the
# declared FM_HOME.
printf 'sm-fixture\n' > "$WT/.fm-secondmate-home"
expect_arm "armable-linked-marked-home" armed "$WT" "$WT/state" \
  FM_HOME="$WT" FM_ROOT_OVERRIDE="$WT"

# The plain primary checkout has no marker and is armable everywhere.
expect_arm "primary-plain-checkout" armed "$PLAIN" "$PLAIN/state" \
  FM_HOME="$PLAIN" FM_ROOT_OVERRIDE="$PLAIN"

# --- inert ------------------------------------------------------------------
# The same marked linked worktree with no declared home is the pooled
# crewmate/scout slot shape: a stale treehouse marker must never arm there.
expect_arm "inert-no-declared-home" inert "$WT" "$WT/state"

# A marked worktree whose FM_HOME points elsewhere (the stale-marker case).
expect_arm "inert-stale-marker-other-home" inert "$WT" "$OTHER/state" \
  FM_HOME="$OTHER" FM_ROOT_OVERRIDE="$WT"

# An invalid marker (empty first line) is not a secondmate home.
printf '\n' > "$WT/.fm-secondmate-home"
expect_arm "inert-invalid-marker" inert "$WT" "$WT/state" \
  FM_HOME="$WT" FM_ROOT_OVERRIDE="$WT"

# A linked worktree with no marker stays inert on the plain-checkout rule.
rm -f "$WT/.fm-secondmate-home"
expect_arm "inert-unmarked-linked-worktree" inert "$WT" "$WT/state" \
  FM_HOME="$WT" FM_ROOT_OVERRIDE="$WT"
