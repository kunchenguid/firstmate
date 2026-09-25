#!/usr/bin/env node
// Bounded T3 shell subscription. Arguments: timeout-seconds thread-id...
// Connection comes from FM_T3CODE_ORIGIN or FM_T3CODE_RUNTIME_FILE and
// FM_T3CODE_TOKEN_FILE. Credentials never ride argv or output.
// Prints subscribed, then tab-separated thread/project/session/pending/instance
// rows. Exit 0 means a synchronized stream lasted the budget; 2 means fallback.
const fs = require('node:fs');
const [seconds, ...ids] = process.argv.slice(2);
const wanted = new Set(ids);
let socket;
let synchronized = false;
const finish = (code) => {
  if (socket) socket.close();
  process.exit(code);
};
if (!(Number(seconds) > 0) || !wanted.size || typeof WebSocket !== 'function') finish(2);
setTimeout(() => finish(synchronized ? 0 : 2), Number(seconds) * 1000);
process.on('SIGTERM', () => finish(2));
process.stdout.on('error', () => finish(2));
const clean = (value) => String(value ?? '').replace(/[\t\r\n]/g, ' ');
function row(thread) {
  if (!thread || !wanted.has(thread.id)) return;
  const pending = thread.hasPendingApprovals === true || thread.hasPendingUserInput === true;
  const status = thread.archivedAt ? 'archived' : thread.session?.status || 'idle';
  console.log([thread.id, thread.projectId, status, pending, thread.modelSelection?.instanceId || 'unknown'].map(clean).join('\t'));
}
(async () => {
  const origin = process.env.FM_T3CODE_ORIGIN || JSON.parse(fs.readFileSync(process.env.FM_T3CODE_RUNTIME_FILE, 'utf8')).origin;
  const token = fs.readFileSync(process.env.FM_T3CODE_TOKEN_FILE, 'utf8').trim();
  if (!token) return finish(2);
  const response = await fetch(new URL('/api/auth/websocket-ticket', origin), {
    method: 'POST', headers: { authorization: `Bearer ${token}` },
  });
  if (!response.ok) return finish(2);
  const { ticket } = await response.json();
  if (typeof ticket !== 'string' || !ticket) return finish(2);
  const url = new URL('/ws', origin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('wsTicket', ticket);
  socket = new WebSocket(url);
  socket.addEventListener('error', () => finish(2));
  socket.addEventListener('close', () => finish(2));
  socket.addEventListener('open', () => socket.send(JSON.stringify({
    _tag: 'Request', id: '1', tag: 'orchestration.subscribeShell',
    payload: { requestCompletionMarker: true }, headers: [],
  })));
  socket.addEventListener('message', ({ data }) => {
    try {
      const decoded = JSON.parse(data);
      for (const message of Array.isArray(decoded) ? decoded : [decoded]) {
        if (message._tag === 'Ping') {
          socket.send(JSON.stringify({ _tag: 'Pong' }));
          continue;
        }
        if (message._tag === 'Pong') continue;
        if (message._tag !== 'Chunk' || message.requestId !== '1' || !Array.isArray(message.values)) return finish(2);
        for (const item of message.values) {
          if (item.kind === 'snapshot') {
            if (!Array.isArray(item.snapshot?.threads)) return finish(2);
            // The initial snapshot is produced after the live subscription is
            // buffered by T3. It reconciles levels without a read/subscribe gap.
            if (!synchronized) console.log('subscribed');
            synchronized = true;
            item.snapshot.threads.forEach(row);
          } else if (item.kind === 'thread-upserted') {
            if (!synchronized) return finish(2);
            row(item.thread);
          } else if (item.kind === 'thread-removed' && wanted.has(item.threadId)) {
            row({ id: item.threadId, archivedAt: true });
          } else if (!['synchronized', 'project-upserted', 'project-removed', 'thread-removed'].includes(item.kind)) {
            return finish(2);
          }
        }
        socket.send(JSON.stringify({ _tag: 'Ack', requestId: '1' }));
      }
    } catch { finish(2); }
  });
})().catch(() => finish(2));
