import {
  constants as fsConstants,
  createReadStream,
} from 'node:fs';
import {
  access,
  chmod,
  copyFile,
  lstat,
  link,
  mkdir,
  open,
  readFile,
  readdir,
  readlink,
  rename,
  rm,
  unlink,
} from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from 'node:path';
import { decode, encode } from '@toon-format/toon';

export const SCHEMA_VERSION = 1;
export const ANSWER_SCHEMA_VERSION = 2;
export const MANIFEST_KIND = 'lavish-decision-manifest';
export const ANSWER_KIND = 'lavish-decision-answer';
export const RECEIPT_KIND = 'lavish-decision-receipt';
export const DECISIONS_RELATIVE_DIR = 'data/decisions';

const ID_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
const SHA_PATTERN = /^sha256:[0-9a-f]{64}$/;
const VISUAL_MEDIA_TYPES = new Map([
  ['.gif', 'image/gif'],
  ['.jpeg', 'image/jpeg'],
  ['.jpg', 'image/jpeg'],
  ['.png', 'image/png'],
  ['.webp', 'image/webp'],
]);
const MAX_VISUAL_COUNT = 64;
const MAX_VISUAL_BYTES = 50 * 1024 * 1024;

export class LavishError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.name = 'LavishError';
    this.exitCode = exitCode;
  }
}

export function sha256Bytes(value) {
  return `sha256:${createHash('sha256').update(value).digest('hex')}`;
}

export async function sha256File(path) {
  return await new Promise((resolveDigest, rejectDigest) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('error', rejectDigest);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolveDigest(`sha256:${hash.digest('hex')}`));
  });
}

export function validateDecisionId(id) {
  if (typeof id !== 'string' || !ID_PATTERN.test(id)) {
    throw new LavishError(
      'decision id must be a lowercase slug of 1-64 letters, digits, or internal dashes',
      2,
    );
  }
  return id;
}

function requireString(value, label, { allowEmpty = false } = {}) {
  if (typeof value !== 'string' || (!allowEmpty && value.trim() === '')) {
    throw new LavishError(`${label} must be a ${allowEmpty ? '' : 'nonempty '}string`, 2);
  }
  return value;
}

function requireTimestamp(value, label) {
  requireString(value, label);
  if (!Number.isFinite(Date.parse(value))) {
    throw new LavishError(`${label} must be an ISO-8601 timestamp`, 2);
  }
  return value;
}

function requireDigest(value, label) {
  if (typeof value !== 'string' || !SHA_PATTERN.test(value)) {
    throw new LavishError(`${label} must be a sha256:<hex> digest`, 2);
  }
  return value;
}

function requirePlainObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new LavishError(`${label} must be an object`, 2);
  }
  return value;
}

function validateVisualFilename(value, label) {
  const filename = requireString(value, label);
  if (basename(filename) !== filename || filename === '.' || filename === '..') {
    throw new LavishError(`${label} must be a plain filename`, 2);
  }
  const mediaType = VISUAL_MEDIA_TYPES.get(extname(filename).toLowerCase());
  if (mediaType === undefined) {
    throw new LavishError(
      `${label} must use png, jpg, jpeg, gif, or webp`,
      2,
    );
  }
  return { filename, mediaType };
}

export function validateQuestions(questions) {
  if (!Array.isArray(questions) || questions.length === 0) {
    throw new LavishError('questions must be a nonempty array', 2);
  }

  const keys = new Set();
  return questions.map((rawQuestion, questionIndex) => {
    const question = requirePlainObject(rawQuestion, `questions[${questionIndex}]`);
    const key = requireString(question.key, `questions[${questionIndex}].key`);
    if (!ID_PATTERN.test(key)) {
      throw new LavishError(
        `questions[${questionIndex}].key must be a lowercase slug`,
        2,
      );
    }
    if (keys.has(key)) {
      throw new LavishError(`duplicate question key: ${key}`, 2);
    }
    keys.add(key);

    const prompt = requireString(
      question.prompt,
      `questions[${questionIndex}].prompt`,
    );
    if (!Array.isArray(question.options) || question.options.length === 0) {
      throw new LavishError(
        `questions[${questionIndex}].options must be a nonempty array`,
        2,
      );
    }
    const values = new Set();
    const options = question.options.map((rawOption, optionIndex) => {
      const option = requirePlainObject(
        rawOption,
        `questions[${questionIndex}].options[${optionIndex}]`,
      );
      const value = requireString(
        option.value,
        `questions[${questionIndex}].options[${optionIndex}].value`,
      );
      const label = requireString(
        option.label,
        `questions[${questionIndex}].options[${optionIndex}].label`,
      );
      if (values.has(value)) {
        throw new LavishError(`duplicate option value ${value} for question ${key}`, 2);
      }
      values.add(value);
      return { value, label };
    });
    let visuals = [];
    if (question.visuals !== undefined) {
      if (!Array.isArray(question.visuals)) {
        throw new LavishError(`questions[${questionIndex}].visuals must be an array`, 2);
      }
      const visualNames = new Set();
      visuals = question.visuals.map((rawVisual, visualIndex) => {
        const { filename } = validateVisualFilename(
          rawVisual,
          `questions[${questionIndex}].visuals[${visualIndex}]`,
        );
        if (visualNames.has(filename)) {
          throw new LavishError(`question ${key} repeats visual ${filename}`, 2);
        }
        visualNames.add(filename);
        return filename;
      });
    }
    return { key, prompt, options, ...(visuals.length === 0 ? {} : { visuals }) };
  });
}

