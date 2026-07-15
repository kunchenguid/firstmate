import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { classifyRisk, enforceRiskRequest, enforceRiskRequestDurably, RISK_CLASS_RULE_VERSION } from '../lib/risk-class.mjs';
import { auditActivity, activityFile } from '../lib/activity.mjs';
import { tmpRegistry } from './helpers.mjs';

// A fully-inspected implementation touching a given path set, so path/inspection
// fail-safes do not fire and we isolate the minimum-rule under test.
function inspected(extra) {
  return { kind: 'ship', inspected: true, paths: ['src/x.js'], ...extra };
}

test('classifier is versioned and chooses the highest matching minimum', () => {
  const result = classifyRisk(inspected({ operationFlags: { sharedRuntime: true, memorySchema: true }, paths: ['memory/lib/schema.mjs'] }));
  assert.equal(result.ruleVersion, RISK_CLASS_RULE_VERSION);
  assert.equal(result.riskClass, 'critical');
  assert.ok(result.matchedRules.includes('shared-runtime-or-orchestration'));
  assert.ok(result.matchedRules.includes('memory-registry-writer-schema-activation'));
});

test('every minimum-risk rule row yields at least its minimum', () => {
  assert.equal(classifyRisk({ kind: 'scout', readOnly: true }).riskClass, 'low');
  assert.equal(classifyRisk(inspected()).riskClass, 'standard'); // normal isolated implementation
  assert.equal(classifyRisk(inspected({ operationFlags: { sharedRuntime: true } })).riskClass, 'high');
  assert.equal(classifyRisk(inspected({ operationFlags: { destructive: true } })).riskClass, 'high');
  assert.equal(classifyRisk(inspected({ operationFlags: { migration: true } })).riskClass, 'critical');
  assert.equal(classifyRisk(inspected({ operationFlags: { memoryRegistry: true } })).riskClass, 'critical');
  assert.equal(classifyRisk(inspected({ operationFlags: { historyRewrite: true } })).riskClass, 'critical');
  assert.equal(classifyRisk({ kind: 'landing', inspected: true, paths: ['x'] }).riskClass, 'critical');
  assert.equal(classifyRisk({ kind: 'qa', inspected: true, paths: ['x'] }).riskClass, 'critical');
  assert.equal(classifyRisk(inspected({ operationFlags: { credential: true } })).riskClass, 'critical');
});

test('fail-safe: missing, uninspected, empty-paths, and unknown-flag inputs default UP to critical', () => {
  assert.equal(classifyRisk({}).riskClass, 'critical', 'missing metadata');
  assert.equal(classifyRisk({ inspected: false }).riskClass, 'critical', 'explicit uninspected');
  assert.equal(classifyRisk({ kind: 'ship' }).riskClass, 'critical', 'ship with no inspection evidence');
  assert.equal(classifyRisk({ kind: 'ship', inspected: true, paths: [] }).riskClass, 'critical', 'inspected but empty path list');
  assert.equal(classifyRisk({ kind: 'ship', inspected: true, paths: ['x'], operationFlags: { surprisingNewFlag: true } }).riskClass, 'critical', 'unknown operation flag');
  // A pure read-only scout is exempt from the inspection fail-safe.
  assert.equal(classifyRisk({ kind: 'scout', readOnly: true }).riskClass, 'low');
});

test('conflicting rules resolve to the highest applicable class', () => {
  const result = classifyRisk(inspected({ operationFlags: { sharedRuntime: true, migration: true } }));
  assert.equal(result.riskClass, 'critical');
});

test('A31 no downgrade-by-label: routine label cannot lower memory-schema work', () => {
  const result = classifyRisk({ label: 'routine ship', kind: 'ship', inspected: true, operationFlags: { memorySchema: true }, paths: ['memory/lib/schema.mjs'] });
  assert.equal(result.riskClass, 'critical');
  assert.throws(() => enforceRiskRequest('standard', result), /downgrade refused/);
});

test('FirstMate may raise a classification without an override', () => {
  const result = classifyRisk({ kind: 'scout', readOnly: true });
  assert.equal(result.riskClass, 'low');
  assert.equal(enforceRiskRequest('high', result).riskClass, 'high');
});

