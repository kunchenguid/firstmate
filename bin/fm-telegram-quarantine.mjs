#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  if (message) process.stderr.write(`${message}\n`);
  process.exit(1);
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function privateRegularFile(stat, links) {
  return stat.isFile() && stat.nlink === BigInt(links) && (stat.mode & 0o777n) === 0o600n;
}

const [source, quarantineDir, requestedBase] = process.argv.slice(2);
if (!source || !quarantineDir || !requestedBase) fail("usage: fm-telegram-quarantine.mjs SOURCE QUARANTINE_DIR BASENAME");
if (requestedBase === "." || requestedBase === ".." || path.basename(requestedBase) !== requestedBase) fail("invalid basename");

let sourceFd;
let destinationFd;
let destination = "";
let ownsDestination = false;

try {
  sourceFd = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  const sourceIdentity = fs.fstatSync(sourceFd, { bigint: true });
  if (!sourceIdentity.isFile() || sourceIdentity.nlink !== 1n) throw new Error("unsafe source");

  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate = path.join(quarantineDir, attempt === 0 ? requestedBase : `${requestedBase}.${attempt}`);
    try {
      destinationFd = fs.openSync(
        candidate,
        fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
        0o600,
      );
      destination = candidate;
      ownsDestination = true;
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }
  if (!ownsDestination) throw new Error("quarantine name exhausted");

  const buffer = Buffer.allocUnsafe(64 * 1024);
  for (;;) {
    const bytesRead = fs.readSync(sourceFd, buffer, 0, buffer.length, null);
    if (bytesRead === 0) break;
    let written = 0;
    while (written < bytesRead) {
      written += fs.writeSync(destinationFd, buffer, written, bytesRead - written);
    }
  }
  fs.fchmodSync(destinationFd, 0o600);
  fs.fsyncSync(destinationFd);
  const destinationIdentity = fs.fstatSync(destinationFd, { bigint: true });
  if (!privateRegularFile(destinationIdentity, 1)) throw new Error("unsafe destination");

  const currentSource = fs.lstatSync(source, { bigint: true });
  if (!currentSource.isFile() || currentSource.nlink !== 1n || !sameIdentity(sourceIdentity, currentSource)) {
    throw new Error("source identity changed");
  }
  fs.unlinkSync(source);
  fs.closeSync(destinationFd);
  destinationFd = undefined;
  fs.closeSync(sourceFd);
  sourceFd = undefined;
  ownsDestination = false;
  process.stdout.write(`${destination}\n`);
} catch {
  if (destinationFd !== undefined) {
    try {
      fs.closeSync(destinationFd);
    } catch {}
  }
  if (sourceFd !== undefined) {
    try {
      fs.closeSync(sourceFd);
    } catch {}
  }
  if (ownsDestination) {
    try {
      fs.unlinkSync(destination);
    } catch {}
  }
  fail("");
}
