#!/usr/bin/env bash
# tests/fm-secondmate-lifecycle-e2e.test.sh - the happy-path secondmate operator
# flow, end to end, against one shared world:
#
#   seed -> spawn -> routed send -> backlog handoff -> recovery respawn -> teardown
#
# Each phase asserts the durable contracts the consolidation audit lists, so the
# many former positive unit tests (registry scope/charter/clone/mode, spawn meta,
# bare-window send, recovery respawn, teardown of an empty home, backlog handoff)
# collapse into one lifecycle. The path-boundary safety invariants and the
# lease-specific paths live in fm-secondmate-safety.test.sh.
#
# Coverage anchored here (must not regress):
#   - registry line records scope (from a filled charter brief) and project list
#   - charter is copied into the subhome
#   - remote-backed projects are cloned with their origin URL preserved
#   - a no-mistakes project is initialized (init + doctor) in the NEW subhome clone
#     and the parent project clone is never mutated (no write through a project)
#   - spawn meta records kind=secondmate, home=, and the project list; launch runs
#     in the subhome with the persistent charter and cleared operational overrides
#   - a bare `fm-<id>` send targets the window recorded in THIS home's meta
#   - backlog items move verbatim into the subhome and leave the main backlog
#   - recovery respawns from the durable registry + persistent home
#   - docker-sandbox secondmate direct placement records exact home+bridge mounts,
#     bridge metadata, canonical watcher sync, exact relaunch reuse, and teardown
#     release while retaining unrelated sandboxes and secondmate-home safeguards
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-lifecycle)
export FM_BACKEND=tmux

HOME_DIR="$TMP_ROOT/main home"
SUB="$TMP_ROOT/design-home"
SANDBOX_SUB="$TMP_ROOT/sandbox-home"
SUB_ABS=
SANDBOX_SUB_ABS=
SANDBOX_BRIDGE=
FAKEBIN=
LOG="$TMP_ROOT/tmux.log"
PANE="$TMP_ROOT/pane.txt"
SBX_STATE="$TMP_ROOT/sbx-state"
SBX_LOG="$TMP_ROOT/sbx.log"
SANDBOX_TMUX_GONE="$TMP_ROOT/sandbox-tmux-gone"
ALPHA_ORIGIN=
BETA_ORIGIN=

make_fake_sbx() {
  cat > "$FAKEBIN/sbx" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_SBX_STATE:?}
log=${FM_FAKE_SBX_LOG:?}
{
  printf 'sbx'
  printf ' %s' "$@"
  printf '\n'
} >> "$log"
case "${1:-}" in
  ls)
    [ -f "$state" ] && cat "$state"
    ;;
  create)
    shift
    name=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) shift; name=${1:-} ;;
      esac
      shift
    done
    [ -n "$name" ] || exit 2
    printf '%s\n' "$name" >> "$state"
    ;;
  exec)
    shift
    [ "${2:-}" = pwd ] && printf '/workspace\n'
    ;;
  stop)
    ;;
  rm)
    target=
    for arg in "$@"; do
      case "$arg" in
        --force) ;;
        *) target=$arg ;;
      esac
    done
    [ -n "$target" ] || exit 2
    [ -f "$state" ] || exit 0
    awk -v target="$target" '$0 != target' "$state" > "$state.tmp"
    mv -f "$state.tmp" "$state"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKEBIN/sbx"
  : > "$SBX_STATE"
  : > "$SBX_LOG"
}

install_relaunch_tmux() {
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  list-windows)
    [ ! -e "$FM_FAKE_TMUX_GONE" ] || exit 0
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
    ;;
  display-message)
    case "$*" in
      *'#{pane_current_command}'*) printf 'bash\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_TMUX_PATH" ;;
      *'#{pane_tty}'*) printf '\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
  has-session|new-session|new-window|send-keys)
    ;;
  kill-window)
    : > "$FM_FAKE_TMUX_GONE"
    ;;
  capture-pane)
    cat "$FM_FAKE_TMUX_CAPTURE"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/tmux"
}

phase_sandbox_seed() {
  local out
  FM_SECONDMATE_SCOPE='sandbox onboarding from brief' \
    scaffold_secondmate_charter "$HOME_DIR" sandbox 'sandbox onboarding charter' alpha \
    || fail "sandbox charter scaffold failed"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-home-seed.sh" sandbox "$SANDBOX_SUB" alpha) \
    || fail "sandbox home seed failed"
  SANDBOX_SUB_ABS=$(cd "$SANDBOX_SUB" && pwd -P)
  assert_contains "$out" "home=$SANDBOX_SUB_ABS" "sandbox seed did not report the subhome"
  assert_present "$SANDBOX_SUB/.fm-secondmate-home" "sandbox seed did not mark the subhome"
  assert_present "$SANDBOX_SUB/data/charter.md" "sandbox seed did not copy the charter"
  pass "sandbox seed: persistent secondmate home fixture is available"
}

