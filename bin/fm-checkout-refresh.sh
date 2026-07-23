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
# A changed tip triggers an immediate safe refresh.
# FM_CHECKOUT_REFRESH_BACKSTOP seconds without a refresh triggers one anyway, so
# missed signals and lost state remain bounded.
# The per-user LaunchAgent installed by `install` runs this probe every
# FM_CHECKOUT_REFRESH_INTERVAL seconds while Firstmate is idle.
#
# Every refresh delegates to fm-fleet-sync.sh with pruning disabled.
# Dirty, diverged, non-default, and otherwise unsafe checkouts remain untouched
# and are recorded as durable alerts.
# Every probe also inventories untracked files in both the covered seed
# checkouts and the Treehouse pool worktrees under repository skill directories
# (`.agents/skills`, `.claude/skills`, `.codex/skills`, and `skills`).
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
#   fm-checkout-refresh.sh run-once [--force] [--verbose]
#   fm-checkout-refresh.sh preflight <checkout>
#   fm-checkout-refresh.sh verify-worktree <worktree>
#   fm-checkout-refresh.sh ensure
#   fm-checkout-refresh.sh install
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="${FM_CHECKOUT_REFRESH_CONFIG:-$CONFIG/checkout-refresh}"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"
STATE_ROOT="${FM_CHECKOUT_REFRESH_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
INTERVAL=${FM_CHECKOUT_REFRESH_INTERVAL:-60}
BACKSTOP=${FM_CHECKOUT_REFRESH_BACKSTOP:-900}
PROBE_TIMEOUT=${FM_CHECKOUT_REFRESH_PROBE_TIMEOUT:-15}
SYNC_TIMEOUT=${FM_CHECKOUT_REFRESH_SYNC_TIMEOUT:-60}
PLATFORM=${FM_CHECKOUT_REFRESH_PLATFORM:-$(uname)}
LABEL=${FM_CHECKOUT_REFRESH_LABEL:-com.firstmate.checkout-refresh}
LAUNCH_AGENTS_DIR=${FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LAUNCHCTL=${FM_CHECKOUT_REFRESH_LAUNCHCTL:-launchctl}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$BACKSTOP" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_BACKSTOP must be a positive integer" >&2; exit 2 ;; esac
case "$PROBE_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_PROBE_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
case "$SYNC_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_CHECKOUT_REFRESH_SYNC_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac

usage() {
  echo "usage: fm-checkout-refresh.sh discover|run-once [--force] [--verbose]|preflight <checkout>|verify-worktree <worktree>|ensure|install" >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

expand_config_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    "\$HOME") printf '%s\n' "$HOME" ;;
    "\$HOME/"*) printf '%s/%s\n' "$HOME" "${1#\$HOME/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) echo "checkout-refresh: skipped config path '$1': paths must be absolute, ~/..., or \$HOME/..." >&2; return 1 ;;
  esac
}

config_values() {
  local wanted=$1 line directive value
  [ -f "$CONFIG_FILE" ] || return 0
  [ ! -L "$CONFIG_FILE" ] || {
    echo "checkout-refresh: skipped unsafe symlink config $CONFIG_FILE" >&2
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in ""|\#*) continue ;; esac
    directive=${line%%[[:space:]]*}
    if [ "$directive" = "$line" ]; then
      echo "checkout-refresh: skipped malformed config directive '$line'" >&2
      continue
    fi
    value=${line#"$directive"}
    value=$(printf '%s\n' "$value" | sed 's/^[[:space:]]*//')
    case "$directive" in
      path|scan)
        [ "$directive" = "$wanted" ] || continue
        expand_config_path "$value" || true
        ;;
      *) echo "checkout-refresh: skipped unknown config directive '$directive'" >&2 ;;
    esac
  done < "$CONFIG_FILE"
}

