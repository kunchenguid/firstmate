#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const schemaPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "fm-github-operation-schema.json");
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

function selection(table, command) {
  return table?.[command] ?? table?.[`${command.split(":")[0]}:*`] ?? table?.default;
}

function optionKind(command, option) {
  return selection(schema.publicOptions[option], command) ?? "unknown";
}

function clearTypeValid(args) {
  const command = `${args[0] || ""}:${args[1] || ""}`;
  const contract = schema.issueTypes[command];
  if (contract?.clear && args.some((arg) => arg.startsWith(`${contract.clear}=`))) return false;
  if (!contract?.clear || !args.includes(contract.clear)) return true;
  let positionals = 0;
  let clears = 0;
  for (let index = 2; index < args.length; index += 1) {
    const arg = args[index];
    const optionKind = contract.clearOptions[arg];
    if (arg === contract.clear) clears += 1;
    else if (optionKind === "value") {
      const value = args[index + 1];
      if (!value || value.startsWith("-")) return false;
      index += 1;
    } else {
      const inline = Object.entries(contract.clearOptions).find(([option, kind]) => kind === "value"
        && (option.startsWith("--") ? arg.startsWith(`${option}=`) : arg.startsWith(option) && arg.length > option.length));
      if (inline) {
        const separator = inline[0].startsWith("--") ? inline[0].length + 1 : inline[0].length;
        if (!arg.slice(separator)) return false;
      } else if (arg.startsWith("-")) return false;
      else positionals += 1;
    }
  }
  return clears === 1 && positionals === contract.clearPositionals;
}

function validate() {
  if (schema.version !== 1 || !schema.publicOptions || !schema.aliases || !schema.generatedFlags
    || !schema.childCommands || !schema.issueTypes || !Array.isArray(schema.stdinOperations)) return false;
  for (const [alias, selections] of Object.entries(schema.aliases)) {
    if (!schema.publicOptions[alias]) return false;
    for (const [command, target] of Object.entries(selections)) {
      if (typeof target !== "string" || target.length === 0
        || optionKind(command, alias) === "unknown") return false;
    }
  }
  const transformKeys = new Set();
  for (const transform of [...schema.payloadTransforms, ...schema.flagTransforms]) {
    const key = `${transform.command || (transform.commands || []).join(",")}:${transform.outer}`;
    if (!transform.outer || transformKeys.has(key)) return false;
    transformKeys.add(key);
  }
  for (const [command, contract] of Object.entries(schema.issueTypes)) {
    if (!Array.isArray(contract.observe) || contract.observe.length === 0 || !command.includes(":")) return false;
    if (contract.set && optionKind(command, contract.set) !== "data") return false;
    if (contract.clear && (optionKind(command, contract.clear) !== "flag"
      || contract.clearOptions?.[contract.clear] !== "flag" || contract.clearPositionals !== 1
      || Object.values(contract.clearOptions).some((kind) => !["flag", "value"].includes(kind)))) return false;
  }
  for (const contracts of Object.values(schema.childCommands)) {
    if (!Array.isArray(contracts) || contracts.length === 0
      || contracts.some((contract) => !["source", "destination"].includes(contract.repository)
        || !Array.isArray(contract.argv) || contract.argv.some((arg) => typeof arg !== "string" || arg.length === 0))) return false;
  }
  return true;
}

function hasIssueTypeVariant(args) {
  const contract = schema.issueTypes[`${args[0] || ""}:${args[1] || ""}`];
  const flags = [contract?.set, contract?.clear, ...(contract?.forbidden || [])].filter(Boolean);
  return args.some((arg) => flags.some((flag) => arg === flag || arg.startsWith(`${flag}=`)));
}

const action = process.argv[2] || "";
if (action === "option-kind") {
  process.stdout.write(`${optionKind(process.argv[3] || "", process.argv[4] || "")}\n`);
} else if (action === "validate-clear-type") {
  const args = process.argv.slice(3);
  if (!clearTypeValid(args)) process.exit(1);
} else if (action === "validate") {
  if (!validate()) process.exit(1);
} else if (action === "has-issue-type-variant") {
  if (!hasIssueTypeVariant(process.argv.slice(3))) process.exit(1);
} else {
  process.exit(1);
}
