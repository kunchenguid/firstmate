#!/usr/bin/env bash
# Behavior tests for role-aware generated Firstmate instruction contexts.
# The assertions use Pi's real resource loader and system-prompt builder plus
# generated briefs and the executable startup wrapper, never source snapshots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for generated role-context test"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/dist/core/resource-loader.js" ] || \
   [ ! -f "$PI_PACKAGE_DIR/dist/core/system-prompt.js" ]; then
  echo "skip: installed Pi resource loader not found"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-role-context)
HOME_DIR="$TMP_ROOT/home"
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/context.json"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$PRIMARY/bin" "$PRIMARY/state"

FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-brief.sh" role-ship firstmate --mode no-mistakes >/dev/null \
  || fail "could not generate role-aware ship brief"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-brief.sh" role-scout firstmate --scout >/dev/null \
  || fail "could not generate role-aware scout brief"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SECONDMATE_CHARTER='Own role-aware context verification.' \
  FM_SECONDMATE_SCOPE='Firstmate instruction architecture.' \
  "$ROOT/bin/fm-brief.sh" role-second --secondmate --no-projects >/dev/null \
  || fail "could not generate role-aware second-mate charter"

ROOT="$ROOT" HOME_DIR="$HOME_DIR" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module > "$OUT" <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const pkg = process.env.PI_PACKAGE_DIR;
const { DefaultResourceLoader } = await import(pathToFileURL(`${pkg}/dist/core/resource-loader.js`).href);
const { buildSystemPrompt } = await import(pathToFileURL(`${pkg}/dist/core/system-prompt.js`).href);
const { formatSkillsForPrompt } = await import(pathToFileURL(`${pkg}/dist/core/skills.js`).href);
const loader = new DefaultResourceLoader({
  cwd: process.env.ROOT,
  agentDir: process.env.PI_CODING_AGENT_DIR || `${process.env.HOME}/.pi/agent`,
  noExtensions: true,
  noPromptTemplates: true,
  noThemes: true,
});
await loader.reload();
const contextFiles = loader.getAgentsFiles().agentsFiles;
const skills = loader.getSkills().skills;
const prompt = buildSystemPrompt({
  cwd: process.env.ROOT,
  selectedTools: ["read", "bash", "edit", "write", "grep", "find", "ls"],
  contextFiles,
  skills,
});
const rootContext = contextFiles.find((entry) => entry.path === `${process.env.ROOT}/AGENTS.md`);
const brief = (id) => readFileSync(`${process.env.HOME_DIR}/data/${id}/brief.md`, "utf8");
console.log(JSON.stringify({
  prompt,
  rootContext: rootContext?.content || "",
  skillIndex: formatSkillsForPrompt(skills),
  skillNames: skills.map((skill) => skill.name),
  ship: brief("role-ship"),
  scout: brief("role-scout"),
  second: brief("role-second"),
}));
EOF

python3 - "$OUT" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
prompt = x["prompt"]
root = x["rootContext"]
skills = set(x["skillNames"])

def need(value, haystack, label):
    if value not in haystack:
        raise SystemExit(f"not ok - {label}: missing {value!r}")

def reject(value, haystack, label):
    if value in haystack:
        raise SystemExit(f"not ok - {label}: unexpectedly contained {value!r}")

need("# Firstmate repository contract", prompt, "generated system prompt lost the universal gateway")
need("Primary and second-mate runtime loading", prompt, "generated system prompt lost the compact primary fallback")
need("Never write to a project", root, "compact fallback lost project-write protection")
need("Never merge without", root, "compact fallback lost merge authority")
need("Never force, stash, reset, delete", root, "compact fallback lost no-discard protection")
need("drain the durable notification queue before", root, "compact fallback lost notification ordering")
need("Never end a turn blind", root, "compact fallback lost supervision continuity")
reject("You are the captain's only point of contact", prompt, "universal prompt retained primary identity")
reject("delegate coding, investigation, planning", prompt, "universal prompt retained primary delegation prohibition")
for name in (
    "primary-runtime",
    "validation-supervision",
    "project-management",
    "stuck-crewmate-recovery",
    "afk",
    "fmx-respond",
    "quota-array-dispatch",
):
    if name not in skills:
        raise SystemExit(f"not ok - generated skill discovery missed {name}")
    need(name, x["skillIndex"], f"generated skill index missed {name}")
if len(root) > 12000:
    raise SystemExit(f"not ok - universal root context is {len(root)} chars, budget is 12000")
if len(prompt) > 40000:
    raise SystemExit(f"not ok - generated universal system prompt is {len(prompt)} chars, budget is 40000")
for role in ("ship", "scout"):
    text = x[role]
    need("establishes the ordinary worker role", text, f"{role} brief lost worker role")
    need("do not load the Firstmate primary runtime", text, f"{role} brief lost primary exclusion")
    need("delegate this task", text, f"{role} brief lost direct-work boundary")
    reject("captain's only point of contact", prompt + text, f"{role} initial context gained primary identity")
second = x["second"]
need("primary-runtime/SKILL.md", second, "second-mate charter lost primary runtime load")
need("marked return channel", second, "second-mate charter lost return-channel authority")
need("idle-by-default", second, "second-mate charter lost idle behavior")
print(
    "ok - generated role contexts: "
    f"root={len(root)} system={len(prompt)} skills={len(skills)} "
    f"ship={len(x['ship'])} scout={len(x['scout'])} second={len(second)}"
)
PY

cp "$ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
  "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$PRIMARY/bin/"
chmod +x "$PRIMARY/bin/fm-sessionstart-nudge.sh"
git init -q "$PRIMARY"
fm_git_identity fixture fixture@example.invalid
git -C "$PRIMARY" config commit.gpgsign false
git -C "$PRIMARY" add AGENTS.md bin
git -C "$PRIMARY" commit -qm fixture
nudge=$(FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" "$PRIMARY/bin/fm-sessionstart-nudge.sh") \
  || fail "primary startup wrapper failed"
case "$nudge" in
  *primary-runtime/SKILL.md*fm-session-start.sh*) ;;
  *) fail "primary startup wrapper did not load runtime before session start: $nudge" ;;
esac
case "$nudge" in
  *"before any other operational instruction or fleet mutation"*) ;;
  *) fail "primary startup wrapper did not prevent pre-runtime mutation: $nudge" ;;
esac
pass "role-aware startup wrapper orders the runtime owner before primary mutation"
