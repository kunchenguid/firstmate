import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyRisk, enforceRiskRequest, RISK_CLASS_RULE_VERSION } from '../lib/risk-class.mjs';

test('riskClass classifier is versioned and chooses highest matching minimum', () => {
  const result = classifyRisk({
    kind: 'ship',
    operationFlags: { sharedRuntime: true, memorySchema: true },
    paths: ['memory/lib/schema.mjs']
  });
  assert.equal(result.ruleVersion, RISK_CLASS_RULE_VERSION);
  assert.equal(result.riskClass, 'critical');
  assert.ok(result.matchedRules.includes('shared-runtime-or-orchestration'));
  assert.ok(result.matchedRules.includes('memory-registry-writer-schema-activation'));
});

test('A31 no downgrade-by-label: routine label cannot lower memory schema work', () => {
  const result = classifyRisk({
    label: 'routine ship',
    kind: 'ship',
    operationFlags: { memorySchema: true },
    paths: ['memory/lib/schema.mjs']
  });
  assert.equal(result.riskClass, 'critical');
  assert.throws(() => enforceRiskRequest('standard', result), /downgrade refused/);
  const overridden = enforceRiskRequest('standard', result, { captainOverrideToken: 'CAPTAIN-OVERRIDE' });
  assert.equal(overridden.override.captainOverrideToken, 'CAPTAIN-OVERRIDE');
});

test('missing, ambiguous, unrecognized flags default upward to critical', () => {
  assert.equal(classifyRisk({}).riskClass, 'critical');
  assert.equal(classifyRisk({ inspected: false }).riskClass, 'critical');
  assert.equal(classifyRisk({ operationFlags: { surprisingNewFlag: true } }).riskClass, 'critical');
});

test('FirstMate may raise a classification without override', () => {
  const result = classifyRisk({ kind: 'scout', readOnly: true });
  assert.equal(result.riskClass, 'low');
  assert.equal(enforceRiskRequest('high', result).riskClass, 'high');
});
