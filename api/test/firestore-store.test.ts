import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createApp } from '../src/app.ts';
import { fakeCheck, fakeDictate, fakeListen, fakePatchify, fakeRoute, fakeTranscribe } from '../src/fake-ai.ts';
import { FirestoreStore } from '../src/firestore-store.ts';
import { seed } from '../src/seed.ts';

const host = process.env.FIRESTORE_EMULATOR_HOST;
const project = process.env.GOOGLE_CLOUD_PROJECT;

// エミュレータがあるときだけ回す（手順は README）
test('Firestore に保存しても、矛盾を確認して確定する流れが通る', { skip: !host && 'FIRESTORE_EMULATOR_HOST が未設定' }, async () => {
  await fetch(`http://${host}/emulator/v1/projects/${project}/databases/(default)/documents`, { method: 'DELETE' });
  const store = new FirestoreStore();
  await seed(store, 'demo');
  const app = createApp({ store, patchify: fakePatchify, check: fakeCheck, transcribe: fakeTranscribe, listen: fakeListen, dictate: fakeDictate, route: fakeRoute });
  const call = async (method: string, path: string, body: unknown) =>
    (await app.request(path, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })).json() as Promise<any>;

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
});