export function validateDestination(destination) {
  requireString(destination, 'destination');
  if (isAbsolute(destination)) {
    throw new LavishError('destination must be relative to FM_HOME', 2);
  }
  const normalized = destination.split(/[\\/]+/);
  if (
    normalized.length < 2
    || normalized[0] !== 'data'
    || normalized.some((part) => part === '' || part === '.' || part === '..')
  ) {
    throw new LavishError(
      'destination must be a normalized file path below FM_HOME/data',
      2,
    );
  }
  if (destination.endsWith('/')) {
    throw new LavishError('destination must name a file', 2);
  }
  const normalizedPath = normalized.join('/');
  if (
    normalizedPath === DECISIONS_RELATIVE_DIR
    || normalizedPath.startsWith(`${DECISIONS_RELATIVE_DIR}/`)
  ) {
    throw new LavishError('destination must not overwrite the decision protocol directory', 2);
  }
  return normalizedPath;
}

export function validateManifest(raw, expectedId = undefined) {
  const manifest = requirePlainObject(raw, 'manifest');
  if (manifest.kind !== MANIFEST_KIND || manifest.schema_version !== SCHEMA_VERSION) {
    throw new LavishError('unsupported manifest kind or schema version', 2);
  }
  const decisionId = validateDecisionId(manifest.decision_id);
  if (expectedId !== undefined && decisionId !== expectedId) {
    throw new LavishError(
      `manifest decision id ${decisionId} does not match directory ${expectedId}`,
      2,
    );
  }
  const title = requireString(manifest.title, 'manifest.title');
  const createdAt = requireTimestamp(manifest.created_at, 'manifest.created_at');
  const destination = validateDestination(manifest.destination);
  let destinationFormat;
  if (manifest.destination_format !== undefined) {
    destinationFormat = requireString(
      manifest.destination_format,
      'manifest.destination_format',
    );
    if (!['answer-toon', 'payload-json-v2'].includes(destinationFormat)) {
      throw new LavishError('unsupported manifest.destination_format', 2);
    }
  }
  const requestSha256 = requireDigest(
    manifest.request_sha256,
    'manifest.request_sha256',
  );
  const questions = validateQuestions(manifest.questions);
  let visuals = [];
  if (manifest.visuals !== undefined) {
    if (!Array.isArray(manifest.visuals)) {
      throw new LavishError('manifest.visuals must be an array', 2);
    }
    if (manifest.visuals.length > MAX_VISUAL_COUNT) {
      throw new LavishError(
        `manifest.visuals exceeds the ${MAX_VISUAL_COUNT} file limit`,
        2,
      );
    }
    const filenames = new Set();
    let totalVisualBytes = 0;
    visuals = manifest.visuals.map((rawVisual, index) => {
      const visual = requirePlainObject(rawVisual, `manifest.visuals[${index}]`);
      const { filename, mediaType } = validateVisualFilename(
        visual.file,
        `manifest.visuals[${index}].file`,
      );
      if (filenames.has(filename)) {
        throw new LavishError(`manifest repeats visual ${filename}`, 2);
      }
      filenames.add(filename);
      if (visual.media_type !== mediaType) {
        throw new LavishError(`manifest visual media type does not match ${filename}`, 2);
      }
      const sha256 = requireDigest(visual.sha256, `manifest.visuals[${index}].sha256`);
      if (!Number.isInteger(visual.size) || visual.size < 0) {
        throw new LavishError(`manifest.visuals[${index}].size must be a nonnegative integer`, 2);
      }
      totalVisualBytes += visual.size;
      if (totalVisualBytes > MAX_VISUAL_BYTES) {
        throw new LavishError(
          `manifest.visuals exceeds the ${MAX_VISUAL_BYTES} byte total limit`,
          2,
        );
      }
      return { file: filename, media_type: mediaType, sha256, size: visual.size };
    });
  }
  const declaredVisuals = new Set(visuals.map((visual) => visual.file));
  for (const question of questions) {
    for (const filename of question.visuals ?? []) {
      if (!declaredVisuals.has(filename)) {
        throw new LavishError(
          `question ${question.key} references undeclared visual ${filename}`,
          2,
        );
      }
    }
  }
  if (!Number.isInteger(manifest.expected_count) || manifest.expected_count < 1) {
    throw new LavishError('manifest.expected_count must be a positive integer', 2);
  }
  if (manifest.expected_count !== questions.length) {
    throw new LavishError(
      `manifest expected_count ${manifest.expected_count} does not match ${questions.length} questions`,
      2,
    );
  }
  let legacySource;
  if (manifest.legacy_source !== undefined) {
    legacySource = requirePlainObject(manifest.legacy_source, 'manifest.legacy_source');
    requireString(legacySource.session_key, 'manifest.legacy_source.session_key');
    requireString(legacySource.file, 'manifest.legacy_source.file');
    requireString(legacySource.prompt_uid, 'manifest.legacy_source.prompt_uid');
  }
  return {
    kind: MANIFEST_KIND,
    schema_version: SCHEMA_VERSION,
    decision_id: decisionId,
    title,
    created_at: createdAt,
    destination,
    ...(destinationFormat === undefined ? {} : { destination_format: destinationFormat }),
    expected_count: manifest.expected_count,
    request_sha256: requestSha256,
    questions,
    ...(visuals.length === 0 ? {} : { visuals }),
    ...(legacySource === undefined ? {} : { legacy_source: legacySource }),
  };
}

