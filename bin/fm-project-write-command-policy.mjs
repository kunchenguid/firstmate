#!/usr/bin/env node
// Semantic policy for writes aimed at firstmate project clones or worker copies.
//
// The shell lexer and command-position analysis are shared with the arm and cd
// guards. This policy adds target-path and file-tool decisions without parsing
// shell syntax independently. It is an accidental-write guard, not a security
// boundary; command-text analysis cannot identify every possible write.

import path from "node:path";
import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
  realpathSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

function denialReason(action) {
  const detail = action || "a project or worker-copy mutation";
  const alternative = ["git fetch", "git pull"].includes(detail)
    ? "read GitHub instead of fetching"
    : "delegate the change to a worker";
  return `${detail} targeting a project clone or worker copy is blocked; ${alternative}.`;
}
const READ_ONLY_GIT = new Set([
  "status", "log", "diff", "show", "rev-parse", "ls-files", "ls-tree",
  "grep", "cat-file", "blame", "shortlog", "describe", "check-attr",
  "check-ignore", "check-mailmap", "count-objects", "diff-tree", "for-each-ref",
  "name-rev", "merge-base", "version", "help",
]);
const FILE_WRITE_TOOLS = new Set([
  "write", "edit", "multiedit", "notebookedit", "apply_patch", "patch",
  "create_file", "write_file", "edit_file", "file_write", "file_edit",
  "replace_file", "str_replace_editor",
]);

function normalizeAbsolute(value, base) {
  if (typeof value !== "string" || !value || value.includes("\0")) return "";
  let candidate = value;
  if (candidate === "~" || candidate.startsWith("~/")) {
    candidate = path.join(process.env.HOME || "", candidate.slice(2));
  }
  return path.resolve(base, candidate);
}

function realpathLoose(candidate) {
  let current = candidate;
  const suffix = [];
  while (!existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) return candidate;
    suffix.unshift(path.basename(current));
    current = parent;
  }
  try {
    return path.resolve(realpathSync(current), ...suffix);
  } catch {
    return candidate;
  }
}

function isWithin(candidate, root) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

function readWorktrees(state) {
  const result = [];
  let entries = [];
  try {
    entries = readdirSync(state).filter((entry) => entry.endsWith(".meta"));
  } catch {
    return result;
  }
  for (const entry of entries) {
    let content;
    try {
      content = readFileSync(path.join(state, entry), "utf8");
    } catch {
      continue;
    }
    for (const line of content.split(/\r?\n/)) {
      if (!line.startsWith("worktree=")) continue;
      const worktree = line.slice("worktree=".length).trim();
      if (path.isAbsolute(worktree)) result.push(path.resolve(worktree));
    }
  }
  return result;
}

function createPathScope(context) {
  const roots = [
    normalizeAbsolute(path.join(context.home, "projects"), context.home),
    normalizeAbsolute(path.join(context.root, "projects"), context.root),
    ...readWorktrees(context.state),
  ];
  const expanded = new Set();
  for (const root of roots) {
    if (!root) continue;
    expanded.add(path.resolve(root));
    expanded.add(realpathLoose(path.resolve(root)));
  }
  return [...expanded];
}

function protectedPath(value, cwd, roots) {
  const candidate = normalizeAbsolute(value, cwd);
  if (!candidate) return false;
  const paths = [candidate, realpathLoose(candidate)];
  return roots.some((root) => paths.some((pathValue) => isWithin(pathValue, root)));
}

function pathFromWord(word, cwd, roots) {
  return word && word.type === "word" && protectedPath(word.value, cwd, roots);
}

function expandStaticWord(word, variables) {
  if (!word || word.type !== "word" || word.literal) return word;
  let resolved = word.subs.length === 0;
  const value = word.value.replace(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g, (match, braced, plain) => {
    const name = braced || plain;
    if (!variables.has(name)) {
      resolved = false;
      return match;
    }
    return variables.get(name);
  });
  if (value.includes("$") && !/\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/.test(value)) resolved = false;
  return { ...word, value, resolved };
}

function applyAssignments(words, start, end, variables) {
  for (const word of words.slice(start, end)) {
    const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
    if (!match) continue;
    if (word.literal || word.resolved !== false) variables.set(match[1], match[2]);
    else variables.delete(match[1]);
  }
}

