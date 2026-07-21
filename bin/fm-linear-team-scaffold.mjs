#!/usr/bin/env node
// Create one or more Linear teams with the standard Firstmate dispatch shape:
// the same 5-state workflow (Inbox/Next/Doing/Waiting/Done) and 3 labels
// (agent-ready/waiting-on-me/waiting-external) as the "Command Center" team,
// so every team is a valid dispatch target for the Modern AI Productivity
// Pack pipeline (see ops/firstmate/data/learnings.md for the full architecture).
//
// Usage: node bin/fm-linear-team-scaffold.mjs "Team One" "Team Two" ...
// Prints one JSON line per created team: {name, id, key, states: {...}, labels: {...}}

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
  process.stderr.write("fm-linear-team-scaffold: missing LINEAR_API_KEY in _config/.env\n");
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

function keyFromName(name) {
  const compact = name.toUpperCase().replace(/[^A-Z]/g, "");
  return compact.slice(0, 5) || "TEAM";
}

async function scaffoldTeam(name) {
  const created = await gql(
    `mutation($input: TeamCreateInput!) { teamCreate(input: $input) { success team { id name key } } }`,
    { input: { name, key: keyFromName(name), description: `Firstmate dispatch team for ${name}. See resources/modern-ai-productivity-pack.` } },
  );
  const team = created.teamCreate.team;

  const detail = await gql(
    `query($id: String!) { team(id: $id) { states { nodes { id name type } } labels { nodes { id name } } } }`,
    { id: team.id },
  );

  const states = {};
  for (const state of detail.team.states.nodes) {
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

  for (const label of detail.team.labels.nodes) {
    await gql(`mutation($id: String!) { issueLabelDelete(id: $id) { success } }`, { id: label.id });
  }

  const labels = {};
  for (const label of WANTED_LABELS) {
    const result = await gql(
      `mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id name } } }`,
      { input: { teamId: team.id, ...label } },
    );
    labels[label.name] = result.issueLabelCreate.issueLabel.id;
  }

  return { name: team.name, id: team.id, key: team.key, states, labels };
}

async function main() {
  const names = process.argv.slice(2);
  if (names.length === 0) {
    process.stderr.write("usage: fm-linear-team-scaffold.mjs \"Team One\" \"Team Two\" ...\n");
    process.exit(1);
  }
  for (const name of names) {
    const result = await scaffoldTeam(name);
    process.stdout.write(JSON.stringify(result) + "\n");
  }
}

main().catch((error) => {
  process.stderr.write(`fm-linear-team-scaffold: ${error.stack || error.message}\n`);
  process.exit(1);
});
