(() => {
"use strict";

const ACTION_OPERATIONS_SCHEMA = "firstmate.fleet-board.action-operations.v1";
const MAX_ACTION_OPERATIONS = 100;
const MAX_PERSISTED_BYTES = 1_000_000;
const OPERATION_ID = /^[A-Za-z0-9._-]{1,160}$/;
const UTF8_ENCODER = new TextEncoder();

function actionStorageKey(scope) {
  if (!OPERATION_ID.test(scope || "")) throw new Error("Fleet board operation scope is invalid");
  return `${ACTION_OPERATIONS_SCHEMA}:${scope}`;
}

function normalizeActionText(text) {
  return typeof text === "string" ? text.trim() : text;
}

function actionTextError(text, maxBytes) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
    throw new Error("Fleet board action limit is invalid");
  }
  const normalized = normalizeActionText(text);
  if (typeof normalized !== "string" || !normalized) return "Action text is required";
  if (UTF8_ENCODER.encode(normalized).byteLength > maxBytes) {
    return `Keep the instruction at or below ${maxBytes.toLocaleString()} UTF-8 bytes`;
  }
  return null;
}

function cardFingerprint(card) {
  const decisions = [...(card.decisions || [])]
    .map((decision) => ({
      key: decision.key,
      verb: decision.verb,
      summary: decision.summary,
      reason: decision.reason,
    }))
    .sort((left, right) => String(left.key).localeCompare(String(right.key)));
  return JSON.stringify({ lane: card.lane, status: card.status, decisions });
}

function draftIsAvailable(draft, card) {
  if (!draft || !card) return false;
  if (draft.action === "request_details") return card.actions?.request_details === true;
  if (draft.action !== "answer" || card.actions?.answer !== true) return false;
  return (card.decisions || []).some((decision) => decision.key === draft.decisionKey);
}

function beginAction(drafts, cardKey, makeRequestId) {
  const draft = drafts.get(cardKey);
  if (!draft) throw new Error("Action draft is unavailable");
  draft.text = normalizeActionText(draft.text);
  if (!draft.requestId) draft.requestId = makeRequestId();
  draft.attempted = true;
  draft.inFlight = true;
  drafts.set(cardKey, draft);
  return draft;
}

function recordPendingAction(pending, cardKey, action, submissionFingerprint, currentCard) {
  if (!currentCard || cardFingerprint(currentCard) !== submissionFingerprint) {
    pending.delete(cardKey);
    return false;
  }
  pending.set(cardKey, { action, fingerprint: submissionFingerprint });
  return true;
}

function recordAcceptedAction(
  drafts,
  pending,
  cardKey,
  submissionFingerprint,
  currentCard,
  handled = false
) {
  const operation = drafts.get(cardKey);
  if (
    handled
    || !operation
    || !recordPendingAction(
      pending,
      cardKey,
      operation.action,
      submissionFingerprint,
      currentCard
    )
  ) {
    drafts.delete(cardKey);
    pending.delete(cardKey);
    return false;
  }
  operation.inFlight = false;
  operation.submitted = true;
  operation.fingerprint = submissionFingerprint;
  drafts.set(cardKey, operation);
  return true;
}

function updateValue(target, key, value) {
  if (target[key] === value) return false;
  target[key] = value;
  return true;
}

function updateLiveStatus(stateTarget, labelTarget, status, label) {
  const stateChanged = updateValue(stateTarget, "state", status);
  updateValue(labelTarget, "textContent", label);
  return stateChanged;
}

function shouldAnnounceLoadFailure(loadState, force, hadBoard) {
  if (force) return true;
  if (hadBoard || loadState.initialFailureAnnounced) return false;
  loadState.initialFailureAnnounced = true;
  return true;
}

function dialogDraftFingerprint(draft) {
  if (!draft) return null;
  return {
    action: draft.action,
    requestId: draft.requestId ?? null,
    attempted: draft.attempted === true,
    inFlight: draft.inFlight === true,
    saved: draft.saved === true,
    submitted: draft.submitted === true,
  };
}

function serializeActionOperations(drafts, maxBytes) {
  const operations = [];
  for (const [cardKey, draft] of drafts) {
    const text = normalizeActionText(draft?.text);
    const submitted = draft?.submitted === true;
    if (
      operations.length >= MAX_ACTION_OPERATIONS
      || typeof cardKey !== "string"
      || !draft?.attempted
      || actionTextError(text, maxBytes) !== null
      || !OPERATION_ID.test(draft.requestId || "")
      || (submitted && (typeof draft.fingerprint !== "string" || !draft.fingerprint))
    ) continue;
    operations.push({
      cardKey,
      action: draft.action,
      text,
      decisionKey: draft.decisionKey ?? null,
      requestId: draft.requestId,
      saved: draft.saved === true,
      submitted,
      fingerprint: submitted ? draft.fingerprint : null,
    });
  }
  return JSON.stringify({ schema: ACTION_OPERATIONS_SCHEMA, operations });
}

