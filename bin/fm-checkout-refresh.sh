#!/usr/bin/env bash
# Keep every checkout that can seed Firstmate or Treehouse work current without
# touching unlanded work.
#
# The single-checkout mutation remains owned by fm-fleet-sync.sh.
# This script owns the broader covered-set discovery and the independent cadence:
#
#   - projects/* under the active FM_HOME;
#   - backing checkouts discovered from Treehouse's state under ~/.treehouse;
#   - exact Git worktree roots from `path <checkout>` entries in config/checkout-refresh;
#   - top-level clones under $HOME, plus explicit `scan <directory>` roots, whose
#     origin URL matches one of the checkouts above.
#
# Matching-origin discovery covers exact top-level clone roots such as ~/relvino
# without hard-coding a captain-specific path or inheriting an enclosing repository.
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
# with `run-once --scheduled` every FM_CHECKOUT_REFRESH_INTERVAL seconds while
# that Firstmate home is idle.
# Every run publishes coverage health, while only that scheduler-owned mode
# advances the independent liveness heartbeat.
# Its default state is under checkout-refresh/homes/<FM_HOME hash>, while
# checkout-refresh/locks remains shared so every fm-fleet-sync.sh caller
# serializes mutation of the same clone.
# Bounded probes and acquisitions terminate and reap their complete process tree.
# fm-fleet-sync.sh owns the equivalent per-checkout refresh bound for every caller.
# FM_TREEHOUSE_ACQUIRE_TIMEOUT applies the same process-tree ownership to the
# synchronous durable lease acquired before a task endpoint is created.
#
# Cadence and spawn-preflight refreshes delegate to fm-fleet-sync.sh with pruning
# disabled, while session-start pruning retains every branch whose landed state
# cannot be proved from repository content or a surviving remote ref.
# Dirty, diverged, non-default, and otherwise unsafe checkouts remain untouched
# and are recorded as durable alerts.
# Every probe also inventories non-ignored untracked files in both the covered seed
# checkouts and the Treehouse pool worktrees under repository skill directories
# (`.agents/skills`, `.claude/skills`, `.codex/skills`, and `skills`).
# Unreadable or malformed Treehouse state invalidates coverage health while the
# heartbeat records scheduler liveness independently.
# Every scan root must be readable and successfully enumerable, and every covered
# checkout retains its actual origin identity across runs.
# Registered local-only checkouts and remote-free repositories use their proven
# local default tip while still surfacing dirty, stale, or non-default states.
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
#   fm-checkout-refresh.sh run-once [--force] [--verbose] [--session] [--scheduled]
#   fm-checkout-refresh.sh preflight <checkout>
#   fm-checkout-refresh.sh pool-preflight <expected-source>
#   fm-checkout-refresh.sh acquire-worktree <expected-source> <lease-holder>
#   fm-checkout-refresh.sh verify-worktree <worktree> <expected-source>
#   fm-checkout-refresh.sh verify-home <home> <expected-source>
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
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
FM_HOME_CANONICAL=$(fm_checkout_trusted_dir "$FM_HOME") || {
  echo "error: checkout-refresh home identity is unavailable: $FM_HOME" >&2
  exit 1
}
FM_HOME_KEY=$(fm_checkout_hash_value "$FM_HOME_CANONICAL" 16) || {
  echo "error: checkout-refresh logical home identity is unavailable: $FM_HOME" >&2
  exit 1
}
FM_HOME_PHYSICAL_KEY=$(fm_checkout_physical_path_key "$FM_HOME_CANONICAL" directory 16) || {
  echo "error: checkout-refresh physical home identity is unavailable: $FM_HOME" >&2
  exit 1
}
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="${FM_CHECKOUT_REFRESH_CONFIG:-$CONFIG/checkout-refresh}"
if [ "${FM_TREEHOUSE_ROOT+x}" = x ]; then
  TREEHOUSE_ROOT_RAW=$FM_TREEHOUSE_ROOT
else
  TREEHOUSE_ROOT_RAW="$HOME/.treehouse"
fi
TREEHOUSE_ROOT=$TREEHOUSE_ROOT_RAW
TREEHOUSE_ROOT_CANONICAL=
TREEHOUSE_ROOT_INVALID=0
TREEHOUSE_ROOT_EXPLICIT=0
[ "${FM_TREEHOUSE_ROOT+x}" != x ] || TREEHOUSE_ROOT_EXPLICIT=1
if ! TREEHOUSE_ROOT=$(fm_checkout_lexical_path "$TREEHOUSE_ROOT_RAW" 1); then
  TREEHOUSE_ROOT_INVALID=1
  TREEHOUSE_ROOT=$TREEHOUSE_ROOT_RAW
elif [ -e "$TREEHOUSE_ROOT" ] && [ ! -d "$TREEHOUSE_ROOT" ]; then
  TREEHOUSE_ROOT_INVALID=1
elif [ -d "$TREEHOUSE_ROOT" ] \
  && TREEHOUSE_ROOT_CANONICAL=$(fm_checkout_trusted_dir "$TREEHOUSE_ROOT"); then
  TREEHOUSE_ROOT=$TREEHOUSE_ROOT_CANONICAL
elif [ -e "$TREEHOUSE_ROOT" ]; then
  TREEHOUSE_ROOT_INVALID=1
elif [ "$TREEHOUSE_ROOT_EXPLICIT" -eq 1 ]; then
  TREEHOUSE_ROOT_INVALID=1
else
  TREEHOUSE_ROOT_INVALID=0
fi
STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
DEFAULT_STATE_ROOT="$STATE_BASE/homes/$FM_HOME_KEY"
PHYSICAL_STATE_ROOT="$STATE_BASE/homes/$FM_HOME_PHYSICAL_KEY"
CUSTOM_STATE_ROOT=0
STATE_ROOT_EXPLICIT=0
USING_PHYSICAL_STATE_ROOT=0
if [ -n "${FM_CHECKOUT_REFRESH_STATE_ROOT:-}" ]; then
  STATE_ROOT_EXPLICIT=1
  case "$FM_CHECKOUT_REFRESH_STATE_ROOT" in
    "$DEFAULT_STATE_ROOT")
      STATE_ROOT=$DEFAULT_STATE_ROOT
      ;;
    "$PHYSICAL_STATE_ROOT")
      STATE_ROOT=$PHYSICAL_STATE_ROOT
      USING_PHYSICAL_STATE_ROOT=1
      ;;
    *)
      STATE_ROOT=$FM_CHECKOUT_REFRESH_STATE_ROOT
      CUSTOM_STATE_ROOT=1
      ;;
  esac
else
  STATE_ROOT=$DEFAULT_STATE_ROOT
fi
LOCK_ROOT=$(fm_checkout_lock_root "$STATE_BASE")
INTERVAL=${FM_CHECKOUT_REFRESH_INTERVAL:-60}
BACKSTOP=${FM_CHECKOUT_REFRESH_BACKSTOP:-900}
PROBE_TIMEOUT=${FM_CHECKOUT_REFRESH_PROBE_TIMEOUT:-15}
SYNC_TIMEOUT=${FM_CHECKOUT_REFRESH_SYNC_TIMEOUT:-60}
ACQUIRE_TIMEOUT=${FM_TREEHOUSE_ACQUIRE_TIMEOUT:-60}
ACTIVATION_TIMEOUT=${FM_CHECKOUT_REFRESH_ACTIVATION_TIMEOUT:-60}
PLATFORM=${FM_CHECKOUT_REFRESH_PLATFORM:-$(uname)}
LABEL_BASE=com.firstmate.checkout-refresh
LABEL=${FM_CHECKOUT_REFRESH_LABEL:-$LABEL_BASE.$FM_HOME_KEY}
PHYSICAL_LABEL=$LABEL_BASE.$FM_HOME_PHYSICAL_KEY
LEGACY_LABEL=${FM_CHECKOUT_REFRESH_LEGACY_LABEL:-$LABEL_BASE}
LAUNCH_AGENTS_DIR=${FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
PHYSICAL_PLIST="$LAUNCH_AGENTS_DIR/$PHYSICAL_LABEL.plist"
LAUNCHCTL=${FM_CHECKOUT_REFRESH_LAUNCHCTL:-launchctl}
HOME_STATE_NAMESPACE_STAGED=0
HOME_MIGRATION_ACTIVE=0
HOME_MIGRATION_RUN_LOCK=
PHYSICAL_AGENT_STOPPED=0
SCHEDULER_GENERATION=${FM_CHECKOUT_REFRESH_GENERATION:-}
case "$SCHEDULER_GENERATION" in
  '') ;;
  *[!0-9a-f]*)
    echo "error: FM_CHECKOUT_REFRESH_GENERATION must be a 32-character lowercase hexadecimal token" >&2
    exit 2
    ;;
esac
if [ -n "$SCHEDULER_GENERATION" ] && [ "${#SCHEDULER_GENERATION}" -ne 32 ]; then
  echo "error: FM_CHECKOUT_REFRESH_GENERATION must be a 32-character lowercase hexadecimal token" >&2
  exit 2
fi

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
case "$ACTIVATION_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_ACTIVATION_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac

usage() {
  echo "usage: fm-checkout-refresh.sh discover|run-once [--force] [--verbose] [--session] [--scheduled]|preflight <checkout>|pool-preflight <expected-source>|acquire-worktree <expected-source> <lease-holder>|verify-worktree <worktree> <expected-source>|verify-home <home> <expected-source>|verify-returnable <worktree> <expected-source> <expected-tip>|ensure|install" >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

canonical_dir() {
  fm_checkout_trusted_dir "$1"
}

exact_git_root() {
  local candidate=$1 canonical top canonical_top
  canonical=$(canonical_dir "$candidate") || return 1
  top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_top=$(canonical_dir "$top") || return 1
  [ "$canonical" = "$canonical_top" ] || return 1
  fm_checkout_validate_git_metadata "$canonical" >/dev/null || return 1
  printf '%s\n' "$canonical"
}

require_exact_git_root() {
  local candidate=$1 label=$2 canonical
  canonical=$(exact_git_root "$candidate") || {
    echo "error: $label must be an exact inspectable Git repository root: $candidate" >&2
    return 1
  }
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

parse_config() {
  local paths_file=$1 scans_file=$2 line directive value expanded failed=0 config_lexical config_parent
  manifest_create "$paths_file" || return 1
  manifest_create "$scans_file" || return 1
  config_lexical=$(fm_checkout_lexical_path "$CONFIG_FILE" 1) || {
    echo "checkout-refresh: skipped: unsafe config path $CONFIG_FILE" >&2
    return 1
  }
  config_parent=${config_lexical%/*}
  [ -n "$config_parent" ] || config_parent=/
  fm_checkout_trusted_dir "$config_parent" >/dev/null || {
    echo "checkout-refresh: skipped: config parent is missing, redirected, or unreadable: $config_parent" >&2
    return 1
  }
  if [ ! -e "$config_lexical" ]; then
    return 0
  fi
  if [ ! -f "$config_lexical" ] || [ ! -r "$config_lexical" ]; then
    echo "checkout-refresh: skipped: unsafe or unreadable config $config_lexical" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in ""|\#*) continue ;; esac
    directive=${line%%[[:space:]]*}
    if [ "$directive" = "$line" ]; then
      echo "checkout-refresh: skipped: malformed config directive '$line'" >&2
      failed=1
      continue
    fi
    value=${line#"$directive"}
    value=$(printf '%s\n' "$value" | sed 's/^[[:space:]]*//')
    [ -n "$value" ] || {
      echo "checkout-refresh: skipped: malformed config directive '$line'" >&2
      failed=1
      continue
    }
    case "$directive" in
      path)
        if expanded=$(expand_config_path "$value"); then
          manifest_append "$paths_file" "$expanded" || failed=1
        else
          failed=1
        fi
        ;;
      scan)
        if expanded=$(expand_config_path "$value"); then
          manifest_append "$scans_file" "$expanded" || failed=1
        else
          failed=1
        fi
        ;;
      *)
        echo "checkout-refresh: skipped: unknown config directive '$directive'" >&2
        failed=1
        ;;
    esac
  done < "$config_lexical"
  [ "$failed" -eq 0 ]
}

