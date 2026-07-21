#!/usr/bin/env bash
# Read-only inventory of fleet tooling versions: installed binaries, locked
# nixpkgs harness package versions from the captain's dotfiles flake, agentic
# pin status (via the dotfiles check script), and fail-soft upstream tips.
#
# Ownership
#   This script owns the inventory contract and exit codes below. It never
#   mutates the system, flake.lock, pins, or installed packages.
#   Agentic pin semantics stay in the dotfiles project
#   (scripts/agentic-tools-check-updates.sh and its lib). Call that script; do
#   not reimplement pin styles, lock parsing, or remote tip rules for agentic
#   tools.
#   Harness CLIs (claude-code, codex, grok-build, opencode, pi-coding-agent)
#   come from the nixpkgs pin in the same flake, not from agentic-tools-bump.
#
# Tools in scope
#   Harness (installed + locked nixpkgs + upstream tip):
#     claude   -> package claude-code; upstream npm @anthropic-ai/claude-code
#     codex    -> package codex; upstream GitHub openai/codex stable release
#     grok     -> package grok-build; upstream only via nixpkgs when no public
#                 stable channel is known (documented as unknown when tip missing)
#     opencode -> package opencode; upstream GitHub anomalyco/opencode stable
#     pi       -> package pi-coding-agent; upstream GitHub badlogic/pi-mono stable
#   Agentic (delegated when the check script is present):
#     firstmate, no-mistakes, treehouse, gh-axi, chrome-devtools-axi,
#     tasks-axi, quota-axi, lavish-axi
#   Also prints installed no-mistakes version on the harness table for quick
#   comparison with the agentic pin section.
#
# Dotfiles resolution (first match wins)
#   1. --dotfiles PATH
#   2. FM_DOTFILES env
#   3. $FM_HOME/projects/dotfiles when FM_HOME is set
#   4. <this-script>/../projects/dotfiles when that path exists (rare)
#
# Classification (STATUS column)
#   current  installed (or pin) matches upstream tip
#   behind   installed (or pin) is older than upstream tip
#   ahead    installed is newer than the known tip
#   unknown  tip or pin not available without a hard failure
#   error    probe or parse failed (offline, missing tool, bad output)
#
# Exit codes (agentic-tools-check spirit)
#   0  all compared rows current or soft-unknown; no hard errors
#   1  one or more rows behind
#   2  usage error
#   3  partial offline / hard probe failure for one or more rows
#      (takes precedence over 1 when any error row exists)
#
# Usage: fm-tool-versions.sh [options]
#   -h, --help              show this help
#   --dotfiles PATH         path to the dotfiles project (flake.nix root)
#   --installed-only        skip locked nixpkgs eval, agentic check, and network
#   --no-network            skip upstream harness probes (locked + installed only)
#   --skip-agentic          do not invoke agentic-tools-check-updates.sh
#   --skip-nix              do not evaluate locked nixpkgs package versions
#   --include-prerelease    prefer latest GitHub release including pre-releases
#   --json                  reserved; not implemented (exit 2 if passed)
#
# Environment
#   FM_HOME, FM_DOTFILES, FM_ROOT_OVERRIDE - path resolution
#   FM_TOOL_VERSIONS_NIX, FM_TOOL_VERSIONS_NPM, FM_TOOL_VERSIONS_GH - override
#     the nix / npm / gh binaries used for probes (tests inject fakes here)
#   NIX_CONFIG - when unset, this script sets experimental-features for nix-command flakes
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

NIX_BIN="${FM_TOOL_VERSIONS_NIX:-nix}"
NPM_BIN="${FM_TOOL_VERSIONS_NPM:-npm}"
GH_BIN="${FM_TOOL_VERSIONS_GH:-gh}"

DOTFILES_ARG=""
INSTALLED_ONLY=0
NO_NETWORK=0
SKIP_AGENTIC=0
SKIP_NIX=0
INCLUDE_PRERELEASE=0

