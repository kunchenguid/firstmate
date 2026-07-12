#!/usr/bin/env node
// Semantic policy for watcher arm and checkpoint shell commands.
//
// This parser is deliberately narrow.
// It recognizes executed command positions without evaluating, expanding,
// sourcing, or running any byte of the submitted command.
//
// This file is the sole owner of firstmate's shell command classification.
// The tokenizer and command-position analysis (Lexer, splitProgram,
// commandPosition) are exported so the sibling cd-guard policy
// (bin/fm-cd-command-policy.mjs) reuses the same proven parser instead of
// duplicating shell lexing; see docs/cd-guard.md. The watcher-arm decision
// procedure below stays private to this file. The CLI entry point at the bottom
// runs only when this module is invoked directly, never on import.

import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "watcher-background": "a protected watcher command cannot run in an asynchronous shell list or through nohup/disown",
  "watcher-pipeline": "a protected watcher command must not participate in a pipeline",
  "watcher-redirection": "a protected watcher command must not use shell redirection",
  "watcher-bundled": "a protected watcher command must be the sole final command after approved setup nodes",
  "watcher-nested": "a protected watcher command must not run through a wrapper, substitution, or compound command",
  "broad-watcher-kill": "a broad process kill targeting the firstmate watcher is forbidden",
  "unclassifiable-protected-command": "unsupported or malformed shell syntax contains a protected watcher command",
  "watcher-direct": "bin/fm-watch.sh must not be run directly; arm the watcher with bin/fm-watch-arm.sh or run bin/fm-watch-checkpoint.sh instead",
};