treehouse_worktree_paths() {
  if [ "$TREEHOUSE_ROOT_INVALID" = 1 ]; then
    echo "checkout-refresh: skipped: incomplete Treehouse coverage because the configured root is unsafe or unreadable: $TREEHOUSE_ROOT_RAW" >&2
    return 1
  fi
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
    if os.path.islink(path):
        raise OSError(f"{label} must not be a symlink")
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
        metadata = pool_entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            try:
                target = pool_entry.stat(follow_symlinks=True)
            except OSError as error:
                raise OSError("broken Treehouse pool symlink") from error
            if stat.S_ISDIR(target.st_mode):
                raise OSError("Treehouse pool must not be a symlink")
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            continue
        if any(character in pool_entry.path for character in ("\n", "\r", "\t")):
            raise OSError("Treehouse pool path contains unsupported control characters")
        entries = directory_entries(pool_entry.path, "Treehouse pool")
        states = [entry for entry in entries if entry.name == "treehouse-state.json"]
        if len(states) != 1:
            raise OSError("Treehouse pool must contain exactly one treehouse-state.json")
        state_paths.append(os.path.join(pool_entry.path, "treehouse-state.json"))
    except OSError as error:
        failed = True
        print(
            f"checkout-refresh: skipped: incomplete Treehouse coverage at {pool_entry.path}: {error}",
            file=sys.stderr,
        )

for state_path in state_paths:
    try:
        metadata = os.lstat(state_path)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise OSError("Treehouse state must be a real regular file")
        permissions = stat.S_IMODE(metadata.st_mode)
        if not permissions & 0o444:
            raise PermissionError("Treehouse state is unreadable")
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
            if not os.path.isabs(path):
                raise TypeError("worktree path must be absolute")
            if any(character in path for character in ("\n", "\r", "\t")):
                raise TypeError("worktree path contains unsupported control characters")
            print(f"{state_path}\t{os.path.dirname(state_path)}\t{path}")
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
    if os.path.islink(path):
        raise OSError(f"{label} must not be a symlink")
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
        metadata = project_entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            try:
                target = project_entry.stat(follow_symlinks=True)
            except OSError as error:
                raise OSError("broken active-home project symlink") from error
            if stat.S_ISDIR(target.st_mode):
                raise OSError("active-home project must not be a symlink")
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            continue
        if any(character in project_entry.path for character in ("\n", "\r")):
            raise OSError("active-home project path contains unsupported control characters")
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
  local worktree=$1 pool=$2 state=$3 worktree_root pool_root state_root main
  local worktree_common main_common listed line listed_root matches=0
  worktree_root=$(exact_git_root "$worktree") || return 1
  pool_root=$(canonical_dir "$pool") || return 1
  [ "$worktree_root" != "$pool_root" ] || return 1
  case "$worktree_root" in "$pool_root"/*) ;; *) return 1 ;; esac
  [ -f "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] || return 1
  state_root=$(canonical_dir "$(dirname "$state")") || return 1
  [ "$state_root" = "$pool_root" ] || return 1
  [ "$(basename "$state")" = treehouse-state.json ] || return 1
  python3 - "$state" "$worktree_root" <<'PY' || return 1
import json
import os
import sys

state_path, expected = sys.argv[1:]
try:
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
    worktrees = state["worktrees"]
    if not isinstance(worktrees, list):
        raise TypeError("worktrees must be an array")
    matches = []
    for entry in worktrees:
        if not isinstance(entry, dict):
            raise TypeError("worktree entry must be an object")
        path = entry.get("path")
        if not isinstance(path, str) or not path:
            raise TypeError("worktree path must be a non-empty string")
        if not os.path.isabs(path):
            raise TypeError("worktree path must be absolute")
        if os.path.realpath(path) == expected:
            matches.append(entry)
    if len(matches) != 1:
        raise ValueError("expected exactly one matching worktree entry")
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    raise SystemExit(1)
PY
  listed=$(git -C "$worktree_root" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  main=$(printf '%s\n' "$listed" | sed -n 's/^worktree //p' | sed -n '1p')
  [ -n "$main" ] || return 1
  main=$(exact_git_root "$main") || return 1
  [ "$main" != "$worktree_root" ] || return 1
  worktree_common=$(fm_checkout_git_common_dir "$worktree_root") || return 1
  main_common=$(fm_checkout_git_common_dir "$main") || return 1
  [ "$worktree_common" = "$main_common" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_root=$(exact_git_root "${line#worktree }" 2>/dev/null) || return 1
        [ "$listed_root" != "$worktree_root" ] || matches=$(( matches + 1 ))
        ;;
    esac
  done <<EOF
$listed
EOF
  [ "$matches" -eq 1 ] || return 1
  printf '%s\n' "$main"
}

origin_url() {
  git -C "$1" remote get-url origin 2>/dev/null
}

CHECKOUT_ORIGIN_KIND=
CHECKOUT_ORIGIN_VALUE=
inspect_checkout_origin() {
  local checkout=$1 remotes
  CHECKOUT_ORIGIN_KIND=
  CHECKOUT_ORIGIN_VALUE=
  remotes=$(git -C "$checkout" remote 2>/dev/null) || return 1
  if printf '%s\n' "$remotes" | grep -Fxq origin; then
    CHECKOUT_ORIGIN_VALUE=$(origin_url "$checkout") || return 1
    [ -n "$CHECKOUT_ORIGIN_VALUE" ] || return 1
    CHECKOUT_ORIGIN_KIND=origin
  else
    CHECKOUT_ORIGIN_KIND=no-origin
  fi
}

scan_root_candidates() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
try:
    if os.path.islink(root):
        raise OSError("scan root must not be a symlink")
    metadata = os.stat(root)
    permissions = stat.S_IMODE(metadata.st_mode)
    if not stat.S_ISDIR(metadata.st_mode):
        raise NotADirectoryError(root)
    if not permissions & 0o444 or not permissions & 0o111:
        raise PermissionError("scan root is unreadable")
    with os.scandir(root) as entries:
        for entry in sorted(entries, key=lambda candidate: candidate.name):
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                try:
                    target = entry.stat(follow_symlinks=True)
                except OSError as error:
                    raise OSError(f"broken scan candidate symlink: {entry.path}") from error
                if stat.S_ISDIR(target.st_mode):
                    raise OSError(f"scan candidate must not be a symlink: {entry.path}")
                continue
            if stat.S_ISDIR(metadata.st_mode):
                if any(character in entry.path for character in ("\n", "\r")):
                    raise OSError("scan candidate path contains unsupported control characters")
                permissions = stat.S_IMODE(metadata.st_mode)
                if not permissions & 0o444 or not permissions & 0o111:
                    raise PermissionError(f"scan candidate is unreadable: {entry.path}")
                print(entry.path)
except OSError as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
PY
}

prove_non_git_directory() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import os
import stat
import sys

candidate = sys.argv[1]
try:
    before = os.lstat(candidate)
    permissions = stat.S_IMODE(before.st_mode)
    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise OSError("candidate is not a real directory")
    if not permissions & 0o444 or not permissions & 0o111:
        raise PermissionError("candidate is unreadable")
    with os.scandir(candidate) as entries:
        snapshot = sorted(
            (
                entry.name,
                entry.inode(),
                entry.stat(follow_symlinks=False).st_mode,
                entry.stat(follow_symlinks=False).st_mtime_ns,
            )
            for entry in entries
        )
    if (
        os.environ.get("FM_CHECKOUT_REFRESH_TEST") == "1"
        and os.environ.get("FM_CHECKOUT_TEST_CREATE_GIT_AT") == candidate
    ):
        os.mkdir(os.path.join(candidate, ".git"))
    after = os.lstat(candidate)
    with os.scandir(candidate) as entries:
        confirmation = sorted(
            (
                entry.name,
                entry.inode(),
                entry.stat(follow_symlinks=False).st_mode,
                entry.stat(follow_symlinks=False).st_mtime_ns,
            )
            for entry in entries
        )
    if (
        (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_ctime_ns)
        != (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_ctime_ns)
        or snapshot != confirmation
    ):
        raise OSError("candidate identity changed")
    if any(name == ".git" for name, *_ in confirmation):
        raise OSError("candidate contains Git metadata")
    try:
        os.lstat(os.path.join(candidate, ".git"))
    except FileNotFoundError:
        pass
    else:
        raise OSError("candidate gained Git metadata")
except OSError:
    raise SystemExit(1)
PY
}

manifest_create() {
  : > "$1"
}

manifest_append() {
  [ "${FM_CHECKOUT_REFRESH_TEST:-0}:${FM_CHECKOUT_TEST_MANIFEST_FAILURE:-}" != "1:append" ] || return 1
  printf '%s\n' "$2" >> "$1"
}

manifest_append_pair() {
  [ "${FM_CHECKOUT_REFRESH_TEST:-0}:${FM_CHECKOUT_TEST_MANIFEST_FAILURE:-}" != "1:append" ] || return 1
  printf '%s\t%s\n' "$2" "$3" >> "$1"
}

manifest_sort_unique() {
  local path=$1 sorted
  [ "${FM_CHECKOUT_REFRESH_TEST:-0}:${FM_CHECKOUT_TEST_MANIFEST_FAILURE:-}" != "1:sort" ] || return 1
  sorted=$(mktemp "${path}.sorted.XXXXXX") || return 1
  if ! sort -u "$path" > "$sorted" || ! mv "$sorted" "$path"; then
    rm -f "$sorted" || true
    return 1
  fi
}

cleanup_discovery_tmp() {
  [ "${FM_CHECKOUT_REFRESH_TEST:-0}:${FM_CHECKOUT_TEST_MANIFEST_FAILURE:-}" != "1:cleanup" ] || return 1
  rm -rf "$1"
}

discover() {
  local tmp seeds origins scans scan_candidates configured_paths configured_scans treehouse_paths project_paths
  local path project worktree pool treehouse_state main root candidate candidate_output url failed=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-checkout-refresh-discover.XXXXXX") || return 1
  seeds="$tmp/seeds"
  origins="$tmp/origins"
  scans="$tmp/scans"
  scan_candidates="$tmp/scan-candidates"
  configured_paths="$tmp/configured-paths"
  configured_scans="$tmp/configured-scans"
  treehouse_paths="$tmp/treehouse-worktrees"
  project_paths="$tmp/active-projects"
  manifest_create "$seeds" || { cleanup_discovery_tmp "$tmp" || true; return 1; }
  manifest_create "$origins" || { cleanup_discovery_tmp "$tmp" || true; return 1; }
  manifest_create "$scans" || { cleanup_discovery_tmp "$tmp" || true; return 1; }
  manifest_create "$scan_candidates" || { cleanup_discovery_tmp "$tmp" || true; return 1; }
  if ! parse_config "$configured_paths" "$configured_scans"; then
    cleanup_discovery_tmp "$tmp" || true
    return 1
  fi
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    cleanup_discovery_tmp "$tmp" || true
    return 1
  fi
  if ! active_project_paths > "$project_paths"; then
    cleanup_discovery_tmp "$tmp" || true
    return 1
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if main=$(exact_git_root "$project"); then
      manifest_append "$seeds" "$main" || failed=1
    else
      echo "checkout-refresh: skipped: active-home project is not an exact inspectable Git repository root: $project" >&2
      failed=1
    fi
  done < "$project_paths"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if main=$(exact_git_root "$path"); then
      manifest_append "$seeds" "$main" || failed=1
    else
      echo "checkout-refresh: skipped: configured checkout is not an exact inspectable Git repository root: $path" >&2
      failed=1
    fi
  done < "$configured_paths"

  while IFS=$'\t' read -r treehouse_state pool worktree; do
    [ -n "$worktree" ] || continue
    if main=$(backing_checkout "$worktree" "$pool" "$treehouse_state" 2>/dev/null); then
      manifest_append "$seeds" "$main" || failed=1
    else
      echo "checkout-refresh: skipped: Treehouse worktree identity or registration is not inspectable: $worktree" >&2
      failed=1
    fi
  done < "$treehouse_paths"
  manifest_sort_unique "$seeds" || failed=1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! inspect_checkout_origin "$path"; then
      echo "checkout-refresh: skipped: covered checkout origin identity cannot be inspected: $path" >&2
      failed=1
      continue
    fi
    if [ "$CHECKOUT_ORIGIN_KIND" = origin ]; then
      manifest_append "$origins" "$CHECKOUT_ORIGIN_VALUE" || failed=1
    fi
  done < "$seeds"
  manifest_sort_unique "$origins" || failed=1

  if main=$(canonical_dir "$HOME" 2>/dev/null); then
    manifest_append "$scans" "$main" || failed=1
  else
    echo "checkout-refresh: skipped: home scan root is not inspectable: $HOME" >&2
    failed=1
  fi
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if main=$(canonical_dir "$root" 2>/dev/null); then
      manifest_append "$scans" "$main" || failed=1
    else
      echo "checkout-refresh: skipped: configured scan root is not a directory: $root" >&2
      failed=1
    fi
  done < "$configured_scans"
  manifest_sort_unique "$scans" || failed=1

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    candidate_output=$(scan_root_candidates "$root") || {
      echo "checkout-refresh: skipped: scan root is unreadable or cannot be enumerated: $root" >&2
      failed=1
      continue
    }
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      manifest_append "$scan_candidates" "$candidate" || failed=1
    done <<EOF
$candidate_output
EOF
  done < "$scans"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if ! git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if prove_non_git_directory "$candidate"; then
        continue
      fi
      echo "checkout-refresh: skipped: discovered Git identity cannot be inspected or disproved: $candidate" >&2
      failed=1
      continue
    fi
    if ! main=$(exact_git_root "$candidate"); then
      echo "checkout-refresh: skipped: discovered clone is not an exact inspectable Git repository root: $candidate" >&2
      failed=1
      continue
    fi
    if ! inspect_checkout_origin "$main"; then
      echo "checkout-refresh: skipped: discovered checkout origin identity cannot be inspected: $main" >&2
      failed=1
      continue
    fi
    [ "$CHECKOUT_ORIGIN_KIND" = origin ] || continue
    url=$CHECKOUT_ORIGIN_VALUE
    if [ ! -s "$origins" ] || ! grep -Fxq -- "$url" "$origins"; then
      continue
    fi
    manifest_append "$seeds" "$main" || failed=1
    if [ -n "${DISCOVERY_IDENTITIES_FILE:-}" ]; then
      manifest_append_pair "$DISCOVERY_IDENTITIES_FILE" "$main" "$url" || failed=1
    fi
  done < "$scan_candidates"

  if [ -n "${DISCOVERY_IDENTITIES_FILE:-}" ]; then
    manifest_sort_unique "$DISCOVERY_IDENTITIES_FILE" || failed=1
  fi
  [ "$failed" -eq 0 ] || {
    cleanup_discovery_tmp "$tmp" || true
    return 1
  }
  manifest_sort_unique "$seeds" || {
    cleanup_discovery_tmp "$tmp" || true
    return 1
  }
  cat "$seeds" || {
    cleanup_discovery_tmp "$tmp" || true
    return 1
  }
  cleanup_discovery_tmp "$tmp"
}

acquire_worktree() {
  local expected_source=$1 lease_holder=$2 status=0 canonical
  canonical=$(require_exact_git_root "$expected_source" "Treehouse acquisition source") || return 1
  expected_source=$canonical
  (
    local checkout_lock
    ensure_lock_roots || exit 1
    checkout_lock=$(fm_checkout_lock_path "$expected_source" "$LOCK_ROOT") || {
      echo "error: cannot resolve Treehouse acquisition lock identity for $expected_source" >&2
      exit 1
    }
    if ! fm_lock_try_acquire "$checkout_lock"; then
      echo "error: Treehouse acquisition already running for $expected_source (pid ${FM_LOCK_HELD_PID:-unknown})" >&2
      exit 1
    fi
    export FM_PROCESS_TREE_GUARD_FILE="${FM_LOCK_OWNER_DIR:?}/process-group"
    trap 'fm_lock_release "$checkout_lock"' EXIT
    cd "$expected_source" || exit 1
    if fm_run_bounded "$ACQUIRE_TIMEOUT" treehouse get --lease --lease-holder "$lease_holder"; then
      status=0
    else
      status=$?
    fi
    if ! fm_process_tree_cleanup_verified; then
      exit "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS"
    fi
    exit "$status"
  ) || status=$?
  case "$status" in
    0) return 0 ;;
    124)
      echo "error: Treehouse worktree acquisition timed out after ${ACQUIRE_TIMEOUT}s and terminated its process tree" >&2
      ;;
    "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS")
      echo "error: Treehouse worktree acquisition process cleanup could not be verified; no worktree was accepted for $lease_holder" >&2
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
  local checkout=$1 out line ref status
  PROBE_BRANCH=
  PROBE_TIP=
  if fm_run_bounded_capture out "$PROBE_TIMEOUT" \
      git -C "$checkout" ls-remote --symref origin HEAD 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] && fm_process_tree_cleanup_verified || return 1
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
  local checkout
  checkout=$(exact_git_root "$1") || return 1
  fm_checkout_hash_value "$checkout" 24
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
  if ! atomic_replace "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
}

atomic_copy() {
  local source=$1 destination=$2 tmp
  tmp=$(mktemp "$STATE_ROOT/.checkout-refresh-write.XXXXXX") || return 1
  cp "$source" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! atomic_replace "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
}

atomic_replace() {
  local source=$1 destination=$2
  python3 - "$source" "$destination" <<'PY'
import os
import stat
import sys

source, destination = sys.argv[1:]
try:
    if os.path.lexists(destination):
        metadata = os.lstat(destination)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("destination is not a regular file")
    os.replace(source, destination)
    metadata = os.lstat(destination)
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError("replacement is not a regular file")
except OSError:
    raise SystemExit(1)
PY
}

validate_external_identity_history() {
  local current=$1 prior="$STATE_ROOT/external-identities" path recorded_origin inspected current_origin failed=0
  if [ ! -e "$prior" ] && [ ! -L "$prior" ]; then
    return 0
  fi
  if [ -L "$prior" ] || [ ! -f "$prior" ] || [ ! -r "$prior" ]; then
    echo "checkout-refresh: skipped: prior external checkout identity manifest is unsafe or unreadable: $prior" >&2
    return 1
  fi
  if ! awk -F '\t' 'NF != 2 || $1 == "" || $2 == "" { failed = 1 } END { exit failed }' "$prior"; then
    echo "checkout-refresh: skipped: prior external checkout identity manifest is malformed: $prior" >&2
    return 1
  fi
  while IFS=$'\t' read -r path recorded_origin; do
    [ -n "$path" ] || continue
    if grep -Fqx -- "$path"$'\t'"$recorded_origin" "$current"; then
      continue
    fi
    if inspected=$(exact_git_root "$path" 2>/dev/null); then
      current_origin=$(origin_url "$inspected" || true)
      if [ "$inspected" != "$path" ]; then
        echo "checkout-refresh: skipped: prior external checkout root identity drifted at $path" >&2
      elif [ -z "$current_origin" ]; then
        echo "checkout-refresh: skipped: prior external checkout origin is unreadable at $path" >&2
      else
        echo "checkout-refresh: skipped: prior external checkout origin changed at $path" >&2
      fi
    else
      echo "checkout-refresh: skipped: prior external checkout disappeared or became unreadable at $path" >&2
    fi
    failed=1
  done < "$prior"
  [ "$failed" -eq 0 ]
}

record_run_result() {
  local coverage=$1 scheduled=${2:-0} now write_status=0
  now=$(date +%s)
  if [ "$scheduled" -eq 1 ]; then
    atomic_write "$STATE_ROOT/heartbeat" "$now" "$SCRIPT_DIR/fm-checkout-refresh.sh" \
      || write_status=1
  fi
  atomic_write "$STATE_ROOT/coverage-health" "$now" "$coverage" \
    || write_status=1
  if [ "$write_status" -eq 0 ] && [ "$scheduled" -eq 1 ] \
      && [ -n "$SCHEDULER_GENERATION" ]; then
    atomic_write "$STATE_ROOT/scheduler-generation" "$SCHEDULER_GENERATION" \
      || write_status=1
  fi
  return "$write_status"
}

ensure_state_root() {
  mkdir -p "$STATE_ROOT" || return 1
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    || { echo "error: unsafe checkout-refresh state directory: $STATE_ROOT" >&2; return 1; }
}

discover_home_launch_agent_namespaces() {
  local discovered label state count=0 logical_count=0 logical_state=
  [ -e "$LAUNCH_AGENTS_DIR" ] || [ -L "$LAUNCH_AGENTS_DIR" ] || return 0
  discovered=$(python3 - "$LAUNCH_AGENTS_DIR" "$LABEL_BASE" \
      "$SCRIPT_DIR/fm-checkout-refresh.sh" "$FM_HOME_CANONICAL" "$FM_HOME" "$STATE_BASE" <<'PY'
import os
import re
import stat
import sys
import xml.etree.ElementTree as ET

root, label_base, script, canonical_home, raw_home, state_base = sys.argv[1:]

def dictionary(element):
    children = list(element)
    if len(children) % 2:
        raise OSError("malformed plist dictionary")
    values = {}
    for index in range(0, len(children), 2):
        key = children[index]
        value = children[index + 1]
        if key.tag != "key" or not key.text or key.text in values:
            raise OSError("malformed or duplicate plist key")
        values[key.text] = value
    return values

def text_value(values, key):
    value = values.get(key)
    if value is None or value.tag != "string" or value.text is None:
        raise OSError("missing plist string")
    return value.text

def safe_directory(path):
    if not os.path.isabs(path) or path == os.path.sep:
        raise OSError("unsafe state root")
    normalized = os.path.normpath(path)
    current = os.path.sep
    for component in normalized.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError("redirected state root")
    metadata = os.lstat(normalized)
    if not stat.S_ISDIR(metadata.st_mode) or os.path.realpath(normalized) != normalized:
        raise OSError("unsafe state root")
    return normalized

try:
    root_meta = os.lstat(root)
    if stat.S_ISLNK(root_meta.st_mode) or not stat.S_ISDIR(root_meta.st_mode):
        raise OSError("unsafe launch agent directory")
    entries = sorted(os.scandir(root), key=lambda entry: entry.name)
    for entry in entries:
        if entry.name != label_base + ".plist" and (
            not entry.name.startswith(label_base + ".") or not entry.name.endswith(".plist")
        ):
            continue
        meta = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(meta.st_mode) or not stat.S_ISREG(meta.st_mode):
            raise OSError("unsafe launch agent definition")
        document = ET.parse(entry.path)
        root_element = document.getroot()
        plist_dictionary = root_element.find("dict")
        if plist_dictionary is None:
            raise OSError("missing plist dictionary")
        values = dictionary(plist_dictionary)
        authoritative_label = text_value(values, "Label")
        arguments = values.get("ProgramArguments")
        environment = values.get("EnvironmentVariables")
        if arguments is None or arguments.tag != "array":
            raise OSError("missing program arguments")
        if environment is None or environment.tag != "dict":
            raise OSError("missing environment")
        program_arguments = [
            argument.text
            for argument in list(arguments)
            if argument.tag == "string" and argument.text is not None
        ]
        if len(program_arguments) != len(list(arguments)):
            raise OSError("malformed program arguments")
        environment_values = dictionary(environment)
        parsed_home = text_value(environment_values, "FM_HOME")
        mentions_home = parsed_home in (canonical_home, raw_home)
        if parsed_home and not mentions_home:
            continue
        if (
            not mentions_home
            or len(program_arguments) != 4
            or not os.path.isabs(program_arguments[0])
            or program_arguments[1:] != [script, "run-once", "--scheduled"]
        ):
            raise OSError("incomplete launch agent identity")
        label = entry.name[:-6]
        if authoritative_label != label:
            raise OSError("launch agent filename and Label differ")
        if label == label_base:
            suffix = ""
        else:
            suffix = label[len(label_base) + 1 :]
        if suffix and re.fullmatch(r"[0-9a-f]{16}", suffix) is None:
            raise OSError("invalid launch agent label")
        parsed_state = safe_directory(
            text_value(environment_values, "FM_CHECKOUT_REFRESH_STATE_ROOT")
        )
        print(f"{label}\t{parsed_state}")
except (ET.ParseError, OSError, UnicodeError):
    raise SystemExit(1)
PY
  ) || {
    echo "error: checkout-refresh LaunchAgent namespaces cannot be safely enumerated" >&2
    return 1
  }
  while IFS=$'\t' read -r label state; do
    [ -n "$label" ] || continue
    if [ "$label" = "$LABEL" ]; then
      logical_state=$state
      logical_count=$((logical_count + 1))
      continue
    fi
    PHYSICAL_LABEL=$label
    PHYSICAL_PLIST="$LAUNCH_AGENTS_DIR/$label.plist"
    PHYSICAL_STATE_ROOT=$state
    count=$((count + 1))
  done <<EOF
$discovered
EOF
  [ "$logical_count" -le 1 ] && [ "$count" -le 1 ] || {
    echo "error: ambiguous checkout-refresh LaunchAgent namespaces for $FM_HOME_CANONICAL" >&2
    return 1
  }
  if [ "$logical_count" -eq 1 ] && [ "$STATE_ROOT_EXPLICIT" -eq 0 ] \
      && [ "$logical_state" != "$DEFAULT_STATE_ROOT" ]; then
    STATE_ROOT=$logical_state
    CUSTOM_STATE_ROOT=1
  elif [ "$logical_count" -eq 1 ] && [ "$logical_state" != "$STATE_ROOT" ]; then
    echo "error: checkout-refresh LaunchAgent state root drifted from the requested namespace" >&2
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    if [ "$STATE_ROOT_EXPLICIT" -eq 1 ] && [ "$STATE_ROOT" != "$PHYSICAL_STATE_ROOT" ]; then
      echo "error: checkout-refresh legacy LaunchAgent state root conflicts with the requested namespace" >&2
      return 1
    fi
    case "$PHYSICAL_STATE_ROOT" in
      "$STATE_BASE"/homes/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        ;;
      *)
        STATE_ROOT=$PHYSICAL_STATE_ROOT
        CUSTOM_STATE_ROOT=1
        return 0
        ;;
    esac
    case "${FM_CHECKOUT_REFRESH_STATE_ROOT:-$DEFAULT_STATE_ROOT}" in
      "$PHYSICAL_STATE_ROOT")
        STATE_ROOT=$PHYSICAL_STATE_ROOT
        USING_PHYSICAL_STATE_ROOT=1
        CUSTOM_STATE_ROOT=0
        ;;
    esac
  fi
}

stage_home_state_namespace() {
  local source=$1 destination=$2 parent
  parent=${destination%/*}
  python3 - "$source" "$destination" "$parent" <<'PY'
import os
import shutil
import stat
import sys
import tempfile

source, destination, parent = sys.argv[1:]
staging = ""

def failed(error):
    raise error

try:
    source_meta = os.lstat(source)
    parent_meta = os.lstat(parent)
    if stat.S_ISLNK(source_meta.st_mode) or not stat.S_ISDIR(source_meta.st_mode):
        raise OSError("unsafe source namespace")
    if stat.S_ISLNK(parent_meta.st_mode) or not stat.S_ISDIR(parent_meta.st_mode):
        raise OSError("unsafe namespace parent")
    if os.path.lexists(destination):
        raise OSError("destination namespace exists")
    staging = tempfile.mkdtemp(prefix=".home-state-migration.", dir=parent)
    payload = os.path.join(staging, "state")
    os.mkdir(payload, 0o700)
    for current, directories, files in os.walk(
        source, topdown=True, followlinks=False, onerror=failed
    ):
        relative = os.path.relpath(current, source)
        target = payload if relative == "." else os.path.join(payload, relative)
        safe_directories = []
        for name in sorted(directories):
            if relative == "." and (
                name == ".run-lock" or name.startswith(".run-lock.")
            ):
                continue
            path = os.path.join(current, name)
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise OSError("unsafe state directory")
            os.mkdir(os.path.join(target, name), metadata.st_mode & 0o777)
            safe_directories.append(name)
        directories[:] = safe_directories
        for name in sorted(files):
            if relative == "." and (
                name == ".run-lock" or name.startswith(".run-lock.")
            ):
                continue
            path = os.path.join(current, name)
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise OSError("unsafe state file")
            target_file = os.path.join(target, name)
            shutil.copyfile(path, target_file)
            os.chmod(target_file, metadata.st_mode & 0o777)
            with open(target_file, "rb") as stream:
                os.fsync(stream.fileno())
    if os.environ.get("FM_CHECKOUT_REFRESH_TEST") == "1" and os.environ.get(
        "FM_CHECKOUT_TEST_HOME_MIGRATION_FAILURE"
    ) == "stage":
        raise OSError("injected staging failure")
    os.replace(payload, destination)
    os.rmdir(staging)
except OSError:
    if staging:
        shutil.rmtree(staging, ignore_errors=True)
    raise SystemExit(1)
PY
}

remove_home_state_namespace() {
  python3 - "$1" "${1%/*}" <<'PY'
import os
import shutil
import stat
import sys

target, parent = sys.argv[1:]
try:
    parent_real = os.path.realpath(parent)
    target_meta = os.lstat(target)
    if stat.S_ISLNK(target_meta.st_mode) or not stat.S_ISDIR(target_meta.st_mode):
        raise OSError("unsafe state namespace")
    if os.path.dirname(os.path.realpath(target)) != parent_real:
        raise OSError("escaping state namespace")
    shutil.rmtree(target)
except OSError:
    raise SystemExit(1)
PY
}

prepare_home_state_namespace() {
  local parent command=${1:-}
  discover_home_launch_agent_namespaces || return 1
  [ "$CUSTOM_STATE_ROOT" -eq 0 ] || return 0
  [ "$DEFAULT_STATE_ROOT" != "$PHYSICAL_STATE_ROOT" ] || return 0
  parent=${DEFAULT_STATE_ROOT%/*}
  if { [ -e "$DEFAULT_STATE_ROOT" ] || [ -L "$DEFAULT_STATE_ROOT" ]; } \
    && { [ -e "$PHYSICAL_STATE_ROOT" ] || [ -L "$PHYSICAL_STATE_ROOT" ]; }; then
    echo "error: ambiguous checkout-refresh home state namespaces for $FM_HOME_CANONICAL" >&2
    return 1
  fi
  if [ "$USING_PHYSICAL_STATE_ROOT" -eq 1 ]; then
    [ -d "$PHYSICAL_STATE_ROOT" ] && [ ! -L "$PHYSICAL_STATE_ROOT" ] || {
      echo "error: unsafe physical checkout-refresh home state namespace: $PHYSICAL_STATE_ROOT" >&2
      return 1
    }
    return 0
  fi
  if [ -e "$DEFAULT_STATE_ROOT" ] || [ -L "$DEFAULT_STATE_ROOT" ]; then
    [ -d "$DEFAULT_STATE_ROOT" ] && [ ! -L "$DEFAULT_STATE_ROOT" ] || {
      echo "error: unsafe logical checkout-refresh home state namespace: $DEFAULT_STATE_ROOT" >&2
      return 1
    }
  fi
  if { [ -e "$PHYSICAL_STATE_ROOT" ] || [ -L "$PHYSICAL_STATE_ROOT" ] \
      || [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; } \
    && [ "$command" != ensure ] && [ "$command" != install ]; then
    echo "error: checkout-refresh physical state requires an ensure or install migration before use" >&2
    return 1
  fi
  if [ -e "$PHYSICAL_STATE_ROOT" ] || [ -L "$PHYSICAL_STATE_ROOT" ]; then
    [ -d "$PHYSICAL_STATE_ROOT" ] && [ ! -L "$PHYSICAL_STATE_ROOT" ] || {
      echo "error: unsafe physical checkout-refresh home state namespace: $PHYSICAL_STATE_ROOT" >&2
      return 1
    }
    mkdir -p "$parent" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  fi
  if [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; then
    if [ ! -e "$PHYSICAL_STATE_ROOT" ] && [ ! -L "$PHYSICAL_STATE_ROOT" ]; then
      echo "error: physical checkout-refresh LaunchAgent has no durable state namespace to migrate" >&2
      return 1
    fi
    [ "$PLATFORM" = Darwin ] || {
      echo "error: checkout-refresh physical LaunchAgent migration requires macOS" >&2
      return 1
    }
    command -v "$LAUNCHCTL" >/dev/null 2>&1 || return 1
    validate_launch_agent_namespaces || return 1
    if "$LAUNCHCTL" print "gui/$(id -u)/$PHYSICAL_LABEL" >/dev/null 2>&1; then
      "$LAUNCHCTL" bootout "gui/$(id -u)/$PHYSICAL_LABEL" >/dev/null 2>&1 || {
        echo "error: cannot quiesce the physical checkout-refresh LaunchAgent before migration" >&2
        return 1
      }
      PHYSICAL_AGENT_STOPPED=1
    fi
  fi
  if [ -e "$PHYSICAL_STATE_ROOT" ] || [ -L "$PHYSICAL_STATE_ROOT" ]; then
    fm_checkout_lock_prepare "$LOCK_ROOT" || {
      rollback_home_state_namespace_migration || true
      return 1
    }
    HOME_MIGRATION_RUN_LOCK="$PHYSICAL_STATE_ROOT/.run-lock"
    fm_lock_try_acquire "$HOME_MIGRATION_RUN_LOCK" || {
      echo "error: checkout-refresh physical state is busy; migration retained the prior namespace" >&2
      HOME_MIGRATION_RUN_LOCK=
      rollback_home_state_namespace_migration || true
      return 1
    }
    stage_home_state_namespace "$PHYSICAL_STATE_ROOT" "$DEFAULT_STATE_ROOT" || {
      echo "error: cannot stage checkout-refresh home state in its logical namespace" >&2
      rollback_home_state_namespace_migration || true
      return 1
    }
    HOME_STATE_NAMESPACE_STAGED=1
  fi
  HOME_MIGRATION_ACTIVE=1
}

rollback_home_state_namespace_migration() {
  local failed=0
  if [ "$HOME_MIGRATION_ACTIVE" -eq 1 ] && [ "$PLATFORM" = Darwin ]; then
    "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
      [ -f "$PLIST" ] && [ ! -L "$PLIST" ] && rm -f "$PLIST" || failed=1
    fi
  fi
  if [ "$HOME_STATE_NAMESPACE_STAGED" -eq 1 ]; then
    if [ ! -d "$DEFAULT_STATE_ROOT" ] || [ -L "$DEFAULT_STATE_ROOT" ] \
      || ! remove_home_state_namespace "$DEFAULT_STATE_ROOT"; then
      failed=1
    else
      HOME_STATE_NAMESPACE_STAGED=0
    fi
  fi
  if [ -n "$HOME_MIGRATION_RUN_LOCK" ]; then
    fm_lock_release "$HOME_MIGRATION_RUN_LOCK" || failed=1
    HOME_MIGRATION_RUN_LOCK=
  fi
  if [ "$PHYSICAL_AGENT_STOPPED" -eq 1 ]; then
    if [ -f "$PHYSICAL_PLIST" ] && [ ! -L "$PHYSICAL_PLIST" ] \
      && "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PHYSICAL_PLIST" >/dev/null 2>&1; then
      PHYSICAL_AGENT_STOPPED=0
    else
      failed=1
    fi
  fi
  [ "$failed" -ne 0 ] || HOME_MIGRATION_ACTIVE=0
  [ "$failed" -eq 0 ]
}

commit_home_state_namespace_migration() {
  local retired=
  [ "$HOME_MIGRATION_ACTIVE" -eq 1 ] || return 0
  if [ -e "$PHYSICAL_STATE_ROOT" ] || [ -L "$PHYSICAL_STATE_ROOT" ]; then
    [ -d "$PHYSICAL_STATE_ROOT" ] && [ ! -L "$PHYSICAL_STATE_ROOT" ] || return 1
    retired="$PHYSICAL_STATE_ROOT.retired.$$"
    [ ! -e "$retired" ] && [ ! -L "$retired" ] || return 1
    mv "$PHYSICAL_STATE_ROOT" "$retired" || return 1
    if [ -n "$HOME_MIGRATION_RUN_LOCK" ]; then
      HOME_MIGRATION_RUN_LOCK="$retired/.run-lock"
      if ! fm_lock_release "$HOME_MIGRATION_RUN_LOCK"; then
        mv "$retired" "$PHYSICAL_STATE_ROOT" || true
        HOME_MIGRATION_RUN_LOCK="$PHYSICAL_STATE_ROOT/.run-lock"
        return 1
      fi
      HOME_MIGRATION_RUN_LOCK=
    fi
  fi
  if [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; then
    if [ ! -f "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ] \
      || { [ "${FM_CHECKOUT_REFRESH_TEST:-0}:${FM_CHECKOUT_TEST_HOME_MIGRATION_FAILURE:-}" = "1:commit" ]; } \
      || ! rm -f "$PHYSICAL_PLIST"; then
      [ -z "$retired" ] || mv "$retired" "$PHYSICAL_STATE_ROOT" || true
      return 1
    fi
  fi
  HOME_MIGRATION_ACTIVE=0
  HOME_STATE_NAMESPACE_STAGED=0
  PHYSICAL_AGENT_STOPPED=0
  if [ -n "$retired" ] && ! remove_home_state_namespace "$retired"; then
    echo "warning: retired checkout-refresh state remains quarantined at $retired" >&2
  fi
  remove_matching_legacy_launch_agent "gui/$(id -u)" || return 1
}

ensure_lock_roots() {
  ensure_state_root || return 1
  fm_checkout_lock_prepare "$LOCK_ROOT" \
    || { echo "error: unsafe checkout-refresh lock directory: $LOCK_ROOT" >&2; return 1; }
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
    rm -f "$inventory" || return 1
    if ! rm -f "$alert"; then
      echo "$checkout: HYGIENE: stale alert cannot be cleared - coverage remains unhealthy" >&2
      return 1
    fi
    return 0
  fi

  signature=$(fm_checkout_hash_file "$inventory") || {
    rm -f "$inventory"
    echo "$checkout: HYGIENE: inventory signature failed - coverage remains unhealthy" >&2
    return 1
  }
  count=$(awk 'END { print NR + 0 }' "$inventory")
  HYGIENE_FOUND=1
  prior=$(sed -n '2p' "$alert" 2>/dev/null || true)
  examples=$(awk 'NR <= 3 { if (shown) printf ", "; printf "%s", $0; shown = 1 } END { if (NR > 3) printf ", ..." }' "$inventory")
  message="$checkout: HYGIENE: $count untracked skill-draft files under repository skill directories - reconcile before an upstream collision"
  if ! atomic_write "$alert" "$checkout" "$signature" "$count" "$(date +%s)" "$examples"; then
    rm -f "$inventory"
    echo "$checkout: HYGIENE: alert persistence failed - coverage remains unhealthy" >&2
    return 1
  fi
  rm -f "$inventory"
  if [ "$repeat" -eq 1 ] || [ "$signature" != "$prior" ]; then
    printf '%s (%s)\n' "$message" "$examples"
  fi
}

prepare_hygiene_discovery() {
  local seed_file=$1 hygiene_file=$2 treehouse_paths treehouse_state pool worktree canonical failed=0
  cp "$seed_file" "$hygiene_file" || return 1
  treehouse_paths=$(mktemp "$STATE_ROOT/.treehouse-worktrees.XXXXXX") || return 1
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    rm -f "$treehouse_paths"
    return 1
  fi
  while IFS=$'\t' read -r treehouse_state pool worktree; do
    [ -n "$worktree" ] || continue
    if backing_checkout "$worktree" "$pool" "$treehouse_state" >/dev/null 2>&1 \
        && canonical=$(exact_git_root "$worktree" 2>/dev/null); then
      manifest_append "$hygiene_file" "$canonical" || failed=1
    else
      echo "checkout-refresh: skipped: Treehouse worktree identity or registration is not inspectable: $worktree" >&2
      failed=1
    fi
  done < "$treehouse_paths"
  rm -f "$treehouse_paths" || failed=1
  [ "$failed" -eq 0 ] || return 1
  manifest_sort_unique "$hygiene_file"
}

clear_stale_hygiene_alerts() {
  local hygiene_file=$1 alert checkout failed=0
  for alert in "$STATE_ROOT"/*.hygiene-alert; do
    [ -f "$alert" ] || continue
    checkout=$(sed -n '1p' "$alert" 2>/dev/null || true)
    if [ -z "$checkout" ] || ! grep -Fxq -- "$checkout" "$hygiene_file"; then
      rm -f "$alert" || failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

sync_checkout() {
  local checkout=$1 output_file=$2 prune=${3:-0}
  local status physical
  physical=$(fm_checkout_physical_path_identity "$checkout" directory) || {
    printf '%s: skipped: refresh physical identity cannot be inspected\n' "$checkout" > "$output_file"
    return 1
  }
  if (
    export FM_FLEET_PRUNE="$prune"
    export FM_CHECKOUT_REFRESH_SYNC_TIMEOUT="$SYNC_TIMEOUT"
    export FM_FLEET_SYNC_EXPECTED_ORIGIN_KIND="$CHECKOUT_ORIGIN_KIND"
    export FM_FLEET_SYNC_EXPECTED_ORIGIN_VALUE="$CHECKOUT_ORIGIN_VALUE"
    export FM_FLEET_SYNC_EXPECTED_PHYSICAL_IDENTITY="$physical"
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

record_reinspection_failure() {
  local checkout=$1 key alert output
  key=$(checkout_key "$checkout") || {
    printf '%s: skipped: covered checkout lock identity cannot be resolved\n' "$checkout"
    return 1
  }
  alert="$STATE_ROOT/$key.alert"
  output="$checkout: skipped: covered checkout became uninspectable during refresh; restore access and rerun checkout refresh"
  printf '%s\n' "$output"
  record_alert "$alert" "$checkout" "$output" || {
    printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
    return 1
  }
}

CHECKOUT_REFRESH_AUTHORITY=
resolve_checkout_refresh_authority() {
  local checkout=$1 mode_line mode
  CHECKOUT_REFRESH_AUTHORITY=
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$(basename "$checkout")" 2>/dev/null) || return 1
  mode=${mode_line%% *}
  if [ "$mode" = local-only ] || [ "$CHECKOUT_ORIGIN_KIND" = no-origin ]; then
    CHECKOUT_REFRESH_AUTHORITY=local
  else
    CHECKOUT_REFRESH_AUTHORITY=upstream
  fi
}

checkout_identity_migration_transaction() {
  local checkout=$1 destination_prefix=$2 physical=$3 source_prefix=${4:-} line_count=${5:-}
  python3 - "$STATE_ROOT" "$checkout" "$destination_prefix" "$physical" \
    "$source_prefix" "$line_count" <<'PY'
import hashlib
import os
import shutil
import stat
import sys
import tempfile

state_root, checkout, destination_prefix, physical, requested_source, requested_lines = sys.argv[1:]
journal = destination_prefix + ".identity-migration"
staging = destination_prefix + ".identity-migration-stage"
allowed_extensions = ("identity", "tip", "last", "alert", "hygiene-alert")
journal_preexisting = os.path.lexists(journal)

def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def regular_file(path):
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise OSError("unsafe state file")
    return metadata

def payload(source, extension, line_count):
    regular_file(source)
    with open(source, "rb") as stream:
        content = stream.read()
    if extension == "identity" and line_count == "2":
        try:
            values = content.decode("utf-8").splitlines()
        except UnicodeError as error:
            raise OSError("invalid identity encoding") from error
        if len(values) != 2:
            raise OSError("identity changed during migration")
        content = ("\n".join(values + [physical]) + "\n").encode("utf-8")
    return content

def digest(content):
    return hashlib.sha256(content).hexdigest()

def write_journal(values):
    descriptor, temporary = tempfile.mkstemp(
        prefix=".identity-migration-journal.", dir=state_root
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            for key, value in values:
                stream.write(f"{key}={value}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, journal)
        fsync_directory(state_root)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise

def read_journal():
    regular_file(journal)
    values = {}
    with open(journal, "r", encoding="utf-8") as stream:
        for raw in stream:
            line = raw.rstrip("\n")
            if "=" not in line:
                raise OSError("malformed migration journal")
            key, value = line.split("=", 1)
            if not key or key in values:
                raise OSError("malformed migration journal")
            values[key] = value
    return values

def staged_payloads(extensions, publish, line_count):
    if os.path.lexists(staging):
        metadata = os.lstat(staging)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise OSError("unsafe migration staging")
        shutil.rmtree(staging)
    os.mkdir(staging, 0o700)
    hashes = {}
    for extension in extensions:
        source = source_prefix + "." + extension
        content = payload(source, extension, line_count)
        hashes[extension] = digest(content)
        if extension not in publish:
            continue
        target = os.path.join(staging, extension)
        with open(target, "xb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(target, regular_file(source).st_mode & 0o777)
    fsync_directory(staging)
    fsync_directory(state_root)
    return hashes

def destination_matches(extension, expected_hash):
    destination = destination_prefix + "." + extension
    if not os.path.lexists(destination):
        return False
    regular_file(destination)
    with open(destination, "rb") as stream:
        return digest(stream.read()) == expected_hash

def staged_matches(extension, expected_hash):
    target = os.path.join(staging, extension)
    if not os.path.lexists(target):
        return False
    regular_file(target)
    with open(target, "rb") as stream:
        return digest(stream.read()) == expected_hash

def publish_file(extension):
    staged = os.path.join(staging, extension)
    regular_file(staged)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".identity-migration-publish.", dir=state_root
    )
    try:
        with os.fdopen(descriptor, "wb") as output, open(staged, "rb") as source:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, os.lstat(staged).st_mode & 0o777)
        os.replace(temporary, destination_prefix + "." + extension)
        fsync_directory(state_root)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise

try:
    root_metadata = os.lstat(state_root)
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise OSError("unsafe state root")
    if os.path.dirname(destination_prefix) != state_root:
        raise OSError("escaping destination")
    values = None
    if os.path.lexists(journal):
        values = read_journal()
        if values.get("version") != "1" or values.get("checkout") != checkout:
            raise OSError("migration journal identity mismatch")
        if values.get("destination") != os.path.basename(destination_prefix):
            raise OSError("migration destination mismatch")
        if values.get("physical") != physical:
            raise OSError("migration physical identity drift")
        line_count = values.get("lines", "")
        source_name = values.get("source", "")
        if (
            len(source_name) != 24
            or any(character not in "0123456789abcdef" for character in source_name)
        ):
            raise OSError("unsafe migration source")
        if source_name == os.path.basename(destination_prefix):
            raise OSError("migration source aliases destination")
        source_prefix = os.path.join(state_root, source_name)
        extensions = tuple(filter(None, values.get("extensions", "").split(",")))
        publish = tuple(filter(None, values.get("publish", "").split(",")))
        if (
            not extensions
            or extensions[0] != "identity"
            or len(set(extensions)) != len(extensions)
            or len(set(publish)) != len(publish)
            or any(extension not in allowed_extensions for extension in extensions)
            or any(extension not in extensions for extension in publish)
            or "identity" not in publish
            or line_count not in ("2", "3")
        ):
            raise OSError("malformed migration journal")
        hashes = {}
        for extension in extensions:
            value = values.get("hash." + extension, "")
            if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                raise OSError("malformed migration hash")
            hashes[extension] = value
    else:
        if os.path.lexists(staging):
            raise OSError("orphaned migration staging")
        if not requested_source:
            raise SystemExit(0)
        if os.path.dirname(requested_source) != state_root or requested_lines not in ("2", "3"):
            raise OSError("unsafe migration request")
        source_prefix = requested_source
        line_count = requested_lines
        extensions = []
        publish = []
        for extension in allowed_extensions:
            source = source_prefix + "." + extension
            if not os.path.lexists(source):
                continue
            regular_file(source)
            extensions.append(extension)
            destination = destination_prefix + "." + extension
            if os.path.lexists(destination):
                regular_file(destination)
                if extension not in ("alert", "hygiene-alert"):
                    raise OSError("destination state exists")
            else:
                publish.append(extension)
        if not extensions or extensions[0] != "identity" or "identity" not in publish:
            raise OSError("identity state is missing")
        hashes = staged_payloads(tuple(extensions), tuple(publish), line_count)
        if os.environ.get("FM_CHECKOUT_REFRESH_TEST") == "1" and os.environ.get(
            "FM_CHECKOUT_TEST_IDENTITY_MIGRATION_FAILURE"
        ) == "stage":
            shutil.rmtree(staging)
            fsync_directory(state_root)
            raise OSError("injected staging failure")
        journal_values = [
            ("version", "1"),
            ("checkout", checkout),
            ("source", os.path.basename(source_prefix)),
            ("destination", os.path.basename(destination_prefix)),
            ("physical", physical),
            ("lines", line_count),
            ("extensions", ",".join(extensions)),
            ("publish", ",".join(publish)),
        ]
        journal_values.extend(
            ("hash." + extension, hashes[extension]) for extension in extensions
        )
        write_journal(journal_values)
        if os.environ.get("FM_CHECKOUT_REFRESH_TEST") == "1" and os.environ.get(
            "FM_CHECKOUT_TEST_IDENTITY_MIGRATION_FAILURE"
        ) == "publish":
            os.unlink(journal)
            shutil.rmtree(staging)
            fsync_directory(state_root)
            raise OSError("injected publish failure")
    complete = all(
        destination_matches(extension, hashes[extension]) for extension in publish
    )
    if not complete:
        for extension in extensions:
            source = source_prefix + "." + extension
            if not os.path.lexists(source) \
                or digest(payload(source, extension, line_count)) != hashes[extension]:
                raise OSError("migration source changed")
        stage_valid = os.path.isdir(staging) and not os.path.islink(staging) and all(
            staged_matches(extension, hashes[extension]) for extension in publish
        )
        if not stage_valid:
            rebuilt_hashes = staged_payloads(extensions, publish, line_count)
            if rebuilt_hashes != hashes:
                raise OSError("migration source changed")
        for extension in publish:
            if destination_matches(extension, hashes[extension]):
                continue
            if not staged_matches(extension, hashes[extension]):
                raise OSError("migration staging changed")
            publish_file(extension)
            if (
                os.environ.get("FM_CHECKOUT_REFRESH_TEST") == "1"
                and os.environ.get("FM_CHECKOUT_TEST_IDENTITY_MIGRATION_CRASH")
                == "after-first-publish"
            ):
                os._exit(86)
    if not all(
        destination_matches(extension, hashes[extension]) for extension in publish
    ):
        raise OSError("migration publication incomplete")
    for extension in extensions:
        source = source_prefix + "." + extension
        if not os.path.lexists(source):
            continue
        if digest(payload(source, extension, line_count)) != hashes[extension]:
            raise OSError("migration source changed")
        regular_file(source)
        os.unlink(source)
    fsync_directory(state_root)
    if os.path.lexists(staging):
        metadata = os.lstat(staging)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise OSError("unsafe migration staging")
        shutil.rmtree(staging)
        fsync_directory(state_root)
    os.unlink(journal)
    fsync_directory(state_root)
except (OSError, UnicodeError):
    if not journal_preexisting and not os.path.lexists(journal) and os.path.lexists(staging):
        try:
            metadata = os.lstat(staging)
            if not stat.S_ISLNK(metadata.st_mode) and stat.S_ISDIR(metadata.st_mode):
                shutil.rmtree(staging)
                fsync_directory(state_root)
        except OSError:
            pass
    raise SystemExit(1)
PY
}

migrate_checkout_identity_state() {
  local checkout=$1 key=$2 destination="$STATE_ROOT/$key.identity"
  local candidate source_prefix destination_prefix match= count=0 lines current_physical current_physical_key
  current_physical=$(fm_checkout_physical_path_identity "$checkout" directory) || return 1
  destination_prefix="$STATE_ROOT/$key"
  checkout_identity_migration_transaction \
    "$checkout" "$destination_prefix" "$current_physical" || return 1
  for candidate in "$STATE_ROOT"/*.identity; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -r "$candidate" ] || return 1
    [ "$(sed -n '1p' "$candidate")" = "$checkout" ] || continue
    match=$candidate
    count=$((count + 1))
  done
  [ "$count" -le 1 ] || return 1
  [ "$count" -eq 1 ] || return 0
  lines=$(awk 'END { print NR + 0 }' "$match") || return 1
  if [ "$match" = "$destination" ]; then
    if [ "$lines" -eq 2 ]; then
      echo "$checkout: skipped: legacy checkout identity is not bound to a proven physical checkout"
      return 1
    fi
    return 0
  fi
  { [ "$lines" -eq 2 ] || [ "$lines" -eq 3 ]; } || return 1
  current_physical_key=$(fm_checkout_physical_path_key "$checkout" directory 24) || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  source_prefix=${match%.identity}
  if [ "$lines" -eq 2 ] && [ "${source_prefix##*/}" != "$current_physical_key" ]; then
    echo "$checkout: skipped: legacy checkout identity filename does not match the current physical checkout"
    return 1
  fi
  if [ "$lines" -eq 3 ] && [ "$(sed -n '3p' "$match")" != "$current_physical" ]; then
    echo "$checkout: skipped: legacy checkout physical identity drifted before migration"
    return 1
  fi
  checkout_identity_migration_transaction \
    "$checkout" "$destination_prefix" "$current_physical" "$source_prefix" "$lines"
}

