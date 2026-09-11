import fs from 'node:fs';
import path from 'node:path';

export function telemetry(home, clock) {
  const directory = path.join(home, 'state/marvin/telemetry');
  const maxBytes = 512 * 1024;
  let prunedDay;
  const isDaily = name => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name);
  return {
    append(event, details = {}) {
      const ts = new Date(clock.now()).toISOString();
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
      const day = ts.slice(0, 10), file = path.join(directory, `${day}.jsonl`);
      if (prunedDay !== day) {
        const cutoff = new Date(clock.now() - 7 * 86400000).toISOString().slice(0, 10);
        for (const name of fs.readdirSync(directory)) if (isDaily(name) && name.slice(0, 10) < cutoff) fs.unlinkSync(path.join(directory, name));
        prunedDay = day;
      }
      const line = JSON.stringify({ ts, module: 'marvin', event,
        requestId: null, threadId: null, actor: 'marvin', inputs: { ids: [], bytes: null }, decision: null,
        reasons: [], stepsMs: {}, model: null, harness: null, effort: null, tokens: null, cost: null,
        outcome: null, evidencePath: null, counters: {}, ...details }) + '\n';
      if (Buffer.byteLength(line) > maxBytes / 2) throw Error('Telemetry record exceeds size budget');
      // Stop recording at the daily cap; never rewrite records another observer may be appending.
      if (fs.existsSync(file) && fs.statSync(file).size + Buffer.byteLength(line) > maxBytes) return;
      fs.appendFileSync(file, line, { mode: 0o600 });
    },
    read(since, event = 'sample') {
      if (!fs.existsSync(directory)) return [];
      const records = [];
      for (const name of fs.readdirSync(directory).sort()) {
        if (!isDaily(name) || name.slice(0, 10) < new Date(since).toISOString().slice(0, 10)) continue;
        const lines = fs.readFileSync(path.join(directory, name), 'utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
          if (!lines[i]) continue;
          try {
            const row = JSON.parse(lines[i]);
            if (Date.parse(row.ts) >= since && Date.parse(row.ts) <= clock.now() && (event === 'all' || row.event === event)) {
              records.push(event === 'all' ? { event: row.event, outcome: row.outcome } : row);
            }
          } catch {
            // A concurrent append may leave only the final line incomplete.
            if (i !== lines.length - 1) throw Error(`Malformed telemetry: ${name}:${i + 1}`);
          }
        }
      }
      return records;
    },
  };
}
