#!/usr/bin/env node
// Claude UserPromptSubmit adapter for exact interactive Firstmate Bearings shortcuts.

import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function canonicalPath(path) {
  try {
    return realpathSync(path);
  } catch {
    return "";
  }
}

if (process.env.CLAUDE_CODE_ENTRYPOINT !== "cli" || !process.env.CLAUDE_PROJECT_DIR) {
  process.exit(0);
}

const root = canonicalPath(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
const projectRoot = canonicalPath(process.env.CLAUDE_PROJECT_DIR);
if (!root || projectRoot !== root) process.exit(0);

const bearingsOwner = canonicalPath(resolve(root, ".agents/skills/bearings/SKILL.md"));
const claudeBearings = canonicalPath(resolve(root, ".claude/skills/bearings/SKILL.md"));
if (!bearingsOwner || bearingsOwner !== claudeBearings) process.exit(0);

let rawPayload = "";
try {
  for await (const chunk of process.stdin) rawPayload += chunk;
} catch {
  process.exit(0);
}

let payload;
try {
  payload = JSON.parse(rawPayload);
} catch {
  process.exit(0);
}

if (payload?.hook_event_name !== "UserPromptSubmit" || typeof payload.prompt !== "string") {
  process.exit(0);
}

const shortcut = payload.prompt.trim().toLowerCase();
let additionalContext;
if (shortcut === "s") {
  additionalContext = "Firstmate interactive Claude CLI shortcut handling applies because the complete trimmed text is the exact case-insensitive `s` token, so Claude invokes the project-owned `bearings` skill with the exact `captains-call-only` argument. Claude UserPromptSubmit does not expose attachment metadata, so this exact mapping also applies when an image accompanies the token; image-bearing near-matches remain ordinary. The project-owned `bearings` skill remains the sole classification and report owner.";
} else if (shortcut === "status?") {
  additionalContext = "Firstmate interactive Claude CLI shortcut handling applies because the complete trimmed text is the exact case-insensitive `status?` token, so Claude invokes the project-owned `bearings` skill with no arguments for its full four-section workflow. Claude UserPromptSubmit does not expose attachment metadata, so this exact mapping also applies when an image accompanies the token; image-bearing near-matches remain ordinary. The project-owned `bearings` skill remains the sole classification and report owner.";
} else {
  process.exit(0);
}

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext,
  },
}));