validate_covered_checkout_identity() {
  local checkout=$1 key=$2 tip_file=$3 identity_file current_identity current_physical
  local recorded_checkout recorded_identity recorded_physical lines
  identity_file="$STATE_ROOT/$key.identity"
  migrate_checkout_identity_state "$checkout" "$key" || {
    echo "$checkout: skipped: covered checkout identity history is ambiguous or cannot be migrated"
    return 1
  }
  if [ "$CHECKOUT_ORIGIN_KIND" = origin ]; then
    current_identity="origin $CHECKOUT_ORIGIN_VALUE"
  else
    current_identity=no-origin
  fi
  current_physical=$(fm_checkout_physical_path_identity "$checkout" directory) || {
    echo "$checkout: skipped: covered checkout physical identity cannot be inspected"
    return 1
  }
  if [ -e "$identity_file" ] || [ -L "$identity_file" ]; then
    if [ -L "$identity_file" ] || [ ! -f "$identity_file" ] || [ ! -r "$identity_file" ]; then
      echo "$checkout: skipped: covered checkout identity record is unsafe or unreadable"
      return 1
    fi
    lines=$(awk 'END { print NR + 0 }' "$identity_file") || return 1
    recorded_checkout=$(sed -n '1p' "$identity_file") || return 1
    recorded_identity=$(sed -n '2p' "$identity_file") || return 1
    recorded_physical=$(sed -n '3p' "$identity_file") || return 1
    if { [ "$lines" -ne 2 ] && [ "$lines" -ne 3 ]; } \
      || [ "$recorded_checkout" != "$checkout" ] || [ -z "$recorded_identity" ]; then
      echo "$checkout: skipped: covered checkout identity record is malformed"
      return 1
    fi
    if [ "$recorded_identity" != "$current_identity" ]; then
      echo "$checkout: skipped: covered checkout origin identity drifted from $recorded_identity to $current_identity"
      return 1
    fi
    if [ "$lines" -eq 3 ] && [ "$recorded_physical" != "$current_physical" ]; then
      echo "$checkout: skipped: covered checkout physical identity drifted at $checkout"
      return 1
    fi
    return 0
  fi
  if [ "$current_identity" = no-origin ] && [ -e "$tip_file" ]; then
    echo "$checkout: skipped: covered checkout lost its previously tracked origin identity"
    return 1
  fi
  atomic_write "$identity_file" "$checkout" "$current_identity" "$current_physical" || {
    echo "$checkout: skipped: covered checkout identity cannot be persisted"
    return 1
  }
}

