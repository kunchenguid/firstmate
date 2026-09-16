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
#   2. INSTRUCTION BUDGET. `dsh-agent-instructions` budgets the whole rendered
#      instruction chain at `maxBytes`, which dsh-base and DSH's shipped agent
#      presets set to 65536. Over budget it omits the broadest file whole, and
#      firstmate's AGENTS.md is larger than that, so the agent receives only the
#      CLAUDE.md pointer and a budget marker the operator never sees. Under
#      dsh-web-app the host row is disabled and the session's agent preset
#      carries the budget, so a raise on the host row there is not a budget.
#   3. SANDBOX. `ps` is denied under the `workspace-write` sandbox. Harness
#      ancestry, the PID-strict watcher lock and away-mode daemon ownership
#      then read "unknown" or "down" rather than reporting a misconfiguration,
#      so the home looks broken instead of unsandboxed. Two settings decide it:
#      the permission preset new sessions are seeded with governs their tool
#      calls, and the host's sandbox-policy mode governs every hook, which the
#      hooks bridge runs with no session. This preflight runs in the launching
#      shell before DSH starts, where nothing is sandboxed, so it cannot probe
#      `ps` itself; it asserts both settings instead.
#
# Usage: fm-dsh-preflight.sh [--profile <name>] [--home <firstmate-home>] [--patch <path>]... [--quiet]
# Exit: 0 all required checks passed; 3 at least one required check failed.
set -u

