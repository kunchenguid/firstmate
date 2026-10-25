// Test harness only (loaded with node --import). Reproduces the window in
// tasks-axi acquireLock between openSync(lock, "wx") and writeSync(token):
// after the real open succeeds, write a marker and freeze in place, so the
// lock file exists with 0 bytes and the process has not written its token.
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";

const realOpenSync = fs.openSync;
fs.openSync = function (path, flags, ...rest) {
  const fd = realOpenSync.call(fs, path, flags, ...rest);
  if (typeof path === "string" && path.endsWith(".lock") && flags === "wx") {
    fs.writeFileSync(process.env.REPRO_MARK, String(process.pid));
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 120_000);
  }
  return fd;
};
syncBuiltinESMExports();
