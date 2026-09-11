// Real, disposable service process for the shared message acceptance tests.
import { execFileSync } from 'node:child_process';
import { messages, serviceMessages } from '../src/index.mjs';
const port = await serviceMessages({ home: process.env.FM_HOME, root: process.env.FM_TEST_ROOT, name: process.argv[2] });
delete process.env.FM_TASK_ID;
process.on('message', async ({ id, method, args = [] }) => {
  try {
    if (method === 'finish') { process.send({ id }); process.disconnect(); return; }
    if (method === 'unmarked') await messages({ home: process.env.FM_HOME, root: process.env.FM_TEST_ROOT }).receive();
    if (method === 'unmarked-control') {
      try { execFileSync(`${process.env.FM_TEST_ROOT}/bin/fm-send.sh`, ['target', '--key', 'Enter'], { stdio: 'pipe' }); }
      catch (error) { throw Error(error.stderr.toString()); }
    }
    const result = await port[method](...args);
    process.send({ id, result });
    if (method === 'close') process.disconnect();
  } catch (error) { process.send({ id, error: error.message }); }
});
process.send({ ready: true });