usage() {
  sed -n '2,70p' "$0" | sed 's/^# \?//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dotfiles)
      if [ "$#" -lt 2 ]; then
        printf 'fm-tool-versions: --dotfiles requires a path\n' >&2
        exit 2
      fi
      DOTFILES_ARG="$2"
      shift 2
      continue
      ;;
    --installed-only)
      INSTALLED_ONLY=1
      NO_NETWORK=1
      SKIP_AGENTIC=1
      SKIP_NIX=1
      ;;
    --no-network)
      NO_NETWORK=1
      ;;
    --skip-agentic)
      SKIP_AGENTIC=1
      ;;
    --skip-nix)
      SKIP_NIX=1
      ;;
    --include-prerelease)
      INCLUDE_PRERELEASE=1
      ;;
    --json)
      printf 'fm-tool-versions: --json is not implemented\n' >&2
      exit 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-tool-versions: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'fm-tool-versions: unexpected argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$#" -gt 0 ]; then
  printf 'fm-tool-versions: unexpected argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

# --- helpers ----------------------------------------------------------------

resolve_dotfiles() {
  local candidate
  if [ -n "$DOTFILES_ARG" ]; then
    candidate="$DOTFILES_ARG"
  elif [ -n "${FM_DOTFILES:-}" ]; then
    candidate="$FM_DOTFILES"
  elif [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/projects/dotfiles" ]; then
    candidate="$FM_HOME/projects/dotfiles"
  elif [ -d "$FM_ROOT/projects/dotfiles" ]; then
    candidate="$FM_ROOT/projects/dotfiles"
  else
    return 1
  fi
  if [ -f "$candidate/flake.nix" ]; then
    printf '%s\n' "$(cd "$candidate" && pwd -P)"
    return 0
  fi
  return 1
}

# Strip common noise into a bare version-ish token (digits/dots, optional pre).
normalize_version() {
  local raw=$1
  raw=$(printf '%s' "$raw" | tr -d '\r')
  # Prefer the first semver-looking token in the string.
  if printf '%s' "$raw" | grep -Eo '[0-9]+(\.[0-9]+)+([.-][A-Za-z0-9.]+)?' >/dev/null 2>&1; then
    printf '%s' "$raw" | grep -Eo '[0-9]+(\.[0-9]+)+([.-][A-Za-z0-9.]+)?' | head -1
    return 0
  fi
  printf '%s' "$raw" | sed -E 's/^[^0-9]*//; s/[[:space:]].*$//; s/^v//; s/^rust-v//'
}

# Compare two version tokens. Echo -1 / 0 / 1 (a<b / equal / a>b).
# Pre-release suffixes (alpha, beta, rc, pre) sort before a bare release of the
# same numeric prefix when only one side has them.
version_cmp() {
  local a b
  a=$(normalize_version "$1")
  b=$(normalize_version "$2")
  if [ -z "$a" ] || [ -z "$b" ]; then
    printf '0\n'
    return 1
  fi
  if [ "$a" = "$b" ]; then
    printf '0\n'
    return 0
  fi
  # Split numeric core and optional suffix at first non-digit/dot boundary.
  local a_core a_suf b_core b_suf
  a_core=$(printf '%s' "$a" | sed -E 's/([0-9]+(\.[0-9]+)*)(.*)/\1/')
  a_suf=$(printf '%s' "$a" | sed -E 's/([0-9]+(\.[0-9]+)*)(.*)/\3/' | sed 's/^[.-]//')
  b_core=$(printf '%s' "$b" | sed -E 's/([0-9]+(\.[0-9]+)*)(.*)/\1/')
  b_suf=$(printf '%s' "$b" | sed -E 's/([0-9]+(\.[0-9]+)*)(.*)/\3/' | sed 's/^[.-]//')

  local IFS='.'
  # shellcheck disable=SC2086
  set -- $a_core
  local a1=${1:-0} a2=${2:-0} a3=${3:-0} a4=${4:-0}
  # shellcheck disable=SC2086
  set -- $b_core
  local b1=${1:-0} b2=${2:-0} b3=${3:-0} b4=${4:-0}

  for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3" "$a4:$b4"; do
    local left=${pair%%:*} right=${pair##*:}
    left=${left//[^0-9]/}
    right=${right//[^0-9]/}
    left=${left:-0}
    right=${right:-0}
    if [ "$left" -lt "$right" ]; then
      printf -- '-1\n'
      return 0
    fi
    if [ "$left" -gt "$right" ]; then
      printf '1\n'
      return 0
    fi
  done

  if [ -z "$a_suf" ] && [ -n "$b_suf" ]; then
    printf '1\n'
    return 0
  fi
  if [ -n "$a_suf" ] && [ -z "$b_suf" ]; then
    printf -- '-1\n'
    return 0
  fi
  if [ "$a_suf" '<' "$b_suf" ]; then
    printf -- '-1\n'
    return 0
  fi
  if [ "$a_suf" '>' "$b_suf" ]; then
    printf '1\n'
    return 0
  fi
  printf '0\n'
}

classify_pair() {
  # Args: installed_or_pin tip
  # Empty tip with empty err -> unknown; empty tip with err flag via third arg error
  local have=$1 tip=$2 mode=${3:-}
  if [ "$mode" = error ]; then
    printf 'error\n'
    return 0
  fi
  if [ -z "$have" ]; then
    printf 'error\n'
    return 0
  fi
  if [ -z "$tip" ]; then
    printf 'unknown\n'
    return 0
  fi
  local cmp
  if ! cmp=$(version_cmp "$have" "$tip"); then
    printf 'unknown\n'
    return 0
  fi
  case "$cmp" in
    0) printf 'current\n' ;;
    -1) printf 'behind\n' ;;
    1) printf 'ahead\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Capture first line of a command's stdout; empty on failure.
cmd_first_line() {
  local out
  if ! out=$("$@" 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$out" | head -1 | tr -d '\r'
}

installed_version() {
  local tool=$1
  local out raw
  case "$tool" in
    claude)
      raw=$(cmd_first_line claude --version) || return 1
      normalize_version "$raw"
      ;;
    codex)
      raw=$(cmd_first_line codex --version) || return 1
      normalize_version "$raw"
      ;;
    grok)
      raw=$(cmd_first_line grok --version) || return 1
      normalize_version "$raw"
      ;;
    opencode)
      raw=$(cmd_first_line opencode --version) || return 1
      normalize_version "$raw"
      ;;
    pi)
      raw=$(cmd_first_line pi --version) || return 1
      normalize_version "$raw"
      ;;
    no-mistakes)
      raw=$(cmd_first_line no-mistakes --version) || return 1
      normalize_version "$raw"
      ;;
    *)
      return 1
      ;;
  esac
}

