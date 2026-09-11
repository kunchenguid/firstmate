// Real message/service composition; only retrieval and reasoning are synthetic.
import { serve } from '../src/adapters/service.mjs';
import { fakes, config } from './fakes.mjs';
const ports = fakes(), controller = new AbortController(), calls = [];
let release;
const firstFetch = new Promise(resolve => { release = resolve; });
process.on('message', value => { if (value === 'continue') release(); });
process.on('SIGTERM', () => controller.abort());
process.on('SIGINT', () => controller.abort());
for (const [name, port] of Object.entries(ports.retrieval)) {
  const fetch = port.fetch;
  port.fetch = async (...args) => {
    calls.push(name);
    if (calls.length === 1) { process.send({ retrieving: true }); await firstFetch; }
    return fetch(...args);
  };
}
await serve({ home: process.env.FM_HOME, root: process.env.FM_TEST_ROOT, config,
  retrieval: ports.retrieval, reasoner: ports.reasoner, signal: controller.signal, ready: () => process.send({ ready: true }) });
process.send({ stopped: true, calls, reasons: ports.reasoner.calls.length });
process.disconnect();
