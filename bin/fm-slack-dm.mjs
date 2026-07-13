#!/usr/bin/env node
// Send one firstmate AFK escalation as a Slack DM through chat.postMessage.
//
// The token is resolved inside this process from a local token-source plugin, so
// the token is never passed as an argv value to curl or another helper.
// Config is local and gitignored at config/afk-slack-dm by default.

import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_TIMEOUT_MS = 15_000;
const MAX_TOKEN_OUTPUT_BYTES = 64 * 1024;

function usage() {
  console.log(`Usage: fm-slack-dm.mjs [--config <file>] --message-file <file>

Reads local config/afk-slack-dm:
  destination=U0123456789
  name=Alex                 optional; attribution becomes "AI agent for Alex here —"
  token-source=file:/absolute/path/to/token
  token-source=command:/absolute/path/to/print-token

Environment:
  FM_SLACK_DM_CONFIG   override config file path
  FM_SLACK_DM_API_URL  override Slack API URL for tests
  FM_HOME              operational firstmate home
  FM_CONFIG_OVERRIDE   operational config directory
`);
}

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--config":
        opts.config = argv[++i];
        break;
      case "--message-file":
      case "--text-file":
        opts.messageFile = argv[++i];
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  return opts;
}

function defaultConfigPath() {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const root = dirname(scriptDir);
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDir = process.env.FM_CONFIG_OVERRIDE || join(home, "config");
  return join(configDir, "afk-slack-dm");
}

function parseConfig(text) {
  const config = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx < 1) throw new Error("malformed config line");
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (!key || !value) throw new Error("malformed config line");
    config[key] = value;
  }
  return config;
}

// The attribution prefix is config-driven so the shared template never hardcodes
// one adopter's name. A local `name=` value yields "AI agent for <name> here —";
// with no `name` key the generic default "AI agent here —" applies. The daemon's
// afk_slack_dm_prefix derives the same string from the same key, so the message it
// builds always satisfies the required-prefix check here.
function attributionPrefix(config) {
  const name = (config.name || "").trim();
  return name ? `AI agent for ${name} here —` : "AI agent here —";
}

function isSlackUserId(value) {
  return /^[UW][A-Z0-9]{2,}$/.test(value);
}

function isSlackConversationId(value) {
  return /^[CDG][A-Z0-9]{2,}$/.test(value);
}

function cleanToken(text) {
  return text.replace(/\r/g, "").split("\n").map((line) => line.trim()).find(Boolean) || "";
}

async function readToken(source) {
  if (!source || source === "none") return "";
  if (source.startsWith("file:")) {
    const file = source.slice("file:".length).trim();
    if (!file) throw new Error("token-source file path is empty");
    return cleanToken(await readFile(file, "utf8"));
  }
  if (source.startsWith("command:")) {
    const command = source.slice("command:".length).trim();
    if (!command) throw new Error("token-source command is empty");
    return readCommandToken(command);
  }
  throw new Error("unsupported token-source mode");
}

function readCommandToken(command) {
  return new Promise((resolve) => {
    const child = spawn("/bin/sh", ["-s"], {
      stdio: ["pipe", "pipe", "ignore"],
    });
    let stdout = "";
    let settled = false;
    let timer;
    const settle = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    timer = setTimeout(() => {
      child.kill("SIGTERM");
      settle("");
    }, DEFAULT_TIMEOUT_MS);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (Buffer.byteLength(stdout, "utf8") > MAX_TOKEN_OUTPUT_BYTES) {
        child.kill("SIGTERM");
        settle("");
      }
    });
    child.on("error", () => settle(""));
    child.on("close", (code) => {
      settle(code === 0 ? cleanToken(stdout) : "");
    });
    child.stdin.end(command.endsWith("\n") ? command : `${command}\n`);
  });
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`config error: ${err.message}`);
    return 3;
  }
  if (opts.help) {
    usage();
    return 0;
  }
  if (!opts.messageFile) {
    console.error("config error: --message-file is required");
    return 3;
  }

  const configPath = opts.config || process.env.FM_SLACK_DM_CONFIG || defaultConfigPath();
  let configText;
  try {
    configText = await readFile(configPath, "utf8");
  } catch {
    console.error("slack-dm disabled: config absent");
    return 2;
  }

  let config;
  try {
    config = parseConfig(configText);
  } catch (err) {
    console.error(`config error: ${err.message}`);
    return 3;
  }

  const destination = config.destination || config.user;
  if (!destination) {
    console.error("config error: destination is required");
    return 3;
  }
  if (!isSlackUserId(destination)) {
    if (isSlackConversationId(destination)) {
      console.error("config error: destination must be a Slack user ID, not a channel or conversation ID");
    } else {
      console.error("config error: destination must be a Slack user ID");
    }
    return 3;
  }

  const sender = config.sender || "slack-api";
  if (sender !== "slack-api") {
    console.error("config error: unsupported sender");
    return 3;
  }

  let message;
  try {
    message = await readFile(opts.messageFile, "utf8");
  } catch {
    console.error("config error: message file is unreadable");
    return 3;
  }
  message = message.replace(/\s+$/g, "");
  const requiredPrefix = attributionPrefix(config);
  if (!message.startsWith(requiredPrefix)) {
    console.error("config error: message must begin with the required AI agent attribution");
    return 3;
  }

  const tokenSource = config["token-source"]
    || (config["token-command"] ? `command:${config["token-command"]}` : "");
  let token;
  try {
    token = await readToken(tokenSource);
  } catch (err) {
    console.error(`config error: ${err.message}`);
    return 3;
  }
  if (!token) {
    console.error("slack-dm skipped: missing-token");
    return 1;
  }

  const apiUrl = process.env.FM_SLACK_DM_API_URL || "https://slack.com/api/chat.postMessage";
  let response;
  try {
    response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ channel: destination, text: message }),
      signal: AbortSignal.timeout(DEFAULT_TIMEOUT_MS),
    });
  } catch {
    console.error("slack-dm failed: network-error");
    return 1;
  }

  let data = {};
  try {
    data = await response.json();
  } catch {
    data = {};
  }

  if (!response.ok) {
    console.error("slack-dm failed: http-error");
    return 1;
  }
  if (data.ok === true) {
    const ts = typeof data.ts === "string" && /^[0-9.]+$/.test(data.ts) ? ` ts=${data.ts}` : "";
    console.log(`slack-dm sent destination=${destination}${ts}`);
    return 0;
  }

  console.error("slack-dm failed: slack-api-error");
  return 1;
}

main().then((code) => {
  process.exitCode = code;
}).catch(() => {
  console.error("slack-dm failed: internal-error");
  process.exitCode = 1;
});
