# Paperclip–FirstMate Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing FirstMate coding crew a durable Paperclip implementation worker, supervised by OpenClaw and coordinated by Hermes.

**Architecture:** Add a purpose-built Paperclip `firstmate-bridge` adapter. It consumes only the FirstMate agent's actionable task runs, sends a normalized task brief to the existing authenticated FirstMate realtime bridge, and records bounded status/result events. FirstMate remains responsible for worktree creation and crew execution; Paperclip remains the system of record.

**Tech Stack:** Paperclip TypeScript adapter SDK, Node.js WebSocket client, existing FirstMate realtime bridge, Paperclip agent runtime keys, Vitest, Docker Compose/systemd deployment on `plane.vthq.net`.

## Global Constraints

- Reuse `/opt/firstmate-realtime-bridge` and the active `firstmate` tmux session on `coding.vthq.net`.
- Do not create a VM, modify UFW, modify router/firewall policy, or expose a new LAN service.
- Keep bridge and Paperclip credentials in root-owned/runtime-owned `0600` files or protected service environments; never emit their values to task comments, test output, or git.
- Preserve the existing uncommitted Paperclip source changes, including the OpenClaw adapter fixes.
- FirstMate only receives tasks assigned to its dedicated Paperclip agent ID.
- Dispatch is idempotent by Paperclip run ID; a retry must not create a second FirstMate work item.
- Initial production validation is a no-change task and must not modify a customer repository or production system.

## File Structure

- Create: `packages/adapters/firstmate-bridge/` — Paperclip adapter package, server entrypoint, UI config schema, documentation, and focused tests.
- Create: `packages/adapters/firstmate-bridge/src/server/bridge-client.ts` — authenticated WebSocket client with explicit command/result correlation.
- Create: `packages/adapters/firstmate-bridge/src/server/execute.ts` — normalize Paperclip wake context, deduplicate dispatches, stream bridge status, and produce final results.
- Create: `packages/adapters/firstmate-bridge/src/server/test.ts` — config/environment checks without consuming a task.
- Create: `packages/adapters/firstmate-bridge/src/ui/index.ts` — adapter form fields and safe defaults.
- Modify: Paperclip adapter package/workspace registry files identified in Task 3 — build and expose the adapter.
- Modify: `ui/src/adapters/adapter-display-registry.ts` — show the FirstMate adapter as available in the Paperclip UI.
- Create: `docs/firstmate-paperclip-operations.md` — key rotation, health checks, recovery, and the end-to-end operating sequence.
- Create: protected runtime files on `.15` and `.10` only — agent-specific Paperclip and bridge credentials, never versioned.

### Task 1: Verify and harden the bridge contract

**Files:**
- Modify: `/opt/firstmate-realtime-bridge/src/server.mjs`
- Modify: `/opt/firstmate-realtime-bridge/src/agent.mjs`
- Create: `/opt/firstmate-realtime-bridge/test/paperclip-contract.test.mjs`

**Consumes:** Existing commands `say`, `status`, `state`, `read`, `windows`, and `start`.

**Produces:** A versioned `paperclip.dispatch` command and structured `paperclip.accepted`, `paperclip.progress`, and `paperclip.completed` events containing `runId` and `taskId` but no credentials.

- [ ] **Step 1: Put the standalone bridge under local version control without altering its runtime**

Run:

```bash
cd /opt/firstmate-realtime-bridge
git init -b main
git add package.json package-lock.json src systemd mcp
git commit -m "chore: baseline FirstMate realtime bridge"
```

Expected: a local Git history exists for bridge changes; token/state files, `node_modules`, and service environment files are excluded.

- [ ] **Step 2: Write failing contract tests**

```js
test('rejects a malformed Paperclip dispatch', async () => {
  const result = await dispatch({ type: 'paperclip.dispatch', runId: '' });
  assert.deepEqual(result, { ok: false, code: 'invalid_dispatch' });
});

test('replaying the same run ID is acknowledged without a second tmux submission', async () => {
  await dispatch(validDispatch);
  await dispatch(validDispatch);
  assert.equal(sendKeysCalls, 1);
});
```

- [ ] **Step 3: Run the bridge contract test and verify RED**

Run: `cd /opt/firstmate-realtime-bridge && node --test test/paperclip-contract.test.mjs`

Expected: FAIL because `paperclip.dispatch` and its replay protection do not exist.

- [ ] **Step 4: Implement the bounded bridge protocol**

