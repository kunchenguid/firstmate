"use strict";

const ACTION_OPERATIONS_SCHEMA = "firstmate.fleet-board.action-operations.v1";
const MAX_ACTION_OPERATIONS = 100;
const MAX_PERSISTED_BYTES = 1_000_000;
const OPERATION_ID = /^[A-Za-z0-9._-]{1,160}$/;

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
  if (!draft.requestId) draft.requestId = makeRequestId();
  draft.attempted = true;
  draft.inFlight = true;
  drafts.set(cardKey, draft);
  return draft;
}

function serializeActionOperations(drafts) {
  const operations = [];
  for (const [cardKey, draft] of drafts) {
    if (
      operations.length >= MAX_ACTION_OPERATIONS
      || typeof cardKey !== "string"
      || !draft?.attempted
      || !OPERATION_ID.test(draft.requestId || "")
    ) continue;
    operations.push({
      cardKey,
      action: draft.action,
      text: draft.text,
      decisionKey: draft.decisionKey ?? null,
      requestId: draft.requestId,
      saved: draft.saved === true,
    });
  }
  return JSON.stringify({ schema: ACTION_OPERATIONS_SCHEMA, operations });
}

function restoreActionOperations(serialized) {
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
      || operation.text.length > 8000
      || !OPERATION_ID.test(operation.requestId || "")
      || (operation.decisionKey !== null && !OPERATION_ID.test(operation.decisionKey || ""))
    ) continue;
    drafts.set(operation.cardKey, {
      action: operation.action,
      text: operation.text,
      decisionKey: operation.decisionKey,
      requestId: operation.requestId,
      attempted: true,
      inFlight: false,
      saved: operation.saved === true,
    });
  }
  return drafts;
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
    if (!draftIsAvailable(draft, cardsByKey.get(key))) drafts.delete(key);
  }
  const selectedCard = selectedKey ? cardsByKey.get(selectedKey) || null : null;
  return { selectedKey: selectedCard ? selectedKey : null, selectedCard };
}

globalThis.FleetBoardState = Object.freeze({
  applyActionObservation,
  beginAction,
  cardFingerprint,
  draftIsAvailable,
  reconcileBoardState,
  restoreActionOperations,
  serializeActionOperations,
});
