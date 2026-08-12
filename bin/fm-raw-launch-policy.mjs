import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";
import { accessSync, constants, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";

const SHELLS = new Set(["sh", "bash", "zsh"]);
const SOURCE_COMMANDS = new Set([".", "source"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function executionContext(value = process.cwd(), pathValue = process.env.PATH) {
  if (value && typeof value === "object") {
    return { cwd: value.cwd || "", path: value.path ?? "" };
  }
  return { cwd: value || "", path: pathValue ?? "" };
}

function resolveExecutable(value, context = process.cwd()) {
  if (!value || !value.literal && typeof value !== "string") return null;
  const { cwd, path } = executionContext(context);
  const name = typeof value === "string" ? value : value.value;
  if (!name || name.includes("\0")) return null;
  let candidates;
  if (name.includes("/")) {
    if (!name.startsWith("/") && !cwd) return null;
    candidates = [name.startsWith("/") ? name : resolvePath(cwd, name)];
  } else {
    candidates = path === "" ? [] : path.split(":").map((directory) => {
      const base = directory || cwd;
      return base && !base.startsWith("/") ? resolvePath(cwd, base, name) : `${base}/${name}`;
    });
  }
  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      if (!statSync(candidate).isFile()) continue;
      return realpathSync(candidate);
    } catch {
      continue;
    }
  }
  return null;
}

function resolveCommandCandidate(name, context = process.cwd()) {
  return name && !name.includes("/") ? resolveExecutable(name, context) : null;
}

const canonicalOmpPath = resolveExecutable("omp");
const canonicalBunPath = resolveExecutable("bun");
const canonicalOmpCommandPath = resolveCommandCandidate("omp");

function resolveCanonicalWrapperPath() {
  const directories = new Set();
  if (canonicalOmpCommandPath) directories.add(dirname(resolvePath(canonicalOmpCommandPath)));
  if (canonicalOmpPath) directories.add(dirname(canonicalOmpPath));
  const paths = new Set();
  for (const directory of directories) {
    const path = resolveExecutable(resolvePath(directory, "start-omp.sh"));
    if (path) paths.add(path);
  }
  return paths.size === 1 ? paths.values().next().value : null;
}

const canonicalWrapperPath = resolveCanonicalWrapperPath();

function isOmpWord(word, context = process.cwd()) {
  return Boolean(word && word.literal && canonicalOmpPath
    && resolveExecutable(word, context) === canonicalOmpPath);
}

function isBunWord(word, context = process.cwd()) {
  return Boolean(word && word.literal && canonicalBunPath
    && resolveExecutable(word, context) === canonicalBunPath);
}

function isSupportedWrapperWord(word, context = process.cwd()) {
  return Boolean(word && word.literal && canonicalWrapperPath
    && resolveExecutable(word, context) === canonicalWrapperPath);
}

function bunScriptTarget(position) {
  let index = position.index + 1;
  if (position.words[index]?.value === "run") index += 1;
  return position.words[index] || null;
}

function commandInvokesOmp(position, context = process.cwd()) {
  if (!position?.command) return false;
  if (isOmpWord(position.command, context)) return true;
  const script = isBunWord(position.command, context) ? bunScriptTarget(position) : null;
  return isOmpWord(script, context);
}

function nextWorkingDirectory(position, context) {
  const current = executionContext(context);
  if (basename(position?.command?.value || "") !== "cd") return current;
  const words = position.words.slice(position.index + 1);
  const target = words[0]?.value === "--" ? words[1] : words[0];
  const expectedLength = words[0]?.value === "--" ? 2 : 1;
  if (!target || words.length !== expectedLength || !target.literal || target.subs.length > 0) return null;
  if (!target.value.startsWith("/") && !current.cwd) return null;
  const candidate = target.value.startsWith("/") ? target.value : resolvePath(current.cwd, target.value);
  try {
    if (!statSync(candidate).isDirectory()) return null;
    return { ...current, cwd: realpathSync(candidate) };
  } catch {
    return null;
  }
}

function pathContextWithAssignments(context, words) {
  let current = executionContext(context);
  for (const word of words) {
    const match = word?.value?.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match || match[1] !== "PATH") continue;
    current = { ...current, path: word.literal && word.subs.length === 0 ? match[2] : "" };
  }
  return current;
}

function literalOptionArgument(word) {
  return word?.literal && word.subs.length === 0 ? word.value : null;
}

