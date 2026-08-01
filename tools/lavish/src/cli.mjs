#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { access, readFile, stat } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { basename, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import {
  LavishError,
  atomicWrite,
  commitAnswer,
  createDecision,
  encodeToon,
  ensureSafeDirectoryTree,
  intakeAll,
  listDecisions,
  readAnswer,
  readDecision,
  validateCollectPayload,
} from './protocol.mjs';
import { renderBoard } from './board.mjs';
import { migrateLegacy } from './migration.mjs';

const VERSION = '1.1.0';
const PROGRAM = basename(process.argv[1] ?? 'lavish-axi');
const SOURCE_WAKE_ADAPTER = fileURLToPath(
  new URL('../../../bin/fm-lavish-wake.sh', import.meta.url),
);

function usage() {
  return `Lavish ${VERSION} - durable store-and-forward decisions

Human commands:
  lavish inbox [--home <path>]
  lavish show <decision-id> [--home <path>]
  lavish answer <decision-id> [--home <path>]
  lavish board <decision-id> [--home <path>] [--out <path>]

Agent commands:
  lavish-axi create --id <id> --title <title> --request <request.md>
    --questions <questions.json> --destination <relative-path>
    [--visuals <dir>] [--home <path>]
  lavish-axi collect <decision-id> --payload <json-file> [--home <path>]
  lavish-axi intake [--home <path>]
  lavish-axi configure-wake --command <absolute-executable> [--home <path>]
  lavish-axi migrate-legacy --state <state.json> --snapshot-dir <dir>
    [--pending-map <map.json>] [--home <path>]

Every command reads files, performs bounded local work, and exits.
There is no server, listener, poller, watcher, or resident process.
The board command writes self-contained HTML but does not open a browser.`;
}

function parseArguments(argv) {
  const positional = [];
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }
    if (arg === '--help' || arg === '--version') {
      options[arg.slice(2)] = true;
      continue;
    }
    const key = arg.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new LavishError(`missing value for ${arg}`, 2);
    }
    if (options[key] !== undefined) {
      throw new LavishError(`duplicate option ${arg}`, 2);
    }
    options[key] = value;
    index += 1;
  }
  return { positional, options };
}

function rejectUnknownOptions(options, allowed) {
  for (const key of Object.keys(options)) {
    if (!allowed.includes(key)) {
      throw new LavishError(`unknown option --${key}`, 2);
    }
  }
}

function requireOption(options, key) {
  const value = options[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new LavishError(`--${key} is required`, 2);
  }
  return value;
}

function resolveHome(options) {
  const home = options.home ?? process.env.FM_HOME;
  if (typeof home !== 'string' || home.trim() === '') {
    throw new LavishError('FM_HOME is required (or pass --home <path>)', 2);
  }
  return resolve(home);
}

function printRequest(decision) {
  process.stdout.write(`${decision.requestText.trimEnd()}\n\n`);
  process.stdout.write(`Decision: ${decision.manifest.title} (${decision.id})\n`);
  for (const [questionIndex, question] of decision.manifest.questions.entries()) {
    process.stdout.write(`\n${questionIndex + 1}. ${question.prompt} [${question.key}]\n`);
    for (const [optionIndex, option] of question.options.entries()) {
      process.stdout.write(`   ${optionIndex + 1}) ${option.label}\n`);
    }
  }
}

async function inboxCommand(options) {
  rejectUnknownOptions(options, ['home']);
  const home = resolveHome(options);
  const decisions = await listDecisions(home);
  const pending = decisions.filter((decision) => decision.status === 'pending');
  if (pending.length === 0) {
    process.stdout.write('No pending Lavish decisions.\n');
    return;
  }
  process.stdout.write('Pending Lavish decisions:\n');
  for (const decision of pending) {
    process.stdout.write(
      `- ${decision.id}: ${decision.manifest.title} (${decision.manifest.expected_count} question${decision.manifest.expected_count === 1 ? '' : 's'})\n`,
    );
  }
}