phase_sandbox_spawn() {
  SANDBOX_BRIDGE="$(cd "$HOME_DIR/state" && pwd -P)/sandbox-bridge/sandbox"
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-sandbox" \
    FM_FAKE_SBX_STATE="$SBX_STATE" FM_FAKE_SBX_LOG="$SBX_LOG" \
    "$ROOT/bin/fm-spawn.sh" sandbox "$SANDBOX_SUB" codex --secondmate \
    --placement docker-sandbox >/dev/null \
    || fail "docker-sandbox secondmate spawn failed"

  local meta="$HOME_DIR/state/sandbox.meta"
  assert_grep 'kind=secondmate' "$meta" "sandbox spawn did not record kind=secondmate"
  assert_grep "home=$SANDBOX_SUB_ABS" "$meta" "sandbox spawn did not record the exact secondmate home"
  assert_grep 'placement=docker-sandbox' "$meta" "sandbox spawn did not record Docker Sandbox placement"
  assert_grep 'placement_mode=direct' "$meta" "sandbox spawn did not record direct placement mode"
  assert_grep 'placement_handle=docker-sandbox:sandbox:fm-sandbox' "$meta" "sandbox spawn did not record the opaque sandbox handle"
  assert_grep "placement_bridge=$SANDBOX_BRIDGE" "$meta" "sandbox spawn did not record the bridge path"
  assert_grep "sbx create --name fm-sandbox codex $SANDBOX_SUB_ABS $SANDBOX_BRIDGE" \
    "$SBX_LOG" "sandbox create did not mount the exact secondmate home and bridge"
  local sandbox_launch
  printf -v sandbox_launch "'%s' '%s' '%s' '%s' '%s' '%s'" \
    sbx exec -it -w "$SANDBOX_SUB_ABS" fm-sandbox
  assert_grep "$sandbox_launch" "$LOG" \
    "sandbox launch did not execute through the recorded sandbox"
  assert_grep "$SANDBOX_BRIDGE/runtime-brief.md" "$LOG" \
    "sandbox launch did not use the bridge runtime brief"
  assert_grep 'sandbox onboarding charter' "$SANDBOX_BRIDGE/runtime-brief.md" \
    "sandbox bridge runtime brief did not carry the persistent charter"
  assert_grep "task_id=sandbox" "$SANDBOX_BRIDGE/binding" "sandbox bridge metadata lost the task identity"
  assert_grep "worktree=$SANDBOX_SUB_ABS" "$SANDBOX_BRIDGE/binding" "sandbox bridge metadata lost the home binding"
  assert_grep "bridge=$SANDBOX_BRIDGE" "$SANDBOX_BRIDGE/binding" "sandbox bridge metadata lost its canonical path"
  assert_no_grep 'treehouse get' "$LOG" "sandbox secondmate spawn used the host treehouse path"
  pass "sandbox spawn: exact home+bridge mounts, bridge metadata, and persistent charter launch"
}

phase_sandbox_sync() {
  printf 'status from sandbox\n' >> "$SANDBOX_BRIDGE/status"
  touch "$SANDBOX_BRIDGE/turn-ended"
  (
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT"
    export FM_HOME FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
    # shellcheck source=bin/fm-watch.sh disable=SC1091
    . "$ROOT/bin/fm-watch.sh"
    watch_sync_sandbox_bridges
  ) || fail "sandbox bridge sync failed"
  assert_grep 'status from sandbox' "$HOME_DIR/state/sandbox.status" \
    "sandbox bridge status did not propagate to canonical state"
  assert_present "$HOME_DIR/state/sandbox.turn-ended" \
    "sandbox bridge turn-end did not propagate to canonical state"
  assert_absent "$SANDBOX_BRIDGE/turn-ended" "sandbox bridge turn-end marker was not consumed once"
  pass "sandbox sync: watcher bridge sync publishes canonical status and one-shot turn-end"
}

