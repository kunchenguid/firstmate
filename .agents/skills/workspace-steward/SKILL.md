---
name: workspace-steward
description: >-
  Agent-only procedure for safe, ongoing stewardship of Herdr workspaces, SSH reachability, and Tailscale health across the primary server and Pop!_OS.
  Use before inventorying or mutating Herdr workspace, pane, or tab state, or diagnosing SSH or Tailscale connectivity across hosts.
user-invocable: false
metadata:
  internal: true
---

# workspace-steward

Use this procedure to observe and propose stewardship work across the primary server and Pop!_OS.
This is the single owner of Firstmate's workspace and connectivity stewardship procedure.
`docs/herdr-backend.md` owns Firstmate's Herdr backend mechanics.

## Read-only inventory

Treat this phase as non-destructive observation.
Treat inventory as observation, never as authority to change a host, workspace, task, or connection.
Start with the applicable Firstmate home records and targeted current task state before reading Herdr.
Classify a workspace, tab, or pane as Firstmate-owned only when its recorded task identity and exact endpoint agree.
Classify a registered secondmate's workspace separately from the primary's workspace and from each sibling home.
Treat labels, names, ordering, and visible activity as display hints rather than ownership proof.
Classify any conflicting, incomplete, or label-only evidence as unknown, never as owned or unowned, and report it without acting.
Never treat a quiet secondmate as failed, because an idle secondmate is healthy unless its own routed result or current-state reconciliation says otherwise.
Never inspect or act on an unregistered external project, even when its workspace name, path, or agent appears familiar.

Read-only Herdr work may list status, workspaces, tabs, panes, and bounded captures without sending text or keys.
Use a one-shot, noninteractive SSH path for a registered remote host, such as `ssh -o BatchMode=yes -o ConnectTimeout=10 -- <registered-host> 'herdr --session <registered-session> status --json'`.
Keep the host and Herdr session explicit in every remote command, and restrict remote inventory to known read-only status, list, or capture operations.
Do not open an interactive shell, a persistent tunnel, or any socket forwarding for inventory.
Never expose, forward, mount, proxy, or otherwise publish a local Herdr socket.

For connectivity diagnosis, separately record each host's local Tailscale status, the observed peer or route status, and the result of one bounded SSH reachability probe.
Report the host, evidence time, reachability result, ownership classification, and the next decision without treating stale output as current health.
A healthy Tailscale peer does not prove SSH or Herdr health, and a reachable SSH host does not prove a task endpoint is safe to touch.

## Workspace mutation mode

Start with targeted task and secondmate metadata, then query only the host and confirmed endpoint whose evidence needs refreshing.
Run at most one bounded batched JSON inventory per host per stewardship pass.
Do not retry a broad inventory in the same pass unless changed or contradictory evidence creates a new question.
Read one exact confirmed pane only for render QA or to resolve contradictory evidence.
Reuse a registered persistent secondmate for its in-scope stewardship work rather than creating another helper or sweeping sibling homes.
Report a compact digest and changes only.
Send a sparse update only when evidence creates an actionable decision, blocker, ownership conflict, or material health change.
Do not conduct periodic, speculative, or repeated broad scans when the prior evidence remains sufficient.

## Approval boundaries

Exact captain approval must name the target, requested action, expected outcome, and rollback or recovery plan before any mutation.
A broad request to steward workspaces or connectivity is not approval for a specific mutation.
Do not close, move, kill, restart, or delete any workspace, pane, tab, agent session, or remote connection without that approval.
Do not rename, reorder, or otherwise change workspace layout without that approval.
Do not change Tailscale login, routes, ACLs, DNS, or exposure without that approval.
Do not install or update software, access secrets, or send a prompt, text, or key to an externally managed agent without that approval.
Do not bypass Firstmate's selected task delivery path, task isolation, or recorded endpoint ownership through manual Herdr commands.
This procedure creates no authority to start, stop, restart, or clean up Herdr lifecycle resources.
A separate task that drives Herdr lifecycle behavior must retain the existing `--herdr-lab` safeguard.

## Mutation guardrails

Only make changes after exact captain approval exists for every requested action.

Propose reversible naming or layout improvements before changing them.
Each proposal must state the current layout, affected confirmed owners, exact reversible change, expected benefit, rollback, and any unknown ownership.
Stop for captain approval when a proposal would touch a Firstmate task, secondmate, external agent, remote connection, or network setting.

## Connectivity failures and reports

Diagnose in order: local Tailscale health, peer or route visibility, bounded SSH reachability, then read-only remote Herdr status.
Treat authentication prompts, missing credentials, unavailable secrets, route ambiguity, and host identity changes as blockers rather than repair opportunities.
Do not retry a failed connection by changing configuration, restarting services, or weakening network controls.
Escalate with the failed stage, safe evidence, operational consequence, and the smallest approved next action.

## Reference boundaries

Use the Pop!_OS Claude `herdr` skill only as a host-local reference point.
Do not copy its implementation or create a competing lifecycle contract here.