function restoreActionOperations(serialized, maxBytes) {
  const drafts = new Map();
  if (typeof serialized !== "string" || serialized.length > MAX_PERSISTED_BYTES) return drafts;
  let value;
  try {
    value = JSON.parse(serialized);
  } catch {
    return drafts;
  }
  if (value?.schema !== ACTION_OPERATIONS_SCHEMA || !Array.isArray(value.operations)) return drafts;
  for (const operation of value.operations.slice(0, MAX_ACTION_OPERATIONS)) {
    if (
      !operation
      || typeof operation.cardKey !== "string"
      || operation.cardKey.length > 360
      || !["answer", "request_details"].includes(operation.action)
      || typeof operation.text !== "string"
      || actionTextError(operation.text, maxBytes) !== null
      || !OPERATION_ID.test(operation.requestId || "")
      || (operation.decisionKey !== null && !OPERATION_ID.test(operation.decisionKey || ""))
      || (operation.submitted === true
        && (typeof operation.fingerprint !== "string" || !operation.fingerprint))
    ) continue;
    drafts.set(operation.cardKey, {
      action: operation.action,
      text: normalizeActionText(operation.text),
      decisionKey: operation.decisionKey,
      requestId: operation.requestId,
      attempted: true,
      inFlight: false,
      saved: operation.saved === true,
      submitted: operation.submitted === true,
      fingerprint: operation.submitted === true ? operation.fingerprint : null,
    });
  }
  return drafts;
}

function submittedRequestIds(drafts) {
  return [...drafts.values()]
    .filter((draft) => draft?.submitted === true && OPERATION_ID.test(draft.requestId || ""))
    .map((draft) => draft.requestId);
}

function clearHandledActionOperations(pending, drafts, statuses) {
  let changed = false;
  for (const [cardKey, draft] of drafts) {
    if (draft?.submitted !== true || statuses?.[draft.requestId] !== "handled") continue;
    drafts.delete(cardKey);
    pending.delete(cardKey);
    changed = true;
  }
  return changed;
}

function syncStoredActionOperations(current, serialized, maxBytes) {
  const stored = restoreActionOperations(serialized, maxBytes);
  for (const [cardKey, draft] of current) {
    if ((!draft?.attempted || draft.inFlight === true) && !stored.has(cardKey)) {
      stored.set(cardKey, draft);
    }
  }
  return stored;
}

function applyActionObservation(board, result) {
  if (!board || result?.observation !== "stale-last-good") return board;
  return {
    ...board,
    health: {
      ...(board.health || {}),
      ...(result.health || {}),
      stale: true,
    },
  };
}

function reconcileBoardState(pending, drafts, selectedKey, cards) {
  const cardsByKey = new Map(cards.map((card) => [card.key, card]));
  for (const [key, instruction] of pending) {
    const card = cardsByKey.get(key);
    if (!card || instruction.fingerprint !== cardFingerprint(card)) pending.delete(key);
  }
  for (const [key, draft] of drafts) {
    const card = cardsByKey.get(key);
    if (draft.submitted === true) {
      if (!draftIsAvailable(draft, card)) {
        drafts.delete(key);
        pending.delete(key);
      } else {
        draft.fingerprint = cardFingerprint(card);
        pending.set(key, { action: draft.action, fingerprint: draft.fingerprint });
      }
    } else if (!draftIsAvailable(draft, card)) {
      drafts.delete(key);
    }
  }
  const selectedCard = selectedKey ? cardsByKey.get(selectedKey) || null : null;
  return { selectedKey: selectedCard ? selectedKey : null, selectedCard };
}

globalThis.FleetBoardState = Object.freeze({
  actionStorageKey,
  actionTextError,
  applyActionObservation,
  beginAction,
  cardFingerprint,
  clearHandledActionOperations,
  dialogDraftFingerprint,
  draftIsAvailable,
  normalizeActionText,
  reconcileBoardState,
  recordAcceptedAction,
  recordPendingAction,
  restoreActionOperations,
  serializeActionOperations,
  shouldAnnounceLoadFailure,
  submittedRequestIds,
  syncStoredActionOperations,
  updateLiveStatus,
  updateValue,
});
})();
