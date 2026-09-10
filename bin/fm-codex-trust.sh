#!/usr/bin/env bash
# Pre-register Codex's directory trust for the isolated task worktree a
# ship/scout spawn is about to launch a codex crewmate into, so the worker
# reaches its brief instead of parking on the directory-trust dialog.
#
# Usage: fm-codex-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints `recorded: <path>` only after reading the store back and confirming
# the trusted record; prints `dropped: <path>` and fails if the record did not
# survive the write and bounded retries. Every other failure is a refusal.
#
# WHY THIS EXISTS. Codex gates a repository root it has not trusted behind an
# interactive directory-trust dialog before it reads the launch brief. The
# control plane deliberately has no raw-key navigation surface, so firstmate
# records Codex's own trust setting before launch instead of trying to drive
# the dialog.
#
# THE SCOPE TEST follows bin/fm-claude-trust.sh deliberately. <worktree> must
# be a LINKED git worktree - its own git dir, sharing <project>'s common dir -
# whose top level is exactly the resolved argument. That proves the supplied
# path is a linked worktree of the supplied project and excludes that project's
# primary checkout. It does NOT prove that <project> is the fleet registry's
# canonical clone or enforce per-clone ownership. A primary checkout, foreign
# repository, subdirectory, plain directory, config directory, or home
# directory is refused rather than guessed at.
#
# Unlike the Claude helper, this edits TOML rather than serializing JSON.
# Codex's live config can contain hundreds of project tables plus unrelated
# settings, so serializing the document would be destructive even if its value
# stayed equivalent. This helper recognizes Codex's project-table form, inserts
# or changes only this worktree's trust_level, and leaves every other byte
# untouched. An ambiguous duplicate table or target trust_level is refused.
# The candidate is staged beside the store, the original is fingerprinted
# immediately before rename, and the read-back result controls the report.
#
# Only the launching user's own ~/.codex/config.toml is written. The config
# directory is resolved from HOME because that is the user-level path Codex
# documents and the same HOME reaches the worker launch. A store symlink is
# followed only when its final target is a regular file owned by this uid.
set -u

# These values can redirect filesystem and git resolution away from the paths
# supplied to this command. Clear the whole class once so the scope verdict is
# based on the filesystem rather than inherited process state.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-codex-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Codex trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is unset, so ~/.codex/config.toml cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "home directory '$HOME' is not accessible"
CONFIG_DIR="$HOME_REAL/.codex"
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
[ -n "$CONFIG_DIR_REAL" ] || refuse "Codex config directory '$CONFIG_DIR' does not exist and could not be created"

