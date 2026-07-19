#!/usr/bin/env node
// Narrow shell classifier for the Claude watcher-continuity PreToolUse gate.
//
// The shared Lexer, program splitter, and command-position resolver remain owned
// by fm-arm-command-policy.mjs. This policy only identifies executed firstmate
// fleet scripts and divides them into recovery commands (wake drain and watcher
// arm) versus every other bin/fm-*.sh command. Unparseable or opaque dynamic
// commands fail open so this gate can never become a blanket shell block.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";

const RECOVERY_SCRIPTS = new Set(["fm-wake-drain.sh", "fm-watch-arm.sh"]);

function parseArguments(argv) {
  const result = { command: "", root: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name !== "--command" && name !== "--root") throw new Error(`unknown argument: ${name}`);
    if (index + 1 >= argv.length) throw new Error(`${name} requires a value`);
    result[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  return result;
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function fleetScript(value, root) {
  const normalized = path.normalize(value);
  const name = basename(normalized);
  if (!/^fm-[A-Za-z0-9._-]+\.sh$/.test(name)) return "";
  const relative = `bin/${name}`;
  if (normalized === relative || normalized === path.join(root, relative) || normalized.endsWith(`/${relative}`)) return name;
  return "";
}

function literalShellPayload(position) {
  if (!position.command || !["sh", "bash", "zsh"].includes(basename(position.command.value))) return null;
  const words = position.words;
  let noExecute = false;
  for (let index = position.index + 1; index < words.length; index += 1) {
    const word = words[index];
    if (/^-[A-Za-z]*n[A-Za-z]*$/.test(word.value)) noExecute = true;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(word.value)) {
      const payload = words[index + 1];
      if (!payload || !payload.literal || payload.subs.length > 0) return null;
      return { kind: noExecute ? "none" : "command", value: payload.value };
    }
    if (/^[-+]O$/.test(word.value)) {
      index += 1;
      continue;
    }
    if (word.value === "--" || /^[-+]/.test(word.value)) continue;
    return { kind: noExecute ? "none" : "script", value: word.value };
  }
  return { kind: noExecute ? "none" : "stdin", value: "" };
}

function literalEvalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return "";
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return "";
  return payloads.map((payload) => payload.value).join(" ");
}

function collectExecutedFleetScripts(command, root, depth = 0) {
  if (depth > 12) return [];
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return [];
  const scripts = [];
  const program = splitProgram(lexed.tokens);

  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);
    const direct = fleetScript(position.command?.value || "", root);
    if (direct) scripts.push(direct);

    for (const token of tokens) {
      if (token.type === "group") scripts.push(...collectExecutedFleetScripts(token.content, root, depth + 1));
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        scripts.push(...collectExecutedFleetScripts(substitution.content, root, depth + 1));
      }
    }

    const shell = literalShellPayload(position);
    if (shell?.kind === "command") scripts.push(...collectExecutedFleetScripts(shell.value, root, depth + 1));
    if (shell?.kind === "script") {
      const script = fleetScript(shell.value, root);
      if (script) scripts.push(script);
    }
    if (shell?.kind === "stdin") {
      for (const token of tokens) {
        if (token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string") {
          scripts.push(...collectExecutedFleetScripts(token.heredoc, root, depth + 1));
        }
      }
    }

    const sourced = position.command && [".", "source"].includes(position.command.value)
      ? fleetScript(position.words[position.index + 1]?.value || "", root)
      : "";
    if (sourced) scripts.push(sourced);
    const evaluated = literalEvalPayload(position);
    if (evaluated) scripts.push(...collectExecutedFleetScripts(evaluated, root, depth + 1));
  }

  return scripts;
}

export function classifyContinuityCommand(command, root) {
  const scripts = collectExecutedFleetScripts(command, root);
  const blocked = scripts.find((script) => !RECOVERY_SCRIPTS.has(script));
  return blocked ? { decision: "deny", script: blocked } : { decision: "allow", script: "" };
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  if (!args.command || !args.root) return;
  const result = classifyContinuityCommand(args.command, args.root);
  if (result.decision === "deny") process.stdout.write(`deny\t${result.script}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch {
    process.exitCode = 0;
  }
}
