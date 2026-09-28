import * as fs from 'node:fs';
import path from 'node:path';

const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));

function receiptAction(step) {
  return step.action === 'recover-sync' ? 'sync' : step.action;
}

export function successfulNotification(home, id) {
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
    return `${id}: completed.\n\nResult:\n${result.summary}${receiptText}\n\nDurable result: ${dir}/result.json`;
  } catch {
    return null;
  }
}
