#!/usr/bin/env bash
# Portable checks for the Claude Code supervision-branch mod
# (.claude/mods/fm-branch-mod, docs/claude-supervision-branch.md) that need no
# Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module plus the one agent it
#     spawns, reached only through --plugin-dir, never through the project's
#     .claude/skills auto-load path, so nothing of it can load into a home that
#     did not launch with it;
#   - the generated agent definition is current with its generator
#     (bin/fm-branch-agent-md.sh) and carries the name and tools the module
#     spawns it with.
# The engine-bound behaviour runs under tests/fm-branch-claude-mod-plugin.test.sh
# and the real session under tests/fm-branch-claude-mod-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/fm-branch-mod"
GENERATOR="$ROOT/bin/fm-branch-agent-md.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code supervision-branch mod checks"; exit 0; }

test_plugin_shape() {
  local out
  [ ! -e "$ROOT/.agents/skills/fm-branch-mod" ] \
    || fail "the mod is linked into .agents/skills, so every Claude home would adopt its agent and hooks without launching with --plugin-dir"
  [ ! -e "$ROOT/.claude/skills/fm-branch-mod" ] \
    || fail "the mod is reachable from the project's .claude/skills auto-load path"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync, existsSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "fm-branch-mod") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}: only the default hooks/ and agents/ folders may load\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./branch.ts"])) throw new Error("hooks.json names a different module");
if (!existsSync(\`\${mod}/hooks/branch.ts\`)) throw new Error("the hooks module is missing");
const agents = readdirSync(\`\${mod}/agents\`).sort();
if (JSON.stringify(agents) !== JSON.stringify(["fm-branch.md"])) throw new Error(\`agents/ holds \${agents.join(", ")}: only the one branch agent may exist\`);
const entries = readdirSync(mod).filter((name) => name !== ".claude-plugin").sort();
if (JSON.stringify(entries) !== JSON.stringify(["agents", "classifier-system.txt", "hooks", "lib", "tests"])) {
  throw new Error(\`the mod folder holds \${entries.join(", ")}: only agents, classifier-system.txt, hooks, lib, and tests may exist\`);
}
console.log("shape-ok");
JS
  out=$(node --input-type=module <"$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the mod is one hooks module and one agent, reached only through --plugin-dir, with no command, skill, or classic hook path"
}

test_agent_definition_is_generated_and_current() {
  local out frontmatter
  out=$("$GENERATOR" --check 2>&1) || fail "the tracked agent definition is stale against its generator: $out"
  frontmatter=$(awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$MOD/agents/fm-branch.md") \
    || fail "agents/fm-branch.md does not open with a frontmatter block"
  printf '%s\n' "$frontmatter" | grep -qx 'name: fm-branch' \
    || fail "the agent is not named fm-branch, which the module spawns as fm-branch-mod:fm-branch: $frontmatter"
  printf '%s\n' "$frontmatter" | grep -q '^tools: .*\bBash\b' \
    || fail "the branch agent cannot run the fleet scripts without Bash: $frontmatter"
  printf '%s\n' "$frontmatter" | grep -q '^tools: .*mcp__fm-branch-mod__fm_branch_report' \
    || fail "the branch agent cannot report an outcome without the module's fm_branch_report tool: $frontmatter"
  out=$("$GENERATOR" --print) || fail "the generator cannot print the definition"
  [ "$out" = "$(cat "$MOD/agents/fm-branch.md")" ] || fail "--print differs from the tracked definition"
  "$GENERATOR" --bogus >/dev/null 2>&1 && fail "an unknown generator argument was accepted"
  pass "agents/fm-branch.md is current with bin/fm-branch-agent-md.sh and names the agent and tools the module spawns"
}

test_lib_resolves_to_the_mod_canonical_modules() {
  local module
  # The canon is inverted (docs/calm.md is the precedent): the mod's lib/
  # holds the canonical shared modules a hooks module can import, and the
  # repo's lib/ entries point at them - the nine tracked module symlinks
  # below plus lib/fm-branch-eligibility-core.ts, and one wrapper that
  # re-exports the eligibility core and adds its node:fs bindings.
  # Assert the layout contract through the filesystem, then load
  # the wrapper to prove it re-exports the core; the hooks-module validator
  # run by fm-branch-claude-mod-plugin.test.sh owns the no-node:-imports
  # check.
  for module in fm-branch-report-sequence.ts fm-branch-provider-latch.ts fm-branch-classifier.ts fm-branch-text.ts fm-branch-scope.ts fm-branch-routing.ts fm-branch-delivery.ts fm-branch-monitor.ts fm-branch-settlement.ts; do
    [ -L "$ROOT/lib/$module" ] || fail "lib/$module is not a symlink; the canonical copy lives under the mod"
    [ "$(readlink "$ROOT/lib/$module")" = "../.claude/mods/fm-branch-mod/lib/$module" ] \
      || fail "lib/$module points at $(readlink "$ROOT/lib/$module" 2>/dev/null || echo nothing), expected the mod's canonical file"
    [ -f "$ROOT/lib/$module" ] || fail "lib/$module does not resolve to the mod's canonical file"
  done
  [ -L "$ROOT/lib/fm-branch-eligibility-core.ts" ] || fail "lib/fm-branch-eligibility-core.ts is not a symlink; the wrapper needs its core sibling"
  [ "$(readlink "$ROOT/lib/fm-branch-eligibility-core.ts")" = "../.claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts" ] \
    || fail "lib/fm-branch-eligibility-core.ts points at $(readlink "$ROOT/lib/fm-branch-eligibility-core.ts" 2>/dev/null || echo nothing), expected the mod's canonical core"
  [ -f "$ROOT/lib/fm-branch-eligibility.ts" ] && [ ! -L "$ROOT/lib/fm-branch-eligibility.ts" ] \
    || fail "lib/fm-branch-eligibility.ts must be the wrapper file that adds the node:fs bindings"
  node --experimental-strip-types -e 'import(process.argv[1] + "/lib/fm-branch-eligibility.ts").then((m) => { if (typeof m.scanStateDirectory !== "function" || typeof m.foldStatusLog !== "function") { console.error("wrapper bindings missing"); process.exit(1); } if (typeof m.scopeForUnreadWake !== "function" || typeof m.foldStatusLines !== "function") { console.error("core re-exports missing"); process.exit(1); } }).catch((e) => { console.error(String(e)); process.exit(1); })' "$ROOT" >/dev/null 2>&1 \
    || fail "the eligibility wrapper does not load and re-export the mod's core with its bindings"
  pass "lib/ resolves to the mod's canonical modules and the eligibility wrapper loads"
}

test_plugin_shape
test_agent_definition_is_generated_and_current
test_lib_resolves_to_the_mod_canonical_modules