PROFILE=web
FM_HOME_OVERRIDE=
QUIET=0
PATCH_ARGS=()
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
      PATCH_ARGS+=(--patch "$2"); shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) printf 'usage: %s [--profile <name>] [--home <path>] [--patch <path>]... [--quiet]\n' "$(basename -- "$0")" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_HOME_DIR=${FM_HOME_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
DSH_HOME_DIR=${DSH_HOME:-$HOME/.dsh}
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"

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
# DSH resolves dsh-base from its own installation first. $DSH_HOME/profiles/
# node_modules only mirrors that installation, and DSH creates it when a host
# boots, so on a fresh home's first launch it does not exist yet. Resolve from
# the installation instead, walking node_modules up from the real dsh binary.
DSH_BIN=$(command -v dsh || true)
BASE_PKG=
[ -z "$DSH_BIN" ] || BASE_PKG=$(node -e '
  const fs = require("node:fs"), path = require("node:path");
  for (let dir = path.dirname(fs.realpathSync(process.argv[1])); ; dir = path.dirname(dir)) {
    const pkg = path.join(dir, "node_modules/@deepseek-ai/dsh-base/package.json");
    if (fs.existsSync(pkg)) { console.log(pkg); break; }
    if (path.dirname(dir) === dir) break;
  }' "$DSH_BIN" 2>/dev/null || true)

BASE_VERSION=$(pkg_version "$BASE_PKG" || true)
BRIDGE_VERSION=$(pkg_version "$BRIDGE_PKG" || true)

if [ -z "$BASE_VERSION" ]; then
  fail "could not read the running dsh-base version from the dsh installation (${DSH_BIN:-dsh is not on PATH})" \
    "put the dsh CLI on PATH: without dsh-base's version the hooks bridge pin cannot be checked, and a mismatched bridge makes every tool call fail"
elif [ -z "$BRIDGE_VERSION" ]; then
  fail "the hooks bridge is not installed in profile '$PROFILE'" \
    "install it at the running dsh-base version: dsh plugin --profile $PROFILE add @deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION"
elif [ "$BRIDGE_VERSION" != "$BASE_VERSION" ]; then
  fail "hooks bridge $BRIDGE_VERSION does not match dsh-base $BASE_VERSION" \
    "a mismatched bridge throws before any hook matches and makes every tool call fail; reinstall: dsh plugin --profile $PROFILE add @deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION"
else
  ok "hooks bridge $BRIDGE_VERSION matches dsh-base $BASE_VERSION"
fi

# --- the composition sessions boot with -------------------------------------
# Print the lines of composition entry <id> read from stdin, indentation
# stripped, so its own keys (config included) can be read with entry_value.
entry_lines() {  # <id>
  awk -v want="$1" '
    /^[[:space:]]*(#|$)/ { next }
    {
      indent = match($0, /[^[:space:]]/) - 1
      line = substr($0, indent + 1)
      if (line ~ /^-[[:space:]]+id:/ || line ~ /^id:/) {
        id = line; sub(/^-?[[:space:]]*id:[[:space:]]*/, "", id); gsub(/["'\'']|[[:space:]].*$/, "", id)
        entry = id; entry_indent = indent
      } else if (line ~ /^-/ && indent <= entry_indent) {
        entry = ""
      }
      if (entry == want) print line
    }
  '
}

# Print the last plain value of <key> among entry lines on stdin.
entry_value() {  # <key>
  sed -n "s/^$1:[[:space:]]*//p" | sed 's/[[:space:]]*#.*$//' | tr -d "\"'" | tail -1
}

# enabled, disabled, or unknown for entry lines on stdin: a `disabled` that is
# neither absent nor a literal boolean (a `!!js` gate) cannot be vouched for.
entry_state() {
  case "$(entry_value disabled)" in
    ''|false) printf 'enabled\n' ;;
    true) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

SETTINGS_FILE="$DSH_HOME_DIR/settings.yaml"
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"

# Print <key>'s value under top-level <section> of the harness settings
# document, where a user's choice outranks the composition's default.
settings_value() {  # <section> <key>
  awk -v section="$1:" '/^[^[:space:]#]/ { inside = ($1 == section) } inside && /^[[:space:]]/' "$SETTINGS_FILE" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | entry_value "$2"
}

# The composition is DSH's own dump of the bundle, profile, home-level and
# --patch layers, not a re-derivation of its layer order.
DUMP=$(dsh --profile "$PROFILE" ${PATCH_ARGS[@]+"${PATCH_ARGS[@]}"} --dump-config 2>/dev/null) || DUMP=
if [ -z "$DUMP" ]; then
  fail "could not read the composed configuration: dsh --profile $PROFILE --dump-config failed" \
    "run that command to see why; neither the instruction budget nor the sandbox that sessions and hooks run under can be checked without it"
fi

# --- 2. the session agent's instruction budget fits the rendered chain -------
AGENTS_MD="$FM_HOME_DIR/AGENTS.md"
FM_PRESET_ID=firstmate
FM_PRESET="$FM_HOME_DIR/.dsh/agent-presets/$FM_PRESET_ID/agent.cordis.yml"
if [ ! -f "$AGENTS_MD" ]; then
  warn "no AGENTS.md at $AGENTS_MD" "the digest will carry no operating contract for this home"
elif [ -n "$DUMP" ]; then
  # DSH budgets the whole rendered chain, not AGENTS.md: every instruction file
  # it discovers (the harness-home AGENTS.md, then this workspace's AGENTS.md,
  # CLAUDE.md and their .local overlays) plus the frame it wraps them in, which
  # measured 336 bytes around AGENTS.md and CLAUDE.md and is rounded up here.
  CHAIN_BYTES=1024
  for f in "$DSH_HOME_DIR/AGENTS.md" "$FM_HOME_DIR/AGENTS.md" "$FM_HOME_DIR/CLAUDE.md" \
    "$FM_HOME_DIR/AGENTS.local.md" "$FM_HOME_DIR/CLAUDE.local.md"; do
    [ -f "$f" ] && CHAIN_BYTES=$((CHAIN_BYTES + $(wc -c < "$f")))
  done
  OMIT_NOTE="over budget, DSH omits AGENTS.md whole and only the model sees its one-line budget marker"
  # Which row governs depends on the profile: where an enabled agent-presets
  # row exists (dsh-web-app), the host agent-instructions row is disabled and
  # each session renders with its default preset's row, which no profile layer
  # reaches; otherwise the host row governs.
  ROW_SOURCE=
  ROW=
  PRESETS=$(printf '%s\n' "$DUMP" | entry_lines agent-presets)
  if [ -n "$PRESETS" ] && [ "$(printf '%s\n' "$PRESETS" | entry_state)" = unknown ]; then
    fail "profile $PROFILE's agent-presets row is not provably enabled or disabled" \
      "make its disabled field a literal boolean, so the composition sessions render with can be checked"
  elif [ -n "$PRESETS" ] && [ "$(printf '%s\n' "$PRESETS" | entry_state)" = enabled ]; then
    PRESET_ID=$(settings_value agent-presets default)
    PRESET_FROM="$SETTINGS_FILE"
    if [ -z "$PRESET_ID" ]; then
      PRESET_ID=$(printf '%s\n' "$PRESETS" | entry_value default)
      PRESET_FROM="profile $PROFILE"
    fi
    if [ "$PRESET_ID" != "$FM_PRESET_ID" ]; then
      fail "sessions compose from agent preset '${PRESET_ID:-<none>}' ($PRESET_FROM), not the $FM_PRESET_ID preset" \
        "make $FM_PRESET_ID the agent-presets default as .dsh/profile.patch.yml does, and clear any agent-presets default in $SETTINGS_FILE: another preset carries its own budget, DSH's standard preset renders at 65536, and $OMIT_NOTE"
    else
      ROW_SOURCE="the $FM_PRESET_ID agent preset"
      ROW_FILE=$FM_PRESET
      ROW=$(entry_lines agent-instructions < "$FM_PRESET" 2>/dev/null)
    fi
  else
    ROW_SOURCE="profile $PROFILE"
    ROW_FILE=$PATCH_FILE
    ROW=$(printf '%s\n' "$DUMP" | entry_lines agent-instructions)
  fi
  if [ -n "$ROW_SOURCE" ]; then
    MAX_BYTES=$(printf '%s\n' "$ROW" | entry_value maxBytes)
    if [ -z "$ROW" ]; then
      fail "$ROW_SOURCE has no agent-instructions row" \
        "add one with a raised maxBytes in $ROW_FILE: without it no workspace instructions reach the agent"
    elif [ "$(printf '%s\n' "$ROW" | entry_state)" != enabled ]; then
      fail "$ROW_SOURCE's agent-instructions row is not enabled, so no maxBytes on it is a budget" \
        "enable the agent-instructions row in $ROW_FILE: a disabled row renders nothing, and $OMIT_NOTE"
    elif ! [ "$MAX_BYTES" -gt 0 ] 2>/dev/null; then
      fail "could not read the effective agent-instructions maxBytes from $ROW_SOURCE" \
        "raise the agent-instructions entry's maxBytes to a plain number in $ROW_FILE, and on every DSH home: $OMIT_NOTE"
    elif [ "$CHAIN_BYTES" -gt "$MAX_BYTES" ]; then
      fail "the rendered instruction chain is about $CHAIN_BYTES bytes but $ROW_SOURCE's maxBytes is $MAX_BYTES" \
        "raise the agent-instructions entry's maxBytes in $ROW_FILE, and on every DSH home: $OMIT_NOTE"
    else
      ok "instruction budget $MAX_BYTES fits the rendered instruction chain (about $CHAIN_BYTES bytes) in $ROW_SOURCE"
    fi
  fi
fi

# --- 3. sessions and hooks run under a sandbox that permits ps --------------
# A new session is seeded with the settings document's default permission
# preset, else the profile's. That proves the default, not any one session: a
# resumed session keeps the preset it recorded, and the per-session /permission
# control can still downgrade a session after launch.
if [ -n "$DUMP" ]; then
  PERMISSION_PRESET=$(settings_value permission defaultPreset)
  PERMISSION_FROM="$SETTINGS_FILE"
  if [ -z "$PERMISSION_PRESET" ]; then
    PERMISSION_PRESET=$(printf '%s\n' "$DUMP" | entry_lines permission | entry_value defaultPreset)
    PERMISSION_FROM="profile $PROFILE"
  fi
  if [ "$PERMISSION_PRESET" = danger-full-access ]; then
    ok "new sessions default to the danger-full-access permission preset ($PERMISSION_FROM)"
  else
    fail "new sessions default to permission preset '${PERMISSION_PRESET:-<inferred from the sandbox knobs>}' ($PERMISSION_FROM), not danger-full-access" \
      "set the permission entry's defaultPreset to danger-full-access in $PATCH_FILE and clear any permission defaultPreset in $SETTINGS_FILE: any other sandbox denies ps, so harness ancestry, the PID-strict watcher lock and away-mode ownership degrade silently (sandbox-policy.mode alone is refused at load)"
  fi

  # Hooks are not session tool calls: the hooks bridge runs them with no
  # session, so they get the host's sandbox-policy mode whatever preset a
  # session was seeded with. DSH evaluates a `!!js` mode at host start in the
  # environment it was launched with, so it is evaluated here in this one.
  SANDBOX_ROW=$(printf '%s\n' "$DUMP" | entry_lines sandbox-policy)
  HOOK_MODE=$(printf '%s\n' "$SANDBOX_ROW" | entry_value mode)
  case "$HOOK_MODE" in
    '!!js '*)
      HOOK_MODE=$(node -e 'process.stdout.write(String(eval(process.argv[1])))' \
        "$(printf '%s\n' "$SANDBOX_ROW" | sed -n 's/^mode:[[:space:]]*!!js[[:space:]]*//p' | tail -1)" 2>/dev/null) || HOOK_MODE= ;;
  esac
  if [ "$HOOK_MODE" = danger-full-access ]; then
    ok "hooks run under the danger-full-access sandbox mode"
  else
    fail "hooks run under sandbox mode '${HOOK_MODE:-<unreadable>}', not danger-full-access" \
      "launch through bin/fm-dsh-launch.sh, which exports DSH_PERMISSION_MODE=danger-full-access, and leave sandbox-policy's mode to that variable: the hooks bridge runs hooks with no session, so ps is denied in every hook and the digest reads READ-ONLY with an unknown harness"
  fi
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