export function validateAnswer(raw, manifest) {
  const answer = requirePlainObject(raw, 'answer');
  if (
    answer.kind !== ANSWER_KIND
    || ![SCHEMA_VERSION, ANSWER_SCHEMA_VERSION].includes(answer.schema_version)
  ) {
    throw new LavishError('unsupported answer kind or schema version', 2);
  }
  if (answer.decision_id !== manifest.decision_id) {
    throw new LavishError('answer decision id does not match manifest', 2);
  }
  if (answer.request_sha256 !== manifest.request_sha256) {
    throw new LavishError('answer request digest does not match manifest', 2);
  }
  requireTimestamp(answer.submitted_at, 'answer.submitted_at');
  if (!Array.isArray(answer.answers)) {
    throw new LavishError('answer.answers must be an array', 2);
  }
  if (answer.answers.length !== manifest.expected_count) {
    throw new LavishError(
      `answer count ${answer.answers.length} does not match expected count ${manifest.expected_count}`,
      2,
    );
  }

  const seen = new Set();
  const normalizedAnswers = answer.answers.map((rawSelection, index) => {
    const selection = requirePlainObject(rawSelection, `answer.answers[${index}]`);
    const expectedQuestion = manifest.questions[index];
    const key = requireString(selection.key, `answer.answers[${index}].key`);
    if (seen.has(key)) {
      throw new LavishError(`duplicate answer key: ${key}`, 2);
    }
    seen.add(key);
    if (key !== expectedQuestion.key) {
      throw new LavishError(
        `answer key ${key} is out of order; expected ${expectedQuestion.key}`,
        2,
      );
    }
    const value = requireString(selection.value, `answer.answers[${index}].value`);
    const option = expectedQuestion.options.find((candidate) => candidate.value === value);
    if (option === undefined) {
      throw new LavishError(`answer value ${value} is not an option for ${key}`, 2);
    }
    if (selection.label !== option.label) {
      throw new LavishError(`answer label does not match option ${value} for ${key}`, 2);
    }
    let questionNote = '';
    let optionComments = {};
    if (answer.schema_version === ANSWER_SCHEMA_VERSION) {
      questionNote = selection.question_note === undefined
        ? ''
        : requireString(
          selection.question_note,
          `answer.answers[${index}].question_note`,
          { allowEmpty: true },
        );
      if (selection.option_comments !== undefined) {
        const rawComments = requirePlainObject(
          selection.option_comments,
          `answer.answers[${index}].option_comments`,
        );
        const comments = new Map();
        for (const [optionValue, comment] of Object.entries(rawComments)) {
          if (!expectedQuestion.options.some((candidate) => candidate.value === optionValue)) {
            throw new LavishError(
              `answer comment value ${optionValue} is not an option for ${key}`,
              2,
            );
          }
          comments.set(optionValue, requireString(
            comment,
            `answer.answers[${index}].option_comments.${optionValue}`,
            { allowEmpty: true },
          ));
        }
        optionComments = Object.fromEntries(
          expectedQuestion.options
            .filter((candidate) => comments.has(candidate.value))
            .map((candidate) => [candidate.value, comments.get(candidate.value)]),
        );
      }
    }
    return {
      key,
      value,
      label: option.label,
      question_note: questionNote,
      option_comments: optionComments,
    };
  });

  const note = answer.note === undefined
    ? ''
    : requireString(answer.note, 'answer.note', { allowEmpty: true });
  return {
    kind: ANSWER_KIND,
    schema_version: answer.schema_version,
    decision_id: manifest.decision_id,
    request_sha256: manifest.request_sha256,
    submitted_at: answer.submitted_at,
    answers: normalizedAnswers,
    note,
  };
}

function payloadError(name, message) {
  throw new LavishError(`${name}: ${message}`, 2);
}

