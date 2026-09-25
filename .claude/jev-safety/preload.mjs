import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { safetyAllows } from './client.mjs';

const originalFetch = globalThis.fetch.bind(globalThis);
const safetyRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

globalThis.fetch = async (input, init = {}) => {
  const method = (init.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const url = typeof input === 'string' ? input : input.url;
  if (method === 'POST' && !url.startsWith('http://127.0.0.1') && !url.startsWith('http://localhost')) {
    let payload = init.body;
    if (payload === undefined && input instanceof Request) payload = await input.clone().text();
    if (typeof payload !== 'string') {
      throw new Error('Jev safety gate cannot inspect this request body; blocked');
    }
    if (!safetyAllows(payload, safetyRoot)) {
      throw new Error('Jev safety gate blocked or was unavailable; request not sent');
    }
  }
  return originalFetch(input, init);
};