nixpkgs_locked_rev() {
  local root=$1
  local lock=$root/flake.lock
  [ -f "$lock" ] || return 1
  # Prefer python for robust JSON; fall back to sed/grep for minimal envs.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
lock = json.load(open(sys.argv[1]))
node = lock.get("nodes", {}).get("nixpkgs", {})
rev = node.get("locked", {}).get("rev")
if not rev:
    sys.exit(1)
print(rev)
' "$lock"
    return 0
  fi
  # Fallback: crude extraction of the nixpkgs locked rev near its node.
  grep -A20 '"nixpkgs"' "$lock" | grep -m1 '"rev"' | sed -E 's/.*"rev": *"([^"]+)".*/\1/'
}

locked_pkg_version() {
  local rev=$1 pkg=$2
  local out
  if [ -z "${NIX_CONFIG:-}" ]; then
    export NIX_CONFIG="experimental-features = nix-command flakes"
  fi
  if ! out=$("$NIX_BIN" eval --raw "github:NixOS/nixpkgs/${rev}#${pkg}.version" 2>/dev/null); then
    return 1
  fi
  normalize_version "$out"
}

# Stable (non-prerelease) GitHub release tag -> bare version.
gh_stable_release_version() {
  local repo=$1
  local jq_filter tag
  if [ "$INCLUDE_PRERELEASE" -eq 1 ]; then
    jq_filter='.[0].tag_name // empty'
  else
    jq_filter='[.[] | select(.prerelease==false and .draft==false) | .tag_name][0] // empty'
  fi
  if ! tag=$("$GH_BIN" api "repos/${repo}/releases" --jq "$jq_filter" 2>/dev/null); then
    return 1
  fi
  [ -n "$tag" ] || return 1
  # openai/codex tags look like rust-v0.144.6
  tag=$(printf '%s' "$tag" | sed -E 's/^rust-//')
  normalize_version "$tag"
}