treehouse_worktree_paths() {
  [ -d "$TREEHOUSE_ROOT" ] || return 0
  command -v python3 >/dev/null 2>&1 || {
    echo "checkout-refresh: cannot discover Treehouse pools because python3 is unavailable" >&2
    return 0
  }
  python3 - "$TREEHOUSE_ROOT" <<'PY'
import glob
import json
import os
import sys

for state_path in sorted(glob.glob(os.path.join(sys.argv[1], "*", "treehouse-state.json"))):
    try:
        with open(state_path, encoding="utf-8") as stream:
            state = json.load(stream)
        for entry in state.get("worktrees", []):
            path = entry.get("path")
            if isinstance(path, str) and path:
                print(path)
    except (OSError, ValueError, TypeError):
        continue
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
  local tmp seeds origins scans path project worktree main root candidate url
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-checkout-refresh-discover.XXXXXX") || return 1
  seeds="$tmp/seeds"
  origins="$tmp/origins"
  scans="$tmp/scans"
  : > "$seeds"
  : > "$origins"
  : > "$scans"

  if [ -d "$PROJECTS" ]; then
    for project in "$PROJECTS"/*; do
      [ -d "$project" ] || continue
      canonical_dir "$project" >> "$seeds" 2>/dev/null || true
    done
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if main=$(canonical_dir "$path" 2>/dev/null); then
      printf '%s\n' "$main" >> "$seeds"
    else
      echo "checkout-refresh: skipped configured checkout that is not a directory: $path" >&2
    fi
  done < <(config_values path)

  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    if main=$(backing_checkout "$worktree" 2>/dev/null); then
      printf '%s\n' "$main" >> "$seeds"
    fi
  done < <(treehouse_worktree_paths)

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
      echo "checkout-refresh: skipped configured scan root that is not a directory: $root" >&2
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

run_bounded() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=1 "$seconds" "$@"
  else
    # shellcheck disable=SC2016
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  fi
}

PROBE_BRANCH=
PROBE_TIP=
probe_upstream() {
  local checkout=$1 out line ref
  PROBE_BRANCH=
  PROBE_TIP=
  out=$(run_bounded "$PROBE_TIMEOUT" git -C "$checkout" ls-remote --symref origin HEAD 2>/dev/null) || return 1
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
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,24)}'
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

skill_draft_inventory() {
  local checkout=$1
  git -C "$checkout" ls-files --others --exclude-standard -- \
    .agents/skills .claude/skills .codex/skills skills 2>/dev/null \
    | LC_ALL=C sort
}

# Surface a changed untracked-skill inventory on the ordinary 60-second probe,
# not only when an upstream tip changes or the 15-minute refresh is due.
# The inventory is intentionally path-only: it detects accumulation without
# reading, copying, stashing, or otherwise touching a draft's content.
surface_skill_drafts() {
  local checkout=$1 key=$2 repeat=${3:-0}
  local inventory alert prior signature count examples message
  inventory=$(mktemp "$STATE_ROOT/.hygiene-inventory.XXXXXX") || return 1
  alert="$STATE_ROOT/$key.hygiene-alert"
  skill_draft_inventory "$checkout" > "$inventory"
  if [ ! -s "$inventory" ]; then
    rm -f "$inventory" "$alert"
    return 0
  fi

  signature=$(shasum -a 256 "$inventory" | awk '{print $1}')
  count=$(awk 'END { print NR + 0 }' "$inventory")
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
  local seed_file=$1 hygiene_file=$2 worktree canonical
  cp "$seed_file" "$hygiene_file" || return 1
  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    if canonical=$(canonical_dir "$worktree" 2>/dev/null); then
      printf '%s\n' "$canonical" >> "$hygiene_file"
    fi
  done < <(treehouse_worktree_paths)
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
  local checkout=$1 output_file=$2 status
  if FM_FLEET_PRUNE=0 run_bounded "$SYNC_TIMEOUT" "$SCRIPT_DIR/fm-fleet-sync.sh" "$checkout" > "$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 124 ]; then
    printf '%s: skipped: refresh timed out after %ss\n' "$checkout" "$SYNC_TIMEOUT" > "$output_file"
  elif [ "$status" -ne 0 ]; then
    printf '%s: skipped: refresh failed with exit %s\n' "$checkout" "$status" >> "$output_file"
  fi
}

record_alert() {
  local alert=$1 checkout=$2 output=$3
  atomic_write "$alert" "$checkout" "$(date +%s)" "$(first_line "$output")"
}

run_once() {
  local force=0 verbose=0 arg lock discovery hygiene checkout key tip_file last_file alert_file
  local prior_tip now last due probe_ok output_file output line
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --verbose) verbose=1 ;;
      *) usage; return 2 ;;
    esac
  done

  ensure_state_root || return 1
  lock="$STATE_ROOT/.run-lock"
  if ! mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  discovery=$(mktemp "$STATE_ROOT/.discover.XXXXXX") || return 1
  hygiene=$(mktemp "$STATE_ROOT/.hygiene-discover.XXXXXX") || { rm -f "$discovery"; return 1; }
  discover > "$discovery"
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
      surface_skill_drafts "$checkout" "$key" 1
    else
      surface_skill_drafts "$checkout" "$key" 0
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
    sync_checkout "$checkout" "$output_file"
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
  atomic_write "$STATE_ROOT/heartbeat" "$now" "$SCRIPT_DIR/fm-checkout-refresh.sh"
  trap - EXIT
  rmdir "$lock" 2>/dev/null || true
}

preflight() {
  local checkout=$1 output key output_file
  [ -d "$checkout" ] || { echo "error: checkout-refresh preflight target is not a directory: $checkout" >&2; return 1; }
  ensure_state_root || return 1
  key=$(checkout_key "$checkout")
  surface_skill_drafts "$checkout" "$key" 1
  output_file=$(mktemp "$STATE_ROOT/.preflight.XXXXXX") || return 1
  sync_checkout "$checkout" "$output_file"
  output=$(cat "$output_file")
  rm -f "$output_file"
  printf '%s\n' "$output"
  case "$output" in *': STUCK:'*|*': skipped: fetch failed'*|*': skipped: refresh '*) return 1 ;; esac
  return 0
}

verify_worktree() {
  local worktree=$1 head
  [ -d "$worktree" ] || { echo "error: worktree freshness target is not a directory: $worktree" >&2; return 1; }
  git -C "$worktree" remote get-url origin >/dev/null 2>&1 || return 0
  probe_upstream "$worktree" || {
    echo "error: cannot verify the upstream default-branch tip for $worktree" >&2
    return 1
  }
  head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || return 1
  if [ "$head" != "$PROBE_TIP" ]; then
    echo "error: acquired worktree is stale: HEAD $head does not match origin/$PROBE_BRANCH $PROBE_TIP" >&2
    return 1
  fi
  return 0
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

install_launch_agent() {
  local bash_runtime python_runtime runtime_path temp previous domain
  [ "$PLATFORM" = Darwin ] || {
    echo "error: checkout-refresh background installation currently requires macOS" >&2
    return 1
  }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  bash_runtime=$(command -v bash) || return 1
  python_runtime=$(command -v python3) || return 1
  case "$bash_runtime" in /*) ;; *) echo "error: cannot resolve an absolute Bash runtime" >&2; return 1 ;; esac
  runtime_path="$(dirname "$python_runtime"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$LAUNCH_AGENTS_DIR" "$STATE_ROOT" || return 1
  [ -d "$LAUNCH_AGENTS_DIR" ] && [ ! -L "$LAUNCH_AGENTS_DIR" ] \
    && [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
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
<key>FM_HOME</key><string>$(xml_escape "$FM_HOME")</string>
<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$(xml_escape "$STATE_ROOT")</string>
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
  domain="gui/$(id -u)"
  "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null 2>&1 \
    || { echo "checkout-refresh LaunchAgent is not loaded" >&2; return 1; }
  heartbeat=$(read_epoch "$STATE_ROOT/heartbeat")
  now=$(date +%s)
  max_age=$((INTERVAL * 3 + 30))
  [ "$heartbeat" -gt 0 ] && [ "$((now - heartbeat))" -le "$max_age" ] \
    || { echo "checkout-refresh heartbeat is stale or missing" >&2; return 1; }
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
  verify-worktree)
    [ $# -eq 2 ] || { usage; exit 2; }
    verify_worktree "$2"
    ;;
  ensure)
    [ $# -eq 1 ] || { usage; exit 2; }
    ensure_launch_agent
    ;;
  install)
    [ $# -eq 1 ] || { usage; exit 2; }
    install_launch_agent
    ;;
  *) usage; exit 2 ;;
esac