export function validateCollectPayload(raw, manifest) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    payloadError('payload_invalid', 'payload must be an object');
  }
  if (raw.schema_version !== ANSWER_SCHEMA_VERSION) {
    payloadError(
      'payload_schema_mismatch',
      `expected schema version ${ANSWER_SCHEMA_VERSION}`,
    );
  }
  if (raw.decision_id !== manifest.decision_id) {
    payloadError('payload_decision_mismatch', 'decision id does not match manifest');
  }
  if (raw.request_sha256 !== manifest.request_sha256) {
    payloadError('payload_stale_request', 'request hash does not match manifest');
  }
  if (!Array.isArray(raw.answers)) {
    payloadError('payload_count_mismatch', 'answers must be an array');
  }
  if (raw.answers.length !== manifest.expected_count) {
    payloadError(
      'payload_count_mismatch',
      `received ${raw.answers.length}; expected ${manifest.expected_count}`,
    );
  }

  const questionsByKey = new Map(
    manifest.questions.map((question) => [question.key, question]),
  );
  const answersByKey = new Map();
  for (const [index, rawSelection] of raw.answers.entries()) {
    if (
      rawSelection === null
      || typeof rawSelection !== 'object'
      || Array.isArray(rawSelection)
    ) {
      payloadError('payload_invalid_answer', `answer ${index} must be an object`);
    }
    if (typeof rawSelection.key !== 'string' || !questionsByKey.has(rawSelection.key)) {
      payloadError('payload_unknown_key', `unknown question key ${String(rawSelection.key)}`);
    }
    if (answersByKey.has(rawSelection.key)) {
      payloadError('payload_duplicate_key', `duplicate question key ${rawSelection.key}`);
    }
    const question = questionsByKey.get(rawSelection.key);
    const selected = question.options.find(
      (option) => option.value === rawSelection.value,
    );
    if (selected === undefined) {
      payloadError(
        'payload_unknown_option',
        `unknown option ${String(rawSelection.value)} for ${question.key}`,
      );
    }
    const questionNote = rawSelection.question_note === undefined
      ? ''
      : rawSelection.question_note;
    if (typeof questionNote !== 'string') {
      payloadError(
        'payload_invalid_annotation',
        `question note for ${question.key} must be a string`,
      );
    }
    const rawComments = rawSelection.option_comments === undefined
      ? {}
      : rawSelection.option_comments;
    if (
      rawComments === null
      || typeof rawComments !== 'object'
      || Array.isArray(rawComments)
    ) {
      payloadError(
        'payload_invalid_annotation',
        `option comments for ${question.key} must be an object`,
      );
    }
    const comments = new Map();
    for (const [optionValue, comment] of Object.entries(rawComments)) {
      if (!question.options.some((option) => option.value === optionValue)) {
        payloadError(
          'payload_unknown_option',
          `unknown annotated option ${optionValue} for ${question.key}`,
        );
      }
      if (typeof comment !== 'string') {
        payloadError(
          'payload_invalid_annotation',
          `comment for ${question.key}.${optionValue} must be a string`,
        );
      }
      comments.set(optionValue, comment);
    }
    const optionComments = Object.fromEntries(
      question.options
        .filter((option) => comments.has(option.value))
        .map((option) => [option.value, comments.get(option.value)]),
    );
    answersByKey.set(question.key, {
      key: question.key,
      value: selected.value,
      label: selected.label,
      question_note: questionNote,
      option_comments: optionComments,
    });
  }

  for (const question of manifest.questions) {
    if (!answersByKey.has(question.key)) {
      payloadError('payload_unknown_key', `missing question key ${question.key}`);
    }
  }
  const note = raw.note === undefined ? '' : raw.note;
  if (typeof note !== 'string') {
    payloadError('payload_invalid_annotation', 'overall note must be a string');
  }
  return {
    selections: manifest.questions.map((question) => answersByKey.get(question.key)),
    note,
  };
}

export function payloadFromAnswer(answer) {
  return {
    schema_version: ANSWER_SCHEMA_VERSION,
    decision_id: answer.decision_id,
    request_sha256: answer.request_sha256,
    answers: answer.answers.map((selection) => ({
      key: selection.key,
      value: selection.value,
      question_note: selection.question_note,
      option_comments: selection.option_comments,
    })),
    note: answer.note,
  };
}

export function encodeJsonPayload(payload) {
  return `${JSON.stringify(payload, null, 2)}\n`;
}

function destinationTextForAnswer(decision, answer, answerText) {
  if (decision.manifest.destination_format === 'payload-json-v2') {
    return encodeJsonPayload(payloadFromAnswer(answer));
  }
  return answerText;
}

export function validateReceipt(raw, manifest, answerSha256) {
  const receipt = requirePlainObject(raw, 'receipt');
  if (receipt.kind !== RECEIPT_KIND || receipt.schema_version !== SCHEMA_VERSION) {
    throw new LavishError('unsupported receipt kind or schema version', 2);
  }
  if (receipt.decision_id !== manifest.decision_id) {
    throw new LavishError('receipt decision id does not match manifest', 2);
  }
  if (receipt.answer_sha256 !== answerSha256) {
    throw new LavishError('receipt answer digest does not match answer', 2);
  }
  if (receipt.destination !== manifest.destination) {
    throw new LavishError('receipt destination does not match manifest', 2);
  }
  requireDigest(receipt.destination_sha256, 'receipt.destination_sha256');
  requireTimestamp(receipt.consumed_at, 'receipt.consumed_at');
  return receipt;
}

export function encodeToon(value) {
  return `${encode(value)}\n`;
}

export function decodeToon(text, label) {
  try {
    return decode(text, { strict: true });
  } catch (error) {
    throw new LavishError(`${label} is not valid strict TOON: ${error.message}`, 2);
  }
}

