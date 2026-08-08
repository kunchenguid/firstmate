#!/usr/bin/env bash
# Behavior tests for role-aware generated Firstmate instruction contexts.
# The assertions use Pi's real resource loader and system-prompt builder plus
# generated briefs and the executable startup wrapper, never source snapshots.
#
# Two halves with different prerequisites, in prerequisite order. The startup
# wrapper is a plain script, so its ordering assertion runs on every runner -
# including this file's own pure-contract-unit lane, where Pi is not installed.
# Only the second half needs a real Pi loader, so only it may skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-role-context)
PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/bin" "$PRIMARY/state"

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

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for generated role-context test"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/dist/core/resource-loader.js" ] || \
   [ ! -f "$PI_PACKAGE_DIR/dist/core/system-prompt.js" ]; then
  echo "skip: installed Pi resource loader not found"
  exit 0
fi

HOME_DIR="$TMP_ROOT/home"
OUT="$TMP_ROOT/context.json"
# An empty user-scope Pi agent dir. Without it the loader would pull the
# operator's own SYSTEM.md, settings, packages, and user skills into the
# measured prompt, so the budgets below would grade host material this
# repository does not own.
PI_AGENT_DIR="$TMP_ROOT/pi-agent"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$PI_AGENT_DIR"

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

ROOT="$ROOT" HOME_DIR="$HOME_DIR" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_AGENT_DIR="$PI_AGENT_DIR" \
  node --input-type=module > "$OUT" <<'EOF' || fail "could not build the generated role contexts"
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const pkg = process.env.PI_PACKAGE_DIR;
const root = process.env.ROOT;
const { DefaultResourceLoader } = await import(pathToFileURL(`${pkg}/dist/core/resource-loader.js`).href);
const { buildSystemPrompt } = await import(pathToFileURL(`${pkg}/dist/core/system-prompt.js`).href);
const { formatSkillsForPrompt } = await import(pathToFileURL(`${pkg}/dist/core/skills.js`).href);
const loader = new DefaultResourceLoader({
  cwd: root,
  agentDir: process.env.PI_AGENT_DIR,
  noExtensions: true,
  noPromptTemplates: true,
  noThemes: true,
});
await loader.reload();
// Pi walks upward from cwd for both context files and `.agents/skills` dirs, so
// an operator's own ancestor AGENTS.md and personal skills would otherwise be
// measured here. Keep the graded surface to what this repository owns.
const ownedByRepo = (path) => typeof path === "string" && path.startsWith(`${root}/`);
const contextFiles = loader.getAgentsFiles().agentsFiles.filter((entry) => ownedByRepo(entry.path));
const skills = loader.getSkills().skills.filter((skill) => ownedByRepo(skill.filePath));
const prompt = buildSystemPrompt({
  cwd: root,
  selectedTools: ["read", "bash", "edit", "write", "grep", "find", "ls"],
  contextFiles,
  skills,
});
const rootContext = contextFiles.find((entry) => entry.path === `${root}/AGENTS.md`);
const primaryRuntime = skills.find((skill) => skill.name === "primary-runtime");
const validationSupervision = skills.find((skill) => skill.name === "validation-supervision");
const brief = (id) => readFileSync(`${process.env.HOME_DIR}/data/${id}/brief.md`, "utf8");
console.log(JSON.stringify({
  prompt,
  rootContext: rootContext?.content || "",
  contextPaths: contextFiles.map((entry) => entry.path),
  skillIndex: formatSkillsForPrompt(skills),
  skillNames: skills.map((skill) => skill.name),
  primaryRuntimeBody: primaryRuntime ? readFileSync(primaryRuntime.filePath, "utf8") : "",
  validationSupervisionBody: validationSupervision ? readFileSync(validationSupervision.filePath, "utf8") : "",
  ship: brief("role-ship"),
  scout: brief("role-scout"),
  second: brief("role-second"),
}));
EOF

python3 - "$OUT" "$ROOT" <<'PY' || fail "generated role contexts failed their assertions"
import json, sys
x = json.load(open(sys.argv[1]))
repo = sys.argv[2].rstrip("/")
prompt = x["prompt"]
root = x["rootContext"]
skills = set(x["skillNames"])

def need(value, haystack, label):
    if value not in haystack:
        raise SystemExit(f"not ok - {label}: missing {value!r}")

def reject(value, haystack, label):
    if value in haystack:
        raise SystemExit(f"not ok - {label}: unexpectedly contained {value!r}")

if x["contextPaths"] != [f"{repo}/AGENTS.md"]:
    raise SystemExit(f"not ok - measured context is not repository-owned: {x['contextPaths']}")
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
runtime = x["primaryRuntimeBody"]
need("bin/fm-check-register.sh <id>", runtime, "primary runtime lost the custom-check registration trigger")
need("mode-`0700`", runtime, "primary runtime lost the custom-check file contract")
need("FM_CHECK_TIMEOUT", runtime, "primary runtime lost the custom-check timeout contract")
# Boundaries the session-start digest and the state layout point at this owner
# for. Each one must survive in the runtime the loader actually delivers, or
# the pointer resolves to nothing.
need("`ABSENT` marker", runtime, "primary runtime lost the absent-file semantics")
need("Rebuild an absent or stale `data/projects.md`", runtime, "primary runtime lost the registry rebuild rule")
need("Never hand-edit", runtime, "primary runtime lost the coordination-internals boundary")
need(".claude-autoarm-epoch", runtime, "primary runtime lost the automatic re-arm never-edit boundary")
need(".supervise-daemon.", runtime, "primary runtime lost the supervision-daemon never-edit boundary")
need(".heartbeat-streak", runtime, "primary runtime lost the watcher-internals never-edit boundary")
need("maintain the current home's private", runtime, "primary runtime lost ordinary private record maintenance")
for boundary in (
    "Never write to a project",
    "Never merge without authority",
    "Never discard unlanded work",
    "Report outcomes faithfully",
):
    need(boundary, runtime, f"primary runtime lost relocated boundary {boundary}")
need("load `validation-supervision`", runtime, "primary runtime lost the validation-supervision reachability trigger")
validation = x["validationSupervisionBody"]
for boundary in (
    "worker that starts the run owns every",
    "must not hand-edit, commit, restart, or start another run",
    "implementation worker never answers its own authority finding",
    "Complete supersession",
):
    need(boundary, validation, f"validation supervisor lost relocated boundary {boundary}")
for role in ("ship", "scout"):
    text = x[role]
    worker_context = prompt + text
    need("establishes the ordinary worker role", text, f"{role} brief lost worker role")
    need("do not adopt the Firstmate primary runtime contract", text, f"{role} brief lost primary exclusion")
    need("Reading or editing any file your task assigns you", text, f"{role} brief lost the authorized-edit allowance")
    need("delegate this task", text, f"{role} brief lost direct-work boundary")
    need("current, exact captain authority", worker_context, f"{role} context lost the captain-only authority floor")
    for boundary in ("discard unlanded work", "destructive", "irreversible", "security-sensitive"):
        need(boundary, worker_context, f"{role} context lost the {boundary} boundary")
    need("direct captain intervention", worker_context, f"{role} context lost captain-intervention authority")
    need("reconcile", worker_context, f"{role} context lost captain-intervention reconciliation")
    need("report outcomes faithfully", worker_context, f"{role} context lost faithful outcome reporting")
    reject("captain's only point of contact", worker_context, f"{role} initial context gained primary identity")
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
