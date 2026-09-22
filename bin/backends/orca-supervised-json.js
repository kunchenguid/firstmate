#!/usr/bin/env node
const fs = require("fs");

const field = process.argv[2];
const input = fs.readFileSync(0, "utf8");
let data;
try {
  data = JSON.parse(input);
} catch (_) {
  process.exit(1);
}
const root = data.result || data;
const dispatch = root.dispatch || {};
const worker = root.worker || {};
const projection = root.projection || {};
const observation = root.observation || {};
const terminal = root.terminal || {};
const terminalResource = root.terminalResource || {};
const resource = worker.resource || root.resource || terminalResource;
const resourceTerminal = resource.terminal || terminalResource.terminal || {};
const resourceWorktree = resource.worktree || terminalResource.worktree || {};
const first = (...values) => values.find(
  (value) => typeof value === "string" || typeof value === "number" || typeof value === "boolean",
);
const string = (value) => typeof value === "string" || typeof value === "number" ? String(value) : "";
const bool = (value) => typeof value === "boolean" ? String(value) : "";
const nested = (object, ...keys) => keys.reduce((value, key) => value && value[key], object);
let value = "";
switch (field) {
  case "schema-version": value = string(first(root.schemaVersion, data.schemaVersion)); break;
  case "run-id": value = string(first(root.runId, root.run_id, dispatch.runId, dispatch.run_id, worker.runId, worker.run_id, nested(root, "run", "id"), nested(dispatch, "run", "id"))); break;
  case "task-id": value = string(first(root.taskId, root.task_id, dispatch.taskId, dispatch.task_id, worker.taskId, worker.task_id, nested(root, "task", "id"), nested(dispatch, "task", "id"))); break;
  case "dispatch-id": value = string(first(root.dispatchId, root.dispatch_id, dispatch.dispatchId, dispatch.id, worker.dispatchId, worker.dispatch_id)); break;
  case "worker-id": value = string(first(root.workerId, root.worker_id, worker.workerId, worker.id, resource.workerId, resource.worker_id)); break;
  case "terminal-handle": value = string(first(root.agentTerminalHandle, root.terminalHandle, terminal.handle, worker.agentTerminalHandle, resource.terminalHandle, resource.handle, resourceTerminal.handle)); break;
  case "terminal-incarnation": value = string(first(root.agentTerminalIncarnation, root.terminalIncarnation, terminal.incarnationId, terminal.incarnation_id, terminal.processIncarnation, root.incarnationId, root.incarnation_id, resource.incarnationId, resource.incarnation_id, resource.endpointIncarnation, resource.endpoint_incarnation, resourceTerminal.incarnationId, resourceTerminal.incarnation_id, resourceTerminal.endpointIncarnation, dispatch.processIncarnation)); break;
  case "pane-key": value = string(first(root.agentTerminalPaneKey, root.terminalPaneKey, terminal.paneKey, terminal.pane_key, terminal.assigneePaneKey, root.paneKey, root.pane_key, dispatch.assigneePaneKey, resource.paneKey, resource.pane_key, resource.endpointPaneKey, resource.endpoint_pane_key, resourceTerminal.paneKey, resourceTerminal.pane_key)); break;
  case "worktree-id": value = string(first(terminal.worktreeId, terminal.worktree_id, terminal.worktree, terminal.worktree && terminal.worktree.id, root.worktreeId, root.worktree_id, root.worktree, root.worktree && root.worktree.id, dispatch.worktreeId, worker.worktreeId, resource.worktreeId, resource.worktree_id, resource.worktree, resourceWorktree.id)); break;
  case "worktree-path": value = string(first(terminal.worktreePath, terminal.path, terminal.worktree && terminal.worktree.path, root.worktreePath, root.path, root.worktree && root.worktree.path, dispatch.worktreePath, worker.worktreePath, resourceWorktree.path)); break;
  case "exact-worker": value = bool(first(observation.exactWorker, observation.exact_worker, root.exactWorker, root.exact_worker, projection.exactWorker, projection.exact_worker)); break;
  case "source": value = string(first(root.source, root.provider)); break;
  case "source-identity": value = string(first(root.sourceIdentity, root.source_identity)); break;
  case "next-cursor": value = string(first(root.nextCursor, root.next_cursor, nested(root, "page", "nextCursor"))); break;
  case "content-complete": value = bool(first(root.contentComplete, root.content_complete, root.complete)); break;
  case "clipping": value = typeof root.clipping === "boolean" ? String(root.clipping) : string(first(root.clipping && root.clipping.clipped, root.clipped, root.truncated)); break;
  case "source-exact": value = bool(first(root.sourceExact, root.source_exact)); break;
  case "source-changed": {
    value = bool(first(root.sourceChanged, root.source_changed));
    if (value !== "true") {
      const reason = string(first(root.fallbackReason, root.fallback_reason));
      const warnings = Array.isArray(root.warnings) ? root.warnings.join(" ") : string(root.warnings);
      value = /source[ _-]?changed/i.test(`${reason} ${warnings}`) ? "true" : "";
    }
    break;
  }
  case "worker-state": value = string(first(worker.state, worker.workerState, dispatch.workerState, dispatch.worker_state, root.workerState, root.worker_state, root.state)); break;
  case "dispatch-status": value = string(first(dispatch.status, dispatch.state, root.dispatchStatus, root.dispatch_status, root.status)); break;
  case "liveness": value = string(first(
    projection.liveness && projection.liveness.state,
    projection.liveness && projection.liveness.status,
    typeof projection.liveness === "string" ? projection.liveness : undefined,
    root.liveness && root.liveness.state,
    root.liveness && root.liveness.status,
    typeof root.liveness === "string" ? root.liveness : undefined,
  )); break;
  case "next-action": value = string(first(projection.nextAction, projection.next_action)); break;
  case "observation-status": value = string(first(observation.status, observation.state)); break;
  case "owned": {
    value = bool(first(resource.ownedByCoordinator, resource.owned_by_coordinator, resource.coordinatorOwned, resource.coordinator_owned));
    if (!value) {
      const owner = string(first(resource.ownership, resource.owner, terminalResource.ownership));
      value = /^(coordinator|owned|firstmate)$/i.test(owner) ? "true" : owner ? "false" : "";
    }
    break;
  }
  case "settled": {
    const explicit = first(root.settled, dispatch.settled, worker.settled);
    value = typeof explicit === "boolean" ? String(explicit) :
      (/^(succeeded|success|failed|cancelled|completed|settled|done)$/i.test(
        string(first(worker.state, worker.workerState, dispatch.status, dispatch.state, dispatch.outcome, root.status, root.outcome)),
      ) ? "true" : "false");
    break;
  }
  case "has-transcript": value = Array.isArray(root.transcript && root.transcript.messages) && root.transcript.messages.length ? "true" : "false"; break;
  case "text": {
    const transcript = root.transcript || {};
    const messages = Array.isArray(transcript.messages) ? transcript.messages : [];
    const blocks = [];
    const walk = (block) => {
      if (!block || typeof block !== "object") return;
      if (typeof block.text === "string") blocks.push(block.text);
      else if (typeof block.output === "string") blocks.push(block.output);
      else if (typeof block.content === "string") blocks.push(block.content);
      else if (Array.isArray(block.blocks)) block.blocks.forEach(walk);
    };
    for (const message of messages) {
      if (Array.isArray(message.blocks)) message.blocks.forEach(walk);
      else if (typeof message.text === "string") blocks.push(message.text);
    }
    if (!blocks.length) {
      if (Array.isArray(terminal.tail)) blocks.push(terminal.tail.join("\n"));
      else if (typeof root.text === "string") blocks.push(root.text);
      else if (typeof root.output === "string") blocks.push(root.output);
      else if (typeof root.content === "string") blocks.push(root.content);
      else if (typeof root.preview === "string") blocks.push(root.preview);
    }
    process.stdout.write(blocks.join("\n"));
    process.exit(0);
    break;
  }
  default: process.exit(2);
}
if (value) process.stdout.write(value);