LOCAL_DEFAULT_BRANCH=
LOCAL_DEFAULT_TIP=
inspect_local_checkout() {
  local checkout=$1 status_raw default current head state untracked_count
  LOCAL_DEFAULT_BRANCH=
  LOCAL_DEFAULT_TIP=
  if ! status_raw=$(GIT_OPTIONAL_LOCKS=0 git -C "$checkout" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    echo "$checkout: skipped: local checkout cleanliness cannot be inspected"
    return 0
  fi
  default=$(local_default_branch "$checkout") || {
    echo "$checkout: skipped: local default branch cannot be determined"
    return 0
  }
  LOCAL_DEFAULT_BRANCH=$default
  LOCAL_DEFAULT_TIP=$(git -C "$checkout" rev-parse "refs/heads/$default^{commit}" 2>/dev/null) || {
    echo "$checkout: skipped: local default tip cannot be inspected"
    return 0
  }
  head=$(git -C "$checkout" rev-parse "HEAD^{commit}" 2>/dev/null) || {
    echo "$checkout: skipped: local checkout HEAD cannot be inspected"
    return 0
  }
  if current=$(git -C "$checkout" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    if [ "$current" = "$default" ]; then
      state="local default branch $default"
    else
      state="non-default branch $current"
    fi
  else
    current=
    state="detached HEAD"
  fi
  if [ -n "$status_raw" ]; then
    untracked_count=$(printf '%s\n' "$status_raw" | awk 'substr($0, 1, 3) == "?? " { count++ } END { print count + 0 }')
    echo "$checkout: STUCK: on $state with uncommitted changes ($untracked_count untracked) - needs attention"
    return 0
  fi
  if [ "$current" != "$default" ]; then
    if [ "$head" != "$LOCAL_DEFAULT_TIP" ]; then
      echo "$checkout: STUCK: on $state at stale local tip $head instead of local $default $LOCAL_DEFAULT_TIP - needs attention"
    else
      echo "$checkout: STUCK: on $state instead of local default branch $default - needs attention"
    fi
    return 0
  fi
  if [ "$head" != "$LOCAL_DEFAULT_TIP" ]; then
    echo "$checkout: STUCK: local default branch $default is stale at $head instead of $LOCAL_DEFAULT_TIP - needs attention"
    return 0
  fi
  echo "$checkout: already current at local $default"
}

run_once() {
  local force=0 verbose=0 session=0 scheduled=0 prune=0 arg lock discovery identities hygiene checkout key tip_file last_file alert_file
  local prior_tip previous_coverage retry_unhealthy now last due probe_ok output_file output line reinspected identity_output
  local state_persisted hygiene_failed=0 coverage_failed=0 status=0
  local coverage=healthy
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --verbose) verbose=1 ;;
      --session) session=1 ;;
      --scheduled) scheduled=1 ;;
      *) usage; return 2 ;;
    esac
  done
  [ "$session" -eq 0 ] || prune=1

  ensure_state_root || return 1
  previous_coverage=$(sed -n '2p' "$STATE_ROOT/coverage-health" 2>/dev/null || true)
  retry_unhealthy=1
  [ "$previous_coverage" != healthy ] || retry_unhealthy=0
  atomic_write "$STATE_ROOT/coverage-health" "$(date +%s)" running || return 1
  if ! fm_checkout_lock_prepare "$LOCK_ROOT"; then
    echo "error: unsafe checkout-refresh lock directory: $LOCK_ROOT" >&2
    record_run_result unhealthy "$scheduled" || true
    return 1
  fi
  lock="$STATE_ROOT/.run-lock"
  if ! fm_lock_try_acquire "$lock"; then
    printf 'checkout-refresh: skipped: refresh already running (pid %s)\n' "${FM_LOCK_HELD_PID:-unknown}"
    return 0
  fi
  trap 'fm_lock_release "$STATE_ROOT/.run-lock"' EXIT
  discovery=$(mktemp "$STATE_ROOT/.discover.XXXXXX") || {
    record_run_result unhealthy "$scheduled" || true
    return 1
  }
  identities=$(mktemp "$STATE_ROOT/.external-identities.XXXXXX") || {
    rm -f "$discovery"
    record_run_result unhealthy "$scheduled" || true
    return 1
  }
  manifest_create "$identities" || {
    rm -f "$discovery" "$identities"
    record_run_result unhealthy "$scheduled" || true
    return 1
  }
  hygiene=$(mktemp "$STATE_ROOT/.hygiene-discover.XXXXXX") || {
    rm -f "$discovery" "$identities"
    record_run_result unhealthy "$scheduled" || true
    return 1
  }
  DISCOVERY_IDENTITIES_FILE=$identities
  if ! discover > "$discovery"; then
    rm -f "$discovery" "$identities" "$hygiene"
    record_run_result unhealthy "$scheduled" || true
    return 1
  fi
  if ! validate_external_identity_history "$identities"; then
    rm -f "$discovery" "$identities" "$hygiene"
    record_run_result unhealthy "$scheduled" || true
    return 1
  fi
  if ! atomic_copy "$identities" "$STATE_ROOT/external-identities"; then
    rm -f "$discovery" "$identities" "$hygiene"
    record_run_result unhealthy "$scheduled" || true
    return 1
  fi
  if ! rm -f "$identities"; then
    rm -f "$discovery" "$hygiene" || true
    record_run_result unhealthy "$scheduled" || true
    return 1
  fi
  prepare_hygiene_discovery "$discovery" "$hygiene" || {
    rm -f "$discovery" "$hygiene"
    record_run_result unhealthy "$scheduled" || true
    return 1
  }
  now=$(date +%s)

  while IFS= read -r checkout; do
    [ -n "$checkout" ] || continue
    if ! reinspected=$(exact_git_root "$checkout") || [ "$reinspected" != "$checkout" ]; then
      record_reinspection_failure "$checkout" || status=1
      coverage_failed=1
      continue
    fi
    key=$(checkout_key "$checkout") || {
      echo "$checkout: skipped: checkout hygiene identity cannot be resolved" >&2
      coverage_failed=1
      status=1
      continue
    }
    if [ "$force" -eq 1 ] || [ "$verbose" -eq 1 ]; then
      surface_skill_drafts "$checkout" "$key" 1 || hygiene_failed=1
    else
      surface_skill_drafts "$checkout" "$key" 0 || hygiene_failed=1
    fi
  done < "$hygiene"
  clear_stale_hygiene_alerts "$hygiene" || {
    echo "checkout-refresh: skipped: stale hygiene alerts cannot be cleared" >&2
    hygiene_failed=1
  }

  while IFS= read -r checkout; do
    [ -n "$checkout" ] || continue
    if ! reinspected=$(exact_git_root "$checkout") || [ "$reinspected" != "$checkout" ]; then
      record_reinspection_failure "$checkout" || status=1
      coverage_failed=1
      continue
    fi
    key=$(checkout_key "$checkout") || {
      echo "$checkout: skipped: checkout refresh identity cannot be resolved" >&2
      coverage_failed=1
      status=1
      continue
    }
    tip_file="$STATE_ROOT/$key.tip"
    last_file="$STATE_ROOT/$key.last"
    alert_file="$STATE_ROOT/$key.alert"
    if ! inspect_checkout_origin "$checkout"; then
      output="$checkout: skipped: covered checkout origin identity cannot be inspected"
      printf '%s\n' "$output"
      if ! record_alert "$alert_file" "$checkout" "$output"; then
        printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
        status=1
      fi
      coverage_failed=1
      continue
    fi
    if ! identity_output=$(validate_covered_checkout_identity "$checkout" "$key" "$tip_file"); then
      [ -n "$identity_output" ] || identity_output="$checkout: skipped: covered checkout identity validation failed"
      printf '%s\n' "$identity_output"
      if ! record_alert "$alert_file" "$checkout" "$identity_output"; then
        printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
        status=1
      fi
      coverage_failed=1
      continue
    fi
    if ! resolve_checkout_refresh_authority "$checkout"; then
      output="$checkout: skipped: checkout refresh authority cannot be determined"
      printf '%s\n' "$output"
      if ! record_alert "$alert_file" "$checkout" "$output"; then
        printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
        status=1
      fi
      coverage_failed=1
      continue
    fi
    last=$(read_epoch "$last_file")
    due=0
    probe_ok=1
    if [ "$CHECKOUT_REFRESH_AUTHORITY" = local ]; then
      due=1
    else
      [ "$retry_unhealthy" -eq 0 ] || due=1
      [ "$force" -eq 0 ] || due=1
      [ "$((now - last))" -lt "$BACKSTOP" ] || due=1
      probe_ok=0
      if probe_upstream "$checkout"; then
        probe_ok=1
        prior_tip=$(sed -n '1,2p' "$tip_file" 2>/dev/null || true)
        [ "$prior_tip" = "$PROBE_BRANCH"$'\n'"$PROBE_TIP" ] || due=1
      else
        due=1
      fi
    fi
    if [ "$due" -eq 0 ]; then
      if [ -e "$alert_file" ] || [ -L "$alert_file" ]; then
        coverage_failed=1
        if [ ! -f "$alert_file" ] || [ -L "$alert_file" ]; then
          printf '%s: skipped: checkout alert state is unsafe\n' "$checkout"
          status=1
        fi
      fi
      continue
    fi

    output_file=$(mktemp "$STATE_ROOT/.sync.XXXXXX") || {
      output="$checkout: skipped: cannot allocate refresh output"
      printf '%s\n' "$output"
      if ! record_alert "$alert_file" "$checkout" "$output"; then
        printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
        status=1
      fi
      coverage_failed=1
      continue
    }
    if [ "$CHECKOUT_REFRESH_AUTHORITY" = local ]; then
      inspect_local_checkout "$checkout" > "$output_file"
    elif [ "$probe_ok" -eq 1 ]; then
      sync_checkout "$checkout" "$output_file" "$prune"
    else
      printf '%s: skipped: cannot probe live upstream default branch\n' "$checkout" > "$output_file"
    fi
    output=$(cat "$output_file")
    rm -f "$output_file"

    case "$output" in
      *': STUCK:'*|*': skipped:'*)
        printf '%s\n' "$output"
        if ! record_alert "$alert_file" "$checkout" "$output"; then
          printf '%s: skipped: checkout alert cannot be persisted\n' "$checkout"
          status=1
        fi
        coverage_failed=1
        ;;
      *)
        state_persisted=1
        if ! rm -f "$alert_file"; then
          printf '%s: skipped: checkout alert cannot be cleared\n' "$checkout"
          state_persisted=0
        elif [ "$CHECKOUT_REFRESH_AUTHORITY" = local ]; then
          if [ -z "$LOCAL_DEFAULT_BRANCH" ] || [ -z "$LOCAL_DEFAULT_TIP" ] \
            || ! atomic_write "$tip_file" "$LOCAL_DEFAULT_BRANCH" "$LOCAL_DEFAULT_TIP"; then
            printf '%s: skipped: local checkout tip state cannot be persisted\n' "$checkout"
            state_persisted=0
          fi
        elif [ "$probe_ok" -eq 1 ] \
          && ! atomic_write "$tip_file" "$PROBE_BRANCH" "$PROBE_TIP"; then
          printf '%s: skipped: upstream checkout tip state cannot be persisted\n' "$checkout"
          state_persisted=0
        fi
        if [ "$state_persisted" -eq 1 ] && ! atomic_write "$last_file" "$now"; then
          printf '%s: skipped: checkout cadence state cannot be persisted\n' "$checkout"
          state_persisted=0
        fi
        if [ "$state_persisted" -eq 0 ]; then
          coverage_failed=1
          status=1
        elif [ "$verbose" -eq 1 ]; then
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

  if ! rm -f "$discovery" "$hygiene"; then
    coverage_failed=1
    status=1
  fi
  if [ "$hygiene_failed" -ne 0 ]; then
    coverage_failed=1
    status=1
  fi
  [ "$coverage_failed" -eq 0 ] || coverage=unhealthy
  record_run_result "$coverage" "$scheduled" || status=1
  trap - EXIT
  fm_lock_release "$lock"
  return "$status"
}

