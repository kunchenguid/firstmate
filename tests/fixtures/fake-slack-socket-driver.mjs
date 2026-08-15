export function createFakeSlackSocketDriver(connectionFrames) {
  const state = {
    acknowledgements: [],
    connections: 0,
    deliveries: [],
  };

  return {
    state,
    async openSocket() {
      const index = state.connections;
      state.connections += 1;
      const frames = connectionFrames[index] ?? [];
      const acknowledged = new Set();

      return {
        send(raw) {
          const parsed = JSON.parse(raw);
          if (parsed.envelope_id) {
            acknowledged.add(parsed.envelope_id);
            state.acknowledgements.push(parsed.envelope_id);
          }
        },
        async *[Symbol.asyncIterator]() {
          for (const frame of frames) {
            state.deliveries.push(frame.envelope_id ?? frame.type);
            yield JSON.stringify(frame);
            await Promise.resolve();
            if (frame.envelope_id && !acknowledged.has(frame.envelope_id)) {
              state.deliveries.push(frame.envelope_id);
              yield JSON.stringify(frame);
            }
          }
        },
      };
    },
  };
}