upstream_harness_tip() {
  local tool=$1
  case "$tool" in
    claude)
      local v
      v=$("$NPM_BIN" view @anthropic-ai/claude-code version 2>/dev/null) || return 1
      normalize_version "$v"
      ;;
    codex)
      gh_stable_release_version openai/codex
      ;;
    opencode)
      # nixpkgs meta.homepage points at anomalyco/opencode
      gh_stable_release_version anomalyco/opencode
      ;;
    pi)
      gh_stable_release_version badlogic/pi-mono
      ;;
    grok)
      # Public xai-org/grok-build has no GitHub Releases API surface today.
      # Upstream tip is unknown unless a future channel is documented; callers
      # treat empty as unknown rather than error when this returns 1 with empty.
      return 1
      ;;
    no-mistakes)
      # Prefer agentic section; optional npm/git tip not used here.
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- main -------------------------------------------------------------------

BEHIND=0
ERRORS=0
DOTFILES=""
NIXPKGS_REV=""

if [ "$INSTALLED_ONLY" -eq 0 ]; then
  if DOTFILES=$(resolve_dotfiles); then
    :
  else
    DOTFILES=""
  fi
fi

if [ -n "$DOTFILES" ] && [ "$SKIP_NIX" -eq 0 ]; then
  NIXPKGS_REV=$(nixpkgs_locked_rev "$DOTFILES" 2>/dev/null || true)
fi

printf 'Fleet tool versions (read-only; never mutates)\n'
if [ -n "$DOTFILES" ]; then
  printf 'dotfiles: %s\n' "$DOTFILES"
  if [ -n "$NIXPKGS_REV" ]; then
    printf 'nixpkgs lock: %s\n' "$NIXPKGS_REV"
  elif [ "$SKIP_NIX" -eq 0 ]; then
    printf 'nixpkgs lock: (unreadable)\n'
  fi
else
  printf 'dotfiles: (not resolved; locked nixpkgs and agentic pin sections skipped or limited)\n'
fi
printf '\n'

# --- harness table ----------------------------------------------------------

printf '## Harness CLIs (nixpkgs-owned in dotfiles; not agentic-tools-bump)\n'
printf '%-12s %-14s %-14s %-14s %s\n' 'TOOL' 'INSTALLED' 'LOCKED' 'UPSTREAM' 'STATUS'
printf '%-12s %-14s %-14s %-14s %s\n' '----' '---------' '------' '--------' '------'

# shell name : nixpkgs attr : show in table
HARNESS_ROWS=(
  'claude:claude-code'
  'codex:codex'
  'grok:grok-build'
  'opencode:opencode'
  'pi:pi-coding-agent'
  'no-mistakes:'
)

