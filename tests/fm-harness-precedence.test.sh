#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh's marker-vs-ancestry precedence boundary,
# and for the supervision protocol session start selects from it.
#
# The bug this pins: a Codex session started from an environment that had
# retained CLAUDECODE=1 detected as claude, because a verified marker outranked
# ancestry unconditionally. Session start then emitted Claude's Stop-owned
# supervision protocol to a Codex primary, which blocked every turn end.
#
# Every case drives the two evidence layers APART deliberately and asserts each
# one alone as well as the combination, so no case can pass vacuously if a layer
# silently stops working:
#   marker alone   - ancestry blinded by a fake ps, proving the marker is live
#                    and is what the old precedence would have returned.
#   ancestry alone - marker cleared, proving the ancestry signal is live.
#   both together  - the precedence verdict this file exists to pin.
# The fake ps blinds only the ancestry walk, and the suite proves that rather
# than assuming it. fm-harness.sh reads process ancestry through ps alone; the
# one source it does not read through ps is the Cursor argv[0] probe, which on
# Linux reads /proc directly and on macOS falls back to ps. Either way it
# resolves the harmless real path of a bash-named process, which
# fm_cursor_process_matches rejects. The no-marker case below asserts `unknown`
# under the fake ps on whichever platform the run happens on, and it is exactly
# that case that fails if the blinding ever leaks a real ancestor through.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite states the markers it means to test in every case. Drop the ambient
# ones so a verdict never depends on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

HARNESS="$ROOT/bin/fm-harness.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-precedence)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A real process named after a harness, asked for its verdict from a child.
# The command substitution around the probe is load-bearing: a bare `-c <cmd>`
# lets the shell exec the probe in place, which REPLACES the harness-named
# process the walk is supposed to find.
under_process() {  # <named-executable> [VAR=VAL ...]
  local bin=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$@" \
    "$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\""
}

# A fake ps that reports a bash ancestor terminating at pid 1, so the ancestry
# layer proves nothing and only the marker layer can answer.
blind_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# A fake ps that models a PID NAMESPACE: every process reports bash with ppid 1,
# and pid 1 reports whatever FM_TEST_PID1_COMM names. This is what a harness
# looks like from inside a container or `codex sandbox`, where the harness is
# pid 1 of its own namespace rather than a child of a shell.
namespace_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
prev=
for a in "$@"; do
  [ "$prev" = -p ] && pid=$a
  prev=$a
done
if [ "$pid" = 1 ]; then
  comm=${FM_TEST_PID1_COMM:-init}
  ppid=0
else
  comm=bash
  ppid=1
fi
case "$*" in
  *'ppid='*) printf '%s\n' "$ppid" ;;
  *) printf '%s\n' "$comm" ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# Run the harness script under a fake ps, with the ambient markers dropped so
# each case states its own.
under_fake_ps() {  # <fakebin> <VAR=VAL ...> -- [harness args]
  local fakebin=$1
  shift
  local -a assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    assignments+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "${assignments[@]}" \
    PATH="$fakebin:$BASE_PATH" "$HARNESS" "$@"
}

with_blind_ancestry() {  # <fakebin> [VAR=VAL ...]
  local fakebin=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$@" \
    PATH="$fakebin:$BASE_PATH" "$HARNESS"
}

named_bin() {  # <dir> <name>
  mkdir -p "$1"
  cp "$(command -v bash)" "$1/$2"
  printf '%s\n' "$1/$2"
}

# --- 1. A foreign marker never renames a markerless harness -----------------

