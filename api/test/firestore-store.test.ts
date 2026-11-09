import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createApp } from '../src/app.ts';
import { hashPassword, sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeDictate, fakeFormat, fakeListen, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { FirestoreStore } from '../src/firestore-store.ts';
import { seed } from '../src/seed.ts';

const host = process.env.FIRESTORE_EMULATOR_HOST;
const project = process.env.GOOGLE_CLOUD_PROJECT;

// エミュレータがあるときだけ回す（手順は README）
test('Firestore に保存しても、矛盾を確認して確定する流れが通る', { skip: !host && 'FIRESTORE_EMULATOR_HOST が未設定' }, async () => {
  await fetch(`http://${host}/emulator/v1/projects/${project}/databases/(default)/documents`, { method: 'DELETE' });
  const store = new FirestoreStore();
  await seed(store, 'demo');
  await store.putAccount({ id: 'demo', ...(await hashPassword('pass-demo')), createdAt: '' });
  const app = createApp({ store, assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, listen: fakeListen, dictate: fakeDictate });
  const send = (method: string, path: string, body: unknown, headers = {}) =>
    app.request(path, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  const { token } = (await (await send('POST', '/login', { id: 'demo', password: 'pass-demo' })).json()) as any;
  const call = async (method: string, path: string, body: unknown) =>
    (await send(method, path, body, { Authorization: `Bearer ${token}` })).json() as Promise<any>;

  const recorded = await call('POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた' });
  const check = recorded.state.checks[0];
  assert.equal(check.kind, 'contradiction');
  const resolved = await call('POST', `/manuals/demo-kitchen/checks/${check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
  });
  assert.ok(resolved.lines.some((l: any) => l.text === '- 塩 小さじ1/2' && l.patchId === resolved.checks[0].resolution.patchId));
  assert.equal(resolved.utterances.length, 2);

  // 確定済みの行を書き換えると確定と食い違うとして確認に入り、ノートのままで確定すると前の確定に戻る（#86・#83）
  const rewritten = await call('POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: '- 塩 小さじ1/2', text: '- 塩 小さじ1' });
  const rewrite = rewritten.patches.at(-1);
  const rechecked = await call('POST', `/manuals/demo-kitchen/patches/${rewrite.id}/check`, {});
  const recheck = rechecked.checks.find((c: any) => c.patchId === rewrite.id);
  assert.deepEqual([recheck.kind, recheck.conflictLine], ['contradiction', '- 塩 小さじ1/2']);
  const restored = await call('POST', `/manuals/demo-kitchen/checks/${recheck.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' });
  assert.deepEqual(restored.lines.filter((l: any) => l.text.startsWith('- 塩')).map((l: any) => l.text), ['- 塩 小さじ1/2']);

  // 名前とアイコンはノートの親のドキュメントに置くが、ノートは消えない
  await call('PUT', '/me', { name: 'かなで', icon: null });
  assert.equal((await (await send('GET', '/me', undefined, { Authorization: `Bearer ${token}` })).json() as any).name, 'かなで');
  assert.equal((await store.listManuals('demo')).length, 2);

  // 共有：相手の側の索引で持ち主を引き、持ち主のノートに書く。外すと両方の側から消える（ADR 0013）
  await store.putAccount({ id: 'sato', ...(await hashPassword('pass-sato')), createdAt: '' });
  await store.putSession({ id: sessionIdOf('sato-token'), userId: 'sato', createdAt: '' });
  const asSato = async (method: string, path: string, body?: unknown) => {
    const res = await send(method, path, body, { Authorization: 'Bearer sato-token' });
    return { status: res.status, json: (await res.json()) as any };
  };
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  assert.deepEqual((await asSato('GET', '/shared')).json.map((m: any) => m.id), ['demo-kitchen']);
  const edited = await asSato('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- だしは煮干し' });
  assert.equal(edited.status, 201);
  assert.ok((await store.list<any>('demo', 'demo-kitchen', 'utterances')).some((u) => u.editedBy === 'sato'));
  await call('DELETE', '/manuals/demo-kitchen/shares/sato', undefined);
  assert.equal((await asSato('GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual(await store.listShared('sato'), []);
  assert.deepEqual(await store.list('demo', 'demo-kitchen', 'shares'), []);

  // ノートを消すと、下のコレクションと相手の側の索引もまとめて消える（ADR 0014）
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  assert.equal((await send('DELETE', '/manuals/demo-kitchen', undefined, { Authorization: `Bearer ${token}` })).status, 204);
  assert.equal(await store.getManual('demo', 'demo-kitchen'), null);
  for (const name of ['utterances', 'patches', 'checks', 'shares']) assert.deepEqual(await store.list('demo', 'demo-kitchen', name), [], name);
  assert.deepEqual(await store.listShared('sato'), []);
  assert.equal((await store.listManuals('demo')).length, 1);

  // 未整理メモも名前とアイコンのドキュメントの下に置くが、名前は消えない（ADR 0014）
  const memo = await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '塩は小さじいち' });
  await call('PATCH', `/memos/${memo.id}`, { text: '塩は小さじ1' });
  assert.deepEqual(await store.listMemos('demo'), [{ ...memo, text: '塩は小さじ1' }]);
  assert.equal((await store.getProfile('demo'))?.name, 'かなで');
  await send('DELETE', `/memos/${memo.id}`, undefined, { Authorization: `Bearer ${token}` });
  assert.deepEqual(await store.listMemos('demo'), []);
});
