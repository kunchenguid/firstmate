#!/usr/bin/env bash
# Skill-catalog contract regression.
# The portable path validates the machine-consumed YAML metadata in every CI run.
# When Pi is installed, its documented extension and RPC APIs additionally prove
# hidden skills stay loaded and command-addressable without entering model context.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HIDDEN_SKILLS='ask-user-authority
bootstrap-diagnostics
captain-hold-lifecycle
decision-hold-lifecycle
diagnostic-reasoning
firstmate-codexapp
firstmate-coding-guidelines
firstmate-orca
fmx-respond
harness-adapters
process-event-sources
project-management
quota-array-dispatch
secondmate-provisioning
stuck-crewmate-recovery'
VISIBLE_SKILLS='afk
ahoy
bearings
stow
updatefirstmate'

command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to validate skill front matter as YAML"
ruby -ryaml - "$ROOT" "$HIDDEN_SKILLS" "$VISIBLE_SKILLS" <<'RB'
root, hidden_text, visible_text = ARGV
hidden = hidden_text.lines(chomp: true).reject(&:empty?).sort
visible = visible_text.lines(chomp: true).reject(&:empty?).sort
expected = (hidden + visible).sort
skills = {}

Dir.glob(File.join(root, ".agents/skills/*/SKILL.md")).sort.each do |path|
  lines = File.readlines(path)
  raise "missing YAML front matter: #{path}" unless lines.first&.strip == "---"

  closing = lines[1..].index { |line| line.strip == "---" }
  raise "unterminated YAML front matter: #{path}" if closing.nil?

  metadata = YAML.safe_load(
    lines[1, closing].join,
    permitted_classes: [],
    permitted_symbols: [],
    aliases: false
  )
  name = metadata.fetch("name")
  directory_name = File.basename(File.dirname(path))
  raise "skill name/path mismatch: #{path}" unless name == directory_name
  raise "duplicate skill name: #{name}" if skills.key?(name)

  skills[name] = metadata
end

raise "unexpected Firstmate skill inventory: #{skills.keys.sort.inspect}" unless skills.keys.sort == expected

hidden.each do |name|
  metadata = skills.fetch(name)
  raise "agent-only skill became user-invocable: #{name}" unless metadata["user-invocable"] == false
  raise "agent-only skill is model-visible: #{name}" unless metadata["disable-model-invocation"] == true
  raise "agent-only skill lost internal metadata: #{name}" unless metadata.dig("metadata", "internal") == true
end

visible.each do |name|
  metadata = skills.fetch(name)
  raise "captain skill became agent-only: #{name}" unless metadata["user-invocable"] == true
  if metadata.key?("disable-model-invocation")
    raise "captain skill gained disable-model-invocation: #{name}"
  end
  raise "captain skill lost internal metadata: #{name}" unless metadata.dig("metadata", "internal") == true
end

puts "ok - portable YAML contract keeps exactly 15 agent-only skills hidden and five captain skills visible"
RB

command -v pi >/dev/null 2>&1 \
  || { echo "skip: pi not found; portable skill-catalog contract passed, installed-Pi behavior not exercised"; exit 0; }
command -v python3 >/dev/null 2>&1 \
  || { echo "skip: python3 not found; portable skill-catalog contract passed, installed-Pi behavior not exercised"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-pi-skill-catalog)
PI_HOME="$TMP_ROOT/pi-agent"
EXTENSION="$TMP_ROOT/catalog-probe.ts"
ALL_CAPTURE="$TMP_ROOT/all-skills.json"
DIRECT_CAPTURE="$TMP_ROOT/direct-hidden-skills.json"

cat > "$EXTENSION" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fm-skill-catalog-probe", {
    baseUrl: "http://127.0.0.1:9/v1",
    apiKey: "local-test-key",
    api: "openai-completions",
    models: [{
      id: "probe",
      name: "Skill catalog probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 1024,
    }],
  });

  pi.registerCommand("fm-capture-skill-catalog", {
    description: "Capture Pi's loaded skill catalog for a behavioral regression",
    handler: async (_args, ctx) => {
      const prompt = ctx.getSystemPrompt();
      writeFileSync(
        process.env.FM_PI_SKILL_CAPTURE!,
        JSON.stringify({
          prompt,
          bytes: Buffer.byteLength(prompt, "utf8"),
          skills: ctx.getSystemPromptOptions().skills,
          commands: pi.getCommands(),
        }),
      );
    },
  });
}
TS

