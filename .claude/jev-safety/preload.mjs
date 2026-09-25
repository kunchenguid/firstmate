import { request } from 'node:http';

const originalFetch = globalThis.fetch.bind(globalThis);
const PORT = parseInt(process.env.JEV_SAFETY_PORT ?? '48752', 10);

function gate(payload) {
  return new Promise((resolve, reject) => {
    const req = request(
      { hostname: '127.0.0.1', port: PORT, path: '/check', method: 'POST', headers: { 'content-type': 'application/json' } },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (part) => { raw += part; });
        res.on('end', () => {
          try {
            const verdict = JSON.parse(raw);
            resolve(
              res.statusCode === 200 &&
              verdict.service === 'firstmate-jev-safety' &&
              verdict.allowed === true
            );
          } catch { resolve(false); }
        });
      },
    );
    req.setTimeout(5000, () => req.destroy(new Error('safety gate timeout')));
    req.on('error', reject);
    req.end(payload);
  });
}

globalThis.fetch = async (input, init = {}) => {
  const method = (init.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const url = typeof input === 'string' ? input : input.url;
  if (method === 'POST' && !url.startsWith('http://127.0.0.1') && !url.startsWith('http://localhost')) {
    let payload = init.body;
    if (payload === undefined && input instanceof Request) payload = await input.clone().text();
    if (typeof payload !== 'string') {
      throw new Error('Jev safety gate cannot inspect this request body; blocked');
    }
    let allowed = false;
    try { allowed = await gate(payload); } catch { allowed = false; }
    if (!allowed) throw new Error('Jev safety gate blocked or was unavailable; request not sent');
  }
  return originalFetch(input, init);
};