# codex, opencode, kimi, and muse publish no identity marker, so before this
# boundary existed ANY retained marker renamed them outright. This is the
# reported live failure, generalized to every markerless adapter and to both
# foreign markers that can be retained.
test_markerless_ancestry_outranks_foreign_marker() {
  local dir fakebin bin got name
  dir="$TMP_ROOT/markerless"
  fakebin=$(blind_ancestry_bin "$dir/blind")
  for name in codex opencode kimi muse-bin-0.1.0; do
    bin=$(named_bin "$dir/$name-tree" "$name")
    local expect=$name
    case "$name" in muse-bin-*) expect=muse ;; esac

    got=$(under_process "$bin")
    [ "$got" = "$expect" ] \
      || fail "$name ancestry alone resolved '$got', expected $expect (the ancestry signal is not live)"

    got=$(with_blind_ancestry "$fakebin" CLAUDECODE=1)
    [ "$got" = claude ] \
      || fail "an inherited CLAUDECODE alone resolved '$got', expected claude (the marker signal is not live)"

    got=$(under_process "$bin" CLAUDECODE=1)
    [ "$got" = "$expect" ] \
      || fail "$name ancestry with an inherited CLAUDECODE resolved '$got', expected $expect"

    got=$(under_process "$bin" CURSOR_AGENT=1)
    [ "$got" = "$expect" ] \
      || fail "$name ancestry with an inherited CURSOR_AGENT resolved '$got', expected $expect"
  done
  pass "a markerless harness keeps its identity under an inherited foreign marker"
}

# --- 2. A genuine harness in its own process tree still wins ----------------

test_genuine_marker_and_ancestry_agree() {
  local dir bin got
  dir="$TMP_ROOT/genuine"

  bin=$(named_bin "$dir/claude-tree" claude)
  got=$(under_process "$bin" CLAUDECODE=1)
  [ "$got" = claude ] || fail "a genuine claude session resolved '$got', expected claude"

  bin=$(named_bin "$dir/cursor-tree" cursor-agent)
  got=$(under_process "$bin" CURSOR_AGENT=1)
  [ "$got" = cursor ] || fail "a genuine cursor session resolved '$got', expected cursor"
  got=$(under_process "$bin" CURSOR_INVOKED_AS=cursor-agent)
  [ "$got" = cursor ] || fail "a genuine cursor session (launcher marker) resolved '$got', expected cursor"

  bin=$(named_bin "$dir/grok-tree" grok)
  got=$(under_process "$bin" GROK_AGENT=1)
  [ "$got" = grok ] || fail "a genuine grok session resolved '$got', expected grok"
  # grok 1.0.0 hook processes carry no GROK_AGENT at all, so ancestry alone must
  # still answer for them.
  got=$(under_process "$bin")
  [ "$got" = grok ] || fail "an unmarked grok hook process resolved '$got', expected grok"

  pass "a harness that publishes a marker inside its own process tree is unchanged"
}

# Cursor is the case that motivated the pre-existing marker ordering: a cursor
# session started by hand under a claude primary carries BOTH markers. Ancestry
# is silent about which owns the tree there, so the ordering still decides.
test_cursor_ordering_still_decides_when_ancestry_is_silent() {
  local fakebin got
  fakebin=$(blind_ancestry_bin "$TMP_ROOT/cursor-ordering")
  got=$(with_blind_ancestry "$fakebin" CLAUDECODE=1 CURSOR_AGENT=1)
  [ "$got" = cursor ] || fail "both markers with no ancestry resolved '$got', expected cursor"
  got=$(with_blind_ancestry "$fakebin" CLAUDECODE=1 CURSOR_INVOKED_AS=cursor-agent)
  [ "$got" = cursor ] || fail "both markers (launcher form) with no ancestry resolved '$got', expected cursor"
  got=$(with_blind_ancestry "$fakebin" CLAUDECODE=1)
  [ "$got" = claude ] || fail "CLAUDECODE with no ancestry resolved '$got', expected claude"
  got=$(with_blind_ancestry "$fakebin")
  [ "$got" = unknown ] \
    || fail "no marker and no ancestry resolved '$got', expected unknown"
  pass "with ancestry silent, the marker layer and its cursor-first ordering still decide"
}

# The symmetric half of the same bug: cursor-agent's marker reaches a nested
# claude worker's environment, and the nearer claude ancestor must win.
test_retained_cursor_marker_does_not_rename_a_nested_claude() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/nested-claude" claude)
  got=$(under_process "$bin" CURSOR_AGENT=1 CLAUDECODE=1)
  [ "$got" = claude ] \
    || fail "a claude tree carrying a retained CURSOR_AGENT resolved '$got', expected claude"
  got=$(under_process "$bin" CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1)
  [ "$got" = claude ] \
    || fail "a claude tree carrying a retained cursor launcher marker resolved '$got', expected claude"
  pass "a retained cursor marker does not rename a nested claude worker"
}

# --- 3. Pi keeps the marker's more specific identity ------------------------

