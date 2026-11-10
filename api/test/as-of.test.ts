import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// ノートの状態に、読み始める前の時刻（asOf）を付ける。応答の届く順が入れ替わっても、アプリが古い状態で新しい状態を戻さないため（ADR 0021）

/** ノートを読み始めた時刻を控え、読むのに少し時間がかかる保存先 */
class SlowStore extends MemoryStore {
  readAt: string[] = [];
  override async getManual(userId: string, id: string) {
    this.readAt.push(new Date().toISOString());
    await new Promise((r) => setTimeout(r, 5));
    return super.getManual(userId, id);
  }
}

let app: ReturnType<typeof createApp>;
let store: SlowStore;

beforeEach(async () => {
  store = new SlowStore();
  await seed(store, 'demo');
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  app = createApp({
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
  });
});

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-token' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as any };
}

const iso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

test('ノートの状態には、読み始める前の時刻を asOf として付ける', async () => {
  const before = new Date().toISOString();
  const { status, json } = await call('GET', '/manuals/demo-kitchen');
  assert.equal(status, 200);
  assert.match(json.asOf, iso);
  assert.ok(json.asOf >= before);
  assert.ok(json.asOf <= store.readAt[0], `${json.asOf} は読み始めた ${store.readAt[0]} より前`);
});

test('書き込みの応答の asOf は、書き込んだ後に読み始めた時刻で、前に読んだ状態より新しい', async () => {
  const read = (await call('GET', '/manuals/demo-kitchen')).json;
  const edited = await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- 胡椒 少々', today: '2026-11-10' });
  assert.equal(edited.status, 201);
  assert.ok(edited.json.asOf > read.asOf);
  assert.ok(edited.json.asOf >= edited.json.patches.at(-1).appliedAt);
});

test('GET /home のノートにも、1冊ずつ asOf を付ける', async () => {
  const { json } = await call('GET', '/home');
  assert.equal(json.notes.length, 2);
  for (const n of json.notes) assert.match(n.asOf, iso);
});