[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
[ "$WT_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$WT_REAL' is the Codex config directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record Codex trust and was not found on PATH"

STORE="$CONFIG_DIR_REAL/config.toml"
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

node - "$STORE" "$WT_REAL" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { TextDecoder } = require("node:util");

const [store, worktree] = process.argv.slice(2);
const decoder = new TextDecoder("utf-8", { fatal: true });

function fail(message) {
  throw new Error(message);
}

function decodeBasicString(source) {
  let result = "";
  for (let index = 1; index < source.length - 1; index += 1) {
    const char = source[index];
    if (char !== "\\") {
      result += char;
      continue;
    }
    index += 1;
    const escaped = source[index];
    const simple = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", '"': '"', "\\": "\\" };
    if (Object.prototype.hasOwnProperty.call(simple, escaped)) {
      result += simple[escaped];
      continue;
    }
    const width = escaped === "u" ? 4 : escaped === "U" ? 8 : 0;
    if (width === 0) fail(`unsupported escape in project table ${source}`);
    const digits = source.slice(index + 1, index + 1 + width);
    if (!new RegExp(`^[0-9A-Fa-f]{${width}}$`).test(digits)) {
      fail(`invalid Unicode escape in project table ${source}`);
    }
    const point = Number.parseInt(digits, 16);
    if (point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) {
      fail(`invalid Unicode code point in project table ${source}`);
    }
    result += String.fromCodePoint(point);
    index += width;
  }
  return result;
}

function decodeTomlString(source) {
  return source.startsWith("'") ? source.slice(1, -1) : decodeBasicString(source);
}

function encodeTomlString(value) {
  let result = '"';
  for (const char of value) {
    const point = char.codePointAt(0);
    const simple = { "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r", '"': '\\"', "\\": "\\\\" };
    if (Object.prototype.hasOwnProperty.call(simple, char)) result += simple[char];
    else if (point < 0x20 || point === 0x7f) result += `\\u${point.toString(16).padStart(4, "0")}`;
    else result += char;
  }
  return `${result}"`;
}

function linesOf(text) {
  const lines = [];
  let start = 0;
  while (start < text.length) {
    const newline = text.indexOf("\n", start);
    const end = newline === -1 ? text.length : newline + 1;
    let contentEnd = newline === -1 ? end : newline;
    if (contentEnd > start && text[contentEnd - 1] === "\r") contentEnd -= 1;
    lines.push({ start, contentEnd, end, text: text.slice(start, contentEnd) });
    start = end;
  }
  return lines;
}

function projectPathFromHeader(line) {
  const match = line.match(/^\s*\[\s*(?:projects|"projects"|'projects')\s*\.\s*("(?:\\.|[^"\\])*"|'[^']*')\s*\]\s*(?:#.*)?$/);
  return match ? decodeTomlString(match[1]) : null;
}

function isTableHeader(line) {
  return /^\s*\[\[?.*\]\]?\s*(?:#.*)?$/.test(line);
}

function locate(text) {
  const lines = linesOf(text);
  const tables = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (projectPathFromHeader(lines[index].text) === worktree) tables.push(index);
  }
  if (tables.length > 1) fail(`config.toml contains duplicate project tables for ${worktree}`);
  if (tables.length === 0) return { lines, table: null, trust: null };
  const table = tables[0];
  const trusts = [];
  for (let index = table + 1; index < lines.length; index += 1) {
    if (isTableHeader(lines[index].text)) break;
    if (/^\s*trust_level\s*=/.test(lines[index].text)) trusts.push(index);
  }
  if (trusts.length > 1) fail(`config.toml contains duplicate trust_level values for ${worktree}`);
  if (trusts.length === 0) return { lines, table, trust: null };
  const trust = trusts[0];
  const match = lines[trust].text.match(/^(\s*trust_level\s*=\s*)("(?:\\.|[^"\\])*"|'[^']*')(\s*(?:#.*)?)$/);
  if (!match) fail(`config.toml has an unsupported trust_level expression for ${worktree}`);
  const value = decodeTomlString(match[2]);
  if (value !== "trusted" && value !== "untrusted") {
    fail(`config.toml has an unsupported trust_level value for ${worktree}`);
  }
  const valueStart = lines[trust].start + match[1].length;
  const valueEnd = valueStart + match[2].length;
  return { lines, table, trust, value, valueStart, valueEnd };
}

function transformed(original) {
  if (original === null) original = Buffer.alloc(0);
  let text;
  try {
    text = decoder.decode(original);
  } catch (error) {
    fail(`config.toml is not valid UTF-8: ${error.message}`);
  }
  const found = locate(text);
  if (found.table === null) {
    const separator = text.length === 0 ? "" : /(?:\r\n|\n)$/.test(text) ? "\n" : "\n\n";
    const addition = `[projects.${encodeTomlString(worktree)}]\ntrust_level = "trusted"\n`;
    return Buffer.from(text + separator + addition, "utf8");
  }
  if (found.trust === null) {
    const header = found.lines[found.table];
    const newline = text.slice(header.contentEnd, header.end) || "\n";
    return Buffer.from(text.slice(0, header.end) + `trust_level = "trusted"${newline}` + text.slice(header.end), "utf8");
  }
  if (found.value === "trusted") return original;
  return Buffer.from(text.slice(0, found.valueStart) + '"trusted"' + text.slice(found.valueEnd), "utf8");
}

function readStore() {
  try {
    return fs.readFileSync(store);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function fingerprint(data) {
  return data === null ? "absent" : crypto.createHash("sha256").update(data).digest("hex");
}

function readBackRecorded() {
  try {
    const current = readStore();
    if (current === null) return false;
    const text = decoder.decode(current);
    const found = locate(text);
    return found.table !== null && found.trust !== null && found.value === "trusted";
  } catch (_) {
    return false;
  }
}

function attempt() {
  const original = readStore();
  const before = fingerprint(original);
  const candidate = transformed(original);
  if (original !== null && candidate.equals(original)) return readBackRecorded() ? "recorded" : "dropped";
  const mode = original === null ? 0o600 : fs.statSync(store).mode & 0o777;
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const temporary = path.join(path.dirname(store), `.config.toml.fm-trust.${unique}`);
  let renamed = false;
  let descriptor = fs.openSync(temporary, "wx", mode);
  try {
    fs.writeFileSync(descriptor, candidate);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = null;
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(temporary, store);
    renamed = true;
  } finally {
    if (descriptor !== null) fs.closeSync(descriptor);
    if (!renamed) fs.rmSync(temporary, { force: true });
  }
  return readBackRecorded() ? "recorded" : "dropped";
}

try {
  for (let index = 0; index < 3; index += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && index >= 1) {
      fail(`${store} was modified while trust was being recorded; refusing to overwrite it`);
    }
    if (result === "dropped" && index >= 2) process.exit(3);
  }
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exit(1);
}
process.exit(3);
NODE
RESULT=$?
case "$RESULT" in
  0)
    echo "recorded: $WT_REAL"
    ;;
  3)
    echo "dropped: $WT_REAL" >&2
    exit 1
    ;;
  *)
    refuse "could not record trust for '$WT_REAL' in '$STORE'"
    ;;
esac
