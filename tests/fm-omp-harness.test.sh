#!/usr/bin/env bash
# Behavior tests for the verified omp ("Oh My Pi") crewmate/secondmate adapter:
# harness detection precedence, the semantic busy-state extension's real
# lifecycle behavior, spawn-time launch flags, the busy-lib trust registration,
# and the bespoke composer/liveness detection omp's collapsed box shape needs
# on both the tmux and Herdr backends.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
NODE_BIN=$(command -v node) || fail "test needs node"

# --- detection precedence ----------------------------------------------------

test_omp_detection_precedence_over_claudecode() {
  local out
  out=$(OMPCODE=1 CLAUDECODE=1 FM_ROOT_OVERRIDE="$ROOT" "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 with CLAUDECODE=1 must detect omp, got '$out'"
  out=$(CLAUDECODE=1 FM_ROOT_OVERRIDE="$ROOT" "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE=1 alone (no OMPCODE) must still detect claude, got '$out'"
  out=$(OMPCODE=1 FM_ROOT_OVERRIDE="$ROOT" "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 alone must detect omp, got '$out'"
  pass "fm-harness.sh checks OMPCODE before CLAUDECODE, so omp never misidentifies as claude"
}

test_omp_detection_precedence_over_claudecode

# --- busy-lib trust registration --------------------------------------------

test_omp_busy_source_trusted() {
  local sources
  sources=$(fm_busy_sources_for_harness omp)
  case " $sources " in
    *' omp-ext '*) : ;;
    *) fail "omp must trust its own omp-ext semantic source, got '$sources'" ;;
  esac
  case " $sources " in
    *' fm-spawn '*) : ;;
    *) fail "omp must trust the firstmate-owned fm-spawn seed source, got '$sources'" ;;
  esac
  fm_busy_source_trusted omp omp-ext || fail "omp-ext must be trusted for harness=omp"
  fm_busy_source_trusted omp pi-ext && fail "omp must never trust pi's semantic source"
  fm_busy_source_trusted pi omp-ext && fail "pi must never trust omp's semantic source"
  pass "omp trusts only its own semantic source, never another adapter's"
}

test_omp_busy_source_trusted

# --- fm-spawn: launch flags and extension wiring ----------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *omp*) printf '%s\n' "$literal" >> "${FM_FAKE_LAUNCH_LOG:?}" ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_omp_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_omp_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra spawn args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" omp --mode no-mistakes --yolo off "$@" 2>&1
}

test_omp_spawn_launch_flags_and_extension() {
  local rec case_dir home proj wt fakebin id out ext launch
  id=omp-flags-1
  rec=$(make_omp_spawn_case flags "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --model sonnet --effort high)
  expect_code 0 $? "omp spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "omp spawn did not report success"
  assert_grep "harness=omp" "$home/state/$id.meta" "meta did not record harness=omp"

  launch="$home/launch.log"
  assert_present "$launch" "omp launch command was never sent to the pane"
  assert_grep '--auto-approve' "$launch" "omp launch is missing --auto-approve"
  assert_grep "--model 'sonnet'" "$launch" "omp launch is missing --model"
  assert_grep "--thinking 'high'" "$launch" "omp launch is missing --thinking"
  assert_grep '-e ' "$launch" "ship omp launch is missing the -e busy-state extension flag"

  ext="$home/state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task busy-state extension"
  assert_grep 'agent_start' "$ext" "omp extension does not subscribe to agent_start"
  assert_grep 'agent_end' "$ext" "omp extension does not subscribe to agent_end"
  assert_grep 'willContinue' "$ext" "omp extension does not check willContinue"
  assert_grep 'setTimeout' "$ext" "omp extension does not defer its isIdle() reconfirmation"
  assert_grep 'turn_end' "$ext" "omp extension does not subscribe to turn_end"
  assert_no_grep 'agent_settled' "$ext" "omp extension must not reuse Pi's nonexistent agent_settled event"
  pass "omp ship spawn sends --auto-approve/--model/--thinking/-e and writes the busy-state extension"
}

test_omp_spawn_secondmate_launches_bare() {
  local rec case_dir home proj wt fakebin id out launch ext
  id=omp-secondmate-1
  rec=$(make_omp_spawn_case secondmate "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  mkdir -p "$wt/bin"
  : > "$wt/.fm-secondmate-home"
  printf '%s\n' "$id" > "$wt/.fm-secondmate-home"
  cp "$ROOT/AGENTS.md" "$wt/AGENTS.md" 2>/dev/null || printf 'agents\n' > "$wt/AGENTS.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$wt" omp --secondmate 2>&1)
  expect_code 0 $? "omp secondmate spawn should succeed: $out"
  launch="$home/launch.log"
  assert_present "$launch" "omp secondmate launch command was never sent to the pane"
  assert_grep '--auto-approve' "$launch" "omp secondmate launch is missing --auto-approve"
  assert_no_grep '-e ' "$launch" "omp secondmate must launch bare (no primary-role extension pair is built yet)"
  ext="$home/state/$id.omp-ext.ts"
  assert_absent "$ext" "a secondmate spawn must not arm the crewmate busy-state extension"
  pass "omp secondmate launches bare, with no busy-state extension armed"
}

test_omp_spawn_launch_flags_and_extension
test_omp_spawn_secondmate_launches_bare

# --- driving the real generated extension through a plain Node host --------
#
# Mirrors tests/fm-busy-adapter-wiring.test.sh's drive_pi_ext: load the actual
# generated .ts file (type-stripped by Node directly, same as the real omp
# runtime would resolve it) in a plain Node host, wire a fake ExtensionAPI,
# and fire real lifecycle handlers, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live omp binary.
drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const idle = process.env.MODE !== "end-not-idle";
const ctx = {
  isIdle: () => idle,
  setTimeout: (fn, ms) => setTimeout(fn, ms),
};
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "end-idle": await handlers["agent_end"]({}, ctx); break;
  case "end-not-idle": await handlers["agent_end"]({}, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ willContinue: true }, ctx); break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