```js
// A dispatch must contain non-empty string runId, taskId, and brief.
// Persist accepted run IDs atomically in the bridge state directory.
// Send only the normalized brief to FirstMate's existing tmux pane.
// Emit status events keyed by runId; reject unrecognized commands.
```

- [ ] **Step 5: Run bridge tests and non-writing health check**

Run: `cd /opt/firstmate-realtime-bridge && npm test`

Run: authenticated `GET /health` and WebSocket connection test against the existing bridge.

Expected: all tests pass; health says `agent_connected: true`; no task is submitted.

- [ ] **Step 6: Commit the bridge-only change**

```bash
git -C /opt/firstmate-realtime-bridge add src test
git -C /opt/firstmate-realtime-bridge commit -m "feat: accept idempotent Paperclip dispatches"
```

### Task 2: Build the FirstMate Paperclip adapter test-first

**Files:**
- Create: `packages/adapters/firstmate-bridge/package.json`
- Create: `packages/adapters/firstmate-bridge/src/index.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/index.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/bridge-client.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/execute.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/execute.test.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/test.ts`
- Create: `packages/adapters/firstmate-bridge/src/server/test.test.ts`
- Create: `packages/adapters/firstmate-bridge/src/ui/index.ts`

**Consumes:** `AdapterExecutionContext`, `AdapterExecutionResult`, and Paperclip wake payload conventions used by `openclaw-gateway/src/server/execute.ts`; the Task 1 bridge protocol.

**Produces:** `execute(ctx)`, `testEnvironment(ctx)`, config schema fields `bridgeUrl`, `bridgeToken`, `sessionKeyStrategy`, and a redacted task status/result stream.

- [ ] **Step 1: Write failing adapter tests**

```ts
it('dispatches each Paperclip run only once', async () => {
  await execute(context({ runId: 'run-1' }));
  await execute(context({ runId: 'run-1' }));
  expect(bridge.dispatches).toHaveLength(1);
});

it('returns a retryable result when the bridge is offline', async () => {
  bridge.close();
  await expect(execute(context())).resolves.toMatchObject({ status: 'retryable' });
});

it('does not include the bridge token in logs or final output', async () => {
  const result = await execute(context());
  expect(JSON.stringify(result)).not.toContain('test-bridge-secret');
});
```

- [ ] **Step 2: Run the focused adapter test and verify RED**

Run: `cd /opt/paperclip/source && pnpm vitest run packages/adapters/firstmate-bridge/src/server/execute.test.ts`

Expected: FAIL because the adapter does not exist.

- [ ] **Step 3: Implement the adapter**

```ts
export async function execute(ctx: AdapterExecutionContext): Promise<AdapterExecutionResult> {
  // Parse only the current assigned task/run context.
  // Build a bounded brief with task ID, run ID, title, and accepted instructions.
  // Authenticate to the bridge, dispatch once, consume matching events, and return a redacted result.
}
```

- [ ] **Step 4: Implement environment testing and UI config**

```ts
// testEnvironment validates URL syntax, TLS policy, credentials present,
// and authenticated bridge health. It never dispatches a task.
// UI stores endpoint/session policy only; runtime secret resolution comes
// from protected service environment variables.
```

- [ ] **Step 5: Run focused adapter tests and typecheck**

Run: `pnpm vitest run packages/adapters/firstmate-bridge/src/server`

Run: `pnpm --filter @paperclipai/adapter-firstmate-bridge typecheck`

Expected: all pass.

- [ ] **Step 6: Commit the adapter**

```bash
git add packages/adapters/firstmate-bridge
git commit -m "feat: add FirstMate Paperclip adapter"
```

### Task 3: Register the adapter and preserve UI availability

**Files:**
- Modify: exact Paperclip workspace/package adapter registry identified by `git grep 'openclaw-gateway'`
- Modify: `ui/src/adapters/adapter-display-registry.ts`
- Modify: `ui/src/adapters/metadata.test.ts`
- Create: `packages/adapters/firstmate-bridge/src/ui/build-config.test.ts`

**Consumes:** Task 2 adapter package and Paperclip’s existing adapter registry/display conventions.

**Produces:** A selectable `firstmate_bridge` adapter in the Paperclip agent UI, with no raw secret field exposed.

- [ ] **Step 1: Write failing registry/UI tests**

```ts
expect(adapterDisplayRegistry.firstmate_bridge).toMatchObject({
  label: 'FirstMate',
  available: true,
});
expect(buildConfig(form)).not.toHaveProperty('bridgeToken');
```