function optionsAndOperands(words, start, takesValue = new Set()) {
  const operands = [];
  let options = true;
  for (let index = start; index < words.length; index += 1) {
    const value = words[index].value;
    if (options && value === "--") {
      options = false;
      continue;
    }
    if (options && value.startsWith("-") && value !== "-") {
      if (takesValue.has(value) && words[index + 1]) index += 1;
      continue;
    }
    operands.push(words[index]);
  }
  return operands;
}

function gitInvocation(position, cwd, roots) {
  const args = position.words.slice(position.index + 1);
  const environment = new Map(Object.entries(process.env));
  applyAssignments(position.words, 0, position.index, environment);
  const routedPaths = [];
  for (const name of ["GIT_DIR", "GIT_WORK_TREE"]) {
    const value = environment.get(name);
    if (value) routedPaths.push(normalizeAbsolute(value, cwd));
  }
  let target = cwd;
  let subcommandIndex = 0;
  for (; subcommandIndex < args.length; subcommandIndex += 1) {
    const value = args[subcommandIndex].value;
    if (value === "-C" || value === "--git-dir" || value === "--work-tree") {
      const operand = args[subcommandIndex + 1];
      if (!operand) break;
      const resolved = normalizeAbsolute(operand.value, target);
      if (value === "-C") {
        target = resolved;
      } else {
        routedPaths.push(resolved);
      }
      subcommandIndex += 1;
      continue;
    }
    if (value.startsWith("-C") && value.length > 2) {
      target = normalizeAbsolute(value.slice(2), target);
      continue;
    }
    if (value.startsWith("--git-dir=") || value.startsWith("--work-tree=")) {
      const operand = value.slice(value.indexOf("=") + 1);
      routedPaths.push(normalizeAbsolute(operand, target));
      continue;
    }
    if (value === "-c" || value === "--config-env") {
      subcommandIndex += 1;
      continue;
    }
    if (value.startsWith("-") && value !== "-") continue;
    break;
  }
  const subcommand = args[subcommandIndex]?.value || "";
  return {
    targeted: routedPaths.some((value) => protectedPath(value, cwd, roots)) || protectedPath(target, cwd, roots),
    subcommand,
    args: args.slice(subcommandIndex + 1),
  };
}


function gitIsReadOnly(subcommand, args) {
  if (READ_ONLY_GIT.has(subcommand)) return true;
  if (subcommand === "worktree") return args.length > 0 && args[0].value === "list";
  if (subcommand === "branch") {
    return args.every((word) => /^-/.test(word.value)) &&
      !args.some((word) => /^(?:-d|-D|--delete|-m|-M|--move|-c|-C|--copy|-f|--force|--set-upstream-to)$/.test(word.value));
  }
  if (subcommand === "tag") {
    return args.some((word) => ["-l", "--list", "--contains", "--points-at", "--merged", "--no-merged"].includes(word.value));
  }
  if (subcommand === "stash") return args.length > 0 && ["list", "show"].includes(args[0].value);
  if (subcommand === "remote") return args.length === 0 || args[0]?.value === "-v" || args[0]?.value === "--verbose" || args[0]?.value === "show";
  if (subcommand === "config") {
    return args.some((word) => ["--get", "--get-all", "--get-regexp", "--list", "--show-origin", "--show-scope", "--name-only"].includes(word.value));
  }
  if (subcommand === "reflog") return args.length === 0 || args[0]?.value === "show";
  return false;
}

