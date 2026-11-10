import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// 直接編集の発言と差分の ID を、アプリが作って送る（ADR 0007 の 2026-11-10 の追記）

let app: ReturnType<typeof createApp>;

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

/** 持ち主 demo と、ノートを共有された sato */
beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  for (const id of ['demo', 'sato']) {
    await store.putAccount({ id, salt: '', hash: '', createdAt: '' });
    await store.putSession({ id: sessionIdOf(`${id}-token`), userId: id, createdAt: '' });
  }
  app = createApp({ store, ...ai });
  assert.equal((await callAs('demo', 'POST', '/manuals/demo-kitchen/shares', { userId: 'sato' })).status, 201);
});

async function callAs(who: string, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${who}-token` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
}

const edit = (who: string, body: object) =>
  callAs(who, 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: '- 塩 小さじ1', today: '2026-11-10', ...body });

const ids = { utteranceId: 'a1b2c3d4-0000-4000-8000-000000000001', patchId: 'a1b2c3d4-0000-4000-8000-000000000002' };

test('アプリが送った ID で、発言と差分を保存する', async () => {
  const { status, json } = await edit('demo', { text: '- だしは煮干し', ...ids });
  assert.equal(status, 201);
  const p = json.patches.find((x: any) => x.id === ids.patchId);
  assert.equal(p.utteranceId, ids.utteranceId);
  assert.ok(json.utterances.some((u: any) => u.id === ids.utteranceId && u.fromEdit));
  assert.equal(json.lines.find((l: any) => l.text === '- だしは煮干し').patchId, ids.patchId);
});

test('ID を省くと、今までどおりサーバーが作る', async () => {
  const { status, json } = await edit('demo', { text: '- だしは煮干し' });
  assert.equal(status, 201);
  const line = json.lines.find((l: any) => l.text === '- だしは煮干し');
  const p = json.patches.find((x: any) => x.id === line.patchId);
  assert.match(p.id, /^[0-9a-f-]{36}$/);
  assert.ok(json.utterances.some((u: any) => u.id === p.utteranceId));
});

test('今ある発言・差分と同じ ID は 409 で断り、何も書き換えない', async () => {
  const before = (await edit('demo', { text: '- だしは煮干し', ...ids })).json;
  // 共有された人が、持ち主の記録の ID を使って上書きしようとする
  for (const reused of [{ utteranceId: ids.utteranceId }, { patchId: ids.patchId }]) {
    const { status, json } = await edit('sato', { line: null, text: '- 書き換えた', ...reused });
    assert.equal(status, 409);
    assert.equal(json.conflict, undefined);
  }
  const after = (await callAs('demo', 'GET', '/manuals/demo-kitchen')).json;
  assert.deepEqual(after.utterances, before.utterances);
  assert.deepEqual(after.patches, before.patches);
  assert.deepEqual(after.lines, before.lines);
});

test('ID に使えない文字や短すぎる ID は 400 で断る', async () => {
  for (const patchId of ['short', '../a1b2c3d4-0000-4000', '__a1b2c3d4-0000-4000__', 'a1b2c3d4/0000-4000-8000']) {
    assert.equal((await edit('demo', { text: '- x', patchId })).status, 400);
  }
});
