#!/usr/bin/env bash
# Keep every checkout that can seed Firstmate or Treehouse work current without
# touching unlanded work.
#
# The single-checkout mutation remains owned by fm-fleet-sync.sh.
# This script owns the broader covered-set discovery and the independent cadence:
#
#   - projects/* under the active FM_HOME;
#   - backing checkouts discovered from Treehouse's state under ~/.treehouse;
#   - explicit `path <checkout>` entries in config/checkout-refresh;
#   - top-level clones under $HOME, plus explicit `scan <directory>` roots, whose
#     origin URL matches one of the checkouts above.
#
# Matching-origin discovery is what covers a second clone such as ~/relvino
# without hard-coding a captain-specific path.
# Treehouse pool entries resolve back to their backing checkout because Treehouse
# fetches origin and resets an acquired detached worktree from that shared Git
# metadata immediately before handoff.
#
# `run-once` probes each tracked upstream default-branch tip with `git ls-remote`.
# A changed tip triggers an immediate safe refresh, and fm-fleet-sync.sh repeats
# that live proof while owning the shared per-checkout mutation lock.
# FM_CHECKOUT_REFRESH_BACKSTOP seconds without a refresh triggers one anyway, so
# missed signals and lost state remain bounded.
# The home-scoped per-user LaunchAgent installed by `install` runs this probe
# every FM_CHECKOUT_REFRESH_INTERVAL seconds while that Firstmate home is idle.
# Its default state is under checkout-refresh/homes/<FM_HOME hash>, while
# checkout-refresh/locks remains shared so every fm-fleet-sync.sh caller
# serializes mutation of the same clone.
# Bounded probes and acquisitions terminate and reap their complete process tree.
# fm-fleet-sync.sh owns the equivalent per-checkout refresh bound for every caller.
# FM_TREEHOUSE_ACQUIRE_TIMEOUT applies the same process-tree ownership to the
# synchronous durable lease acquired before a task endpoint is created.
#
# Cadence and spawn-preflight refreshes delegate to fm-fleet-sync.sh with pruning
# disabled, while the explicit session-start mode preserves gone-branch pruning.
# Dirty, diverged, non-default, and otherwise unsafe checkouts remain untouched
# and are recorded as durable alerts.
# Every probe also inventories non-ignored untracked files in both the covered seed
# checkouts and the Treehouse pool worktrees under repository skill directories
# (`.agents/skills`, `.claude/skills`, `.codex/skills`, and `skills`).
# Unreadable or malformed Treehouse state invalidates discovery and suppresses
# the healthy heartbeat until every pool state file can be inspected.
# A new or changed inventory is surfaced immediately and persisted as a separate
# hygiene alert, even when no upstream change or backstop refresh is due.
# Forced/operator-visible runs repeat unresolved hygiene alerts.
# Nothing is forced, stashed, reset, or discarded.
#
# Config format (config/checkout-refresh), one directive per line:
#
#   path /absolute/or/~/relative/checkout
#   scan /directory/whose/immediate/children/are/clones
#
# Blank lines and lines beginning with # are ignored.
# Paths may contain spaces.
# Relative paths and unknown directives are rejected visibly.
#
# Usage:
#   fm-checkout-refresh.sh discover
#   fm-checkout-refresh.sh run-once [--force] [--verbose] [--session]
#   fm-checkout-refresh.sh preflight <checkout>
#   fm-checkout-refresh.sh pool-preflight <expected-source>
#   fm-checkout-refresh.sh acquire-worktree <expected-source> <lease-holder>
#   fm-checkout-refresh.sh verify-worktree <worktree> <expected-source>
#   fm-checkout-refresh.sh verify-returnable <worktree> <expected-source> <expected-tip>
#   fm-checkout-refresh.sh ensure
#   fm-checkout-refresh.sh install
#
# `install` and `ensure` dispatch through the scheduler adapter seam.
# macOS launchd is the implemented primary-fleet adapter.
# Linux currently has no cron/systemd adapter and reports that limitation
# explicitly instead of pretending a background backstop exists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
if FM_HOME_CANONICAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
  :
else
  FM_HOME_CANONICAL=$FM_HOME
fi
FM_HOME_KEY=$(printf '%s' "$FM_HOME_CANONICAL" | shasum -a 256 | awk '{print substr($1,1,16)}')
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="${FM_CHECKOUT_REFRESH_CONFIG:-$CONFIG/checkout-refresh}"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"
TREEHOUSE_ROOT_CANONICAL=
if [ -d "$TREEHOUSE_ROOT" ] \
  && TREEHOUSE_ROOT_CANONICAL=$(cd "$TREEHOUSE_ROOT" 2>/dev/null && pwd -P); then
  TREEHOUSE_ROOT=$TREEHOUSE_ROOT_CANONICAL