test('a Captain token without durable logging does not make a downgrade effective', () => {
  const RAW = 'CAPTAIN-RAW-SECRET-TOKEN';
  const result = classifyRisk({ kind: 'ship', inspected: true, paths: ['memory/lib/x.mjs'], operationFlags: { memorySchema: true } });
  assert.equal(result.riskClass, 'critical');
  assert.throws(
    () => enforceRiskRequest('standard', result, { captainOverrideToken: RAW, reason: 'captain approved' }),
    /durable Captain override log required/
  );
});

test('a Captain-authorized downgrade persists a durable activity event and never leaks the raw token', async () => {
  const dir = tmpRegistry();
  const RAW = 'CAPTAIN-RAW-SECRET-TOKEN';
  const result = classifyRisk({ kind: 'ship', inspected: true, paths: ['memory/lib/x.mjs'], operationFlags: { memorySchema: true } });
  assert.equal(result.riskClass, 'critical');
  const overridden = await enforceRiskRequestDurably('standard', result, { activityDir: dir, captainOverrideToken: RAW, reason: 'captain approved', taskId: 'memory-pr1-fix-f2' });
  // The downgrade is actually applied...
  assert.equal(overridden.riskClass, 'standard');
  assert.equal(overridden.appliedClass, 'standard');
  // ...the computed minimum is retained...
  assert.equal(overridden.computedMinimum, 'critical');
  // ...an opaque reference is recorded (not the raw token)...
  assert.match(overridden.override.ref, /^ovr-[0-9a-f]{16}$/);
  assert.equal(overridden.override.captainAuthorization, overridden.override.ref);
  assert.match(overridden.override.eventId, /^[0-9a-f-]{36}$/);
  assert.equal(overridden.override.reason, 'captain approved');
  // ...and NO sensitive override material appears anywhere in the output.
  assert.equal(JSON.stringify(overridden).includes(RAW), false);
  const activity = fs.readFileSync(activityFile(dir), 'utf8');
  const event = JSON.parse(activity.trim());
  assert.equal(event.task, 'memory-pr1-fix-f2');
  assert.equal(activity.includes(RAW), false);
  assert.ok(activity.includes(overridden.override.eventId));
  assert.ok(activity.includes('"computedMinimum":"critical"'));
  assert.ok(activity.includes('"appliedRisk":"standard"'));
  assert.equal(auditActivity(dir).health, 'ok');
});

test('Captain downgrade requires a valid non-empty task ID before persistence or application', async () => {
  const RAW = 'CAPTAIN-RAW-SECRET-TOKEN';
  const result = classifyRisk({ kind: 'ship', inspected: true, paths: ['memory/lib/x.mjs'], operationFlags: { memorySchema: true } });
  const invalid = [
    {},
    { taskId: null },
    { taskId: '' },
    { taskId: '   ' },
    { taskId: '../malformed task' }
  ];
  for (const extra of invalid) {
    const dir = tmpRegistry();
    await assert.rejects(
      enforceRiskRequestDurably('standard', result, {
        activityDir: dir,
        captainOverrideToken: RAW,
        reason: 'missing task probe',
        ...extra
      }),
      (error) => {
        assert.equal(error.code, 'RISK_DOWNGRADE_TASK_REQUIRED');
        return /valid taskId required/.test(error.message);
      }
    );
    assert.equal(fs.existsSync(activityFile(dir)), false, `no risk override event for ${JSON.stringify(extra)}`);
  }
});

test('activity-write failure refuses a Captain downgrade', async () => {
  const result = classifyRisk({ kind: 'ship', inspected: true, paths: ['memory/lib/x.mjs'], operationFlags: { memorySchema: true } });
  await assert.rejects(
    enforceRiskRequestDurably('standard', result, {
      activityDir: tmpRegistry(),
      captainOverrideToken: 'TOKEN',
      taskId: 'memory-pr1-fix-f3',
      appendActivityFn: async () => { throw new Error('disk full'); }
    }),
    /failed to persist Captain override/
  );
});