function gitTargetedMutation(position, cwd, roots) {
  if (path.basename(position.command?.value || "") !== "git") return "";
  const target = gitInvocation(position, cwd, roots);
  if (!target.subcommand) return "";
  const cloneOptions = new Set([
    "-b", "--branch", "-o", "--origin", "-c", "--config", "--depth", "--filter",
    "--jobs", "--reference", "--reference-if-able", "--separate-git-dir", "--shallow-since",
    "--shallow-exclude", "--server-option", "--template", "--upload-pack", "-j",
  ]);
  if (["clone", "init"].includes(target.subcommand)) {
    for (let index = 0; index < target.args.length; index += 1) {
      const value = target.args[index].value;
      if (value === "--separate-git-dir" && target.args[index + 1] && pathFromWord(target.args[index + 1], cwd, roots)) {
        return `git ${target.subcommand}`;
      }
      if (value.startsWith("--separate-git-dir=") && pathFromWord({ type: "word", value: value.slice("--separate-git-dir=".length) }, cwd, roots)) {
        return `git ${target.subcommand}`;
      }
    }
  }
  if (target.subcommand === "clone") {
    const operands = optionsAndOperands(target.args, 0, cloneOptions);
    if (operands.length > 1 && pathFromWord(operands.at(-1), cwd, roots)) return "git clone";
  }
  if (target.subcommand === "init") {
    const initOptions = new Set(["--template", "--initial-branch", "--object-format", "--ref-format", "--separate-git-dir"]);
    const operands = optionsAndOperands(target.args, 0, initOptions);
    if (operands.length > 0 && pathFromWord(operands.at(-1), cwd, roots)) return "git init";
  }
  if (target.subcommand === "worktree") {
    const worktreeCommand = target.args[0]?.value || "";
    const worktreeOptions = new Set(["-b", "-B", "--reason"]);
    const operands = optionsAndOperands(target.args, 1, worktreeOptions);
    if (["add", "move", "remove"].includes(worktreeCommand) && operands.some((word) => pathFromWord(word, cwd, roots))) {
      return `git worktree ${worktreeCommand}`;
    }
  }
  if (target.subcommand === "submodule" && target.args[0]?.value === "add") {
    const operands = optionsAndOperands(target.args, 1, new Set(["-b", "--branch", "--name", "--depth"]));
    if (operands.length > 1 && pathFromWord(operands.at(-1), cwd, roots)) return "git submodule add";
  }
  for (let index = 0; index < target.args.length; index += 1) {
    const value = target.args[index].value;
    const output = value === "--output" ? target.args[index + 1] : value.startsWith("--output=") ? { type: "word", value: value.slice("--output=".length) } : null;
    if (output && (target.targeted || pathFromWord(output, cwd, roots))) return `git ${target.subcommand} output`;
  }
  if (target.subcommand === "archive") {
    for (let index = 0; index < target.args.length; index += 1) {
      const value = target.args[index].value;
      const output = value === "-o" ? target.args[index + 1]
        : value.startsWith("-o") && value.length > 2 ? { type: "word", value: value.slice(2).replace(/^=/, "") }
          : null;
      if (output && pathFromWord(output, cwd, roots)) return "git archive output";
    }
  }
  if (target.subcommand === "checkout-index") {
    for (let index = 0; index < target.args.length; index += 1) {
      const value = target.args[index].value;
      const prefix = value === "--prefix" ? target.args[index + 1]
        : value.startsWith("--prefix=") ? { type: "word", value: value.slice("--prefix=".length) }
          : null;
      if (prefix && pathFromWord(prefix, cwd, roots)) return "git checkout-index output";
    }
  }
  if (target.subcommand === "bundle" && target.args[0]?.value === "create") {
    const operands = optionsAndOperands(target.args, 1);
    if (operands.length > 0 && pathFromWord(operands[0], cwd, roots)) return "git bundle create";
  }
  if (!target.targeted || gitIsReadOnly(target.subcommand, target.args)) return "";
  return `git ${target.subcommand}`;
}

function redirectedTargets(tokens, cwd, roots) {
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token.type !== "redir" || ![">", ">>", "<>", "&>", "&>>", ">|"].includes(token.value)) continue;
    const target = token.inlineTarget ? null : tokens[index + 1];
    if (pathFromWord(target, cwd, roots)) return [">>", "&>>"].includes(token.value) ? "append redirection" : "file redirection";
  }
  return "";
}

function sedTargets(position, cwd, roots) {
  const words = position.words;
  let index = position.index + 1;
  let inPlace = false;
  let hasScript = false;
  while (index < words.length && words[index].value.startsWith("-")) {
    const option = words[index].value;
    if (option === "--") {
      index += 1;
      break;
    }
    if (/^-[A-Za-z]*i/.test(option) || option.startsWith("--in-place")) inPlace = true;
    if (["-e", "-f"].includes(option)) {
      hasScript = true;
      index += 1;
    }
    index += 1;
  }
  if (!inPlace) return "";
  if (!hasScript && index < words.length) index += 1; // positional sed program
  return words.slice(index).some((word) => pathFromWord(word, cwd, roots)) ? "sed -i" : "";
}

