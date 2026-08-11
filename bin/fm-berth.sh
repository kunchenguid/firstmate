#!/usr/bin/env bash
# fm-berth.sh - opt-in per-project session berths, so one home can run several
# concurrent firstmate sessions (one per project) without them colliding.
#
# WHY THIS IS THIN
# A firstmate home already routes every piece of volatile per-session state
# through FM_STATE_OVERRIDE: the session lock, the durable wake queue, task
# metadata, status logs, watcher internals and turn-end records. 42 scripts in
# bin/ honour it and none hardcode "$FM_HOME/state" around it. The only thing
# missing was something that hands each project its own slice. That is all this
# script does; it adds no daemon, no registry and no policy layer.
#
# WHAT A BERTH IS
# A berth is one project's private state slice inside this home:
#   $FM_HOME/state/berths/<slug>/
# A session that exports the berth's environment gets its own .lock, its own
# wake queue and its own task records, so two sessions working two projects
# never contend. Isolation is enforced by the SAME session lock as always - it
# simply now lives per berth instead of per home, so the existing
# "another live firstmate session holds the lock" refusal still protects a
# single berth from two sessions.
#
# OPT-IN, DEFAULT UNCHANGED
# Berths are inert unless $FM_HOME/config/berths exists (gitignored, local).
# Without that flag every command here refuses and a home behaves exactly as it
# does today: one session, one state dir. Nothing in AGENTS.md changes, and a
# home that never opts in cannot be affected by this script.
#
# SCOPE OF v1 (deliberate)
# Only state/ is per berth. data/ (backlog, captain preferences, learnings) stays
# shared home-wide, because that knowledge is the home's, not a project's. Two
# berths therefore still share one backlog file; keep each project's items in
# their own section. Isolating data/ per berth is a separate decision because it
# would split captain preferences and learnings too.
#
# Usage:
#   fm-berth.sh env <project>     print the export lines to eval for that berth
#   fm-berth.sh list              every berth with its lock holder and liveness
#   fm-berth.sh status <project>  one berth's lock state; exit 1 if held elsewhere
#   fm-berth.sh path <project>    print the berth state dir
#   fm-berth.sh --help
#
# Typical use, from the home root:
#   eval "$(bin/fm-berth.sh env acme-web)" && bin/fm-session-start.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
BERTH_FLAG="$FM_HOME/config/berths"
BERTH_ROOT="$FM_HOME/state/berths"

# shellcheck source=bin/fm-session-lock-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "fm-berth: $*" >&2; exit 1; }

# Opt-in gate. Absent flag = berths disabled = this home is untouched.
assert_enabled() {
  [ -f "$BERTH_FLAG" ] || die "berths are not enabled in this home; create $BERTH_FLAG to opt in (see --help)"
}

# A slug becomes a directory name, so it is validated rather than trusted.
# Refuses traversal, absolute paths, leading dots and anything exotic.
assert_slug() { # slug
  local s=${1:-}
  [ -n "$s" ] || die "project name required"
  case "$s" in
    */*|*\\*) die "project name must not contain a path separator: $s" ;;
    .*)       die "project name must not start with a dot: $s" ;;
    *[!A-Za-z0-9._-]*) die "project name may use only letters, digits, dot, underscore and dash: $s" ;;
  esac
  [ "${#s}" -le 64 ] || die "project name is longer than 64 characters: $s"
  return 0
}

berth_dir() { # slug
  printf '%s/%s\n' "$BERTH_ROOT" "$1"
}

# Report a berth's lock holder using the SAME identity contract as fm-lock.sh,
# so "held" here means exactly what it means at session start.
berth_lock_state() { # dir -> "free" | "held <pid>" | "stale <pid>" | "unreadable"
  local lock="$1/.lock" pid
  [ -f "$lock" ] || { printf 'free\n'; return 0; }
  pid=$(cat "$lock" 2>/dev/null) || { printf 'unreadable\n'; return 0; }
  [ -n "$pid" ] || { printf 'unreadable\n'; return 0; }
  if fm_harness_pid_alive "$pid"; then printf 'held %s\n' "$pid"; else printf 'stale %s\n' "$pid"; fi
}

cmd=${1:---help}
case "$cmd" in
  --help|-h|help) usage; exit 0 ;;
esac
shift || true

case "$cmd" in
  env)
    assert_enabled
    slug=${1:-}; assert_slug "$slug"
    dir=$(berth_dir "$slug")
    mkdir -p "$dir" 2>/dev/null || die "cannot create berth state dir: $dir"
    state=$(berth_lock_state "$dir")
    case "$state" in
      "held "*) die "berth '$slug' is already held by live session pid ${state#held } - use a different project, or close that session" ;;
    esac
    # Only STATE is redirected; data/, config/ and projects/ stay home-wide.
    printf 'export FM_STATE_OVERRIDE=%s\n' "$dir"
    printf 'export FM_BERTH=%s\n' "$slug"
    ;;
  path)
    assert_enabled
    slug=${1:-}; assert_slug "$slug"
    berth_dir "$slug"
    ;;
  status)
    assert_enabled
    slug=${1:-}; assert_slug "$slug"
    dir=$(berth_dir "$slug")
    if [ ! -d "$dir" ]; then echo "berth '$slug': absent (never used)"; exit 0; fi
    state=$(berth_lock_state "$dir")
    echo "berth '$slug': $state"
    case "$state" in "held "*) exit 1 ;; esac
    ;;
  list)
    assert_enabled
    if [ ! -d "$BERTH_ROOT" ]; then echo "(no berths yet)"; exit 0; fi
    found=0
    printf '%-24s %s\n' BERTH LOCK
    for d in "$BERTH_ROOT"/*/; do
      [ -d "$d" ] || continue
      found=1
      printf '%-24s %s\n' "$(basename "$d")" "$(berth_lock_state "${d%/}")"
    done
    [ "$found" -eq 1 ] || echo "(no berths yet)"
    ;;
  *)
    die "unknown command: $cmd (try --help)"
    ;;
esac
