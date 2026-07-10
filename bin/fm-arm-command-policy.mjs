#!/usr/bin/env node
// Semantic policy for watcher arm and checkpoint shell commands.
//
// This parser is deliberately narrow.
// It recognizes executed command positions without evaluating, expanding,
// sourcing, or running any byte of the submitted command.

import path from "node:path";

const REASONS = {
  "watcher-background": "a protected watcher command cannot run in an asynchronous shell list or through nohup/disown",
  "watcher-pipeline": "a protected watcher command must not participate in a pipeline",
  "watcher-redirection": "a protected watcher command must not use shell redirection",
  "watcher-bundled": "a protected watcher command must be the sole final command after approved setup nodes",
  "watcher-nested": "a protected watcher command must not run through a wrapper, substitution, or compound command",
  "broad-watcher-kill": "a broad process kill targeting the firstmate watcher is forbidden",
  "unclassifiable-protected-command": "unsupported or malformed shell syntax contains a protected watcher command",
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
  return /(?:^|[/\s'"`(])fm-watch-(?:arm|checkpoint)\.sh\b/.test(command);
}

function rawMentionsWatcher(command) {
  return /fm-watch/.test(command);
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

class Lexer {
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
        this.tokens.push({ type: "redir", value: redirection.value, inlineTarget: redirection.inlineTarget });
        if (redirection.value === "<<" || redirection.value === "<<-") this.expectHeredoc = redirection.value;
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
        this.pendingHeredocs.push({ delimiter: word.value, stripTabs: this.expectHeredoc === "<<-" });
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
      }
      if (!found) {
        this.error = "unclosed heredoc";
        break;
      }
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
    const match = remaining.match(/^(?:\d+)?(?:<<<|<<-|<<|>>|<>|>&|<&|>|<)(?:&?[0-9-]+)?/);
    if (!match) return "";
    this.index += match[0].length;
    const inlineTarget = /(?:>&|<&)[0-9-]+$/.test(match[0]);
    let normalized = match[0].replace(/^\d+/, "");
    if (inlineTarget) normalized = normalized.replace(/[0-9-]+$/, "");
    return { value: normalized, inlineTarget };
  }

  readWord() {
    const word = { type: "word", value: "", literal: true, subs: [], quoted: false };
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
        word.value += this.source[this.index + 1];
        this.index += 2;
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

function splitProgram(tokens) {
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

function commandPosition(tokens) {
  const words = wordsInNode(tokens);
  let index = 0;
  while (index < words.length && isAssignment(words[index].value)) index += 1;
  const prefixAssignments = index;
  const wrappers = [];
  let command = words[index];
  while (command) {
    const name = basename(command.value);
    if (name === "exec" || name === "command" || name === "sudo" || name === "nohup") {
      wrappers.push(name);
      index += 1;
      while (words[index] && words[index].value.startsWith("-")) index += 1;
      command = words[index];
      continue;
    }
    if (name === "env") {
      wrappers.push(name);
      index += 1;
      while (words[index] && (words[index].value.startsWith("-") || isAssignment(words[index].value))) index += 1;
      command = words[index];
      continue;
    }
    break;
  }
  return { words, index, command, wrappers, prefixAssignments };
}

function protectedIdentity(value, root) {
  const normalized = path.normalize(value);
  const arm = "bin/fm-watch-arm.sh";
  const checkpoint = "bin/fm-watch-checkpoint.sh";
  if (normalized === arm || normalized === `./${arm}` || normalized === path.join(root, arm)) return "arm";
  if (normalized === checkpoint || normalized === `./${checkpoint}` || normalized === path.join(root, checkpoint)) return "checkpoint";
  return "";
}

function nestedShellPayload(position) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  for (let i = position.index + 1; i < position.words.length; i += 1) {
    const option = position.words[i];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.value)) {
      const payload = position.words[i + 1];
      if (!payload || !payload.literal || payload.subs.length > 0) return null;
      return payload.value;
    }
  }
  return null;
}

function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payload = position.words[position.index + 1];
  if (!payload || !payload.literal || payload.subs.length > 0) return null;
  return payload.value;
}

function hasDynamicExecutionPayload(position) {
  if (!position.command) return false;
  const name = basename(position.command.value);
  if (["sh", "bash", "zsh"].includes(name)) {
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(position.words[i].value)) continue;
      const payload = position.words[i + 1];
      return Boolean(payload && (!payload.literal || payload.subs.length > 0));
    }
  }
  if (name === "eval") {
    const payload = position.words[position.index + 1];
    return Boolean(payload && (!payload.literal || payload.subs.length > 0));
  }
  return false;
}