for row in "${HARNESS_ROWS[@]}"; do
  tool=${row%%:*}
  pkg=${row#*:}

  installed='-'
  locked='-'
  upstream='-'
  status='unknown'
  tip_failed=0
  lock_failed=0
  install_missing=0

  if inst=$(installed_version "$tool" 2>/dev/null); then
    installed=$inst
  else
    installed='(missing)'
    install_missing=1
  fi

  if [ -n "$pkg" ] && [ -n "$NIXPKGS_REV" ] && [ "$SKIP_NIX" -eq 0 ]; then
    if lkv=$(locked_pkg_version "$NIXPKGS_REV" "$pkg" 2>/dev/null); then
      locked=$lkv
    else
      locked='(error)'
      lock_failed=1
    fi
  elif [ -n "$pkg" ] && [ "$SKIP_NIX" -eq 0 ] && [ -z "$NIXPKGS_REV" ]; then
    locked='(no lock)'
  fi

  if [ "$NO_NETWORK" -eq 0 ]; then
    if tip=$(upstream_harness_tip "$tool" 2>/dev/null); then
      upstream=$tip
    else
      # grok has no public stable channel today; no-mistakes is agentic-owned.
      if [ "$tool" = grok ] || [ "$tool" = no-mistakes ]; then
        upstream='(unknown)'
      else
        upstream='(unreachable)'
        tip_failed=1
      fi
    fi
  else
    upstream='(skipped)'
  fi

  # Status prioritizes: missing install / unreachable tip -> error; else
  # compare installed vs a real upstream tip; else soft unknown.
  if [ "$install_missing" -eq 1 ]; then
    status=error
  elif [ "$tip_failed" -eq 1 ]; then
    status=error
  elif [ "$upstream" != '(unknown)' ] && [ "$upstream" != '(skipped)' ] && [ "$upstream" != '-' ] && [ "$upstream" != '(unreachable)' ]; then
    status=$(classify_pair "$installed" "$upstream")
  elif [ "$lock_failed" -eq 1 ]; then
    # No tip to compare; a hard lock eval failure still surfaces as error.
    status=error
  else
    status=unknown
  fi

  case "$status" in
    behind) BEHIND=$((BEHIND + 1)) ;;
    error) ERRORS=$((ERRORS + 1)) ;;
  esac

  printf '%-12s %-14s %-14s %-14s %s\n' "$tool" "$installed" "$locked" "$upstream" "$status"
done

printf '\n'
printf 'Note: harnesses advance when the dotfiles flake nixpkgs (nixos-unstable)\n'
printf 'pin is updated and Home Manager is rebuilt. agentic-tools-bump.sh does not\n'
printf 'bump claude/codex/grok/opencode/pi.\n'
printf '\n'

# --- agentic section --------------------------------------------------------

if [ "$SKIP_AGENTIC" -eq 0 ] && [ -n "$DOTFILES" ]; then
  agentic_check="$DOTFILES/scripts/agentic-tools-check-updates.sh"
  printf '## Agentic pins (dotfiles agentic-tools-check-updates.sh)\n'
  if [ -x "$agentic_check" ] || [ -f "$agentic_check" ]; then
    set +e
    agentic_out=$(bash "$agentic_check" 2>&1)
    agentic_ec=$?
    set -e
    printf '%s\n' "$agentic_out"
    case "$agentic_ec" in
      0) : ;;
      1) BEHIND=$((BEHIND + 1)) ;;
      2)
        ERRORS=$((ERRORS + 1))
        printf '(agentic check usage error)\n' >&2
        ;;
      3) ERRORS=$((ERRORS + 1)) ;;
      *)
        ERRORS=$((ERRORS + 1))
        printf '(agentic check exited %s)\n' "$agentic_ec" >&2
        ;;
    esac
  else
    printf 'agentic check script missing at %s\n' "$agentic_check"
    ERRORS=$((ERRORS + 1))
  fi
  printf '\n'
elif [ "$SKIP_AGENTIC" -eq 0 ]; then
  printf '## Agentic pins\n'
  printf '(skipped: dotfiles path not resolved)\n\n'
fi

# --- summary ----------------------------------------------------------------

printf 'Summary: behind=%s errors=%s\n' "$BEHIND" "$ERRORS"
if [ "$ERRORS" -gt 0 ]; then
  printf 'Check incomplete: one or more probes failed (offline, missing tool, or parse error).\n' >&2
  exit 3
fi
if [ "$BEHIND" -gt 0 ]; then
  printf 'One or more tools are behind upstream or their agentic pin is behind.\n'
  exit 1
fi
printf 'All compared tools are current (or soft-unknown without a hard failure).\n'
exit 0
