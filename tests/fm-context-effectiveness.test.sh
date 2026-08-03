#!/usr/bin/env bash
# Behavioral regressions for measured context-effectiveness contracts that can run without provider credentials.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-effectiveness)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
REMOTE_SOURCE=git:github.com/algal/pi-openai-server-compaction
HANDOFF_DOC="$ROOT/docs/verification/context-effectiveness.md"
MEASURED_PI_VERSION=0.83.0

# The measured matrix in docs/verification/context-effectiveness.md is scoped to
# one exact Pi build, and these checks drive that build's own dist modules. A
# different installed version is recorded as a skip rather than a failure so a
# routine Pi upgrade does not redden the default family.
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed @earendil-works/pi-coding-agent package not found"; exit 0; }
PI_PACKAGE_VERSION=$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$PI_PACKAGE_DIR/package.json" 2>/dev/null) \
  || PI_PACKAGE_VERSION=
[ "$PI_PACKAGE_VERSION" = "$MEASURED_PI_VERSION" ] || {
  echo "skip: measured context-effectiveness matrix records exact Pi $MEASURED_PI_VERSION, installed package is ${PI_PACKAGE_VERSION:-unreadable}"
  exit 0
}

load_skill_metadata() {
  local project=$1 agent_dir=$2
  mkdir -p "$agent_dir"
  node --input-type=module - "$project" "$agent_dir" "$PI_PACKAGE_DIR" <<'NODE'
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const project = process.argv[2];
const agentDir = process.argv[3];
const packageDir = process.argv[4];
const moduleUrl = pathToFileURL(join(packageDir, "dist/core/resource-loader.js"));
const { DefaultResourceLoader } = await import(moduleUrl);
const loader = new DefaultResourceLoader({
  cwd: project,
  agentDir,
  noExtensions: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const matches = loader.getSkills().skills.filter((skill) => skill.name === "evidence-consumption");
if (matches.length !== 1) throw new Error(`expected one evidence-consumption skill, found ${matches.length}`);
const skill = matches[0];
console.log(JSON.stringify({ name: skill.name, description: skill.description, filePath: skill.filePath }));
NODE
}

metadata_has_precise_trigger() {
  local metadata=$1
  python3 - "$metadata" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
description = data["description"]
required = [
    "long report",
    "broad GitHub response",
    "process listing",
    "validation log",
    "repeated unchanged live evidence",
]
assert data["name"] == "evidence-consumption"
assert all(term in description for term in required)
PY
}

test_skill_discovery_and_trigger_precision() {
  local metadata mutant metadata_mutant
  metadata=$(load_skill_metadata "$ROOT" "$TMP_ROOT/agent-actual") \
    || fail "Pi could not discover the evidence-consumption skill through its resource loader"
  metadata_has_precise_trigger "$metadata" \
    || fail "discovered evidence-consumption metadata lost one of its precise trigger surfaces"

  mutant="$TMP_ROOT/skill-mutant"
  mkdir -p "$mutant/.agents/skills/evidence-consumption"
  git -C "$mutant" init -q
  cat > "$mutant/.agents/skills/evidence-consumption/SKILL.md" <<'MD'
---
name: evidence-consumption
description: Use before consuming a long report, broad GitHub response, process listing, or repeated unchanged live evidence.
user-invocable: false
metadata:
  internal: true
---

# Evidence consumption

Mutation fixture with an incomplete trigger.
MD
  metadata_mutant=$(load_skill_metadata "$mutant" "$TMP_ROOT/agent-mutant") \
    || fail "Pi could not discover the realistic skill mutation fixture"
  if metadata_has_precise_trigger "$metadata_mutant" 2>/dev/null; then
    fail "skill-discovery behavior check survived a missing validation-log trigger mutation"
  fi
  pass "Pi discovers one agent-only evidence skill and the trigger rejects a realistic omitted-surface mutation"
}

# --- documented-handoff execution -------------------------------------------
#
# The maintainer artifact is the labelled shell block in the verification
# record, so these checks extract and run that exact text instead of a copy.
# Editing a block without updating this test therefore fails here.

handoff_block() {
  local label=$1
  awk -v opener="\`\`\`sh fm-handoff=$label" '
    $0 == opener { capture = 1; found = 1; next }
    capture && $0 == "```" { capture = 0; next }
    capture { print }
    END { if (!found) exit 1 }
  ' "$HANDOFF_DOC"
}

run_handoff_block() {
  local label=$1 home=$2 agent_dir=${3:-} context body
  context=$(handoff_block context) || fail "docs handoff block 'context' is missing from $HANDOFF_DOC"
  body=$(handoff_block "$label") || fail "docs handoff block '$label' is missing from $HANDOFF_DOC"
  if [ -n "$agent_dir" ]; then mkdir -p "$agent_dir"; fi
  FM_PRIMARY_HOME="$home" FM_PI_PACKAGE_DIR="$PI_PACKAGE_DIR" FM_PI_AGENT_DIR="$agent_dir" \
    bash -c "$context"$'\n'"$body"
}

write_package_fixture() {
  local project=$1
  mkdir -p "$project/.pi/git/github.com/algal/pi-openai-server-compaction/extensions" \
    "$project/.pi/git/github.com/algal/pi-openai-server-compaction/skills/fixture"
  cat > "$project/.pi/git/github.com/algal/pi-openai-server-compaction/package.json" <<'JSON'
{
  "name": "pi-openai-server-compaction",
  "version": "0.1.0",
  "pi": {
    "extensions": ["extensions/remote.ts"],
    "skills": ["skills"]
  }
}
JSON
  cat > "$project/.pi/git/github.com/algal/pi-openai-server-compaction/extensions/remote.ts" <<'TS'
export default function fixtureExtension() {}
TS
  cat > "$project/.pi/git/github.com/algal/pi-openai-server-compaction/skills/fixture/SKILL.md" <<'MD'
---
name: fixture-package-skill
description: Proves that non-extension package resources remain available.
---

# Fixture package skill
MD
}

write_initial_settings() {
  local project=$1
  mkdir -p "$project/.pi"
  cat > "$project/.pi/settings.json" <<JSON
{
  "theme": "fixture-theme",
  "retry": {"maxRetries": 7},
  "futureTopLevel": {"preserve": true},
  "packages": [
    "npm:unrelated-package",
    {
      "source": "$REMOTE_SOURCE",
      "futurePackageField": "preserve"
    }
  ],
  "compaction": {
    "enabled": false,
    "keepRecentTokens": 20000,
    "futureCompactionField": "preserve"
  }
}
JSON
}

write_primary_home_fixture() {
  local project=$1
  mkdir -p "$project"
  git -C "$project" init -q
  write_package_fixture "$project"
  write_initial_settings "$project"
}

test_documented_handoff_preserves_unrelated_state_and_disables_only_extensions() {
  local project backup overwrite_mutant filter_mutant out
  project="$TMP_ROOT/settings-project"
  backup="$project/data/pi-settings-before-native-12k.json"
  write_primary_home_fixture "$project"

  run_handoff_block apply "$project" >/dev/null \
    || fail "documented native settings handoff failed on a valid object-form package fixture"
  run_handoff_block verify "$project" >/dev/null \
    || fail "documented handoff did not preserve every unrelated settings field"
  out=$(run_handoff_block resolve "$project" "$TMP_ROOT/settings-agent") \
    || fail "Pi did not keep package resources available while disabling only its extension"
  assert_contains "$out" "package extensions=1 disabled" \
    "documented resolver check did not report the disabled package extension"
  assert_contains "$out" "package skills=1 enabled" \
    "documented resolver check did not report the still-available package skill"

  overwrite_mutant="$TMP_ROOT/settings-overwrite-mutant"
  mkdir -p "$overwrite_mutant/.pi" "$overwrite_mutant/data"
  cp "$backup" "$overwrite_mutant/data/pi-settings-before-native-12k.json"
  cat > "$overwrite_mutant/.pi/settings.json" <<JSON
{"packages":[{"source":"$REMOTE_SOURCE","extensions":[]}],"compaction":{"enabled":true,"reserveTokens":16384,"keepRecentTokens":12000}}
JSON
  if run_handoff_block verify "$overwrite_mutant" >/dev/null 2>&1; then
    fail "documented preservation check survived a realistic whole-file overwrite mutation"
  fi

  filter_mutant="$TMP_ROOT/settings-filter-mutant"
  cp -R "$project" "$filter_mutant"
  python3 - "$filter_mutant/.pi/settings.json" "$REMOTE_SOURCE" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
source = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
for package in data["packages"]:
    if isinstance(package, dict) and package.get("source") == source:
        package.pop("extensions", None)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  if run_handoff_block resolve "$filter_mutant" "$TMP_ROOT/filter-mutant-agent" >/dev/null 2>&1; then
    fail "documented package-resource check survived removal of the extensions-empty filter"
  fi
  pass "the documented handoff preserves unrelated local settings and keeps the remote package available with only its extension disabled"
}

test_documented_handoff_is_reversible_and_refuses_unsafe_preconditions() {
  local project backup duplicate settled
  project="$TMP_ROOT/rollback-project"
  backup="$project/data/pi-settings-before-native-12k.json"
  write_primary_home_fixture "$project"

  run_handoff_block apply "$project" >/dev/null \
    || fail "documented native settings handoff failed on the rollback fixture"
  settled=$(cat "$project/.pi/settings.json")
  if run_handoff_block apply "$project" >/dev/null 2>&1; then
    fail "documented handoff overwrote an existing exact backup on a second run"
  fi
  [ "$(cat "$project/.pi/settings.json")" = "$settled" ] \
    || fail "documented handoff mutated settings while refusing to overwrite an existing backup"

  run_handoff_block rollback "$project" >/dev/null \
    || fail "documented rollback failed to restore the exact backup"
  cmp -s "$project/.pi/settings.json" "$backup" \
    || fail "documented rollback did not restore the exact prior settings bytes"

  duplicate="$TMP_ROOT/duplicate-declaration"
  mkdir -p "$duplicate/.pi"
  cat > "$duplicate/.pi/settings.json" <<JSON
{"packages":["$REMOTE_SOURCE",{"source":"$REMOTE_SOURCE"}],"compaction":{}}
JSON
  if run_handoff_block apply "$duplicate" >/dev/null 2>&1; then
    fail "documented handoff accepted a duplicate remote package declaration"
  fi
  assert_absent "$duplicate/data/pi-settings-before-native-12k.json" \
    "documented handoff wrote a backup before refusing a duplicate package declaration"
  pass "the documented handoff refuses duplicate declarations and backup overwrites, and rolls back to exact prior bytes"
}

test_installed_pi_version_is_recorded_without_claiming_broader_compatibility() {
  local runtime_version
  if ! command -v pi >/dev/null 2>&1; then
    echo "skip: pi not on PATH, so the installed Pi $PI_PACKAGE_VERSION CLI version could not be recorded"
    return 0
  fi
  runtime_version=$(pi --version 2>/dev/null) || runtime_version=
  if [ "$runtime_version" != "$PI_PACKAGE_VERSION" ]; then
    echo "skip: Pi CLI and installed package versions differ (cli=${runtime_version:-unreadable} package=$PI_PACKAGE_VERSION)"
    return 0
  fi
  pass "context-effectiveness behavior checks run against exact installed Pi $runtime_version"
}

test_skill_discovery_and_trigger_precision
test_documented_handoff_preserves_unrelated_state_and_disables_only_extensions
test_documented_handoff_is_reversible_and_refuses_unsafe_preconditions
test_installed_pi_version_is_recorded_without_claiming_broader_compatibility