# Both Pi identities share the launcher name, so ancestry can only prove the
# family. A marker that agrees on the family must keep its finer verdict rather
# than being flattened to pi by the ancestry walk.
test_pi_signed_survives_agreeing_ancestry() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/pi-tree" pi)
  got=$(under_process "$bin" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$got" = pi-signed ] || fail "signed Pi over pi ancestry resolved '$got', expected pi-signed"
  got=$(under_process "$bin" PI_CODING_AGENT=true)
  [ "$got" = pi ] || fail "plain Pi over pi ancestry resolved '$got', expected pi"
  got=$(under_process "$bin")
  [ "$got" = pi ] || fail "unmarked pi ancestry resolved '$got', expected pi"

  bin=$(named_bin "$TMP_ROOT/pi-signed-tree" pi-signed)
  got=$(under_process "$bin" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$got" = pi-signed ] \
    || fail "signed Pi over shared signed-wrapper ancestry resolved '$got', expected pi-signed"
  got=$(under_process "$bin")
  [ "$got" = pi ] \
    || fail "unmarked signed-wrapper ancestry resolved '$got', expected pi"
  pass "an agreeing marker keeps Pi's finer identity that ancestry cannot prove"
}

# --- 4. The weakest ancestry signal does not outrank a marker ---------------

# A bare interpreter matched only by a harness name inside the script path it
# was handed is the weakest inference in fm-harness.sh: any node process holding
# a harness-shaped path matches it. It answers when nothing else does, but it
# must not overturn a harness publishing its own identity.
test_interpreter_args_match_does_not_outrank_a_marker() {
  local dir node script got
  dir="$TMP_ROOT/weak-args"
  node=$(named_bin "$dir" node)
  script="$dir/codex-tool.sh"
  cat > "$script" <<SH
r=\$("$HARNESS"); printf '%s' "\$r"
SH

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$node" "$script")
  [ "$got" = codex ] \
    || fail "an unmarked interpreter holding a codex-shaped script path resolved '$got', expected codex"

  got=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 "$node" "$script")
  [ "$got" = claude ] \
    || fail "a published CLAUDECODE lost to a codex-shaped script path, resolving '$got'"
  pass "an interpreter script-path match answers alone but never outranks a marker"
}

# The real Codex install topology, modelled because the fix depends on it. codex
# ships as a `node` npm shim that spawns its native `codex` binary as a child and
# waits, so BOTH are in a tool subprocess's parent chain and the native name is
# the nearer one. Verified live on 2026-09-01 with codex-cli 0.152.0, whose pane
# foreground process names were [node codex]. What this case pins is that rule
# and nothing wider: a native harness binary nearer than an interpreter decides
# at comm strength, so the shim's own script path never gets to hand the verdict
# back to a retained marker. The strength assertion below is what keeps that
# non-vacuous - reaching the node shim instead would answer 'args codex'.
# A fixture cannot notice a vendor topology change; the opt-in live drift guard
# (tests/fm-harness-liveness-drift-live-e2e.test.sh) owns that.
test_native_child_of_an_interpreter_shim_decides_at_comm_strength() {
  local dir node native probe entry got
  dir="$TMP_ROOT/shim-topology"
  node=$(named_bin "$dir" node)
  native=$(named_bin "$dir/vendor" codex)

  # The probe forks so the command substitution's child is what asks, exactly as
  # a tool subprocess of a real harness would.
  probe="$dir/probe.sh"
  cat > "$probe" <<'SH'
r=$("$FM_TEST_HARNESS" "$@")
printf '%s' "$r"
SH
  # The shim SPAWNS its native binary and waits, so the node process stays alive
  # above it and the walk meets the native binary first.
  entry="$dir/codex-cli-entry.sh"
  cat > "$entry" <<'SH'
"$FM_TEST_NATIVE" "$FM_TEST_PROBE" "$@" &
wait "$!"
SH

  # No arguments: the two cases that vary the environment or the subcommand call
  # the shim entry point directly below, so this helper stays the plain no-marker
  # launch.
  run_shim() {
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_TEST_HARNESS="$HARNESS" FM_TEST_NATIVE="$native" FM_TEST_PROBE="$probe" \
      "$node" "$entry"
  }

  got=$(run_shim)
  [ "$got" = codex ] \
    || fail "the shim topology without a marker resolved '$got', expected codex"

  got=$(env CLAUDECODE=1 FM_TEST_HARNESS="$HARNESS" FM_TEST_NATIVE="$native" \
    FM_TEST_PROBE="$probe" "$node" "$entry")
  [ "$got" = codex ] \
    || fail "the real Codex shim topology with a retained CLAUDECODE resolved '$got', expected codex"

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_TEST_HARNESS="$HARNESS" FM_TEST_NATIVE="$native" FM_TEST_PROBE="$probe" \
    "$node" "$entry" ancestry)
  [ "$got" = "comm codex" ] \
    || fail "the native child must decide at comm strength, got '$got'"
  pass "a native harness binary under an interpreter shim decides at comm strength"
}

