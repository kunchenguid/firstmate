#!/usr/bin/env node
// Semantic external-tool policy for Firstmate protected task commands and native tools.
//
// The machine-readable policy lives only in the task brief. This classifier
// reads that brief on every decision and reuses fm-arm-command-policy.mjs for
// shell tokenization and nested execution traversal. It never executes,
// expands, sources, or imports submitted command bytes.

import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { walkShellCommandTree } from "./fm-arm-command-policy.mjs";

const POLICY_SCHEMA = "firstmate.external-tools.v1";
const POLICY_FENCE = "firstmate-external-tools";

const BROWSER_SHELL_TOOLS = new Set([
  "agent-browser",
  "browser-use",
  "chrome-devtools-axi",
  "chromedriver",
  "chromium",
  "cypress",
  "firefox",
  "geckodriver",
  "google-chrome",
  "nightwatch",
  "playwright",
  "puppeteer",
  "selenium",
  "testcafe",
  "webdriverio",
  "webdriver-manager",
]);
const GITHUB_SHELL_TOOLS = new Set(["gh", "gh-axi"]);
const PACKAGE_RUNNERS = new Set(["bunx", "npx", "pnpx", "uvx"]);
const PACKAGE_MANAGERS = new Set(["bun", "npm", "pnpm", "yarn", "yarnpkg"]);
const PYTHON_COMMANDS = new Set(["python", "python3", "python3.11", "python3.12", "python3.13"]);
const PIP_COMMANDS = new Set(["pip", "pip3", "pip3.11", "pip3.12", "pip3.13"]);
const SYSTEM_PACKAGE_MANAGERS = new Set(["apt", "apt-get", "brew", "dnf", "flatpak", "pacman", "snap", "yum"]);

function parseArguments(argv) {
  const result = { brief: "", tool: "", inputJson: "{}", command: "", validate: false };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === "--validate") {
      result.validate = true;
      continue;
    }
    if (["--brief", "--tool", "--input-json", "--command"].includes(name)) {
      if (index + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2).replace("-json", "Json")] = argv[index + 1];
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  if (!result.brief) throw new Error("--brief is required");
  return result;
}

function exactObjectKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.join("\0") !== wanted.join("\0")) throw new Error(`${label} keys must be exactly: ${wanted.join(", ")}`);
}

function validateToolAllowList(value, label) {
  exactObjectKeys(value, ["allow"], label);
  if (!Array.isArray(value.allow)) throw new Error(`${label}.allow must be an array`);
  const seen = new Set();
  for (const item of value.allow) {
    if (typeof item !== "string" || !/^[A-Za-z0-9@._/+:-]+$/.test(item)) {
      throw new Error(`${label}.allow entries must be non-empty literal tool names`);
    }
    if (seen.has(item)) throw new Error(`${label}.allow contains duplicate tool '${item}'`);
    seen.add(item);
  }
  return seen;
}

/** Reads and validates the only external-tool authorization source: the fenced JSON in one ship brief. */
export function readExternalToolPolicy(briefPath) {
  const source = readFileSync(briefPath, "utf8");
  const fenceStart = `\`\`\`${POLICY_FENCE}`;
  const start = source.indexOf(fenceStart);
  if (start < 0) throw new Error(`brief lacks the ${POLICY_FENCE} policy fence`);
  if (source.indexOf(fenceStart, start + fenceStart.length) >= 0) throw new Error(`brief contains more than one ${POLICY_FENCE} policy fence`);
  const jsonStart = source.indexOf("\n", start + fenceStart.length);
  if (jsonStart < 0) throw new Error(`${POLICY_FENCE} policy fence has no JSON body`);
  const end = source.indexOf("\n```", jsonStart + 1);
  if (end < 0) throw new Error(`${POLICY_FENCE} policy fence is not closed`);
  let parsed;
  try {
    parsed = JSON.parse(source.slice(jsonStart + 1, end));
  } catch (error) {
    throw new Error(`${POLICY_FENCE} policy is invalid JSON: ${error.message}`);
  }
  exactObjectKeys(parsed, ["native", "schema", "shell"], "external-tool policy");
  if (parsed.schema !== POLICY_SCHEMA) throw new Error(`external-tool policy schema must be '${POLICY_SCHEMA}'`);
  return {
    schema: parsed.schema,
    briefPath,
    shellAllow: validateToolAllowList(parsed.shell, "external-tool policy shell"),
    nativeAllow: validateToolAllowList(parsed.native, "external-tool policy native"),
  };
}

