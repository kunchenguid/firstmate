import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, snapshotRegistry } from '../lib/registry.mjs';
import { sha256 } from '../lib/hash.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { runMemIn, spawnMemIn, tmpRegistry } from './helpers.mjs';

test('snapshot filename is derived from seq + hash and stays inside the snapshots dir', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'snapshot me' } });
  const { file } = snapshotRegistry(dir);
  const resolved = path.resolve(file);
  assert.equal(path.dirname(resolved), path.resolve(paths.snapshots));
  assert.match(path.basename(resolved), /^registry-\d+-manual-[0-9a-f]{16}\.json$/);
  assert.ok(fs.existsSync(resolved));
  assert.equal(fs.statSync(resolved).mode & 0o777, 0o600);
  const snapshot = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  assert.equal(snapshot.reason, 'manual');
  assert.equal(snapshot.registryHash, snapshot.registry.registryHash);
  assert.match(snapshot.snapshotHash, /^[0-9a-f]{64}$/);
});

test('a hostile event ID cannot traverse out of the snapshots directory', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  // Inject a malicious event ID directly into the ledger.
  await appendRegistryEvent(dir, {
    event: 'proposed',
    eventId: '../../../../tmp/evil-snapshot',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'path traversal fixture' }
  });
  const { file } = snapshotRegistry(dir);
  const resolved = path.resolve(file);
  assert.ok(resolved.startsWith(path.resolve(paths.snapshots) + path.sep), 'snapshot must resolve inside the snapshots dir');
  assert.equal(fs.existsSync('/tmp/evil-snapshot.json'), false);
  assert.match(path.basename(resolved), /^registry-\d+-manual-[0-9a-f]{16}\.json$/);
});

test('snapshot is written atomically (no leftover temp files)', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'atomic snapshot' } });
  snapshotRegistry(dir);
  const leftovers = fs.readdirSync(paths.snapshots).filter((name) => name.includes('.tmp-'));
  assert.deepEqual(leftovers, []);
});

async function appendMany(dir, start, end) {
  for (let i = start; i <= end; i += 1) {
    await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: `snapshot boundary ${i}` } });
  }
}

function boundarySnapshotNames(paths, seq = 500) {
  return fs.readdirSync(paths.snapshots).filter((name) => name.includes(`automatic-${seq}-event-boundary`) && name.endsWith('.json')).sort();
}

function boundarySnapshotFile(paths, seq = 500) {
  const names = boundarySnapshotNames(paths, seq);
  assert.equal(names.length, 1, `expected one active boundary snapshot for ${seq}`);
  return path.join(paths.snapshots, names[0]);
}

async function boundaryFixture() {
  const dir = tmpRegistry();
  await appendMany(dir, 1, 500);
  assert.equal(boundarySnapshotNames(registryPaths(dir)).length, 1);
  assert.equal(auditRegistry(dir).ok, true);
  return dir;
}

function cloneRegistry(src) {
  const dst = tmpRegistry();
  fs.rmSync(dst, { recursive: true, force: true });
  fs.cpSync(src, dst, { recursive: true });
  return dst;
}

function rewriteSnapshot(paths, mutate) {
  const file = boundarySnapshotFile(paths);
  const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(snapshot);
  fs.writeFileSync(file, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
  return file;
}

async function assertNextMutationRepairs(dir, label) {
  const paths = registryPaths(dir);
  const beforeSeq = foldRegistry(dir).watermark.seq;
  const beforeBytes = fs.readFileSync(paths.registry);
  const result = await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'snap-test' },
    fields: { summary: `${label} event ${beforeSeq + 1}` }
  });
  assert.equal(result.skipped, false);
  assert.equal(foldRegistry(dir).watermark.seq, beforeSeq + 1);
  assert.equal(fs.readFileSync(paths.registry).subarray(0, beforeBytes.length).equals(beforeBytes), true, 'repair preserves prior canonical bytes');
  assert.equal(boundarySnapshotNames(paths).length, 1, 'exactly one active boundary snapshot remains');
  assert.equal(auditRegistry(dir).ok, true);
  const doctor = runMemIn(dir, ['doctor', '--json']);
  assert.equal(doctor.status, 0, doctor.stderr || doctor.stdout);
  assert.equal(JSON.parse(doctor.stdout).ok, true);
}

test('automatic snapshots are created once at every 500-event boundary', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendMany(dir, 1, 499);
  assert.deepEqual(fs.existsSync(paths.snapshots) ? fs.readdirSync(paths.snapshots) : [], []);

  await appendMany(dir, 500, 500);
  const at500 = fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary'));
  assert.equal(at500.length, 1);
  const afterFold = foldRegistry(dir);
  assert.equal(afterFold.watermark.seq, 500);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1);

  await appendMany(dir, 501, 1000);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-1000-event-boundary')).length, 1);
});

