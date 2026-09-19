import {runCodexHost} from './codex-host-runtime.mjs';

try {
 await runCodexHost();
} catch(error) {
 console.error(error.message);
 process.exitCode=1;
}