function executableBasename(value) {
  return String(value || "").split("/").filter(Boolean).at(-1)?.toLowerCase() || "";
}

function stripPackageVersion(value) {
  let item = String(value || "").toLowerCase().replace(/^npm:/, "");
  item = item.split("#", 1)[0].split("?", 1)[0];
  if (item.startsWith("@")) {
    const versionAt = item.indexOf("@", item.indexOf("/") + 1);
    if (versionAt > 0) item = item.slice(0, versionAt);
  } else {
    item = item.split("@", 1)[0];
  }
  return item.replace(/(?:==|~=|>=|<=|>|<).*/, "").replace(/\[[^\]]*\]$/, "");
}

function browserToolFromValue(value) {
  const item = stripPackageVersion(value).replace(/\\/g, "/");
  const base = executableBasename(item);
  if (base === "agent-browser" || base === "agent_browser") return "agent-browser";
  if (/(^|[/._-])playwright(?:$|[/._-])/.test(item) || item === "@playwright/test") return "playwright";
  if (/(^|[/._-])puppeteer(?:$|[/._-])/.test(item) || item === "@puppeteer/browsers") return "puppeteer";
  if (/(^|[/._-])selenium(?:$|[/._-])/.test(item) || base === "selenium-side-runner") return "selenium";
  if (/(^|[/._-])webdriverio(?:$|[/._-])/.test(item) || base === "wdio") return "webdriverio";
  if (/(^|[/._-])cypress(?:$|[/._-])/.test(item)) return "cypress";
  if (/(^|[/._-])testcafe(?:$|[/._-])/.test(item)) return "testcafe";
  if (/(^|[/._-])nightwatch(?:$|[/._-])/.test(item)) return "nightwatch";
  if (/(^|[/._-])browser-use(?:$|[/._-])/.test(item)) return "browser-use";
  if (/(^|[/._-])webdriver-manager(?:$|[/._-])/.test(item)) return "webdriver-manager";
  if (/(^|[/._-])chromedriver(?:$|[/._-])/.test(item)) return "chromedriver";
  if (/(^|[/._-])geckodriver(?:$|[/._-])/.test(item)) return "geckodriver";
  if (/(^|[/._-])chrome-for-testing(?:$|[/._-])/.test(item)) return "google-chrome";
  if (["chromium", "chromium-browser"].includes(base)) return "chromium";
  if (["google-chrome", "google-chrome-stable", "chrome"].includes(base)) return "google-chrome";
  if (["firefox", "firefox-esr"].includes(base)) return "firefox";
  return "";
}

function browserToolFromText(value) {
  const direct = browserToolFromValue(value);
  if (direct) return direct;
  const candidates = String(value || "").split(/[^A-Za-z0-9@._/+:-]+/).filter(Boolean);
  for (const candidate of candidates) {
    const tool = browserToolFromValue(candidate);
    if (tool) return tool;
  }
  return "";
}

function request(tool, category, channel = "shell") {
  return { tool, category, channel };
}

function firstNonOption(values, start = 0) {
  for (let index = start; index < values.length; index += 1) {
    if (values[index] === "--") return index + 1 < values.length ? index + 1 : -1;
    if (!values[index].startsWith("-") || values[index] === "-") return index;
  }
  return -1;
}

function browserRequestsFromValues(values) {
  const requests = [];
  for (const value of values) {
    if (value.startsWith("-")) continue;
    const tool = browserToolFromValue(value);
    if (tool) requests.push(request(tool, "browser"));
  }
  return requests;
}

