#!/usr/bin/env bash
# Install or remove Firstmate's guarded agy crew turn-end hook.
#
# This command is the sole owner of the edit to $HOME/.gemini/config/hooks.json.
# agy's hooks file is a JSON object whose top-level keys are named hooks, so
# Firstmate owns exactly one key - "firstmate-turn-end" - and every other named
# hook, including the operator's own, is read back and rewritten untouched.
# Missing, malformed, symlinked, or otherwise surprising config is refused
# without a config write.
#
# The installed Stop hook always prints "{}" and exits 0 so it can neither block
# a turn nor keep the agent looping. It fires ONLY when the payload reports
# fullyIdle true, reads workspacePaths from the payload, checks for a
# .fm-agy-turnend pointer before registry work, and touches a task turn-end
# marker only when the pointer names a Firstmate-created token in
# $HOME/.gemini/antigravity-cli/fm-turn-end.d/.
#
# THE fullyIdle GATE IS LOAD-BEARING. agy moves a shell command that outruns its
# WaitMsBeforeAsync into the background, yields the composer, and fires Stop with
# fullyIdle false while that command is still running; a second Stop with
# fullyIdle true follows once the command finishes and the agent has reported it
# (verified on agy 1.1.25 with a 40s sleep: two Stop events, false then true).
# Waking firstmate on the first one would report a worker done while its own
# build or test run is still going.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,27{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-agy-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'fm-agy-turnend-hook: refused: node is required to edit hooks.json and by the installed hook.\n' >&2
  exit 1
fi

