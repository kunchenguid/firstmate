import * as fs from 'node:fs';
import path from 'node:path';

const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));

export const SHORT_RESULT_INLINE_CHARACTERS = 4096;
export const SHORT_RESULT_NOTICE_CHARACTERS = 1024;
export const SHORT_RESULT_LOADED_EVENT = 'firstmate:short-result-loaded';

function receiptAction(step) {
  return step.action === 'recover-sync' ? 'sync' : step.action;
}

function withinCharacters(value, limit) {
  let characters = 0;
  for (const _character of value) if (++characters > limit) return false;
  return true;
}

function successfulNotificationBinding(home, id) {
  if (!home || !path.isAbsolute(home) || !/^short-[a-f0-9]{64}$/.test(id)) return null;
  try {
    const canonicalHome = fs.realpathSync(home);
    const dir = path.join(canonicalHome, 'state/short-agents', id);
    const request = json(path.join(dir, 'request.json'));
    const result = json(path.join(dir, 'result.json'));
    if (![1, 2].includes(request.version) || request.id !== id || result.id !== id || result.state !== 'completed' ||
        result.evidence !== dir || typeof result.summary !== 'string') return null;
    const steps = request.input?.operations?.steps ?? [];
    if (!Array.isArray(steps)) return null;
    const receipts = steps.map((step, index) => json(path.join(dir, `operation-${index}.receipt.json`)));
    if (receipts.some((receipt, index) => receipt.id !== id || receipt.nonce !== request.nonce ||
        receipt.index !== index || receipt.action !== receiptAction(steps[index]) || receipt.state !== 'completed')) return null;
    const receiptText = receipts.length
      ? `\n\nVerified operation receipts:\n${receipts.map(receipt => JSON.stringify(receipt)).join('\n')}`
      : '';
    if (withinCharacters(result.summary, SHORT_RESULT_INLINE_CHARACTERS)) {
      return {
        inline: true,
        summary: result.summary,
        notification: `${id}: completed.\n\nResult:\n${result.summary}${receiptText}\n\nDurable result: ${dir}/result.json`,
      };
    }
    const reference = `state/short-agents/${id}/result.json`;
    const receiptNotice = receipts.length
      ? `\n\nVerified operation receipts: ${receipts.length}; retained beside the durable result.`
      : '';
    const notification = `${id}: completed.\n\nResult exceeds the ${SHORT_RESULT_INLINE_CHARACTERS}-Unicode-character inline notification limit. ` +
      `Load the complete unchanged result with fm_short_task action=result for this ShortTask.${receiptNotice}` +
      `\n\nDurable result relative to FM_HOME: ${reference}`;
    if (!withinCharacters(notification, SHORT_RESULT_NOTICE_CHARACTERS)) return null;
    return { inline: false, summary: result.summary, notification };
  } catch {
    return null;
  }
}

export function successfulNotification(home, id) {
  return successfulNotificationBinding(home, id)?.notification ?? null;
}

export function successfulInlineNotification(home, id) {
  const bound = successfulNotificationBinding(home, id);
  return bound?.inline ? bound.notification : null;
}

export function successfulResultSummary(home, id) {
  return successfulNotificationBinding(home, id)?.summary ?? null;
}
