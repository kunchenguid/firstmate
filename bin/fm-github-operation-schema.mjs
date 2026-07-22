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

function classifyArgv(command, args) {
  const classifications = [];
  const seen = new Set();
  for (const arg of args) {
    const option = arg.startsWith("--") && arg.includes("=") ? arg.slice(0, arg.indexOf("=")) : arg;
    if (!Object.hasOwn(schema.publicOptions, option)) continue;
    const kind = optionKind(command, option);
    if (seen.has(option)) continue;
    seen.add(option);
    classifications.push(`${option}\t${kind}`);
  }
  return classifications;
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
    || !schema.childCommands || !schema.issueTypes || !schema.ignoredOuterFlags
    || Array.isArray(schema.ignoredOuterFlags) || !Array.isArray(schema.stdinOperations)) return false;
  const optionKinds = new Set(["data", "destination_repo", "flag", "head", "host", "issue", "owner", "reject", "repo", "unknown"]);
  for (const selections of Object.values(schema.publicOptions)) {
    if (!selections || typeof selections !== "object"
      || Object.values(selections).some((kind) => !optionKinds.has(kind))) return false;
  }
  const issueTypeOptions = new Map();
  const addIssueTypeOption = (option, command, kind) => {
    if (!option) return;
    const commands = issueTypeOptions.get(option) || new Map();
    commands.set(command, kind);
    issueTypeOptions.set(option, commands);
  };
  for (const [command, contract] of Object.entries(schema.issueTypes)) {
    addIssueTypeOption(contract.set, command, "data");
    addIssueTypeOption(contract.clear, command, "flag");
    for (const option of contract.forbidden || []) addIssueTypeOption(option, command, "reject");
  }
  for (const [option, commands] of issueTypeOptions) {
    const selections = schema.publicOptions[option];
    if (!selections || selections.default !== "unknown") return false;
    const scoped = Object.entries(selections).filter(([command]) => command !== "default");
    if (scoped.length !== commands.size
      || scoped.some(([command, kind]) => commands.get(command) !== kind)) return false;
  }
  for (const [command, options] of Object.entries(schema.ignoredOuterFlags)) {
    if (!command.includes(":") || !Array.isArray(options) || new Set(options).size !== options.length
      || options.some((option) => !schema.publicOptions[option]
        || ["unknown", "reject"].includes(optionKind(command, option)))) return false;
    if (options.some((option) => issueTypeOptions.has(option))) return false;
  }
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
    if ((contract.forbidden || []).some((option) => optionKind(command, option) !== "reject")) return false;
    if (contract.clear && (optionKind(command, contract.clear) !== "flag"
      || contract.clearOptions?.[contract.clear] !== "flag" || contract.clearPositionals !== 1
      || Object.values(contract.clearOptions).some((kind) => !["flag", "value"].includes(kind)))) return false;
    const observedFields = schema.childCommands[command]
      ?.filter(({argv}) => argv[0] === "issue" && argv[1] === "view")
      .map(({argv}) => argv[argv.indexOf("--json") + 1])
      .filter(Boolean) || [];
    if (!observedFields.includes(contract.observe.join(","))) return false;
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
} else if (action === "classify-argv") {
  const classifications = classifyArgv(process.argv[3] || "", process.argv.slice(4));
  if (classifications.length > 0) process.stdout.write(`${classifications.join("\n")}\n`);
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
