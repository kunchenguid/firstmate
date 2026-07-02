#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per problem and exits 0. Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "CREW_HARNESS_OVERRIDE: <name>", "FLEET_SYNC: <repo>: skipped: <reason>".
#          Fleet sync fetches, fast-forwards, and prunes gone local branches;
#          it is bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  timeout=${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    tmux|node|gh) echo "brew install $1  # or the platform's package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    codebase-memory-mcp) echo "curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config" ;;
    *) return 1 ;;
  esac
}

# Resolve the codebase-memory-mcp binary without relying on PATH (it installs to
# ~/.local/bin, which may be off firstmate's PATH). Echoes a path or nothing.
cbm_bin() {
  local c
  c=$(command -v codebase-memory-mcp 2>/dev/null) && { echo "$c"; return 0; }
  for c in "$HOME/.local/bin/codebase-memory-mcp" /usr/local/bin/codebase-memory-mcp /opt/homebrew/bin/codebase-memory-mcp; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Ensure the code-graph engine is set up and each base clone is indexed. Every
# step is best-effort and non-fatal — code intelligence must never block startup.
cbm_setup() {
  local bin
  bin=$(cbm_bin) || return 0
  # one-time: enable self-indexing (idempotent, quiet)
  "$bin" config set auto_index true >/dev/null 2>&1 || true
  [ -d "$PROJECTS" ] || return 0
  local known clone abs
  known=$("$bin" cli list_projects '{}' 2>/dev/null || echo '')
  for clone in "$PROJECTS"/*/; do
    [ -d "$clone" ] || continue
    abs=$(cd "$clone" 2>/dev/null && pwd) || continue
    # rule #1 defensive: keep any in-tree index artifact out of git (untracked exclude)
    if [ -d "$clone/.git" ] || [ -f "$clone/.git" ]; then
      local excl="$clone/.git/info/exclude"
      if [ -w "$(dirname "$excl")" ] 2>/dev/null || [ ! -e "$excl" ]; then
        grep -qxF '.codebase-memory/' "$excl" 2>/dev/null || echo '.codebase-memory/' >> "$excl" 2>/dev/null || true
      fi
    fi
    # index once if this clone is not yet known (auto_index keeps it fresh after)
    case "$known" in
      *"\"$abs\""*) ;;
      *) nohup "$bin" cli index_repository "{\"repo_path\":\"$abs\"}" >/dev/null 2>&1 & ;;
    esac
  done
}

TOOLS="tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi"

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $TOOLS; do
  command -v "$t" >/dev/null || echo "MISSING: $t (install: $(install_cmd "$t"))"
done
cbm_bin >/dev/null || echo "MISSING: codebase-memory-mcp (install: $(install_cmd codebase-memory-mcp))"
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
fleet_sync
cbm_setup
exit 0
