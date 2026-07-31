import {
  mkdir,
  readFile,
  readdir,
  stat,
} from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  LavishError,
  atomicWrite,
  commitAnswer,
  createDecision,
  readAnswer,
  readDecision,
  sha256Bytes,
  sha256File,
  validateDecisionId,
  validateQuestions,
} from './protocol.mjs';

function legacyIdPart(value) {
  const normalized = String(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 32);
  return normalized || 'prompt';
}

async function existingSnapshot(snapshotDirectory, sourceDigest) {
  let entries;
  try {
    entries = await readdir(snapshotDirectory, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.startsWith('state-') || !entry.name.endsWith('.json')) {
      continue;
    }
    const candidate = join(snapshotDirectory, entry.name);
    if (await sha256File(candidate) === sourceDigest) {
      return candidate;
    }
  }
  return undefined;
}

export async function snapshotLegacyState(statePath, snapshotDirectory) {
  const source = resolve(statePath);
  const sourceState = await stat(source);
  if (!sourceState.isFile()) {
    throw new LavishError(`legacy state is not a regular file: ${source}`, 2);
  }
  await mkdir(snapshotDirectory, { recursive: true, mode: 0o700 });
  const sourceDigest = await sha256File(source);
  const prior = await existingSnapshot(snapshotDirectory, sourceDigest);
  if (prior !== undefined) {
    return { path: prior, digest: sourceDigest, created: false };
  }
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const target = join(
    snapshotDirectory,
    `state-${timestamp}-${sourceDigest.slice('sha256:'.length, 'sha256:'.length + 12)}.json`,
  );
  const bytes = await readFile(source);
  await atomicWrite(target, bytes, { failIfExists: true });
  if (await sha256File(target) !== sourceDigest) {
    throw new LavishError('legacy state snapshot digest mismatch', 2);
  }
  return { path: target, digest: sourceDigest, created: true };
}

function parseLegacyState(raw) {
  let state;
  try {
    state = JSON.parse(raw);
  } catch (error) {
    throw new LavishError(`legacy state is not valid JSON: ${error.message}`, 2);
  }
  if (state === null || typeof state !== 'object' || Array.isArray(state)) {
    throw new LavishError('legacy state root must be an object', 2);
  }
  if (
    state.sessions === null
    || typeof state.sessions !== 'object'
    || Array.isArray(state.sessions)
  ) {
    throw new LavishError('legacy state sessions must be an object keyed by session id', 2);
  }
  return state;
}

function pendingPrompts(session, sessionKey) {
  const count = session.pending_prompts;
  if (!Number.isInteger(count) || count < 0) {
    throw new LavishError(`legacy session ${sessionKey} has invalid pending_prompts`, 2);
  }
  if (count === 0) {
    return [];
  }
  if (!Array.isArray(session.prompts) || session.prompts.length < count) {
    throw new LavishError(
      `legacy session ${sessionKey} says ${count} prompts are pending but only ${session.prompts?.length ?? 0} are stored`,
      2,
    );
  }
  return session.prompts.slice(-count);
}

function validatePendingMap(raw, sessions) {
  if (raw === undefined) {
    return [];
  }
  if (!Array.isArray(raw)) {
    throw new LavishError('pending map must be a JSON array', 2);
  }
  const ids = new Set();
  const sessionKeys = new Set();
  return raw.map((entry, index) => {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new LavishError(`pending map entry ${index} must be an object`, 2);
    }
    if (typeof entry.session_key !== 'string' || sessions[entry.session_key] === undefined) {
      throw new LavishError(`pending map entry ${index} names an unknown session`, 2);
    }
    const decisionId = validateDecisionId(entry.decision_id);
    if (ids.has(decisionId)) {
      throw new LavishError(`pending map repeats decision id ${decisionId}`, 2);
    }
    if (sessionKeys.has(entry.session_key)) {
      throw new LavishError(`pending map repeats session ${entry.session_key}`, 2);
    }
    ids.add(decisionId);
    sessionKeys.add(entry.session_key);
    if (typeof entry.title !== 'string' || entry.title.trim() === '') {
      throw new LavishError(`pending map entry ${index} needs a title`, 2);
    }
    if (typeof entry.destination !== 'string' || entry.destination.trim() === '') {
      throw new LavishError(`pending map entry ${index} needs a destination`, 2);
    }
    if (typeof entry.request_md !== 'string' || entry.request_md.trim() === '') {
      throw new LavishError(`pending map entry ${index} needs complete request_md`, 2);
    }
    const questions = validateQuestions(entry.questions);
    return {
      sessionKey: entry.session_key,
      decisionId,
      title: entry.title,
      destination: entry.destination,
      request: entry.request_md,
      questions,
    };
  });
}

