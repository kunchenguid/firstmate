const {execFileSync} = require("node:child_process");
const {existsSync} = require("node:fs");

const leader = Number(process.argv[2]);
const delay = Number(process.argv[3]);
if (!Number.isInteger(leader) || leader <= 1 || !Number.isInteger(delay) || delay < 1) {
  process.exit(2);
}

setTimeout(() => {
  let group;
  try {
    const ps = existsSync("/bin/ps") ? "/bin/ps" : "/usr/bin/ps";
    group = Number(execFileSync(ps, ["-p", String(process.pid), "-o", "pgid="], {
      encoding: "utf8",
      timeout: 1000,
    }).trim());
  } catch {
    process.exit(1);
  }
  if (!Number.isInteger(group) || group !== leader) {
    process.exit(1);
  }
  try {
    process.kill(-leader, "SIGKILL");
  } catch {
    process.exit(0);
  }
}, delay);
