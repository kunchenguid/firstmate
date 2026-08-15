#!/usr/bin/env node
// Slack Socket Mode transport. Business rules stay in fm-slack-socket-event.sh.

import { fileURLToPath } from 'node:url';

const defaultSleep = (delay) => new Promise((resolve) => setTimeout(resolve, delay));

function boundedDelay(attempt, minimum, maximum) {
  return Math.min(maximum, minimum * (2 ** Math.min(attempt, 10)));
}

export async function productionOpenSocket(appToken, {
  fetchImpl = globalThis.fetch,
  WebSocketImpl = globalThis.WebSocket,
} = {}) {
  const response = await fetchImpl('https://slack.com/api/apps.connections.open', {
    method: 'POST',
    headers: { authorization: `Bearer ${appToken}` },
  });
  const body = await response.json();
  if (!body.ok || typeof body.url !== 'string') {
    throw new Error(`apps.connections.open failed: ${body.error ?? 'invalid response'}`);
  }

  const frames = [];
  const waiters = [];
  let ended = false;
  let failure;
  const websocket = new WebSocketImpl(body.url);

  const publish = (entry) => {
    const waiter = waiters.shift();
    if (waiter) waiter.resolve(entry);
    else frames.push(entry);
  };
  websocket.onmessage = (event) => publish({ value: String(event.data), done: false });
  websocket.onerror = () => {
    failure = new Error('Socket Mode WebSocket error');
  };
  websocket.onclose = () => {
    ended = true;
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      if (failure) waiter.reject(failure);
      else waiter.resolve({ value: undefined, done: true });
    }
  };

  await new Promise((resolve, reject) => {
    websocket.onopen = resolve;
    const priorError = websocket.onerror;
    websocket.onerror = (event) => {
      priorError(event);
      reject(failure);
    };
  });

  return {
    send(payload) {
      websocket.send(payload);
    },
    [Symbol.asyncIterator]() {
      return {
        next() {
          if (frames.length > 0) return Promise.resolve(frames.shift());
          if (ended) {
            if (failure) return Promise.reject(failure);
            return Promise.resolve({ value: undefined, done: true });
          }
          return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
        },
      };
    },
  };
}

export async function consumeSocketMode({
  appToken,
  driver = { openSocket: productionOpenSocket },
  maxConnections = Number.POSITIVE_INFINITY,
  minBackoffMs = 1_000,
  maxBackoffMs = 30_000,
  onAlarm = () => {},
  onEvent,
  sleep = defaultSleep,
}) {
  if (!appToken || typeof onEvent !== 'function') throw new Error('Socket Mode requires a token and event handler');
  let connections = 0;
  let failedAttempts = 0;

  while (connections < maxConnections) {
    let connected = false;
    let failureRecorded = false;
    try {
      const socket = await driver.openSocket(appToken);
      connections += 1;
      for await (const raw of socket) {
        let frame;
        try {
          frame = JSON.parse(raw);
        } catch {
          continue;
        }
        if (frame.type === 'hello') {
          connected = true;
          failedAttempts = 0;
          continue;
        }
        if (frame.envelope_id) {
          socket.send(JSON.stringify({ envelope_id: frame.envelope_id }));
        }
        if (frame.payload?.event) {
          await onEvent({ envelope_id: frame.envelope_id ?? '', event: frame.payload.event });
        }
      }
    } catch (error) {
      onAlarm(error);
      failedAttempts += 1;
      failureRecorded = true;
    }

    if (!connected && !failureRecorded) {
      onAlarm(new Error('Socket Mode connection closed before hello'));
      failedAttempts += 1;
    }

    if (connections >= maxConnections) return;
    const attempt = connected ? 0 : Math.max(0, failedAttempts - 1);
    await sleep(boundedDelay(attempt, minBackoffMs, maxBackoffMs));
  }
}

async function main() {
  const appToken = process.env.FM_SLACK_APP_TOKEN ?? '';
  if (!appToken) process.exit(2);
  await consumeSocketMode({
    appToken,
    onAlarm: (error) => process.stderr.write(`slack-socket: ${error.message}\n`),
    onEvent: async (event) => process.stdout.write(`${JSON.stringify(event)}\n`),
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await main();
}