function findExecMutation(args, cwd, roots) {
  const mutators = new Set(["rm", "mv", "cp", "tee", "mkdir", "rmdir", "touch", "truncate", "chmod", "chown", "ln", "install", "patch", "dd"]);
  let searchRootProtected = false;
  let hasSearchRoot = false;
  for (const word of args) {
    if (word.value.startsWith("-") || ["!", "("].includes(word.value)) break;
    hasSearchRoot = true;
    searchRootProtected ||= pathFromWord(word, cwd, roots);
  }
  if (!hasSearchRoot) searchRootProtected = protectedPath(".", cwd, roots);
  if (args.some((word) => word.value === "-delete") && searchRootProtected) return "find -delete";

  for (let index = 0; index < args.length; index += 1) {
    if (!["-exec", "-execdir"].includes(args[index].value)) continue;
    const action = [];
    for (let cursor = index + 1; cursor < args.length && !["+", ";"].includes(args[cursor].value); cursor += 1) action.push(args[cursor]);
    const actionPosition = commandPosition(action);
    const actionName = path.basename(actionPosition.command?.value || "");
    const targetedArgument = action.some((word) => pathFromWord(word, cwd, roots) ||
      (word.value.startsWith("of=") && protectedPath(word.value.slice(3), cwd, roots)));
    const shellWrite = ["sh", "bash", "zsh"].includes(actionName) && action.some((word) =>
      /(?:^|\s)(?:>|>>|<>|\b(?:rm|mv|cp|tee|touch|truncate|patch|dd)\b)/.test(word.value));
    if ((searchRootProtected && mutators.has(actionName)) || targetedArgument && mutators.has(actionName) || shellWrite) {
      return `find ${args[index].value}`;
    }
  }
  return "";
}

function patchStripCount(args) {
  let count = 0;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index].value;
    if (value === "-p") {
      const next = args[index + 1]?.value;
      if (!/^\d+$/.test(next || "")) return null;
      count = Number(next);
      index += 1;
    } else if (/^-p\d+$/.test(value)) {
      count = Number(value.slice(2));
    }
  }
  return count;
}

function patchHeaderPaths(content) {
  const paths = [];
  const add = (value) => {
    const candidate = value.trim().split(/[\t ]/)[0];
    if (!candidate) return false;
    if (candidate.startsWith('"')) return false;
    if (candidate !== "/dev/null") paths.push(candidate);
    return true;
  };
  for (const line of content.split(/\r?\n/)) {
    if (line.startsWith("diff --git ")) {
      const match = line.slice("diff --git ".length).match(/^(\S+)\s+(\S+)$/);
      if (!match || !add(match[1]) || !add(match[2])) return null;
      continue;
    }
    const header = line.match(/^(?:---|\+\+\+|\*{3}|Index:)\s+(.+)$/);
    if (header && !add(header[1])) return null;
  }
  return paths.length > 0 ? paths : null;
}

function readPatchInputs(args, tokens, cwd) {
  const sources = [];
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index].value;
    if (["-i", "--input"].includes(value)) {
      if (!args[index + 1]) return null;
      sources.push({ file: args[index + 1].value });
      index += 1;
    } else if (value.startsWith("--input=")) {
      sources.push({ file: value.slice("--input=".length) });
    } else if (value.startsWith("-i") && value.length > 2) {
      sources.push({ file: value.slice(2) });
    }
  }
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token.type !== "redir") continue;
    if (["<<", "<<-"].includes(token.value)) {
      sources.push({ content: token.heredoc });
    } else if (token.value === "<<<") {
      const word = tokens[index + 1];
      sources.push(word?.literal ? { content: word.value } : {});
    } else if (token.value === "<") {
      const word = token.inlineTarget ? null : tokens[index + 1];
      sources.push(word?.type === "word" ? { file: word.value } : {});
    }
  }
  if (sources.length === 0) return [];
  const contents = [];
  for (const source of sources) {
    if (typeof source.content === "string") {
      contents.push(source.content);
      continue;
    }
    if (typeof source.file !== "string" || !source.file || source.file === "-") return null;
    const file = normalizeAbsolute(source.file, cwd);
    try {
      if (!statSync(file).isFile()) return null;
      contents.push(readFileSync(file, "utf8"));
    } catch {
      return null;
    }
  }
  return contents;
}

function patchTargetsProtectedPath(args, tokens, cwd, roots, hasExplicitTarget) {
  const stripCount = patchStripCount(args);
  if (stripCount === null) return true;
  const inputs = readPatchInputs(args, tokens, cwd);
  if (inputs === null) return true;
  if (inputs.length === 0) return !hasExplicitTarget;
  for (const input of inputs) {
    const paths = patchHeaderPaths(input);
    if (!paths) return true;
    for (const value of paths) {
      const components = value.split("/").slice(stripCount);
      if (components.length > 0 && protectedPath(components.join("/"), cwd, roots)) return true;
    }
  }
  return false;
}

