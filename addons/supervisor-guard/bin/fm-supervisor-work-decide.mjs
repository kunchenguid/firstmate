#!/usr/bin/env node
// Command-line entry for the supervisor-work policy. The shell lexer is loaded
// from the Firstmate checkout named by --lexer, so the add-on carries none.
// Usage: node fm-supervisor-work-decide.mjs --lexer <checkout>/bin/fm-arm-command-policy.mjs
//          [--secondmate] --command <cmd>
// Prints `allow`, or `deny<TAB><code><TAB><reason>`. Exits 2 on bad usage.
import * as url from "node:url";
import { bindLexer, decision } from "./fm-supervisor-work-command-policy.mjs";

const argv = process.argv.slice(2);
const valueOf = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const lexerPath = valueOf("--lexer");
const command = valueOf("--command");

if (lexerPath === undefined || command === undefined) {
  process.stderr.write("usage: fm-supervisor-work-decide.mjs --lexer <path> [--secondmate] --command <cmd>\n");
  process.exit(2);
}

bindLexer(await import(url.pathToFileURL(lexerPath).href));
const result = decision(command, { secondmate: argv.includes("--secondmate") });
const verdict = result.decision === "allow" ? "allow" : `deny\t${result.code}\t${result.reason}`;
process.stdout.write(`${verdict}\n`);