function parseArguments(argv) {
  const result = { command: "", root: "", home: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--root" || name === "--home") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function rawMentionsProtected(command) {
  return /(?:^|[/\s'"`(])fm-watch(?:-(?:arm|checkpoint))?\.sh\b/.test(normalizeLineContinuations(command));
}

function rawMentionsBroadKill(command) {
  const normalized = normalizeLineContinuations(command);
  return /fm-watch/.test(normalized) && /\b(?:pkill|kill)\b/.test(normalized);
}

function normalizeLineContinuations(source) {
  return source.replace(/\\\r?\n/g, "");
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function extractBalanced(source, start, open, close) {
  let depth = 1;
  let quote = "";
  let escaped = false;
  for (let i = start; i < source.length; i += 1) {
    const char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (char === "'") quote = "";
      continue;
    }
    if (quote === '"') {
      if (char === "\\") {
        escaped = true;
      } else if (char === '"') {
        quote = "";
      }
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === open) depth += 1;
    if (char === close) {
      depth -= 1;
      if (depth === 0) return { content: source.slice(start, i), next: i + 1 };
    }
  }
  return null;
}

function extractBackticks(source, start) {
  let escaped = false;
  for (let i = start; i < source.length; i += 1) {
    const char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "`") return { content: source.slice(start, i), next: i + 1 };
  }
  return null;
}

function decodeAnsiCQuoted(source, start) {
  let index = start + 2;
  let value = "";
  while (index < source.length) {
    const char = source[index];
    if (char === "'") return { value, next: index + 1 };
    if (char !== "\\") {
      value += char;
      index += 1;
      continue;
    }
    if (index + 1 >= source.length) return null;
    const escape = source[index + 1];
    index += 2;
    const simple = { a: "\u0007", b: "\b", e: "\u001b", E: "\u001b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", "\\": "\\", "'": "'", '"': '"', "?": "?" };
    if (Object.hasOwn(simple, escape)) {
      value += simple[escape];
      continue;
    }
    if (/[0-7]/.test(escape)) {
      let digits = escape;
      while (digits.length < 3 && /[0-7]/.test(source[index] || "")) {
        digits += source[index];
        index += 1;
      }
      value += String.fromCodePoint(Number.parseInt(digits, 8));
      continue;
    }
    if (escape === "x") {
      let digits = "";
      while (digits.length < 2 && /[0-9A-Fa-f]/.test(source[index] || "")) {
        digits += source[index];
        index += 1;
      }
      value += digits ? String.fromCodePoint(Number.parseInt(digits, 16)) : "\\x";
      continue;
    }
    if (escape === "u" || escape === "U") {
      const length = escape === "u" ? 4 : 8;
      const digits = source.slice(index, index + length);
      if (digits.length === length && /^[0-9A-Fa-f]+$/.test(digits)) {
        const codePoint = Number.parseInt(digits, 16);
        try {
          value += String.fromCodePoint(codePoint);
          index += length;
          continue;
        } catch {}
      }
      value += `\\${escape}`;
      continue;
    }
    if (escape === "c" && index < source.length) {
      value += String.fromCodePoint(source.codePointAt(index) & 31);
      index += 1;
      continue;
    }
    value += `\\${escape}`;
  }
  return null;
}

export class Lexer {
  constructor(source) {
    this.source = source;
    this.index = 0;
    this.error = "";
    this.tokens = [];
    this.pendingHeredocs = [];
    this.expectHeredoc = null;
  }

  tokenize() {
    while (this.index < this.source.length && !this.error) {
      const char = this.source[this.index];
      if (char === " " || char === "\t" || char === "\r") {
        this.index += 1;
        continue;
      }
      if (char === "#") {
        this.skipComment();
        continue;
      }
      if (char === "\n") {
        this.tokens.push({ type: "op", value: "newline" });
        this.index += 1;
        if (this.pendingHeredocs.length > 0) this.skipHeredocBodies();
        continue;
      }
      const control = this.readControlOperator();
      if (control) {
        this.tokens.push({ type: "op", value: control });
        continue;
      }
      const redirection = this.readRedirection();
      if (redirection) {
        const token = { type: "redir", value: redirection.value, inlineTarget: redirection.inlineTarget, fd: redirection.fd };
        this.tokens.push(token);
        if (redirection.value === "<<" || redirection.value === "<<-") this.expectHeredoc = { token, stripTabs: redirection.value === "<<-" };
        continue;
      }
      if (char === "(" || char === "{") {
        const close = char === "(" ? ")" : "}";
        const balanced = extractBalanced(this.source, this.index + 1, char, close);
        if (!balanced) {
          this.error = `unclosed ${char}`;
          break;
        }
        this.tokens.push({ type: "group", kind: char === "(" ? "subshell" : "brace", content: balanced.content });
        this.index = balanced.next;
        continue;
      }
      const word = this.readWord();
      if (!word) {
        this.error = `unsupported token at byte ${this.index}`;
        break;
      }
      this.tokens.push(word);
      if (this.expectHeredoc) {
        this.pendingHeredocs.push({ delimiter: word.value, stripTabs: this.expectHeredoc.stripTabs, token: this.expectHeredoc.token });
        this.expectHeredoc = null;
      }
    }
    if (this.expectHeredoc) this.error = "missing heredoc delimiter";
    return { tokens: this.tokens, error: this.error };
  }

  skipComment() {
    while (this.index < this.source.length && this.source[this.index] !== "\n") this.index += 1;
  }

  skipHeredocBodies() {
    for (const heredoc of this.pendingHeredocs) {
      let found = false;
      let body = "";
      while (this.index < this.source.length) {
        const end = this.source.indexOf("\n", this.index);
        const lineEnd = end === -1 ? this.source.length : end;
        const line = this.source.slice(this.index, lineEnd);
        const comparable = heredoc.stripTabs ? line.replace(/^\t+/, "") : line;
        this.index = end === -1 ? this.source.length : end + 1;
        if (comparable === heredoc.delimiter) {
          found = true;
          break;
        }
        body += comparable;
        if (end !== -1) body += "\n";
      }
      if (!found) {
        this.error = "unclosed heredoc";
        break;
      }
      heredoc.token.heredoc = body;
    }
    this.pendingHeredocs = [];
  }

  readControlOperator() {
    for (const operator of ["&&", "||", "|&", ";;", ";", "&", "|"]) {
      if (this.source.startsWith(operator, this.index)) {
        this.index += operator.length;
        return operator;
      }
    }
    return "";
  }

  readRedirection() {
    const remaining = this.source.slice(this.index);
    const match = remaining.match(/^(\d+)?(<<<|<<-|<<|>>|<>|>&|<&|>|<)(?:&?[0-9-]+)?/);
    if (!match) return "";
    this.index += match[0].length;
    const inlineTarget = /(?:>&|<&)[0-9-]+$/.test(match[0]);
    let normalized = match[0].replace(/^\d+/, "");
    if (inlineTarget) normalized = normalized.replace(/[0-9-]+$/, "");
    const fd = match[1] === undefined ? (match[2].startsWith("<") ? 0 : 1) : Number(match[1]);
    return { value: normalized, inlineTarget, fd };
  }

  readWord() {
    const word = { type: "word", value: "", literal: true, subs: [], quoted: false, unquotedExpansion: false };
    let consumed = false;
    while (this.index < this.source.length) {
      const char = this.source[this.index];
      if (/\s/.test(char) || ";&|<>()".includes(char)) break;
      if (char === "#" && !consumed) break;
      consumed = true;
      if (char === "'") {
        word.quoted = true;
        const end = this.source.indexOf("'", this.index + 1);
        if (end === -1) {
          this.error = "unclosed single quote";
          return null;
        }
        word.value += this.source.slice(this.index + 1, end);
        this.index = end + 1;
        continue;
      }
      if (char === '"') {
        word.quoted = true;
        if (!this.readDoubleQuoted(word)) return null;
        continue;
      }
      if (char === "\\") {
        if (this.index + 1 >= this.source.length) {
          this.error = "trailing escape";
          return null;
        }
        if (this.source[this.index + 1] === "\n") {
          this.index += 2;
          continue;
        }
        word.value += this.source[this.index + 1];
        this.index += 2;
        continue;
      }
      if (this.source.startsWith("$'", this.index)) {
        const ansi = decodeAnsiCQuoted(this.source, this.index);
        if (!ansi) {
          this.error = "unclosed ANSI-C quote";
          return null;
        }
        word.quoted = true;
        word.value += ansi.value;
        this.index = ansi.next;
        continue;
      }
      if (this.source.startsWith('$"', this.index)) {
        word.quoted = true;
        this.index += 1;
        if (!this.readDoubleQuoted(word)) return null;
        continue;
      }
      if (this.source.startsWith("$(", this.index)) {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) {
          this.error = "unclosed command substitution";
          return null;
        }
        word.subs.push({ kind: "command", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if ((char === "<" || char === ">") && this.source[this.index + 1] === "(") {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) {
          this.error = "unclosed process substitution";
          return null;
        }
        word.subs.push({ kind: "process", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if (char === "`") {
        const backticks = extractBackticks(this.source, this.index + 1);
        if (!backticks) {
          this.error = "unclosed backtick substitution";
          return null;
        }
        word.subs.push({ kind: "command", content: backticks.content });
        word.literal = false;
        this.index = backticks.next;
        continue;
      }
      if (char === "$") word.literal = false;
      if ("*?[]{}".includes(char)) word.unquotedExpansion = true;
      word.value += char;
      this.index += 1;
    }
    return consumed ? word : null;
  }

  readDoubleQuoted(word) {
    this.index += 1;
    while (this.index < this.source.length) {
      const char = this.source[this.index];
      if (char === '"') {
        this.index += 1;
        return true;
      }
      if (char === "\\") {
        if (this.index + 1 >= this.source.length) break;
        if (this.source[this.index + 1] === "\n") {
          this.index += 2;
          continue;
        }
        word.value += this.source[this.index + 1];
        this.index += 2;
        continue;
      }
      if (this.source.startsWith("$(", this.index)) {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) break;
        word.subs.push({ kind: "command", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if (char === "`") {
        const backticks = extractBackticks(this.source, this.index + 1);
        if (!backticks) break;
        word.subs.push({ kind: "command", content: backticks.content });
        word.literal = false;
        this.index = backticks.next;
        continue;
      }
      if (char === "$") word.literal = false;
      word.value += char;
      this.index += 1;
    }
    this.error = "unclosed double quote";
    return false;
  }
}

export function splitProgram(tokens) {
  const nodes = [];
  const separators = [];
  let current = [];
  for (const token of tokens) {
    if (token.type === "op") {
      if (current.length > 0) {
        nodes.push(current);
        current = [];
        separators.push(token.value);
      } else if (token.value !== "newline") {
        separators.push(token.value);
      }
      continue;
    }
    current.push(token);
  }
  if (current.length > 0) nodes.push(current);
  while (separators.length >= nodes.length && separators.at(-1) === "newline") separators.pop();
  return { nodes, separators };
}

function isAssignment(value) {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(value);
}

function wordsInNode(tokens) {
  const words = [];
  let skipRedirectionTarget = false;
  for (const token of tokens) {
    if (token.type === "redir") {
      skipRedirectionTarget = !token.inlineTarget;
      continue;
    }
    if (skipRedirectionTarget && token.type === "word") {
      skipRedirectionTarget = false;
      continue;
    }
    if (token.type === "word") words.push(token);
  }
  return words;
}

const WRAPPER_OPTIONS = {
  command: { noArgument: new Set(["p", "v", "V"]), takesArgument: new Set() },
  env: { noArgument: new Set(["0", "i", "P", "v"]), takesArgument: new Set(["a", "C", "S", "u"]) },
  exec: { noArgument: new Set(["c", "l"]), takesArgument: new Set(["a"]) },
  nohup: { noArgument: new Set(), takesArgument: new Set() },
  sudo: { noArgument: new Set(["A", "B", "b", "E", "e", "H", "i", "K", "k", "l", "N", "n", "P", "S", "s", "v", "V"]), takesArgument: new Set(["C", "D", "g", "h", "p", "r", "R", "t", "T", "u", "U"]) },
  timeout: { noArgument: new Set(["f", "p", "v"]), takesArgument: new Set(["k", "s"]) },
};

const WRAPPER_LONG_OPTIONS = {
  command: { noArgument: new Set(["help", "version"]), takesArgument: new Set() },
  env: { noArgument: new Set(["ignore-environment", "null", "help", "version"]), takesArgument: new Set(["argv0", "block-signal", "chdir", "default-signal", "ignore-signal", "split-string", "unset"]) },
  exec: { noArgument: new Set(), takesArgument: new Set() },
  nohup: { noArgument: new Set(["help", "version"]), takesArgument: new Set() },
  sudo: { noArgument: new Set(["askpass", "background", "bell", "edit", "help", "login", "non-interactive", "preserve-env", "preserve-groups", "remove-timestamp", "reset-timestamp", "set-home", "shell", "stdin", "validate", "version"]), takesArgument: new Set(["chdir", "chroot", "close-from", "command-timeout", "group", "host", "other-user", "prompt", "role", "type", "user"]) },
  timeout: { noArgument: new Set(["foreground", "preserve-status", "verbose", "help", "version"]), takesArgument: new Set(["kill-after", "signal"]) },
};

function consumeWrapperOptions(name, words, index) {
  const optionOwner = name === "gtimeout" ? "timeout" : name;
  const short = WRAPPER_OPTIONS[optionOwner];
  const long = WRAPPER_LONG_OPTIONS[optionOwner];
  const embeddedPayloads = [];
  let next = index;
  while (words[next]) {
    const value = words[next].value;
    if (value === "--") return { index: next + 1, unresolved: false, embeddedPayloads };
    if (!value.startsWith("-") || value === "-") return { index: next, unresolved: false, embeddedPayloads };
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      const option = value.slice(2, equals === -1 ? undefined : equals);
      if (long.noArgument.has(option)) {
        next += 1;
        continue;
      }
      if (!long.takesArgument.has(option)) return { index: next, unresolved: true, embeddedPayloads };
      if (equals !== -1) {
        if (name === "env" && option === "split-string") embeddedPayloads.push(value.slice(equals + 1));
        next += 1;
        continue;
      }
      if (!words[next + 1]) return { index: next, unresolved: true, embeddedPayloads };
      if (name === "env" && option === "split-string") embeddedPayloads.push(words[next + 1].value);
      next += 2;
      continue;
    }
    let consumedArgument = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      const option = value[offset];
      if (short.noArgument.has(option)) continue;
      if (!short.takesArgument.has(option)) return { index: next, unresolved: true, embeddedPayloads };
      if (offset + 1 === value.length) {
        if (!words[next + 1]) return { index: next, unresolved: true, embeddedPayloads };
        if (name === "env" && option === "S") embeddedPayloads.push(words[next + 1].value);
        next += 2;
      } else {
        if (name === "env" && option === "S") embeddedPayloads.push(value.slice(offset + 1));
        next += 1;
      }
      consumedArgument = true;
      break;
    }
    if (!consumedArgument) next += 1;
  }
  return { index: next, unresolved: false, embeddedPayloads };
}

export function commandPosition(tokens) {
  const words = wordsInNode(tokens);
  let index = 0;
  while (index < words.length && isAssignment(words[index].value)) index += 1;
  const prefixAssignments = index;
  const wrappers = [];
  let unresolvedWrapperOption = false;
  const wrapperPayloads = [];
  let command = words[index];
  while (command) {
    const name = basename(command.value);
    if (name === "exec" || name === "command" || name === "sudo" || name === "nohup") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      wrapperPayloads.push(...options.embeddedPayloads);
      index = options.index;
      command = words[index];
      continue;
    }
    if (name === "env") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      wrapperPayloads.push(...options.embeddedPayloads);
      index = options.index;
      while (words[index] && (words[index].value.startsWith("-") || isAssignment(words[index].value))) index += 1;
      command = words[index];
      continue;
    }
    if (name === "timeout" || name === "gtimeout") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      index = options.index;
      if (!words[index]) {
        unresolvedWrapperOption = true;
        command = undefined;
        break;
      }
      index += 1;
      command = words[index];
      if (!command) {
        unresolvedWrapperOption = true;
        break;
      }
      continue;
    }
    break;
  }
  return { words, index, command, wrappers, prefixAssignments, unresolvedWrapperOption, wrapperPayloads };
}

const PROTECTED_SCRIPTS = [
  { relative: "bin/fm-watch-arm.sh", kind: "arm" },
  { relative: "bin/fm-watch-checkpoint.sh", kind: "checkpoint" },
  { relative: "bin/fm-watch.sh", kind: "watch" },
];

function protectedIdentity(value, root) {
  const normalized = path.normalize(value);
  for (const { relative, kind } of PROTECTED_SCRIPTS) {
    if (normalized === relative || normalized === path.join(root, relative) || normalized.endsWith(`/${relative}`)) return kind;
  }
  return "";
}

function hasUnclassifiableProtectedExpansion(word, root) {
  if (!word?.unquotedExpansion || protectedIdentity(word.value, root)) return false;
  return /(?:^|\/)fm-watch/.test(word.value);
}

function shellInvocation(position) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const option = words[i];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.value)) {
      let payloadIndex = i + 1;
      if (words[payloadIndex]?.value === "--") payloadIndex += 1;
      return { kind: "command", payload: words[payloadIndex] || null };
    }
    if (/^[-+]O$/.test(option.value)) {
      i += 1;
      continue;
    }
    if (option.value === "--" || /^[-+]/.test(option.value)) continue;
    return { kind: "script", payload: option };
  }
  return { kind: "stdin", payload: null };
}

function shellHeredocPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const heredocs = tokens.filter((token) => token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string");
  return heredocs.length === 0 ? [] : [heredocs.at(-1).heredoc];
}

function shellHereStringPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const payloads = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type !== "redir" || token.value !== "<<<" || token.fd !== 0) continue;
    const payload = tokens[i + 1];
    if (payload?.type === "word" && payload.literal && payload.subs.length === 0) payloads.push(payload.value);
  }
  return payloads;
}

function sourcedScript(position) {
  if (!position.command || ![".", "source"].includes(position.command.value)) return null;
  return position.words[position.index + 1] || null;
}

function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

function wordReferencesAny(word, names) {
  if (!word || names.size === 0) return false;
  for (const match of word.value.matchAll(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g)) {
    if (names.has(match[1] || match[2])) return true;
  }
  return false;
}

function hasDynamicExecutionPayload(position, context) {
  if (!position.command) return false;
  const name = basename(position.command.value);
  if (["sh", "bash", "zsh"].includes(name)) {
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(position.words[i].value)) continue;
      const payload = position.words[i + 1];
      return Boolean(payload && (!payload.literal || payload.subs.length > 0) && wordReferencesAny(payload, context.protectedVariables));
    }
  }
  if (name === "eval") {
    return position.words.slice(position.index + 1).some((payload) => (!payload.literal || payload.subs.length > 0) && wordReferencesAny(payload, context.protectedVariables));
  }
  return false;
}