# --- 5. A harness that is pid 1 of its own namespace ------------------------

# The walk used to stop as soon as the NEXT pid was 1, on the assumption that
# pid 1 is always init. Inside a PID namespace that assumption inverts: the
# harness itself is pid 1, so the one process that proves who owns the tree was
# never examined and a retained marker won by default. Verified against the real
# installed Codex, which runs as pid 1 under `codex sandbox`.
test_harness_at_namespace_pid1_is_examined() {
  local fakebin got
  fakebin=$(namespace_ancestry_bin "$TMP_ROOT/namespace-pid1")

  # Non-vacuity, both directions: with a host-shaped pid 1 the marker is the
  # only evidence and must still answer, so the case below cannot pass by the
  # ancestry layer simply matching everything.
  got=$(under_fake_ps "$fakebin" FM_TEST_PID1_COMM=init CLAUDECODE=1 --)
  [ "$got" = claude ] \
    || fail "a host-shaped pid 1 resolved '$got', expected claude (the marker layer is not live)"

  got=$(under_fake_ps "$fakebin" FM_TEST_PID1_COMM=codex --)
  [ "$got" = codex ] \
    || fail "a Codex session at namespace pid 1 resolved '$got' with no marker, expected codex"

  got=$(under_fake_ps "$fakebin" FM_TEST_PID1_COMM=codex CLAUDECODE=1 --)
  [ "$got" = codex ] \
    || fail "a Codex session at namespace pid 1 holding a retained CLAUDECODE resolved '$got', expected codex"

  got=$(under_fake_ps "$fakebin" FM_TEST_PID1_COMM=codex CLAUDECODE=1 -- ancestry)
  [ "$got" = "comm codex" ] \
    || fail "the namespace pid 1 harness must decide at comm strength, got '$got'"

  pass "a harness that is pid 1 of its own namespace is examined, not skipped"
}

# --- 6. The vantage point a probe asks from decides what strength it can see --

# The shipped guarantee is a strength claim, not just an identity one: detect_own
# hands an args-strength verdict back to a retained marker, so a harness is only
# protected where the walk reaches it at comm strength. Which strength is even
# REACHABLE depends on where the question is asked from. Under an interpreter
# shim the top of the session is the shim, whose own script path is args
# strength, while the native binary that carries comm strength is its CHILD.
# firstmate's own detect_own always runs from a tool subprocess below that child,
# so it sees comm; a guard that probed only the top of a real session would
# observe args, pass, and never notice a vendor release that stopped spawning the
# native child at all. `ancestry-descent` is what lets a probe ask from the same
# vantage a real session occupies, and this case pins that it reaches strictly
# further than the top-of-session probe does.
test_descent_probe_reaches_a_strength_the_top_of_session_cannot() {
  local dir node native hold entry ready shim_pid got waited
  dir="$TMP_ROOT/descent-vantage"
  node=$(named_bin "$dir" node)
  native=$(named_bin "$dir/vendor" codex)
  ready="$dir/ready"

  # The native binary parks until the test releases it, so the whole topology is
  # still standing while the probes run.
  hold="$dir/hold.sh"
  cat > "$hold" <<'SH'
touch "$FM_TEST_READY"
while [ -e "$FM_TEST_READY" ]; do sleep 0.05; done
SH
  # The shim spawns its native binary and waits, so the node process stays alive
  # ABOVE it exactly as the real Codex npm shim does.
  entry="$dir/codex-cli-entry.sh"
  cat > "$entry" <<'SH'
"$FM_TEST_NATIVE" "$FM_TEST_HOLD" &
wait "$!"
SH

  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_TEST_NATIVE="$native" FM_TEST_HOLD="$hold" FM_TEST_READY="$ready" \
    "$node" "$entry" &
  shim_pid=$!

  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || { rm -f "$ready"; kill "$shim_pid" 2>/dev/null; fail "the shim fixture never reached its native child"; }

  # Non-vacuity: the top-of-session vantage really is limited to args strength
  # here, which is the whole reason the descent probe has something to add.
  got=$("$HARNESS" ancestry "$shim_pid")
  [ "$got" = "args codex" ] \
    || fail "the shim's own vantage should see only 'args codex', got '$got'; the descent case proves nothing if the top of the session already reaches comm strength"

  got=$("$HARNESS" ancestry-descent "$shim_pid")
  case "$got" in
    *"comm codex"*) ;;
    *) fail "the descent probe did not reach the native child at comm strength, got '$got'" ;;
  esac

  # No vantage point inside the session may name a DIFFERENT harness, or a guard
  # built on this probe would accept a tree it should have rejected.
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$named" = codex ] \
      || fail "a vantage point inside the codex fixture reported '$strength $named'"
  done <<EOF