// agent_end defers its idle write one event-loop tick via ctx.setTimeout;
// give every mode enough real wall-clock time for that deferred write (and
// the async fm-busy-event.sh execFile call inside it) to land before exit.
await new Promise((resolve) => setTimeout(resolve, 200));
EOF
}

classify_omp() {  # <id> <state-dir>
  fm_busy_classify tmux fake:w omp "$1" "$2"
}

test_omp_extension_semantic_lifecycle() {
  local rec case_dir home proj wt fakebin id out state ext
  id=omp-lifecycle-1
  rec=$(make_omp_spawn_case lifecycle "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$home/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"

  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_omp_ext "$ext" end-idle) || fail "agent_end (idle) drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "agent_end with a confirmed isIdle() must classify 'idle omp-ext', got '$out'"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext', got '$out'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "agent_end (willContinue) drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "agent_end carrying willContinue must never settle idle, got '$out'"

  out=$(drive_omp_ext "$ext" end-not-idle) || fail "agent_end (not yet idle) drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "agent_end whose deferred isIdle() reads false must stay busy, got '$out'"

  out=$(drive_omp_ext "$ext" end-idle) || fail "final agent_end drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "the final confirmed settle must classify idle, got '$out'"
  pass "omp extension reports agent_start busy, settles idle only via a deferred confirmed isIdle(), never on willContinue, and keeps turn_end a notification"
}