function commandTargetedMutation(position, tokens, cwd, roots) {
  const command = path.basename(position.command?.value || "");
  if (!command) return "";
  const words = position.words;
  const start = position.index + 1;
  const args = words.slice(start);

  const gitMutation = gitTargetedMutation(position, cwd, roots);
  if (gitMutation) return gitMutation;

  const redirection = redirectedTargets(tokens, cwd, roots);
  if (redirection) return redirection;

  if (command === "sed") return sedTargets(position, cwd, roots);
  if (command === "perl" && args.some((word) => /^-[^-]*i/.test(word.value))) {
    return args.some((word) => pathFromWord(word, cwd, roots)) ? "perl -i" : "";
  }

  if (command === "find") return findExecMutation(args, cwd, roots);

  if (command === "dd") {
    return args.some((word) => word.value.startsWith("of=") && protectedPath(word.value.slice(3), cwd, roots)) ? "dd" : "";
  }
  if (command === "patch") {
    if (protectedPath(".", cwd, roots)) return "patch";
    const directoryOption = args.find((word) => word.value === "-d" || word.value === "--directory");
    const directoryEquals = args.find((word) => word.value.startsWith("--directory="));
    const directory = directoryEquals
      ? { type: "word", value: directoryEquals.value.slice("--directory=".length) }
      : directoryOption ? args[args.indexOf(directoryOption) + 1] : null;
    if (pathFromWord(directory, cwd, roots)) return "patch";
    if (args.some((word) => word.value.startsWith("-o") && word.value.length > 2 && pathFromWord({ type: "word", value: word.value.slice(2).replace(/^=/, "") }, cwd, roots))) return "patch";
    if (args.some((word, index) => word.value === "-o" && pathFromWord(args[index + 1], cwd, roots))) return "patch";
    const operands = optionsAndOperands(words, start, new Set(["-i", "--input", "-o", "-d", "--directory"]));
    if (operands.some((word) => pathFromWord(word, cwd, roots))) return "patch";
    return patchTargetsProtectedPath(args, tokens, cwd, roots, operands.length > 0) ? "patch" : "";
  }

  const targets = new Set(["rm", "mv", "cp", "tee", "mkdir", "rmdir", "touch", "truncate", "chmod", "chown", "ln", "install"]);
  if (!targets.has(command)) return "";
  const pathOperands = optionsAndOperands(words, start, new Set(["-t", "--target-directory", "--reference", "-m", "--mode", "-o", "--owner", "-g", "--group"]))
    .filter((word) => !["-t", "--target-directory"].includes(word.value));
  if (command === "cp" || command === "mv" || command === "install") {
    const targetOptionIndex = args.findIndex((word) => ["-t", "--target-directory"].includes(word.value));
    if (targetOptionIndex >= 0 && args[targetOptionIndex + 1] && pathFromWord(args[targetOptionIndex + 1], cwd, roots)) return command;
    const targetOption = args.find((word) => word.value.startsWith("--target-directory="));
    if (targetOption && pathFromWord({ type: "word", value: targetOption.value.slice("--target-directory=".length) }, cwd, roots)) return command;
    const shortTarget = args.find((word) => word.value.startsWith("-t") && word.value.length > 2);
    if (shortTarget && pathFromWord({ type: "word", value: shortTarget.value.slice(2) }, cwd, roots)) return command;
  }
  if (command === "mv" || command === "rm" || command === "rmdir") {
    return pathOperands.some((word) => pathFromWord(word, cwd, roots)) ? command : "";
  }
  if (command === "cp" || command === "install") {
    return pathOperands.length > 0 && pathFromWord(pathOperands.at(-1), cwd, roots) ? command : "";
  }
  if (command === "tee") return pathOperands.some((word) => pathFromWord(word, cwd, roots)) ? command : "";
  return pathOperands.some((word) => pathFromWord(word, cwd, roots)) ? command : "";
}

