#!/usr/bin/env node
// Private quarantine for permanently-unprocessable Telegram inbox / rate-log
// artifacts: no-clobber dest, single-link source validation, mode 0600 before
// source removal, generic phone ack is owned by the shell respond path.
//
// Threat boundary (captain decision key=quarantine-toctou-ratchet): a same-UID
// local-FS adversary that can rewrite this home's private state is OUT OF
// SCOPE - that access already steals FM_TELEGRAM_BOT_TOKEN, rewrites these
// scripts, and controls the process. Residual pathname TOCTOU under concurrent
// same-UID mutation is accepted at that boundary; do not add openat/dirfd
// identity-bound protocols solely for host compromise. See
// docs/telegram-mode.md "Local-filesystem threat boundary".

import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

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

function entryMatches(file, identity) {
  try {
    const current = fs.lstatSync(file, { bigint: true });
    return current.isFile() && sameIdentity(current, identity);
  } catch {
    return false;
  }
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function uniqueBase(requestedBase) {
  const id = randomUUID();
  return requestedBase.endsWith(".json")
    ? `${requestedBase.slice(0, -5)}.${id}.json`
    : `${requestedBase}.${id}`;
}

const [source, quarantineDir, requestedBase] = process.argv.slice(2);
if (!source || !quarantineDir || !requestedBase) fail("usage: fm-telegram-quarantine.mjs SOURCE QUARANTINE_DIR BASENAME");
if (requestedBase === "." || requestedBase === ".." || path.basename(requestedBase) !== requestedBase) fail("invalid basename");

let sourceFd;
let destinationFd;
let destination = "";
let ownsDestination = false;
let destinationIdentity;
let sourceIdentity;
let sourceClaim = "";
let sourceClaimDir = "";
let sourceRemoved = false;

try {
  sourceFd = fs.openSync(
    source,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
  );
  sourceIdentity = fs.fstatSync(sourceFd, { bigint: true });
  if (!sourceIdentity.isFile() || sourceIdentity.nlink !== 1n) throw new Error("unsafe source");

  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate = path.join(quarantineDir, uniqueBase(requestedBase));
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
  destinationIdentity = fs.fstatSync(destinationFd, { bigint: true });
  if (!privateRegularFile(destinationIdentity, 1)) throw new Error("unsafe destination");
  if (!entryMatches(destination, destinationIdentity)) throw new Error("destination identity changed");
  syncDirectory(quarantineDir);

  const currentSource = fs.lstatSync(source, { bigint: true });
  if (!currentSource.isFile() || currentSource.nlink !== 1n || !sameIdentity(sourceIdentity, currentSource)) {
    throw new Error("source identity changed");
  }
  sourceClaimDir = path.join(path.dirname(source), `.${path.basename(source)}.quarantine-${process.pid}-${randomUUID()}`);
  fs.mkdirSync(sourceClaimDir, { mode: 0o700 });
  sourceClaim = path.join(sourceClaimDir, "source");
  fs.renameSync(source, sourceClaim);
  const claimedSource = fs.lstatSync(sourceClaim, { bigint: true });
  if (!claimedSource.isFile() || claimedSource.nlink !== 1n || !sameIdentity(sourceIdentity, claimedSource)) {
    throw new Error("source claim changed identity");
  }
  if (!entryMatches(destination, destinationIdentity)) throw new Error("destination identity changed");
  fs.unlinkSync(sourceClaim);
  sourceClaim = "";
  fs.rmdirSync(sourceClaimDir);
  sourceClaimDir = "";
  sourceRemoved = true;
  syncDirectory(path.dirname(source));
  if (!entryMatches(destination, destinationIdentity)) throw new Error("destination identity changed");
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
  if (sourceClaim && entryMatches(sourceClaim, sourceIdentity)) {
    try {
      if (!fs.existsSync(source)) fs.renameSync(sourceClaim, source);
    } catch {}
  }
  if (sourceClaimDir) {
    try {
      fs.rmdirSync(sourceClaimDir);
    } catch {}
  }
  if (!sourceRemoved && ownsDestination && destinationIdentity && entryMatches(destination, destinationIdentity)) {
    try {
      fs.unlinkSync(destination);
    } catch {}
  }
  fail("");
}
