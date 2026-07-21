#!/usr/bin/env node
// Apply the standard Firstmate dispatch shape (5-state workflow + 3 labels) to
// an EXISTING Linear team by ID, without creating a new team. Companion to
// fm-linear-team-scaffold.mjs (which creates a brand-new team) — use this one
// when a team already exists (e.g. was created before this pipeline existed).
//
// Usage: node bin/fm-linear-team-reshape.mjs <teamId>

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const FM_ROOT = path.resolve(fileURLToPath(import.meta.url), "..", "..");
const ENV_PATH = path.join(FM_ROOT, "..", "..", "_config", ".env");

function loadEnv(envPath) {
  const env = {};
  if (!existsSync(envPath)) return env;
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    env[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return env;
}

const env = loadEnv(ENV_PATH);
const LINEAR_API_KEY = env.LINEAR_API_KEY;
if (!LINEAR_API_KEY) {
  process.stderr.write("fm-linear-team-reshape: missing LINEAR_API_KEY in _config/.env\n");
  process.exit(1);
}

async function gql(query, variables) {
  const res = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: { Authorization: LINEAR_API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) throw new Error(`linear graphql error: ${JSON.stringify(json.errors)}`);
  return json.data;
}

const RENAME_MAP = { Backlog: "Inbox", Todo: "Next", "In Progress": "Doing", "In Review": "Waiting" };
const WANTED_LABELS = [
  { name: "agent-ready", color: "#5e6ad2", description: "An AI agent MAY work this task once it is also moved to Next" },
  { name: "waiting-on-me", color: "#f2c94c", description: "Agent finished or got stuck, needs Brandon input" },
  { name: "waiting-external", color: "#eb5757", description: "Blocked on a third party" },
];

async function reshapeTeam(teamId) {
  const detail = await gql(
    `query($id: String!) { team(id: $id) { id name states { nodes { id name type } } labels { nodes { id name } } } }`,
    { id: teamId },
  );
  const team = detail.team;

  const states = {};
  for (const state of team.states.nodes) {
    const target = RENAME_MAP[state.name];
    if (target) {
      await gql(
        `mutation($id: String!, $input: WorkflowStateUpdateInput!) { workflowStateUpdate(id: $id, input: $input) { success } }`,
        { id: state.id, input: { name: target } },
      );
      states[target] = state.id;
    } else if (state.name === "Done") {
      states.Done = state.id;
    }
  }

  for (const label of team.labels.nodes) {
    await gql(`mutation($id: String!) { issueLabelDelete(id: $id) { success } }`, { id: label.id });
  }

  const labels = {};
  for (const label of WANTED_LABELS) {
    // Skip create if a label with this name somehow survived (shouldn't, since
    // we just deleted every label on the team, but stay idempotent on re-run).
    const result = await gql(
      `mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id name } } }`,
      { input: { teamId, ...label } },
    );
    labels[label.name] = result.issueLabelCreate.issueLabel.id;
  }

  return { name: team.name, id: team.id, states, labels };
}

async function main() {
  const teamId = process.argv[2];
  if (!teamId) {
    process.stderr.write("usage: fm-linear-team-reshape.mjs <teamId>\n");
    process.exit(1);
  }
  const result = await reshapeTeam(teamId);
  process.stdout.write(JSON.stringify(result) + "\n");
}

main().catch((error) => {
  process.stderr.write(`fm-linear-team-reshape: ${error.stack || error.message}\n`);
  process.exit(1);
});