else
  case "$TREEHOUSE_ROOT" in
    /*) ;;
    *) TREEHOUSE_ROOT="$(pwd -P)/$TREEHOUSE_ROOT" ;;
  esac
fi
STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
if [ -n "${FM_CHECKOUT_REFRESH_STATE_ROOT:-}" ]; then
  STATE_ROOT=$FM_CHECKOUT_REFRESH_STATE_ROOT
  LOCK_ROOT="${FM_CHECKOUT_REFRESH_LOCK_ROOT:-$STATE_ROOT/locks}"
else
  STATE_ROOT="$STATE_BASE/homes/$FM_HOME_KEY"
  LOCK_ROOT="${FM_CHECKOUT_REFRESH_LOCK_ROOT:-$STATE_BASE/locks}"
fi
INTERVAL=${FM_CHECKOUT_REFRESH_INTERVAL:-60}
BACKSTOP=${FM_CHECKOUT_REFRESH_BACKSTOP:-900}
PROBE_TIMEOUT=${FM_CHECKOUT_REFRESH_PROBE_TIMEOUT:-15}
SYNC_TIMEOUT=${FM_CHECKOUT_REFRESH_SYNC_TIMEOUT:-60}
ACQUIRE_TIMEOUT=${FM_TREEHOUSE_ACQUIRE_TIMEOUT:-60}
PLATFORM=${FM_CHECKOUT_REFRESH_PLATFORM:-$(uname)}
LABEL_BASE=com.firstmate.checkout-refresh
LABEL=${FM_CHECKOUT_REFRESH_LABEL:-$LABEL_BASE.$FM_HOME_KEY}
LEGACY_LABEL=${FM_CHECKOUT_REFRESH_LEGACY_LABEL:-$LABEL_BASE}
LAUNCH_AGENTS_DIR=${FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LAUNCHCTL=${FM_CHECKOUT_REFRESH_LAUNCHCTL:-launchctl}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"

case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$BACKSTOP" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_BACKSTOP must be a positive integer" >&2; exit 2 ;; esac
case "$PROBE_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_PROBE_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
case "$SYNC_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_SYNC_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
case "$ACQUIRE_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_TREEHOUSE_ACQUIRE_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac

usage() {
  echo "usage: fm-checkout-refresh.sh discover|run-once [--force] [--verbose] [--session]|preflight <checkout>|pool-preflight <expected-source>|acquire-worktree <expected-source> <lease-holder>|verify-worktree <worktree> <expected-source>|verify-returnable <worktree> <expected-source> <expected-tip>|ensure|install" >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

exact_git_root() {
  local candidate=$1 canonical top canonical_top
  canonical=$(canonical_dir "$candidate") || return 1
  top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_top=$(canonical_dir "$top") || return 1
  [ "$canonical" = "$canonical_top" ] || return 1
  printf '%s\n' "$canonical"
}

expand_config_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    "\$HOME") printf '%s\n' "$HOME" ;;
    "\$HOME/"*) printf '%s/%s\n' "$HOME" "${1#\$HOME/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) echo "checkout-refresh: skipped: config path '$1' must be absolute, ~/..., or \$HOME/..." >&2; return 1 ;;
  esac
}

config_values() {
  local wanted=$1 line directive value
  [ -f "$CONFIG_FILE" ] || return 0
  [ ! -L "$CONFIG_FILE" ] || {
    echo "checkout-refresh: skipped: unsafe symlink config $CONFIG_FILE" >&2
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in ""|\#*) continue ;; esac
    directive=${line%%[[:space:]]*}
    if [ "$directive" = "$line" ]; then
      echo "checkout-refresh: skipped: malformed config directive '$line'" >&2
      continue
    fi
    value=${line#"$directive"}
    value=$(printf '%s\n' "$value" | sed 's/^[[:space:]]*//')
    case "$directive" in
      path|scan)
        [ "$directive" = "$wanted" ] || continue
        expand_config_path "$value" || true
        ;;
      *) echo "checkout-refresh: skipped: unknown config directive '$directive'" >&2 ;;
    esac
  done < "$CONFIG_FILE"
}

treehouse_worktree_paths() {
  if [ ! -e "$TREEHOUSE_ROOT" ] && [ ! -L "$TREEHOUSE_ROOT" ]; then
    return 0
  fi
  [ -d "$TREEHOUSE_ROOT" ] || {
    echo "checkout-refresh: skipped: incomplete Treehouse coverage because the root is not a directory: $TREEHOUSE_ROOT" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "checkout-refresh: skipped: incomplete Treehouse coverage because python3 is unavailable" >&2
    return 1
  }
  python3 - "$TREEHOUSE_ROOT" <<'PY'
import json
import os
import stat
import sys

failed = False


def directory_entries(path, label):
    metadata = os.stat(path)
    if not stat.S_ISDIR(metadata.st_mode):
        raise NotADirectoryError(path)
    permissions = stat.S_IMODE(metadata.st_mode)
    if not permissions & 0o444 or not permissions & 0o111:
        raise PermissionError(f"{label} is unreadable")
    with os.scandir(path) as entries:
        return sorted(entries, key=lambda entry: entry.name)


root = sys.argv[1]
try:
    pool_entries = directory_entries(root, "Treehouse root")
except OSError as error:
    failed = True
    pool_entries = []
    print(
        f"checkout-refresh: skipped: incomplete Treehouse coverage at {root}: {error}",
        file=sys.stderr,
    )

state_paths = []
for pool_entry in pool_entries:
    try:
        if not pool_entry.is_dir(follow_symlinks=True):
            continue
        entries = directory_entries(pool_entry.path, "Treehouse pool")
        if any(entry.name == "treehouse-state.json" for entry in entries):
            state_paths.append(os.path.join(pool_entry.path, "treehouse-state.json"))
    except OSError as error:
        failed = True
        print(
            f"checkout-refresh: skipped: incomplete Treehouse coverage at {pool_entry.path}: {error}",
            file=sys.stderr,
        )

for state_path in state_paths:
    try:
        with open(state_path, encoding="utf-8") as stream:
            state = json.load(stream)
        if not isinstance(state, dict):
            raise TypeError("root must be an object")
        if "worktrees" not in state:
            raise TypeError("worktrees is required")
        worktrees = state["worktrees"]
        if not isinstance(worktrees, list):
            raise TypeError("worktrees must be an array")
        for entry in worktrees:
            if not isinstance(entry, dict):
                raise TypeError("worktree entry must be an object")
            path = entry.get("path")
            if not isinstance(path, str) or not path:
                raise TypeError("worktree path must be a non-empty string")
            print(path)
    except (OSError, ValueError, TypeError) as error:
        failed = True
        print(
            f"checkout-refresh: skipped: incomplete Treehouse coverage at {state_path}: {error}",
            file=sys.stderr,
        )
if failed:
    raise SystemExit(1)
PY
}

