"use strict";

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
});