function assignmentName(word) {
  const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
  return match ? match[1] : "";
}

function contextWithAssignments(context, words) {
  const protectedVariables = new Set(context.protectedVariables || []);
  const watcherPatterns = new Set(context.watcherPatterns || []);
  const watcherPids = new Set(context.watcherPids || []);
  for (const word of words) {
    const name = assignmentName(word);
    if (!name) continue;
    const value = word.value.slice(word.value.indexOf("=") + 1);
    if (rawMentionsProtected(value) || wordReferencesAny(word, protectedVariables)) protectedVariables.add(name);
    else protectedVariables.delete(name);
    if (/fm-watch/.test(value) || wordReferencesAny(word, watcherPatterns)) watcherPatterns.add(name);
    else watcherPatterns.delete(name);
    if (wordReferencesAny(word, watcherPids)) watcherPids.add(name);
    else watcherPids.delete(name);
  }
  return { ...context, protectedVariables, watcherPatterns, watcherPids };
}

function nodeHasRedirection(tokens) {
  return tokens.some((token) => token.type === "redir");
}

function nodeHasUnsafeSubstitution(tokens) {
  return tokens.some((token) => token.type === "word" && token.subs.length > 0);
}

function isWatcherPgrep(position, context) {
  if (!position.command || basename(position.command.value) !== "pgrep") return false;
  return position.words.slice(position.index + 1).some((word) => /(?:^|\/)fm-watch(?:\.sh)?\b/.test(word.value) || wordReferencesAny(word, context.watcherPatterns));
}

