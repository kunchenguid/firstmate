import { execFile } from 'node:child_process';
// One-shot commands cannot inherit an open input pipe that prevents print-mode exit.
export const run = (command, args, options = {}) => new Promise((resolve, reject) => {
  const child = execFile(command, args, options, (error, stdout, stderr) => {
    if (error) { error.stdout = stdout; error.stderr = stderr; reject(error); }
    else resolve({ stdout, stderr });
  });
  child.stdin?.end();
});
