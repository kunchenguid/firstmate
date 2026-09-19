// Request policy for a controller-owned Codex app-server connection.
// The host supplies protocol-envelope identity and a fixed operation adapter;
// model arguments never select a process, command, home, or thread.
export function createNotificationGate({ primaryThread, operate, isAlive }) {
  if (typeof primaryThread !== 'string' || !primaryThread ||
      typeof operate !== 'function' || typeof isAlive !== 'function') {
    throw new TypeError('A primary thread, operation adapter, and liveness source are required');
  }
  let activeTurn = null;
  let closed = false;
  let busy = false;
  let receipt = null;
  let challenge = null;
  let acknowledged = false;
  let offered = null;
  const offers = new Map();
  const seen = new Set();
  const retiredTurns = new Set();
  const deny = reason => ({ success: false, value: { denied: reason } });
  const recordOffer = (turn, value) => {
    let turnOffers = offers.get(turn);
    if (!turnOffers) {
      turnOffers = new Set();
      offers.set(turn, turnOffers);
    }
    turnOffers.add(value);
  };
  const wasOffered = (thread, turn, expectedReceipt) =>
    thread === primaryThread && offers.get(turn)?.has(expectedReceipt) === true;
  const valid = params => !closed && isAlive() && params.threadId === primaryThread &&
    typeof params.turnId === 'string' && params.turnId === activeTurn;

  return Object.freeze({
    beginTurn(thread, turn) {
      if (closed || thread !== primaryThread || typeof turn !== 'string' || !turn || activeTurn || retiredTurns.has(turn)) {
        throw new Error('Cannot register this turn');
      }
      activeTurn = turn;
    },
    endTurn(thread, turn) {
      if (thread === primaryThread && turn === activeTurn) {
        retiredTurns.add(turn);
        activeTurn = null;
      }
    },
    close() {
      closed = true;
      activeTurn = null;
    },
    async handle(params) {
      if (!params || !valid(params) || typeof params.callId !== 'string' || !params.callId) {
        return deny('wrong-thread-turn-or-replay');
      }
      const key = JSON.stringify([params.threadId, params.turnId, params.callId]);
      if (seen.has(key)) return deny('wrong-thread-turn-or-replay');
      seen.add(key);
      if (params.namespace != null) return deny('unexpected-namespace');
      const args = params.arguments;
      if (!args || Array.isArray(args) || typeof args !== 'object') return deny('invalid-arguments');
      if (busy) return deny('operation-in-progress');

      if (params.tool === 'fm_notification_check') {
        if (Object.keys(args).length) return deny('invalid-arguments');
        // Redelivery is read-only: cancellation or a lost response must not
        // strand pending work or start another native check before handling it.
        if (receipt && !acknowledged) {
          recordOffer(params.turnId, receipt);
          return { success: true, value: { ...offered } };
        }
      } else if (params.tool === 'fm_notification_ack') {
        if (Object.keys(args).sort().join(',') !== 'observed,receipt' || !receipt ||
            args.receipt !== receipt || args.observed !== challenge ||
            !wasOffered(params.threadId, params.turnId, receipt)) {
          return deny('wrong-receipt-or-unhandled-notification');
        }
        if (acknowledged) return deny('receipt-already-consumed');
      } else {
        return deny('unknown-tool');
      }

      busy = true;
      try {
        if (params.tool === 'fm_notification_check') {
          const result = await operate('check');
          if (result?.operationState === 'starting') {
            return valid(params) ? { success: false, value: { unavailable: 'startup-in-progress' } } : deny('wrong-thread-turn-or-replay');
          }
          if (result?.operationState === 'quiet') {
            return valid(params) ? { success: true, value: { quiet: true } } : deny('wrong-thread-turn-or-replay');
          }
          const note = result?.notification;
          if (result?.operationState !== 'delivered' || !note ||
              typeof note.receipt !== 'string' || !note.receipt ||
              typeof note.challenge !== 'string' || !note.challenge ||
              typeof note.message !== 'string') {
            throw new Error('Missing notification delivery');
          }
          receipt = note.receipt;
          challenge = note.challenge;
          acknowledged = false;
          offered = Object.freeze({ message: note.message, receipt, challenge, checkpointExit: note.checkpointExit });
          if (!valid(params)) return deny('wrong-thread-turn-or-replay');
          recordOffer(params.turnId, receipt);
          return { success: true, value: { ...offered } };
        }
        const result = await operate('ack', { receipt, observed: args.observed });
        if (result?.operationState !== 'acknowledged') throw new Error('Acknowledgement did not complete');
        acknowledged = true;
        if (!valid(params)) return deny('wrong-thread-turn-or-replay');
        return { success: true, value: { acknowledged: true } };
      } catch (error) {
        // A failed mutation may have partially completed. Never retry it based
        // on a missing response or manufacture a success; retain durable work.
        closed = true;
        return { success: false, value: { error: error.message } };
      } finally {
        busy = false;
      }
    },
    wasOffered,
  });
}

export function confirmAutomaticNotificationOffer(gate, thread, turn, receipt) {
  if (turn?.status !== 'completed') return false;
  if (!gate?.wasOffered(thread, turn.id, receipt)) {
    throw new Error('Automatic notification turn completed without receiving its pending receipt; durable work was preserved');
  }
  return true;
}