test('failed automatic boundary snapshot creates repairable exactly-once debt', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendMany(dir, 1, 499);
  const event500 = { event: 'proposed', eventId: 'event-500-fixed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'snapshot boundary 500' } };

  const old = process.env.MEM_SNAPSHOT_FAIL;
  process.env.MEM_SNAPSHOT_FAIL = '1';
  try {
    await assert.rejects(appendRegistryEvent(dir, event500), /snapshot failure/);
  } finally {
    if (old === undefined) delete process.env.MEM_SNAPSHOT_FAIL;
    else process.env.MEM_SNAPSHOT_FAIL = old;
  }

  assert.equal(foldRegistry(dir).watermark.seq, 500, 'event 500 remains committed');
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 0);
  assert.equal(fs.existsSync(paths.snapshotState), true, 'snapshot obligation is durable');
  let state = JSON.parse(fs.readFileSync(paths.snapshotState, 'utf8'));
  assert.equal(state.obligations[0].boundarySeq, 500);
  assert.equal(state.obligations[0].status, 'failed');

  const auditDuringDebt = auditRegistry(dir);
  assert.equal(auditDuringDebt.ok, false);
  assert.equal(auditDuringDebt.registry.health, 'ok');
  assert.equal(auditDuringDebt.snapshots.health, 'degraded');
  assert.equal(auditDuringDebt.snapshots.outstanding[0].boundarySeq, 500);
  const doctorDuringDebt = runMemIn(dir, ['doctor', '--json']);
  assert.equal(doctorDuringDebt.status, 1);
  assert.equal(JSON.parse(doctorDuringDebt.stdout).snapshots.outstanding[0].boundarySeq, 500);

  const retry = await appendRegistryEvent(dir, event500);
  assert.equal(retry.skipped, true, 'idempotent retry skips the already-committed event');
  const boundarySnapshots = fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary'));
  assert.equal(boundarySnapshots.length, 1, 'retry repairs exactly one boundary snapshot');
  state = JSON.parse(fs.readFileSync(paths.snapshotState, 'utf8'));
  assert.equal(state.obligations[0].status, 'complete');
  assert.equal(auditRegistry(dir).ok, true);

  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'snapshot boundary 501' } });
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1, 'later mutation does not duplicate repaired snapshot');
});

test('a later mutation repairs missing boundary snapshot debt before appending', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendMany(dir, 1, 499);
  const old = process.env.MEM_SNAPSHOT_FAIL;
  process.env.MEM_SNAPSHOT_FAIL = '1';
  try {
    await assert.rejects(
      appendRegistryEvent(dir, { event: 'proposed', eventId: 'event-500-later-repair', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'snapshot boundary 500' } }),
      /snapshot failure/
    );
  } finally {
    if (old === undefined) delete process.env.MEM_SNAPSHOT_FAIL;
    else process.env.MEM_SNAPSHOT_FAIL = old;
  }
  assert.equal(auditRegistry(dir).snapshots.outstanding[0].boundarySeq, 500);

  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'snapshot boundary 501' } });
  assert.equal(foldRegistry(dir).watermark.seq, 501);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1);
  assert.equal(auditRegistry(dir).ok, true);
});

test('QA4: corrupt completed boundary snapshotHash is repaired before event 501 appends', async () => {
  const dir = await boundaryFixture();
  const paths = registryPaths(dir);
  const beforeRegistry = fs.readFileSync(paths.registry);
  rewriteSnapshot(paths, (snapshot) => {
    snapshot.snapshotHash = '0'.repeat(64);
  });

  const auditBefore = auditRegistry(dir);
  assert.equal(auditBefore.ok, false);
  assert.equal(auditBefore.snapshots.health, 'degraded');
  assert.match(auditBefore.snapshots.issues.join('\n'), /invalid boundary snapshot for sequence 500/);
  assert.match(auditBefore.snapshots.issues.join('\n'), /snapshot hash mismatch/);
  assert.equal(auditBefore.snapshots.outstanding[0].boundarySeq, 500);

  await assertNextMutationRepairs(dir, 'qa4');
  assert.equal(fs.readFileSync(paths.registry).subarray(0, beforeRegistry.length).equals(beforeRegistry), true);
  const corruptEvidence = fs.readdirSync(path.join(paths.snapshots, 'corrupt'));
  assert.equal(corruptEvidence.length, 1, 'corrupt original is preserved as evidence');
});