function analyzeProgram(command, context, depth = 0) {
  if (depth > 12) {
    return { error: "recursion limit", protectedFound: rawMentionsProtected(command), broadKill: rawMentionsBroadKill(command), pgrepWatcher: false, watcherPids: new Set() };
  }
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    return { error: lexed.error, protectedFound: rawMentionsProtected(command), broadKill: rawMentionsBroadKill(command), pgrepWatcher: false, watcherPids: new Set() };
  }
  const program = splitProgram(lexed.tokens);
  const nodeInfos = [];
  let nestedProtected = false;
  let broadKill = false;
  let pgrepWatcher = false;
  let unsupported = false;
  let activeContext = {
    ...context,
    protectedVariables: new Set(context.protectedVariables || []),
    watcherPatterns: new Set(context.watcherPatterns || []),
    watcherPids: new Set(context.watcherPids || []),
  };
  let unclassifiableProtected = false;

  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);
    const nodeContext = contextWithAssignments(activeContext, position.words);
    const firstName = basename(position.words[0]?.value || "");
    if (["if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "do", "done", "function", "time", "coproc"].includes(firstName)) {
      unsupported = true;
    }

    let nodeNestedProtected = false;
    let nodePgrepWatcher = false;
    const substitutionResults = new Map();
    for (const payload of position.wrapperPayloads) {
      const nested = analyzeProgram(payload, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(payload)) unsupported = true;
    }
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = analyzeProgram(token.content, nodeContext, depth + 1);
        nodeNestedProtected ||= nested.protectedFound;
        broadKill ||= nested.broadKill;
        nodePgrepWatcher ||= nested.pgrepWatcher;
        if (nested.error && rawMentionsProtected(token.content)) unsupported = true;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = analyzeProgram(substitution.content, nodeContext, depth + 1);
          substitutionResults.set(substitution, nested);
          nodeNestedProtected ||= nested.protectedFound;
          broadKill ||= nested.broadKill;
          nodePgrepWatcher ||= nested.pgrepWatcher;
          if (nested.error && rawMentionsProtected(substitution.content)) unsupported = true;
        }
      }
    }

    const shell = shellInvocation(position);
    const shellPayload = shell?.kind === "command" ? shell.payload : null;
    const shellScript = shell?.kind === "script" ? shell.payload : null;
    const sourceScript = sourcedScript(position);
    const literalEvalPayload = evalPayload(position);
    const heredocPayloads = shellHeredocPayloads(tokens, position);
    const hereStringPayloads = shellHereStringPayloads(tokens, position);
    for (const script of [shellScript, sourceScript]) {
      if (!script) continue;
      nodeNestedProtected ||= Boolean(protectedIdentity(script.value, context.root)) || wordReferencesAny(script, nodeContext.protectedVariables);
      unclassifiableProtected ||= hasUnclassifiableProtectedExpansion(script, context.root);
    }
    if (shellPayload && (!shellPayload.literal || shellPayload.subs.length > 0)) {
      if (wordReferencesAny(shellPayload, nodeContext.protectedVariables)) nodeNestedProtected = true;
    } else if (shellPayload) {
      const nested = analyzeProgram(shellPayload.value, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(shellPayload.value)) unsupported = true;
    }
    for (const payload of [literalEvalPayload, ...heredocPayloads, ...hereStringPayloads]) {
      if (payload === null) continue;
      const nested = analyzeProgram(payload, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(payload)) unsupported = true;
    }

    const executable = position.command?.value || "";
    const protectedKind = protectedIdentity(executable, context.root);
    if (hasUnclassifiableProtectedExpansion(position.command, context.root)) unclassifiableProtected = true;
    const commandName = basename(executable);
    const args = position.words.slice(position.index + 1);
    if (commandName === "pkill" && args.some((word) => /fm-watch/.test(word.value) || wordReferencesAny(word, nodeContext.watcherPatterns))) broadKill = true;
    if (commandName === "kill" && (nodePgrepWatcher || args.some((word) => wordReferencesAny(word, nodeContext.watcherPids)))) broadKill = true;
    if (isWatcherPgrep(position, nodeContext)) pgrepWatcher = true;
    if (hasDynamicExecutionPayload(position, nodeContext) || wordReferencesAny(position.command, nodeContext.protectedVariables)) nodeNestedProtected = true;
    for (const word of position.words) {
      const name = assignmentName(word);
      if (!name) continue;
      if (word.subs.some((substitution) => substitutionResults.get(substitution)?.pgrepWatcher)) nodeContext.watcherPids.add(name);
    }
    pgrepWatcher ||= nodePgrepWatcher;
    nestedProtected ||= nodeNestedProtected;
    activeContext = nodeContext;
    if (position.unresolvedWrapperOption) unsupported = true;
    nodeInfos.push({
      tokens,
      position,
      protectedKind,
      nestedProtected: nodeNestedProtected,
      redirection: nodeHasRedirection(tokens),
      substitution: nodeHasUnsafeSubstitution(tokens),
    });
  }

  const directProtected = nodeInfos.some((info) => Boolean(info.protectedKind));
  const protectedFound = directProtected || nestedProtected || unclassifiableProtected;
  if (unclassifiableProtected) unsupported = true;
  const broadKillFound = broadKill || (unsupported && rawMentionsBroadKill(command));
  if (unsupported && (protectedFound || rawMentionsProtected(command) || broadKillFound)) {
    return { error: "unsupported compound grammar", protectedFound: true, broadKill: broadKillFound, pgrepWatcher, watcherPids: activeContext.watcherPids, program, nodeInfos };
  }
  return { error: "", protectedFound, directProtected, nestedProtected, broadKill: broadKillFound, pgrepWatcher, watcherPids: activeContext.watcherPids, program, nodeInfos };
}

