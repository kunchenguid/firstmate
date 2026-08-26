#!/usr/bin/env bash
# fm-git-guard.sh - PreToolUse/Bash gate with two duties, both scoped to the
# git ecosystem, both gated by the same transitional arm-flag:
#
#   1. HR1 PATH LOCK. In the PRIMARY firstmate session (never a crewmate/scout
#      task worktree, never a session outside the firstmate home) a Bash
#      command that WRITES under ${FM_HOME}/projects/ is refused. Project
#      changes travel through the selected worker delivery path, never through
#      a direct edit from the firstmate seat itself (AGENTS.md HR1). Read-only
#      inspection (cat, ls, rg, git log/diff/show/status/...) always passes.
#      Escape hatch for exactly one command: prefix it with
#      `FM_HR1_AUSNAHME=O-<order-id>` - visible in the transcript, logged.
#
#   2. HR3' SALVAGE TOR. A git command with destructive effect (force push,
#      branch -D, reset --hard, clean -f, checkout -- ., a broad-path
#      `restore --worktree`, stash drop/clear) is not refused - it is
#      salvaged first: `git bundle create ${FM_HOME}/data/salvage/
#      <ts>-<repo>-<branch>.bundle --all` runs in the target repo before the
#      command is allowed through. A bundle failure denies the command (no
#      unlanded work is thrown away without a recovery point - HR3). Two
#      narrower cases are refused outright, with no salvage possible:
#      `git reflog expire...` (the one operation a bundle cannot undo, since it
#      erases exactly the recovery trail a bundle would otherwise let you walk
#      back through) and any `rm` targeting a path under
#      ${FM_HOME}/data/salvage/ (throwing away a rescue you already made).
#      Both open the SAME escape hatch: prefix the command with
#      `FM_SALVAGE_DISCARD=O-<id>` - a captain-worded, logged, single-command
#      exception, matching HR3's "no discarding without the captain's explicit
#      discard word".
#
# Usage:
#   <PreToolUse JSON on stdin> | fm-git-guard.sh [--claude]
#   fm-git-guard.sh --command '<cmd>' [--cwd '<dir>'] [--claude]
#
# Stdin mode extracts .toolInput.command // .tool_input.command (the command)
# and .cwd (the shell's current directory at call time) - the same shape the
# turn-end and cd-pretool hooks read. CLI mode is for direct invocation and
# tests; --cwd defaults to this process's own $PWD when omitted.
#
# Transitional arm-flag: this gate is built but not yet live. The very first
# check, before any payload is even read, is $FM_HOME/state/.tor-git-scharf -
# absent, this script exits 0 with total silence (no output, no log line: an
# unarmed gate never even looked). Present, both duties above are enforced.
#
# Exit/output contract (matches fm-cd-pretool-check.sh):
#   ALLOW      - exit 0, no output.
#   DENY       - exit 2, a Claude-shaped deny object on stderr, plus a
#                Grok-shaped deny object on stdout unless --claude was given.
#   FAIL OPEN  - unarmed flag, malformed/empty stdin, missing jq for stdin
#                transport, missing git, or a payload with no usable command -
#                a broken or absent signal never blocks real work.
#
# Session scoping for duty 1 (HR1) mirrors bin/fm-cd-pretool-check.sh: the
# PRIMARY session is identified by resolving the git checkout that the
# command's own cwd sits in and requiring (a) that cwd falls under $FM_HOME,
# (b) that checkout's toplevel carries AGENTS.md and bin/ (the firstmate
# home's own signature - a project clone under projects/ does not carry it),
# and (c) that checkout is not a linked worktree (git-dir == git-common-dir) -
# the shape every crewmate/scout task worktree has (bin/fm-spawn.sh always
# hands one out). All three together are the "no crewmate marker" test; there
# is no separate marker file. Duty 2 (HR3') is NOT scoped to the primary
# session - unlanded work deserves a recovery point in any repo a firstmate
# process touches, worker worktrees included.
#
# Tor-Log: every decision this gate actually reaches (a write/destructive
# pattern recognized, allowed or refused) writes one line via fm_tor_log from
# bin/fm-tor-log-lib.sh - gate name "git-guard". Commands the patterns never
# recognize are prefiltered out before any decision exists to log, exactly
# like the flag-off case above. If bin/fm-tor-log-lib.sh is not yet present
# (see TODO-Marker below), a local no-op stands in so this gate still degrades
# to fail-open behavior on logging rather than failing the gate itself.
#
# Command classification is regex-based, not a shell parser - the same
# tradeoff tools/writ-fm/hooks/bash-guard.sh makes for `git add -A`. It
# recognizes the literal command shapes named above; deliberate obfuscation
# (nested `eval`, indirection through a variable, `bash -c '...'`) is out of
# scope, matching every sibling guard's documented threat model.
set -u

