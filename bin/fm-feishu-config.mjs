#!/usr/bin/env node
// Parse the local Feishu configuration strictly as data.
//
// The only supported file is <FM_HOME>/config/feishu.env.  This parser never
// evaluates shell syntax, expands variables, or prints configured values.
import {
  closeSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join, resolve } from "node:path";
const ALLOWED_KEYS = new Set([
  "FM_FEISHU_ENABLED",
  "FM_FEISHU_APP_ID",
  "FM_FEISHU_APP_SECRET",
  "FM_FEISHU_CAPTAIN_OPEN_ID",
  "FM_FEISHU_P2P_CHAT_ID",
]);
const REQUIRED_KEYS = [
  "FM_FEISHU_APP_ID",
  "FM_FEISHU_APP_SECRET",
  "FM_FEISHU_CAPTAIN_OPEN_ID",
  "FM_FEISHU_P2P_CHAT_ID",
];
const KEY_PATTERN = /^[A-Z][A-Z0-9_]*$/;
const APP_ID_PATTERN = /^cli_[A-Za-z0-9_-]{8,128}$/;
const APP_SECRET_PATTERN = /^[A-Za-z0-9._~+/=-]{8,4096}$/;
const OPEN_ID_PATTERN = /^ou_[A-Za-z0-9_-]{4,128}$/;
const CHAT_ID_PATTERN = /^oc_[A-Za-z0-9_-]{4,128}$/;

function configError(reason) {
  const error = new Error(`Feishu config refused: ${reason}; inspect config/feishu.env and docs/feishu-channel.md`);
  error.code = "FM_FEISHU_CONFIG_INVALID";
  return error;
}

function safeRegularFile(path) {
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw configError("cannot inspect the local configuration");
  }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1) throw configError("the local configuration must be one regular non-symlink file");
  if (stat.uid !== process.getuid()) throw configError("the local configuration must be owned by the current user");
  if ((stat.mode & 0o777) !== 0o600) throw configError("the local configuration permissions must be exactly 0600");
  return stat;
}

function safeConfigDirectory(path) {
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw configError("cannot inspect the local configuration directory");
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw configError("the local configuration directory must be a regular directory");
  if (stat.uid !== process.getuid()) throw configError("the local configuration directory must be owned by the current user");
  if ((stat.mode & 0o022) !== 0) throw configError("the local configuration directory must not be writable by group or others");
  return true;
}

