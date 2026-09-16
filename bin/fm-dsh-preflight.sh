#!/usr/bin/env bash
# Preflight for a DeepSeek Harness firstmate home.
#
# Three DSH misconfigurations are SILENT and TOTAL, so each is asserted here
# rather than documented. Documentation is not a check: every one of these was
# written down before it was measured, and one of them had no producer at all.
#
#   1. HOOKS BRIDGE VERSION. A bridge whose version differs from the running
#      dsh-base reads `session.events` synchronously - a read DSH deprecated
#      after rc.5 - and throws inside `lastTurn()` before any hook is matched.
#      Every tool call then fails with "agent.session.events is not iterable"
#      while the guards go inert. The sub-packages' npm `latest` tag is stale,
#      so a bare `dsh plugin add @deepseek-ai/dsh-hooks-claude-code` installs
#      the wrong build.
#   2. INSTRUCTION BUDGET. `dsh-agent-instructions` truncates the injected chain
#      at `maxBytes`, which dsh-base ships as 65536. firstmate's AGENTS.md is
#      larger, so the default silently drops its later sections - including the
#      crewmate-brief and backlog contracts.
#   3. PROCESS INSPECTION. `ps` is denied under the `workspace-write` sandbox.
#      Harness ancestry, the PID-strict watcher lock and away-mode daemon
#      ownership then read "unknown" or "down" rather than reporting a
#      misconfiguration, so the home looks broken instead of unsandboxed.
#
# Usage: fm-dsh-preflight.sh [--profile <name>] [--home <firstmate-home>] [--patch <path>]... [--quiet]
# Exit: 0 all required checks passed; 3 at least one required check failed.
set -u

