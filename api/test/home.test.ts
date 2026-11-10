import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { demoManual, seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// アプリを開いたときに1本で読む GET /home（ADR 0021）

let app: ReturnType<typeof createApp>;
let store: MemoryStore;

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

/** demo のノート2冊（キッチン・ホール）。sato と kim はアカウントだけ */
beforeEach(async () => {
  store = new MemoryStore();
  await seed(store, 'demo');
  for (const id of ['demo', 'sato', 'kim']) {
    await store.putAccount({ id, salt: '', hash: '', createdAt: '' });
    await store.putSession({ id: sessionIdOf(`${id}-token`), userId: id, createdAt: '' });
  }
  await store.putProfile('sato', { name: '佐藤店長', icon: null });
  app = createApp({ store, ...ai });
});

async function callAs(who: string | null, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { ...(who ? { Authorization: `Bearer ${who}-token` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, json: (text ? JSON.parse(text) : null) as any };
}

/** 持ち主の側と相手の側の両方に、共有の記録を置く。並びを決めるため、共有した時刻を指定する */
async function share(manualId: string, to: string, at: string) {
  await store.put('demo', manualId, 'shares', { id: to, createdAt: at });
  await store.putShared(to, { id: manualId, ownerId: 'demo', createdAt: at });
}

test('ログインしていなければ 401', async () => {
  assert.equal((await callAs(null, 'GET', '/home')).status, 401);
});

test('自分・全部のノートの状態・未整理メモを1本で返す。ノートは GET /manuals → GET /shared と同じ並び', async () => {
  // sato のノートは、作った順と入れた順を逆にしておく
  await store.putManual('sato', { ...demoManual, id: 'sato-new', title: '新しいノート', createdAt: '2026-11-05T00:00:00.000Z' });
  await store.putManual('sato', { ...demoManual, id: 'sato-old', title: '古いノート', createdAt: '2026-11-04T00:00:00.000Z' });
  await share('demo-kitchen', 'sato', '2026-11-02T00:00:00.000Z');
  await share('demo-hall', 'sato', '2026-11-03T00:00:00.000Z');
  await store.putMemo('sato', { id: 'm2', at: '2026-11-06T10:00:00.000Z', text: 'あと' });
  await store.putMemo('sato', { id: 'm1', at: '2026-11-06T09:00:00.000Z', text: 'さき' });

  const { status, json } = await callAs('sato', 'GET', '/home');
  assert.equal(status, 200);
  assert.deepEqual(json.me, { id: 'sato', name: '佐藤店長', icon: null });

  const ids = json.notes.map((n: any) => n.manual.id);
  assert.deepEqual(ids, ['sato-new', 'sato-old', 'demo-hall', 'demo-kitchen']);
  const own = (await callAs('sato', 'GET', '/manuals')).json.map((m: any) => m.id);
  const shared = (await callAs('sato', 'GET', '/shared')).json.map((m: any) => m.id);
  assert.deepEqual(ids, [...own, ...shared]);

  // 1冊ずつの形は GET /manuals/:id と同じ。共有されたノートには持ち主が付く
  for (const n of json.notes) assert.deepEqual(n, (await callAs('sato', 'GET', `/manuals/${n.manual.id}`)).json);
  assert.deepEqual(
    json.notes.map((n: any) => n.sharedBy),
    [null, null, { id: 'demo', name: 'demo' }, { id: 'demo', name: 'demo' }],
  );

  assert.deepEqual(json.memos.map((m: any) => m.id), ['m1', 'm2']);
});

test('名前を決めていなければログイン ID を名前にし、ノートもメモも無ければ空で返す', async () => {
  const { json } = await callAs('kim', 'GET', '/home');
  assert.deepEqual(json, { me: { id: 'kim', name: 'kim', icon: null }, notes: [], memos: [], notices: { seenAt: null, items: [] } });
});

test('共有を外された直後で、相手の側の索引だけが残っているノートは入れない', async () => {
  await store.putShared('kim', { id: 'demo-kitchen', ownerId: 'demo', createdAt: '2026-11-02T00:00:00.000Z' });
  assert.deepEqual((await callAs('kim', 'GET', '/home')).json.notes, []);
});

test('通知（ADR 0020）：持ち主には GET /notices と同じ通知と見た時刻を返し、共有された人には自分のノートの分しか返さない', async () => {
  await share('demo-kitchen', 'sato', '2026-11-02T00:00:00.000Z');
  const edited = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす', today: '2026-11-10' });
  assert.equal(edited.status, 201);

  const home = (await callAs('demo', 'GET', '/home')).json.notices;
  assert.deepEqual(
    home.items.map(({ kind, manualId, by, line, text }: any) => ({ kind, manualId, by, line, text })),
    [{ kind: 'edit', manualId: 'demo-kitchen', by: { id: 'sato', name: '佐藤店長' }, line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす' }],
  );
  assert.deepEqual(home, (await callAs('demo', 'GET', '/notices')).json);
  // 共有されたノートでの出来事は、共有された人には知らせない
  assert.deepEqual((await callAs('sato', 'GET', '/home')).json.notices, { seenAt: null, items: [] });

  assert.equal((await callAs('demo', 'POST', '/notices/seen')).status, 204);
  const seen = (await callAs('demo', 'GET', '/home')).json.notices;
  assert.ok(seen.seenAt >= home.items[0].at);
  assert.deepEqual(seen, (await callAs('demo', 'GET', '/notices')).json);
});
