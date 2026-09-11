import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { json } from './journal.mjs';
import { validate } from '../core/config.mjs';
export const moduleRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const toolRoot = path.resolve(moduleRoot, '../..');
export const defaultConfig = path.join(moduleRoot, 'config.json');
export function config(file = defaultConfig) {
  return validate(json(file), json(path.join(moduleRoot, 'config.schema.json')));
}
