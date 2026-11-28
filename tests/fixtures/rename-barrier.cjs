"use strict";
// Preloaded with NODE_OPTIONS=--require to pause or kill the lifecycle host
// inside its directory-lock retirement. FM_TEST_BARRIERS carries the same
// role:stage:action:lock specs as the barrier shims in
// tests/fm-watcher-lock.test.sh: retire = rename of <lock>/pid,
// discard = rm of <lock>/.owner.* (stage partial deletes pid.retired first);
// actions wait, kill, fail and none. Each spec fires once and appends
// "<subject> <role>:<stage>:<lock> pid=<host pid>" to FM_TEST_EVENTS.
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const { syncBuiltinESMExports } = require("node:module");

const specs = (process.env.FM_TEST_BARRIERS || "").split(/\s+/).filter(Boolean).map((spec) => {
  const [role, stage, action, ...lock] = spec.split(":");
  return { role, stage, action, lock: lock.join(":") };
});

function claim(role, matches) {
  for (const [index, spec] of specs.entries()) {
    if (spec.role !== role || !matches(spec.lock)) continue;
    try {
      fs.mkdirSync(path.join(process.env.FM_TEST_BARRIER_DIR, `node-fired.${index + 1}`), { recursive: false });
    } catch {
      continue;
    }
    return spec;
  }
  return null;
}

function barrier(spec) {
  fs.appendFileSync(process.env.FM_TEST_EVENTS,
    `${process.env.FM_TEST_SUBJECT} ${spec.role}:${spec.stage}:${spec.lock} pid=${process.pid}\n`);
  if (spec.action === "wait") {
    const fd = fs.openSync(process.env.FM_TEST_RESUME, "r");
    fs.readSync(fd, Buffer.alloc(64));
    fs.closeSync(fd);
  } else if (spec.action === "kill") {
    process.kill(process.pid, "SIGKILL");
  } else if (spec.action === "fail") {
    throw Object.assign(new Error("rename barrier fault"), { code: "EIO" });
  }
}

if (specs.length > 0) {
  const realRename = fsp.rename;
  const realRm = fsp.rm;
  fsp.rename = async function barrierRename(from, to) {
    const spec = claim("retire", (lock) => path.resolve(String(from)) === path.join(lock, "pid"));
    if (!spec) return realRename(from, to);
    if (spec.stage === "pre") barrier(spec);
    await realRename(from, to);
    if (spec.stage === "post") barrier(spec);
  };
  fsp.rm = async function barrierRm(target, options) {
    const resolved = path.resolve(String(target));
    const spec = claim("discard", (lock) => path.dirname(resolved) === lock && path.basename(resolved).startsWith(".owner."));
    if (!spec) return realRm(target, options);
    if (spec.stage === "partial") await realRm(path.join(resolved, "pid.retired"), { force: true });
    barrier(spec);
    return realRm(target, options);
  };
  syncBuiltinESMExports();
}