active_project_paths() {
  if [ ! -e "$PROJECTS" ] && [ ! -L "$PROJECTS" ]; then
    return 0
  fi
  [ -d "$PROJECTS" ] || {
    echo "checkout-refresh: skipped: incomplete active-home project coverage because the projects root is not a directory: $PROJECTS" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "checkout-refresh: skipped: incomplete active-home project coverage because python3 is unavailable" >&2
    return 1
  }
  python3 - "$PROJECTS" <<'PY'
import os
import stat
import sys

failed = False


def directory_entries(path, label):
    metadata = os.stat(path)
    if not stat.S_ISDIR(metadata.st_mode):
        raise NotADirectoryError(path)
    permissions = stat.S_IMODE(metadata.st_mode)
    if not permissions & 0o444 or not permissions & 0o111:
        raise PermissionError(f"{label} is unreadable")
    with os.scandir(path) as entries:
        return sorted(entries, key=lambda entry: entry.name)


root = sys.argv[1]
try:
    project_entries = directory_entries(root, "active-home projects root")
except OSError as error:
    failed = True
    project_entries = []
    print(
        f"checkout-refresh: skipped: incomplete active-home project coverage at {root}: {error}",
        file=sys.stderr,
    )

for project_entry in project_entries:
    try:
        if not project_entry.is_dir(follow_symlinks=True):
            continue
        directory_entries(project_entry.path, "active-home project")
        print(project_entry.path)
    except OSError as error:
        failed = True
        print(
            f"checkout-refresh: skipped: incomplete active-home project coverage at {project_entry.path}: {error}",
            file=sys.stderr,
        )

if failed:
    raise SystemExit(1)
PY
}

backing_checkout() {
  local worktree=$1 main
  [ -d "$worktree" ] || return 1
  main=$(git -C "$worktree" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | sed -n '1p')
  [ -n "$main" ] || return 1
  canonical_dir "$main"
}

origin_url() {
  git -C "$1" remote get-url origin 2>/dev/null
}

