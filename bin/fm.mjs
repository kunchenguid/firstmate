#!/usr/bin/env node
// Firstmate native core entry — dispatches to the TypeScript CLI.
// Cross-platform: invoked directly by `bin/fm` (posix) and `bin/fm.cmd` (Windows).
import { runCli } from '../dist/src/cli/index.js';

process.exitCode = await runCli(process.argv.slice(2));
