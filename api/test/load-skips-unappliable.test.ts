import assert from 'node:assert/strict';
import { beforeEach, mock, test } from 'node:test';

import { createApp } from '../src/app.ts';
import type { Assess } from '../src/assess.ts';
import { sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { render, type Patch, type PatchDraft, type Utterance } from '../src/foundation/manual.ts';
import { demoManual, seed, seedWithHistory } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// 書き込みが重なって、反映順に並べると当たらないパッチが残ったノートでも開けること（ADR 0001）

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

let warn: ReturnType<typeof mock.method<Console, 'warn'>>;

beforeEach(() => {
  mock.restoreAll();
  warn = mock.method(console, 'warn', () => {});
});

const warned = () => warn.mock.calls.map((c) => c.arguments[0] as string);

async function open(store: MemoryStore, assess: Assess = fakeAssess) {
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  const app = createApp({ store, ...ai, assess });
  return async (method: string, path: string, body?: unknown) => {
    const res = await app.request(path, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-token' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
  };
}

/** 返った patches の反映済みだけを反映順に当て直したもの。アプリの履歴（app/lib/history.dart）と同じ当て方 */
const replay = (json: any) => render(demoManual.base, json.patches);
const statusOf = (json: any, id: string) => {
  const p = json.patches.find((x: any) => x.id === id);
  return { status: p.status, appliedAt: p.appliedAt };
};
const texts = (json: any) => json.lines.map((l: any) => l.text as string);

const at = (n: number) => `2026-11-01T00:00:0${n}.000Z`;
const tick = (ms = 2) => new Promise((res) => setTimeout(res, ms));

/**
 * 保存の層に直接書いて、重なった書き込みのあとの状態を作る。
 * p1 が「大盛り」の行を書き換えたあとに、書き換える前の行を指す p2 と、p2 が足すはずだった行を指す p3 が反映されている。
 * p4 は関係のない行を直したもの
 */
async function broken() {
  const store = new MemoryStore();
  await seed(store, 'demo');
  const drafts: [string, Pick<PatchDraft, 'op' | 'line' | 'text'>][] = [
    ['p1', { op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは300gまで' }],
    ['p2', { op: 'insert', line: '- 大盛りは250gまで', text: '- おかわりは1回まで' }],
    ['p3', { op: 'insert', line: '- おかわりは1回まで', text: '- 2回目からは有料' }],
    ['p4', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす' }],
  ];
  for (const [i, [id, draft]] of drafts.entries()) {
    const u: Utterance = { id: `u-${id}`, text: '言われたこと', speaker: '田中さん', saidAt: '2026-11-01', createdAt: at(i + 1) };
    const p: Patch = { ...draft, id, utteranceId: u.id, summary: '補足', status: 'applied', createdAt: at(i + 1), appliedAt: at(i + 1) };
    await store.put('demo', 'demo-kitchen', 'utterances', u);
    await store.put('demo', 'demo-kitchen', 'patches', p);
  }
  return { store, call: await open(store) };
}

test('当たらない差分は当てずに未反映として返し、その差分が足すはずだった行を指す差分も飛ばす', async () => {
  const { store, call } = await broken();
  const { status, json } = await call('GET', '/manuals/demo-kitchen');
  assert.equal(status, 200);
  assert.deepEqual(statusOf(json, 'p1'), { status: 'applied', appliedAt: at(1) });
  assert.deepEqual(statusOf(json, 'p2'), { status: 'proposed', appliedAt: null });
  assert.deepEqual(statusOf(json, 'p3'), { status: 'proposed', appliedAt: null });
  assert.deepEqual(statusOf(json, 'p4'), { status: 'applied', appliedAt: at(4) });
  assert.ok(texts(json).includes('- 大盛りは300gまで'));
  assert.ok(texts(json).includes('- 炊けたら15分蒸らす'));
  assert.ok(!texts(json).includes('- おかわりは1回まで'));
  assert.ok(!texts(json).includes('- 2回目からは有料'));
  // 返った行と、返った差分の反映済みだけを当て直した行（履歴）が食い違わない
  assert.deepEqual(replay(json), json.lines);

  // 保存してある中身は書き換えないので、読むたびに同じになる（読んだ時刻 asOf のほか）
  assert.deepEqual({ ...(await call('GET', '/manuals/demo-kitchen')).json, asOf: json.asOf }, json);
  const stored = await store.list<Patch>('demo', 'demo-kitchen', 'patches');
  assert.deepEqual(
    stored.filter((p) => p.id === 'p2' || p.id === 'p3').map((p) => [p.status, p.appliedAt]),
    [
      ['applied', at(2)],
      ['applied', at(3)],
    ],
  );

  // 一覧も開ける
  assert.equal((await call('GET', '/manuals')).status, 200);
});

test('飛ばした差分は、持ち主・ノート・差分の ID だけを1行の JSON でログに残す', async () => {
  const { call } = await broken();
  await call('GET', '/manuals/demo-kitchen');
  const logs = warned();
  assert.deepEqual(
    logs.map((x) => JSON.parse(x)),
    ['p2', 'p3'].map((patchId) => ({ severity: 'WARNING', message: 'skipped unappliable patch', owner: 'demo', manualId: 'demo-kitchen', patchId })),
  );
  for (const x of logs) {
    assert.ok(!x.includes('\n'));
    assert.ok(!x.includes('大盛り') && !x.includes('おかわり'));
  }
});

test('未反映になった差分は、今の行に当たるなら書き込み直せ、当たらなければ 409 になる', async () => {
  const { call } = await broken();
  assert.equal((await call('POST', '/manuals/demo-kitchen/patches/p2/apply')).status, 409);
  assert.equal((await call('POST', '/manuals/demo-kitchen/patches/p3/apply')).status, 409);

  // p2 が指す行を戻すと、p2、続けて p3 を書き込み直せる
  const e = await call('POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: '- 大盛りは300gまで', text: '- 大盛りは250gまで', today: '2026-11-10' });
  assert.equal(e.status, 201);
  // 反映日時が同じミリ秒だと記録した順に並び、前に記録した p2 が編集より先に当たってしまう
  await tick();
  const a2 = await call('POST', '/manuals/demo-kitchen/patches/p2/apply');
  assert.equal(a2.status, 200);
  assert.equal(statusOf(a2.json, 'p2').status, 'applied');
  assert.equal(statusOf(a2.json, 'p3').status, 'proposed');
  assert.deepEqual(replay(a2.json), a2.json.lines);
  const a3 = await call('POST', '/manuals/demo-kitchen/patches/p3/apply');
  assert.equal(a3.status, 200);
  const rice = texts(a3.json).slice(texts(a3.json).indexOf('- 大盛りは250gまで'));
  assert.deepEqual(rice.slice(0, 3), ['- 大盛りは250gまで', '- おかわりは1回まで', '- 2回目からは有料']);
  assert.deepEqual(replay(a3.json), a3.json.lines);

  // すべて当たるようになれば、もう飛ばさない
  warn.mock.resetCalls();
  const { json } = await call('GET', '/manuals/demo-kitchen');
  assert.ok(json.patches.every((p: any) => p.status === 'applied'));
  assert.deepEqual(warned(), []);
});

/** 割り込みを起こすため、書き込みの /apply が保存する直前で止める */
class GateStore extends MemoryStore {
  gate: Promise<void> | null = null;
  hit: (() => void) | null = null;
  override async put<T extends { id: string }>(userId: string, manualId: string, collection: string, doc: T) {
    const p = doc as unknown as Patch;
    if (this.gate && collection === 'patches' && p.status === 'applied' && p.summary === '補足') {
      this.hit?.();
      await this.gate;
    }
    return super.put(userId, manualId, collection, doc);
  }
}

test('書き込み（/apply）の間に、書き換える前の行の下へ直接足しても、ノートは開ける', async () => {
  const store = new GateStore();
  await seed(store, 'demo');
  const call = await open(store, async () => ({
    speaker: '田中さん',
    saidAt: '2026-11-10',
    items: [
      {
        manual: 0,
        patch: { op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは250gまで（ランチは300g）', summary: '補足' },
        check: { kind: 'qualification', conflictLine: null, sameLine: null, reason: '条件付き', ask: null, materialRef: null },
      },
    ],
  }));
  const r = await call('POST', '/utterances', { text: '田中さんからランチの大盛りは300gと言われた', manualIds: ['demo-kitchen'] });
  const said = r.json.results[0];
  const p = said.state.patches.find((x: any) => x.utteranceId === said.utteranceId);

  let release!: () => void;
  store.gate = new Promise<void>((res) => (release = res));
  const hit = new Promise<void>((res) => (store.hit = res));
  const applying = call('POST', `/manuals/demo-kitchen/patches/${p.id}/apply`);
  await hit;
  // /apply が反映日時を決めたあとに、編集の反映日時が来るようにする
  await tick(5);
  const e = await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: '- 大盛りは250gまで', text: '- 新しい行', today: '2026-11-10' });
  assert.equal(e.status, 201);
  const edit = e.json.patches.at(-1);
  store.gate = null;
  release();

  assert.equal((await applying).status, 200);
  const { status, json } = await call('GET', '/manuals/demo-kitchen');
  assert.equal(status, 200);
  assert.equal(statusOf(json, p.id).status, 'applied');
  assert.deepEqual(statusOf(json, edit.id), { status: 'proposed', appliedAt: null });
  assert.ok(texts(json).includes('- 大盛りは250gまで（ランチは300g）'));
  assert.ok(!texts(json).includes('- 新しい行'));
  assert.deepEqual(replay(json), json.lines);
  assert.ok(warned().some((x) => JSON.parse(x).patchId === edit.id));
});

test('壊れていないノートは、行も差分も今までと変わらず、ログも出さない', async () => {
  const store = new MemoryStore();
  await seedWithHistory(store, 'demo');
  const call = await open(store);
  for (const m of await store.listManuals('demo')) {
    const stored = (await store.list<Patch>('demo', m.id, 'patches')).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    assert.ok(stored.some((p) => p.status === 'applied'));
    const { status, json } = await call('GET', `/manuals/${m.id}`);
    assert.equal(status, 200);
    assert.deepEqual(json.patches, stored);
    assert.deepEqual(json.lines, render(m.base, stored));
  }
  assert.deepEqual(warned(), []);
});
