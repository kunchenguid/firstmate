#!/usr/bin/env node
// One local queue in front of the Z.AI API: at most GLM_QUEUE_MAX requests in flight (default 8), the rest wait in a
// FIFO line instead of drawing Z.AI's 1302 "Rate limit reached for requests" refusal.
// Method, path, query, headers (Authorization included) and body pass through unchanged; only Host is set to the
// upstream. Responses, SSE streams included, are piped back as they arrive. Nothing is logged but one line per call:
// upstream status, ms waited in line, ms in flight, and the in-flight and waiting counts when it finished.
// Env: GLM_QUEUE_MAX (8), GLM_QUEUE_PORT (8787), GLM_QUEUE_UPSTREAM (https://api.z.ai). Binds 127.0.0.1 only.
import http from 'node:http';
import https from 'node:https';

const MAX = Number(process.env.GLM_QUEUE_MAX || 8);
const PORT = Number(process.env.GLM_QUEUE_PORT || 8787);
if (!Number.isInteger(MAX) || MAX < 1) throw new Error(`glm-queue: GLM_QUEUE_MAX must be a positive integer, got "${process.env.GLM_QUEUE_MAX}"`);
const UP = new URL(process.env.GLM_QUEUE_UPSTREAM || 'https://api.z.ai');
const lib = UP.protocol === 'https:' ? https : http;
const agent = new lib.Agent({ keepAlive: true });

let active = 0;
const line = [];
const acquire = () => (active < MAX ? (active++, Promise.resolve()) : new Promise((r) => line.push(r)));
const release = () => { const next = line.shift(); next ? next() : active--; };  // a freed slot passes straight on

// requestTimeout 0: a request body may sit unread in the line for longer than Node's 5-minute default.
http.createServer({ requestTimeout: 0 }, async (req, res) => {
  const t0 = Date.now();
  let gone = false;
  res.on('close', () => { gone = true; });
  await acquire();
  const t1 = Date.now();
  let done = false;
  const finish = (status) => {
    if (done) return;
    done = true;
    release();
    console.log(`status=${status} wait_ms=${t1 - t0} flight_ms=${Date.now() - t1} in_flight=${active} waiting=${line.length}`);
  };
  if (gone) return finish('client-gone');  // the caller left while waiting: hand the slot on unused

  const up = lib.request({
    protocol: UP.protocol, hostname: UP.hostname, port: UP.port, agent,
    method: req.method, path: req.url, headers: { ...req.headers, host: UP.host },
  }, (upRes) => {
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
    upRes.on('end', () => finish(upRes.statusCode));
    upRes.on('error', () => { if (!res.writableEnded) { res.end(); res.socket?.destroy(); } finish('upstream-error'); });
  });
  up.setTimeout(300_000, () => up.destroy(new Error('upstream idle timeout')));
  up.on('error', (e) => {
    if (res.headersSent) {
      if (!res.writableEnded) { res.end(); res.socket?.destroy(); }
    } else {
      res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(`glm-queue: upstream ${UP.host} failed: ${e.message}\n`);
    }
    finish('upstream-error');
  });
  res.on('close', () => { if (!done) { up.destroy(); finish('client-gone'); } });
  req.pipe(up);
}).listen(PORT, '127.0.0.1', () => console.log(`glm-queue on 127.0.0.1:${PORT} -> ${UP.origin}, max ${MAX} in flight`));