PROFILE=web
FM_HOME_OVERRIDE=
QUIET=0
PATCH_OVERLAYS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -gt 1 ] || { printf 'error: --profile requires a name\n' >&2; exit 2; }
      PROFILE=$2; shift 2 ;;
    --profile=*) PROFILE=${1#--profile=}; shift ;;
    --home)
      [ "$#" -gt 1 ] || { printf 'error: --home requires a path\n' >&2; exit 2; }
      FM_HOME_OVERRIDE=$2; shift 2 ;;
    --home=*) FM_HOME_OVERRIDE=${1#--home=}; shift ;;
    --patch)
      [ "$#" -gt 1 ] || { printf 'error: --patch requires a path\n' >&2; exit 2; }
      PATCH_OVERLAYS+=("$2"); shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) printf 'usage: %s [--profile <name>] [--home <path>] [--patch <path>]... [--quiet]\n' "$(basename -- "$0")" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_HOME_DIR=${FM_HOME_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
DSH_HOME_DIR=${DSH_HOME:-$HOME/.dsh}
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"
SHARED_MODULES="$DSH_HOME_DIR/profiles/node_modules"

FAILED=0
WARNED=0
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
warn() { WARNED=$((WARNED + 1)); printf 'WARN  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
ok() { [ "$QUIET" -eq 1 ] || printf 'ok    %s\n' "$1"; return 0; }

pkg_version() {  # <package.json path>
  [ -f "$1" ] || return 1
  node -p "require(process.argv[1]).version" "$1" 2>/dev/null
}

# --- 1. hooks bridge version matches the running dsh-base --------------------
BRIDGE_PKG="$PROFILE_DIR/node_modules/@deepseek-ai/dsh-hooks-claude-code/package.json"
BASE_PKG="$SHARED_MODULES/@deepseek-ai/dsh-base/package.json"
[ -f "$BASE_PKG" ] || BASE_PKG="$PROFILE_DIR/node_modules/@deepseek-ai/dsh-base/package.json"

BASE_VERSION=$(pkg_version "$BASE_PKG" || true)
BRIDGE_VERSION=$(pkg_version "$BRIDGE_PKG" || true)

if [ -z "$BRIDGE_VERSION" ]; then
  fail "the hooks bridge is not installed in profile '$PROFILE'" \
    "install it at the running dsh-base version: dsh plugin --profile $PROFILE add @deepseek-ai/dsh-hooks-claude-code@${BASE_VERSION:-<version>}"
elif [ -z "$BASE_VERSION" ]; then
  warn "could not read the running dsh-base version" "checked $BASE_PKG"
elif [ "$BRIDGE_VERSION" != "$BASE_VERSION" ]; then
  fail "hooks bridge $BRIDGE_VERSION does not match dsh-base $BASE_VERSION" \
    "a mismatched bridge throws before any hook matches and makes every tool call fail; reinstall: dsh plugin --profile $PROFILE add @deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION"
else
  ok "hooks bridge $BRIDGE_VERSION matches dsh-base $BASE_VERSION"
fi

# --- 2. the instruction budget fits AGENTS.md --------------------------------
AGENTS_MD="$FM_HOME_DIR/AGENTS.md"
if [ -f "$AGENTS_MD" ]; then
  AGENTS_BYTES=$(wc -c < "$AGENTS_MD" | tr -d ' ')
  # The user layers compose in DSH's order - the profile's patch, then the
  # home-level patch, then each --patch overlay - so the last layer that sets
  # the agent-instructions entry's maxBytes wins. Only that entry counts: another
  # plugin's maxBytes says nothing about AGENTS.md. The dsh-base default applies
  # when no layer raises it, and that default is what silently truncates.
  MAX_BYTES=65536
  MAX_SOURCE=
  PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"
  for layer in "$PATCH_FILE" "$DSH_HOME_DIR/cordis.patch.yml" ${PATCH_OVERLAYS[@]+"${PATCH_OVERLAYS[@]}"}; do
    [ -f "$layer" ] || continue
    FOUND=$(awk '
      /^[[:space:]]*(#|$)/ { next }
      {
        indent = match($0, /[^[:space:]]/) - 1
        line = substr($0, indent + 1)
        if (line ~ /^-[[:space:]]+id:/ || line ~ /^id:/) {
          id = line; sub(/^-?[[:space:]]*id:[[:space:]]*/, "", id); gsub(/["'\'']|[[:space:]].*$/, "", id)
          entry = id; entry_indent = indent; next
        }
        if (line ~ /^-/ && indent <= entry_indent) entry = ""
        if (entry == "agent-instructions" && line ~ /^maxBytes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/) {
          value = line; sub(/^maxBytes:[[:space:]]*/, "", value); sub(/[^0-9].*$/, "", value)
        }
      }
      END { if (value != "") print value }
    ' "$layer")
    [ -n "$FOUND" ] && { MAX_BYTES=$FOUND; MAX_SOURCE=$layer; }
  done
  if [ "$AGENTS_BYTES" -gt "$MAX_BYTES" ]; then
    fail "AGENTS.md is $AGENTS_BYTES bytes but maxBytes is $MAX_BYTES${MAX_SOURCE:+ (set in $MAX_SOURCE)}" \
      "raise the agent-instructions entry's maxBytes in ${MAX_SOURCE:-$PATCH_FILE}, and on every DSH home: this truncation is silent"
  else
    ok "instruction budget $MAX_BYTES fits AGENTS.md ($AGENTS_BYTES bytes)${MAX_SOURCE:+ from $MAX_SOURCE}"
  fi
else
  warn "no AGENTS.md at $AGENTS_MD" "the digest will carry no operating contract for this home"
fi

# --- 3. process inspection survives the sandbox ------------------------------
if ps -o comm= -p $$ >/dev/null 2>&1; then
  ok "process inspection works (ps)"
else
  fail "ps is denied in this profile" \
    "harness ancestry, the PID-strict watcher lock and away-mode ownership all degrade silently; select the danger-full-access permission preset (sandbox-policy.mode alone is refused at load)"
fi

# lsof is required by teardown's stale-lock proof and its orphan reap, both of
# which refuse rather than fail when it is absent.
if command -v lsof >/dev/null 2>&1; then
  ok "lsof present (teardown stale-lock proof and orphan reap)"
else
  warn "lsof is not on PATH" "teardown's stale-lock and orphan-reap steps will refuse rather than proceed"
fi

# --- hook-subprocess prerequisites -------------------------------------------
# Every guard fails OPEN without these, so an absent tool is a silent no-op -
# exactly the failure mode the guards exist to prevent.
for tool in jq node; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool present (hook transport and command policies)"
  else
    fail "$tool is not on PATH" "every hook that needs it becomes a silent no-op"
  fi
done

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  printf 'dsh preflight: %s required check(s) failed, %s warning(s)\n' "$FAILED" "$WARNED"
  exit 3
fi
printf 'dsh preflight: all required checks passed, %s warning(s)\n' "$WARNED"
exit 0