phase_sandbox_relaunch() {
  local creates_before creates_after
  creates_before=$(grep -c '^sbx create ' "$SBX_LOG" || true)
  install_relaunch_tmux
  rm -f "$SANDBOX_TMUX_GONE"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-sandbox" FM_FAKE_TMUX_PATH="$SANDBOX_SUB_ABS" \
    FM_FAKE_TMUX_GONE="$SANDBOX_TMUX_GONE" \
    FM_FAKE_SBX_STATE="$SBX_STATE" FM_FAKE_SBX_LOG="$SBX_LOG" \
    "$ROOT/bin/fm-spawn.sh" sandbox --relaunch >/dev/null \
    || fail "docker-sandbox exact relaunch failed"
  creates_after=$(grep -c '^sbx create ' "$SBX_LOG" || true)
  [ "$creates_after" = "$creates_before" ] \
    || fail "exact relaunch created a new Docker Sandbox"
  assert_grep 'placement_handle=docker-sandbox:sandbox:fm-sandbox' "$HOME_DIR/state/sandbox.meta" \
    "exact relaunch changed the recorded sandbox handle"
  assert_grep "placement_bridge=$SANDBOX_BRIDGE" "$HOME_DIR/state/sandbox.meta" \
    "exact relaunch changed the recorded bridge"
  pass "sandbox relaunch: exact recorded sandbox and bridge are reused without creation"
}

phase_sandbox_teardown() {
  printf 'fm-unrelated\n' >> "$SBX_STATE"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    FM_FAKE_TMUX_WINDOW="firstmate:fm-sandbox" FM_FAKE_TMUX_PATH="$SANDBOX_SUB_ABS" \
    FM_FAKE_TMUX_GONE="$SANDBOX_TMUX_GONE" \
    FM_FAKE_SBX_STATE="$SBX_STATE" FM_FAKE_SBX_LOG="$SBX_LOG" \
    "$ROOT/bin/fm-teardown.sh" sandbox >/dev/null 2>&1 \
    || fail "docker-sandbox secondmate teardown failed"
  assert_present "$SANDBOX_TMUX_GONE" "teardown did not observe the endpoint closure"
  assert_absent "$SANDBOX_SUB" "sandbox teardown did not remove the secondmate home"
  assert_absent "$HOME_DIR/state/sandbox.meta" "sandbox teardown did not clear task metadata"
  assert_absent "$SANDBOX_BRIDGE" "sandbox teardown did not remove the verified bridge"
  assert_no_grep 'sbx stop fm-unrelated' "$SBX_LOG" "teardown stopped the unrelated sandbox"
  assert_no_grep 'sbx rm fm-unrelated' "$SBX_LOG" "teardown targeted the unrelated sandbox"
  assert_grep 'fm-unrelated' "$SBX_STATE" "teardown released a sandbox other than the recorded placement"
  pass "sandbox teardown: release is exact, bridge is removed after endpoint closure, home safeguards remain"
}

# --- shared world + seed ----------------------------------------------------
setup_world() {
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
  fm_git_init_commit "$HOME_DIR/projects/alpha"
  fm_git_init_commit "$HOME_DIR/projects/beta"
  fm_git_init_commit "$HOME_DIR/projects/gamma"
  fm_git_add_origin "$HOME_DIR/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
  fm_git_add_origin "$HOME_DIR/projects/beta" "$TMP_ROOT/remotes/beta.git"
  fm_git_add_origin "$HOME_DIR/projects/gamma" "$TMP_ROOT/remotes/gamma.git"
  cat > "$HOME_DIR/data/projects.md" <<EOF
- alpha [direct-PR +yolo] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
- gamma - gamma project (added 2026-06-22)
EOF
  ALPHA_ORIGIN=$(git -C "$HOME_DIR/projects/alpha" remote get-url origin)
  BETA_ORIGIN=$(git -C "$HOME_DIR/projects/beta" remote get-url origin)

  # One combined fakebin: tmux + treehouse (spawn/send/teardown) and no-mistakes
  # (gamma initialization during seed).
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  make_fake_no_mistakes "$TMP_ROOT/fake" >/dev/null
  make_fake_sbx

  # A filled charter brief whose routing scope differs from the charter summary,
  # so the registry must read the scope from the brief, not invent a generic one.
  FM_SECONDMATE_SCOPE='customer onboarding from brief' \
    scaffold_secondmate_charter "$HOME_DIR" design 'customer onboarding charter' alpha beta gamma \
    || fail "filled secondmate charter scaffold failed"
}