$got
EOF

  rm -f "$ready"
  wait "$shim_pid" 2>/dev/null || true
  pass "the descent probe reaches comm strength where the top-of-session probe sees only args"
}

# The other half of the vantage question: which vantages a probe must NOT ask
# from. harness_ancestry only ever climbs, so firstmate's own detection can never
# occupy a SIBLING branch of the process that runs it. A harness routinely spawns
# such branches - an MCP server started as `node <home>/.claude/mcp/<server>.js`
# matches *claude* on its script path in the bare-interpreter branch of the walk -
# and a probe that reported every descendant would answer a foreign harness from a
# process no real tool subprocess can ask from. The descent probe asks only the
# vantages on the upward path from the deepest descendant, which is exactly the set
# detection itself can reach.
test_descent_probe_ignores_a_sibling_branch_the_walk_cannot_reach() {
  local dir node native worker mcp_script block hold entry ready fifo
  local shim_pid mcp_pid got waited
  dir="$TMP_ROOT/descent-sibling"
  node=$(named_bin "$dir" node)
  native=$(named_bin "$dir/vendor" codex)
  worker=$(named_bin "$dir/vendor" worker)
  ready="$dir/ready"
  fifo="$dir/fifo"
  mkdir -p "$dir/.claude/mcp"
  mkfifo "$fifo"

  # Both leaves park on a fifo nothing ever writes, so they hold their position in
  # the tree without spawning children of their own and the depths stay fixed.
  block="$dir/block.sh"
  cat > "$block" <<'SH'
read -r _ < "$FM_TEST_FIFO"
SH
  # The MCP server is the sibling branch: a bare interpreter whose script path
  # carries a harness name it does not belong to.
  mcp_script="$dir/.claude/mcp/foo.js"
  cp "$block" "$mcp_script"

  # The native binary keeps a child of its own, so the deepest descendant is
  # unambiguously on the codex branch rather than tied with the sibling.
  hold="$dir/hold.sh"
  cat > "$hold" <<'SH'
"$FM_TEST_WORKER" "$FM_TEST_BLOCK" &
printf '%s\n' "$!" > "$FM_TEST_DIR/worker.pid"
touch "$FM_TEST_READY"
wait
SH
  entry="$dir/codex-cli-entry.sh"
  cat > "$entry" <<'SH'
"$FM_TEST_NATIVE" "$FM_TEST_HOLD" &
printf '%s\n' "$!" > "$FM_TEST_DIR/native.pid"
"$FM_TEST_NODE" "$FM_TEST_MCP" &
printf '%s\n' "$!" > "$FM_TEST_DIR/mcp.pid"
wait
SH

  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_TEST_DIR="$dir" FM_TEST_NODE="$node" FM_TEST_NATIVE="$native" \
    FM_TEST_WORKER="$worker" FM_TEST_HOLD="$hold" FM_TEST_BLOCK="$block" \
    FM_TEST_MCP="$mcp_script" FM_TEST_READY="$ready" FM_TEST_FIFO="$fifo" \
    "$node" "$entry" &
  shim_pid=$!

  waited=0
  while { [ ! -e "$ready" ] || [ ! -s "$dir/mcp.pid" ] || [ ! -s "$dir/worker.pid" ]; } \
    && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  release_sibling_fixture() {
    kill "$(cat "$dir/worker.pid" 2>/dev/null)" "$(cat "$dir/mcp.pid" 2>/dev/null)" \
      "$(cat "$dir/native.pid" 2>/dev/null)" "$shim_pid" 2>/dev/null || true
    wait "$shim_pid" 2>/dev/null || true
  }
  { [ -e "$ready" ] && [ -s "$dir/mcp.pid" ] && [ -s "$dir/worker.pid" ]; } \
    || { release_sibling_fixture; fail "the sibling fixture never reached both of its leaves"; }
  mcp_pid=$(cat "$dir/mcp.pid")

  # Non-vacuity: the sibling really does answer a foreign harness when asked, so a
  # probe that reported every descendant would have reported claude here.
  got=$("$HARNESS" ancestry "$mcp_pid")
  [ "$got" = "args claude" ] \
    || { release_sibling_fixture; fail "the sibling MCP process reported '$got', expected 'args claude'; this case proves nothing unless that branch really names a foreign harness"; }

  got=$("$HARNESS" ancestry-descent "$shim_pid")
  case "$got" in
    *"comm codex"*) ;;
    *) release_sibling_fixture; fail "the descent probe did not reach the native child at comm strength, got '$got'" ;;
  esac
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$named" = codex ] \
      || { release_sibling_fixture; fail "the descent probe reported '$strength $named' from a sibling branch the ancestry walk can never climb through"; }
  done <<EOF