- [ ] **Step 2: Run focused UI tests and verify RED**

Run: `pnpm vitest run ui/src/adapters/metadata.test.ts packages/adapters/firstmate-bridge/src/ui/build-config.test.ts`

Expected: FAIL because FirstMate is not registered.

- [ ] **Step 3: Register the package and adapter display metadata**

```ts
firstmate_bridge: {
  label: 'FirstMate',
  description: 'Dispatch implementation work to the existing FirstMate coding crew.',
  available: true,
}
```

- [ ] **Step 4: Run full adapter/UI verification**

Run: `pnpm vitest run packages/adapters/firstmate-bridge ui/src/adapters/metadata.test.ts`

Expected: all pass.

- [ ] **Step 5: Commit registration changes**

```bash
git add ui packages
git commit -m "feat: register FirstMate in Paperclip"
```

### Task 4: Provision identities and configure the production agents

**Files:**
- Create: protected Paperclip runtime environment file on `.15`
- Create: protected FirstMate bridge credential file on `.10`
- Create: Paperclip agent record through its supported authenticated UI/API
- Modify: Paperclip service configuration only to inject the protected runtime secret

**Consumes:** Task 3 production image; Paperclip’s supported agent-key creation flow; existing runtime patterns for Hermes/OpenClaw.

**Produces:** `FirstMate` Paperclip agent, title `Implementation Lead`, reporting to OpenClaw, with a unique runtime key.

- [ ] **Step 1: Verify permissions before creating anything**

Run: inspect Paperclip agent management API/UI schema and verify the current operator identity can create an agent and scoped key without direct database writes.

Expected: supported API/UI path available; otherwise stop and request the user’s one-time UI action rather than altering the database.

- [ ] **Step 2: Create the agent and scoped runtime key**

Configuration:

```text
Name: FirstMate
Title: Implementation Lead
Reports to: OpenClaw
Adapter: firstmate_bridge
Session strategy: issue
```

Expected: a distinct agent ID and key; key stored only in protected runtime configuration.

- [ ] **Step 3: Install and validate protected configuration**

Run: verify ownership/mode, restart through the existing `paperclip.service`, and call the adapter environment test.

Expected: config files are `0600`; Paperclip health remains `ok`; adapter test passes without creating a FirstMate task.

- [ ] **Step 4: Record the operations runbook**

Document: component locations, health commands, safe restart sequence, key rotation order, offline/retry behavior, and the explicit prohibition on firewall changes.

- [ ] **Step 5: Commit only non-secret documentation/config templates**

```bash
git add docs/firstmate-paperclip-operations.md packages/adapters/firstmate-bridge
git commit -m "docs: operate FirstMate through Paperclip"
```

### Task 5: Deploy and prove the supervised workflow

**Files:**
- Modify: no versioned source unless deployment verification reveals a tested defect
- Create: Paperclip task `FirstMate integration smoke test`

**Consumes:** Active Paperclip service, FirstMate bridge, FirstMate agent, OpenClaw reviewer, Hermes coordinator.

**Produces:** Evidence that a no-change task completes through the intended chain.

- [ ] **Step 1: Build the production image**

Run: `sudo systemctl restart paperclip.service`

Expected: the service uses `/etc/paperclip/paperclip.env`; do not invoke a manual Compose command without that environment file.

- [ ] **Step 2: Verify production health and adapter discovery**

Run: authenticated Paperclip health/API checks and FirstMate adapter environment test.

Expected: health `ok`, FirstMate selectable, bridge connected, no duplicate service container.

- [ ] **Step 3: Run the bounded smoke task**

Task brief:

```text
Confirm you received this Paperclip task. Do not edit files, run write commands,
create a worktree, or contact external services. Return exactly:
FirstMate Paperclip handoff verified.
```

Expected: Hermes assigns; FirstMate reports the exact response; OpenClaw records a pass; Hermes emits a concise final summary.

- [ ] **Step 4: Verify task history and recovery behavior**

Run: replay/run retry check with the same run ID against the test fixture, inspect task audit/status history, and confirm no secret appears in resulting content or service logs.

Expected: one FirstMate dispatch; complete trace visible in Paperclip; no secret matches.

- [ ] **Step 5: Final verification and handoff**

Run: focused adapter tests, Paperclip’s relevant full test suite, production health check, and `git status --short`.

Expected: tests pass; production healthy; only intentional, committed source changes remain; user receives agent names, hierarchy, and normal task flow.
