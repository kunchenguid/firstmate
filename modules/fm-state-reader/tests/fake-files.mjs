/** @returns {import('../src/ports/files').StateFiles & {set: (key: string, text: string) => void}} */
export function fakeFiles(records = {}, at = 1000) {
  const listeners = new Set();
  return {
    pools: Object.keys(records).filter(key => key.startsWith('pool:')),
    taskIds: () => Object.keys(records).filter(key => /^state\/[\w.-]+\.meta$/.test(key)).map(key => key.slice(6, -5)).sort(),
    read: key => key in records ? { text: records[key], at, truncated: false } : null,
    watch: changed => { listeners.add(changed); return () => listeners.delete(changed); },
    set: (key, text) => { records[key] = text; listeners.forEach(changed => changed()); },
  };
}
