#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import vm from 'node:vm';
import { parseHTML } from 'linkedom';

const statePath = process.env.LAVISH_FAKE_CHROME_STATE;
if (typeof statePath !== 'string' || statePath === '') {
  process.stderr.write('LAVISH_FAKE_CHROME_STATE is required\n');
  process.exit(2);
}

function loadState() {
  try {
    return JSON.parse(readFileSync(statePath, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return { open: false, submitted: false, storage: {} };
  }
}

function saveState(state) {
  writeFileSync(statePath, `${JSON.stringify(state)}\n`, { mode: 0o600 });
}

function executePage(url, state, { submit }) {
  const html = readFileSync(fileURLToPath(url), 'utf8');
  const { window, document } = parseHTML(html);
  Object.defineProperty(window, 'localStorage', {
    configurable: true,
    value: {
      getItem(key) {
        return state.storage[key] ?? null;
      },
      setItem(key, value) {
        state.storage[key] = String(value);
      },
    },
  });
  window.Blob = globalThis.Blob;
  window.URL = {
    createObjectURL: () => 'blob:lavish-fake-browser',
    revokeObjectURL: () => {},
  };
  window.scrollTo = () => {};
  window.setTimeout = (callback) => {
    callback();
    return 1;
  };
  const script = document.querySelector('script').textContent;
  vm.runInContext(script, vm.createContext(window));
  if (submit) {
    const selected = document.querySelector('input[type="radio"]');
    selected.checked = true;
    selected.setAttribute('checked', '');
    document.querySelector('#review-button').click();
    document.querySelector('#submit-button').click();
    if (Object.keys(state.storage).length === 0) {
      throw new Error('submit handler did not persist a browser record');
    }
  }
  state.title = document.title;
}

const [command, argument] = process.argv.slice(2);
const state = loadState();
try {
  switch (command) {
    case 'open':
      executePage(argument, state, {
        submit: process.env.LAVISH_FAKE_CHROME_AUTO_SUBMIT !== '0' && !state.submitted,
      });
      state.page = argument;
      state.open = true;
      if (process.env.LAVISH_FAKE_CHROME_AUTO_SUBMIT !== '0') state.submitted = true;
      saveState(state);
      break;
    case 'eval': {
      if (!state.open) process.exit(1);
      const durableRecord = Object.values(state.storage)[0] ?? null;
      process.stdout.write(`result: ${JSON.stringify({
        title: state.title,
        payload: null,
        durable_record: durableRecord,
      })}\n`);
      break;
    }
    case 'stop':
      state.open = false;
      saveState(state);
      break;
    default:
      process.stderr.write(`unsupported fake browser command: ${String(command)}\n`);
      process.exit(2);
  }
} catch (error) {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exit(1);
}
