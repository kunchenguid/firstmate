"use strict";

const fs = require("node:fs");
const { syncBuiltinESMExports } = require("node:module");
const path = require("node:path");

const projectDirValue = process.env.FM_PI_DELEGATED_PROJECT_DIR;
if (!projectDirValue || !path.isAbsolute(projectDirValue)) {
  throw new Error("delegated Pi startup guard requires an absolute project directory");
}

const projectDir = fs.realpathSync(projectDirValue);
const hiddenPaths = new Set([
  path.join(projectDir, ".pi", "commands"),
  path.join(projectDir, ".pi", "hooks"),
  path.join(projectDir, ".pi", "settings.json"),
  path.join(projectDir, ".pi", "tools"),
]);
const originalExistsSync = fs.existsSync;

fs.existsSync = function guardedExistsSync(candidate) {
  const candidatePath = Buffer.isBuffer(candidate) ? candidate.toString() : String(candidate);
  if (hiddenPaths.has(path.resolve(candidatePath))) {
    return false;
  }
  return originalExistsSync(candidate);
};

process.env.NODE_OPTIONS = "";
delete process.env.FM_PI_DELEGATED_PROJECT_DIR;
syncBuiltinESMExports();
