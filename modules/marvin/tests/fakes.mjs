export function fakes(inputs, now = Date.parse('2026-09-11T00:00:00Z')) {
  const events = [], frames = [], sleeps = [];
  let instant = now;
  return { events, frames, sleeps,
    source: { async read() { events.push('read'); return structuredClone(inputs); } },
    clock: { now: () => instant, async sleep(ms) { sleeps.push(ms); instant += ms; events.push('sleep'); } },
    renderer: { render(frame) { frames.push(frame); events.push('render'); } },
    telemetry: { append(event, details) { events.push([event, details]); }, read() { return []; } },
  };
}
export const provider = { provider: 'claude', plan: 'max', source: 'oauth',
  account: { email: 'private@example.test' }, windows: [
    { id: 'weekly', label: '7D ALL', percentRemaining: 36, resetsAt: '2026-09-12T00:00:00Z', windowSeconds: 172800 },
  ] };