CMD=""
CMD_SET=0
CWD=""
CWD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-git-guard.sh [--command <cmd> [--cwd <dir>]] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin
(.toolInput.command // .tool_input.command, plus .cwd).
Exits 0 to allow and 2 to deny. The deny reason is written to stderr, with a
Grok-shaped decision object on stdout unless --claude is supplied.
Unarmed (no state/.tor-git-scharf), malformed transport, and a missing git
all fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      CWD=$2
      CWD_SET=1
      shift 2
      ;;
    --cwd=*)
      CWD=${1#--cwd=}
      CWD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}" || exit 0
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SALVAGE_DIR="$DATA/salvage"
FLAG="$STATE/.tor-git-scharf"

# Transitional arm-flag: unarmed gates pass in total silence (no log line -
# the gate never looked).
[ -f "$FLAG" ] || exit 0

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # A Cursor-delivered payload duplicates its own registration's copy of this
  # event; that copy already decided, so this one stands down.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || CWD=""
  CWD_SET=1
else
  [ "$CWD_SET" -eq 1 ] || CWD=$PWD
fi

[ -n "$CMD" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0

# --- Tor-Log: source the shared owner, or fall back to a local no-op. -------
TOR_LOG_LIB="$SCRIPT_DIR/fm-tor-log-lib.sh"
if [ -f "$TOR_LOG_LIB" ]; then
  # shellcheck source=bin/fm-tor-log-lib.sh
  . "$TOR_LOG_LIB"
else
  # TODO-Marker: TOR-LOG-LIB - remove this stand-in once bin/fm-tor-log-lib.sh
  # exists; until then every decision below still allows/denies correctly, it
  # just cannot be reconstructed later from state/tor-log/git-guard.jsonl.
  fm_tor_log() { :; }
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

deny() {  # <regel-id> <reason> [<log-kontext>]
  local regel=$1 reason=$2 kontext=${3:-"cmd=$CMD cwd=$CWD"}
  fm_tor_log git-guard "$regel" rot - "$kontext"
  local escaped
  escaped=$(json_escape "[$regel] $reason")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

regex_escape() {  # <string> -> ERE-escaped for embedding in a grep -E pattern
  printf '%s' "$1" | sed -e 's/[.[\*^$/+?(){}|]/\\&/g'
}

# Quote-normalized copy for detection only - mirrors the transport-only
# prefilters in fm-cd-pretool-check.sh / fm-arm-pretool-check.sh. Never used
# to build the actual command that runs; this script never executes CMD.
NORM=$CMD
NORM=${NORM//\"/}
NORM=${NORM//\'/}

# ============================================================================
# Duty 2a: rm targeting the salvage store itself - HR3' salvage-discard.
# Independent of session scope: throwing away a rescue is refused wherever it
# is attempted.
# ============================================================================
SALVAGE_RX=$(regex_escape "$SALVAGE_DIR")
if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*rm([[:space:]]+-{1,2}[A-Za-z-]+)*[[:space:]]+[^;&|]*${SALVAGE_RX}"; then
  if [[ $CMD =~ (^|[[:space:];&|])FM_SALVAGE_DISCARD=(O-[A-Za-z0-9_-]+)([[:space:]]|$) ]]; then
    order_id=${BASH_REMATCH[2]}
    fm_tor_log git-guard HR3-salvage-discard gruen "$order_id" "cmd=$CMD"
    exit 0
  fi
  deny HR3-salvage-discard \
    "'rm' targets the salvage store itself - throwing away a rescue needs the captain's explicit discard word (HR3: no discarding without it). Escape for exactly this command: prefix it with FM_SALVAGE_DISCARD=O-<order-id>."
fi

# ============================================================================
# Duty 1: HR1 path lock, PRIMARY session only.
# ============================================================================
is_primary_session=0
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  case "$CWD" in
    "$FM_HOME"|"$FM_HOME"/*)
      CWD_GIT_DIR=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null) || CWD_GIT_DIR=""
      CWD_GIT_COMMON_DIR=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || CWD_GIT_COMMON_DIR=""
      if [ -n "$CWD_GIT_DIR" ] && [ "$CWD_GIT_DIR" = "$CWD_GIT_COMMON_DIR" ]; then
        CWD_TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || CWD_TOP=""
        if [ -n "$CWD_TOP" ] && [ -f "$CWD_TOP/AGENTS.md" ] && [ -d "$CWD_TOP/bin" ]; then
          is_primary_session=1
        fi
      fi
      ;;
  esac
fi

if [ "$is_primary_session" -eq 1 ]; then
  PROJECTS_DIR="$CWD_TOP/projects"
  PROJECTS_RX=$(regex_escape "$PROJECTS_DIR/")
  writes_projects=0

  # a) redirects: > or >> onto a path under projects/
  if printf '%s' "$NORM" | grep -qE ">>?[[:space:]]*${PROJECTS_RX}"; then
    writes_projects=1
  fi
  # b) tee ... projects/path
  if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*tee([[:space:]]+-{1,2}[A-Za-z-]+)*[[:space:]]+[^;&|]*${PROJECTS_RX}"; then
    writes_projects=1
  fi
  # c) cp/mv/rm/mkdir/touch with a projects/ argument
  if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(cp|mv|rm|mkdir|touch)([[:space:]]+-{1,2}[A-Za-z-]+)*[[:space:]]+[^;&|]*${PROJECTS_RX}"; then
    writes_projects=1
  fi
  # d) sed -i touching a projects/ path
  if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*sed[[:space:]]+(-[A-Za-z]*i[A-Za-z]*|--in-place[^[:space:]]*)[[:space:]]+[^;&|]*${PROJECTS_RX}"; then
    writes_projects=1
  fi
  # e) git -C <projects-path> <non-read-only-subcommand>
  GIT_C_RX="(^|[;&|]|&&)[[:space:]]*git[[:space:]]+-C[[:space:]]+${PROJECTS_RX}[^[:space:]]*[[:space:]]+([A-Za-z-]+)"
  if [[ $NORM =~ $GIT_C_RX ]]; then
    sub=${BASH_REMATCH[3]}
    case "$sub" in
      log|diff|show|status|remote|branch|fetch|blame|shortlog|describe|reflog|rev-parse|ls-files|cat-file) ;;
      *) writes_projects=1 ;;
    esac
  fi

  if [ "$writes_projects" -eq 1 ]; then
    if [[ $CMD =~ (^|[[:space:];&|])FM_HR1_AUSNAHME=(O-[A-Za-z0-9_-]+)([[:space:]]|$) ]]; then
      order_id=${BASH_REMATCH[2]}
      fm_tor_log git-guard HR1 gruen "$order_id" "cmd=$CMD cwd=$CWD"
      exit 0
    fi
    deny HR1 \
      "Projektaenderungen laufen ueber Worker-Lieferwege (HR1). Ausweg fuer genau einen Handgriff: FM_HR1_AUSNAHME=O-<order-id> als Praefix."
  fi
fi

# ============================================================================
# Duty 2b: HR3' reflog expire - refused outright, no salvage possible.
# ============================================================================
if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\breflog\b[[:space:]]+expire\b"; then
  if [[ $CMD =~ (^|[[:space:];&|])FM_SALVAGE_DISCARD=(O-[A-Za-z0-9_-]+)([[:space:]]|$) ]]; then
    order_id=${BASH_REMATCH[2]}
    fm_tor_log git-guard HR3-reflog-expire gruen "$order_id" "cmd=$CMD cwd=$CWD"
    exit 0
  fi
  deny HR3-reflog-expire \
    "'git reflog expire' erases exactly the recovery trail a salvage bundle cannot rebuild - no bundle can stand in for it, so it is refused, not bundled (HR3: no discarding without the captain's explicit discard word). Escape for exactly this command: prefix it with FM_SALVAGE_DISCARD=O-<order-id>."
fi

# ============================================================================
# Duty 2c: HR3' salvage - bundle first, then allow; deny only if the bundle
# itself fails.
# ============================================================================
destructive_label=""
if printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\bpush\b[^;&|]*(--force(-with-lease)?\b|[[:space:]]-f\b)"; then
  destructive_label="push --force"
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\bbranch\b[^;&|]*(-D\b|--delete[[:space:]]+--force\b|--force[[:space:]]+--delete\b|-[a-zA-Z]*D[a-zA-Z]*\b)"; then
  destructive_label="branch -D"
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\breset\b[^;&|]*--hard\b"; then
  destructive_label="reset --hard"
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\bclean\b[^;&|]*(-[A-Za-z]*f[A-Za-z]*\b|--force\b)"; then
  destructive_label="clean -f"
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\bcheckout\b[[:space:]]+--[[:space:]]+\.([[:space:]]|$)"; then
  destructive_label="checkout -- ."
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\brestore\b[^;&|]*--worktree\b" \
  && printf '%s' "$NORM" | grep -qE "\brestore\b[^;&|]*(^|[[:space:]])\.([[:space:]]|$)"; then
  destructive_label="restore --worktree ."
elif printf '%s' "$NORM" | grep -qE "(^|[;&|]|&&)[[:space:]]*git[[:space:]]+.*\bstash\b[[:space:]]+(drop|clear)\b"; then
  destructive_label="stash drop/clear"
fi

if [ -n "$destructive_label" ]; then
  TARGET_DIR=$CWD
  if [[ $CMD =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    TARGET_DIR=${BASH_REMATCH[1]}
  fi
  [ -n "$TARGET_DIR" ] || TARGET_DIR=$PWD

  TOPLEVEL=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || TOPLEVEL=""
  if [ -z "$TOPLEVEL" ]; then
    deny HR3-salvage \
      "'$destructive_label' is destructive and normally earns a salvage bundle first, but the target directory ('$TARGET_DIR') could not be resolved to a git repo - refusing rather than running the command with no recovery point (HR3)." \
      "cmd=$CMD target=$TARGET_DIR reason=no-repo"
  fi

  REPO_NAME=$(basename "$TOPLEVEL")
  BRANCH_NAME=$(git -C "$TOPLEVEL" rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH_NAME="HEAD"
  [ -n "$BRANCH_NAME" ] || BRANCH_NAME="HEAD"
  safe() { printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-]/-/g'; }
  REPO_SAFE=$(safe "$REPO_NAME")
  BRANCH_SAFE=$(safe "$BRANCH_NAME")
  # Sub-second precision (with a PID fallback where %N is unsupported, e.g.
  # BSD/macOS date) so two destructive commands in the same second never
  # collide on one bundle filename and silently overwrite each other's
  # rescue.
  TS=$(date -u +%Y%m%dT%H%M%S)
  TS_NS=$(date -u +%N 2>/dev/null)
  case "$TS_NS" in ''|*[!0-9]*) TS_NS=$$ ;; esac
  TS="${TS}.${TS_NS}Z"
  BUNDLE_PATH="$SALVAGE_DIR/${TS}-${REPO_SAFE}-${BRANCH_SAFE}.bundle"

  if ! mkdir -p "$SALVAGE_DIR" 2>/dev/null; then
    deny HR3-salvage \
      "'$destructive_label' is destructive and normally earns a salvage bundle first, but $SALVAGE_DIR could not be created - refusing rather than running the command with no recovery point (HR3)." \
      "cmd=$CMD target=$TOPLEVEL reason=salvage-dir"
  fi

  if git -C "$TOPLEVEL" bundle create "$BUNDLE_PATH" --all >/dev/null 2>&1 && [ -s "$BUNDLE_PATH" ]; then
    fm_tor_log git-guard HR3-salvage gruen - "cmd=$CMD bundle=$BUNDLE_PATH"
    exit 0
  fi
  rm -f "$BUNDLE_PATH" 2>/dev/null || true
  deny HR3-salvage \
    "'$destructive_label' is destructive and normally earns a salvage bundle first, but 'git bundle create' failed in '$TOPLEVEL' - refusing rather than running the command with no recovery point (HR3)." \
    "cmd=$CMD target=$TOPLEVEL reason=bundle-create-failed"
fi

exit 0