async function lstatIfPresent(path) {
  try {
    return await lstat(path, { bigint: false });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
}

async function assertNoSymlink(path, label) {
  try {
    await readlink(path);
  } catch (error) {
    if (error.code === 'EINVAL' || error.code === 'ENOENT') {
      return;
    }
    throw error;
  }
  throw new LavishError(`${label} must not be a symlink`, 2);
}

export async function ensureSafeDirectoryTree(home, targetDirectory, { create = false } = {}) {
  const realHome = resolve(home);
  const realTarget = resolve(targetDirectory);
  if (realTarget !== realHome && !realTarget.startsWith(`${realHome}${sep}`)) {
    throw new LavishError(`unsafe path outside FM_HOME: ${realTarget}`, 2);
  }
  await assertNoSymlink(realHome, 'FM_HOME');
  if (create) {
    await mkdir(realHome, { recursive: true, mode: 0o700 });
  }
  const rel = relative(realHome, realTarget);
  let cursor = realHome;
  if (rel !== '') {
    for (const part of rel.split(sep)) {
      cursor = join(cursor, part);
      await assertNoSymlink(cursor, cursor);
      const existing = await lstatIfPresent(cursor);
      if (existing === undefined) {
        if (!create) {
          throw new LavishError(`required directory is missing: ${cursor}`, 2);
        }
        await mkdir(cursor, { mode: 0o700 });
      } else if (!existing.isDirectory()) {
        throw new LavishError(`expected directory: ${cursor}`, 2);
      }
    }
  }
  return realTarget;
}

async function syncDirectory(path) {
  let handle;
  try {
    handle = await open(path, 'r');
    await handle.sync();
  } catch (error) {
    if (!['EINVAL', 'EBADF', 'EISDIR'].includes(error.code)) {
      throw error;
    }
  } finally {
    await handle?.close();
  }
}

export async function atomicWrite(path, content, {
  mode = 0o600,
  failIfExists = false,
  beforeRename = undefined,
} = {}) {
  const parent = dirname(path);
  await assertNoSymlink(parent, parent);
  await assertNoSymlink(path, path);
  if (failIfExists) {
    try {
      await access(path, fsConstants.F_OK);
      throw new LavishError(`refusing to overwrite existing file: ${path}`, 3);
    } catch (error) {
      if (error instanceof LavishError) {
        throw error;
      }
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
  }
  const token = randomBytes(8).toString('hex');
  const temporary = join(parent, `.${path.split(sep).at(-1)}.tmp-${process.pid}-${token}`);
  let handle;
  let committed = false;
  try {
    handle = await open(temporary, 'wx', mode);
    await handle.writeFile(content);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await beforeRename?.(temporary);
    if (failIfExists) {
      try {
        await access(path, fsConstants.F_OK);
        throw new LavishError(`refusing to overwrite existing file: ${path}`, 3);
      } catch (error) {
        if (error instanceof LavishError) {
          throw error;
        }
        if (error.code !== 'ENOENT') {
          throw error;
        }
      }
    }
    await rename(temporary, path);
    committed = true;
    await chmod(path, mode);
    await syncDirectory(parent);
  } finally {
    await handle?.close();
    if (!committed && process.env.LAVISH_TEST_KEEP_TEMP !== '1') {
      await rm(temporary, { force: true });
    }
  }
}

async function readDecisionVisuals(home, visualsDirectory, declaredVisuals) {
  const directoryState = await lstatIfPresent(visualsDirectory);
  if (directoryState === undefined) {
    if (declaredVisuals.length > 0) {
      throw new LavishError('manifest declares visuals but the visuals directory is missing', 2);
    }
    return [];
  }
  await ensureSafeDirectoryTree(home, visualsDirectory);
  const entries = (await readdir(visualsDirectory, { withFileTypes: true }))
    .filter((entry) => !entry.name.startsWith('.'))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (entries.length > MAX_VISUAL_COUNT) {
    throw new LavishError(
      `decision visuals exceed the ${MAX_VISUAL_COUNT} file limit`,
      2,
    );
  }
  const declaredByName = new Map(
    declaredVisuals.map((visual) => [visual.file, visual]),
  );
  const seen = new Set();
  const visuals = [];
  let totalBytes = 0;
  for (const entry of entries) {
    if (!entry.isFile() || entry.isSymbolicLink()) {
      throw new LavishError(`visual must be a regular file: ${entry.name}`, 2);
    }
    const { filename, mediaType } = validateVisualFilename(entry.name, 'visual filename');
    const visualPath = join(visualsDirectory, filename);
    await assertNoSymlink(visualPath, visualPath);
    const visualState = await lstat(visualPath);
    totalBytes += visualState.size;
    if (totalBytes > MAX_VISUAL_BYTES) {
      throw new LavishError(
        `decision visuals exceed the ${MAX_VISUAL_BYTES} byte total limit`,
        2,
      );
    }
    const sha256 = await sha256File(visualPath);
    const declared = declaredByName.get(filename);
    if (declared !== undefined) {
      if (declared.media_type !== mediaType) {
        throw new LavishError(`visual media type mismatch for ${filename}`, 2);
      }
      if (declared.size !== visualState.size) {
        throw new LavishError(`visual size mismatch for ${filename}`, 2);
      }
      if (declared.sha256 !== sha256) {
        throw new LavishError(`visual digest mismatch for ${filename}`, 2);
      }
      seen.add(filename);
    }
    visuals.push({
      file: filename,
      media_type: mediaType,
      sha256,
      size: visualState.size,
    });
  }
  for (const declared of declaredVisuals) {
    if (!seen.has(declared.file)) {
      throw new LavishError(`declared visual is missing: ${declared.file}`, 2);
    }
  }
  return visuals;
}

export async function readDecision(home, id) {
  validateDecisionId(id);
  const decisionDirectory = join(resolve(home), DECISIONS_RELATIVE_DIR, id);
  await ensureSafeDirectoryTree(home, decisionDirectory);
  const requestPath = join(decisionDirectory, 'request.md');
  const manifestPath = join(decisionDirectory, 'manifest.toon');
  await assertNoSymlink(requestPath, requestPath);
  await assertNoSymlink(manifestPath, manifestPath);
  const [request, manifestText] = await Promise.all([
    readFile(requestPath),
    readFile(manifestPath, 'utf8'),
  ]);
  const manifest = validateManifest(decodeToon(manifestText, manifestPath), id);
  const requestDigest = sha256Bytes(request);
  if (requestDigest !== manifest.request_sha256) {
    throw new LavishError(`request digest mismatch for ${id}`, 2);
  }
  const visualsDirectory = join(decisionDirectory, 'visuals');
  const visuals = await readDecisionVisuals(
    home,
    visualsDirectory,
    manifest.visuals ?? [],
  );
  return {
    id,
    directory: decisionDirectory,
    request,
    requestText: request.toString('utf8'),
    manifest,
    manifestText,
    visuals,
    visualsDirectory,
    answerPath: join(decisionDirectory, 'answer.toon'),
    receiptPath: join(decisionDirectory, 'receipt.toon'),
  };
}

export async function listDecisions(home) {
  const decisionsDirectory = join(resolve(home), DECISIONS_RELATIVE_DIR);
  await ensureSafeDirectoryTree(home, decisionsDirectory, { create: true });
  const entries = await readdir(decisionsDirectory, { withFileTypes: true });
  const decisions = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isDirectory() || !ID_PATTERN.test(entry.name)) {
      continue;
    }
    try {
      const decision = await readDecision(home, entry.name);
      const [answer, receipt] = await Promise.all([
        lstatIfPresent(decision.answerPath),
        lstatIfPresent(decision.receiptPath),
      ]);
      decisions.push({
        ...decision,
        status: receipt?.isFile() ? 'consumed' : answer?.isFile() ? 'answered' : 'pending',
      });
    } catch (error) {
      decisions.push({ id: entry.name, status: 'invalid', error });
    }
  }
  return decisions;
}