function envDirectory(value, context) {
  const directory = literalOptionArgument(value);
  if (directory === null || directory === "") return null;
  const current = executionContext(context);
  const candidate = directory.startsWith("/") ? directory : resolvePath(current.cwd, directory);
  try {
    if (!statSync(candidate).isDirectory()) return null;
    return realpathSync(candidate);
  } catch {
    return null;
  }
}

function consumeEnvDispatcher(words, index, context) {
  let current = executionContext(context);
  const payloads = [];
  let cursor = index + 1;
  let endOptions = false;
  while (words[cursor]) {
    const word = words[cursor];
    const value = literalOptionArgument(word);
    if (value === null) return { unresolved: true, payloads };
    if (endOptions) return { index: cursor, command: word, context: current, payloads };
    if (value === "--") {
      endOptions = true;
      cursor += 1;
      continue;
    }
    const assignment = value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (assignment) {
      if (assignment[1] === "PATH") current = { ...current, path: assignment[2] };
      cursor += 1;
      continue;
    }
    if (!value.startsWith("-") || value === "-") {
      return { index: cursor, command: word, context: current, payloads };
    }
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      const option = value.slice(2, equals === -1 ? undefined : equals);
      const argument = equals === -1
        ? words[cursor + 1]
        : { literal: true, subs: [], value: value.slice(equals + 1) };
      const argumentValue = literalOptionArgument(argument);
      if (["ignore-environment", "null", "verbose"].includes(option)) {
        if (equals !== -1) return { unresolved: true, payloads };
        if (option === "ignore-environment") current = { ...current, path: "" };
        cursor += 1;
        continue;
      }
      if (["help", "version"].includes(option)) return { unresolved: true, payloads };
      if (!["chdir", "split-string", "unset"].includes(option) || argumentValue === null) {
        return { unresolved: true, payloads };
      }
      if (option === "chdir") {
        const cwd = envDirectory(argument, current);
        if (!cwd) return { unresolved: true, payloads };
        current = { ...current, cwd };
      } else if (option === "unset") {
        if (argumentValue === "PATH") current = { ...current, path: "" };
      } else {
        payloads.push({ source: argumentValue, context: current });
        return { index: cursor + (equals === -1 ? 2 : 1), command: undefined, context: current, payloads };
      }
      cursor += equals === -1 ? 2 : 1;
      continue;
    }
    let consumed = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      const option = value[offset];
      if (["0", "P", "v"].includes(option)) continue;
      if (option === "i") {
        current = { ...current, path: "" };
        continue;
      }
      if (!["C", "S", "u"].includes(option)) return { unresolved: true, payloads };
      const attached = value.slice(offset + 1);
      const argument = attached ? { literal: true, subs: [], value: attached } : words[cursor + 1];
      const argumentValue = literalOptionArgument(argument);
      if (argumentValue === null) return { unresolved: true, payloads };
      if (option === "C") {
        const cwd = envDirectory(argument, current);
        if (!cwd) return { unresolved: true, payloads };
        current = { ...current, cwd };
      } else if (option === "u") {
        if (argumentValue === "PATH") current = { ...current, path: "" };
      } else {
        payloads.push({ source: argumentValue, context: current });
        return { index: cursor + (attached ? 1 : 2), command: undefined, context: current, payloads };
      }
      cursor += attached ? 1 : 2;
      consumed = true;
      break;
    }
    if (!consumed) cursor += 1;
  }
  return { index: cursor, command: undefined, context: current, payloads };
}

