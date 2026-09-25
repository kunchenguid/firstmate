import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

export function safetyAllows(payload, root) {
  try {
    const safetyDir = join(root, '.claude', 'jev-safety');
    const result = spawnSync(join(safetyDir, '.venv', 'bin', 'python'), [join(safetyDir, 'check.py')], {
      cwd: root,
      encoding: 'utf8',
      input: payload,
      maxBuffer: 8 * 1024 * 1024,
      timeout: 35_000,
    });
    return !result.error && result.status === 0 && JSON.parse(result.stdout).allowed === true;
  } catch {
    return false;
  }
}