function packageRunnerRequests(name, args) {
  const requests = [];
  let commandIndex = -1;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value === "--") {
      commandIndex = index + 1;
      break;
    }
    if (value === "-p" || value === "--package") {
      if (args[index + 1]) requests.push(...browserRequestsFromValues([args[index + 1]]));
      index += 1;
      continue;
    }
    if (value === "-c" || value === "--call") {
      if (args[index + 1]) requests.push(...classifyExternalShellCommand(args[index + 1]));
      index += 1;
      continue;
    }
    if (value.startsWith("--package=")) {
      requests.push(...browserRequestsFromValues([value.slice("--package=".length)]));
      continue;
    }
    if (value.startsWith("--call=")) {
      requests.push(...classifyExternalShellCommand(value.slice("--call=".length)));
      continue;
    }
    if (!value.startsWith("-")) {
      commandIndex = index;
      break;
    }
  }
  if (commandIndex >= 0 && args[commandIndex]) requests.push(...directExecutableRequests(args[commandIndex], args.slice(commandIndex + 1)));
  if (name === "uvx" && commandIndex < 0) requests.push(...browserRequestsFromValues(args));
  return requests;
}

function packageManagerRequests(name, args) {
  const commandAt = firstNonOption(args);
  if (commandAt < 0) return [];
  const subcommand = args[commandAt].toLowerCase();
  const rest = args.slice(commandAt + 1);
  if (["exec", "x", "dlx"].includes(subcommand)) return packageRunnerRequests(name, rest);
  if (["add", "i", "install"].includes(subcommand)) return browserRequestsFromValues(rest);
  if (["yarn", "yarnpkg"].includes(name)) return directExecutableRequests(subcommand, rest);
  return [];
}

function pythonRequests(args) {
  for (let index = 0; index < args.length - 1; index += 1) {
    if (args[index] !== "-m") continue;
    const tool = browserToolFromValue(args[index + 1]);
    return tool ? [request(tool, "browser")] : [];
  }
  const codeIndex = args.findIndex((value) => value === "-c");
  if (codeIndex >= 0 && args[codeIndex + 1]) {
    const tool = browserToolFromText(args[codeIndex + 1]);
    return tool ? [request(tool, "browser")] : [];
  }
  return [];
}

function nodeRequests(args) {
  const scriptAt = firstNonOption(args);
  if (scriptAt >= 0) {
    const tool = browserToolFromValue(args[scriptAt]);
    if (tool) return [request(tool, "browser")];
  }
  const evalIndex = args.findIndex((value) => value === "-e" || value === "--eval");
  if (evalIndex >= 0 && args[evalIndex + 1]) {
    const tool = browserToolFromText(args[evalIndex + 1]);
    if (tool) return [request(tool, "browser")];
  }
  return [];
}

function systemPackageManagerRequests(name, args) {
  const commandAt = firstNonOption(args);
  if (commandAt < 0) return [];
  const subcommand = args[commandAt].toLowerCase();
  const installCommands = new Set(["add", "install", "reinstall"]);
  if (name === "pacman") {
    if (!args.some((value) => /^-[^-]*S/.test(value))) return [];
    return browserRequestsFromValues(args);
  }
  if (!installCommands.has(subcommand)) return [];
  return browserRequestsFromValues(args.slice(commandAt + 1));
}

function directExecutableRequests(executable, args) {
  const name = executableBasename(executable);
  if (["bash", "sh", "zsh"].includes(name)) {
    const commandAt = args.findIndex((value) => /^-[A-Za-z]*c[A-Za-z]*$/.test(value));
    if (commandAt >= 0 && args[commandAt + 1]) return classifyExternalShellCommand(args[commandAt + 1]);
  }
  if (name === "chrome-devtools-axi") return [request(name, "browser")];
  if (name === "gh" || name === "gh-axi") return [request(name, "github")];
  const directBrowser = browserToolFromValue(executable);
  if (directBrowser) return [request(directBrowser, "browser")];
  if (PACKAGE_RUNNERS.has(name)) return packageRunnerRequests(name, args);
  if (PACKAGE_MANAGERS.has(name)) return packageManagerRequests(name, args);
  if (name === "corepack" && args.length > 0) return directExecutableRequests(args[0], args.slice(1));
  if (PYTHON_COMMANDS.has(name)) return pythonRequests(args);
  if (PIP_COMMANDS.has(name)) {
    const commandAt = firstNonOption(args);
    return commandAt >= 0 && args[commandAt] === "install" ? browserRequestsFromValues(args.slice(commandAt + 1)) : [];
  }
  if (name === "pipx") {
    const commandAt = firstNonOption(args);
    return commandAt >= 0 && ["install", "run"].includes(args[commandAt]) ? browserRequestsFromValues(args.slice(commandAt + 1, commandAt + 2)) : [];
  }
  if (name === "uv" && args[0] === "pip" && args[1] === "install") return browserRequestsFromValues(args.slice(2));
  if (name === "node" || /^nodejs?$/.test(name)) return nodeRequests(args);
  if (SYSTEM_PACKAGE_MANAGERS.has(name)) return systemPackageManagerRequests(name, args);
  return [];
}