async function showCommand(id, options) {
  rejectUnknownOptions(options, ['home']);
  const decision = await readDecision(resolveHome(options), id);
  printRequest(decision);
  try {
    const { answer } = await readAnswer(decision);
    process.stdout.write(`\nStatus: answered at ${answer.submitted_at}\n`);
  } catch (error) {
    if (error.code === 'ENOENT') {
      process.stdout.write('\nStatus: pending\n');
      return;
    }
    throw error;
  }
}

async function collectAnswers(decision) {
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  const lines = terminal[Symbol.asyncIterator]();
  const ask = async (prompt) => {
    process.stdout.write(prompt);
    const next = await lines.next();
    if (next.done) {
      throw new LavishError('input ended before the answer batch was confirmed', 2);
    }
    return next.value;
  };
  const selections = [];
  try {
    for (const question of decision.manifest.questions) {
      let selected;
      while (selected === undefined) {
        const raw = (await ask(
          `Choose 1-${question.options.length} for ${question.key}: `,
        )).trim();
        if (!/^[0-9]+$/.test(raw)) {
          process.stdout.write('Enter one option number.\n');
          continue;
        }
        const option = question.options[Number(raw) - 1];
        if (option === undefined) {
          process.stdout.write(`Enter a number from 1 to ${question.options.length}.\n`);
          continue;
        }
        selected = { key: question.key, value: option.value, label: option.label };
      }
      selections.push(selected);
    }
    const note = await ask('Optional note (press Enter to skip): ');
    process.stdout.write('\nComplete answer batch:\n');
    for (const selection of selections) {
      process.stdout.write(`- ${selection.key}: ${selection.label}\n`);
    }
    if (note.trim() !== '') {
      process.stdout.write(`- note: ${note.trim()}\n`);
    }
    const confirmation = (await ask('Submit this complete batch? [y/N]: '))
      .trim()
      .toLowerCase();
    return { selections, note: note.trim(), confirmed: confirmation === 'y' || confirmation === 'yes' };
  } finally {
    terminal.close();
  }
}

