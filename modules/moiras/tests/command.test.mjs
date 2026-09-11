import test from 'node:test';
import assert from 'node:assert/strict';
import { run } from '../src/adapters/command.mjs';
test('one-shot child receives EOF without a model or inherited open stdin', async () => {
  try {
    const { stdout } = await run(process.execPath, ['-e', 'console.log("READY"); process.stdin.resume(); process.stdin.on("end", () => console.log("EOF"));'], { timeout: 2000 });
    assert.equal(stdout, 'READY\nEOF\n');
  } catch (error) { assert.match(error.stdout ?? '', /READY/); throw error; }
});