# The shared answer to "can anyone but this user write a directory on the way to
# this path", owned by one file and called from here and from fm-agy-trust.sh.
case $0 in */*) FM_BIN_SRC=${0%/*} ;; *) FM_BIN_SRC=. ;; esac
PATH_TRUST=$(cd -P -- "$FM_BIN_SRC" && pwd -P)/fm-path-trust.mjs
if [ ! -f "$PATH_TRUST" ]; then
  printf 'fm-agy-turnend-hook: refused: the shared path-trust check is missing at %s.\n' "$PATH_TRUST" >&2
  exit 1
fi

node - "$ACTION" "$HOME" "$PATH_TRUST" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFileSync } = require("node:child_process");

const [action, home, pathTrust] = process.argv.slice(2);
const CONFIG_DIR = path.join(home, ".gemini", "config");
const CONFIG = path.join(CONFIG_DIR, "hooks.json");
// The hook script and the token registry live in agy's own CLI state directory
// rather than in .gemini/config, because .gemini/config is a CUSTOMIZATION ROOT
// that agy scans for skills, rules and plugins; a stray script and directory
// there are discovery surface rather than inert files.
const STATE_DIR = path.join(home, ".gemini", "antigravity-cli");
const HOOK = path.join(STATE_DIR, "fm-turn-end.sh");
const REGISTRY = path.join(STATE_DIR, "fm-turn-end.d");
const KEY = "firstmate-turn-end";
const TOKEN_NAME = /^fm\.[A-Za-z0-9]{12}$/;

// The hook body is compared byte for byte on remove, so it is a single constant
// with no interpolation. It prints its JSON answer FIRST and sends everything
// after that to /dev/null, so no later failure can corrupt the answer agy reads
// or leak output into the pane.
const HOOK_BYTES = `#!/usr/bin/env bash
# Firstmate agy turn-end hook. Managed by fm-agy-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
payload=$(cat)
printf '{}\\n'
exec >/dev/null 2>&1
[ -n "\${HOME:-}" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
FM_AGY_PAYLOAD=$payload node -e '
const fs = require("node:fs");
const path = require("node:path");
let p;
try { p = JSON.parse(process.env.FM_AGY_PAYLOAD || ""); } catch { process.exit(0); }
if (!p || p.fullyIdle !== true) process.exit(0);
const spaces = Array.isArray(p.workspacePaths) ? p.workspacePaths : [];
const registry = path.join(process.env.HOME, ".gemini", "antigravity-cli", "fm-turn-end.d");
for (const ws of spaces) {
  if (typeof ws !== "string" || !ws.startsWith("/")) continue;
  let first;
  try { first = fs.readFileSync(path.join(ws, ".fm-agy-turnend"), "utf8").split("\\n", 1)[0]; } catch { continue; }
  if (!first.startsWith("token=")) continue;
  const token = first.slice(6).trim();
  if (!/^fm\\.[A-Za-z0-9]{12}$/.test(token)) continue;
  let target;
  try { target = fs.readFileSync(path.join(registry, token), "utf8").trim(); } catch { continue; }
  if (!target.startsWith("/") || !target.endsWith(".turn-ended")) continue;
  try { fs.closeSync(fs.openSync(target, "a")); fs.utimesSync(target, new Date(), new Date()); } catch { /* passive */ }
}
' 2>/dev/null
exit 0
`;

const refuse = (reason) => {
  console.error(`fm-agy-turnend-hook: refused: ${reason}`);
  process.exit(1);
};

const lstatOrNull = (p) => {
  try {
    return fs.lstatSync(p);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};

const regularNotSymlink = (p, label) => {
  const info = lstatOrNull(p);
  if (info === null) refuse(`${label} is missing at ${p}.`);
  if (info.isSymbolicLink() || !info.isFile()) {
    refuse(`${label} is not a regular non-symlink file at ${p}.`);
  }
  return info;
};

const atomicWrite = (target, body, mode) => {
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(target), `.${path.basename(target)}.fm.${unique}`);
  fs.writeFileSync(tmp, body, { mode, flag: "wx" });
  try {
    fs.renameSync(tmp, target);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
};

// agy writes this file two-space pretty-printed with a trailing newline, the
// same shape as its settings.json, so a Firstmate edit leaves the operator's
// formatting alone instead of reflowing the whole file on every spawn.
const serialize = (root) => `${JSON.stringify(root, null, 2)}\n`;

const readConfig = () => {
  const info = lstatOrNull(CONFIG);
  if (info === null) return { root: {}, existed: false };
  if (info.isSymbolicLink() || !info.isFile()) {
    refuse(`agy hooks config is not a regular non-symlink file at ${CONFIG}.`);
  }
  const raw = fs.readFileSync(CONFIG, "utf8");
  if (raw.trim() === "") return { root: {}, existed: true };
  let root;
  try {
    root = JSON.parse(raw);
  } catch (err) {
    refuse(`agy hooks config is malformed JSON at ${CONFIG}: ${err.message}`);
  }
  if (root === null || typeof root !== "object" || Array.isArray(root)) {
    refuse(`agy hooks config is not a JSON object at ${CONFIG}.`);
  }
  return { root, existed: true };
};

// Refuse rather than clobber when something other than this command has written
// a hook that runs the Firstmate script: a second reference means an ownership
// assumption here is already wrong.
const assertNoForeignReference = (root) => {
  for (const [name, value] of Object.entries(root)) {
    if (name === KEY) continue;
    if (JSON.stringify(value ?? null).includes("fm-turn-end.sh")) {
      refuse(`a hook other than "${KEY}" references fm-turn-end.sh in ${CONFIG}.`);
    }
  }
};

const firstmateHook = () => ({
  Stop: [
    {
      type: "command",
      command: 'bash "$HOME/.gemini/antigravity-cli/fm-turn-end.sh"',
      timeout: 5,
    },
  ],
});

try {
  const { root, existed } = readConfig();
  assertNoForeignReference(root);

  if (action === "install") {
    // The hook script agy executes on every Stop, and the hooks.json holding the
    // command string, live under these directories, so a directory other
    // accounts can write - or one whose ANCESTORS they can write, which lets
    // them rename it aside and plant their own - lets one of them replace either
    // with arbitrary code. The same predicate the trust pre-registration uses
    // answers it, from the same file, so the two cannot drift: a directory that
    // does not exist yet is judged where it would be created.
    for (const [target, label] of [
      [path.join(home, ".gemini"), ".gemini directory"],
      [STATE_DIR, "agy state directory"],
      [CONFIG_DIR, "agy config directory"],
    ]) {
      let verdict;
      try {
        verdict = execFileSync(process.execPath, [pathTrust, "check", target], { encoding: "utf8" });
      } catch (err) {
        refuse(`the shared path-trust check could not judge ${label} at ${target}.`);
      }
      if (verdict.startsWith("loose:")) {
        const loose = verdict.slice(6);
        refuse(`${label} at ${target} is reached through '${loose}', which is writable by other users; remove write access for others with: chmod go-w ${loose}`);
      }
      if (!verdict.startsWith("ok:")) {
        refuse(`${label} at ${target} could not be resolved.`);
      }
    }
    // Created 0755 regardless of the caller's umask, so an install under the
    // umask-002 default does not create the loose directories it just refused.
    const oldUmask = process.umask(0o022);
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o755 });
      fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o755 });
    } finally {
      process.umask(oldUmask);
    }
    const registryInfo = lstatOrNull(REGISTRY);
    if (registryInfo !== null && (registryInfo.isSymbolicLink() || !registryInfo.isDirectory())) {
      refuse(`Firstmate registry is not a regular directory at ${REGISTRY}.`);
    }
    fs.mkdirSync(REGISTRY, { recursive: true, mode: 0o700 });
    fs.chmodSync(REGISTRY, 0o700);
    const hookInfo = lstatOrNull(HOOK);
    if (hookInfo !== null) regularNotSymlink(HOOK, "Firstmate hook script");
    if (hookInfo === null || fs.readFileSync(HOOK, "utf8") !== HOOK_BYTES) {
      atomicWrite(HOOK, HOOK_BYTES, 0o700);
    } else {
      fs.chmodSync(HOOK, 0o700);
    }
    root[KEY] = firstmateHook();
    atomicWrite(CONFIG, serialize(root), 0o600);
    console.log(`installed: ${KEY} in ${CONFIG}`);
    process.exit(0);
  }

  // remove
  if (fs.existsSync(HOOK)) {
    const info = regularNotSymlink(HOOK, "Firstmate hook script");
    if (fs.readFileSync(HOOK, "utf8") !== HOOK_BYTES) {
      refuse(`Firstmate hook script has unexpected content at ${HOOK}.`);
    }
    if (info.mode & 0o077) {
      refuse(`Firstmate hook script has unexpectedly broad permissions at ${HOOK}.`);
    }
  }
  const registryInfo = lstatOrNull(REGISTRY);
  if (registryInfo !== null) {
    if (registryInfo.isSymbolicLink() || !registryInfo.isDirectory()) {
      refuse(`Firstmate registry is not a regular directory at ${REGISTRY}.`);
    }
    for (const name of fs.readdirSync(REGISTRY)) {
      const entry = fs.lstatSync(path.join(REGISTRY, name));
      if (!TOKEN_NAME.test(name) || entry.isSymbolicLink() || !entry.isFile()) {
        refuse(`Firstmate registry contains an unexpected entry at ${path.join(REGISTRY, name)}.`);
      }
    }
    // Live tokens mean tasks still expect a turn-end wake, so removing the hook
    // would silence them. Retire the tasks first.
    const live = fs.readdirSync(REGISTRY);
    if (live.length > 0) {
      refuse(`${live.length} task token(s) still registered in ${REGISTRY}; tear those tasks down first.`);
    }
    fs.rmSync(REGISTRY, { recursive: true, force: true });
  }
  fs.rmSync(HOOK, { force: true });
  if (existed && Object.prototype.hasOwnProperty.call(root, KEY)) {
    delete root[KEY];
    // An otherwise empty hooks.json is removed rather than left as "{}", so a
    // home that never had one is returned to exactly that state.
    if (Object.keys(root).length === 0) fs.rmSync(CONFIG, { force: true });
    else atomicWrite(CONFIG, serialize(root), 0o600);
  }
  console.log(`removed: ${KEY}`);
  process.exit(0);
} catch (err) {
  console.error(`fm-agy-turnend-hook: refused: ${err.message}`);
  process.exit(1);
}
NODE
