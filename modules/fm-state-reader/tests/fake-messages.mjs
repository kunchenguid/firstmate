/** In-memory MessagePort for application use-case tests; messages stay plain data. */
export function fakeMessages(entries = []) {
  let sequence = 0, closed = false;
  const open = () => { if (closed) throw Error('Service message port closed'); };
  const inbox = structuredClone(entries), calls = [];
  const receipt = () => ({ id: `msg-${(++sequence).toString(16).padStart(32, '0')}`, thread: 'fake-thread', delivered: [], partial: false });
  return {
    calls,
    async send(to, text, options) { open(); calls.push({ method: 'send', to: [...to], text, options: structuredClone(options) }); return { ...receipt(), delivered: [...to] }; },
    async reply(ref, text) { open(); calls.push({ method: 'reply', ref, text }); return receipt(); },
    async retry(id, thread) { open(); calls.push({ method: 'retry', id, thread }); return { ...receipt(), id, thread }; },
    async receive() { open(); return structuredClone(inbox); },
    async close() { closed = true; calls.push({ method: 'close' }); },
    async acknowledge(name) {
      open();
      const index = inbox.findIndex(entry => entry.name === name);
      if (index !== -1) inbox.splice(index, 1);
      calls.push({ method: 'acknowledge', name });
    },
  };
}
