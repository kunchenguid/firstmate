import path from 'node:path';
import { pathToFileURL } from 'node:url';

export async function resolve(specifier, context, nextResolve) {
  if (/^@beeline\/[^/]+(?:\/.*)?$/.test(specifier)) {
    const root = process.env.FM_BEELINE_NODE_MODULES;
    if (!root) throw new Error('FM_BEELINE_NODE_MODULES is required');
    const parentURL = pathToFileURL(path.join(path.dirname(root), '.fm-beeline-resolver-entry.mjs')).href;
    return nextResolve(specifier, { ...context, parentURL });
  }
  return nextResolve(specifier, context);
}
