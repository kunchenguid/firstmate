import { publishEvent } from '../../../fm-state-reader/src/index.mjs';
/** @returns {import('../ports/research.d.ts').EventPort} */
export function events({ home, root }) {
  return { publish: id => publishEvent({ home, root, module: 'robin', id }) };
}
