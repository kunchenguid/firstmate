// Shared FM_HOME/FM_ROOT_OVERRIDE resolution for every Firstmate extension that
// needs this process's own operational home.
//
// The ordinary shell contract (bin/fm-lock.sh and friends) lets an inherited
// FM_HOME win over the script's own code-root location, because a crewmate task
// worktree legitimately diverges from its parent's home on every launch. A
// persistent second mate's own top-level session is different: bin/fm-home-seed.sh
// always provisions it so its home IS its own tracked code root, and every
// secondmate launch sets FM_HOME to that same root. There is no legitimate
// reason for a second mate's own session to see a DIFFERENT FM_HOME, so an
// inherited override that disagrees with root is exactly the launcher/
// environment leak recorded in data/learnings.md - a restored pane or reboot
// inheriting the launching server's environment - rather than an intentional
// divergence, and must not be trusted.
//
// The `.fm-secondmate-home` identity marker bin/fm-home-seed.sh writes once at
// seed time is what decides this locally, without depending on the launcher's
// environment at all. A crewmate task worktree never carries that marker, so
// its own legitimate FM_HOME divergence toward its parent home is untouched,
// and a primary's own root never carries it either. This mirrors the shell
// marker predicate in bin/fm-primary-scope-lib.sh rather than re-deciding it.
import { lstatSync } from "node:fs";
import { join, resolve } from "node:path";

const SECONDMATE_HOME_MARKER = ".fm-secondmate-home";

function isSecondmateRoot(root: string): boolean {
  try {
    return lstatSync(join(root, SECONDMATE_HOME_MARKER)).isFile();
  } catch {
    return false;
  }
}

// A second mate's own root always wins over a disagreeing override; every other
// root keeps the ordinary inherited-override precedence.
function ownRootOrOverride(root: string, override: string): string {
  if (!override) return root;
  const resolvedOverride = resolve(override);
  if (resolvedOverride === root) return resolvedOverride;
  if (isSecondmateRoot(root)) return root;
  return resolvedOverride;
}

// Mirrors the shell contract's FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
// precedence, corrected for a second mate's own session as described above.
export function resolveFirstmateHome(root: string): string {
  return ownRootOrOverride(root, process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || "");
}

// Mirrors the shell contract's FM_ROOT="${FM_ROOT_OVERRIDE:-$(...)}" precedence
// for the code-root override some spawned children read, same correction.
export function resolveFirstmateRoot(root: string): string {
  return ownRootOrOverride(root, process.env.FM_ROOT_OVERRIDE || "");
}

// The corrected pair every child process this extension spawns must see, so a
// leaked launcher environment is never carried into bin/fm-turnend-guard.sh,
// bin/fm-arm-pretool-check.sh, bin/fm-cd-pretool-check.sh, or the session-start
// chain through an ordinary process.env passthrough.
export function firstmateChildEnv(home: string, fmRoot: string): NodeJS.ProcessEnv {
  return { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: fmRoot };
}