async function inspectVisualsDirectory(visualsDirectory) {
  if (visualsDirectory === undefined) {
    return [];
  }
  const sourceDirectory = resolve(visualsDirectory);
  const directoryState = await lstat(sourceDirectory);
  if (!directoryState.isDirectory() || directoryState.isSymbolicLink()) {
    throw new LavishError('--visuals must name a real directory, not a symlink', 2);
  }
  const entries = (await readdir(sourceDirectory, { withFileTypes: true }))
    .filter((entry) => !entry.name.startsWith('.'))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (entries.length > MAX_VISUAL_COUNT) {
    throw new LavishError(
      `--visuals contains ${entries.length} entries; maximum is ${MAX_VISUAL_COUNT}`,
      2,
    );
  }
  const visuals = [];
  let totalBytes = 0;
  for (const entry of entries) {
    if (!entry.isFile() || entry.isSymbolicLink()) {
      throw new LavishError(`visual must be a regular file: ${entry.name}`, 2);
    }
    const { filename, mediaType } = validateVisualFilename(entry.name, 'visual filename');
    const source = join(sourceDirectory, filename);
    const sourceState = await lstat(source);
    totalBytes += sourceState.size;
    if (totalBytes > MAX_VISUAL_BYTES) {
      throw new LavishError(
        `--visuals exceeds the ${MAX_VISUAL_BYTES} byte total limit`,
        2,
      );
    }
    visuals.push({
      source,
      file: filename,
      media_type: mediaType,
      sha256: await sha256File(source),
      size: sourceState.size,
    });
  }
  return visuals;
}

