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

function reconcileBoardState(pending, selectedKey, cards) {
  const cardsByKey = new Map(cards.map((card) => [card.key, card]));
  for (const [key, instruction] of pending) {
    const card = cardsByKey.get(key);
    if (!card || instruction.fingerprint !== cardFingerprint(card)) pending.delete(key);
  }
  const selectedCard = selectedKey ? cardsByKey.get(selectedKey) || null : null;
  return { selectedKey: selectedCard ? selectedKey : null, selectedCard };
}

globalThis.FleetBoardState = Object.freeze({ cardFingerprint, reconcileBoardState });