function xModePathAllowed(value, home) {
  if (value === "config/x-mode.env" || value === "./config/x-mode.env") return true;
  if (!path.isAbsolute(value)) return false;
  return path.normalize(value) === path.join(path.normalize(home), "config/x-mode.env");
}

function ordinaryWordsOnly(tokens) {
  return tokens.every((token) => token.type === "word" && token.subs.length === 0);
}

function setupKind(info, context) {
  const { tokens, position } = info;
  if (!ordinaryWordsOnly(tokens) || position.prefixAssignments > 0 || position.wrappers.length > 0) return "";
  const values = position.words.map((word) => word.value);
  if (values[0] === "cd" && values.length === 2) return "cd";
  if (values[0] === "export" && values.length === 2 && isAssignment(values[1])) return "export";
  if ((values[0] === "source" || values[0] === ".") && values.length === 2 && xModePathAllowed(values[1], context.home)) return "source";
  if (values[0] === "[" && values[1] === "-f" && values[3] === "]" && values.length === 4 && xModePathAllowed(values[2], context.home)) return "test-source";
  return "";
}

function finalProtectedAllowed(info) {
  if (!info.protectedKind || info.protectedKind === "watch" || info.redirection || info.substitution) return false;
  if (!ordinaryWordsOnly(info.tokens) || info.position.prefixAssignments > 0) return false;
  const wrappers = info.position.wrappers;
  return wrappers.length === 0 || (wrappers.length === 1 && wrappers[0] === "exec");
}