export async function createDecision(home, {
  id,
  title,
  request,
  destination,
  questions,
  visualsDirectory = undefined,
  createdAt = new Date().toISOString(),
  legacySource = undefined,
}) {
  validateDecisionId(id);
  requireString(title, 'title');
  requireTimestamp(createdAt, 'created_at');
  const normalizedDestination = validateDestination(destination);
  const destinationFormat = extname(normalizedDestination).toLowerCase() === '.json'
    ? 'payload-json-v2'
    : 'answer-toon';
  const normalizedQuestions = validateQuestions(questions);
  const requestBytes = Buffer.isBuffer(request) ? request : Buffer.from(request, 'utf8');
  if (requestBytes.length === 0) {
    throw new LavishError('request.md must not be empty', 2);
  }
  const sourceVisuals = await inspectVisualsDirectory(visualsDirectory);
  const visuals = sourceVisuals.map(({ source: _source, ...visual }) => visual);
  const requestDigest = sha256Bytes(requestBytes);
  const manifest = validateManifest({
    kind: MANIFEST_KIND,
    schema_version: SCHEMA_VERSION,
    decision_id: id,
    title,
    created_at: createdAt,
    destination: normalizedDestination,
    destination_format: destinationFormat,
    expected_count: normalizedQuestions.length,
    request_sha256: requestDigest,
    questions: normalizedQuestions,
    ...(visuals.length === 0 ? {} : { visuals }),
    ...(legacySource === undefined ? {} : { legacy_source: legacySource }),
  }, id);

  const decisionsDirectory = join(resolve(home), DECISIONS_RELATIVE_DIR);
  await ensureSafeDirectoryTree(home, decisionsDirectory, { create: true });
  const finalDirectory = join(decisionsDirectory, id);
  const existing = await lstatIfPresent(finalDirectory);
  if (existing !== undefined) {
    if (!existing.isDirectory()) {
      throw new LavishError(`decision path is not a directory: ${finalDirectory}`, 2);
    }
    const current = await readDecision(home, id);
    const currentComparable = {
      ...current.manifest,
      created_at: manifest.created_at,
    };
    const requestedComparable = { ...manifest };
    if (current.manifest.destination_format === undefined) {
      delete requestedComparable.destination_format;
    }
    if (
      current.request.equals(requestBytes)
      && JSON.stringify(currentComparable) === JSON.stringify(requestedComparable)
    ) {
      return { decision: current, created: false };
    }
    throw new LavishError(`decision ${id} already exists with different content`, 3);
  }

  const staging = join(
    decisionsDirectory,
    `.${id}.creating-${process.pid}-${randomBytes(8).toString('hex')}`,
  );
  await mkdir(staging, { mode: 0o700 });
  let committed = false;
  try {
    await atomicWrite(join(staging, 'request.md'), requestBytes, { failIfExists: true });
    await atomicWrite(join(staging, 'manifest.toon'), encodeToon(manifest), {
      failIfExists: true,
    });
    if (sourceVisuals.length > 0) {
      const stagingVisuals = join(staging, 'visuals');
      await mkdir(stagingVisuals, { mode: 0o700 });
      for (const visual of sourceVisuals) {
        const destinationPath = join(stagingVisuals, visual.file);
        await copyFile(visual.source, destinationPath, fsConstants.COPYFILE_EXCL);
        await chmod(destinationPath, 0o600);
        if (await sha256File(destinationPath) !== visual.sha256) {
          throw new LavishError(`visual changed while being copied: ${visual.file}`, 4);
        }
      }
      await syncDirectory(stagingVisuals);
    }
    await syncDirectory(staging);
    await rename(staging, finalDirectory);
    committed = true;
    await syncDirectory(decisionsDirectory);
  } finally {
    if (!committed) {
      await rm(staging, { recursive: true, force: true });
    }
  }
  return { decision: await readDecision(home, id), created: true };
}

async function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === 'ESRCH') {
      return false;
    }
    return true;
  }
}

export async function withDecisionLock(decisionDirectory, operation) {
  const lockPath = join(decisionDirectory, '.answer.lock');
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      await atomicWrite(
        join(lockPath, 'owner.json'),
        `${JSON.stringify({ pid: process.pid, created_at: new Date().toISOString() })}\n`,
        { failIfExists: true },
      );
      try {
        return await operation();
      } finally {
        await rm(lockPath, { recursive: true, force: true });
      }
    } catch (error) {
      if (error.code !== 'EEXIST') {
        throw error;
      }
      let owner;
      try {
        owner = JSON.parse(await readFile(join(lockPath, 'owner.json'), 'utf8'));
      } catch {
        owner = {};
      }
      const created = Number.isFinite(Date.parse(owner.created_at))
        ? Date.parse(owner.created_at)
        : 0;
      if (await pidAlive(owner.pid) && Date.now() - created < 300_000) {
        throw new LavishError('another lavish answer command is committing this decision', 4);
      }
      const stalePath = `${lockPath}.stale-${process.pid}-${randomBytes(4).toString('hex')}`;
      try {
        await rename(lockPath, stalePath);
        await rm(stalePath, { recursive: true, force: true });
      } catch (staleError) {
        if (staleError.code !== 'ENOENT') {
          throw staleError;
        }
      }
    }
  }
  throw new LavishError('could not acquire decision commit lock', 4);
}

export async function readAnswer(decision) {
  await assertNoSymlink(decision.answerPath, decision.answerPath);
  const text = await readFile(decision.answerPath, 'utf8');
  const answer = validateAnswer(decodeToon(text, decision.answerPath), decision.manifest);
  return { answer, text, digest: sha256Bytes(Buffer.from(text, 'utf8')) };
}

async function cleanStaleAnswerTemps(decisionDirectory) {
  const entries = await readdir(decisionDirectory, { withFileTypes: true });
  for (const entry of entries) {
    if (
      entry.isFile()
      && /^\.answer\.toon\.tmp-[0-9]+-[0-9a-f]{16}$/.test(entry.name)
    ) {
      await rm(join(decisionDirectory, entry.name), { force: true });
    }
  }
}

export async function commitAnswer(decision, selections, note, {
  submittedAt = new Date().toISOString(),
  beforeRename = undefined,
} = {}) {
  const answer = validateAnswer({
    kind: ANSWER_KIND,
    schema_version: ANSWER_SCHEMA_VERSION,
    decision_id: decision.id,
    request_sha256: decision.manifest.request_sha256,
    submitted_at: submittedAt,
    answers: selections,
    note,
  }, decision.manifest);
  const text = encodeToon(answer);
  await withDecisionLock(decision.directory, async () => {
    await cleanStaleAnswerTemps(decision.directory);
    const existing = await lstatIfPresent(decision.answerPath);
    if (existing !== undefined) {
      throw new LavishError(`decision ${decision.id} is already answered`, 3);
    }
    await atomicWrite(decision.answerPath, text, {
      failIfExists: true,
      beforeRename,
    });
  });
  return { answer, text, digest: sha256Bytes(Buffer.from(text, 'utf8')) };
}

