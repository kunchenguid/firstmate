// OpenCode v2-to-v1 adapter shared by the primary plugins. Each plugin exports
// both a v1 named function and a v2 `export default { id, setup(ctx) }`; these
// helpers translate the v2 API onto the v1 hook shape so the adaptation exists
// once. The v2 loader requires `{ id, setup(ctx) }`, v2 events arrive from
// `ctx.event.subscribe()`, and a follow-up turn is forced with
// `ctx.session.prompt`.

export function clientFromCtx(ctx) {
  return {
    session: {
      promptAsync: ({ path, body }) =>
        ctx.session.prompt({ sessionID: path?.id, text: body?.parts?.[0]?.text ?? "" }),
    },
  };
}

// v2 events carry their payload under `data`; the v1 hooks read `properties`.
// v2 publishes no `session.idle`: a turn ends with a terminal
// `session.execution.*` event, which is mapped onto the v1 idle event.
const V2_TURN_END = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
];

export function v1Event(event) {
  const properties = event.data ?? {};
  if (V2_TURN_END.includes(event.type)) return { type: "session.idle", properties };
  return { type: event.type, properties };
}