run_probe() {
  local capture=$1
  shift
  printf '%s\n' \
    '{"id":"capture","type":"prompt","message":"/fm-capture-skill-catalog"}' \
    '{"id":"commands","type":"get_commands"}' \
    | PI_CODING_AGENT_DIR="$PI_HOME" PI_OFFLINE=1 FM_PI_SKILL_CAPTURE="$capture" \
      pi --mode rpc --approve --no-session --no-context-files --no-extensions \
        -e "$EXTENSION" --no-skills "$@" --no-prompt-templates --no-themes \
        --model fm-skill-catalog-probe/probe \
        > "$capture.rpc" 2> "$capture.stderr"

  [ -s "$capture" ] || fail "Pi did not publish the skill-catalog capture"
  python3 - "$capture.rpc" <<'PY'
import json
import sys

responses = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
by_id = {record.get("id"): record for record in responses if record.get("type") == "response"}
for request_id in ("capture", "commands"):
    record = by_id.get(request_id)
    if not record or not record.get("success"):
        raise SystemExit(f"missing successful RPC response for {request_id}: {record!r}")
PY
}

run_probe "$ALL_CAPTURE" --skill "$ROOT/.agents/skills"

DIRECT_ARGS=()
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  DIRECT_ARGS+=(--skill "$ROOT/.agents/skills/$skill/SKILL.md")
done <<EOF
$HIDDEN_SKILLS
EOF
run_probe "$DIRECT_CAPTURE" "${DIRECT_ARGS[@]}"

python3 - "$ALL_CAPTURE" "$DIRECT_CAPTURE" "$HIDDEN_SKILLS" "$VISIBLE_SKILLS" <<'PY'
import html
import json
import sys
import xml.etree.ElementTree as ET

all_capture = json.load(open(sys.argv[1], encoding="utf-8"))
direct_capture = json.load(open(sys.argv[2], encoding="utf-8"))
hidden = set(sys.argv[3].splitlines())
visible = set(sys.argv[4].splitlines())
expected = hidden | visible


def loaded_skills(capture):
    return {skill["name"]: skill["description"] for skill in capture["skills"]}


def skill_commands(capture):
    return {
        command["name"][len("skill:"):]
        for command in capture["commands"]
        if command.get("source") == "skill" and command["name"].startswith("skill:")
    }


def prompt_catalog(capture):
    prompt = capture["prompt"]
    opening = "<available_skills>"
    closing = "</available_skills>"
    if opening not in prompt:
        return {}
    start = prompt.index(opening)
    end = prompt.index(closing, start) + len(closing)
    root = ET.fromstring(prompt[start:end])
    return {
        skill.findtext("name"): skill.findtext("description")
        for skill in root.findall("skill")
    }


all_loaded = loaded_skills(all_capture)
if set(all_loaded) != expected:
    raise SystemExit(f"Pi loaded unexpected Firstmate skill set: {sorted(all_loaded)}")

catalog = prompt_catalog(all_capture)
if set(catalog) != visible:
    raise SystemExit(f"automatic model catalog mismatch: {sorted(catalog)}")
for name in visible:
    if catalog[name] != all_loaded[name]:
        raise SystemExit(f"visible description changed in Pi's catalog: {name}")

unescaped_prompt = html.unescape(all_capture["prompt"])
for name in hidden:
    if all_loaded[name] in unescaped_prompt:
        raise SystemExit(f"agent-only description leaked into automatic model context: {name}")

if skill_commands(all_capture) != expected:
    raise SystemExit("Pi did not retain all 20 registered Firstmate skill commands")

direct_loaded = loaded_skills(direct_capture)
if set(direct_loaded) != hidden:
    raise SystemExit(f"explicit --skill paths did not load all hidden skills: {sorted(direct_loaded)}")
if prompt_catalog(direct_capture):
    raise SystemExit("explicitly loaded hidden skills leaked into the automatic model catalog")
if skill_commands(direct_capture) != hidden:
    raise SystemExit("explicitly loaded hidden skills lost their registered commands")

direct_prompt = html.unescape(direct_capture["prompt"])
for name in hidden:
    if direct_loaded[name] in direct_prompt:
        raise SystemExit(f"explicitly loaded hidden description leaked into model context: {name}")

print(
    "ok - Pi kept 15 agent-only skills out of model context while preserving "
    "five visible skills, all commands, and all explicit paths"
)
print(
    f"evidence: pi-skills-loaded={len(all_loaded)} visible={len(catalog)} "
    f"hidden-direct={len(direct_loaded)} prompt-bytes={all_capture['bytes']}"
)
PY
