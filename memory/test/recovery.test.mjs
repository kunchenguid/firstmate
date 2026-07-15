import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, recoverRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { sha256 } from '../lib/hash.mjs';
import { withRegistryLock } from '../lib/lock.mjs';
import { tmpRegistry } from './helpers.mjs';

test('rewritten A20: canonical corruption blocks mutations but reads through last valid event', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, {
    event: 'proposed',
    eventId: 'valid-1',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'valid event before corrupt tail' }
  });
  const originalValid = fs.readFileSync(paths.registry);
  fs.appendFileSync(paths.registry, '{"schema":"kraken-memory/registry-event/v1","eventId":"partial"');
  const originalCorrupt = fs.readFileSync(paths.registry);
  const fold = foldRegistry(dir);
  assert.equal(fold.health, 'critical');
  assert.equal(fold.events.length, 1);
  assert.equal(fold.records.get('MEM-0001').summary, 'valid event before corrupt tail');
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'proposed',
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: 'must not append while critical' }
    }),
    /CRITICAL/
  );
  assert.equal(sha256(fs.readFileSync(paths.registry)), sha256(originalCorrupt));
  const result = await recoverRegistry(dir);
  assert.ok(fs.existsSync(result.backup));
  assert.ok(fs.existsSync(result.sidecar));
  assert.equal(sha256(fs.readFileSync(result.backup)), sha256(originalCorrupt));
  assert.equal(fs.readFileSync(result.sidecar, 'utf8'), '{"schema":"kraken-memory/registry-event/v1","eventId":"partial"');
  assert.equal(fs.readFileSync(paths.registry, 'utf8'), originalValid.toString('utf8'));
  assert.equal(auditRegistry(dir).registry.health, 'ok');
  assert.equal(auditRegistry(dir).activeIndex.status, 'current');
  assert.equal(result.recoveryEvent.event, 'registry_recovered');
  assert.ok(result.recoveryEvent.eventId);
  assert.equal(JSON.parse(fs.readFileSync(result.recoveryStateFile, 'utf8')).currentStage, 'completed');
});

test('recovery preserves arbitrary corrupt bytes byte-for-byte in the sidecar', async () => {
  // Reproduces the QA binary-fidelity failure: invalid UTF-8 (ff fe 80) and a NUL
  // byte must be preserved exactly, never mangled into U+FFFD replacement chars.
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'valid before binary corruption' } });
  const validBytes = fs.readFileSync(paths.registry);
  const corrupt = Buffer.from([0xff, 0xfe, 0x80, 0x00, 0x41]);
  fs.appendFileSync(paths.registry, corrupt);
  const originalHash = sha256(fs.readFileSync(paths.registry));

  const result = await recoverRegistry(dir);
  const sidecarBytes = fs.readFileSync(result.sidecar);
  assert.equal(sidecarBytes.toString('hex'), corrupt.toString('hex'), 'sidecar bytes must match the corrupt suffix exactly');
  assert.equal(result.sidecarHash, sha256(corrupt));
  // backup is the exact original; repaired registry is the exact valid prefix.
  assert.equal(result.originalHash, originalHash);
  assert.equal(sha256(fs.readFileSync(result.backup)), originalHash);
  assert.equal(sha256(fs.readFileSync(paths.registry)), sha256(validBytes));
  assert.equal(auditRegistry(dir).ok, true);
});

test('recovery is durable across every failpoint: partial recovery is diagnosable and re-runnable', async () => {
  const stages = [
    'before-backup', 'after-backup', 'after-sidecar', 'after-repaired-write',
    'before-validation', 'before-rename', 'after-rename', 'before-recovery-event',
    'after-recovery-activity', 'before-index-rebuild', 'after-index-rebuild',
    'before-final-audit'
  ];
  for (const stage of stages) {
    const dir = tmpRegistry();
    const paths = registryPaths(dir);
    await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: `failpoint ${stage}` } });
    const validBytes = fs.readFileSync(paths.registry);
    fs.appendFileSync(paths.registry, '{bad-tail');
    const corruptHash = sha256(fs.readFileSync(paths.registry));

    await assert.rejects(recoverRegistry(dir, { failpoints: [stage] }), /recovery failpoint/);
    const incompleteAudit = auditRegistry(dir);
    assert.equal(incompleteAudit.ok, false, `${stage}: incomplete recovery cannot audit green`);
    assert.equal(incompleteAudit.registry.health, 'recovery_incomplete', `${stage}: health exposes incomplete recovery`);
    await assert.rejects(
      appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'blocked during recovery' } }),
      /recovery is incomplete|CRITICAL/,
      `${stage}: ordinary mutations remain blocked`
    );

    // Before the atomic rename the canonical file is untouched (still CRITICAL,
    // re-runnable). After the rename it is the repaired valid prefix.
    const preRename = ['before-backup', 'after-backup', 'after-sidecar', 'after-repaired-write', 'before-validation', 'before-rename'].includes(stage);
    const registryNow = fs.readFileSync(paths.registry);
    if (preRename) {
      assert.equal(sha256(registryNow), corruptHash, `${stage}: canonical file must be untouched before rename`);
      assert.equal(foldRegistry(dir).health, 'critical');
    } else {
      assert.equal(sha256(registryNow), sha256(validBytes), `${stage}: canonical file is the repaired valid prefix after rename`);
    }
    const completed = await recoverRegistry(dir);
    assert.equal(auditRegistry(dir).ok, true, `${stage}: recovery is resumable`);
    assert.ok(completed.recoveryEvent.eventId, `${stage}: durable recovery event exists`);
    const marker = JSON.parse(fs.readFileSync(completed.recoveryStateFile, 'utf8'));
    assert.equal(marker.currentStage, 'completed');
    assert.ok(marker.completedAt);
  }
});

test('recovery refuses when the registry is healthy', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'healthy registry' } });
  await assert.rejects(recoverRegistry(dir), /not CRITICAL/);
});

test('recovery refuses while another writer owns the lock', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'valid event before active lock' } });
  fs.appendFileSync(paths.registry, '{bad');
  await assert.rejects(
    withRegistryLock(paths.lock, async () => {
      await recoverRegistry(dir, { lock: { waitMs: 100 } });
    }),
    /registry lock is held/
  );
});

test('index rebuild refuses a critical registry and never repairs canonical bytes', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'valid before index refusal' } });
  fs.appendFileSync(paths.registry, '{bad');
  const before = sha256(fs.readFileSync(paths.registry));
  assert.throws(() => buildActiveIndex(dir), /CRITICAL/);
  assert.equal(sha256(fs.readFileSync(paths.registry)), before);
});