function readSecureFile(path) {
  const before = safeRegularFile(path);
  if (!before) return undefined;
  let descriptor;
  try {
    descriptor = openSync(path, "r");
    const opened = fstatSync(descriptor);
    const after = lstatSync(path);
    if (!opened.isFile() || opened.nlink !== 1 || opened.uid !== process.getuid() || (opened.mode & 0o777) !== 0o600) {
      throw configError("the opened local configuration is unsafe");
    }
    if (opened.dev !== before.dev || opened.ino !== before.ino || after.dev !== before.dev || after.ino !== before.ino) {
      throw configError("the local configuration changed while it was being opened");
    }
    const raw = readFileSync(descriptor, "utf8");
    if (Buffer.byteLength(raw, "utf8") > 16384) throw configError("the local configuration is too large");
    return { raw, stat: opened };
  } catch (error) {
    if (error?.code === "FM_FEISHU_CONFIG_INVALID") throw error;
    throw configError("cannot read the local configuration");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function parseValue(raw, lineNumber) {
  if (raw.length === 0) throw configError(`line ${lineNumber} has an empty value`);
  if (/[\0\r\n]/.test(raw)) throw configError(`line ${lineNumber} has an invalid value`);
  if (/^['"]|['"]$/.test(raw) || /\s/.test(raw)) throw configError(`line ${lineNumber} must use an unquoted value without whitespace`);
  return raw;
}

function fileIdentity(stat) {
  return `${stat.dev}:${stat.ino}:${stat.mtimeMs}:${stat.size}`;
}

export function resolveFeishuConfigPath(home) {
  const homeRealpath = realpathSync(resolve(home));
  return join(homeRealpath, "config", "feishu.env");
}

export function readFeishuConfig(home) {
  const path = resolveFeishuConfigPath(home);
  if (!safeConfigDirectory(dirname(path))) return { status: "absent", path };
  const secure = readSecureFile(path);
  if (secure === undefined) return { status: "absent", path };
  const { raw, stat } = secure;
  if (raw.length === 0 || !raw.endsWith("\n")) throw configError("the local configuration must end with one newline");
  const values = new Map();
  for (const [index, line] of raw.slice(0, -1).split("\n").entries()) {
    const lineNumber = index + 1;
    if (line.length === 0 || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) throw configError(`line ${lineNumber} must be KEY=value data`);
    const key = line.slice(0, separator);
    if (!KEY_PATTERN.test(key)) throw configError(`line ${lineNumber} has a malformed key`);
    if (!ALLOWED_KEYS.has(key)) throw configError(`line ${lineNumber} uses unsupported field ${key}`);
    if (values.has(key)) throw configError(`line ${lineNumber} duplicates field ${key}`);
    values.set(key, parseValue(line.slice(separator + 1), lineNumber));
  }
  const enabled = values.get("FM_FEISHU_ENABLED");
  if (enabled !== "true" && enabled !== "false") throw configError("FM_FEISHU_ENABLED must be true or false");
  if (enabled === "true") for (const key of REQUIRED_KEYS) if (!values.has(key)) throw configError(`missing required field ${key}`);
  if (values.has("FM_FEISHU_APP_ID") && !APP_ID_PATTERN.test(values.get("FM_FEISHU_APP_ID"))) throw configError("FM_FEISHU_APP_ID is malformed");
  if (values.has("FM_FEISHU_APP_SECRET") && !APP_SECRET_PATTERN.test(values.get("FM_FEISHU_APP_SECRET"))) throw configError("FM_FEISHU_APP_SECRET is malformed");
  if (values.has("FM_FEISHU_CAPTAIN_OPEN_ID") && !OPEN_ID_PATTERN.test(values.get("FM_FEISHU_CAPTAIN_OPEN_ID"))) throw configError("FM_FEISHU_CAPTAIN_OPEN_ID is malformed");
  if (values.has("FM_FEISHU_P2P_CHAT_ID") && !CHAT_ID_PATTERN.test(values.get("FM_FEISHU_P2P_CHAT_ID"))) throw configError("FM_FEISHU_P2P_CHAT_ID is malformed");
  if (enabled === "false") return { status: "disabled", path, fileIdentity: fileIdentity(stat) };
  return {
    status: "enabled",
    path,
    fileIdentity: fileIdentity(stat),
    appId: values.get("FM_FEISHU_APP_ID"),
    appSecret: values.get("FM_FEISHU_APP_SECRET"),
    captainOpenId: values.get("FM_FEISHU_CAPTAIN_OPEN_ID"),
    p2pChatId: values.get("FM_FEISHU_P2P_CHAT_ID"),
  };
}

export function disableFeishuConfig(home) {
  const config = readFeishuConfig(home);
  if (config.status === "absent") return { changed: false, status: "absent" };
  if (config.status === "disabled") return { changed: false, status: "disabled" };
  const secure = readSecureFile(config.path);
  if (!secure || fileIdentity(secure.stat) !== config.fileIdentity) throw configError("the local configuration changed before disable");
  const updated = secure.raw.replace(/^FM_FEISHU_ENABLED=true$/m, "FM_FEISHU_ENABLED=false");
  if (updated === secure.raw) throw configError("FM_FEISHU_ENABLED=true is unavailable for disable");
  const directory = dirname(config.path);
  const temp = join(directory, `.feishu.env.${process.pid}.${randomBytes(6).toString("hex")}.tmp`);
  let descriptor;
  try {
    descriptor = openSync(temp, "wx", 0o600);
    writeFileSync(descriptor, updated, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    const current = safeRegularFile(config.path);
    if (!current || fileIdentity(current) !== config.fileIdentity) throw configError("the local configuration changed before disable publication");
    renameSync(temp, config.path);
    const directoryDescriptor = openSync(directory, "r");
    try {
      fsyncSync(directoryDescriptor);
    } finally {
      closeSync(directoryDescriptor);
    }
    return { changed: true, status: "disabled" };
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    try { unlinkSync(temp); } catch {}
  }
}