phase_seed() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-home-seed.sh" design "$SUB" alpha beta gamma) \
    || fail "seed failed"
  SUB_ABS=$(cd "$SUB" && pwd -P)

  assert_contains "$out" "home=$SUB_ABS" "seed did not report the subhome"
  assert_present "$SUB/.fm-secondmate-home" "seed did not mark the subhome"
  assert_present "$SUB/data/charter.md" "seed did not copy the charter into the subhome"
  assert_grep 'customer onboarding charter' "$SUB/data/charter.md" "charter body was not copied verbatim"

  # Projects cloned; remote-backed origins preserved.
  assert_present "$SUB/projects/alpha/.git" "alpha was not cloned"
  assert_present "$SUB/projects/beta/.git" "beta was not cloned"
  assert_present "$SUB/projects/gamma/.git" "gamma was not cloned"
  [ "$(git -C "$SUB/projects/alpha" remote get-url origin)" = "$ALPHA_ORIGIN" ] \
    || fail "alpha clone did not preserve its origin URL"
  [ "$(git -C "$SUB/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
    || fail "direct-PR beta clone did not preserve its origin URL"

  # no-mistakes init runs in the NEW clone, never the parent project.
  assert_present "$SUB/projects/gamma/.no-mistakes-init" "no-mistakes project was not initialized in the subhome"
  assert_present "$SUB/projects/gamma/.no-mistakes-doctor" "no-mistakes project was not doctored in the subhome"
  assert_absent "$HOME_DIR/projects/gamma/.no-mistakes-init" "seed wrote no-mistakes state through the parent project"

  # Registry line: scope from the filled brief, project list, no legacy owns field.
  assert_grep '- design - customer onboarding charter' "$HOME_DIR/data/secondmates.md" "registry summary not from the charter"
  assert_grep 'scope: customer onboarding from brief' "$HOME_DIR/data/secondmates.md" "registry scope not from the filled brief"
  assert_grep 'projects: alpha, beta, gamma' "$HOME_DIR/data/secondmates.md" "registry did not record the project list"
  assert_no_grep 'owns:' "$HOME_DIR/data/secondmates.md" "registry used the legacy owns field"

  # Delivery modes preserved in the subhome registry; validation passes.
  [ "$(FM_HOME="$SUB" "$ROOT/bin/fm-project-mode.sh" alpha)" = "direct-PR on" ] \
    || fail "alpha delivery mode not preserved in the subhome"
  [ "$(FM_HOME="$SUB" "$ROOT/bin/fm-project-mode.sh" beta)" = "direct-PR off" ] \
    || fail "beta delivery mode not preserved in the subhome"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed after seed"

  pass "seed: registry scope+projects, charter copied, clones+origins, no-mistakes init in subhome only"
}

phase_spawn() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" design "$SUB" codex --secondmate >/dev/null \
    || fail "secondmate spawn failed"

  local meta="$HOME_DIR/state/design.meta"
  assert_grep 'kind=secondmate' "$meta" "spawn meta did not record kind=secondmate"
  assert_grep "home=$SUB_ABS" "$meta" "spawn meta did not record the subhome"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "spawn meta did not record the project list"
  # Launch ran in the subhome, with the persistent charter and cleared overrides,
  # and never ran a project-style treehouse get.
  assert_grep "FM_HOME='$SUB_ABS'" "$LOG" "secondmate launch did not set FM_HOME to the subhome"
  assert_grep 'FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE=' "$LOG" "launch did not clear operational overrides"
  assert_grep 'FM_CONFIG_OVERRIDE=' "$LOG" "launch did not clear the config override"
  assert_grep "$SUB_ABS/data/charter.md" "$LOG" "launch did not use the persistent charter"
  assert_no_grep 'notify=' "$LOG" "secondmate codex launch included the parent turn-end notify hook"
  assert_no_grep 'turn-ended' "$LOG" "secondmate codex launch referenced a parent turn-ended signal"
  assert_no_grep 'treehouse get' "$LOG" "secondmate spawn ran a project treehouse get"
  pass "spawn: launches in the subhome with persistent charter, records routing meta"
}

phase_send() {
  : > "$LOG"
  printf '❯\n' > "$PANE"
  # The meta window (firstmate:fm-design) must win over a foreign same-named
  # window returned by list-windows.
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_WINDOW="other-session:fm-design" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-send.sh" fm-design 'route this work' >/dev/null 2>&1 \
    || fail "fm-send failed for a bare firstmate window with home metadata"
  # design is a kind=secondmate target, so the request is prefixed with the
  # from-firstmate marker (bin/fm-marker-lib.sh): the send targets the meta window
  # AND carries the marker label, and the original payload still follows it.
  assert_grep 'send-keys -t firstmate:fm-design -l [fm-from-firstmate]' "$LOG" "send did not use the window recorded in this home's meta, or did not mark the secondmate request"
  assert_grep 'route this work' "$LOG" "the original request text did not survive the marker"
  assert_no_grep 'send-keys -t other-session:fm-design' "$LOG" "send targeted a foreign same-named window"
  pass "send: a bare fm-<id> secondmate routes to the meta window with the from-firstmate marker"
}