function rawMentionsControlledBrowser(value) {
  return Boolean(browserToolFromText(value));
}

/** Classifies controlled external tools in shell execution positions without evaluating the command. */
export function classifyExternalShellCommand(command) {
  const tree = walkShellCommandTree(command);
  const requests = [];
  for (const entry of tree.commands) {
    const position = entry.position;
    if (!position.command) continue;
    const args = position.words.slice(position.index + 1).map((word) => word.value);
    requests.push(...directExecutableRequests(position.command.value, args));
  }
  if ((tree.errors.length > 0 || tree.opaquePayloads.length > 0) && rawMentionsControlledBrowser(command)) {
    requests.push(request("unclassifiable-browser-command", "browser"));
  }
  const seen = new Set();
  return requests.filter((item) => {
    const key = `${item.channel}\0${item.category}\0${item.tool}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function nativeToolRequest(toolName) {
  const normalized = String(toolName || "").toLowerCase().replace(/[.:-]/g, "_");
  if (normalized === "agent_browser" || normalized.endsWith("__agent_browser") || normalized.endsWith("_agent_browser")) {
    return request("agent_browser", "browser", "native");
  }
  return null;
}

function browserAlternatives(policy) {
  const shell = [...policy.shellAllow].filter((item) => BROWSER_SHELL_TOOLS.has(browserToolFromValue(item) || item));
  const native = [...policy.nativeAllow].filter((item) => item === "agent_browser");
  const alternatives = [];
  if (shell.length > 0) alternatives.push(`shell: ${shell.join(", ")}`);
  if (native.length > 0) alternatives.push(`native: ${native.join(", ")}`);
  return alternatives.join("; ") || "none";
}

function githubAlternatives(policy) {
  const shell = [...policy.shellAllow].filter((item) => GITHUB_SHELL_TOOLS.has(item));
  return shell.length > 0 ? `shell: ${shell.join(", ")}` : "none";
}

function requestAllowed(policy, item) {
  if (item.channel === "native") return policy.nativeAllow.has(item.tool);
  if (policy.shellAllow.has(item.tool)) return true;
  if (item.category === "browser" && item.tool === "playwright") {
    return policy.shellAllow.has("@playwright/test");
  }
  return false;
}

function denyExternalTool(policy, item) {
  const alternatives = item.category === "github" ? githubAlternatives(policy) : browserAlternatives(policy);
  return {
    decision: "deny",
    code: "external-tool-denied",
    reason: `requested ${item.category} ${item.channel} tool '${item.tool}' is not authorized by ${policy.schema} in brief ${policy.briefPath}; authorized alternatives: ${alternatives}`,
  };
}

/** Applies one brief policy to a harness tool call. Uncontrolled project-development tools remain allowed. */
export function decideExternalToolCall(policy, toolName, input, commandOverride = "") {
  const nativeRequest = nativeToolRequest(toolName);
  if (nativeRequest && !requestAllowed(policy, nativeRequest)) return denyExternalTool(policy, nativeRequest);
  const command = commandOverride || (input && typeof input.command === "string" ? input.command : "");
  if (!command) return { decision: "allow" };
  for (const item of classifyExternalShellCommand(command)) {
    if (!requestAllowed(policy, item)) return denyExternalTool(policy, item);
  }
  return { decision: "allow" };
}

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
    const policy = readExternalToolPolicy(args.brief);
    if (args.validate) {
      process.stdout.write("allow\n");
    } else {
      let input;
      try {
        input = JSON.parse(args.inputJson || "{}");
      } catch (error) {
        throw new Error(`--input-json is invalid JSON: ${error.message}`);
      }
      const result = decideExternalToolCall(policy, args.tool, input, args.command);
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`fm-external-tool-policy: ${error.message}\n`);
    process.exitCode = 1;
  }
}
