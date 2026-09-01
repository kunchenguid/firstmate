// help — print usage.
import type { CliCommand } from '../index.js';
import { printUsage } from '../index.js';

export const helpCommand: CliCommand = {
  name: 'help',
  summary: 'Show this help',
  async run() {
    printUsage();
    return 0;
  },
};
