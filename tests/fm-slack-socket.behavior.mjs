import assert from 'node:assert/strict';
import { createFakeSlackSocketDriver } from './fixtures/fake-slack-socket-driver.mjs';

const CASE = process.argv[2];

function envelope(id, text = 'status') {
  return {
    envelope_id: id,
    payload: {
      event: {
        type: 'message',
        channel: 'C0BQ9K1TJKG',
        user: 'U0CAPTAIN1',
        text,
        ts: '1786735224.690829',
      },
    },
  };
}

async function fakeControl() {
  const driver = createFakeSlackSocketDriver([[envelope('env-control')]]);
  const socket = await driver.openSocket('synthetic-token');
  const seen = [];
  for await (const raw of socket) {
    seen.push(JSON.parse(raw).envelope_id);
  }
  assert.deepEqual(seen, ['env-control', 'env-control']);
  assert.deepEqual(driver.state.acknowledgements, []);
  process.stdout.write('ok - fake redelivers an unacknowledged envelope\n');
}

async function loadConsumer() {
  return import('../bin/fm-slack-socket.mjs');
}

async function envelopeAck() {
  const { consumeSocketMode } = await loadConsumer();
  const driver = createFakeSlackSocketDriver([[
    { type: 'hello', connection_info: { app_id: 'A_TEST' } },
    envelope('env-ack'),
  ]]);
  const events = [];
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver,
    maxConnections: 1,
    onEvent: async (event) => events.push(event),
  });
  assert.deepEqual(driver.state.acknowledgements, ['env-ack']);
  assert.deepEqual(driver.state.deliveries, ['hello', 'env-ack']);
  assert.equal(events.length, 1);
  assert.equal(events[0].event.text, 'status');
  process.stdout.write('ok - consumer acks before the fake can redeliver\n');
}

async function reconnect() {
  const { consumeSocketMode } = await loadConsumer();
  const driver = createFakeSlackSocketDriver([
    [{ type: 'hello', connection_info: { app_id: 'A_TEST' } }],
    [{ type: 'hello', connection_info: { app_id: 'A_TEST' } }, envelope('env-after-reconnect')],
  ]);
  const delays = [];
  const alarms = [];
  const events = [];
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver,
    maxConnections: 2,
    minBackoffMs: 10,
    maxBackoffMs: 20,
    onAlarm: (error) => alarms.push(error),
    onEvent: async (event) => events.push(event),
    sleep: async (delay) => delays.push(delay),
  });
  assert.equal(driver.state.connections, 2);
  assert.deepEqual(delays, [10]);
  assert.deepEqual(alarms, []);
  assert.equal(events.length, 1);
  process.stdout.write('ok - clean disconnect reconnects within bounded backoff without alarm\n');
}

async function instantConnectFailure() {
  const { consumeSocketMode } = await loadConsumer();
  const healthy = createFakeSlackSocketDriver([[
    { type: 'hello', connection_info: { app_id: 'A_TEST' } },
  ]]);
  let attempts = 0;
  const startedAt = Date.now();
  const driver = {
    async openSocket(appToken) {
      attempts += 1;
      if (attempts < 3) throw new Error('synthetic instant connect failure');
      return healthy.openSocket(appToken);
    },
  };
  const alarms = [];
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver,
    maxConnections: 1,
    onAlarm: (error) => alarms.push(error),
    onEvent: async () => {},
  });
  const elapsedMs = Date.now() - startedAt;
  const ratePerSecond = (attempts / elapsedMs) * 1_000;
  assert.equal(attempts, 3);
  assert.ok(elapsedMs >= 2_800, `opened ${attempts} connections in ${elapsedMs}ms`);
  assert.ok(ratePerSecond <= 1.1, `opened ${Math.round(ratePerSecond)} connections/second`);
  assert.equal(alarms.length, 2);

  let capAttempts = 0;
  const defaultDelays = [];
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver: {
      async openSocket(appToken) {
        capAttempts += 1;
        if (capAttempts < 8) throw new Error('synthetic repeated connect failure');
        return healthy.openSocket(appToken);
      },
    },
    maxConnections: 1,
    onAlarm: () => {},
    onEvent: async () => {},
    sleep: async (delay) => defaultDelays.push(delay),
  });
  assert.deepEqual(defaultDelays, [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);

  let resetAttempts = 0;
  const resetDelays = [];
  const resetHealthy = createFakeSlackSocketDriver([[
    { type: 'hello', connection_info: { app_id: 'A_TEST' } },
  ]]);
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver: {
      async openSocket(appToken) {
        resetAttempts += 1;
        if (resetAttempts < 3) throw new Error('synthetic pre-hello connect failure');
        if (resetAttempts === 3) {
          return {
            send() {},
            async *[Symbol.asyncIterator]() {
              yield JSON.stringify({ type: 'hello', connection_info: { app_id: 'A_TEST' } });
              throw new Error('synthetic post-hello socket failure');
            },
          };
        }
        if (resetAttempts === 4) throw new Error('synthetic post-hello connect failure');
        return resetHealthy.openSocket(appToken);
      },
    },
    maxConnections: 2,
    minBackoffMs: 10,
    maxBackoffMs: 40,
    onAlarm: () => {},
    onEvent: async () => {},
    sleep: async (delay) => resetDelays.push(delay),
  });
  assert.deepEqual(resetDelays, [10, 20, 10, 20]);
  process.stdout.write(`ok - instant connect rate is bounded over ${elapsedMs}ms of wall-clock time\n`);
}

async function noHelloClose() {
  const { consumeSocketMode } = await loadConsumer();
  const driver = createFakeSlackSocketDriver([[], [], [], [], [], [], [], []]);
  const delays = [];
  const alarms = [];
  await consumeSocketMode({
    appToken: 'synthetic-token',
    driver,
    maxConnections: 8,
    onAlarm: (error) => alarms.push(error),
    onEvent: async () => {},
    sleep: async (delay) => delays.push(delay),
  });
  assert.deepEqual(delays, [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);
  assert.equal(alarms.length, 8);
  process.stdout.write('ok - a socket closing before hello escalates backoff and alarms\n');
}

async function productionErrorClose() {
  const { productionOpenSocket } = await loadConsumer();
  let websocket;
  class FakeWebSocket {
    constructor(url) {
      this.url = url;
      websocket = this;
      queueMicrotask(() => this.onopen?.());
    }

    send() {}
  }

  const socket = await productionOpenSocket('xapp-synthetic', {
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://slack.com/api/apps.connections.open');
      assert.equal(options.headers.authorization, 'Bearer xapp-synthetic');
      return { json: async () => ({ ok: true, url: 'wss://socket.test/connection' }) };
    },
    WebSocketImpl: FakeWebSocket,
  });
  assert.equal(websocket.url, 'wss://socket.test/connection');
  const pending = socket[Symbol.asyncIterator]().next();
  websocket.onerror({});
  websocket.onclose({});
  await assert.rejects(pending, /Socket Mode WebSocket error/);
  process.stdout.write('ok - production transport rejects a pending waiter after error-close\n');
}

switch (CASE) {
  case 'fake-control': await fakeControl(); break;
  case 'envelope-ack': await envelopeAck(); break;
  case 'reconnect': await reconnect(); break;
  case 'instant-connect-failure': await instantConnectFailure(); break;
  case 'no-hello-close': await noHelloClose(); break;
  case 'production-error-close': await productionErrorClose(); break;
  default: throw new Error(`unknown case: ${CASE}`);
}