discover() {
  local tmp seeds origins scans treehouse_paths project_paths path project worktree main root candidate url failed=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-checkout-refresh-discover.XXXXXX") || return 1
  seeds="$tmp/seeds"
  origins="$tmp/origins"
  scans="$tmp/scans"
  treehouse_paths="$tmp/treehouse-worktrees"
  project_paths="$tmp/active-projects"
  : > "$seeds"
  : > "$origins"
  : > "$scans"
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! active_project_paths > "$project_paths"; then
    rm -rf "$tmp"
    return 1
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if main=$(exact_git_root "$project"); then
      printf '%s\n' "$main" >> "$seeds"
    else
      echo "checkout-refresh: skipped: active-home project is not an exact inspectable Git repository root: $project" >&2
      failed=1
    fi
  done < "$project_paths"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if main=$(canonical_dir "$path" 2>/dev/null); then
      printf '%s\n' "$main" >> "$seeds"
    else
      echo "checkout-refresh: skipped: configured checkout is not a directory: $path" >&2
    fi
  done < <(config_values path)

  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    if main=$(backing_checkout "$worktree" 2>/dev/null); then
      printf '%s\n' "$main" >> "$seeds"
    else
      echo "checkout-refresh: skipped: Treehouse worktree is not inspectable: $worktree" >&2
      failed=1
    fi
  done < "$treehouse_paths"
  if [ "$failed" -ne 0 ]; then
    rm -rf "$tmp"
    return 1
  fi

  sort -u "$seeds" -o "$seeds"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    url=$(origin_url "$path" || true)
    [ -n "$url" ] && printf '%s\n' "$url" >> "$origins"
  done < "$seeds"
  sort -u "$origins" -o "$origins"

  canonical_dir "$HOME" >> "$scans" 2>/dev/null || true
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if main=$(canonical_dir "$root" 2>/dev/null); then
      printf '%s\n' "$main" >> "$scans"
    else
      echo "checkout-refresh: skipped: configured scan root is not a directory: $root" >&2
    fi
  done < <(config_values scan)
  sort -u "$scans" -o "$scans"

  if [ -s "$origins" ]; then
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      for candidate in "$root"/*; do
        [ -d "$candidate" ] || continue
        git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
        url=$(origin_url "$candidate" || true)
        if [ -z "$url" ] || ! grep -Fxq -- "$url" "$origins"; then
          continue
        fi
        canonical_dir "$candidate" >> "$seeds" 2>/dev/null || true
      done
    done < "$scans"
  fi

  sort -u "$seeds"
  rm -rf "$tmp"
}

acquire_worktree() {
  local expected_source=$1 lease_holder=$2 status=0
  [ -d "$expected_source" ] \
    || { echo "error: Treehouse acquisition source is not a directory: $expected_source" >&2; return 1; }
  (
    local expected_common checkout_lock
    ensure_lock_roots || exit 1
    expected_common=$(git_common_dir "$expected_source") || {
      echo "error: cannot resolve Treehouse acquisition lock identity for $expected_source" >&2
      exit 1
    }
    checkout_lock="$LOCK_ROOT/$(checkout_key "$expected_common").lock"
    if ! fm_lock_try_acquire "$checkout_lock"; then
      echo "error: Treehouse acquisition already running for $expected_source (pid ${FM_LOCK_HELD_PID:-unknown})" >&2
      exit 1
    fi
    trap 'fm_lock_release "$checkout_lock"' EXIT
    cd "$expected_source" || exit 1
    fm_run_bounded "$ACQUIRE_TIMEOUT" treehouse get --lease --lease-holder "$lease_holder"
  ) || status=$?
  case "$status" in
    0) return 0 ;;
    124)
      echo "error: Treehouse worktree acquisition timed out after ${ACQUIRE_TIMEOUT}s and terminated its process tree" >&2
      ;;
    *)
      echo "error: Treehouse worktree acquisition failed for $lease_holder (exit $status)" >&2
      ;;
  esac
  return "$status"
}

PROBE_BRANCH=
PROBE_TIP=
probe_upstream() {
  local checkout=$1 out line ref
  PROBE_BRANCH=
  PROBE_TIP=
  out=$(fm_run_bounded "$PROBE_TIMEOUT" git -C "$checkout" ls-remote --symref origin HEAD 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      "ref: refs/heads/"*$'\t'"HEAD")
        ref=${line#ref: refs/heads/}
        PROBE_BRANCH=${ref%$'\t'HEAD}
        ;;
      *$'\t'"HEAD")
        PROBE_TIP=${line%$'\t'HEAD}
        ;;
    esac
  done <<EOF
$out
EOF
  [ -n "$PROBE_BRANCH" ] && [ -n "$PROBE_TIP" ]
}

checkout_key() {
  local identity
  identity=$(canonical_dir "$1" 2>/dev/null) || identity=$1
  printf '%s' "$identity" | shasum -a 256 | awk '{print substr($1,1,24)}'
}

read_epoch() {
  local value
  value=$(sed -n '1p' "$1" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) echo 0 ;; *) echo "$value" ;; esac
}

atomic_write() {
  local destination=$1
  shift
  local tmp
  tmp=$(mktemp "$STATE_ROOT/.checkout-refresh-write.XXXXXX") || return 1
  printf '%s\n' "$@" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$destination"
}

ensure_state_root() {
  mkdir -p "$STATE_ROOT" || return 1
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    || { echo "error: unsafe checkout-refresh state directory: $STATE_ROOT" >&2; return 1; }
}

CHECKOUT_LOCK_HELPERS_LOADED=0
ensure_lock_roots() {
  local FM_STATE_OVERRIDE="$STATE_ROOT" STATE='' FM_WAKE_LIB_DIR='' FM_WAKE_DEFAULT_ROOT=''
  local FM_WAKE_QUEUE='' FM_WAKE_QUEUE_LOCK='' FM_ROOT="$FM_ROOT" FM_HOME="$FM_HOME"
  ensure_state_root || return 1
  mkdir -p "$LOCK_ROOT" || return 1
  [ -d "$LOCK_ROOT" ] && [ ! -L "$LOCK_ROOT" ] \
    || { echo "error: unsafe checkout-refresh lock directory: $LOCK_ROOT" >&2; return 1; }
  if [ "$CHECKOUT_LOCK_HELPERS_LOADED" -eq 0 ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
    CHECKOUT_LOCK_HELPERS_LOADED=1
  fi
}

skill_draft_inventory() {
  local checkout=$1
  (
    set -o pipefail
    git -C "$checkout" ls-files --others --exclude-standard -- \
      .agents/skills .claude/skills .codex/skills skills 2>/dev/null \
      | LC_ALL=C sort
  )
}

# Surface a changed untracked-skill inventory on the ordinary 60-second probe,
# not only when an upstream tip changes or the 15-minute refresh is due.
# The inventory is intentionally path-only: it detects accumulation without
# reading, copying, stashing, or otherwise touching a draft's content.
surface_skill_drafts() {
  local checkout=$1 key=$2 repeat=${3:-0}
  local inventory alert prior signature count examples message
  HYGIENE_FOUND=0
  inventory=$(mktemp "$STATE_ROOT/.hygiene-inventory.XXXXXX") || return 1
  alert="$STATE_ROOT/$key.hygiene-alert"
  if ! skill_draft_inventory "$checkout" > "$inventory"; then
    rm -f "$inventory"
    echo "$checkout: HYGIENE: inventory failed - preserving the prior alert" >&2
    return 1
  fi
  if [ ! -s "$inventory" ]; then
    rm -f "$inventory" "$alert"
    return 0
  fi

  signature=$(shasum -a 256 "$inventory" | awk '{print $1}')
  count=$(awk 'END { print NR + 0 }' "$inventory")
  HYGIENE_FOUND=1
  prior=$(sed -n '2p' "$alert" 2>/dev/null || true)
  examples=$(awk 'NR <= 3 { if (shown) printf ", "; printf "%s", $0; shown = 1 } END { if (NR > 3) printf ", ..." }' "$inventory")
  message="$checkout: HYGIENE: $count untracked skill-draft files under repository skill directories - reconcile before an upstream collision"
  atomic_write "$alert" "$checkout" "$signature" "$count" "$(date +%s)" "$examples"
  rm -f "$inventory"
  if [ "$repeat" -eq 1 ] || [ "$signature" != "$prior" ]; then
    printf '%s (%s)\n' "$message" "$examples"
  fi
}

prepare_hygiene_discovery() {
  local seed_file=$1 hygiene_file=$2 treehouse_paths worktree canonical failed=0
  cp "$seed_file" "$hygiene_file" || return 1
  treehouse_paths=$(mktemp "$STATE_ROOT/.treehouse-worktrees.XXXXXX") || return 1
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    rm -f "$treehouse_paths"
    return 1
  fi
  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    if canonical=$(canonical_dir "$worktree" 2>/dev/null); then
      printf '%s\n' "$canonical" >> "$hygiene_file"
    else
      echo "checkout-refresh: skipped: Treehouse worktree is not inspectable: $worktree" >&2
      failed=1
    fi
  done < "$treehouse_paths"
  rm -f "$treehouse_paths"
  [ "$failed" -eq 0 ] || return 1
  sort -u "$hygiene_file" -o "$hygiene_file"
}

clear_stale_hygiene_alerts() {
  local hygiene_file=$1 alert checkout
  for alert in "$STATE_ROOT"/*.hygiene-alert; do
    [ -f "$alert" ] || continue
    checkout=$(sed -n '1p' "$alert" 2>/dev/null || true)
    if [ -z "$checkout" ] || ! grep -Fxq -- "$checkout" "$hygiene_file"; then
      rm -f "$alert"
    fi
  done
}

sync_checkout() {
  local checkout=$1 output_file=$2 prune=${3:-0}
  local status
  if (
    export FM_FLEET_PRUNE="$prune"
    export FM_CHECKOUT_REFRESH_SYNC_TIMEOUT="$SYNC_TIMEOUT"
    "$SCRIPT_DIR/fm-fleet-sync.sh" "$checkout"
  ) > "$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    printf '%s: skipped: refresh failed with exit %s\n' "$checkout" "$status" >> "$output_file"
  fi
}

record_alert() {
  local alert=$1 checkout=$2 output=$3
  atomic_write "$alert" "$checkout" "$(date +%s)" "$(first_line "$output")"
}

run_once() {
  local force=0 verbose=0 session=0 prune=0 arg lock discovery hygiene checkout key tip_file last_file alert_file
  local prior_tip now last due probe_ok output_file output line hygiene_failed=0 status=0
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --verbose) verbose=1 ;;
      --session) session=1 ;;
      *) usage; return 2 ;;
    esac
  done
  [ "$session" -eq 0 ] || prune=1

  ensure_lock_roots || return 1
  lock="$STATE_ROOT/.run-lock"
  if ! fm_lock_try_acquire "$lock"; then
    printf 'checkout-refresh: skipped: refresh already running (pid %s)\n' "${FM_LOCK_HELD_PID:-unknown}"
    return 0
  fi
  trap 'fm_lock_release "$STATE_ROOT/.run-lock"' EXIT
  discovery=$(mktemp "$STATE_ROOT/.discover.XXXXXX") || return 1
  hygiene=$(mktemp "$STATE_ROOT/.hygiene-discover.XXXXXX") || { rm -f "$discovery"; return 1; }
  if ! discover > "$discovery"; then
    rm -f "$discovery" "$hygiene"
    return 1
  fi
  prepare_hygiene_discovery "$discovery" "$hygiene" || {
    rm -f "$discovery" "$hygiene"
    return 1
  }
  now=$(date +%s)

  while IFS= read -r checkout; do
    [ -n "$checkout" ] || continue
    git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    key=$(checkout_key "$checkout")
    if [ "$force" -eq 1 ] || [ "$verbose" -eq 1 ]; then
      surface_skill_drafts "$checkout" "$key" 1 || hygiene_failed=1
    else
      surface_skill_drafts "$checkout" "$key" 0 || hygiene_failed=1
    fi
  done < "$hygiene"
  clear_stale_hygiene_alerts "$hygiene"

  while IFS= read -r checkout; do
    [ -n "$checkout" ] || continue
    git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    git -C "$checkout" remote get-url origin >/dev/null 2>&1 || continue
    key=$(checkout_key "$checkout")
    tip_file="$STATE_ROOT/$key.tip"
    last_file="$STATE_ROOT/$key.last"
    alert_file="$STATE_ROOT/$key.alert"
    last=$(read_epoch "$last_file")
    due=0
    [ "$force" -eq 0 ] || due=1
    [ "$((now - last))" -lt "$BACKSTOP" ] || due=1
    probe_ok=0
    if probe_upstream "$checkout"; then
      probe_ok=1
      prior_tip=$(sed -n '1,2p' "$tip_file" 2>/dev/null || true)
      [ "$prior_tip" = "$PROBE_BRANCH"$'\n'"$PROBE_TIP" ] || due=1
    fi
    [ "$due" -eq 1 ] || continue

    output_file=$(mktemp "$STATE_ROOT/.sync.XXXXXX") || continue
    if [ "$probe_ok" -eq 1 ]; then
      sync_checkout "$checkout" "$output_file" "$prune"
    else
      printf '%s: skipped: cannot probe live upstream default branch\n' "$checkout" > "$output_file"
    fi
    output=$(cat "$output_file")
    rm -f "$output_file"
    atomic_write "$last_file" "$now"
    if [ "$probe_ok" -eq 1 ]; then
      atomic_write "$tip_file" "$PROBE_BRANCH" "$PROBE_TIP"
    fi

    case "$output" in
      *': STUCK:'*|*': skipped:'*)
        record_alert "$alert_file" "$checkout" "$output"
        printf '%s\n' "$output"
        ;;
      *)
        rm -f "$alert_file"
        if [ "$verbose" -eq 1 ]; then
          printf '%s\n' "$output"
        else
          while IFS= read -r line; do
            case "$line" in *': synced '*|*': recovered:'*) printf '%s\n' "$line" ;; esac
          done <<EOF
$output
EOF
        fi
        ;;
    esac
  done < "$discovery"

  rm -f "$discovery" "$hygiene"
  if [ "$hygiene_failed" -eq 0 ]; then
    atomic_write "$STATE_ROOT/heartbeat" "$now" "$SCRIPT_DIR/fm-checkout-refresh.sh" || status=1
  else
    status=1
  fi
  trap - EXIT
  fm_lock_release "$lock"
  return "$status"
}

preflight() {
  local checkout=$1 output key output_file hygiene_found=0
  [ -d "$checkout" ] || { echo "error: checkout-refresh preflight target is not a directory: $checkout" >&2; return 1; }
  ensure_lock_roots || return 1
  key=$(checkout_key "$checkout")
  surface_skill_drafts "$checkout" "$key" 1 || return 1
  hygiene_found=$HYGIENE_FOUND
  output_file=$(mktemp "$STATE_ROOT/.preflight.XXXXXX") || return 1
  if git -C "$checkout" remote get-url origin >/dev/null 2>&1; then
    if probe_upstream "$checkout"; then
      sync_checkout "$checkout" "$output_file" 0
    else
      printf '%s: skipped: cannot probe live upstream default branch\n' "$checkout" > "$output_file"
    fi
  else
    sync_checkout "$checkout" "$output_file" 0
  fi
  output=$(cat "$output_file")
  rm -f "$output_file"
  printf '%s\n' "$output"
  [ "$hygiene_found" -eq 0 ] || return 1
  case "$output" in *': STUCK:'*|*': skipped: fetch failed'*|*': skipped: refresh '*) return 1 ;; esac
  case "$output" in *': skipped: cannot probe live upstream default branch'*) return 1 ;; esac
  return 0
}

git_common_dir() {
  local checkout=$1 common
  common=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) canonical_dir "$common" ;;
    *) canonical_dir "$checkout/$common" ;;
  esac
}

pool_preflight() {
  local expected_source=$1 expected_common treehouse_paths worktree canonical common dirty example failed=0
  [ -d "$expected_source" ] \
    || { echo "error: expected Treehouse source is not a directory: $expected_source" >&2; return 1; }
  expected_common=$(git_common_dir "$expected_source") || {
    echo "error: cannot resolve expected Treehouse repository identity for $expected_source" >&2
    return 1
  }
  treehouse_paths=$(mktemp "${TMPDIR:-/tmp}/fm-checkout-refresh-pool.XXXXXX") || return 1
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    rm -f "$treehouse_paths"
    return 1
  fi
  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    canonical=$(canonical_dir "$worktree" 2>/dev/null) || {
      echo "checkout-refresh: skipped: Treehouse worktree is not inspectable: $worktree" >&2
      failed=1
      continue
    }
    common=$(git_common_dir "$canonical") || {
      echo "checkout-refresh: skipped: Treehouse repository identity is not inspectable: $canonical" >&2
      failed=1
      continue
    }
    [ "$common" = "$expected_common" ] || continue
    dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$canonical" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
      echo "checkout-refresh: skipped: Treehouse worktree cleanliness is not inspectable: $canonical" >&2
      failed=1
      continue
    }
    [ -n "$dirty" ] || continue
    example=$(first_line "$dirty")
    echo "$canonical: skipped: dirty Treehouse pool worktree remains unavailable for acquisition ($example)" >&2
  done < "$treehouse_paths"
  rm -f "$treehouse_paths"
  [ "$failed" -eq 0 ]
}

local_default_branch() {
  local checkout=$1 branch
  for branch in main master; do
    if git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

verify_worktree_safety() {
  local worktree=$1 expected_source=$2 dirty dirty_example worktree_common source_common
  local worktree_origin source_origin branch
  [ -d "$worktree" ] || { echo "error: worktree freshness target is not a directory: $worktree" >&2; return 1; }
  [ -d "$expected_source" ] || { echo "error: expected worktree source is not a directory: $expected_source" >&2; return 1; }
  if ! dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    echo "error: acquired worktree safety cannot be inspected at $worktree; retain it for manual recovery" >&2
    return 3
  fi
  if [ -n "$dirty" ]; then
    dirty_example=$(first_line "$dirty")
    echo "error: acquired worktree is dirty at $worktree; retain it for manual recovery without reset, clean, stash, or forced return ($dirty_example)" >&2
    return 3
  fi
  worktree_common=$(git_common_dir "$worktree") || {
    echo "error: cannot resolve acquired worktree repository identity for $worktree" >&2
    return 1
  }
  source_common=$(git_common_dir "$expected_source") || {
    echo "error: cannot resolve expected repository identity for $expected_source" >&2
    return 1
  }
  if [ "$worktree_common" != "$source_common" ]; then
    echo "error: acquired worktree repository mismatch: $worktree does not belong to $expected_source" >&2
    return 1
  fi
  worktree_origin=$(git -C "$worktree" remote get-url origin 2>/dev/null || true)
  source_origin=$(git -C "$expected_source" remote get-url origin 2>/dev/null || true)
  if [ "$worktree_origin" != "$source_origin" ]; then
    echo "error: acquired worktree origin mismatch: $worktree does not match $expected_source" >&2
    return 1
  fi
  if branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    echo "error: acquired worktree is attached to branch $branch at $worktree; retain it for manual recovery" >&2
    return 3
  fi
  return 0
}

verify_worktree() {
  local worktree=$1 expected_source=$2 source_origin default tip head expected
  verify_worktree_safety "$worktree" "$expected_source" || return $?
  source_origin=$(git -C "$expected_source" remote get-url origin 2>/dev/null || true)
  if [ -n "$source_origin" ]; then
    probe_upstream "$expected_source" || {
      echo "error: cannot verify the upstream default-branch tip for $expected_source" >&2
      return 1
    }
    tip=$PROBE_TIP
    expected="origin/$PROBE_BRANCH"
  else
    default=$(local_default_branch "$expected_source") || {
      echo "error: cannot determine the local default branch for $expected_source" >&2
      return 1
    }
    tip=$(git -C "$expected_source" rev-parse "refs/heads/$default^{commit}" 2>/dev/null) || return 1
    expected="local $default"
  fi
  head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || return 1
  if [ "$head" != "$tip" ]; then
    echo "error: acquired worktree is stale: HEAD $head does not match $expected $tip" >&2
    return 1
  fi
  return 0
}

verify_returnable_worktree() {
  local worktree=$1 expected_source=$2 expected_tip=$3 head expected_commit
  verify_worktree_safety "$worktree" "$expected_source" || return $?
  expected_commit=$(git -C "$worktree" rev-parse --verify "$expected_tip^{commit}" 2>/dev/null) || {
    echo "error: expected acquired worktree tip cannot be resolved: $expected_tip" >&2
    return 1
  }
  head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || {
    echo "error: acquired worktree HEAD cannot be resolved at $worktree" >&2
    return 1
  }
  if [ "$head" != "$expected_commit" ]; then
    echo "error: acquired worktree changed from expected detached tip $expected_commit to $head; retain it for manual recovery" >&2
    return 3
  fi
  return 0
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

remove_matching_legacy_launch_agent() {
  local domain=$1 legacy_plist="$LAUNCH_AGENTS_DIR/$LEGACY_LABEL.plist"
  [ "$LABEL" != "$LEGACY_LABEL" ] || return 0
  [ -f "$legacy_plist" ] && [ ! -L "$legacy_plist" ] || return 0
  grep -Fq "<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>" "$legacy_plist" || return 0
  if ! grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME_CANONICAL")</string>" "$legacy_plist" \
    && ! grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME")</string>" "$legacy_plist"; then
    return 0
  fi
  "$LAUNCHCTL" bootout "$domain/$LEGACY_LABEL" >/dev/null 2>&1 || true
  rm -f "$legacy_plist"
}

install_launch_agent() {
  local bash_runtime python_runtime perl_runtime runtime_path temp previous domain
  [ "$PLATFORM" = Darwin ] || {
    echo "error: checkout-refresh background installation currently requires macOS" >&2
    return 1
  }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  bash_runtime=$(command -v bash) || return 1
  python_runtime=$(command -v python3) || return 1
  perl_runtime=$(command -v perl) \
    || { echo "error: perl is unavailable for checkout-refresh process control" >&2; return 1; }
  case "$bash_runtime" in /*) ;; *) echo "error: cannot resolve an absolute Bash runtime" >&2; return 1 ;; esac
  runtime_path="$(dirname "$python_runtime"):$(dirname "$perl_runtime"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$LAUNCH_AGENTS_DIR" "$STATE_ROOT" "$LOCK_ROOT" || return 1
  [ -d "$LAUNCH_AGENTS_DIR" ] && [ ! -L "$LAUNCH_AGENTS_DIR" ] \
    && [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    && [ -d "$LOCK_ROOT" ] && [ ! -L "$LOCK_ROOT" ] \
    || { echo "error: unsafe checkout-refresh installation directories" >&2; return 1; }
  temp=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.XXXXXX") || return 1
  previous=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.previous.XXXXXX") || { rm -f "$temp"; return 1; }
  rm -f "$previous"
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
      || { rm -f "$temp"; echo "error: unsafe checkout-refresh plist" >&2; return 1; }
    cp -p "$PLIST" "$previous" || return 1
  fi
  cat > "$temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml_escape "$LABEL")</string>
<key>ProgramArguments</key><array>
<string>$(xml_escape "$bash_runtime")</string>
<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>
<string>run-once</string>
</array>
<key>EnvironmentVariables</key><dict>
<key>HOME</key><string>$(xml_escape "$HOME")</string>
<key>PATH</key><string>$(xml_escape "$runtime_path")</string>
<key>FM_HOME</key><string>$(xml_escape "$FM_HOME_CANONICAL")</string>
<key>FM_TREEHOUSE_ROOT</key><string>$(xml_escape "$TREEHOUSE_ROOT")</string>
<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$(xml_escape "$STATE_ROOT")</string>
<key>FM_CHECKOUT_REFRESH_LOCK_ROOT</key><string>$(xml_escape "$LOCK_ROOT")</string>
<key>FM_CHECKOUT_REFRESH_INTERVAL</key><string>$(xml_escape "$INTERVAL")</string>
<key>FM_CHECKOUT_REFRESH_BACKSTOP</key><string>$(xml_escape "$BACKSTOP")</string>
</dict>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>$INTERVAL</integer>
<key>StandardOutPath</key><string>$(xml_escape "$STATE_ROOT/stdout.log")</string>
<key>StandardErrorPath</key><string>$(xml_escape "$STATE_ROOT/stderr.log")</string>
</dict></plist>
EOF
  chmod 600 "$temp" || return 1
  mv -f "$temp" "$PLIST" || return 1
  domain="gui/$(id -u)"
  "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  if "$LAUNCHCTL" bootstrap "$domain" "$PLIST" \
    && "$LAUNCHCTL" kickstart "$domain/$LABEL"; then
    rm -f "$previous"
    remove_matching_legacy_launch_agent "$domain"
    return 0
  fi
  if [ -f "$previous" ]; then
    mv -f "$previous" "$PLIST"
    "$LAUNCHCTL" bootstrap "$domain" "$PLIST" >/dev/null 2>&1 || true
  else
    rm -f "$PLIST"
  fi
  echo "error: checkout-refresh LaunchAgent activation failed; previous definition restored" >&2
  return 1
}

ensure_launch_agent() {
  local domain heartbeat now max_age
  [ "$PLATFORM" = Darwin ] || return 0
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "checkout-refresh LaunchAgent is not installed" >&2; return 1; }
  grep -Fq "<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent points at a different Firstmate checkout" >&2; return 1; }
  grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME_CANONICAL")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent belongs to a different Firstmate home" >&2; return 1; }
  grep -Fq "<key>FM_TREEHOUSE_ROOT</key><string>$(xml_escape "$TREEHOUSE_ROOT")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different Treehouse root" >&2; return 1; }
  grep -Fq "<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$(xml_escape "$STATE_ROOT")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different home-scoped state root" >&2; return 1; }
  grep -Fq "<key>FM_CHECKOUT_REFRESH_LOCK_ROOT</key><string>$(xml_escape "$LOCK_ROOT")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different shared lock root" >&2; return 1; }
  grep -Fq "<key>FM_CHECKOUT_REFRESH_INTERVAL</key><string>$(xml_escape "$INTERVAL")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different refresh interval" >&2; return 1; }
  grep -Fq "<key>FM_CHECKOUT_REFRESH_BACKSTOP</key><string>$(xml_escape "$BACKSTOP")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different refresh backstop" >&2; return 1; }
  grep -Fq "<key>StartInterval</key><integer>$INTERVAL</integer>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent uses a different scheduler interval" >&2; return 1; }
  domain="gui/$(id -u)"
  "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null 2>&1 \
    || { echo "checkout-refresh LaunchAgent is not loaded" >&2; return 1; }
  heartbeat=$(read_epoch "$STATE_ROOT/heartbeat")
  now=$(date +%s)
  max_age=$((INTERVAL * 3 + 30))
  [ "$heartbeat" -gt 0 ] && [ "$((now - heartbeat))" -le "$max_age" ] \
    || { echo "checkout-refresh heartbeat is stale or missing" >&2; return 1; }
}

scheduler_install() {
  case "$PLATFORM" in
    Darwin) install_launch_agent ;;
    Linux)
      echo "error: checkout-refresh has no Linux scheduler adapter yet; use run-once from cron or systemd until one is implemented" >&2
      return 1
      ;;
    *)
      echo "error: checkout-refresh has no scheduler adapter for $PLATFORM" >&2
      return 1
      ;;
  esac
}

scheduler_ensure() {
  case "$PLATFORM" in
    Darwin) ensure_launch_agent ;;
    Linux)
      echo "error: checkout-refresh has no Linux scheduler adapter yet" >&2
      return 1
      ;;
    *)
      echo "error: checkout-refresh has no scheduler adapter for $PLATFORM" >&2
      return 1
      ;;
  esac
}

case "${1:-}" in
  discover)
    [ $# -eq 1 ] || { usage; exit 2; }
    discover
    ;;
  run-once)
    shift
    run_once "$@"
    ;;
  preflight)
    [ $# -eq 2 ] || { usage; exit 2; }
    preflight "$2"
    ;;
  pool-preflight)
    [ $# -eq 2 ] || { usage; exit 2; }
    pool_preflight "$2"
    ;;
  acquire-worktree)
    [ $# -eq 3 ] || { usage; exit 2; }
    acquire_worktree "$2" "$3"
    ;;
  verify-worktree)
    [ $# -eq 3 ] || { usage; exit 2; }
    verify_worktree "$2" "$3"
    ;;
  verify-returnable)
    [ $# -eq 4 ] || { usage; exit 2; }
    verify_returnable_worktree "$2" "$3" "$4"
    ;;
  ensure)
    [ $# -eq 1 ] || { usage; exit 2; }
    scheduler_ensure
    ;;
  install)
    [ $# -eq 1 ] || { usage; exit 2; }
    scheduler_install
    ;;
  *) usage; exit 2 ;;
esac