preflight() {
  local checkout=$1 output key output_file tip_file identity_output hygiene_found=0 canonical
  canonical=$(require_exact_git_root "$checkout" "checkout-refresh preflight target") || return 1
  checkout=$canonical
  ensure_lock_roots || return 1
  key=$(checkout_key "$checkout") || {
    echo "error: checkout-refresh preflight identity is unavailable for $checkout" >&2
    return 1
  }
  tip_file="$STATE_ROOT/$key.tip"
  surface_skill_drafts "$checkout" "$key" 1 || return 1
  hygiene_found=$HYGIENE_FOUND
  output_file=$(mktemp "$STATE_ROOT/.preflight.XXXXXX") || return 1
  if ! inspect_checkout_origin "$checkout"; then
    rm -f "$output_file"
    echo "$checkout: skipped: covered checkout origin identity cannot be inspected"
    return 1
  fi
  if ! identity_output=$(validate_covered_checkout_identity "$checkout" "$key" "$tip_file"); then
    rm -f "$output_file"
    [ -n "$identity_output" ] || identity_output="$checkout: skipped: covered checkout identity validation failed"
    printf '%s\n' "$identity_output"
    return 1
  fi
  if ! resolve_checkout_refresh_authority "$checkout"; then
    rm -f "$output_file"
    echo "$checkout: skipped: checkout refresh authority cannot be determined"
    return 1
  fi
  if [ "$CHECKOUT_REFRESH_AUTHORITY" = local ]; then
    inspect_local_checkout "$checkout" > "$output_file"
  else
    if probe_upstream "$checkout"; then
      sync_checkout "$checkout" "$output_file" 0
    else
      printf '%s: skipped: cannot probe live upstream default branch\n' "$checkout" > "$output_file"
    fi
  fi
  output=$(cat "$output_file")
  rm -f "$output_file"
  printf '%s\n' "$output"
  [ "$hygiene_found" -eq 0 ] || return 1
  case "$output" in *': STUCK:'*|*': skipped:'*) return 1 ;; esac
  return 0
}

