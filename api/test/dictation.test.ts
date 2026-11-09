import assert from 'node:assert/strict';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';

import { serve } from '@hono/node-server';
import { WebSocketServer } from 'ws';

import { createApp, type Deps } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

/** 本物のサーバーを立て、demo としてログインして音声入力の WebSocket につなげる URL を返す */
async function start(t: { after(fn: () => void): void }, deps: Partial<Deps> = {}) {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  const app = createApp({
    store,
    assess: fakeAssess,
    check: fakeCheckPatch,
    transcribe: fakeTranscribe,
    format: fakeFormat,
    readNote: fakeReadNote,
    readMaterial: fakeReadMaterial,
    countTokens: fakeCountTokens,
    listen: fakeListen,
    dictate: fakeDictate,
    ...deps,
  });
  const wss = new WebSocketServer({ noServer: true });
  const server = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1', websocket: { server: wss } });
  await once(server, 'listening');
  t.after(() => {
    wss.close();
    server.close();
  });
  const base = `ws://127.0.0.1:${(server.address() as AddressInfo).port}/dictation`;
  return { url: `${base}?token=test-token`, base, store };
}

/** 音声を送り、届いた文面を集めて、閉じられるまで待つ */
async function dictate(url: string, chunks: number[]) {
  const ws = new WebSocket(url);
  const got: any[] = [];
  ws.onmessage = (e) => got.push(JSON.parse(e.data as string));
  await once(ws, 'open');
  for (const n of chunks) ws.send(new Uint8Array(n));
  ws.send('end');
  await once(ws, 'close');
  return got;
}

test('音声入力：話している途中から文面を返し、end で確定の文面を返して閉じる', async (t) => {
  const { url, store } = await start(t);
  const got = await dictate(url, [8000, 8000, 8000]);
  assert.deepEqual(got, [{ text: '佐' }, { text: '佐藤' }, { text: '佐藤さ' }, { text: '佐藤さ', done: true }]);
  // 書き起こすだけで記録はしない
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, 0);
});

test('音声入力：登録したマニュアルの語句をフレーズヒントに渡す', async (t) => {
  let phrases: string[] = [];
  const { url } = await start(t, {
    dictate: async (p, on) => {
      phrases = p;
      return { write() {}, end: () => on.done('') };
    },
  });
  await dictate(url, []);
  assert.ok(phrases.includes('レジ締め'));
  assert.ok(phrases.includes('お冷や'));
});

test('音声入力：書き起こしに失敗したら、どうすればいいかを返して閉じる', async (t) => {
  const { url } = await start(t, {
    dictate: async () => {
      throw new Error('Speech-to-Text に権限がない');
    },
  });
  const got = await dictate(url, [8000]);
  assert.deepEqual(got, [{ error: '書き起こせませんでした。もう一度話すか、文字で書いてください' }]);
});

test('音声入力：ログインのトークンはクエリで受け、違えばつながない', async (t) => {
  const { url, base } = await start(t);
  const ok = await dictate(url, [8000]);
  assert.equal(ok.at(-1).done, true);

  for (const wrong of [base, `${base}?token=made-up-token`]) {
    const ws = new WebSocket(wrong);
    const [e] = await once(ws, 'close');
    assert.notEqual((e as CloseEvent).code, 1000);
  }
});