$got
EOF

  release_sibling_fixture
  pass "the descent probe reports no verdict from a sibling branch detection cannot reach"
}

# The deeper shape the case above cannot reach, and the reason the live guard's
# reject-other-harness cross-check judges COMM-strength vantages only. A harness
# spawns its MCP servers from the AGENT BINARY, not from the npm shim, so the real
# Codex topology is shim -> native codex -> mcp server: the server inherits its
# parent's process group, passes the foreground filter, and is the deepest eligible
# descendant, which puts its own `args claude` vantage ON the descent path rather
# than off it. An args-strength verdict is path-ambiguous by construction - the
# bare-interpreter branch of the walk matches a harness name anywhere in the script
# path - so it is the comm-strength verdicts that carry a real process name and are
# the ones worth cross-checking. This case pins that the path still reaches
# `comm codex`, that every comm-strength vantage on it names codex, and that an
# `args claude` vantage really is present, which is what a cross-check applied to
# args strength would have rejected.
test_descent_probe_tolerates_an_args_only_foreign_verdict_at_the_deepest_vantage() {
  local dir node native mcp_script hold entry ready fifo
  local shim_pid mcp_pid got waited saw_comm
  dir="$TMP_ROOT/descent-deep-mcp"
  node=$(named_bin "$dir" node)
  native=$(named_bin "$dir/vendor" codex)
  ready="$dir/ready"
  fifo="$dir/fifo"
  mkdir -p "$dir/.claude/mcp"
  mkfifo "$fifo"

  mcp_script="$dir/.claude/mcp/foo.js"
  cat > "$mcp_script" <<'SH'
read -r _ < "$FM_TEST_FIFO"
SH

  # The native binary is what starts the MCP server, so the server sits BELOW it and
  # is the deepest descendant of the whole tree.
  hold="$dir/hold.sh"
  cat > "$hold" <<'SH'
"$FM_TEST_NODE" "$FM_TEST_MCP" &
printf '%s\n' "$!" > "$FM_TEST_DIR/mcp.pid"
touch "$FM_TEST_READY"
wait
SH
  entry="$dir/codex-cli-entry.sh"
  cat > "$entry" <<'SH'
"$FM_TEST_NATIVE" "$FM_TEST_HOLD" &
printf '%s\n' "$!" > "$FM_TEST_DIR/native.pid"
wait
SH

  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_TEST_DIR="$dir" FM_TEST_NODE="$node" FM_TEST_NATIVE="$native" \
    FM_TEST_HOLD="$hold" FM_TEST_MCP="$mcp_script" FM_TEST_READY="$ready" \
    FM_TEST_FIFO="$fifo" \
    "$node" "$entry" &
  shim_pid=$!

  waited=0
  while { [ ! -e "$ready" ] || [ ! -s "$dir/mcp.pid" ]; } && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  release_deep_mcp_fixture() {
    kill "$(cat "$dir/mcp.pid" 2>/dev/null)" "$(cat "$dir/native.pid" 2>/dev/null)" \
      "$shim_pid" 2>/dev/null || true
    wait "$shim_pid" 2>/dev/null || true
  }
  { [ -e "$ready" ] && [ -s "$dir/mcp.pid" ]; } \
    || { release_deep_mcp_fixture; fail "the deep MCP fixture never reached its server process"; }
  mcp_pid=$(cat "$dir/mcp.pid")

  got=$("$HARNESS" ancestry "$mcp_pid")
  [ "$got" = "args claude" ] \
    || { release_deep_mcp_fixture; fail "the MCP server reported '$got', expected 'args claude'; this case proves nothing unless the deepest vantage really answers a foreign harness"; }

  got=$("$HARNESS" ancestry-descent "$shim_pid")
  case "$got" in
    *"args claude"*) ;;
    *) release_deep_mcp_fixture; fail "the descent path did not include the MCP server's foreign args verdict, got '$got'; a cross-check restricted to comm strength is untested unless that vantage is on the path" ;;
  esac
  case "$got" in
    *"comm codex"*) ;;
    *) release_deep_mcp_fixture; fail "the descent probe did not reach the native binary at comm strength, got '$got'" ;;
  esac

  saw_comm=0
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$strength" = comm ] || continue
    [ "$named" = codex ] \
      || { release_deep_mcp_fixture; fail "a comm-strength vantage on the descent path reported '$named', expected codex"; }
    saw_comm=1
  done <<EOF