function nodeHasRedirection(tokens) {
  return tokens.some((token) => token.type === "redir");
}

function nodeHasUnsafeSubstitution(tokens) {
  return tokens.some((token) => token.type === "word" && token.subs.length > 0);
}

function isWatcherPgrep(position) {
  if (!position.command || basename(position.command.value) !== "pgrep") return false;
  return position.words.slice(position.index + 1).some((word) => /(?:^|\/)fm-watch(?:\.sh)?\b/.test(word.value));
}

function analyzeProgram(command, context, depth = 0) {
  if (depth > 12) {
    return { error: "recursion limit", protectedFound: rawMentionsProtected(command), broadKill: false, pgrepWatcher: false };
  }
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    return { error: lexed.error, protectedFound: rawMentionsProtected(command), broadKill: false, pgrepWatcher: false };
  }
  const program = splitProgram(lexed.tokens);
  const nodeInfos = [];
  let nestedProtected = false;
  let broadKill = false;
  let pgrepWatcher = false;
  let unsupported = false;
  let constructedProtectedPayload = false;

  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);
    const firstName = basename(position.words[0]?.value || "");
    if (["if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "do", "done", "function", "time", "coproc"].includes(firstName)) {
      unsupported = true;
    }

    let nodeNestedProtected = false;
    let nodePgrepWatcher = false;
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = analyzeProgram(token.content, context, depth + 1);
        nodeNestedProtected ||= nested.protectedFound;
        broadKill ||= nested.broadKill;
        nodePgrepWatcher ||= nested.pgrepWatcher;
        if (nested.error && rawMentionsProtected(token.content)) unsupported = true;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = analyzeProgram(substitution.content, context, depth + 1);
          nodeNestedProtected ||= nested.protectedFound;
          broadKill ||= nested.broadKill;
          nodePgrepWatcher ||= nested.pgrepWatcher;
          if (nested.error && rawMentionsProtected(substitution.content)) unsupported = true;
        }
      }
    }

    const shellPayload = nestedShellPayload(position);
    const literalEvalPayload = evalPayload(position);
    for (const payload of [shellPayload, literalEvalPayload]) {
      if (payload === null) continue;
      const nested = analyzeProgram(payload, context, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(payload)) unsupported = true;
    }

    const executable = position.command?.value || "";
    const protectedKind = protectedIdentity(executable, context.root);
    const commandName = basename(executable);
    const args = position.words.slice(position.index + 1);
    if (commandName === "pkill" && args.some((word) => /fm-watch/.test(word.value))) broadKill = true;
    if (commandName === "kill" && nodePgrepWatcher) broadKill = true;
    if (isWatcherPgrep(position)) pgrepWatcher = true;
    if (constructedProtectedPayload && hasDynamicExecutionPayload(position)) nodeNestedProtected = true;
    if (position.words.some((word) => isAssignment(word.value) && rawMentionsProtected(word.value.slice(word.value.indexOf("=") + 1)))) {
      constructedProtectedPayload = true;
    }
    pgrepWatcher ||= nodePgrepWatcher;
    nestedProtected ||= nodeNestedProtected;
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
  const protectedFound = directProtected || nestedProtected;
  if (unsupported && (protectedFound || rawMentionsProtected(command))) {
    return { error: "unsupported compound grammar", protectedFound: true, broadKill, pgrepWatcher, program, nodeInfos };
  }
  return { error: "", protectedFound, directProtected, nestedProtected, broadKill, pgrepWatcher, program, nodeInfos };
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
  if (!info.protectedKind || info.redirection || info.substitution) return false;
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
  const context = { root: path.normalize(root), home: path.normalize(home) };
  const analysis = analyzeProgram(command, context);
  if (analysis.broadKill) return deny("broad-watcher-kill");
  if (analysis.error && rawMentionsProtected(command)) return deny("unclassifiable-protected-command");
  if (!analysis.protectedFound) return { decision: "allow" };
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

try {
  const args = parseArguments(process.argv.slice(2));
  if (!args.root || !args.home) throw new Error("--root and --home are required");
  if (!args.command || !rawMentionsWatcher(args.command)) {
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
