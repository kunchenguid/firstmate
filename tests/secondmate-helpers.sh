#!/usr/bin/env bash
# tests/secondmate-helpers.sh - shared fixtures and mocks for the secondmate
# suites (fm-secondmate-lifecycle-e2e and fm-secondmate-safety).
#
# These mocks encode secondmate-lifecycle behavior (fake tmux that logs window
# ops, fake treehouse that leases/returns homes, fake no-mistakes that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux (window ops are logged to FM_FAKE_TMUX_LOG, list-windows returns
# FM_FAKE_TMUX_WINDOW, capture-pane echoes FM_FAKE_TMUX_CAPTURE) plus a fake
# treehouse (durable lease of FM_FAKE_TREEHOUSE_HOME, recording the lease holder
# to FM_FAKE_TREEHOUSE_LEASE_FILE; `return` removes the target and lease unless
# FM_FAKE_TREEHOUSE_RETURN_FAIL is set). Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && printf '%s\n' "$arg" >> "$FM_FAKE_TMUX_LOG.killed"
      prev=$arg
    done
    exit 0
    ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    fi
    exit 0
    ;;
  display-message)
    target=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
    done
    if [ -n "$target" ] && [ -f "$FM_FAKE_TMUX_LOG.killed" ] && grep -qxF "$target" "$FM_FAKE_TMUX_LOG.killed"; then
      exit 1
    fi
    # Answer #{pane_current_command} separately. A present pane whose foreground
    # command is unreadable classifies as `unknown` (fm_backend_tmux_agent_alive),
    # and callers must never act on unknown - so every caller that has to prove an
    # endpoint's state would retain instead, for an unprovable read rather than
    # for anything the fixture meant to say. This pane is idle, matching the
    # "idle prompt" capture below; FM_FAKE_TMUX_COMMAND overrides it.
    case " $* " in
      *' #{pane_current_command} '*)
        printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-bash}"
        exit 0
        ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-panes)
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    if [ -n "${FM_EXPECT_CHECKOUT_LOCK:-}" ]; then
      [ -e "$FM_EXPECT_CHECKOUT_LOCK" ] || [ -L "$FM_EXPECT_CHECKOUT_LOCK" ] || exit 91
      lock_pid=$(cat "$FM_EXPECT_CHECKOUT_LOCK/pid" 2>/dev/null || true)
      kill -0 "$lock_pid" 2>/dev/null || exit 92
      [ -z "${FM_EXPECT_CHECKOUT_LOCK_MARKER:-}" ] || touch "$FM_EXPECT_CHECKOUT_LOCK_MARKER"
    fi
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    case "$target" in
      .|/dev/fd/*) target=$(cd "$target" && pwd -P) || exit 18 ;;
    esac
    printf 'treehouse return --force %s\n' "$target" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal firstmate home (AGENTS.md + bin/).
mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

# A firstmate home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  # A firstmate source's own tracked .gitignore is what makes a seeded secondmate
  # home clean: the home marker and every operational directory the home creates
  # are ignored by construction. Without it, teardown correctly reports the marker
  # as unlanded changes and refuses - a fixture artifact, not a product refusal.
  # Mirrors the operational subset of this repo's real .gitignore.
  printf '%s\n' 'projects/' 'state/' 'data/' '.no-mistakes/' '.fm-secondmate-home' \
    > "$home/.gitignore"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md .gitignore bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# make_secondmate_home_and_source <prefix> <id> <project>: the standard two-sided
# secondmate teardown fixture, minus the home's project clone (see
# clone_registered_secondmate_project, kept separate so a case can reshape
# <subhome>/projects first). Under $TMP_ROOT/<prefix>-* it builds:
#   -fmroot   a firstmate source git root, carrying the .gitignore that keeps a
#             seeded home clean
#   -home     the parent firstmate home: state/, data/, the registered source clone
#             projects/<project> with an origin, the <id> meta and the registry route
#   -subhome  the secondmate home: a plain CLONE of the source (not a registered
#             worktree of it, so teardown takes the non-Treehouse removal path),
#             marked for <id>, with the full operational directory set
# bin/fm-teardown.sh proves all of that - exact repository root, resolvable identity,
# operational directories, and a projects/ matching the registration - before it
# touches anything, so a bare mkdir'd home is refused long before whatever a case
# actually means to pin. Sets SECONDMATE_FIXTURE_FMROOT/_HOME/_SUBHOME/_PROJECT and
# exports nothing; pass SECONDMATE_FIXTURE_FMROOT as FM_ROOT_OVERRIDE when running
# teardown.
make_secondmate_home_and_source() {
  local prefix=$1 id=$2 project=$3
  SECONDMATE_FIXTURE_FMROOT="$TMP_ROOT/$prefix-fmroot"
  SECONDMATE_FIXTURE_HOME="$TMP_ROOT/$prefix-home"
  SECONDMATE_FIXTURE_SUBHOME="$TMP_ROOT/$prefix-subhome"
  SECONDMATE_FIXTURE_PROJECT=$project
  rm -rf "$SECONDMATE_FIXTURE_FMROOT" "$SECONDMATE_FIXTURE_HOME" "$SECONDMATE_FIXTURE_SUBHOME"
  make_firstmate_git_root "$SECONDMATE_FIXTURE_FMROOT"
  git clone --quiet "$SECONDMATE_FIXTURE_FMROOT" "$SECONDMATE_FIXTURE_SUBHOME"
  mkdir -p "$SECONDMATE_FIXTURE_HOME/state" "$SECONDMATE_FIXTURE_HOME/data" \
    "$TMP_ROOT/remotes" "$SECONDMATE_FIXTURE_SUBHOME/data" \
    "$SECONDMATE_FIXTURE_SUBHOME/state" "$SECONDMATE_FIXTURE_SUBHOME/config" \
    "$SECONDMATE_FIXTURE_SUBHOME/projects"
  fm_git_init_commit "$SECONDMATE_FIXTURE_HOME/projects/$project"
  fm_git_add_origin "$SECONDMATE_FIXTURE_HOME/projects/$project" \
    "$TMP_ROOT/remotes/$prefix-$project.git"
  printf '%s\n' "$id" > "$SECONDMATE_FIXTURE_SUBHOME/.fm-secondmate-home"
  cat > "$SECONDMATE_FIXTURE_HOME/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$SECONDMATE_FIXTURE_SUBHOME
project=$SECONDMATE_FIXTURE_SUBHOME
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$SECONDMATE_FIXTURE_SUBHOME
projects=$project
EOF
  printf -- '- %s - design domain (home: %s; scope: design domain; projects: %s; added 2026-06-22)\n' \
    "$id" "$SECONDMATE_FIXTURE_SUBHOME" "$project" \
    > "$SECONDMATE_FIXTURE_HOME/data/secondmates.md"
}

# clone_registered_secondmate_project: clone the parent home's registered source of
# SECONDMATE_FIXTURE_PROJECT into the secondmate home, so both sides of the
# registration exist and share an origin.
clone_registered_secondmate_project() {
  git clone --quiet \
    "$(git -C "$SECONDMATE_FIXTURE_HOME/projects/$SECONDMATE_FIXTURE_PROJECT" remote get-url origin)" \
    "$SECONDMATE_FIXTURE_SUBHOME/projects/$SECONDMATE_FIXTURE_PROJECT"
}

# write_treehouse_pool_lease <worktree> <holder>: record <worktree> as durably
# leased to <holder> in its Treehouse pool state. bin/fm-teardown.sh resolves that
# state authoritatively by walking up two levels from the worktree (worktree ->
# slot -> pool) and reading <pool>/treehouse-state.json, so a worktree that is not
# laid out inside a pool has no provable ownership and teardown refuses before it
# does anything else.
write_treehouse_pool_lease() {
  local worktree=$1 holder=$2 slot pool
  slot=$(cd "$(dirname "$worktree")" && pwd -P) || return 1
  pool=$(cd "$(dirname "$slot")" && pwd -P) || return 1
  python3 - "$pool/treehouse-state.json" "$(cd "$worktree" && pwd -P)" "$holder" <<'PY'
import json
import sys

state, path, holder = sys.argv[1:]
with open(state, "w", encoding="utf-8") as stream:
    json.dump(
        {"worktrees": [{"name": "1", "path": path, "leased": True, "lease_holder": holder}]},
        stream,
    )
PY
}

# make_leased_secondmate_home <pool> <fmroot> <id>: a Treehouse-slot-shaped
# secondmate home. bin/fm-teardown.sh takes the Treehouse-return path for any home
# that is a registered worktree of the firstmate source, and that path then proves
# ownership from the AUTHORITATIVE pool state - <pool>/treehouse-state.json, found
# by walking up two levels from the worktree (worktree -> slot -> pool). A worktree
# parked directly under the test temp root has no such pool, so teardown refuses
# with "cannot resolve authoritative Treehouse state" before it ever tries the
# return. Lay the home out as <pool>/1/home and record its durable lease, held by
# the task id (which is what teardown passes as the expected holder).
# The home starts with no project clones; add them the way the suites already do,
# by cloning the parent's registered source origin into <home>/projects/<name>.
# Prints the home path.
make_leased_secondmate_home() {
  local pool=$1 fmroot=$2 id=$3 home
  home="$pool/1/home"
  mkdir -p "$pool/1"
  git -C "$fmroot" worktree add --quiet --detach "$home" HEAD
  # A seeded home always carries the full operational directory set; teardown
  # proves each one before removal, and proves that the clones under projects/
  # exactly match the home's registered project list.
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  write_treehouse_pool_lease "$home" "$id"
  printf '%s\n' "$home"
}

# Scaffold a filled secondmate charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

# Make a directory look like a genuine seeded secondmate home (for handoff tests).
seed_secondmate_home_marker() {
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
