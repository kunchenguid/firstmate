#!/usr/bin/env bash
# Exercise the real Pi loader with the compiled primary prompt and compact skills.
# The temporary extension captures structured loader inputs from an extension
# command, which bypasses the agent loop; a before_provider_request sentinel
# proves provider work did not begin.  This is Pi-only by design.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-prompt-pi.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
PROMPT="$TMP/primary.md"
CAPTURE="$TMP/capture.json"
PROVIDER="$TMP/provider-called"
python3 "$SCRIPT_DIR/fm-prompt-compile.py" --role primary --harness pi --runtime tmux --output "$PROMPT"
cat > "$TMP/capture.ts" <<'TS'
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.registerCommand("capture-loader", {
    description: "Capture loader state without an agent turn",
    handler: async (_args, ctx) => {
      const options = ctx.getSystemPromptOptions();
      writeFileSync(process.env.FM_PI_CAPTURE!, JSON.stringify({
        customPrompt: options.customPrompt,
        skills: options.skills?.map((skill) => ({
          name: skill.name,
          description: skill.description,
          filePath: skill.filePath,
          baseDir: skill.baseDir,
        })) ?? [],
        skillCommands: pi.getCommands()
          .filter((command) => command.source === "skill")
          .map((command) => ({ name: command.name, description: command.description })),
      }));
    },
  });
  pi.on("before_provider_request", () => {
    writeFileSync(process.env.FM_PI_PROVIDER_SENTINEL!, "called\n");
  });
}
TS
set +e
(
  cd "$TMP"
  FM_PI_CAPTURE="$CAPTURE" FM_PI_PROVIDER_SENTINEL="$PROVIDER" \
    pi --offline --no-session --no-extensions --extension "$TMP/capture.ts" \
      --no-context-files --no-tools --no-skills --skill "$ROOT/.agents/skills" \
      --system-prompt "$PROMPT" --print /capture-loader >/dev/null 2>"$TMP/pi.err"
)
rc=$?
set -e
[ -f "$CAPTURE" ] || { cat "$TMP/pi.err" >&2; echo "fm-prompt-pi-offline-check: Pi did not execute the loader command (exit $rc)" >&2; exit 1; }
[ ! -e "$PROVIDER" ] || { echo "fm-prompt-pi-offline-check: provider work began" >&2; exit 1; }
python3 - "$ROOT" "$PROMPT" "$CAPTURE" <<'PY'
import json,re,sys
from pathlib import Path
root,prompt,capture=map(Path,sys.argv[1:])
value=json.loads(capture.read_text())
if value.get('customPrompt') != prompt.read_text():
    raise SystemExit('fm-prompt-pi-offline-check: compiled prompt did not load exactly')
expected=[]
for path in sorted((root/'.agents/skills').glob('*/SKILL.md')):
    front=path.read_text().split('---',2)[1]
    name=re.search(r'^name:\s*(.+)$',front,re.M).group(1).strip()
    description=re.search(r'^description:\s*(.+)$',front,re.M).group(1).strip()
    expected.append({
        'name':name,
        'description':description,
        'filePath':str(path),
        'baseDir':str(path.parent),
    })
actual=sorted(value.get('skills',[]),key=lambda item:item['name'])
expected.sort(key=lambda item:item['name'])
if actual != expected:
    raise SystemExit(f'fm-prompt-pi-offline-check: compact skill discovery mismatch expected={len(expected)} actual={len(actual)}')
commands=sorted(value.get('skillCommands',[]),key=lambda item:item['name'])
expected_commands=[{'name':f"skill:{item['name']}",'description':item['description']} for item in expected]
if commands != expected_commands:
    raise SystemExit(f'fm-prompt-pi-offline-check: skill command contract mismatch expected={len(expected_commands)} actual={len(commands)}')
print(f'PASS Pi offline loader: compiled primary prompt and {len(actual)} compact skills loaded; provider request aborted')
PY