async function importLegacyPrompt(home, sessionKey, session, prompt, index) {
  if (prompt === null || typeof prompt !== 'object' || Array.isArray(prompt)) {
    throw new LavishError(`pending prompt ${index} in ${sessionKey} is not an object`, 2);
  }
  if (typeof prompt.prompt !== 'string' || prompt.prompt.trim() === '') {
    throw new LavishError(`pending prompt ${index} in ${sessionKey} has no captain input`, 2);
  }
  const uid = typeof prompt.uid === 'string' && prompt.uid.trim() !== ''
    ? prompt.uid
    : String(index + 1);
  const identityDigest = sha256Bytes(
    Buffer.from(JSON.stringify([sessionKey, uid, index]), 'utf8'),
  ).slice('sha256:'.length, 'sha256:'.length + 23);
  const id = validateDecisionId(
    `legacy-${legacyIdPart(sessionKey).slice(0, 16)}-${legacyIdPart(uid).slice(0, 16)}-${identityDigest}`,
  );
  const sourceFile = typeof session.file === 'string' ? session.file : '(unknown legacy file)';
  const request = [
    '# Imported legacy Lavish feedback',
    '',
    'This record preserves captain input that the upstream Lavish session had queued but had not delivered.',
    '',
    `Legacy session: ${sessionKey}`,
    `Legacy file: ${sourceFile}`,
    `Legacy prompt uid: ${uid}`,
    `Legacy selector: ${typeof prompt.selector === 'string' ? prompt.selector : ''}`,
    `Legacy tag: ${typeof prompt.tag === 'string' ? prompt.tag : ''}`,
    '',
    'The complete original captain input is stored in answer.toon as the note.',
    '',
  ].join('\n');
  const legacySource = {
    session_key: sessionKey,
    file: sourceFile,
    prompt_uid: uid,
  };
  const createdAt = Number.isFinite(Date.parse(session.updated_at))
    ? session.updated_at
    : new Date().toISOString();
  const result = await createDecision(home, {
    id,
    title: `Imported legacy feedback ${uid}`,
    request,
    destination: `data/legacy-lavish-feedback/${id}.toon`,
    questions: [{
      key: 'legacy-feedback',
      prompt: typeof prompt.text === 'string' && prompt.text.trim() !== ''
        ? prompt.text
        : 'Imported legacy feedback',
      options: [{ value: 'imported', label: 'Imported legacy feedback' }],
    }],
    createdAt,
    legacySource,
  });
  const decision = result.decision ?? await readDecision(home, id);
  try {
    await commitAnswer(
      decision,
      [{ key: 'legacy-feedback', value: 'imported', label: 'Imported legacy feedback' }],
      prompt.prompt,
      { submittedAt: createdAt },
    );
    return { id, created: true };
  } catch (error) {
    if (!(error instanceof LavishError) || error.exitCode !== 3) {
      throw error;
    }
    const existing = await readAnswer(decision);
    if (
      existing.answer.note !== prompt.prompt
      || existing.answer.answers.length !== 1
      || existing.answer.answers[0].key !== 'legacy-feedback'
      || existing.answer.answers[0].value !== 'imported'
    ) {
      throw new LavishError(`legacy prompt ${id} already has a different answer`, 3);
    }
    return { id, created: false };
  }
}

export async function migrateLegacy(home, {
  statePath,
  snapshotDirectory,
  pendingMap = undefined,
}) {
  const snapshot = await snapshotLegacyState(statePath, snapshotDirectory);
  const stateText = await readFile(statePath, 'utf8');
  if (sha256Bytes(Buffer.from(stateText, 'utf8')) !== snapshot.digest) {
    throw new LavishError('legacy state changed after snapshot; retry from a fresh snapshot', 4);
  }
  const state = parseLegacyState(stateText);
  const mappings = validatePendingMap(pendingMap, state.sessions);

  const importedPrompts = [];
  for (const [sessionKey, session] of Object.entries(state.sessions)) {
    const prompts = pendingPrompts(session, sessionKey);
    for (let index = 0; index < prompts.length; index += 1) {
      importedPrompts.push(
        await importLegacyPrompt(home, sessionKey, session, prompts[index], index),
      );
    }
  }

  const migratedRequests = [];
  for (const mapping of mappings) {
    const session = state.sessions[mapping.sessionKey];
    const result = await createDecision(home, {
      id: mapping.decisionId,
      title: mapping.title,
      request: mapping.request,
      destination: mapping.destination,
      questions: mapping.questions,
      legacySource: {
        session_key: mapping.sessionKey,
        file: typeof session.file === 'string' ? session.file : '(unknown legacy file)',
        prompt_uid: 'unanswered-request',
      },
    });
    migratedRequests.push({ id: mapping.decisionId, created: result.created });
  }

  return {
    snapshot,
    sessionCount: Object.keys(state.sessions).length,
    importedPrompts,
    migratedRequests,
  };
}