pool_preflight() {
  local expected_source=$1 expected_common treehouse_paths treehouse_state pool worktree canonical common dirty example failed=0
  expected_source=$(require_exact_git_root "$expected_source" "expected Treehouse source") || return 1
  expected_common=$(fm_checkout_git_common_dir "$expected_source") || {
    echo "error: cannot resolve expected Treehouse repository identity for $expected_source" >&2
    return 1
  }
  treehouse_paths=$(mktemp "${TMPDIR:-/tmp}/fm-checkout-refresh-pool.XXXXXX") || return 1
  if ! treehouse_worktree_paths > "$treehouse_paths"; then
    rm -f "$treehouse_paths"
    return 1
  fi
  while IFS=$'\t' read -r treehouse_state pool worktree; do
    [ -n "$worktree" ] || continue
    backing_checkout "$worktree" "$pool" "$treehouse_state" >/dev/null 2>&1 || {
      echo "checkout-refresh: skipped: Treehouse worktree identity or registration is not inspectable: $worktree" >&2
      failed=1
      continue
    }
    canonical=$(exact_git_root "$worktree" 2>/dev/null) || {
      echo "checkout-refresh: skipped: Treehouse worktree is not an exact Git root: $worktree" >&2
      failed=1
      continue
    }
    common=$(fm_checkout_git_common_dir "$canonical") || {
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
  local worktree=$1 expected_source=$2 dirty dirty_example worktree_common source_common canonical
  local worktree_origin source_origin branch
  canonical=$(require_exact_git_root "$worktree" "worktree freshness target") || return 1
  worktree=$canonical
  canonical=$(require_exact_git_root "$expected_source" "expected worktree source") || return 1
  expected_source=$canonical
  if ! dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    echo "error: acquired worktree safety cannot be inspected at $worktree; retain it for manual recovery" >&2
    return 3
  fi
  if [ -n "$dirty" ]; then
    dirty_example=$(first_line "$dirty")
    echo "error: acquired worktree is dirty at $worktree; retain it for manual recovery without reset, clean, stash, or forced return ($dirty_example)" >&2
    return 3
  fi
  worktree_common=$(fm_checkout_git_common_dir "$worktree") || {
    echo "error: cannot resolve acquired worktree repository identity for $worktree" >&2
    return 1
  }
  source_common=$(fm_checkout_git_common_dir "$expected_source") || {
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

remote_identity() {
  local checkout=$1 remote=$2 candidate
  case "$remote" in
    file://*) candidate=${remote#file://} ;;
    /*|./*|../*) candidate=$remote ;;
    *) printf 'remote:%s\n' "$remote"; return 0 ;;
  esac
  case "$candidate" in
    /*) ;;
    *) candidate="$checkout/$candidate" ;;
  esac
  candidate=$(canonical_dir "$candidate" 2>/dev/null) || return 1
  printf 'path:%s\n' "$candidate"
}

verify_home() {
  local home=$1 expected_source=$2 canonical dirty home_common source_common home_origin source_origin
  local home_identity source_identity source_path_identity default branch tip head expected
  canonical=$(require_exact_git_root "$home" "secondmate home freshness target") || return 1
  home=$canonical
  canonical=$(require_exact_git_root "$expected_source" "expected secondmate source") || return 1
  expected_source=$canonical
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$home" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    echo "error: secondmate home cleanliness cannot be inspected at $home" >&2
    return 1
  }
  [ -z "$dirty" ] || {
    echo "error: secondmate home is dirty at $home; retain it for manual recovery" >&2
    return 1
  }
  home_common=$(fm_checkout_git_common_dir "$home") || return 1
  source_common=$(fm_checkout_git_common_dir "$expected_source") || return 1
  if [ "$home_common" != "$source_common" ]; then
    home_origin=$(origin_url "$home" || true)
    source_origin=$(origin_url "$expected_source" || true)
    [ -n "$home_origin" ] || {
      echo "error: secondmate home origin is unavailable at $home" >&2
      return 1
    }
    home_identity=$(remote_identity "$home" "$home_origin") || return 1
    source_path_identity="path:$expected_source"
    source_identity=
    [ -z "$source_origin" ] || source_identity=$(remote_identity "$expected_source" "$source_origin") || return 1
    if [ "$home_identity" != "$source_path_identity" ] && [ "$home_identity" != "$source_identity" ]; then
      echo "error: secondmate home repository identity does not match $expected_source" >&2
      return 1
    fi
  fi
  source_origin=$(origin_url "$expected_source" || true)
  if [ -n "$source_origin" ]; then
    probe_upstream "$expected_source" || {
      echo "error: cannot verify the live upstream default-branch tip for $expected_source" >&2
      return 1
    }
    branch=$PROBE_BRANCH
    tip=$PROBE_TIP
    expected="origin/$branch"
  else
    branch=$(local_default_branch "$expected_source") || {
      echo "error: cannot determine the local default branch for $expected_source" >&2
      return 1
    }
    tip=$(git -C "$expected_source" rev-parse "refs/heads/$branch^{commit}" 2>/dev/null) || return 1
    expected="local $branch"
  fi
  if default=$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    [ "$default" = "$branch" ] || {
      echo "error: secondmate home is on non-default branch $default at $home" >&2
      return 1
    }
  fi
  head=$(git -C "$home" rev-parse HEAD 2>/dev/null) || return 1
  [ "$head" = "$tip" ] || {
    echo "error: secondmate home is stale: HEAD $head does not match $expected $tip" >&2
    return 1
  }
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
  grep -Fq "<key>Label</key><string>$(xml_escape "$LEGACY_LABEL")</string>" "$legacy_plist" || return 1
  grep -Fq "<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>" "$legacy_plist" || return 0
  if ! grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME_CANONICAL")</string>" "$legacy_plist" \
    && ! grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME")</string>" "$legacy_plist"; then
    return 0
  fi
  "$LAUNCHCTL" bootout "$domain/$LEGACY_LABEL" >/dev/null 2>&1 || true
  rm -f "$legacy_plist"
}

physical_launch_agent_matches_home() {
  [ "$PHYSICAL_LABEL" != "$LABEL" ] || return 1
  [ -f "$PHYSICAL_PLIST" ] && [ ! -L "$PHYSICAL_PLIST" ] || return 1
  grep -Fq "<key>Label</key><string>$(xml_escape "$PHYSICAL_LABEL")</string>" "$PHYSICAL_PLIST" \
    && grep -Fq "<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>" "$PHYSICAL_PLIST" \
    && grep -Fq '<string>--scheduled</string>' "$PHYSICAL_PLIST" \
    && grep -Fq "<key>FM_HOME</key><string>$(xml_escape "$FM_HOME_CANONICAL")</string>" "$PHYSICAL_PLIST" \
    && grep -Fq "<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$(xml_escape "$PHYSICAL_STATE_ROOT")</string>" "$PHYSICAL_PLIST"
}

validate_launch_agent_namespaces() {
  [ "$PHYSICAL_LABEL" != "$LABEL" ] || return 0
  if { [ -e "$PLIST" ] || [ -L "$PLIST" ]; } \
    && { [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; } \
    && [ "$HOME_MIGRATION_ACTIVE" -ne 1 ]; then
    echo "error: ambiguous logical and physical checkout-refresh LaunchAgents for $FM_HOME_CANONICAL" >&2
    return 1
  fi
  if [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; then
    physical_launch_agent_matches_home || {
      echo "error: unsafe or mismatched physical checkout-refresh LaunchAgent at $PHYSICAL_PLIST" >&2
      return 1
    }
  fi
}

remove_matching_physical_launch_agent() {
  local domain=$1
  [ "$PHYSICAL_LABEL" != "$LABEL" ] || return 0
  [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ] || return 0
  physical_launch_agent_matches_home || return 1
  "$LAUNCHCTL" bootout "$domain/$PHYSICAL_LABEL" >/dev/null 2>&1 || true
  rm -f "$PHYSICAL_PLIST"
}

launch_agent_environment_value() {
  python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, requested = sys.argv[1:]
try:
    document = ET.parse(path)
    root = document.getroot().find("dict")
    if root is None:
        raise ValueError
    children = list(root)
    values = {}
    for index in range(0, len(children), 2):
        if index + 1 >= len(children) or children[index].tag != "key":
            raise ValueError
        key = children[index].text
        if not key or key in values:
            raise ValueError
        values[key] = children[index + 1]
    environment = values.get("EnvironmentVariables")
    if environment is None or environment.tag != "dict":
        raise ValueError
    children = list(environment)
    values = {}
    for index in range(0, len(children), 2):
        if index + 1 >= len(children) or children[index].tag != "key":
            raise ValueError
        key = children[index].text
        value = children[index + 1]
        if not key or key in values:
            raise ValueError
        values[key] = value
    value = values.get(requested)
    if value is None or value.tag != "string" or value.text is None:
        raise ValueError
    print(value.text)
except (ET.ParseError, OSError, ValueError):
    raise SystemExit(1)
PY
}

wait_for_scheduler_generation() {
  local generation deadline recorded
  generation=$(launch_agent_environment_value "$PLIST" FM_CHECKOUT_REFRESH_GENERATION) || return 1
  deadline=$(( $(date +%s) + ACTIVATION_TIMEOUT ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if [ -f "$STATE_ROOT/scheduler-generation" ] \
        && [ ! -L "$STATE_ROOT/scheduler-generation" ]; then
      recorded=$(sed -n '1p' "$STATE_ROOT/scheduler-generation" 2>/dev/null || true)
      [ "$recorded" != "$generation" ] || return 0
    fi
    sleep 1
  done
  echo "checkout-refresh active scheduler generation did not complete before activation timeout" >&2
  return 1
}

generate_scheduler_generation() {
  local token_seed token
  token_seed=$(mktemp "$STATE_ROOT/.scheduler-generation.XXXXXX") || return 1
  token=$(fm_checkout_hash_value \
    "$LABEL:$STATE_ROOT:$$:$(date +%s):${RANDOM:-0}:$token_seed" 32) || {
    rm -f "$token_seed"
    return 1
  }
  rm -f "$token_seed" || return 1
  printf '%s\n' "$token"
}

install_launch_agent() {
  local bash_runtime python_runtime perl_runtime runtime_path temp previous domain generation
  [ "$PLATFORM" = Darwin ] || {
    echo "error: checkout-refresh background installation currently requires macOS" >&2
    return 1
  }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  validate_launch_agent_namespaces || return 1
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
  generation=$(generate_scheduler_generation) || return 1
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
<string>--scheduled</string>
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
<key>FM_CHECKOUT_REFRESH_GENERATION</key><string>$generation</string>
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
    if [ "$HOME_MIGRATION_ACTIVE" -ne 1 ]; then
      remove_matching_physical_launch_agent "$domain" || return 1
      remove_matching_legacy_launch_agent "$domain" || return 1
    fi
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
  local domain heartbeat coverage_epoch coverage now max_age generation recorded_generation generation_lines installed=0
  [ "$PLATFORM" = Darwin ] || return 0
  validate_launch_agent_namespaces || return 1
  if [ ! -e "$PLIST" ] && [ ! -L "$PLIST" ] \
    && { [ -e "$PHYSICAL_PLIST" ] || [ -L "$PHYSICAL_PLIST" ]; }; then
    install_launch_agent || return 1
    installed=1
  fi
  [ "$installed" -eq 0 ] || wait_for_scheduler_generation || return 1
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "checkout-refresh LaunchAgent is not installed" >&2; return 1; }
  grep -Fq "<key>Label</key><string>$(xml_escape "$LABEL")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent Label identity drifted" >&2; return 1; }
  grep -Fq "<string>$(xml_escape "$SCRIPT_DIR/fm-checkout-refresh.sh")</string>" "$PLIST" \
    || { echo "checkout-refresh LaunchAgent points at a different Firstmate checkout" >&2; return 1; }
  grep -Fq '<string>--scheduled</string>' "$PLIST" \
    || { echo "checkout-refresh LaunchAgent does not own scheduler liveness" >&2; return 1; }
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
  generation=$(launch_agent_environment_value "$PLIST" FM_CHECKOUT_REFRESH_GENERATION) \
    || { echo "checkout-refresh LaunchAgent has no authoritative scheduler generation" >&2; return 1; }
  case "$generation" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#generation}" -eq 32 ] \
    || { echo "checkout-refresh LaunchAgent scheduler generation is malformed" >&2; return 1; }
  domain="gui/$(id -u)"
  "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null 2>&1 \
    || { echo "checkout-refresh LaunchAgent is not loaded" >&2; return 1; }
  heartbeat=$(read_epoch "$STATE_ROOT/heartbeat")
  now=$(date +%s)
  max_age=$((INTERVAL * 3 + 30))
  [ "$heartbeat" -gt 0 ] && [ "$((now - heartbeat))" -le "$max_age" ] \
    || { echo "checkout-refresh heartbeat is stale or missing" >&2; return 1; }
  coverage_epoch=$(read_epoch "$STATE_ROOT/coverage-health")
  coverage=$(sed -n '2p' "$STATE_ROOT/coverage-health" 2>/dev/null || true)
  [ "$coverage_epoch" -gt 0 ] && [ "$coverage" = healthy ] \
    || {
      echo "checkout-refresh latest coverage run is missing or unhealthy; inspect $STATE_ROOT for checkout alerts and scheduler diagnostics" >&2
      return 1
    }
  [ -f "$STATE_ROOT/scheduler-generation" ] \
    && [ ! -L "$STATE_ROOT/scheduler-generation" ] \
    && [ -r "$STATE_ROOT/scheduler-generation" ] \
    || { echo "checkout-refresh active scheduler generation has not completed a run" >&2; return 1; }
  generation_lines=$(awk 'END { print NR + 0 }' "$STATE_ROOT/scheduler-generation") || return 1
  recorded_generation=$(sed -n '1p' "$STATE_ROOT/scheduler-generation") || return 1
  [ "$generation_lines" -eq 1 ] && [ "$recorded_generation" = "$generation" ] \
    || { echo "checkout-refresh active scheduler generation has not completed a run" >&2; return 1; }
}

scheduler_install() {
  local status
  case "$PLATFORM" in
    Darwin)
      if install_launch_agent \
        && { [ "$HOME_MIGRATION_ACTIVE" -ne 1 ] || wait_for_scheduler_generation; } \
        && { [ "$HOME_MIGRATION_ACTIVE" -ne 1 ] || ensure_launch_agent; } \
        && commit_home_state_namespace_migration; then
        return 0
      else
        status=$?
      fi
      rollback_home_state_namespace_migration || true
      return "$status"
      ;;
    Linux)
      echo "error: checkout-refresh has no Linux scheduler adapter yet; use run-once from cron or systemd until one is implemented" >&2
      rollback_home_state_namespace_migration || true
      return 1
      ;;
    *)
      echo "error: checkout-refresh has no scheduler adapter for $PLATFORM" >&2
      rollback_home_state_namespace_migration || true
      return 1
      ;;
  esac
}

scheduler_ensure() {
  local status
  case "$PLATFORM" in
    Darwin)
      if ensure_launch_agent && commit_home_state_namespace_migration; then
        return 0
      else
        status=$?
      fi
      rollback_home_state_namespace_migration || true
      return "$status"
      ;;
    Linux)
      echo "error: checkout-refresh has no Linux scheduler adapter yet" >&2
      rollback_home_state_namespace_migration || true
      return 1
      ;;
    *)
      echo "error: checkout-refresh has no scheduler adapter for $PLATFORM" >&2
      rollback_home_state_namespace_migration || true
      return 1
      ;;
  esac
}

prepare_home_state_namespace "${1:-}" || exit 1

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
  verify-home)
    [ $# -eq 3 ] || { usage; exit 2; }
    verify_home "$2" "$3"
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
