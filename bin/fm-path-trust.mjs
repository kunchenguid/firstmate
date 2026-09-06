#!/usr/bin/env node
// The ONE answer to one question: can any account but this one write a
// directory on the way to this path?
//
// It exists because that question was answered separately at every site that
// asked it, and each hand-written answer carved out a different exception. The
// settings store exempted the caller's own primary group, which is what let a
// shared macOS `staff` plant a symlink. Closing that left the middle of a link
// chain unjudged. Closing THAT left the ancestors of every hop unjudged, and
// the turn-end hook installer had grown a third spelling of the same mode test
// with no walk at all. Four sites, four ranges, four different wrong answers.
// One owner, called from all of them, is the only shape where the next site
// cannot quietly disagree. (kunchenguid/firstmate#3858)
//
// WHAT UNSAFE MEANS. Whoever can write a directory can replace what the next
// step of a resolution finds there, so a path is only as trustworthy as every
// directory it passes through - the one holding the name, that directory's
// parent, and so on to the root. Ownership of the endpoint cannot substitute:
// the file a confused deputy is pointed at is owned by the very user it runs
// as, which is the whole trick.
//
// GROUP-WRITE IS REFUSED WITH NO CARVE-OUT for the caller's own primary group.
// The mode bits cannot tell a shared group from a private one, and membership
// cannot be enumerated portably or completely: `getent` does not exist on
// macOS, a group's primary members are not listed in its group entry on any
// platform, and a directory service is free not to enumerate at all. Guessing
// at that opened the first hole; it is not guessed at here.
//
// THE STICKY BIT IS THE ONE REAL EXCEPTION, and it is not a carve-out for
// convenience: `chmod +t` is precisely the rule that stops a non-owner renaming
// or removing an entry that is not theirs, which is the exact capability this
// guards against. So a world-writable sticky directory - /tmp is the everyday
// one - is safe for an entry that ALREADY EXISTS and belongs to this user or to
// root, and unsafe for a name that does not exist yet, because anyone may still
// create that one.
//
// The walk stops at the filesystem root rather than at $HOME. A stop at $HOME
// was the previous range guess, and `~/.gemini` is not $HOME: writing it does
// not own the login, and neither does writing a `~/dotfiles` a store is
// symlinked into. A 0775 home is refused now, and the refusal names its chmod.
import fs from "node:fs";
import path from "node:path";

const OUR_UID = process.getuid();
const MAX_LINKS = 40;

// Throws if `dir` cannot be read; every caller here has already resolved it.
function directoryIsLoose(dir, entry) {
  const st = fs.statSync(dir);
  if ((st.mode & 0o022) === 0) return false;
  if ((st.mode & 0o1000) === 0) return true;
  // Sticky: safe only for an existing entry nobody else may replace.
  if (entry === null) return true;
  let est;
  try {
    est = fs.lstatSync(path.join(dir, entry));
  } catch (err) {
    return true;
  }
  return est.uid !== OUR_UID && est.uid !== 0;
}

// The first directory others can write on the way to `target`, or null. `dir`
// is resolved once and every ancestor above it is already real, so the walk
// climbs with plain dirname. `checked` dedupes the ancestor chains that repeat
// across the hops of one resolution.
function firstLooseDirectory(target, checked) {
  let entry = path.basename(target);
  let dir = fs.realpathSync(path.dirname(target));
  for (;;) {
    const key = `${dir}\0${entry}`;
    if (!checked.has(key)) {
      checked.add(key);
      if (directoryIsLoose(dir, entry)) return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    entry = path.basename(dir);
    dir = parent;
  }
}

// Follow a store path to the file that would actually be written, judging every
// directory the resolution passes through. A link is followed deliberately, so
// a dotfile manager or synced folder keeps working; it is only safe to follow
// because nothing on the way can be repointed by anyone else.
export function resolveStore(start) {
  const checked = new Set();
  let p = start;
  let followed = 0;
  for (;;) {
    let dir;
    try {
      dir = fs.realpathSync(path.dirname(p));
    } catch (err) {
      return followed > 0 ? { kind: "dangling" } : { kind: "unresolvable" };
    }
    p = path.join(dir, path.basename(p));
    const loose = firstLooseDirectory(p, checked);
    if (loose !== null) return { kind: "loose", dir: loose };
    let st;
    try {
      st = fs.lstatSync(p);
    } catch (err) {
      st = null;
    }
    // Nothing there yet is a store the caller creates itself - unless a link
    // pointed at it, which is a dangling store to fix rather than to rewrite.
    if (st === null) return followed > 0 ? { kind: "dangling" } : { kind: "store", path: p };
    if (!st.isSymbolicLink()) return { kind: "store", path: p };
    if (++followed > MAX_LINKS) return { kind: "dangling" };
    const target = fs.readlinkSync(p);
    p = path.isAbsolute(target) ? target : path.join(dir, target);
  }
}

// The first directory others can write on the way to `target`, or null, for a
// path that may not exist yet: the nearest existing ancestor is judged as a
// place a NAME WILL BE CREATED, which is the case the sticky bit does not cover.
export function checkPath(target) {
  let dir = target;
  for (;;) {
    try {
      dir = fs.realpathSync(dir);
      break;
    } catch (err) {
      const parent = path.dirname(dir);
      if (parent === dir) throw err;
      dir = parent;
    }
  }
  if (directoryIsLoose(dir, null)) return dir;
  return firstLooseDirectory(dir, new Set());
}

// CLI, so a shell caller and a node caller share one implementation rather than
// one interface with two implementations behind it.
//   resolve <path>  -> store:<resolved> | loose:<dir> | dangling: | unresolvable:
//   check <path>    -> ok: | loose:<dir> | unresolvable:
const [command, argument] = process.argv.slice(2);
if (command === "resolve" || command === "check") {
  if (typeof argument !== "string" || argument === "") {
    process.stderr.write(`fm-path-trust: ${command} needs a path\n`);
    process.exit(2);
  }
  try {
    if (command === "resolve") {
      const verdict = resolveStore(argument);
      if (verdict.kind === "store") process.stdout.write(`store:${verdict.path}`);
      else if (verdict.kind === "loose") process.stdout.write(`loose:${verdict.dir}`);
      else if (verdict.kind === "dangling") process.stdout.write("dangling:");
      else process.stdout.write("unresolvable:");
    } else {
      const loose = checkPath(argument);
      process.stdout.write(loose === null ? "ok:" : `loose:${loose}`);
    }
  } catch (err) {
    process.stdout.write("unresolvable:");
  }
} else if (command !== undefined) {
  process.stderr.write("usage: fm-path-trust.mjs resolve|check <path>\n");
  process.exit(2);
}
