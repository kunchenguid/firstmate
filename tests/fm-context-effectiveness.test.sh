#!/usr/bin/env bash
# Behavioral regressions for measured context-effectiveness contracts that can run without provider credentials.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-effectiveness)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
REMOTE_SOURCE=git:github.com/algal/pi-openai-server-compaction

[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed @earendil-works/pi-coding-agent package not found"; exit 0; }

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

apply_native_settings_merge() {
  local settings=$1 backup=$2
  python3 - "$settings" "$backup" "$REMOTE_SOURCE" <<'PY'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

settings = Path(sys.argv[1])
backup = Path(sys.argv[2])
source = sys.argv[3]
raw = settings.read_bytes()
document = json.loads(raw.decode("utf-8"))
if not isinstance(document, dict):
    raise SystemExit("settings root must be an object")
packages = document.get("packages")
if not isinstance(packages, list):
    raise SystemExit("settings packages must already be an array")
matching = [
    index
    for index, package in enumerate(packages)
    if package == source or (isinstance(package, dict) and package.get("source") == source)
]
if len(matching) != 1:
    raise SystemExit(f"expected one installed remote package declaration, found {len(matching)}")
current_compaction = document.get("compaction", {})
if not isinstance(current_compaction, dict):
    raise SystemExit("settings compaction must be an object when present")
mode = stat.S_IMODE(settings.stat().st_mode)
fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
with os.fdopen(fd, "wb") as stream:
    stream.write(raw)
next_packages = list(packages)
current_package = packages[matching[0]]
if isinstance(current_package, str):
    next_package = {"source": source, "extensions": []}
else:
    next_package = dict(current_package)
    next_package["extensions"] = []
next_packages[matching[0]] = next_package
next_compaction = dict(current_compaction)
next_compaction.update({
    "enabled": True,
    "reserveTokens": 16384,
    "keepRecentTokens": 12000,
})
next_document = dict(document)
next_document["packages"] = next_packages
next_document["compaction"] = next_compaction
handle, temporary = tempfile.mkstemp(prefix="settings.json.", dir=settings.parent)
try:
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump(next_document, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    os.chmod(temporary, mode)
    os.replace(temporary, settings)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

settings_match_narrow_merge() {
  local settings=$1 backup=$2
  python3 - "$settings" "$backup" "$REMOTE_SOURCE" <<'PY'
import json
import sys
from pathlib import Path

current = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
prior = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
source = sys.argv[3]
expected = dict(prior)
packages = list(prior["packages"])
matching = [
    index
    for index, package in enumerate(packages)
    if package == source or (isinstance(package, dict) and package.get("source") == source)
]
assert len(matching) == 1
package = packages[matching[0]]
packages[matching[0]] = (
    {"source": source, "extensions": []}
    if isinstance(package, str)
    else {**package, "extensions": []}
)
expected["packages"] = packages
expected["compaction"] = {
    **prior.get("compaction", {}),
    "enabled": True,
    "reserveTokens": 16384,
    "keepRecentTokens": 12000,
}
assert current == expected
PY
}

package_resources_match_policy() {
  local project=$1 agent_dir=$2
  mkdir -p "$agent_dir"
  PI_OFFLINE=1 node --input-type=module - "$project" "$agent_dir" "$PI_PACKAGE_DIR" <<'NODE'
import { join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const project = process.argv[2];
const agentDir = process.argv[3];
const packageDir = process.argv[4];
const { SettingsManager } = await import(pathToFileURL(join(packageDir, "dist/core/settings-manager.js")));
const { DefaultPackageManager } = await import(pathToFileURL(join(packageDir, "dist/core/package-manager.js")));
const settings = SettingsManager.create(project, agentDir);
const manager = new DefaultPackageManager({ cwd: project, agentDir, settingsManager: settings });
const resources = await manager.resolve();
const clone = resolve(project, ".pi/git/github.com/algal/pi-openai-server-compaction");
const isFromPackage = (entry) => {
  const candidate = resolve(entry.path);
  return candidate === clone || candidate.startsWith(`${clone}${sep}`);
};
const extensions = resources.extensions.filter(isFromPackage);
const skills = resources.skills.filter(isFromPackage);
if (extensions.length !== 1 || extensions.some((entry) => entry.enabled)) {
  throw new Error(`expected one disabled package extension, got ${JSON.stringify(extensions)}`);
}
if (skills.length !== 1 || skills.some((entry) => !entry.enabled)) {
  throw new Error(`expected one enabled package skill, got ${JSON.stringify(skills)}`);
}
if (!settings.getCompactionEnabled()) throw new Error("native compaction disabled");
if (settings.getCompactionReserveTokens() !== 16384) throw new Error("reserve mismatch");
if (settings.getCompactionKeepRecentTokens() !== 12000) throw new Error("recent-tail mismatch");
NODE
}

test_local_settings_merge_preserves_unrelated_state_and_disables_only_extensions() {
  local project backup overwrite_mutant filter_mutant
  project="$TMP_ROOT/settings-project"
  mkdir -p "$project/.pi"
  git -C "$project" init -q
  write_package_fixture "$project"
  write_initial_settings "$project"
  backup="$project/settings.before.json"
  apply_native_settings_merge "$project/.pi/settings.json" "$backup" \
    || fail "native settings handoff merge failed on a valid object-form package fixture"
  settings_match_narrow_merge "$project/.pi/settings.json" "$backup" \
    || fail "native settings handoff did not preserve every unrelated settings field"
  package_resources_match_policy "$project" "$TMP_ROOT/settings-agent" \
    || fail "Pi did not keep package resources available while disabling only its extension"

  overwrite_mutant="$TMP_ROOT/settings-overwrite-mutant"
  cp "$backup" "$overwrite_mutant.before"
  cat > "$overwrite_mutant" <<JSON
{"packages":[{"source":"$REMOTE_SOURCE","extensions":[]}],"compaction":{"enabled":true,"reserveTokens":16384,"keepRecentTokens":12000}}
JSON
  if settings_match_narrow_merge "$overwrite_mutant" "$overwrite_mutant.before" 2>/dev/null; then
    fail "settings preservation check survived a realistic whole-file overwrite mutation"
  fi

  filter_mutant="$TMP_ROOT/settings-filter-mutant"
  cp -R "$project" "$filter_mutant"
  python3 - "$filter_mutant/.pi/settings.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
for package in data["packages"]:
    if isinstance(package, dict) and package.get("source") == "git:github.com/algal/pi-openai-server-compaction":
        package.pop("extensions", None)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  if package_resources_match_policy "$filter_mutant" "$TMP_ROOT/filter-mutant-agent" >/dev/null 2>&1; then
    fail "package-resource behavior check survived removal of the extensions-empty filter"
  fi
  pass "Pi preserves unrelated local settings and keeps the remote package available with only its extension disabled"
}

test_installed_pi_version_is_recorded_without_claiming_broader_compatibility() {
  local runtime_version package_version
  runtime_version=$(pi --version)
  package_version=$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.version)' "$PI_PACKAGE_DIR/package.json")
  [ "$runtime_version" = "$package_version" ] \
    || fail "Pi CLI and installed package versions differ: cli=$runtime_version package=$package_version"
  [ "$runtime_version" = 0.83.0 ] \
    || fail "measured context-effectiveness fixture requires exact Pi 0.83.0, found $runtime_version"
  pass "context-effectiveness behavior checks run against exact installed Pi $runtime_version"
}

test_skill_discovery_and_trigger_precision
test_local_settings_merge_preserves_unrelated_state_and_disables_only_extensions
test_installed_pi_version_is_recorded_without_claiming_broader_compatibility