function analyzeProgram(source, context, cwd, roots, depth = 0, inheritedVariables = new Map(Object.entries(process.env))) {
  if (depth > 12) return { denied: "" };
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return { denied: "" };
  const { nodes } = splitProgram(lexed.tokens);
  const variables = new Map(inheritedVariables);
  for (let index = 0; index < nodes.length; index += 1) {
    const tokens = nodes[index].map((token) => token.type === "word" ? expandStaticWord(token, variables) : token);
    const position = commandPosition(tokens);
    const mutating = commandTargetedMutation(position, tokens, cwd, roots);
    if (mutating) return { denied: mutating };
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = analyzeProgram(token.content, context, cwd, roots, depth + 1, variables);
        if (nested.denied) return nested;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = analyzeProgram(substitution.content, context, cwd, roots, depth + 1, variables);
          if (nested.denied) return nested;
        }
      }
    }
    if (position.command && ["cd", "pushd"].includes(path.basename(position.command.value))) {
      const args = position.words.slice(position.index + 1).map((word) => word.value);
      const destination = args.find((value) => value !== "--" && !["-L", "-P"].includes(value) && !value.startsWith("-"));
      if (destination) cwd = normalizeAbsolute(destination, cwd);
    }
    if (position.command && ["sh", "bash", "zsh"].includes(path.basename(position.command.value))) {
      const args = position.words.slice(position.index + 1);
      const commandFlag = args.findIndex((word) => /^-[A-Za-z]*c[A-Za-z]*$/.test(word.value));
      const payload = commandFlag >= 0 ? args[commandFlag + 1] : null;
      if (payload?.literal && payload.subs.length === 0) {
        const nested = analyzeProgram(payload.value, context, cwd, roots, depth + 1, variables);
        if (nested.denied) return nested;
      }
    }
    if (!position.command) applyAssignments(position.words, 0, position.words.length, variables);
    else if (["export", "declare", "typeset", "readonly", "local"].includes(path.basename(position.command.value))) {
      applyAssignments(position.words, position.index + 1, position.words.length, variables);
    }
  }
  return { denied: "" };
}

function toolTargets(payload, roots, cwd) {
  const toolName = String(payload?.tool_name ?? payload?.toolName ?? payload?.tool ?? "").toLowerCase();
  const input = payload?.tool_input ?? payload?.toolInput ?? payload?.input ?? {};
  if (toolName === "bash" || toolName === "shell" || toolName === "run_terminal_command") {
    const command = input?.command ?? input?.cmd;
    return typeof command === "string" ? analyzeProgram(command, {}, cwd, roots) : { denied: "" };
  }
  const simpleName = toolName.split(/[.:/]/).at(-1);
  if (!FILE_WRITE_TOOLS.has(simpleName)) return { denied: "" };
  const paths = [];
  const collect = (value, key = "") => {
    if (typeof value === "string") {
      if (/(?:path|file|filename|destination|target|source)$/i.test(key) || ["path", "file_path", "filePath", "target_file", "targetFile", "filename", "destination"].includes(key)) paths.push(value);
      if (["patch", "diff"].includes(key)) {
        for (const match of value.matchAll(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/gm)) paths.push(match[1]);
      }
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) collect(item, key);
      return;
    }
    if (value && typeof value === "object") {
      for (const [childKey, child] of Object.entries(value)) collect(child, childKey);
    }
  };
  collect(input);
  if (paths.some((value) => protectedPath(value, cwd, roots))) return { denied: `file tool ${toolName}` };
  return { denied: "" };
}

function evaluate(payload, context) {
  const roots = createPathScope(context);
  const cwd = context.cwd;
  const result = toolTargets(payload, roots, cwd);
  return result.denied
    ? { decision: "deny", code: "project-write", reason: denialReason(result.denied) }
    : result;
}

function parseArgs(argv) {
  const result = { root: process.cwd(), home: process.cwd(), state: path.join(process.cwd(), "state"), cwd: process.cwd(), command: null, payloadStdin: false };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (["--root", "--home", "--state", "--cwd", "--command"].includes(key)) {
      if (index + 1 >= argv.length) throw new Error(`${key} requires a value`);
      result[key.slice(2)] = argv[index + 1];
      index += 1;
    } else if (key === "--payload-stdin") {
      result.payloadStdin = true;
    } else {
      throw new Error(`unknown argument: ${key}`);
    }
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArgs(process.argv.slice(2));
    let payload;
    if (args.payloadStdin) {
      let source = "";
      for await (const chunk of process.stdin) source += chunk;
      payload = JSON.parse(source);
    } else {
      payload = { tool_name: "bash", tool_input: { command: args.command || "" } };
    }
    const context = {
      root: path.resolve(args.root),
      home: path.resolve(args.home),
      state: path.resolve(args.state),
      cwd: path.resolve(args.cwd),
    };
    const result = evaluate(payload, context);
    if (result.decision === "deny") process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    else process.stdout.write("allow\n");
  } catch {
    process.stdout.write("allow\n");
  }
}

export { evaluate };
