#!/usr/bin/env node
// Poll the linear_dispatch_queue Supabase table (the Vercel webhook's bridge
// table - see ops/linear-dispatch-webhook/) for Linear issues that entered
// Next + agent-ready, claim them, and dispatch a real Firstmate crewmate for
// each. This is Component 2's Firstmate-side half of
// resources/modern-ai-productivity-pack/01-SHARED-WORKSPACE.md's dispatch flow.
//
// Design (see ops/firstmate/data/learnings.md "Linear Modern AI Productivity
// Pack integration" for the full architecture and IDs):
//   Linear (Next + agent-ready) -> Vercel webhook -> Supabase queue row (pending)
//     -> this poller claims it (compare-and-swap on status='pending') and:
//        1. best-effort creates a Notion Task under the matching business
//           Project (plan-before-dispatch; skipped gracefully if no mapping
//           exists yet for that business - never blocks dispatch)
//        2. scaffolds a crewmate brief via fm-brief.sh
//        3. spawns a crewmate via fm-spawn.sh
//        4. moves the Linear issue to Doing and posts a "starting" comment
//        5. marks the Supabase row dispatched (or failed, with the error kept
//           in the row for inspection)
//
// Run manually (one pass) or wire into a periodic wakeup; this script does
// not loop or daemonize itself - one invocation is one pass over pending rows.
//
// Routing is by Linear TEAM, not Project (2026-07-20 restructure: every
// business is now its own Linear team with the standard 5-state/3-label
// shape - see bin/fm-linear-team-scaffold.mjs / fm-linear-team-reshape.mjs -
// rather than one shared team holding a Project per business). The webhook
// is workspace-wide (allPublicTeams) so it fires for issues in any team.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const FM_ROOT = path.resolve(fileURLToPath(import.meta.url), "..", "..");
const COMMAND_CENTER_ROOT = path.resolve(FM_ROOT, "..", "..");
const ENV_PATH = path.join(COMMAND_CENTER_ROOT, "_config", ".env");

// Linear team id -> where a crewmate should work + which Notion Project (if
// any) should get the plan-before-dispatch Task. Notion Project URLs are the
// ones created 2026-07-20; businesses without one yet are left null and
// simply skip the Notion pre-task step (never blocks dispatch).
const TEAM_ROUTING = {
  "2371d781-641f-4fb9-9664-812a2b9ba01a": { name: "Command Center", repo: "claude-skills", business: null, notionProject: "https://app.notion.com/p/3a36723139938117832dcdc360491d11" },
  "f4d9d1c1-8cf9-4d17-82da-6a8591bf9544": { name: "BuyBox", repo: "command-center", business: "businesses/on-hold/buybox/", notionProject: null },
  "69890873-b361-445d-a39f-f9f470d4aa9e": { name: "Firstmate", repo: "claude-skills", business: null, notionProject: "https://app.notion.com/p/3a36723139938117832dcdc360491d11" },
  "92040d34-1452-4921-8e2a-38efa678f9ff": { name: "Cold Email", repo: "command-center", business: "businesses/cold-email/", notionProject: null },
  "3f86ee73-9df5-4eeb-87d5-aa447725adb1": { name: "Upwork", repo: "command-center", business: "businesses/upwork/", notionProject: null },
  "2b259fd2-bae3-4574-9d4f-f1932d8483e5": { name: "EpicOS", repo: "command-center", business: "businesses/epic-os/", notionProject: null },
  "1a76e9c8-2227-4da7-b73d-26b3193e8e41": { name: "UltraStays", repo: "command-center", business: "businesses/ultra-stays/", notionProject: null },
  "2d7acd3b-f909-4876-aa29-27e9c84880d7": { name: "BrandonQ", repo: "command-center", business: "businesses/brandonq/", notionProject: null },
  "c7976784-da5b-4459-aea8-465433b30c02": { name: "OmniFlows", repo: "command-center", business: "businesses/omniflows/", notionProject: null },
  "ee5b177c-7fca-44ee-b2f8-774541ae656a": { name: "MonetizedMind", repo: "command-center", business: "businesses/monetized-mind/", notionProject: "https://app.notion.com/p/124672313993802f9cb2dc949f59947f" },
  "bd9a7a03-d1d6-4cd0-8041-571a7595bd91": { name: "Real Estate", repo: "command-center", business: "businesses/real-estate/", notionProject: "https://app.notion.com/p/3a367231399381648a3ed28272e1e717" },
  "a1b2d189-a7ce-4603-ac63-57c0554376f0": { name: "Acquisitions", repo: "command-center", business: "businesses/acquisitions/", notionProject: null },
  "a8ea0815-4072-4cbc-9921-4b02462c0fc0": { name: "Content Machine", repo: "command-center", business: "businesses/content-machine/", notionProject: null },
};

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
const SUPABASE_URL = env.BH1VE_SUPABASE_URL;
const SUPABASE_SERVICE_KEY = env.BH1VE_SUPABASE_SERVICE_KEY;

function fail(message) {
  process.stderr.write(`fm-linear-poll: ${message}\n`);
  process.exitCode = 1;
}

if (!LINEAR_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
  fail("missing LINEAR_API_KEY / BH1VE_SUPABASE_URL / BH1VE_SUPABASE_SERVICE_KEY in _config/.env");
  process.exit(1);
}