test('shared boundary snapshot validator rejects corruption variants before repair', async () => {
  const base = await boundaryFixture();
  const variants = [
    ['payload modified while stored hash is unchanged', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.records[0].summary = 'tampered payload';
      });
    }, /snapshot records do not match boundary fold|snapshot hash mismatch/],
    ['stored hash modified while payload is unchanged', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.snapshotHash = 'f'.repeat(64);
      });
    }, /snapshot hash mismatch/],
    ['snapshot file missing despite complete obligation', (paths) => {
      fs.unlinkSync(boundarySnapshotFile(paths));
    }, /required boundary snapshot missing/],
    ['malformed JSON', (paths) => {
      fs.writeFileSync(boundarySnapshotFile(paths), '{not json\n');
    }, /snapshot is not valid JSON/],
    ['missing required snapshot field', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        delete snapshot.schema;
      });
    }, /snapshot required field missing: schema/],
    ['wrong sequence', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.registry.seq = 499;
      });
    }, /snapshot registry seq mismatch/],
    ['wrong event ID', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.registry.eventId = 'wrong-event';
      });
    }, /snapshot registry eventId mismatch/],
    ['wrong registry hash', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.registry.registryHash = '1'.repeat(64);
        snapshot.registryHash = '1'.repeat(64);
      });
    }, /snapshot registry hash mismatch|snapshot registryHash mismatch/],
    ['wrong snapshot reason', (paths) => {
      rewriteSnapshot(paths, (snapshot) => {
        snapshot.reason = 'manual';
      });
    }, /snapshot reason mismatch/],
    ['obligation path points outside the snapshot directory', (paths) => {
      const state = JSON.parse(fs.readFileSync(paths.snapshotState, 'utf8'));
      state.obligations[0].expectedSnapshot = '../outside.json';
      fs.writeFileSync(paths.snapshotState, `${JSON.stringify(state, null, 2)}\n`);
    }, /expectedSnapshot escapes snapshots directory|expectedSnapshot mismatch/],
    ['unreadable snapshot artifact', (paths) => {
      fs.chmodSync(boundarySnapshotFile(paths), 0o000);
    }, /snapshot file is not readable|snapshot file mode must be 600/],
    ['non-regular snapshot artifact', (paths) => {
      const file = boundarySnapshotFile(paths);
      fs.unlinkSync(file);
      fs.mkdirSync(file);
    }, /snapshot file is not a regular file/]
  ];

  for (const [label, corrupt, issuePattern] of variants) {
    const dir = cloneRegistry(base);
    const paths = registryPaths(dir);
    try {
      corrupt(paths);
      const audit = auditRegistry(dir);
      assert.equal(audit.ok, false, label);
      assert.equal(audit.snapshots.health, 'degraded', label);
      assert.match(audit.snapshots.issues.join('\n'), issuePattern, label);
      await assertNextMutationRepairs(dir, label);
    } finally {
      const file = boundarySnapshotNames(paths).length === 1 ? boundarySnapshotFile(paths) : null;
      if (file) fs.chmodSync(file, 0o600);
    }
  }
});

test('corrupt boundary snapshot is repaired by idempotent retry and explicit snapshot', async () => {
  const retryDir = await boundaryFixture();
  const retryPaths = registryPaths(retryDir);
  rewriteSnapshot(retryPaths, (snapshot) => {
    snapshot.records[0].summary = 'tampered before retry';
  });
  const retry = await appendRegistryEvent(retryDir, {
    event: 'proposed',
    eventId: foldRegistry(retryDir).events.at(-1).eventId,
    actor: { kind: 'firstmate', id: 'snap-test' },
    fields: { summary: 'snapshot boundary 500' }
  });
  assert.equal(retry.skipped, true);
  assert.equal(foldRegistry(retryDir).watermark.seq, 500);
  assert.equal(boundarySnapshotNames(retryPaths).length, 1);
  assert.equal(auditRegistry(retryDir).ok, true);

  const explicitDir = await boundaryFixture();
  const explicitPaths = registryPaths(explicitDir);
  rewriteSnapshot(explicitPaths, (snapshot) => {
    snapshot.snapshotHash = 'a'.repeat(64);
  });
  const corruptBytes = fs.readFileSync(boundarySnapshotFile(explicitPaths));
  const beforeRegistry = sha256(fs.readFileSync(explicitPaths.registry));
  const repaired = snapshotRegistry(explicitDir);
  assert.match(path.basename(repaired.file), /^registry-500-manual-[0-9a-f]{16}\.json$/);
  assert.equal(boundarySnapshotNames(explicitPaths).length, 1);
  assert.equal(sha256(fs.readFileSync(explicitPaths.registry)), beforeRegistry);
  assert.equal(auditRegistry(explicitDir).ok, true);
  const evidenceFile = path.join(explicitPaths.snapshots, 'corrupt', fs.readdirSync(path.join(explicitPaths.snapshots, 'corrupt'))[0]);
  assert.equal(fs.readFileSync(evidenceFile).equals(corruptBytes), true, 'quarantine preserves corrupt artifact bytes');
});