$got
EOF
  [ "$saw_comm" = 1 ] \
    || { release_deep_mcp_fixture; fail "no comm-strength vantage on the descent path, so the guard's strength requirement would reject this tree"; }

  release_deep_mcp_fixture
  pass "a foreign args-only verdict at the deepest vantage leaves the comm-strength identity intact"
}

# Two equally deep foreground leaves must not let ps ordering decide whether the
# chosen path reaches comm strength. The foreign MCP interpreter is spawned first
# in one pass and the native codex binary first in the other; both must resolve to
# the native leaf while the single-path shape remains intact.
test_descent_probe_prefers_comm_strength_when_deepest_leaves_tie() {
  local order dir node native mcp_script block entry ready fifo
  local shim_pid mcp_pid native_pid got waited
  for order in mcp-first native-first; do
    dir="$TMP_ROOT/descent-equal-$order"
    node=$(named_bin "$dir" node)
    native=$(named_bin "$dir/vendor" codex)
    ready="$dir/ready"
    fifo="$dir/fifo"
    mkdir -p "$dir/.claude/mcp"
    mkfifo "$fifo"

    block="$dir/block.sh"
    cat > "$block" <<'SH'
read -r _ < "$FM_TEST_FIFO"
SH
    mcp_script="$dir/.claude/mcp/foo.js"
    cp "$block" "$mcp_script"
    entry="$dir/codex-cli-entry.sh"
    cat > "$entry" <<'SH'
if [ "$FM_TEST_ORDER" = mcp-first ]; then
  "$FM_TEST_NODE" "$FM_TEST_MCP" &
  printf '%s\n' "$!" > "$FM_TEST_DIR/mcp.pid"
  "$FM_TEST_NATIVE" "$FM_TEST_BLOCK" &
  printf '%s\n' "$!" > "$FM_TEST_DIR/native.pid"
else
  "$FM_TEST_NATIVE" "$FM_TEST_BLOCK" &
  printf '%s\n' "$!" > "$FM_TEST_DIR/native.pid"
  "$FM_TEST_NODE" "$FM_TEST_MCP" &
  printf '%s\n' "$!" > "$FM_TEST_DIR/mcp.pid"
fi
touch "$FM_TEST_READY"
wait
SH

    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_TEST_ORDER="$order" FM_TEST_DIR="$dir" FM_TEST_NODE="$node" \
      FM_TEST_NATIVE="$native" FM_TEST_BLOCK="$block" FM_TEST_MCP="$mcp_script" \
      FM_TEST_READY="$ready" FM_TEST_FIFO="$fifo" "$node" "$entry" &
    shim_pid=$!

    waited=0
    while { [ ! -e "$ready" ] || [ ! -s "$dir/mcp.pid" ] || [ ! -s "$dir/native.pid" ]; } \
      && [ "$waited" -lt 200 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    mcp_pid=$(cat "$dir/mcp.pid" 2>/dev/null || true)
    native_pid=$(cat "$dir/native.pid" 2>/dev/null || true)
    release_equal_depth_fixture() {
      kill "$mcp_pid" "$native_pid" "$shim_pid" 2>/dev/null || true
      wait "$shim_pid" 2>/dev/null || true
    }
    { [ -e "$ready" ] && [ -n "$mcp_pid" ] && [ -n "$native_pid" ]; } \
      || { release_equal_depth_fixture; fail "the $order equal-depth fixture never reached both leaves"; }

    got=$("$HARNESS" ancestry "$mcp_pid")
    [ "$got" = "args claude" ] \
      || { release_equal_depth_fixture; fail "the $order MCP leaf reported '$got', expected 'args claude'"; }
    got=$("$HARNESS" ancestry "$native_pid")
    [ "$got" = "comm codex" ] \
      || { release_equal_depth_fixture; fail "the $order native leaf reported '$got', expected 'comm codex'"; }

    got=$("$HARNESS" ancestry-descent "$shim_pid" "$mcp_pid" "$native_pid")
    case "$got" in
      "comm codex"*) ;;
      *) release_equal_depth_fixture; fail "the $order equal-depth tie did not choose the comm-strength native leaf, got '$got'" ;;
    esac
    case "$got" in
      *"args claude"*) release_equal_depth_fixture; fail "the $order equal-depth tie chose the foreign args-strength leaf" ;;
    esac

    release_equal_depth_fixture
  done
  pass "equal-depth descent ties prefer the comm-strength leaf regardless of spawn order"
}