async function supabase(pathAndQuery, init = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    ...init,
    headers: {
      apikey: SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`supabase ${init.method || "GET"} ${pathAndQuery} -> ${res.status}: ${body}`);
  }
  return res.json();
}

async function linearGraphQL(query, variables) {
  const res = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: { Authorization: LINEAR_API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) throw new Error(`linear graphql error: ${JSON.stringify(json.errors)}`);
  return json.data;
}

const stateIdCache = new Map();
async function stateIdByName(teamId, name) {
  const key = `${teamId}:${name}`;
  if (stateIdCache.has(key)) return stateIdCache.get(key);
  const data = await linearGraphQL(
    `query($teamId: String!) { team(id: $teamId) { states { nodes { id name } } } }`,
    { teamId },
  );
  for (const state of data.team.states.nodes) stateIdCache.set(`${teamId}:${state.name}`, state.id);
  if (!stateIdCache.has(key)) throw new Error(`no Linear state named "${name}" on team ${teamId}`);
  return stateIdCache.get(key);
}

async function claimPendingRows() {
  // Compare-and-swap: only rows still status='pending' actually update, so two
  // concurrent poll runs can never both claim the same row.
  const claimedAt = new Date().toISOString();
  const rows = await supabase(
    `linear_dispatch_queue?status=eq.pending&order=created_at.asc&limit=10`,
  );
  const claimed = [];
  for (const row of rows) {
    const updated = await supabase(
      `linear_dispatch_queue?id=eq.${row.id}&status=eq.pending`,
      {
        method: "PATCH",
        body: JSON.stringify({ status: "claimed", claimed_at: claimedAt, claimed_by: "firstmate-primary" }),
      },
    );
    if (updated.length > 0) claimed.push(updated[0]);
  }
  return claimed;
}

async function markRow(id, fields) {
  await supabase(`linear_dispatch_queue?id=eq.${id}`, { method: "PATCH", body: JSON.stringify(fields) });
}

function slugify(identifier) {
  return `linear-${identifier.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
}

function run(cmd, args, opts = {}) {
  return execFileSync(cmd, args, { cwd: FM_ROOT, encoding: "utf8", ...opts });
}

async function createNotionTask(routing, row) {
  if (!routing.notionProject) return null;
  // Best-effort only: this poller does not have direct Notion MCP access (it's
  // a plain node script, not an agent turn), so it cannot call notion-create-pages
  // itself. It writes a plan-first request file that the NEXT primary firstmate
  // session picks up and creates for real, keeping the two-gate rule intact
  // without requiring this script to embed Notion credentials/API calls.
  const requestsPath = path.join(FM_ROOT, "state", "linear-notion-task-requests.jsonl");
  const request = {
    linear_identifier: row.linear_identifier,
    title: row.title,
    notion_project: routing.notionProject,
    requested_at: new Date().toISOString(),
  };
  const existing = existsSync(requestsPath) ? readFileSync(requestsPath, "utf8") : "";
  writeFileSync(requestsPath, existing + JSON.stringify(request) + "\n");
  return request;
}

async function dispatchOne(row) {
  const routing = TEAM_ROUTING[row.linear_team_id];
  if (!routing) {
    await markRow(row.id, { status: "failed" });
    process.stdout.write(`skipped ${row.linear_identifier}: no TEAM_ROUTING entry for team id "${row.linear_team_id}"\n`);
    return;
  }

  const taskId = slugify(row.linear_identifier);
  try {
    await createNotionTask(routing, row);

    run("bin/fm-brief.sh", [taskId, routing.repo]);
    const briefPath = path.join(FM_ROOT, "data", taskId, "brief.md");
    const brief = readFileSync(briefPath, "utf8");
    const businessLine = routing.business ? `Business area: \`${routing.business}\`.\n\n` : "";
    const taskText =
      `${businessLine}${row.title}\n\n${row.description || "(no description on the Linear issue)"}\n\n` +
      `Source: Linear issue ${row.linear_identifier} — ${row.linear_url}\n` +
      `When done, the result should also be summarized as a comment back on that Linear issue ` +
      `(firstmate posts it after you report done — you do not need Linear access yourself).`;
    writeFileSync(briefPath, brief.replace("{TASK}", taskText));

    run("bin/fm-spawn.sh", [taskId, `projects/${routing.repo}`, "--effort", "medium"]);

    const doingId = await stateIdByName(row.linear_team_id, "Doing");
    await linearGraphQL(
      `mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }`,
      { id: row.linear_issue_id, input: { stateId: doingId } },
    );
    await linearGraphQL(
      `mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }`,
      { input: { issueId: row.linear_issue_id, body: `Starting — dispatched to Firstmate crewmate \`${taskId}\`.` } },
    );

    await markRow(row.id, { status: "dispatched", firstmate_task_id: taskId });
    process.stdout.write(`dispatched ${row.linear_identifier} -> ${taskId}\n`);
  } catch (error) {
    await markRow(row.id, { status: "failed" });
    process.stdout.write(`failed ${row.linear_identifier}: ${error.message}\n`);
  }
}

async function main() {
  const claimed = await claimPendingRows();
  if (claimed.length === 0) {
    process.stdout.write("no pending Linear dispatch rows\n");
    return;
  }
  for (const row of claimed) {
    await dispatchOne(row);
  }
}

main().catch((error) => {
  fail(error.stack || error.message);
  process.exit(1);
});
