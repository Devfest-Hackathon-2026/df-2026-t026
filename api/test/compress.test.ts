import assert from 'node:assert/strict';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import { gunzipSync } from 'node:zlib';

import { serve } from '@hono/node-server';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };
const origin = 'https://web.example';
const auth = { Authorization: 'Bearer test-token', Origin: origin };
const body = Array.from({ length: 300 }, (_, i) => `- 手順${i + 1}：棚の奥から順に並べ、賞味期限の近いものを手前に出す`).join('\n');

/** gzip なら解凍して JSON を読む。app.request はブラウザと違って解凍しない */
async function jsonOf(res: Response): Promise<unknown> {
  const raw = Buffer.from(await res.arrayBuffer());
  return JSON.parse((res.headers.get('Content-Encoding') === 'gzip' ? gunzipSync(raw) : raw).toString());
}

/** 本番と同じく許すオリジンを決めたアプリで、長い本文のノートを1冊作る */
async function setup() {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  const app = createApp({ store, ...ai, allowOrigin: origin });
  const res = await app.request('/manuals', {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: '品出し', body }),
  });
  assert.equal(res.status, 201);
  const { manual } = (await res.json()) as any;
  return { app, path: `/manuals/${manual.id}` };
}

test('大きい応答は gzip で返し、解凍すると圧縮しないときと同じ JSON になる', async () => {
  const { app, path } = await setup();
  const plain = await app.request(path, { headers: auth });
  assert.equal(plain.headers.get('Content-Encoding'), null);
  const expected = await plain.json();

  const res = await app.request(path, { headers: { ...auth, 'Accept-Encoding': 'gzip' } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('Content-Encoding'), 'gzip');
  // 読んだ時刻（asOf）は読むたびに変わる
  assert.deepEqual({ ...(await jsonOf(res)) as object, asOf: (expected as any).asOf }, expected);
  // CORS のヘッダーが落ちない
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), origin);
  assert.match(res.headers.get('Vary') ?? '', /Origin/);
  assert.match(res.headers.get('Vary') ?? '', /Accept-Encoding/);
});

test('Accept-Encoding の無い依頼は圧縮しない', async () => {
  const { app, path } = await setup();
  const res = await app.request(path, { headers: auth });
  assert.equal(res.headers.get('Content-Encoding'), null);
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), origin);
  assert.ok(((await res.json()) as any).lines.length >= 300);
});

test('ログインしていないときの 401 も、これまでどおり JSON で読める', async () => {
  const { app } = await setup();
  const res = await app.request('/me', { headers: { Origin: origin, 'Accept-Encoding': 'gzip' } });
  assert.equal(res.status, 401);
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal(((await jsonOf(res)) as any).error, 'ログインしてください');
});

test('本物のサーバー越しでも、gzip の応答を解凍して読める', async (t) => {
  const { app, path } = await setup();
  const server = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1' });
  await once(server, 'listening');
  t.after(() => server.close());
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  const big = await fetch(base + path, { headers: { ...auth, 'Accept-Encoding': 'gzip' } });
  assert.equal(big.headers.get('Content-Encoding'), 'gzip');
  assert.ok(((await big.json()) as any).lines.length >= 300);
});
