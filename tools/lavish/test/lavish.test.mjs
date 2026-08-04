import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  readdir,
  rm,
  symlink,
  stat,
  utimes,
  writeFile,
} from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';
import { decode, encode } from '@toon-format/toon';
import { parseHTML } from 'linkedom';

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = resolve(PACKAGE_ROOT, '../..');
const CLI = join(PACKAGE_ROOT, 'src/cli.mjs');
const BOARD_ADAPTER = join(REPO_ROOT, 'bin/fm-lavish-board.sh');
const WAKE_ADAPTER = join(REPO_ROOT, 'bin/fm-lavish-wake.sh');
const QUEUE_ADAPTER = join(REPO_ROOT, 'bin/fm-lavish-queue.sh');
const WAKE_DRAIN = join(REPO_ROOT, 'bin/fm-wake-drain.sh');
const FAKE_BROWSER = join(PACKAGE_ROOT, 'test-support/fake-browser.mjs');
const ONE_PIXEL_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);

async function exists(path) {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function fixture(name) {
  const root = await mkdtemp(join(tmpdir(), `lavish-${name}-`));
  const home = join(root, 'home');
  const request = join(root, 'request.md');
  const questions = join(root, 'questions.json');
  await mkdir(home, { recursive: true });
  await writeFile(
    request,
    '# Release choice\n\nRecommendation: choose blue.\n\nBlue is safer; green is faster.\n',
  );
  await writeFile(
    questions,
    `${JSON.stringify([{
      key: 'rollout',
      prompt: 'Which rollout should we use?',
      options: [
        { value: 'blue', label: 'Blue rollout' },
        { value: 'green', label: 'Green rollout' },
      ],
    }])}\n`,
  );
  return { root, home, request, questions };
}

function processGroupMembers(pgid) {
  let output;
  try {
    // Filter in ps so a large process table cannot overflow execFileSync's default 1 MiB maxBuffer.
    output = execFileSync(
      'ps',
      ['-o', 'pid=,pgid=,command=', '-g', String(pgid)],
      {
        encoding: 'utf8',
        maxBuffer: 8 * 1024 * 1024,
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
  } catch (error) {
    if (
      error.status === 1
      && error.signal === null
      && error.stdout === ''
      && error.stderr === ''
    ) {
      return [];
    }
    throw error;
  }
  return output
    .trim()
    .split('\n')
    .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
    .filter((match) => match !== null && Number(match[2]) === pgid)
    .map((match) => ({ pid: Number(match[1]), command: match[3] }));
}

function processDescendants(rootPid) {
  const output = execFileSync('ps', ['-axo', 'pid=,ppid=,command='], {
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
  });
  const processes = output
    .trim()
    .split('\n')
    .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
    .filter((match) => match !== null)
    .map((match) => ({
      pid: Number(match[1]),
      ppid: Number(match[2]),
      command: match[3],
    }));
  const descendants = new Set([rootPid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const processInfo of processes) {
      if (
        !descendants.has(processInfo.pid)
        && descendants.has(processInfo.ppid)
      ) {
        descendants.add(processInfo.pid);
        changed = true;
      }
    }
  }
  descendants.delete(rootPid);
  return processes.filter((processInfo) => descendants.has(processInfo.pid));
}

function executeBoardSubmission(html, { storageFailure = false } = {}) {
  const { window, document } = parseHTML(html);
  const storage = new Map();
  Object.defineProperty(window, 'localStorage', {
    configurable: true,
    value: {
      getItem(key) {
        return storage.get(key) ?? null;
      },
      setItem(key, value) {
        if (storageFailure) throw new Error('durable browser storage unavailable');
        storage.set(key, String(value));
      },
    },
  });
  window.Blob = globalThis.Blob;
  window.URL = {
    createObjectURL: () => 'blob:lavish-test',
    revokeObjectURL: () => {},
  };
  window.scrollTo = () => {};
  window.setTimeout = (callback) => {
    callback();
    return 1;
  };
  const script = document.querySelector('script').textContent;
  vm.runInContext(script, vm.createContext(window));
  const selected = document.querySelector('input[type="radio"]');
  selected.checked = true;
  selected.setAttribute('checked', '');
  document.querySelector('#review-button').click();
  document.querySelector('#submit-button').click();
  return { document, storage };
}

async function fakeTmux(fx) {
  const bin = join(fx.root, 'fake-bin');
  const log = join(fx.root, 'tmux.log');
  await mkdir(bin);
  const tmux = join(bin, 'tmux');
  await writeFile(
    tmux,
    `#!/bin/sh
case "$1" in
  display-message)
    case "$*" in
      *pane_pid*) printf '%s\\n' "\${LAVISH_FAKE_TMUX_PANE_PID:?}" ;;
      *pane_current_command*) printf 'claude\\n' ;;
      *cursor_y*) printf '0\\n' ;;
      *) printf '@1\\n' ;;
    esac
    ;;
  capture-pane) printf '│ > │\\n' ;;
  send-keys) printf '%s\\n' "$*" >> '${log}' ;;
  *) exit 1 ;;
esac
`,
  );
  await chmod(tmux, 0o700);
  return { bin, log };
}

async function writeSupervisorLock(fx, target, stateDirectory = join(fx.home, 'state')) {
  const holderPath = join(fx.root, 'fake-bin/codex-lock-holder');
  await symlink('/bin/sleep', holderPath);
  const holder = spawn(holderPath, ['30'], { stdio: 'ignore' });
  await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  const started = execFileSync(
    'ps',
    ['-o', 'lstart=', '-p', String(holder.pid)],
    { encoding: 'utf8' },
  ).trim();
  const canonicalHome = execFileSync('/bin/pwd', ['-P'], {
    cwd: fx.home,
    encoding: 'utf8',
  }).trim();
  await mkdir(stateDirectory, { recursive: true });
  await writeFile(
    join(stateDirectory, '.lock'),
    `${holder.pid}\n${started}\nhome=${canonicalHome}\nbackend=tmux\ntarget=${target}\n`,
  );
  return holder;
}

async function listeningSockets(pid) {
  try {
    const output = execFileSync(
      'lsof',
      ['-nP', '-a', '-p', String(pid), '-iTCP', '-sTCP:LISTEN'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    );
    return output.trim() === '' ? [] : output.trim().split('\n').slice(1);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      return [];
    }
  }

  const listeningInodes = new Set();
  for (const table of ['/proc/net/tcp', '/proc/net/tcp6']) {
    if (!(await exists(table))) continue;
    const lines = (await readFile(table, 'utf8')).trim().split('\n').slice(1);
    for (const line of lines) {
      const columns = line.trim().split(/\s+/);
      if (columns[3] === '0A') listeningInodes.add(columns[9]);
    }
  }
  const sockets = [];
  const fdDirectory = `/proc/${pid}/fd`;
  if (!(await exists(fdDirectory))) return sockets;
  for (const fd of await readdir(fdDirectory)) {
    try {
      const target = await readlink(join(fdDirectory, fd));
      const match = target.match(/^socket:\[(\d+)]$/);
      if (match !== null && listeningInodes.has(match[1])) sockets.push(match[1]);
    } catch {
      // Descriptors can close while they are inspected.
    }
  }
  return sockets;
}

function runCli(args, {
  home,
  input = '',
  env = {},
} = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(CLI, [...args, '--home', home], {
      detached: true,
      env: {
        ...process.env,
        LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
        LAVISH_SCAN_HOME_DOWNLOADS: '0',
        FM_LAVISH_QUEUE_DISABLE: '1',
        ...env,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', rejectRun);
    child.on('close', (code, signal) => {
      const members = processGroupMembers(child.pid);
      assert.deepEqual(
        members,
        [],
        `command left processes in group ${child.pid}: ${JSON.stringify(members)}`,
      );
      resolveRun({ code, signal, stdout, stderr, pid: child.pid });
    });
    child.stdin.end(input);
  });
}

function runExecutable(executable, args, {
  env = {},
  input = '',
  unsetEnv = [],
} = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const childEnv = {
      ...process.env,
      LAVISH_SCAN_HOME_DOWNLOADS: '0',
      FM_LAVISH_QUEUE_DISABLE: '1',
      ...env,
    };
    for (const key of unsetEnv) delete childEnv[key];
    const child = spawn(executable, args, {
      detached: true,
      env: childEnv,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', rejectRun);
    child.on('close', (code, signal) => {
      const members = processGroupMembers(child.pid);
      assert.deepEqual(
        members,
        [],
        `command left processes in group ${child.pid}: ${JSON.stringify(members)}`,
      );
      resolveRun({ code, signal, stdout, stderr, pid: child.pid });
    });
    child.stdin.end(input);
  });
}

async function createRequest(fx, {
  id = 'release-choice',
  destination = 'data/replies/release-choice.toon',
  createdAt = undefined,
  returnResult = false,
  visuals = undefined,
} = {}) {
  const args = [
    'create',
    '--id',
    id,
    '--title',
    'Release choice',
    '--request',
    fx.request,
    '--questions',
    fx.questions,
    '--destination',
    destination,
  ];
  if (createdAt !== undefined) args.push('--created-at', createdAt);
  if (visuals !== undefined) args.push('--visuals', visuals);
  const result = await runCli(args, { home: fx.home });
  assert.equal(result.code, 0, result.stderr);
  return returnResult ? { id, result } : id;
}

async function manifestFor(fx, id) {
  return decode(
    await readFile(join(fx.home, 'data/decisions', id, 'manifest.toon'), 'utf8'),
    { strict: true },
  );
}

function browserPayload(fx, manifest, overrides = {}) {
  return {
    schema_version: 2,
    decision_id: manifest.decision_id,
    home_marker: resolve(fx.home),
    request_sha256: manifest.request_sha256,
    answers: manifest.questions.map((question) => ({
      key: question.key,
      value: question.options[0].value,
      question_note: '',
      option_comments: {},
    })),
    note: '',
    ...overrides,
  };
}

async function answer(fx, id, {
  choice = 1,
  note = '',
  env = {},
} = {}) {
  return await runCli(['answer', id], {
    home: fx.home,
    input: `${choice}\n${note}\ny\n`,
    env,
  });
}

test('answer has no child process or listening socket while waiting and leaves none', async () => {
  const fx = await fixture('resources');
  const id = await createRequest(fx);
  const child = spawn(CLI, ['answer', id, '--home', fx.home], {
    detached: true,
    env: {
      ...process.env,
      LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  const completion = new Promise((resolveCompletion, rejectCompletion) => {
    child.on('error', rejectCompletion);
    child.on('close', (code, signal) => {
      resolveCompletion({ code, signal, stderr });
    });
  });
  const deadline = Date.now() + 5_000;
  while (
    !stdout.includes('Choose 1-2 for rollout: ')
    && child.exitCode === null
    && Date.now() < deadline
  ) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  assert.match(stdout, /Choose 1-2 for rollout:/, stderr);
  assert.equal(child.exitCode, null, stderr);
  assert.deepEqual(processDescendants(child.pid), []);
  assert.deepEqual(await listeningSockets(child.pid), []);

  child.stdin.end('1\nresource proof\ny\n');
  const result = await completion;
  assert.equal(result.signal, null);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(processDescendants(child.pid), []);
});

test('a seven-day-old request remains answerable with no firstmate process', async () => {
  const fx = await fixture('seven-day');
  const createdAt = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const id = await createRequest(fx, { createdAt });
  const decisionDirectory = join(fx.home, 'data/decisions', id);
  const oldTime = new Date(createdAt);
  await utimes(join(decisionDirectory, 'request.md'), oldTime, oldTime);
  await utimes(join(decisionDirectory, 'manifest.toon'), oldTime, oldTime);

  assert.equal(await exists(join(fx.home, 'state/.lock')), false);
  const result = await answer(fx, id, { note: 'Answer after seven quiet days' });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /Answer saved.*wake queued/);
  assert.equal(await exists(join(decisionDirectory, 'answer.toon')), true);
  assert.equal(await exists(join(fx.home, 'state/.wake-queue')), true);

  const inbox = await runCli(['inbox'], { home: fx.home });
  assert.equal(inbox.code, 0, inbox.stderr);
  assert.equal(inbox.stdout, 'No pending Lavish decisions.\n');
});

test('the surfaced captain command works with FM_HOME unset', async () => {
  const fx = await fixture('captain shell');
  const { id, result: created } = await createRequest(fx, { returnResult: true });
  const runLine = created.stdout
    .split('\n')
    .find((line) => line.startsWith('Run: '));
  assert.ok(runLine, `create did not surface a Run line: ${created.stdout}`);
  const surfacedCommand = runLine.slice('Run: '.length);
  assert.equal(
    surfacedCommand,
    `lavish answer ${id} --home '${fx.home}'`,
  );

  const fakeBin = join(fx.root, 'captain-bin');
  await mkdir(fakeBin);
  await symlink(CLI, join(fakeBin, 'lavish'));
  const answered = await runExecutable('/bin/sh', ['-c', surfacedCommand], {
    env: { PATH: `${fakeBin}:${process.env.PATH}` },
    unsetEnv: ['FM_HOME'],
    input: '1\nRun from the captain shell\ny\n',
  });
  assert.equal(answered.code, 0, answered.stderr);
  assert.doesNotMatch(answered.stderr, /FM_HOME is required/);
  assert.match(answered.stdout, /Answer saved.*wake queued/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    true,
  );
});

test('interruption before rename cannot expose a partial answer', async () => {
  const fx = await fixture('interrupted');
  const id = await createRequest(fx);
  const decisionDirectory = join(fx.home, 'data/decisions', id);
  const crashed = await answer(fx, id, {
    env: {
      LAVISH_TEST_CRASH_BEFORE_RENAME: '1',
      LAVISH_TEST_KEEP_TEMP: '1',
    },
  });
  assert.equal(crashed.code, null);
  assert.equal(crashed.signal, 'SIGKILL');
  assert.equal(await exists(join(decisionDirectory, 'answer.toon')), false);
  const leftovers = (await readdir(decisionDirectory))
    .filter((name) => name.startsWith('.answer.toon.tmp-'));
  assert.equal(leftovers.length, 1);

  const inbox = await runCli(['inbox'], { home: fx.home });
  assert.equal(inbox.code, 0, inbox.stderr);
  assert.match(inbox.stdout, new RegExp(id));

  const recovered = await answer(fx, id, { choice: 2 });
  assert.equal(recovered.code, 0, recovered.stderr);
  assert.equal(await exists(join(decisionDirectory, 'answer.toon')), true);
  assert.deepEqual(
    (await readdir(decisionDirectory)).filter((name) => name.startsWith('.answer.toon.tmp-')),
    [],
  );
});

test('cancelling the explicit confirmation leaves no answer', async () => {
  const fx = await fixture('cancel');
  const id = await createRequest(fx);
  const cancelled = await runCli(['answer', id], {
    home: fx.home,
    input: '1\nnot yet\nn\n',
  });
  assert.equal(cancelled.code, 0, cancelled.stderr);
  assert.match(cancelled.stdout, /Cancelled; no answer was saved/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    false,
  );
});

test('duplicate submission is idempotent and does not queue another wake', async () => {
  const fx = await fixture('duplicate');
  const id = await createRequest(fx);
  const first = await answer(fx, id);
  assert.equal(first.code, 0, first.stderr);
  const answerPath = join(fx.home, 'data/decisions', id, 'answer.toon');
  const before = await readFile(answerPath);
  const wakePath = join(fx.home, 'state/.wake-queue');
  const wakesBefore = await readFile(wakePath, 'utf8');

  const duplicate = await answer(fx, id, { choice: 2, note: 'must not overwrite' });
  assert.equal(duplicate.code, 0, duplicate.stderr);
  assert.match(duplicate.stdout, /already submitted.*answer unchanged/);
  assert.deepEqual(await readFile(answerPath), before);
  assert.equal(await readFile(wakePath, 'utf8'), wakesBefore);
});

test('failed wake append is recoverable by ordinary intake scan', async () => {
  const fx = await fixture('wake-failure');
  const id = await createRequest(fx);
  const result = await answer(fx, id, {
    env: { LAVISH_WAKE_COMMAND: '/usr/bin/false' },
  });
  assert.equal(result.code, 5);
  assert.match(result.stderr, /answer saved; wake not queued/);
  const decisionDirectory = join(fx.home, 'data/decisions', id);
  assert.equal(await exists(join(decisionDirectory, 'answer.toon')), true);
  assert.equal(await exists(join(decisionDirectory, 'receipt.toon')), false);

  const intake = await runCli(['intake'], { home: fx.home });
  assert.equal(intake.code, 0, intake.stderr);
  assert.match(intake.stdout, /release-choice,consumed/);
  assert.equal(await exists(join(decisionDirectory, 'receipt.toon')), true);
  assert.deepEqual(
    await readFile(join(decisionDirectory, 'answer.toon')),
    await readFile(join(fx.home, 'data/replies/release-choice.toon')),
  );

  const again = await runCli(['intake'], { home: fx.home });
  assert.equal(again.code, 0, again.stderr);
  assert.equal(again.stdout, '');
});

test('ordinary wake drain consumes the answer before draining its pointer', async () => {
  const fx = await fixture('wake-boundary');
  const id = await createRequest(fx);
  const answered = await answer(fx, id);
  assert.equal(answered.code, 0, answered.stderr);
  const fakeBin = join(fx.root, 'bin');
  await mkdir(fakeBin);
  await symlink(CLI, join(fakeBin, 'lavish-axi'));

  const drained = await runExecutable(WAKE_DRAIN, [], {
    env: {
      FM_HOME: fx.home,
      FM_GATE_REFUSE_BYPASS: '1',
      PATH: `${fakeBin}:${process.env.PATH}`,
    },
  });
  assert.equal(drained.code, 0, drained.stderr);
  assert.match(drained.stdout, /LAVISH_INTAKE:/);
  assert.match(drained.stdout, /release-choice,consumed/);
  assert.match(drained.stdout, /\tsignal\tlavish:release-choice\tdecision-answer:/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'receipt.toon')),
    true,
  );
  assert.equal(
    await exists(join(fx.home, 'data/replies/release-choice.toon')),
    true,
  );
});

test('configured wake adapter works from an installed-style CLI location', async () => {
  const fx = await fixture('configured-wake');
  const id = await createRequest(fx);
  const adapterLog = join(fx.root, 'wake-adapter.log');
  const adapter = join(fx.root, 'configured-wake.sh');
  await writeFile(
    adapter,
    `#!/bin/sh\nprintf '%s\\n' "$*" >> '${adapterLog}'\nexec '${WAKE_ADAPTER}' "$@"\n`,
  );
  await chmod(adapter, 0o700);

  const configured = await runExecutable(
    CLI,
    ['configure-wake', '--command', adapter, '--home', fx.home],
  );
  assert.equal(configured.code, 0, configured.stderr);
  const answered = await runExecutable(
    CLI,
    ['answer', id, '--home', fx.home],
    { input: '1\nconfigured path\ny\n' },
  );
  assert.equal(answered.code, 0, answered.stderr);
  const adapterArgs = await readFile(adapterLog, 'utf8');
  assert.match(adapterArgs, /--decision release-choice/);
  assert.match(adapterArgs, /--destination data\/replies\/release-choice\.toon/);
});

test('board renders the manifest, annotations, Markdown context, visuals, and submit contract', async () => {
  const fx = await fixture('board');
  const visuals = join(fx.root, 'visuals');
  await mkdir(visuals);
  await writeFile(
    join(visuals, 'rollout.png'),
    ONE_PIXEL_PNG,
  );
  await writeFile(
    fx.questions,
    `${JSON.stringify([
      {
        key: 'rollout',
        prompt: 'Which rollout should we use?',
        visuals: ['rollout.png'],
        options: [
          { value: 'blue', label: 'Blue rollout' },
          { value: 'green', label: 'Green rollout' },
        ],
      },
      {
        key: 'timing',
        prompt: 'When should it begin?',
        options: [
          { value: 'now', label: 'Begin now' },
          { value: 'later', label: 'Wait until later' },
        ],
      },
    ])}\n`,
  );
  const id = await createRequest(fx, { visuals });
  const output = join(fx.root, 'board.html');
  const result = await runCli(['board', id, '--out', output], { home: fx.home });
  assert.equal(result.code, 0, result.stderr);

  const html = await readFile(output, 'utf8');
  const { document } = parseHTML(html);
  assert.equal(document.documentElement.dataset.theme, 'dark');
  assert.equal(document.querySelector('[data-request-context] h1').textContent, 'Release choice');
  const questionNodes = [...document.querySelectorAll('[data-question-key].question')];
  assert.equal(questionNodes.length, 2);
  for (const [index, question] of (await manifestFor(fx, id)).questions.entries()) {
    const node = questionNodes[index];
    assert.equal(node.dataset.questionKey, question.key);
    assert.equal(node.querySelector('h2').textContent, question.prompt);
    assert.deepEqual(
      [...node.querySelectorAll('input[type="radio"]')].map((input) => input.value),
      question.options.map((option) => option.value),
    );
    assert.equal(node.querySelectorAll('textarea[data-option-comment]').length, question.options.length);
    assert.ok(node.querySelector('textarea[data-question-note]'));
  }
  const evidence = document.querySelector('figure[data-visual-file="rollout.png"] img');
  assert.ok(evidence);
  assert.match(evidence.getAttribute('src'), /^data:image\/png;base64,/);
  assert.equal(document.querySelectorAll('link[rel="stylesheet"]').length, 0);
  const payloadBackup = document.querySelector('#submitted-payload');
  assert.ok(payloadBackup);
  assert.equal(payloadBackup.hasAttribute('readonly'), true);
  const script = document.querySelector('script').textContent;
  assert.match(script, /window\.__lavishPayload = payload/);
  assert.match(script, /new Blob\(\[payloadJson\]/);
  assert.match(script, /URL\.createObjectURL\(blob\)/);
  assert.match(script, /anchor\.download = downloadFilename/);
  assert.match(script, /anchor\.click\(\)/);
  assert.match(script, /submittedPayload\.value = payloadJson/);
  assert.match(script, /document\.title = SUBMIT_MARKER/);
  assert.match(script, /LAVISH-SUBMIT v2/);
});

test('B1 board submit persists the payload before showing durable confirmation', async () => {
  const fx = await fixture('board-durable-submit');
  const id = await createRequest(fx);
  const output = join(fx.root, 'board.html');
  const result = await runCli(['board', id, '--out', output], { home: fx.home });
  assert.equal(result.code, 0, result.stderr);

  const submitted = executeBoardSubmission(await readFile(output, 'utf8'));
  assert.equal(submitted.storage.size, 1, 'submit did not persist a browser record');
  const durableRecord = JSON.parse([...submitted.storage.values()][0]);
  assert.equal(durableRecord.marker, 'LAVISH-SUBMIT v2');
  assert.equal(durableRecord.payload.decision_id, id);
  assert.equal(durableRecord.payload.home_marker, resolve(fx.home));
  const confirmation = submitted.document.querySelector('#confirmation');
  assert.equal(confirmation.hidden, false);
  assert.match(confirmation.textContent, /durably saved/i);

  const rejected = executeBoardSubmission(await readFile(output, 'utf8'), {
    storageFailure: true,
  });
  assert.equal(
    rejected.document.querySelector('#confirmation').hidden,
    true,
    'a failed durable write still showed success',
  );
  assert.equal(rejected.document.querySelector('#submit-button').disabled, false);
  assert.equal(rejected.storage.size, 0);
});

test('B5 fm-lavish-board executes submit and recovers after immediate browser close', async () => {
  const fx = await fixture('board-shell-e2e');
  const id = await createRequest(fx);
  const downloads = join(fx.root, 'Downloads');
  const fakeBin = join(fx.root, 'browser-bin');
  const fakeState = join(fx.root, 'fake-browser-state.json');
  const effectiveState = join(fx.root, 'effective-state');
  await mkdir(downloads);
  await mkdir(fakeBin);
  const chrome = join(fakeBin, 'chrome-devtools-axi');
  await writeFile(
    chrome,
    `#!/bin/sh\nexec '${process.execPath}' '${FAKE_BROWSER}' "$@"\n`,
  );
  await chmod(chrome, 0o700);
  const fake = await fakeTmux(fx);
  const holder = await writeSupervisorLock(fx, 'home:0', effectiveState);
  const environment = {
    PATH: `${fake.bin}:${fakeBin}:${process.env.PATH}`,
    FM_LAVISH_BIN: CLI,
    FM_LAVISH_QUEUE_DISABLE: '0',
    FM_STATE_OVERRIDE: effectiveState,
    LAVISH_FAKE_CHROME_STATE: fakeState,
    LAVISH_FAKE_TMUX_PANE_PID: String(holder.pid),
    LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
  };

  try {
    const opened = await runExecutable(
      BOARD_ADAPTER,
      [id, '--home', fx.home, '--downloads', downloads],
      { env: environment },
    );
    assert.equal(opened.code, 0, opened.stderr);
    const checkPath = join(effectiveState, `lavish-board-${id}.check.sh`);
    assert.equal(await exists(checkPath), true);
    assert.equal(
      await exists(join(fx.home, 'state', `lavish-board-${id}.check.sh`)),
      false,
    );
    const openedAtMatch = (await readFile(checkPath, 'utf8')).match(/--opened-at ([0-9]+)/);
    assert.ok(openedAtMatch);
    const openedAt = Number(openedAtMatch[1]);
    const manifest = await manifestFor(fx, id);
    const staleDownload = join(downloads, `lavish-answer-${id}.json`);
    await writeFile(
      staleDownload,
      `${JSON.stringify(browserPayload(fx, manifest, {
        answers: [{
          key: 'rollout',
          value: 'green',
          question_note: 'Stale answer from the prior board.',
          option_comments: {},
        }],
      }))}\n`,
    );
    const staleTime = new Date(openedAt + 500);
    await utimes(staleDownload, staleTime, staleTime);
    const staleInfo = await stat(staleDownload);
    assert.ok(staleInfo.mtimeMs > openedAt);

    const stopped = await runExecutable(chrome, ['stop'], { env: environment });
    assert.equal(stopped.code, 0, stopped.stderr);
    const checked = await runExecutable(checkPath, [], {
      env: environment,
      unsetEnv: ['FM_STATE_OVERRIDE'],
    });
    assert.equal(checked.code, 0, checked.stderr);
    assert.match(checked.stdout, new RegExp(`lavish-submit: ${id}`));
    assert.match(checked.stdout, /lavish-delivery: prompt queued/);
    assert.equal(
      await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
      true,
    );
    const stored = decode(
      await readFile(join(fx.home, 'data/decisions', id, 'answer.toon'), 'utf8'),
      { strict: true },
    );
    assert.equal(stored.answers[0].value, 'blue');
    assert.equal(
      await exists(join(fx.home, 'data/decisions', id, 'receipt.toon')),
      true,
    );
    assert.equal(await exists(join(fx.home, 'data/replies/release-choice.toon')), true);
    assert.match(await readFile(fake.log, 'utf8'), /-t home:0 /);
    assert.equal(
      await exists(join(effectiveState, 'lavish-deliveries', `${id}.digest`)),
      true,
    );
    assert.equal(await exists(checkPath), false);
  } finally {
    const closed = new Promise((resolveClose) => holder.once('close', resolveClose));
    holder.kill();
    await closed;
  }
});

test('B5 watcher check leaves a live unsubmitted board open and pending', async () => {
  const fx = await fixture('board-live-pending');
  const id = await createRequest(fx);
  const downloads = join(fx.root, 'Downloads');
  const fakeBin = join(fx.root, 'browser-bin');
  const fakeState = join(fx.root, 'fake-browser-state.json');
  await mkdir(downloads);
  await mkdir(fakeBin);
  const chrome = join(fakeBin, 'chrome-devtools-axi');
  await writeFile(
    chrome,
    `#!/bin/sh\nexec '${process.execPath}' '${FAKE_BROWSER}' "$@"\n`,
  );
  await chmod(chrome, 0o700);
  const environment = {
    PATH: `${fakeBin}:${process.env.PATH}`,
    FM_LAVISH_BIN: CLI,
    LAVISH_FAKE_CHROME_STATE: fakeState,
    LAVISH_FAKE_CHROME_AUTO_SUBMIT: '0',
    LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
  };

  const opened = await runExecutable(
    BOARD_ADAPTER,
    [id, '--home', fx.home, '--downloads', downloads],
    { env: environment },
  );
  assert.equal(opened.code, 0, opened.stderr);
  const checkPath = join(fx.home, 'state', `lavish-board-${id}.check.sh`);
  const checked = await runExecutable(checkPath, [], { env: environment });
  assert.equal(checked.code, 0, checked.stderr);
  const browserState = JSON.parse(await readFile(fakeState, 'utf8'));
  assert.equal(browserState.open, true);
  assert.equal(Object.keys(browserState.storage).length, 0);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    false,
  );
  assert.equal(await exists(checkPath), true);
});

test('watcher check fails closed when its download location becomes unreadable', async () => {
  const fx = await fixture('board-unreadable-downloads');
  const id = await createRequest(fx);
  const downloads = join(fx.root, 'Downloads');
  const fakeBin = join(fx.root, 'browser-bin');
  const fakeState = join(fx.root, 'fake-browser-state.json');
  await mkdir(downloads);
  await mkdir(fakeBin);
  const chrome = join(fakeBin, 'chrome-devtools-axi');
  await writeFile(
    chrome,
    `#!/bin/sh\nexec '${process.execPath}' '${FAKE_BROWSER}' "$@"\n`,
  );
  await chmod(chrome, 0o700);
  const environment = {
    PATH: `${fakeBin}:${process.env.PATH}`,
    FM_LAVISH_BIN: CLI,
    LAVISH_FAKE_CHROME_STATE: fakeState,
    LAVISH_FAKE_CHROME_AUTO_SUBMIT: '0',
    LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
  };

  const opened = await runExecutable(
    BOARD_ADAPTER,
    [id, '--home', fx.home, '--downloads', downloads],
    { env: environment },
  );
  assert.equal(opened.code, 0, opened.stderr);
  const checkPath = join(fx.home, 'state', `lavish-board-${id}.check.sh`);
  await rm(downloads, { recursive: true });
  await writeFile(downloads, 'not a directory\n');

  const checked = await runExecutable(checkPath, [], { env: environment });
  assert.equal(checked.code, 2, checked.stderr);
  assert.match(checked.stderr, /unsafe or missing downloads directory/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    false,
  );
  assert.equal(await exists(checkPath), true);
});

test('board renders a conventional visuals directory on an existing manifest', async () => {
  const fx = await fixture('board-existing-visual');
  const id = await createRequest(fx);
  const visualDirectory = join(fx.home, 'data/decisions', id, 'visuals');
  await mkdir(visualDirectory);
  await writeFile(join(visualDirectory, 'existing.png'), ONE_PIXEL_PNG);
  const output = join(fx.root, 'board.html');
  const result = await runCli(['board', id, '--out', output], { home: fx.home });
  assert.equal(result.code, 0, result.stderr);

  const { document } = parseHTML(await readFile(output, 'utf8'));
  const evidence = document.querySelector('figure[data-visual-file="existing.png"] img');
  assert.ok(evidence);
  assert.match(evidence.getAttribute('src'), /^data:image\/png;base64,/);
});

test('collect validates and persists structured annotations through the normal wake path', async () => {
  const fx = await fixture('collect');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const payloadPath = join(fx.root, 'payload.json');
  await writeFile(
    payloadPath,
    `${JSON.stringify(browserPayload(fx, manifest, {
      answers: [{
        key: 'rollout',
        value: 'green',
        question_note: 'Prefer the faster path after one health check.',
        option_comments: {
          blue: 'Safe, but too slow for this release.',
          green: 'Use this with the rollback guard.',
        },
      }],
      note: 'Proceed after the current deploy completes.',
    }))}\n`,
  );
  const result = await runCli(['collect', id, '--payload', payloadPath], { home: fx.home });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /Collected answer.*wake queued/);

  const answerPath = join(fx.home, 'data/decisions', id, 'answer.toon');
  const stored = decode(await readFile(answerPath, 'utf8'), { strict: true });
  assert.equal(stored.schema_version, 2);
  assert.equal(stored.answers[0].value, 'green');
  assert.equal(stored.answers[0].label, 'Green rollout');
  assert.equal(
    stored.answers[0].question_note,
    'Prefer the faster path after one health check.',
  );
  assert.deepEqual(stored.answers[0].option_comments, {
    blue: 'Safe, but too slow for this release.',
    green: 'Use this with the rollback guard.',
  });
  assert.equal(stored.note, 'Proceed after the current deploy completes.');
  assert.match(await readFile(join(fx.home, 'state/.wake-queue'), 'utf8'), /lavish:release-choice/);
});

test('intake recovers a browser download payload without manual copy', async () => {
  const fx = await fixture('download-intake');
  const id = await createRequest(fx, {
    destination: 'data/lavish-answers/release-choice.json',
  });
  const manifest = await manifestFor(fx, id);
  const downloads = join(fx.root, 'Downloads');
  await mkdir(downloads);
  const payloadPath = join(downloads, 'lavish-answer-release-choice.json');
  const payload = browserPayload(fx, manifest, {
    answers: [{
      key: 'rollout',
      value: 'green',
      question_note: 'This landed through the browser download path.',
      option_comments: { green: 'Ship this route.' },
    }],
    note: 'No manual copy was involved.',
  });
  await writeFile(payloadPath, `${JSON.stringify(payload, null, 2)}\n`);

  const intake = await runCli(['intake'], {
    home: fx.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(intake.code, 0, intake.stderr);
  assert.match(intake.stdout, /release-choice,payload-collected/);
  assert.match(intake.stdout, /release-choice,consumed/);

  const destinationPath = join(fx.home, 'data/lavish-answers/release-choice.json');
  assert.deepEqual(JSON.parse(await readFile(destinationPath, 'utf8')), payload);
  assert.equal(manifest.destination_format, 'payload-json-v2');
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    true,
  );
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'receipt.toon')),
    true,
  );
  assert.match(await readFile(join(fx.home, 'state/.wake-queue'), 'utf8'), /lavish:release-choice/);

  const again = await runCli(['intake'], {
    home: fx.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(again.code, 0, again.stderr);
  assert.equal(again.stdout, '');
});

test('intake ignores a home-bound download in unrelated homes', async () => {
  const fx = await fixture('download-home-routing');
  const unrelated = await fixture('download-unrelated-home');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const downloads = join(fx.root, 'Downloads');
  await mkdir(downloads);
  await writeFile(
    join(downloads, `lavish-answer-${id}.json`),
    `${JSON.stringify(browserPayload(fx, manifest))}\n`,
  );

  const unrelatedIntake = await runCli(['intake'], {
    home: unrelated.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(unrelatedIntake.code, 0, unrelatedIntake.stderr);
  assert.equal(unrelatedIntake.stdout, '');
  assert.equal(
    await exists(join(unrelated.home, 'data/decisions', id, 'answer.toon')),
    false,
  );

  const matchingIntake = await runCli(['intake'], {
    home: fx.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(matchingIntake.code, 0, matchingIntake.stderr);
  assert.match(matchingIntake.stdout, /release-choice,payload-collected/);
});

test('intake recovers a legacy unmarked download only in a matching home', async () => {
  const fx = await fixture('download-legacy-home-routing');
  const unrelated = await fixture('download-legacy-unrelated-home');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const downloads = join(fx.root, 'Downloads');
  const payload = browserPayload(fx, manifest);
  delete payload.home_marker;
  await mkdir(downloads);
  await writeFile(
    join(downloads, `lavish-answer-${id}.json`),
    `${JSON.stringify(payload)}\n`,
  );

  const unrelatedIntake = await runCli(['intake'], {
    home: unrelated.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(unrelatedIntake.code, 0, unrelatedIntake.stderr);
  assert.equal(unrelatedIntake.stdout, '');

  const matchingIntake = await runCli(['intake'], {
    home: fx.home,
    env: { LAVISH_DOWNLOADS_DIR: downloads },
  });
  assert.equal(matchingIntake.code, 0, matchingIntake.stderr);
  assert.match(matchingIntake.stdout, /release-choice,payload-collected/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    true,
  );
});

test('intake publishes nothing when any configured payload location is unreadable', async () => {
  const fx = await fixture('download-incomplete-scan');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const effectiveState = join(fx.root, 'effective-state');
  const unreadableLocation = join(fx.root, 'not-a-directory');
  await mkdir(effectiveState);
  await writeFile(
    join(effectiveState, `lavish-board-${id}.payload.json`),
    `${JSON.stringify(browserPayload(fx, manifest))}\n`,
  );
  await writeFile(unreadableLocation, 'not a directory\n');

  const intake = await runCli(['intake'], {
    home: fx.home,
    env: {
      FM_STATE_OVERRIDE: effectiveState,
      LAVISH_DOWNLOADS_DIR: unreadableLocation,
    },
  });
  assert.equal(intake.code, 6, intake.stderr);
  assert.match(intake.stdout, /scan-incomplete/);
  assert.match(intake.stdout, /payload_scan_error/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
    false,
  );
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'receipt.toon')),
    false,
  );
});

test('intake recovers landed payloads only from the effective state root', async () => {
  const fx = await fixture('state-override-intake');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const effectiveState = join(fx.root, 'effective-state');
  const defaultState = join(fx.home, 'state');
  await mkdir(effectiveState);
  await mkdir(defaultState);
  await writeFile(
    join(effectiveState, `lavish-board-${id}.payload.json`),
    `${JSON.stringify(browserPayload(fx, manifest))}\n`,
  );
  await writeFile(
    join(defaultState, `lavish-board-${id}.payload.json`),
    `${JSON.stringify(browserPayload(fx, manifest, {
      answers: [{
        key: 'rollout',
        value: 'green',
        question_note: 'Stale default-state answer.',
        option_comments: {},
      }],
    }))}\n`,
  );

  const intake = await runCli(['intake'], {
    home: fx.home,
    env: { FM_STATE_OVERRIDE: effectiveState },
  });
  assert.equal(intake.code, 0, intake.stderr);
  assert.match(intake.stdout, /release-choice,payload-collected/);
  assert.match(intake.stdout, /release-choice,consumed/);
  const stored = decode(
    await readFile(join(fx.home, 'data/decisions', id, 'answer.toon'), 'utf8'),
    { strict: true },
  );
  assert.equal(stored.answers[0].value, 'blue');
});

test('field-less protocol-1 JSON destinations retain JSON payload semantics', async () => {
  const fx = await fixture('legacy-json-intake');
  const id = await createRequest(fx, {
    destination: 'data/lavish-answers/release-choice.json',
  });
  const manifestPath = join(fx.home, 'data/decisions', id, 'manifest.toon');
  const manifest = await manifestFor(fx, id);
  delete manifest.destination_format;
  await writeFile(manifestPath, `${encode(manifest)}\n`);

  const payloadPath = join(fx.root, 'payload.json');
  const payload = browserPayload(fx, manifest);
  const payloadText = `${JSON.stringify(payload, null, 2)}\n`;
  await writeFile(payloadPath, payloadText);
  const collected = await runCli(['collect', id, '--payload', payloadPath], { home: fx.home });
  assert.equal(collected.code, 0, collected.stderr);

  const destinationDirectory = join(fx.home, 'data/lavish-answers');
  const destinationPath = join(destinationDirectory, 'release-choice.json');
  await mkdir(destinationDirectory, { recursive: true });
  await writeFile(destinationPath, payloadText);

  const intake = await runCli(['intake'], { home: fx.home });
  assert.equal(intake.code, 0, intake.stderr);
  assert.match(intake.stdout, /release-choice,consumed/);
  assert.deepEqual(JSON.parse(await readFile(destinationPath, 'utf8')), payload);
  assert.equal(
    await exists(join(fx.home, 'data/decisions', id, 'receipt.toon')),
    true,
  );
});

test('create retries preserve field-less protocol-1 manifests', async () => {
  const fx = await fixture('legacy-create-retry');
  const destination = 'data/lavish-answers/release-choice.json';
  const id = await createRequest(fx, { destination });
  const manifestPath = join(fx.home, 'data/decisions', id, 'manifest.toon');
  const legacyManifest = await manifestFor(fx, id);
  delete legacyManifest.destination_format;
  const legacyText = `${encode(legacyManifest)}\n`;
  await writeFile(manifestPath, legacyText);

  const retry = await createRequest(fx, { destination, returnResult: true });
  assert.match(retry.result.stdout, /Already exists: release-choice/);
  assert.equal(await readFile(manifestPath, 'utf8'), legacyText);
});

test('collect fails closed with named errors for count, key, option, and request drift', async () => {
  const fx = await fixture('collect-invalid');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const payloadPath = join(fx.root, 'payload.json');
  const cases = [
    {
      name: 'payload_count_mismatch',
      payload: browserPayload(fx, manifest, { answers: [] }),
    },
    {
      name: 'payload_unknown_key',
      payload: browserPayload(fx, manifest, {
        answers: [{ key: 'missing', value: 'blue', question_note: '', option_comments: {} }],
      }),
    },
    {
      name: 'payload_unknown_option',
      payload: browserPayload(fx, manifest, {
        answers: [{ key: 'rollout', value: 'purple', question_note: '', option_comments: {} }],
      }),
    },
    {
      name: 'payload_stale_request',
      payload: browserPayload(fx, manifest, { request_sha256: `sha256:${'0'.repeat(64)}` }),
    },
    {
      name: 'payload_wrong_home',
      payload: browserPayload(fx, manifest, { home_marker: resolve(fx.root, 'other-home') }),
    },
  ];
  for (const failure of cases) {
    await writeFile(payloadPath, `${JSON.stringify(failure.payload)}\n`);
    const result = await runCli(['collect', id, '--payload', payloadPath], { home: fx.home });
    assert.equal(result.code, 2, `${failure.name}: ${result.stderr}`);
    assert.match(result.stderr, new RegExp(failure.name));
    assert.equal(
      await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
      false,
    );
  }
});

test('B4 collect rejects explicit null annotations without committing an answer', async () => {
  const cases = [
    {
      name: 'question-note',
      mutate(payload) {
        payload.answers[0].question_note = null;
      },
    },
    {
      name: 'option-comments',
      mutate(payload) {
        payload.answers[0].option_comments = null;
      },
    },
    {
      name: 'overall-note',
      mutate(payload) {
        payload.note = null;
      },
    },
  ];
  for (const failure of cases) {
    const fx = await fixture(`null-${failure.name}`);
    const id = await createRequest(fx);
    const payload = browserPayload(fx, await manifestFor(fx, id));
    failure.mutate(payload);
    const payloadPath = join(fx.root, 'payload.json');
    await writeFile(payloadPath, `${JSON.stringify(payload)}\n`);
    const result = await runCli(['collect', id, '--payload', payloadPath], { home: fx.home });
    assert.equal(result.code, 2, `${failure.name}: ${result.stderr}`);
    assert.match(result.stderr, /payload_invalid_annotation/);
    assert.equal(
      await exists(join(fx.home, 'data/decisions', id, 'answer.toon')),
      false,
    );
  }
});

test('B2 visible queue refuses an ambient target not bound to the answer home', async () => {
  const fx = await fixture('queue-wrong-home');
  await mkdir(join(fx.home, 'state'), { recursive: true });
  const fake = await fakeTmux(fx);
  const result = await runExecutable(
    QUEUE_ADAPTER,
    [
      '--home', fx.home,
      '--decision', 'release-choice',
      '--answer', join(fx.home, 'data/decisions/release-choice/answer.toon'),
      '--digest', `sha256:${'0'.repeat(64)}`,
    ],
    {
      env: {
        PATH: `${fake.bin}:${process.env.PATH}`,
        FM_SUPERVISOR_BACKEND: 'tmux',
        FM_SUPERVISOR_TARGET: 'ambient:0',
      },
    },
  );
  assert.equal(result.code, 4, result.stderr);
  assert.match(result.stderr, /home-bound supervisor/i);
  assert.equal(await exists(fake.log), false, 'queue wrote into the ambient pane');
});

test('B2 visible queue revalidates the target against the lock holder', async () => {
  const fx = await fixture('queue-unbound-lock');
  const fake = await fakeTmux(fx);
  const holder = await writeSupervisorLock(fx, 'ambient:0');
  try {
    const result = await runExecutable(
      QUEUE_ADAPTER,
      [
        '--home', fx.home,
        '--decision', 'release-choice',
        '--answer', join(fx.home, 'data/decisions/release-choice/answer.toon'),
        '--digest', `sha256:${'0'.repeat(64)}`,
        '--destination', 'data/replies/release-choice.toon',
      ],
      {
        env: {
          PATH: `${fake.bin}:${process.env.PATH}`,
          LAVISH_FAKE_TMUX_PANE_PID: '999999999',
        },
      },
    );
    assert.equal(result.code, 4, result.stderr);
    assert.match(result.stderr, /home-bound supervisor/i);
    assert.equal(await exists(fake.log), false, 'queue wrote into an unowned pane');
  } finally {
    const closed = new Promise((resolveClose) => holder.once('close', resolveClose));
    holder.kill();
    await closed;
  }
});

test('B3 visible queue uses the manifest destination and home-bound target', async () => {
  const fx = await fixture('queue-destination');
  const id = await createRequest(fx);
  const payloadPath = join(fx.root, 'payload.json');
  await writeFile(
    payloadPath,
    `${JSON.stringify(browserPayload(fx, await manifestFor(fx, id)))}\n`,
  );
  const fake = await fakeTmux(fx);
  const holder = await writeSupervisorLock(fx, 'home:0');
  try {
    const result = await runExecutable(
      CLI,
      [
        'collect', id,
        '--payload', payloadPath,
        '--home', fx.home,
      ],
      {
        env: {
          PATH: `${fake.bin}:${process.env.PATH}`,
          LAVISH_WAKE_COMMAND: WAKE_ADAPTER,
          FM_LAVISH_QUEUE_DISABLE: '0',
          FM_SUPERVISOR_BACKEND: 'tmux',
          FM_SUPERVISOR_TARGET: 'ambient:0',
          LAVISH_FAKE_TMUX_PANE_PID: String(holder.pid),
        },
      },
    );
    assert.equal(result.code, 0, result.stderr);
    const log = await readFile(fake.log, 'utf8');
    assert.match(log, /-t home:0 /);
    assert.match(log, /ingested at data\/replies\/release-choice\.toon/);
    assert.doesNotMatch(log, /data\/lavish-answers\/release-choice\.json/);
  } finally {
    const closed = new Promise((resolveClose) => holder.once('close', resolveClose));
    holder.kill();
    await closed;
  }
});

test('schema version 1 answers remain readable', async () => {
  const fx = await fixture('answer-v1');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const answer = {
    kind: 'lavish-decision-answer',
    schema_version: 1,
    decision_id: id,
    request_sha256: manifest.request_sha256,
    submitted_at: '2026-08-01T00:00:00.000Z',
    answers: [{ key: 'rollout', value: 'blue', label: 'Blue rollout' }],
    note: 'Existing schema one answer.',
  };
  await writeFile(
    join(fx.home, 'data/decisions', id, 'answer.toon'),
    `${encode(answer)}\n`,
  );
  const shown = await runCli(['show', id], { home: fx.home });
  assert.equal(shown.code, 0, shown.stderr);
  assert.match(shown.stdout, /Status: answered at 2026-08-01T00:00:00.000Z/);
});

test('strict TOON count validation rejects a malformed manifest before showing it', async () => {
  const fx = await fixture('toon-count');
  const id = await createRequest(fx);
  const manifestPath = join(fx.home, 'data/decisions', id, 'manifest.toon');
  const valid = await readFile(manifestPath, 'utf8');
  const malformed = valid.replace('questions[1]', 'questions[2]');
  assert.notEqual(malformed, valid);
  await writeFile(manifestPath, malformed);

  const shown = await runCli(['show', id], { home: fx.home });
  assert.equal(shown.code, 2);
  assert.match(shown.stderr, /not valid strict TOON/);
});

test('legacy migration snapshots first, imports queued input, and ignores open status', async () => {
  const fx = await fixture('migration');
  const statePath = join(fx.root, 'state.json');
  const snapshotDirectory = join(fx.root, 'audit');
  const sessions = {};
  for (let index = 0; index < 243; index += 1) {
    const key = `session-${String(index).padStart(3, '0')}`;
    sessions[key] = {
      key,
      file: `/legacy/${key}.html`,
      status: index < 152 ? 'open' : 'ended',
      updated_at: '2026-07-30T12:00:00.000Z',
      pending_prompts: 0,
      prompts: [],
    };
  }
  sessions['session-200'] = {
    ...sessions['session-200'],
    status: 'feedback',
    pending_prompts: 1,
    prompts: [{
      uid: 'captain-1',
      prompt: 'Defer this option until the next review.',
      selector: 'body > button',
      tag: 'decision-batch',
      text: 'Final send choice',
    }],
  };
  const source = `${JSON.stringify({ sessions }, null, 2)}\n`;
  await writeFile(statePath, source);

  const migrated = await runCli(
    [
      'migrate-legacy',
      '--state',
      statePath,
      '--snapshot-dir',
      snapshotDirectory,
    ],
    { home: fx.home },
  );
  assert.equal(migrated.code, 0, migrated.stderr);
  assert.match(migrated.stdout, /source_sessions: 243/);
  assert.match(migrated.stdout, /imported_prompt_count: 1/);
  assert.match(migrated.stdout, /migrated_request_count: 0/);
  assert.equal(await readFile(statePath, 'utf8'), source);

  const snapshots = await readdir(snapshotDirectory);
  assert.equal(snapshots.length, 1);
  assert.equal(await readFile(join(snapshotDirectory, snapshots[0]), 'utf8'), source);
  const decisions = (await readdir(join(fx.home, 'data/decisions')))
    .filter((name) => !name.startsWith('.'));
  assert.equal(decisions.length, 1);
  assert.match(decisions[0], /^legacy-session-200-captain-1-[0-9a-f]{23}$/);
  const answerText = await readFile(
    join(fx.home, 'data/decisions', decisions[0], 'answer.toon'),
    'utf8',
  );
  const imported = decode(answerText, { strict: true });
  assert.equal(imported.note, 'Defer this option until the next review.');
});

test('legacy migration assigns distinct ids to lossy prompt-name collisions', async () => {
  const fx = await fixture('migration-collisions');
  const statePath = join(fx.root, 'state.json');
  const snapshotDirectory = join(fx.root, 'audit');
  await writeFile(
    statePath,
    `${JSON.stringify({
      sessions: {
        'session/with/a/name-that-shares-more-than-thirty-two-characters': {
          file: '/legacy/collisions.html',
          updated_at: '2026-07-30T12:00:00.000Z',
          pending_prompts: 2,
          prompts: [
            { uid: 'review/a', prompt: 'First answer.' },
            { uid: 'review-a', prompt: 'Second answer.' },
          ],
        },
      },
    })}\n`,
  );

  const migrated = await runCli(
    [
      'migrate-legacy',
      '--state',
      statePath,
      '--snapshot-dir',
      snapshotDirectory,
    ],
    { home: fx.home },
  );
  assert.equal(migrated.code, 0, migrated.stderr);
  assert.match(migrated.stdout, /imported_prompt_count: 2/);
  const decisions = (await readdir(join(fx.home, 'data/decisions')))
    .filter((name) => !name.startsWith('.'));
  assert.equal(decisions.length, 2);
  assert.notEqual(decisions[0], decisions[1]);
});

test('an explicit reconciled map migrates only the named unanswered session', async () => {
  const fx = await fixture('pending-map');
  const statePath = join(fx.root, 'state.json');
  const snapshotDirectory = join(fx.root, 'audit');
  await writeFile(
    statePath,
    `${JSON.stringify({
      sessions: {
        relevant: {
          file: '/legacy/relevant.html',
          status: 'open',
          pending_prompts: 0,
          prompts: [],
        },
        irrelevant: {
          file: '/legacy/irrelevant.html',
          status: 'open',
          pending_prompts: 0,
          prompts: [],
        },
      },
    })}\n`,
  );
  const pendingMapPath = join(fx.root, 'pending-map.json');
  await writeFile(
    pendingMapPath,
    `${JSON.stringify([{
      session_key: 'relevant',
      decision_id: 'reconciled-choice',
      title: 'Reconciled choice',
      destination: 'data/replies/reconciled-choice.toon',
      request_md: '# Reconciled choice\n\nRecommendation: A.\n\nA is safer; B is faster.\n',
      questions: [{
        key: 'choice',
        prompt: 'Choose the next step.',
        options: [
          { value: 'a', label: 'A' },
          { value: 'b', label: 'B' },
        ],
      }],
    }])}\n`,
  );
  const result = await runCli(
    [
      'migrate-legacy',
      '--state',
      statePath,
      '--snapshot-dir',
      snapshotDirectory,
      '--pending-map',
      pendingMapPath,
    ],
    { home: fx.home },
  );
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /migrated_request_count: 1/);
  assert.equal(
    await exists(join(fx.home, 'data/decisions/reconciled-choice/manifest.toon')),
    true,
  );
  assert.equal(
    await exists(join(fx.home, 'data/decisions/irrelevant/manifest.toon')),
    false,
  );
});