test('repair failure blocks mutation and leaves canonical sequence unchanged', async () => {
  const dir = await boundaryFixture();
  const paths = registryPaths(dir);
  rewriteSnapshot(paths, (snapshot) => {
    snapshot.snapshotHash = 'b'.repeat(64);
  });
  const beforeSeq = foldRegistry(dir).watermark.seq;
  const beforeHash = sha256(fs.readFileSync(paths.registry));
  const old = process.env.MEM_SNAPSHOT_FAIL;
  process.env.MEM_SNAPSHOT_FAIL = '1';
  try {
    await assert.rejects(
      appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'must not append' } }),
      /snapshot failure/
    );
  } finally {
    if (old === undefined) delete process.env.MEM_SNAPSHOT_FAIL;
    else process.env.MEM_SNAPSHOT_FAIL = old;
  }
  assert.equal(foldRegistry(dir).watermark.seq, beforeSeq);
  assert.equal(sha256(fs.readFileSync(paths.registry)), beforeHash);
  assert.equal(auditRegistry(dir).ok, false);
  assert.equal(fs.readdirSync(path.join(paths.snapshots, 'corrupt')).length, 1);
});

test('validator parity: audit, doctor, mutation, snapshot, and index rebuild consume the same corrupt boundary result', async () => {
  const base = await boundaryFixture();
  const consumers = [
    ['mutation preflight', async (dir) => {
      await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'parity mutation' } });
    }],
    ['explicit snapshot', async (dir) => {
      snapshotRegistry(dir);
    }],
    ['index rebuild', async (dir) => {
      buildActiveIndex(dir);
    }]
  ];

  for (const [label, consume] of consumers) {
    const dir = cloneRegistry(base);
    const paths = registryPaths(dir);
    rewriteSnapshot(paths, (snapshot) => {
      snapshot.snapshotHash = 'c'.repeat(64);
    });
    const audit = auditRegistry(dir);
    assert.equal(audit.ok, false, `${label} audit must classify corrupt fixture invalid`);
    assert.match(audit.snapshots.issues.join('\n'), /snapshot hash mismatch/, label);
    const doctor = runMemIn(dir, ['doctor', '--json']);
    assert.equal(doctor.status, 1, label);
    assert.match(JSON.parse(doctor.stdout).snapshots.issues.join('\n'), /snapshot hash mismatch/, label);
    await consume(dir);
    assert.equal(auditRegistry(dir).ok, true, `${label} repairs through shared validator path`);
  }
});

test('concurrent corrupt snapshot repair produces one replacement and no lost writes', async () => {
  const dir = await boundaryFixture();
  const paths = registryPaths(dir);
  rewriteSnapshot(paths, (snapshot) => {
    snapshot.snapshotHash = 'd'.repeat(64);
  });
  const N = 12;
  const results = await Promise.all(
    Array.from({ length: N }, (_, i) => spawnMemIn(dir, ['propose', '--summary', `concurrent repair ${i}`, '--json']))
  );
  assert.equal(results.filter((result) => result.code === 0).length, N, results.map((result) => result.stderr || result.stdout).join('\n'));
  assert.equal(foldRegistry(dir).watermark.seq, 500 + N);
  assert.equal(boundarySnapshotNames(paths).length, 1);
  assert.equal(auditRegistry(dir).ok, true);
  assert.equal(fs.readdirSync(path.join(paths.snapshots, 'corrupt')).length, 1);
});

test('explicit index rebuild creates a pre-rebuild snapshot and preserves canonical bytes', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'pre rebuild' } });
  const before = sha256(fs.readFileSync(paths.registry));
  buildActiveIndex(dir);
  const names = fs.readdirSync(paths.snapshots);
  assert.equal(names.filter((name) => name.includes('pre-index-rebuild')).length, 1);
  assert.equal(sha256(fs.readFileSync(paths.registry)), before);
});

test('snapshot-write failure blocks explicit index rebuild', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'blocked rebuild' } });
  const beforeIndex = fs.existsSync(paths.index) ? fs.readFileSync(paths.index, 'utf8') : null;
  const old = process.env.MEM_SNAPSHOT_FAIL;
  process.env.MEM_SNAPSHOT_FAIL = '1';
  try {
    assert.throws(() => buildActiveIndex(dir), /snapshot failure/);
  } finally {
    if (old === undefined) delete process.env.MEM_SNAPSHOT_FAIL;
    else process.env.MEM_SNAPSHOT_FAIL = old;
  }
  const afterIndex = fs.existsSync(paths.index) ? fs.readFileSync(paths.index, 'utf8') : null;
  assert.equal(afterIndex, beforeIndex);
});
