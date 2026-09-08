#!/usr/bin/env bash
# tests/fm-opencode-plugin-spawn.test.sh - the OpenCode plugins must reach a
# shell script through bash, never through its shebang.
#
# Windows has no shebang. CreateProcess cannot execute a .sh at all, so
# spawn("/path/to/x.sh") fails with EFTYPE, and every one of these plugins
# converts a spawn error into {code: 0} - which reads as "allowed", "no nudge",
# or "guard passed". The whole OpenCode surface therefore fails open and silent
# on Windows, which is why the structural check below is the primary guard: it
# fails on every platform, including the Linux CI where the broken form happens
# to work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the OpenCode plugins)"; exit 0; }

PLUGIN_DIR="$ROOT/.opencode/plugins"

# The scripts the plugins spawn, and the call site that spawns each one.
PLUGIN_SPAWNED_SCRIPTS="
fm-cd-pretool-check.sh|fm-primary-cd-check.js
fm-arm-pretool-check.sh|fm-primary-pretool-check.js
fm-sessionstart-nudge.sh|fm-primary-sessionstart-nudge.js
fm-turnend-guard.sh|fm-primary-turnend-guard.js
fm-operational-input.sh|lib/fm-operational-input.js
"

# A spawn whose command argument is itself a script: a .sh literal, or the bare
# `script` binding the cross-language encoder resolves before spawning.
# shellcheck disable=SC2016 # this is an ERE for grep, not shell text to expand.
BARE_SCRIPT_SPAWN='(runProcess|spawn|spawnSync)\((`[^`,]*\.sh`|"[^",]*\.sh"|script)[[:space:]]*,'

test_no_plugin_spawns_a_script_directly() {
  local hits
  hits=$(grep -rnE "$BARE_SCRIPT_SPAWN" "$PLUGIN_DIR" --include='*.js' 2>/dev/null || true)
  [ -z "$hits" ] || fail "an OpenCode plugin spawns a script directly, which cannot execute on Windows:"$'\n'"$hits"
  pass "opencode plugins: no call site spawns a shell script as the command"
}

test_every_spawned_script_is_reached_through_bash() {
  local script plugin file
  while IFS='|' read -r script plugin; do
    [ -n "$script" ] || continue
    file="$PLUGIN_DIR/$plugin"
    [ -f "$file" ] || fail "the plugin that spawns $script is missing: $file"
    grep -qF "\"bash\"" "$file" \
      || fail "$plugin no longer spawns bash, so $script cannot run on Windows"
    grep -qF "$script" "$file" \
      || fail "$plugin no longer names $script; this pinning needs updating"
  done <<EOF
$PLUGIN_SPAWNED_SCRIPTS
EOF
  pass "opencode plugins: every spawned script is reached through bash"
}

# The uniform fix hard-codes bash instead of honoring each script's own shebang
# line. That is only equivalent while every script it reaches is a bash script,
# so this pins the assumption rather than leaving it to be rediscovered.
test_every_spawned_script_declares_bash() {
  local script plugin shebang
  while IFS='|' read -r script plugin; do
    [ -n "$script" ] || continue
    shebang=$(head -1 "$ROOT/bin/$script")
    [ "$shebang" = '#!/usr/bin/env bash' ] \
      || fail "bin/$script declares '$shebang', so spawning it through bash is no longer equivalent"
  done <<EOF
$PLUGIN_SPAWNED_SCRIPTS
EOF
  pass "opencode plugins: every spawned script is a bash script, so one uniform path stays correct"
}

# Behavior, not just shape: each script must actually execute when spawned the
# way the plugins now spawn it. A rejected argument proves the body parsed it;
# a spawn that never started cannot report one.
test_every_spawned_script_executes_through_bash() {
  local script plugin out
  while IFS='|' read -r script plugin; do
    [ -n "$script" ] || continue
    out=$(SCRIPT="$ROOT/bin/$script" node --input-type=module <<'JS'
import { spawnSync } from "node:child_process";
const r = spawnSync("bash", [process.env.SCRIPT, "--fm-bogus-flag"], { input: "", encoding: "utf8" });
process.stdout.write(`${r.error?.code ?? "none"} ${r.status}`);
JS
    ) || fail "the node probe for $script did not run"
    case "$out" in
      'none '*) : ;;
      *) fail "spawning bin/$script through bash still failed to start: $out" ;;
    esac
  done <<EOF
$PLUGIN_SPAWNED_SCRIPTS
EOF
  pass "opencode plugins: every spawned script starts and runs when reached through bash"
}

test_no_plugin_spawns_a_script_directly
test_every_spawned_script_is_reached_through_bash
test_every_spawned_script_declares_bash
test_every_spawned_script_executes_through_bash