# --- 7. Session start's supervision protocol follows the corrected verdict ---

# The consequence the captain actually hit: the wrong verdict emitted Claude's
# Stop-owned protocol to a Codex primary, so every turn end was blocked for
# missing Claude recovery.
test_supervision_protocol_follows_corrected_verdict() {
  local dir home fakebin bin got
  dir="$TMP_ROOT/supervision"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config"
  bin=$(named_bin "$dir/codex-tree" codex)
  fakebin=$(blind_ancestry_bin "$dir/blind")

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_HOME="$home" \
    PATH="$fakebin:$BASE_PATH" "$RENDER")
  assert_contains "$got" "primary harness: claude" \
    "with ancestry blinded, the retained marker must still render claude (the case is otherwise vacuous)"

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_HOME="$home" \
    "$bin" -c "r=\$(\"$RENDER\"); printf '%s' \"\$r\"")
  assert_contains "$got" "primary harness: codex" \
    "a Codex primary carrying a retained CLAUDECODE did not render the Codex protocol"
  assert_contains "$got" "Mode: Codex foreground checkpoint." \
    "the rendered block is not Codex's foreground-checkpoint protocol"
  assert_not_contains "$got" "Mode: Claude Stop-hook-owned supervision." \
    "the rendered block still carries Claude's Stop-owned protocol"
  pass "session start renders the Codex protocol for a Codex primary holding a retained CLAUDECODE"
}

test_markerless_ancestry_outranks_foreign_marker
test_genuine_marker_and_ancestry_agree
test_cursor_ordering_still_decides_when_ancestry_is_silent
test_retained_cursor_marker_does_not_rename_a_nested_claude
test_pi_signed_survives_agreeing_ancestry
test_interpreter_args_match_does_not_outrank_a_marker
test_native_child_of_an_interpreter_shim_decides_at_comm_strength
test_harness_at_namespace_pid1_is_examined
test_descent_probe_reaches_a_strength_the_top_of_session_cannot
test_descent_probe_ignores_a_sibling_branch_the_walk_cannot_reach
test_descent_probe_tolerates_an_args_only_foreign_verdict_at_the_deepest_vantage
test_descent_probe_prefers_comm_strength_when_deepest_leaves_tie
test_supervision_protocol_follows_corrected_verdict