function dispatcherChainPosition(position, context = process.cwd()) {
  let index = position.index;
  if (position.wrappers?.includes("env")) {
    const envIndex = position.words.findIndex((word, wordIndex) =>
      wordIndex >= position.prefixAssignments && basename(word.value) === "env");
    if (envIndex >= 0) index = envIndex;
  }
  let currentContext = pathContextWithAssignments(context, position.words.slice(0, position.prefixAssignments));
  let command = position.words[index];
  const dispatcherPayloads = [];
  for (let depth = 0; command && depth < 8; depth += 1) {
    if (basename(command.value) === "env") {
      const envPosition = consumeEnvDispatcher(position.words, index, currentContext);
      if (envPosition.unresolved) {
        return { ...position, index, command, dispatcherUnresolved: true, dispatcherPayloads };
      }
      dispatcherPayloads.push(...envPosition.payloads);
      currentContext = envPosition.context;
      if (!envPosition.command) {
        return { ...position, index, command: undefined, dispatcherPayloads, executionContext: currentContext };
      }
      index = envPosition.index;
      command = envPosition.command;
      continue;
    }
    if (!DISPATCHER_OPTIONS[basename(command.value)]) {
      return { ...position, index, command, dispatcherPayloads, executionContext: currentContext };
    }
    const target = dispatcherTarget({ ...position, index, command });
    if (!target) return null;
    index = position.words.findIndex((word, wordIndex) => wordIndex > index && word === target);
    if (index < 0) return null;
    command = target;
  }
  return null;
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

function supportedWrapperScriptTarget(position, context) {
  const command = position.command;
  if (!isSupportedWrapperWord(command, context)) return null;
  const resolved = resolveExecutable(command, context);
  return resolved ? { ...command, value: resolved } : null;
}

function shellScriptUsesOmp(word, depth, context) {
  const current = executionContext(context);
  if (!word || !word.literal || (!word.value.startsWith("/") && !current.cwd)) return false;
  const scriptPath = word.value.startsWith("/") ? word.value : resolvePath(current.cwd, word.value);
  try {
    return containsOmpCommand(readFileSync(scriptPath, "utf8"), depth + 1, { ...current, cwd: dirname(scriptPath) });
  } catch {
    return false;
  }
}

function containsOmpCommand(source, depth = 0, context = process.cwd()) {
  if (depth > 12) return false;
  const inheritedContext = executionContext(context);
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  let workingContext = inheritedContext;
  for (const node of nodes) {
    const nodeContext = workingContext;
    for (const token of node) {
      if (token.type === "group" && containsOmpCommand(token.content, depth + 1, nodeContext)) return true;
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        if (containsOmpCommand(substitution.content, depth + 1, nodeContext)) return true;
      }
    }

    const position = commandPosition(node);
    if (position.unresolvedWrapperOption) continue;
    const hasEnvWrapper = position.wrappers.includes("env");
    if (!hasEnvWrapper) {
      for (const payload of position.wrapperPayloads) {
        if (containsOmpCommand(payload, depth + 1, nodeContext)) return true;
      }
    }
    if (!position.command && !hasEnvWrapper) continue;
    if (!hasEnvWrapper && commandInvokesOmp(position, nodeContext)) return true;
    const dispatched = dispatcherChainPosition(position, nodeContext);
    if (dispatched?.dispatcherUnresolved) {
      const nextContext = nextWorkingDirectory(position, nodeContext);
      workingContext = nextContext || { cwd: "", path: "" };
      continue;
    }
    if (!dispatched?.dispatcherUnresolved) {
      for (const payload of dispatched?.dispatcherPayloads || []) {
        const payloadSource = typeof payload === "string" ? payload : payload.source;
        const payloadContext = typeof payload === "string" ? dispatched?.executionContext || nodeContext : payload.context;
        if (containsOmpCommand(payloadSource, depth + 1, payloadContext)) return true;
      }
      if (commandInvokesOmp(dispatched, dispatched?.executionContext || nodeContext)) return true;
    }
    const analysisPosition = dispatched?.command ? dispatched : position;
    const analysisContext = dispatched?.executionContext || nodeContext;
    if (isOmpWord(xargsTarget(analysisPosition), analysisContext)) return true;

    if (!analysisPosition.command) continue;
    const command = basename(analysisPosition.command.value);
    const script = shellScriptTarget(analysisPosition)
      || shellInputScriptTarget(node, analysisPosition)
      || supportedWrapperScriptTarget(analysisPosition, analysisContext);
    if (script && shellScriptUsesOmp(script, depth, analysisContext)) return true;
    if (SHELLS.has(command)) {
      for (let index = analysisPosition.index + 1; index < analysisPosition.words.length; index += 1) {
        if (!/^-?[A-Za-z]*c[A-Za-z]*$/.test(analysisPosition.words[index].value)) continue;
        const payload = analysisPosition.words[index + 1];
        if (payload?.literal && containsOmpCommand(payload.value, depth + 1, analysisContext)) return true;
      }
    }
    if (command === "eval") {
      const payloads = analysisPosition.words.slice(analysisPosition.index + 1);
      if (payloads.every((payload) => payload.literal)) {
        const payload = payloads.map((word) => word.value).join(" ");
        if (containsOmpCommand(payload, depth + 1, analysisContext)) return true;
      }
    }
    const nextContext = nextWorkingDirectory(position, nodeContext);
    workingContext = nextContext || { cwd: "", path: "" };
  }
  return false;
}

if (process.argv.length !== 4 || process.argv[2] !== "--command") {
  process.exitCode = 2;
} else {
  process.stdout.write(`${containsOmpCommand(process.argv[3]) ? "omp" : "other"}\n`);
}
