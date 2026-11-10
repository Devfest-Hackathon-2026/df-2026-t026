import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { MemoryStore } from '../src/store.ts';

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

/** セッションを読んだ回数を数える */
class CountingStore extends MemoryStore {
  reads = 0;
  override async getSession(id: string) {
    this.reads++;
    return super.getSession(id);
  }
}

async function setup() {
  const store = new CountingStore();
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  const app = createApp({ store, ...ai });
  const me = async (token: string) => app.request('/me', { headers: { Authorization: `Bearer ${token}` } });
  return { store, me };
}

test('同じトークンで続けて呼んでも、セッションは1回しか読まない', async () => {
  const { store, me } = await setup();
  assert.equal(((await (await me('test-token')).json()) as any).id, 'demo');
  assert.equal(((await (await me('test-token')).json()) as any).id, 'demo');
  assert.equal(store.reads, 1);
});

test('知らないトークンは毎回読んで 401 にし、あとからできたセッションはすぐ通す', async () => {
  const { store, me } = await setup();
  assert.equal((await me('new-token')).status, 401);
  assert.equal((await me('new-token')).status, 401);
  assert.equal(store.reads, 2);
  // ほかのインスタンスでログインした直後でも弾かない
  await store.putSession({ id: sessionIdOf('new-token'), userId: 'sato', createdAt: '' });
  assert.equal(((await (await me('new-token')).json()) as any).id, 'sato');
});

test('覚えるのは1分だけで、過ぎたらもう一度読む', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: 0 });
  const { store, me } = await setup();
  await me('test-token');
  t.mock.timers.tick(60 * 1000 - 1);
  await me('test-token');
  assert.equal(store.reads, 1);
  t.mock.timers.tick(1);
  await me('test-token');
  assert.equal(store.reads, 2);
});

test('覚えた件数が増えすぎたら捨てて、読み直す', async () => {
  const { store, me } = await setup();
  await me('test-token');
  for (let i = 0; i < 1000; i++) {
    await store.putSession({ id: sessionIdOf(`token-${i}`), userId: 'demo', createdAt: '' });
    await me(`token-${i}`);
  }
  assert.equal(store.reads, 1001);
  await me('test-token');
  assert.equal(store.reads, 1002);
  assert.equal((await me('test-token')).status, 200);
  assert.equal(store.reads, 1002);
});