test_omp_extension_stale_incarnation_rejected() {
  local rec case_dir home proj wt fakebin id out state ext
  id=omp-stale-1
  rec=$(make_omp_spawn_case stale "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$home/state"
  ext="$state/$id.omp-ext.ts"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_omp_ext "$ext" end-idle) || fail "stale drive failed: $out"
  out=$(classify_omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  pass "omp extension events from a superseded incarnation are rejected as stale"
}

test_omp_extension_semantic_lifecycle
test_omp_extension_stale_incarnation_rejected

# --- tmux composer detection: omp's collapsed top/bottom-border box ---------
#
# omp's composer has no │ side-border content row in the common (unwrapped)
# case, so the generic multi-row box scanner never finds it; these pin the
# bespoke fm_tmux_omp_composer_find/fm_tmux_omp_composer_state path this task
# added, fed fixed pane fixtures through a fake tmux exactly like
# tests/fm-composer-ghost.test.sh does for every other adapter's shape.
make_fake_tmux_composer() {  # <dir> -> fakebin dir
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '0\n'; exit 0 ;;
  capture-pane) printf '%b' "${FM_FAKE_OMP_PANE:-}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# ANSI-C quoted constants (bash $'...' hex escapes), built once so no test
# body needs a variable-as-format-string printf (SC2059): omp's own box
# corners (╭ ╮ ╰ ╯), its "▶" prompt/run marker, and a plain content-row side
# border (│), concatenated directly into fixed pane fixtures below.
OMP_BOX_TL=$'\xe2\x95\xad'    # ╭
OMP_BOX_TR=$'\xe2\x95\xae'    # ╮
OMP_BOX_BL=$'\xe2\x95\xb0'    # ╰
OMP_BOX_BR=$'\xe2\x95\xaf'    # ╯
OMP_BOX_H=$'\xe2\x94\x80'     # ─
OMP_BOX_V=$'\xe2\x94\x82'     # │
OMP_MARKER=$'\xe2\x96\xb6'    # ▶
OMP_TOP_ROW="$OMP_BOX_TL$OMP_BOX_H$OMP_BOX_H $OMP_MARKER$OMP_BOX_H$OMP_BOX_H$OMP_BOX_H$OMP_BOX_TR"

test_omp_tmux_composer_empty() {
  local fb pane out
  fb=$(make_fake_tmux_composer "$TMP_ROOT/tmux-empty")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_BL$OMP_BOX_H                                                 $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" PATH="$fb:$PATH" fm_tmux_composer_state fakepane)
  [ "$out" = empty ] || fail "an all-blank omp composer must classify empty, got '$out'"
  pass "omp's collapsed idle composer classifies empty structurally"
}

test_omp_tmux_composer_pending() {
  local fb pane out
  fb=$(make_fake_tmux_composer "$TMP_ROOT/tmux-pending")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_BL$OMP_BOX_H hello unsent text                               $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" PATH="$fb:$PATH" fm_tmux_composer_state fakepane)
  [ "$out" = pending ] || fail "real typed text embedded in omp's bottom border must classify pending, got '$out'"
  pass "omp's bottom-border-embedded text classifies pending structurally"
}

test_omp_tmux_composer_wrapped_pending() {
  local fb pane out
  fb=$(make_fake_tmux_composer "$TMP_ROOT/tmux-wrapped")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_V first line of a wrapped message                $OMP_BOX_V"$'\n'"$OMP_BOX_BL$OMP_BOX_H second line overflow                            $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" PATH="$fb:$PATH" fm_tmux_composer_state fakepane)
  [ "$out" = pending ] || fail "a wrapped omp composer (top / │ / bottom) must classify pending, got '$out'"
  pass "omp's wrapped multi-row composer is still located and classified pending"
}

test_omp_tmux_composer_ignores_unrelated_box() {
  local fb pane plain out
  fb=$(make_fake_tmux_composer "$TMP_ROOT/tmux-unrelated")
  pane="$OMP_BOX_TL$OMP_BOX_H$OMP_BOX_H$OMP_BOX_H$OMP_BOX_TR"$'\n''$ echo hi'$'\n'"$OMP_BOX_BL$OMP_BOX_H$OMP_BOX_H$OMP_BOX_H$OMP_BOX_BR"$'\n'
  plain=$(printf '%s' "$pane" | fm_composer_strip_ansi)
  out=$(FM_FAKE_OMP_PANE="$pane" PATH="$fb:$PATH" fm_tmux_omp_composer_state "$pane" "$plain")
  [ "$out" = no-match ] || fail "a box with no omp prompt marker in its top row must never be mistaken for omp's composer, got '$out'"
  pass "a decorative box with no omp prompt marker is never mistaken for the composer"
}

test_omp_tmux_composer_empty
test_omp_tmux_composer_pending
test_omp_tmux_composer_wrapped_pending
test_omp_tmux_composer_ignores_unrelated_box

# --- Herdr composer detection: native identity + the same collapsed shape --

JQ_BIN=$(command -v jq) || fail "test needs jq"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

make_fake_herdr() {  # <dir> -> fakebin dir
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"server":{"running":true},"client":{"protocol":17}}\n'; exit 0 ;;
  "agent get") printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "${FM_FAKE_HERDR_AGENT:-omp}" "${FM_FAKE_HERDR_STATUS:-idle}"; exit 0 ;;
  "pane read") printf '%b' "${FM_FAKE_OMP_PANE:-}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  # jq must be real (used to parse status/agent JSON); put its real directory
  # first so it resolves ahead of anything else on the caller's PATH.
  printf '%s\n' "$JQ_BIN_DIR:$fb"
}
JQ_BIN_DIR=$(dirname "$JQ_BIN")

