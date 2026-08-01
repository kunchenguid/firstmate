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
import { decode, encode } from '@toon-format/toon';
import { parseHTML } from 'linkedom';

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = resolve(PACKAGE_ROOT, '../..');
const CLI = join(PACKAGE_ROOT, 'src/cli.mjs');
const WAKE_ADAPTER = join(REPO_ROOT, 'bin/fm-lavish-wake.sh');
const WAKE_DRAIN = join(REPO_ROOT, 'bin/fm-wake-drain.sh');
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
  const output = execFileSync('ps', ['-axo', 'pid=,pgid=,command='], {
    encoding: 'utf8',
  });
  return output
    .trim()
    .split('\n')
    .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
    .filter((match) => match !== null && Number(match[2]) === pgid)
    .map((match) => ({ pid: Number(match[1]), command: match[3] }));
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
} = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(executable, args, {
      detached: true,
      env: { ...process.env, ...env },
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
  return id;
}

async function manifestFor(fx, id) {
  return decode(
    await readFile(join(fx.home, 'data/decisions', id, 'manifest.toon'), 'utf8'),
    { strict: true },
  );
}

function browserPayload(manifest, overrides = {}) {
  return {
    schema_version: 2,
    decision_id: manifest.decision_id,
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
  assert.match(await readFile(adapterLog, 'utf8'), /--decision release-choice/);
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
  const script = document.querySelector('script').textContent;
  assert.match(script, /window\.__lavishPayload = payload/);
  assert.match(script, /document\.title = SUBMIT_MARKER/);
  assert.match(script, /LAVISH-SUBMIT v2/);
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
    `${JSON.stringify(browserPayload(manifest, {
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

test('collect fails closed with named errors for count, key, option, and request drift', async () => {
  const fx = await fixture('collect-invalid');
  const id = await createRequest(fx);
  const manifest = await manifestFor(fx, id);
  const payloadPath = join(fx.root, 'payload.json');
  const cases = [
    {
      name: 'payload_count_mismatch',
      payload: browserPayload(manifest, { answers: [] }),
    },
    {
      name: 'payload_unknown_key',
      payload: browserPayload(manifest, {
        answers: [{ key: 'missing', value: 'blue', question_note: '', option_comments: {} }],
      }),
    },
    {
      name: 'payload_unknown_option',
      payload: browserPayload(manifest, {
        answers: [{ key: 'rollout', value: 'purple', question_note: '', option_comments: {} }],
      }),
    },
    {
      name: 'payload_stale_request',
      payload: browserPayload(manifest, { request_sha256: `sha256:${'0'.repeat(64)}` }),
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
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });
  const deadline = Date.now() + 5_000;
  while (!stdout.includes('Choose 1-2 for rollout: ') && Date.now() < deadline) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  assert.match(stdout, /Choose 1-2 for rollout:/);
  assert.deepEqual(processGroupMembers(child.pid), [
    { pid: child.pid, command: processGroupMembers(child.pid)[0]?.command },
  ]);
  assert.deepEqual(await listeningSockets(child.pid), []);

  const completion = new Promise((resolveCompletion, rejectCompletion) => {
    let stderr = '';
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', rejectCompletion);
    child.on('close', (code, signal) => {
      resolveCompletion({ code, signal, stderr });
    });
  });
  child.stdin.end('1\nresource proof\ny\n');
  const result = await completion;
  assert.equal(result.signal, null);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(processGroupMembers(child.pid), []);
});