phase_handoff() {
  # The move is delegated to `tasks-axi mv`; skip cleanly when it is absent (the
  # downstream recovery and teardown phases do not depend on this phase).
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip: tasks-axi not found (backlog handoff delegates to it)"
    return 0
  fi
  cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] feat-x - add feature x (repo: alpha)
- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF
  local out before
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-backlog-handoff.sh" design feat-x feat-y) \
    || fail "handoff failed for in-scope items"
  assert_contains "$out" "handed off 2 item(s) to design" "handoff did not report the moved items"

  assert_no_grep 'feat-x' "$HOME_DIR/data/backlog.md" "feat-x was not removed from the main backlog"
  assert_no_grep 'feat-y' "$HOME_DIR/data/backlog.md" "feat-y was not removed from the main backlog"
  assert_grep 'bug-z' "$HOME_DIR/data/backlog.md" "out-of-scope bug-z was wrongly removed"
  assert_grep 'live-task' "$HOME_DIR/data/backlog.md" "in-flight item was wrongly removed"

  assert_grep '- [ ] feat-x - add feature x (repo: alpha)' "$SUB/data/backlog.md" "feat-x did not arrive verbatim"
  assert_grep '- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits' "$SUB/data/backlog.md" "feat-y line not preserved verbatim"
  awk '/^## Queued/{q=1;next} /^## /{q=0} q && /feat-x/{found=1} END{exit found?0:1}' "$SUB/data/backlog.md" \
    || fail "feat-x did not land under the Queued section"

  # Idempotent: a second handoff neither errors nor duplicates, and leaves main alone.
  before=$(cat "$HOME_DIR/data/backlog.md")
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-backlog-handoff.sh" design feat-x feat-y >/dev/null 2>&1 \
    || fail "idempotent re-run failed"
  [ "$(grep -cF -- '- [ ] feat-x - add feature x (repo: alpha)' "$SUB/data/backlog.md")" -eq 1 ] \
    || fail "idempotent re-run duplicated feat-x in the subhome backlog"
  [ "$before" = "$(cat "$HOME_DIR/data/backlog.md")" ] || fail "idempotent re-run mutated the main backlog"
  pass "handoff: in-scope items move verbatim, out-of-scope stays, idempotent"
}

phase_recovery() {
  # Simulate a restart: drop the live meta, then respawn from the registry +
  # persistent home (no explicit home argument).
  rm -f "$HOME_DIR/state/design.meta"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" design "echo relaunch" --secondmate >/dev/null 2>&1 \
    || fail "recovery respawn failed"
  local meta="$HOME_DIR/state/design.meta"
  assert_grep "home=$SUB_ABS" "$meta" "respawn did not preserve the persistent home from the registry"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "respawn did not preserve the project list from the registry"
  assert_grep 'window=firstmate:fm-design' "$meta" "respawn did not reconstruct the direct-report window"
  pass "recovery: respawns from the durable registry and persistent home"
}

phase_teardown() {
  local teardown_out
  : > "$LOG"
  teardown_out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-teardown.sh" design 2>&1) \
    || fail "teardown failed for the empty secondmate home"
  printf '%s\n' "$teardown_out" | grep -F 'Backlog:' >/dev/null \
    && fail "secondmate teardown emitted a main-backlog completion reminder"
  assert_absent "$SUB" "teardown did not remove the retired secondmate home"
  assert_absent "$HOME_DIR/state/design.meta" "teardown did not clear the parent meta"
  assert_no_grep '- design ' "$HOME_DIR/data/secondmates.md" "teardown did not remove the registry route"
  # The parent's source projects are untouched (no write through a parent home).
  assert_present "$HOME_DIR/projects/alpha" "teardown disturbed a parent project"
  pass "teardown: removes the home, then clears meta and the registry route"
}
setup_world
phase_seed
phase_spawn
phase_send
phase_handoff
phase_recovery
phase_teardown
phase_sandbox_seed
phase_sandbox_spawn
phase_sandbox_sync
phase_sandbox_relaunch
phase_sandbox_teardown
