import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { ACTIVITY_SCHEMA, validateActivityEvent } from './schema.mjs';

export function activityFile(dir, date = new Date()) {
  const ym = date.toISOString().slice(0, 7);
  return path.join(dir, `memory-activity-${ym}.jsonl`);
}

export function appendActivity(dir, event) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
  const row = validateActivityEvent({
    schema: ACTIVITY_SCHEMA,
    eventId: event.eventId || crypto.randomUUID(),
    ts: event.ts || new Date().toISOString(),
    actor: { kind: 'mem', id: 'memory-cli' },
    detail: {},
    ...event
  });
  const file = activityFile(dir, new Date(row.ts));
  const line = `${JSON.stringify(row)}\n`;
  const fd = fs.openSync(file, 'a', 0o600);
  try {
    fs.writeFileSync(fd, line);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  return row;
}