function blessedProgram(analysis, context) {
  const { nodeInfos } = analysis;
  const separators = analysis.program.separators;
  if (nodeInfos.length === 0 || separators.some((separator) => ![";", "newline", "&&"].includes(separator))) return false;
  if (!finalProtectedAllowed(nodeInfos.at(-1))) return false;
  if (nodeInfos.slice(0, -1).some((info) => info.protectedKind || info.nestedProtected)) return false;

  const setup = nodeInfos.slice(0, -1).map((info) => setupKind(info, context));
  if (setup.some((kind) => !kind)) return false;
  for (let i = 0; i < setup.length; i += 1) {
    if (setup[i] !== "test-source") continue;
    if (setup[i + 1] !== "source" || separators[i] !== "&&") return false;
    i += 1;
  }
  return true;
}

function decision(command, root, home) {
  const context = { root: path.normalize(root), home: path.normalize(home), protectedVariables: new Set(), watcherPatterns: new Set(), watcherPids: new Set() };
  const analysis = analyzeProgram(command, context);
  if (analysis.broadKill) return deny("broad-watcher-kill");
  if (analysis.error && analysis.protectedFound) return deny("unclassifiable-protected-command");
  if (!analysis.protectedFound) return { decision: "allow" };
  if (analysis.nodeInfos?.some((info) => info.protectedKind === "watch")) return deny("watcher-direct");
  if (analysis.nestedProtected) return deny("watcher-nested");

  const separators = analysis.program.separators;
  if (separators.includes("&") || analysis.nodeInfos.some((info) => info.position.wrappers.includes("nohup")) || analysis.nodeInfos.some((info) => basename(info.position.words[0]?.value || "") === "disown")) {
    return deny("watcher-background");
  }
  if (separators.includes("|") || separators.includes("|&")) return deny("watcher-pipeline");
  if (analysis.nodeInfos.some((info) => info.redirection)) return deny("watcher-redirection");
  if (analysis.nodeInfos.some((info) => info.substitution)) return deny("watcher-nested");
  if (blessedProgram(analysis, context)) return { decision: "allow" };
  if (analysis.nodeInfos.some((info) => info.position.prefixAssignments > 0 || info.position.wrappers.some((wrapper) => wrapper !== "exec"))) {
    return deny("watcher-nested");
  }
  return deny("watcher-bundled");
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// Run the CLI only when invoked directly (node fm-arm-command-policy.mjs ...),
// never when imported by a sibling policy such as bin/fm-cd-command-policy.mjs.
function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.root || !args.home) throw new Error("--root and --home are required");
    if (!args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.root, args.home);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
