// fm-fast-proxy.js - the same-origin front door for bin/fm-fast-mode.sh.
//
// Backends commonly hand the browser site-relative paths (/api/images/...), so
// running the API and the dev server on two ports makes those assets 404. This
// puts both behind one origin: everything under FAST_API_PREFIX goes to the API,
// everything else to the dev server.
//
// Started by fm-fast-mode.sh with FAST_API_PORT, FAST_WEB_PORT, FAST_PROXY_PORT
// and FAST_API_PREFIX in the environment. Not meant to be run by hand.
const http = require('http');
const net = require('net');

const API = Number(process.env.FAST_API_PORT);
const WEB = Number(process.env.FAST_WEB_PORT);
const PORT = Number(process.env.FAST_PROXY_PORT);
const API_PREFIX = process.env.FAST_API_PREFIX || '/api/';

for (const [name, value] of [
  ['FAST_API_PORT', API],
  ['FAST_WEB_PORT', WEB],
  ['FAST_PROXY_PORT', PORT],
]) {
  if (!Number.isInteger(value) || value <= 0) {
    console.error(`fm-fast-proxy: ${name} must be a port number`);
    process.exit(2);
  }
}

const server = http.createServer((req, res) => {
  const port = req.url.startsWith(API_PREFIX) ? API : WEB;
  const up = http.request(
    { host: '127.0.0.1', port, path: req.url, method: req.method, headers: req.headers },
    (r) => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    }
  );
  up.on('error', (e) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`fm-fast-proxy: 127.0.0.1:${port} failed: ${e.message}`);
  });
  req.pipe(up);
});

// Dev-server hot reload rides a websocket: without forwarding upgrades the fast
// loop degrades into restarting the frontend by hand.
server.on('upgrade', (req, sock, head) => {
  const up = net.connect(WEB, '127.0.0.1', () => {
    up.write(
      `${req.method} ${req.url} HTTP/1.1\r\n` +
        Object.entries(req.headers)
          .map(([k, v]) => `${k}: ${v}`)
          .join('\r\n') +
        '\r\n\r\n'
    );
    if (head && head.length) up.write(head);
    sock.pipe(up).pipe(sock);
  });
  up.on('error', () => sock.destroy());
  sock.on('error', () => up.destroy());
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`fm-fast-proxy http://localhost:${PORT} (${API_PREFIX}* -> :${API}, rest -> :${WEB})`);
});
