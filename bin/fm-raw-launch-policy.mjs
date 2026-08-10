import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";

const SHELLS = new Set(["sh", "bash", "zsh"]);
const SHELL_KEYWORDS = new Set(["case", "do", "elif", "else", "for", "if", "in", "then", "until", "while"]);
const RAW_OMP_TOKEN = /(?:^|[\s;&|()'"`])(?:[^\s;&|()<>]*\/)?omp(?:$|[\s;&|()<> '"`])/;

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function mentionsOmpToken(source) {
  return RAW_OMP_TOKEN.test(source);
}

function isOmpWord(word) {
  return Boolean(word && (!word.literal || basename(word.value) === "omp"));
}

const DISPATCHER_OPTIONS = {
  nice: { takesArgument: new Set(["n", "adjustment"]) },
  setsid: { takesArgument: new Set() },
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
    for (let offset = 1; offset < value.length; offset += 1) {
      if (!options.takesArgument.has(value[offset])) continue;
      takesArgument = true;
      break;
    }
    index += takesArgument ? 2 : 1;
  }
  return null;
}

function containsOmpCommand(source, depth = 0) {
  if (depth > 12) return true;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return mentionsOmpToken(source);
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
    if (!position.command) continue;
    if (isOmpWord(position.command)) return true;
    if (isOmpWord(dispatcherTarget(position))) return true;
    for (const payload of position.wrapperPayloads) {
      if (containsOmpCommand(payload, depth + 1)) return true;
    }

    const command = basename(position.command.value);
    if (SHELLS.has(command)) {
      for (let index = position.index + 1; index < position.words.length; index += 1) {
        if (!/^-?[A-Za-z]*c[A-Za-z]*$/.test(position.words[index].value)) continue;
        const payload = position.words[index + 1];
        if (!payload || !payload.literal) return true;
        if (containsOmpCommand(payload.value, depth + 1)) return true;
      }
    }
    if (command === "eval") {
      for (const payload of position.words.slice(position.index + 1)) {
        if (!payload.literal || containsOmpCommand(payload.value, depth + 1)) return true;
      }
    }
    if (command === "xargs") {
      for (const payload of position.words.slice(position.index + 1)) {
        if (isOmpWord(payload)) return true;
      }
    }
    for (let index = 1; index < position.words.length; index += 1) {
      if (SHELL_KEYWORDS.has(position.words[index - 1].value) && isOmpWord(position.words[index])) return true;
    }
  }
  return false;
}

if (process.argv.length !== 4 || process.argv[2] !== "--command") {
  process.exitCode = 2;
} else {
  process.stdout.write(`${containsOmpCommand(process.argv[3]) ? "omp" : "other"}\n`);
}
