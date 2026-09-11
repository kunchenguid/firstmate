/** @returns {import('../ports/terminal').Terminal} */
export function terminal(stream = process.stdout, env = process.env) {
  return { tty: !!stream.isTTY, color: !!stream.isTTY && !Object.hasOwn(env, 'NO_COLOR'), write: text => { stream.write(text); } };
}
