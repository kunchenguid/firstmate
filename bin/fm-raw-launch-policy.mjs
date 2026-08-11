import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";
import { readFileSync } from "node:fs";

const SHELLS = new Set(["sh", "bash", "zsh"]);
const SOURCE_COMMANDS = new Set([".", "source"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function isOmpWord(word) {
  return Boolean(word && word.literal && basename(word.value) === "omp");
}

const DISPATCHER_OPTIONS = {
  nice: { takesArgument: new Set(["n", "adjustment"]) },
  setsid: { takesArgument: new Set() },
  stdbuf: { takesArgument: new Set(["i", "o", "e", "input", "output", "error"]) },
  time: { takesArgument: new Set(["f", "format", "o", "output"]) },
};

function dispatcherTarget(position) {
  const options = DISPATCHER_OPTIONS[basename(position.command?.value || "")];
  if (!options) return null;
  let index = position.index + 1;
  while (position.words[index]) {
    const value = position.words[index].value;
    if (value === "--") return position.words[index + 1] || null;
    if (!value.startsWith("-") || value === "-") return position.words[index];
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      const option = value.slice(2, equals === -1 ? undefined : equals);
      index += equals === -1 && options.takesArgument.has(option) ? 2 : 1;
      continue;
    }
    let takesArgument = false;
    let attachedArgument = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      if (!options.takesArgument.has(value[offset])) continue;
      takesArgument = true;
      attachedArgument = offset + 1 < value.length;
      break;
    }
    index += takesArgument && !attachedArgument ? 2 : 1;
  }
  return null;
}

function dispatcherChainTarget(position) {
  let index = position.index;
  let command = position.words[index];
  for (let depth = 0; command && depth < 8; depth += 1) {
    if (!DISPATCHER_OPTIONS[basename(command.value)]) return command;
    const target = dispatcherTarget({ ...position, index, command });
    if (!target) return null;
    if (isOmpWord(target)) return target;
    index = position.words.findIndex((word, wordIndex) => wordIndex > index && word === target);
    if (index < 0) return target;
    command = target;
  }
  return null;
}

const XARGS_OPTIONS = new Set(["a", "d", "E", "I", "L", "n", "P", "R", "s", "S"]);

function xargsTarget(position) {
  if (basename(position.command?.value || "") !== "xargs") return null;
  let index = position.index + 1;
  while (position.words[index]) {
    const value = position.words[index].value;
    if (value === "--") return position.words[index + 1] || null;
    if (!value.startsWith("-") || value === "-") return position.words[index];
    if (value === "-0") {
      index += 1;
      continue;
    }
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      const option = value.slice(2, equals === -1 ? undefined : equals);
      index += equals === -1 && XARGS_OPTIONS.has(option) ? 2 : 1;
      continue;
    }
    let takesArgument = false;
    let attachedArgument = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      if (!XARGS_OPTIONS.has(value[offset])) continue;
      takesArgument = true;
      attachedArgument = offset + 1 < value.length;
      break;
    }
    index += takesArgument && !attachedArgument ? 2 : 1;
  }
  return null;
}

function shellScriptTarget(position) {
  const command = basename(position.command?.value || "");
  if (!SHELLS.has(command) && !SOURCE_COMMANDS.has(command)) return null;
  let index = position.index + 1;
  while (position.words[index]) {
    const value = position.words[index].value;
    if (value === "--") return position.words[index + 1] || null;
    if (!value.startsWith("-") || value === "-") return position.words[index];
    if (SHELLS.has(command) && /^-?[A-Za-z]*c[A-Za-z]*$/.test(value)) return null;
    if (SHELLS.has(command) && value === "-s") return null;
    index += 1;
  }
  return null;
}

function shellInputScriptTarget(tokens, position) {
  const command = basename(position.command?.value || "");
  if (!SHELLS.has(command)) return null;
  for (let index = 0; index < tokens.length - 1; index += 1) {
    const token = tokens[index];
    if (token.type !== "redir" || token.value !== "<" || token.fd !== 0 || token.inlineTarget) continue;
    const target = tokens[index + 1];
    if (target?.type === "word") return target;
  }
  return null;
}

function supportedWrapperScriptTarget(position) {
  return basename(position.command?.value || "") === "start-omp.sh" ? position.command : null;
}

function shellScriptUsesOmp(word, depth) {
  if (!word || !word.literal) return false;
  try {
    return containsOmpCommand(readFileSync(word.value, "utf8"), depth + 1);
  } catch {
    return false;
  }
}

function containsOmpCommand(source, depth = 0) {
  if (depth > 12) return false;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    for (const token of node) {
      if (token.type === "group" && containsOmpCommand(token.content, depth + 1)) return true;
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        if (containsOmpCommand(substitution.content, depth + 1)) return true;
      }
    }

    const position = commandPosition(node);
    for (const payload of position.wrapperPayloads) {
      if (containsOmpCommand(payload, depth + 1)) return true;
    }
    if (!position.command) continue;
    if (isOmpWord(position.command)) return true;
    if (isOmpWord(dispatcherChainTarget(position))) return true;
    if (isOmpWord(xargsTarget(position))) return true;

    const command = basename(position.command.value);
    const script = shellScriptTarget(position)
      || shellInputScriptTarget(node, position)
      || supportedWrapperScriptTarget(position);
    if (script && shellScriptUsesOmp(script, depth)) return true;
    if (SHELLS.has(command)) {
      for (let index = position.index + 1; index < position.words.length; index += 1) {
        if (!/^-?[A-Za-z]*c[A-Za-z]*$/.test(position.words[index].value)) continue;
        const payload = position.words[index + 1];
        if (payload?.literal && containsOmpCommand(payload.value, depth + 1)) return true;
      }
    }
    if (command === "eval") {
      const payloads = position.words.slice(position.index + 1);
      if (payloads.every((payload) => payload.literal)) {
        const payload = payloads.map((word) => word.value).join(" ");
        if (containsOmpCommand(payload, depth + 1)) return true;
      }
    }
  }
  return false;
}

if (process.argv.length !== 4 || process.argv[2] !== "--command") {
  process.exitCode = 2;
} else {
  process.stdout.write(`${containsOmpCommand(process.argv[3]) ? "omp" : "other"}\n`);
}