async function copyFileAtomic(source, destination) {
  const parent = dirname(destination);
  const temporary = join(
    parent,
    `.${destination.split(sep).at(-1)}.tmp-${process.pid}-${randomBytes(8).toString('hex')}`,
  );
  let committed = false;
  try {
    await copyFile(source, temporary, fsConstants.COPYFILE_EXCL);
    const handle = await open(temporary, 'r+');
    await handle.sync();
    await handle.close();
    await chmod(temporary, 0o600);
    try {
      await link(temporary, destination);
    } catch (error) {
      if (error.code === 'EEXIST') {
        return false;
      }
      throw error;
    }
    await unlink(temporary);
    committed = true;
    await syncDirectory(parent);
    return true;
  } finally {
    if (!committed) {
      await rm(temporary, { force: true });
    }
  }
}

export async function intakeDecision(home, decision) {
  const { answer, text: answerText, digest: answerDigest } = await readAnswer(decision);
  const destinationText = destinationTextForAnswer(decision, answer, answerText);
  const expectedDestinationDigest = sha256Bytes(Buffer.from(destinationText, 'utf8'));
  const receiptState = await lstatIfPresent(decision.receiptPath);
  if (receiptState !== undefined) {
    const receiptText = await readFile(decision.receiptPath, 'utf8');
    const receipt = validateReceipt(
      decodeToon(receiptText, decision.receiptPath),
      decision.manifest,
      answerDigest,
    );
    const destinationPath = join(resolve(home), receipt.destination);
    const destinationDigest = await sha256File(destinationPath);
    if (destinationDigest !== receipt.destination_sha256) {
      throw new LavishError(`consumed destination digest changed for ${decision.id}`, 2);
    }
    return { status: 'already-consumed', receipt };
  }

  const destinationPath = join(resolve(home), decision.manifest.destination);
  const destinationParent = dirname(destinationPath);
  await ensureSafeDirectoryTree(home, destinationParent, { create: true });
  await assertNoSymlink(destinationPath, destinationPath);
  const destinationState = await lstatIfPresent(destinationPath);
  if (destinationState !== undefined) {
    if (!destinationState.isFile()) {
      throw new LavishError(`destination is not a regular file: ${destinationPath}`, 2);
    }
    const destinationDigest = await sha256File(destinationPath);
    if (destinationDigest !== expectedDestinationDigest) {
      throw new LavishError(
        `destination already exists with different content: ${decision.manifest.destination}`,
        3,
      );
    }
  } else {
    const temporary = join(
      destinationParent,
      `.${destinationPath.split(sep).at(-1)}.tmp-${process.pid}-${randomBytes(8).toString('hex')}`,
    );
    let committed = false;
    try {
      await atomicWrite(temporary, destinationText, { failIfExists: true });
      try {
        await link(temporary, destinationPath);
      } catch (error) {
        if (error.code !== 'EEXIST') {
          throw error;
        }
      }
      await rm(temporary, { force: true });
      await syncDirectory(destinationParent);
      committed = true;
    } finally {
      if (!committed) {
        await rm(temporary, { force: true });
      }
    }
    const concurrentDestinationState = await lstatIfPresent(destinationPath);
    if (concurrentDestinationState === undefined || !concurrentDestinationState.isFile()) {
      throw new LavishError(`destination is not a regular file: ${destinationPath}`, 2);
    }
    const concurrentDestinationDigest = await sha256File(destinationPath);
    if (concurrentDestinationDigest !== expectedDestinationDigest) {
      throw new LavishError(
        `destination already exists with different content: ${decision.manifest.destination}`,
        3,
      );
    }
  }

  const destinationSha256 = await sha256File(destinationPath);
  if (destinationSha256 !== expectedDestinationDigest) {
    throw new LavishError(`destination digest mismatch after write for ${decision.id}`, 2);
  }
  const receipt = {
    kind: RECEIPT_KIND,
    schema_version: SCHEMA_VERSION,
    decision_id: decision.id,
    answer_sha256: answerDigest,
    destination: decision.manifest.destination,
    destination_sha256: destinationSha256,
    consumed_at: new Date().toISOString(),
  };
  await atomicWrite(decision.receiptPath, encodeToon(receipt), { failIfExists: true });
  return { status: 'consumed', receipt, answerText };
}

export async function intakeAll(home) {
  const decisions = await listDecisions(home);
  const results = [];
  let failed = false;
  for (const decision of decisions) {
    if (decision.status === 'pending') {
      continue;
    }
    if (decision.status === 'invalid') {
      failed = true;
      results.push({ id: decision.id, status: 'invalid', detail: decision.error.message });
      continue;
    }
    if (decision.status === 'consumed') {
      continue;
    }
    try {
      const result = await intakeDecision(home, decision);
      results.push({ id: decision.id, status: result.status, detail: '' });
    } catch (error) {
      failed = true;
      results.push({ id: decision.id, status: 'error', detail: error.message });
    }
  }
  return { results, failed };
}