test_omp_herdr_composer_empty_with_native_identity() {
  local fb pane out
  fb=$(make_fake_herdr "$TMP_ROOT/herdr-empty")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_BL$OMP_BOX_H                                                 $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" FM_FAKE_HERDR_AGENT=omp FM_FAKE_HERDR_STATUS=idle \
    PATH="$fb:$PATH" fm_backend_herdr_composer_state 'fmtest:w1:p1')
  [ "$out" = empty ] || fail "an all-blank omp composer under Herdr must classify empty, got '$out'"
  pass "Herdr: omp's collapsed idle composer classifies empty with native identity confirmed"
}

test_omp_herdr_composer_pending_with_native_identity() {
  local fb pane out
  fb=$(make_fake_herdr "$TMP_ROOT/herdr-pending")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_BL$OMP_BOX_H hello unsent text                               $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" FM_FAKE_HERDR_AGENT=omp FM_FAKE_HERDR_STATUS=idle \
    PATH="$fb:$PATH" fm_backend_herdr_composer_state 'fmtest:w1:p1')
  [ "$out" = pending ] || fail "real typed text under Herdr must classify pending, got '$out'"
  pass "Herdr: omp's bottom-border-embedded text classifies pending"
}

test_omp_herdr_composer_refuses_without_native_identity() {
  local fb pane out
  fb=$(make_fake_herdr "$TMP_ROOT/herdr-refuse")
  pane="$OMP_TOP_ROW"$'\n'"$OMP_BOX_BL$OMP_BOX_H                                                 $OMP_BOX_H$OMP_BOX_BR"$'\n'
  out=$(FM_FAKE_OMP_PANE="$pane" FM_FAKE_HERDR_AGENT=claude FM_FAKE_HERDR_STATUS=idle \
    PATH="$fb:$PATH" fm_backend_herdr_composer_state 'fmtest:w1:p1')
  [ "$out" = unknown ] || fail "the omp composer shape must never authorize injection without the native omp identity, got '$out'"
  pass "Herdr: an omp-shaped box with a non-omp native identity never classifies empty/pending"
}

test_omp_herdr_composer_empty_with_native_identity
test_omp_herdr_composer_pending_with_native_identity
test_omp_herdr_composer_refuses_without_native_identity

# --- tmux liveness: the "bun" comm quirk ------------------------------------
#
# omp ships as a bun-run script; tmux's #{pane_current_command} reports "bun"
# for a running omp process, not "omp" (verified live, see
# docs/verification/runtime-backends.md). Bare "bun" is too generic to trust
# fleet-wide, so fm_backend_tmux_agent_state confirms it via the pane's live
# child process args before classifying alive.

# shellcheck disable=SC2034 # read by the sourced backends/tmux.sh itself
FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/tmux.sh"

make_fake_tmux_liveness() {  # <dir> <comm> <child-args> -> fakebin dir
  local dir=$1 comm=$2 args=$3 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-windows) printf 'testwin\n'; exit 0 ;;
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' "$comm"; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_pid*) printf '4242\n'; exit 0 ;; esac; done
    printf '\n'; exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *--ppid*4242*) printf '%s\n' "$args" ;;
esac
exit 0
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

test_omp_tmux_liveness_confirms_bun_omp_child() {
  local fb out
  fb=$(make_fake_tmux_liveness "$TMP_ROOT/liveness-omp" bun 'bun /home/user/.bun/bin/omp --auto-approve')
  out=$(PATH="$fb:$PATH" fm_backend_tmux_agent_state "sess:testwin")
  [ "$out" = alive ] || fail "a bun comm whose child args end in /omp must classify alive, got '$out'"
  pass "tmux liveness confirms a bun-reported omp process via its child args"
}

test_omp_tmux_liveness_refuses_unconfirmed_bun() {
  local fb out
  fb=$(make_fake_tmux_liveness "$TMP_ROOT/liveness-other" bun 'bun /home/user/some/other/tool.js')
  out=$(PATH="$fb:$PATH" fm_backend_tmux_agent_state "sess:testwin")
  [ "$out" = ambiguous ] || fail "a bun comm whose child args do NOT name omp must never be guessed alive, got '$out'"
  pass "tmux liveness never guesses alive for an unconfirmed bun process"
}

test_omp_tmux_liveness_confirms_bun_omp_child
test_omp_tmux_liveness_refuses_unconfirmed_bun