async function executable(path) {
  try {
    await access(path, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function wakeAdapter(home) {
  if (process.env.LAVISH_WAKE_COMMAND) {
    return process.env.LAVISH_WAKE_COMMAND;
  }
  const configured = resolve(home, 'config/lavish-wake-command');
  try {
    const value = (await readFile(configured, 'utf8')).trim();
    if (value !== '' && resolve(value) === value && await executable(value)) {
      return value;
    }
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  if (await executable(SOURCE_WAKE_ADAPTER)) {
    return SOURCE_WAKE_ADAPTER;
  }
  return 'fm-lavish-wake';
}

async function enqueueWake(home, decision, answerDigest) {
  const adapter = await wakeAdapter(home);
  return await new Promise((resolveResult) => {
    const child = execFile(
      adapter,
      [
        '--home',
        home,
        '--decision',
        decision.id,
        '--answer',
        decision.answerPath,
        '--digest',
        answerDigest,
      ],
      {
        env: process.env,
        timeout: 10_000,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        resolveResult({
          ok: error === null,
          detail: (stderr || stdout || error?.message || '').trim(),
        });
      },
    );
    child.stdin?.end();
  });
}

async function configureWakeCommand(options) {
  rejectUnknownOptions(options, ['home', 'command']);
  const home = resolveHome(options);
  const command = resolve(requireOption(options, 'command'));
  const commandState = await stat(command);
  if (!commandState.isFile() || !(await executable(command))) {
    throw new LavishError('--command must be an executable regular file', 2);
  }
  const configDirectory = resolve(home, 'config');
  await ensureSafeDirectoryTree(home, configDirectory, { create: true });
  const configPath = resolve(configDirectory, 'lavish-wake-command');
  await atomicWrite(configPath, `${command}\n`);
  process.stdout.write(`Configured Lavish wake adapter: ${command}\n`);
}

async function answerCommand(id, options) {
  rejectUnknownOptions(options, ['home']);
  const home = resolveHome(options);
  const decision = await readDecision(home, id);
  try {
    const existing = await readAnswer(decision);
    process.stdout.write(
      `Decision ${id} was already submitted at ${existing.answer.submitted_at}; answer unchanged.\n`,
    );
    return;
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }

  printRequest(decision);
  const batch = await collectAnswers(decision);
  if (!batch.confirmed) {
    process.stdout.write('Cancelled; no answer was saved.\n');
    return;
  }

  const beforeRename = process.env.LAVISH_TEST_CRASH_BEFORE_RENAME === '1'
    ? async () => {
      process.kill(process.pid, 'SIGKILL');
      await new Promise(() => {});
    }
    : undefined;
  const committed = await commitAnswer(
    decision,
    batch.selections,
    batch.note,
    { beforeRename },
  );
  const wake = await enqueueWake(home, decision, committed.digest);
  if (!wake.ok) {
    process.stderr.write(
      `answer saved; wake not queued${wake.detail ? `: ${wake.detail}` : ''}\n`,
    );
    process.exitCode = 5;
    return;
  }
  process.stdout.write(`Answer saved for ${id}; firstmate wake queued.\n`);
}

async function boardCommand(id, options) {
  rejectUnknownOptions(options, ['home', 'out']);
  const decision = await readDecision(resolveHome(options), id);
  try {
    const existing = await readAnswer(decision);
    throw new LavishError(
      `decision ${id} was already submitted at ${existing.answer.submitted_at}`,
      3,
    );
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  const outputPath = resolve(options.out ?? `${id}.html`);
  await atomicWrite(outputPath, await renderBoard(decision), { mode: 0o600 });
  process.stdout.write(`Board written: ${outputPath}\n`);
}

async function collectCommand(id, options) {
  rejectUnknownOptions(options, ['home', 'payload']);
  const home = resolveHome(options);
  const decision = await readDecision(home, id);
  const payloadPath = resolve(requireOption(options, 'payload'));
  let payload;
  try {
    payload = JSON.parse(await readFile(payloadPath, 'utf8'));
  } catch (error) {
    throw new LavishError(`payload_invalid_json: ${error.message}`, 2);
  }
  const batch = validateCollectPayload(payload, decision.manifest);
  try {
    const existing = await readAnswer(decision);
    if (
      JSON.stringify(existing.answer.answers) === JSON.stringify(batch.selections)
      && existing.answer.note === batch.note
    ) {
      process.stdout.write(
        `Decision ${id} already contains this collected payload; answer unchanged.\n`,
      );
      return;
    }
    throw new LavishError(`decision ${id} is already answered with different content`, 3);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  const committed = await commitAnswer(decision, batch.selections, batch.note);
  const wake = await enqueueWake(home, decision, committed.digest);
  if (!wake.ok) {
    process.stderr.write(
      `answer saved; wake not queued${wake.detail ? `: ${wake.detail}` : ''}\n`,
    );
    process.exitCode = 5;
    return;
  }
  process.stdout.write(`Collected answer for ${id}; firstmate wake queued.\n`);
}

async function createCommand(options) {
  rejectUnknownOptions(options, [
    'home',
    'id',
    'title',
    'request',
    'questions',
    'destination',
    'visuals',
    'created-at',
  ]);
  const home = resolveHome(options);
  const requestPath = resolve(requireOption(options, 'request'));
  const questionsPath = resolve(requireOption(options, 'questions'));
  let questions;
  try {
    questions = JSON.parse(await readFile(questionsPath, 'utf8'));
  } catch (error) {
    throw new LavishError(`could not parse questions JSON: ${error.message}`, 2);
  }
  const result = await createDecision(home, {
    id: requireOption(options, 'id'),
    title: requireOption(options, 'title'),
    request: await readFile(requestPath),
    questions,
    destination: requireOption(options, 'destination'),
    visualsDirectory: options.visuals === undefined ? undefined : resolve(options.visuals),
    createdAt: options['created-at'] ?? new Date().toISOString(),
  });
  process.stdout.write(
    `${result.created ? 'Created' : 'Already exists'}: ${result.decision.id}\n`
    + `Run: lavish board ${result.decision.id} --home ${home}\n`,
  );
}

async function intakeCommand(options) {
  rejectUnknownOptions(options, ['home']);
  const result = await intakeAll(resolveHome(options));
  if (result.results.length === 0) {
    return;
  }
  process.stdout.write(encodeToon({ decisions: result.results }));
  if (result.failed) {
    process.exitCode = 6;
  }
}

async function migrationCommand(options) {
  rejectUnknownOptions(options, ['home', 'state', 'snapshot-dir', 'pending-map']);
  const home = resolveHome(options);
  const statePath = resolve(requireOption(options, 'state'));
  const snapshotDirectory = resolve(requireOption(options, 'snapshot-dir'));
  let pendingMap;
  if (options['pending-map'] !== undefined) {
    try {
      pendingMap = JSON.parse(await readFile(resolve(options['pending-map']), 'utf8'));
    } catch (error) {
      throw new LavishError(`could not parse pending map JSON: ${error.message}`, 2);
    }
  }
  const result = await migrateLegacy(home, {
    statePath,
    snapshotDirectory,
    pendingMap,
  });
  process.stdout.write(encodeToon({
    migration: {
      snapshot: result.snapshot.path,
      snapshot_sha256: result.snapshot.digest,
      source_sessions: result.sessionCount,
      imported_prompt_count: result.importedPrompts.length,
      migrated_request_count: result.migratedRequests.length,
    },
    imported_prompts: result.importedPrompts,
    migrated_requests: result.migratedRequests,
  }));
}

async function main(argv) {
  const { positional, options } = parseArguments(argv);
  if (options.version) {
    rejectUnknownOptions(options, ['version']);
    process.stdout.write(`lavish-axi ${VERSION} (store-forward protocol 1)\n`);
    return;
  }
  if (options.help || positional.length === 0) {
    rejectUnknownOptions(options, ['help']);
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const [command, id, ...extra] = positional;
  if (extra.length > 0) {
    throw new LavishError(`unexpected arguments: ${extra.join(' ')}`, 2);
  }
  switch (command) {
    case 'inbox':
      if (id !== undefined) throw new LavishError('inbox takes no decision id', 2);
      await inboxCommand(options);
      break;
    case 'show':
      if (id === undefined) throw new LavishError('show requires a decision id', 2);
      await showCommand(id, options);
      break;
    case 'answer':
      if (id === undefined) throw new LavishError('answer requires a decision id', 2);
      await answerCommand(id, options);
      break;
    case 'board':
      if (id === undefined) throw new LavishError('board requires a decision id', 2);
      await boardCommand(id, options);
      break;
    case 'create':
      if (id !== undefined) throw new LavishError('create uses --id, not a positional id', 2);
      await createCommand(options);
      break;
    case 'collect':
      if (id === undefined) throw new LavishError('collect requires a decision id', 2);
      await collectCommand(id, options);
      break;
    case 'intake':
      if (id !== undefined) throw new LavishError('intake takes no decision id', 2);
      await intakeCommand(options);
      break;
    case 'configure-wake':
      if (id !== undefined) throw new LavishError('configure-wake takes no positional id', 2);
      await configureWakeCommand(options);
      break;
    case 'migrate-legacy':
      if (id !== undefined) throw new LavishError('migrate-legacy takes no positional id', 2);
      await migrationCommand(options);
      break;
    default:
      throw new LavishError(`unknown command: ${command}`, 2);
  }
}

main(process.argv.slice(2)).catch((error) => {
  if (error instanceof LavishError) {
    process.stderr.write(`${PROGRAM}: ${error.message}\n`);
    process.exitCode = error.exitCode;
    return;
  }
  process.stderr.write(`${PROGRAM}: ${error.stack ?? error.message}\n`);
  process.exitCode = 1;
});
