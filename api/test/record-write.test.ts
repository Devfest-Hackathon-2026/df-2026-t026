import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import type { AssessInput, AssessResult } from '../src/assess.ts';
import { sessionIdOf } from '../src/auth.ts';
import type { CheckResult, Kind } from '../src/conflict/check.ts';
import { fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import type { PatchDraft } from '../src/foundation/manual.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// 入力ページの記録で、迷う所の無い差分を同じ呼び出しの中で書き込む（POST /utterances の write。設計書 0021 の C2）

let app: ReturnType<typeof createApp>;

/** 照らし合わせの代わり。テストごとに返す中身を決める。照らし合わせている間にノートを変えることもできる */
let assessed: (input: AssessInput) => Promise<AssessResult>;

/** failWrites の間は、差分を反映・捨てる書き込みが失敗する（記録そのものの保存は通る） */
class FlakyStore extends MemoryStore {
  failWrites = false;
  override async put<T extends { id: string }>(userId: string, manualId: string, collection: string, doc: T) {
    const status = (doc as { status?: string }).status;
    if (this.failWrites && collection === 'patches' && status !== 'proposed') throw new Error('Firestore が混んでいます');
    return super.put(userId, manualId, collection, doc);
  }
}

let store: FlakyStore;

beforeEach(async () => {
  store = new FlakyStore();
  await seed(store, 'demo');
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  app = createApp({
    store,
    assess: (input) => assessed(input),
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
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
}

const item = (kind: Kind, patch: PatchDraft, check: Partial<CheckResult> = {}) => ({
  manual: 0,
  patch,
  check: { kind, conflictLine: null, sameLine: null, reason: '理由', ask: null, materialRef: null, ...check },
});

const insert = (line: string | null, text: string): PatchDraft => ({ op: 'insert', line, text, summary: '追記' });

/** キッチンのノートに、決めた差分を記録する */
async function recordKitchen(items: AssessResult['items'], { speaker = '田中さん' as string | null, write = true, memoIds = [] as string[] } = {}) {
  assessed = async () => ({ speaker, saidAt: '2026-11-10', items });
  const res = await call('POST', '/utterances', { text: '言われたこと', manualIds: ['demo-kitchen'], today: '2026-11-10', write, memoIds });
  assert.equal(res.status, 201);
  const [r] = res.json.results;
  const mine = r.state.patches.filter((p: any) => p.utteranceId === r.utteranceId);
  return { state: r.state, patches: mine as any[], texts: r.state.lines.map((l: any) => l.text) as string[] };
}

const statusOf = (patches: any[], text: string) => patches.find((p) => p.text === text).status;

test('発言者が分かれば、追記・補足は書き込み、同じ内容は書き込まず、食い違いは確認リストに残す', async () => {
  const memo = (await call('POST', '/memos', { at: '2026-11-10T01:00:00.000Z', text: '言われたこと' })).json;
  const { state, patches, texts } = await recordKitchen(
    [
      item('addition', insert('- 炊けたら10分蒸らす', '- ご飯はおかわり1回まで無料')),
      item('qualification', { op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは250gまで（ランチは300g）', summary: '補足' }),
      item('same', insert(null, '- 味噌は火を止めてから溶く'), { sameLine: '- 味噌は火を止めてから溶く' }),
      item('contradiction', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2', summary: '塩' }, {
        conflictLine: '- 塩 小さじ1',
        ask: { candidates: [], question: 'どちらですか？' },
      }),
    ],
    { memoIds: [memo.id] },
  );

  assert.equal(statusOf(patches, '- ご飯はおかわり1回まで無料'), 'applied');
  assert.equal(statusOf(patches, '- 大盛りは250gまで（ランチは300g）'), 'applied');
  assert.equal(statusOf(patches, '- 味噌は火を止めてから溶く'), 'discarded');
  assert.equal(statusOf(patches, '- 塩 小さじ1/2'), 'proposed');
  assert.equal(texts[texts.indexOf('- 炊けたら10分蒸らす') + 1], '- ご飯はおかわり1回まで無料');
  assert.ok(texts.includes('- 大盛りは250gまで（ランチは300g）') && !texts.includes('- 大盛りは250gまで'));
  // 食い違いは書き込まず、あとで確認に入ったまま
  assert.ok(texts.includes('- 塩 小さじ1'));
  assert.equal(state.checks.filter((c: any) => c.kind === 'contradiction' && !c.resolution).length, 1);
  // 記録できたので、入力欄に入れたメモは消える
  assert.deepEqual((await call('GET', '/memos')).json, []);
  // 書き込んだあとも、ノートを開ける
  const opened = await call('GET', '/manuals/demo-kitchen');
  assert.equal(opened.status, 200);
  assert.deepEqual(opened.json.lines, state.lines);
});

test('発言者が読み取れなければ、何も書き込まない', async () => {
  const before = (await call('GET', '/manuals/demo-kitchen')).json.lines;
  const { patches, state } = await recordKitchen(
    [
      item('addition', insert('- 炊けたら10分蒸らす', '- ご飯はおかわり1回まで無料')),
      item('same', insert(null, '- 味噌は火を止めてから溶く'), { sameLine: '- 味噌は火を止めてから溶く' }),
    ],
    { speaker: null },
  );
  assert.deepEqual(patches.map((p) => p.status), ['proposed', 'proposed']);
  assert.deepEqual(state.lines, before);
});

test('write を付けなければ、今まで通り何も書き込まない', async () => {
  const { patches } = await recordKitchen([item('addition', insert('- 炊けたら10分蒸らす', '- ご飯はおかわり1回まで無料'))], {
    write: false,
  });
  assert.equal(patches[0].status, 'proposed');
});

/** キッチンに記録する。照らし合わせている間に change でノートを変える */
async function recordWhileChanging(change: () => Promise<unknown>, items: AssessResult['items']) {
  assessed = async () => {
    await change();
    return { speaker: '田中さん', saidAt: '2026-11-10', items };
  };
  const res = await call('POST', '/utterances', { text: '言われたこと', manualIds: ['demo-kitchen'], write: true });
  assert.equal(res.status, 201);
  const [r] = res.json.results;
  return { state: r.state, patches: r.state.patches.filter((p: any) => p.utteranceId === r.utteranceId) as any[] };
}

test('照らし合わせている間に食い違う行が足されたら、追記として書き込まず、全部を未反映のまま残す', async () => {
  const { state, patches } = await recordWhileChanging(
    () => call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- ご飯のおかわりは有料', today: '2026-11-10' }),
    [
      item('addition', insert(null, '- ご飯のおかわりは1回まで無料')),
      item('addition', insert('- 洗った皿は右の棚に戻す', '- グラスは左の棚')),
    ],
  );
  // 分類は足される前のノートに対するもの。食い違いを見逃さないよう、利用者が確かめるまで書き込まない
  assert.deepEqual(patches.map((p) => p.status), ['proposed', 'proposed']);
  const texts = state.lines.map((l: any) => l.text);
  assert.ok(texts.includes('- ご飯のおかわりは有料'));
  assert.ok(!texts.includes('- ご飯のおかわりは1回まで無料') && !texts.includes('- グラスは左の棚'));
});

test('照らし合わせている間に同じ内容の行が消されたら、同じ内容の差分も捨てずに未反映のまま残す', async () => {
  const { patches } = await recordWhileChanging(
    () => call('POST', '/manuals/demo-kitchen/edits', { op: 'delete', line: '- 味噌は火を止めてから溶く', today: '2026-11-10' }),
    [item('same', insert(null, '- 味噌は火を止めてから溶く'), { sameLine: '- 味噌は火を止めてから溶く' })],
  );
  assert.equal(patches[0].status, 'proposed');
  // 確かめてから書き込める
  const applied = await call('POST', `/manuals/demo-kitchen/patches/${patches[0].id}/apply`, {});
  assert.equal(applied.status, 200);
  assert.ok(applied.json.lines.some((l: any) => l.text === '- 味噌は火を止めてから溶く'));
});

test('ノートが変わっていなくても、当たらない差分は未反映のまま残し、記録は成功にする', async () => {
  const { patches, texts } = await recordKitchen([
    item('qualification', { op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは250gまで（ランチは300g）', summary: '補足' }),
    // 前の差分が書き換えた行の後ろには足せない
    item('addition', insert('- 大盛りは250gまで', '- 大盛りは予約のみ')),
    item('addition', insert('- 洗った皿は右の棚に戻す', '- グラスは左の棚')),
  ]);
  assert.equal(statusOf(patches, '- 大盛りは250gまで（ランチは300g）'), 'applied');
  assert.equal(statusOf(patches, '- 大盛りは予約のみ'), 'proposed');
  assert.equal(statusOf(patches, '- グラスは左の棚'), 'applied');
  assert.equal(texts[texts.indexOf('- 洗った皿は右の棚に戻す') + 1], '- グラスは左の棚');
  assert.equal((await call('GET', '/manuals/demo-kitchen')).status, 200);
});

test('記録先に同じノートが2回入っていても、1回だけ記録し、ノートを開ける', async () => {
  let given = 0;
  assessed = async ({ manuals }) => {
    given = manuals.length;
    return {
      speaker: '田中さん',
      saidAt: '2026-11-10',
      items: [item('qualification', { op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは250gまで（ランチは300g）', summary: '補足' })],
    };
  };
  const res = await call('POST', '/utterances', { text: '言われたこと', manualIds: ['demo-kitchen', 'demo-kitchen'], write: true });
  assert.equal(res.status, 201);
  assert.equal(given, 1);
  assert.equal(res.json.results.length, 1);
  const opened = await call('GET', '/manuals/demo-kitchen');
  assert.equal(opened.status, 200);
  assert.ok(opened.json.lines.some((l: any) => l.text === '- 大盛りは250gまで（ランチは300g）'));
});

test('記録を保存したあとの書き込みが失敗しても、記録は成功で返し、メモを消し、差分は未反映のまま残す', async () => {
  const memo = (await call('POST', '/memos', { at: '2026-11-10T01:00:00.000Z', text: '言われたこと' })).json;
  store.failWrites = true;
  assessed = async () => ({
    speaker: '田中さん',
    saidAt: '2026-11-10',
    items: [item('addition', insert('- 炊けたら10分蒸らす', '- ご飯はおかわり1回まで無料'))],
  });
  const res = await call('POST', '/utterances', { text: '言われたこと', manualIds: ['demo-kitchen'], write: true, memoIds: [memo.id] });
  store.failWrites = false;
  assert.equal(res.status, 201);
  const [r] = res.json.results;
  assert.equal(r.state.patches.find((p: any) => p.utteranceId === r.utteranceId).status, 'proposed');
  assert.deepEqual((await call('GET', '/memos')).json, []);
  // 送り直さないので、記録は1件だけ
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.utterances.length, 1);
});

test('前の差分の行に重ねる差分を続けて書き込んでも、反映した時刻は1件ずつ増え、ノートを開ける', async (t) => {
  // 時計を止め、同じミリ秒に書き込んでも順がずれないことを確かめる
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-11-10T03:00:00.000Z') });
  await recordKitchen([
    item('addition', insert('- 炊けたら10分蒸らす', '- X1')),
    item('addition', insert('- X1', '- X2')),
  ]);
  await recordKitchen([
    item('addition', insert('- X2', '- X3')),
    item('qualification', { op: 'replace', line: '- X1', text: '- X1（ランチだけ）', summary: '補足' }),
  ]);

  const opened = await call('GET', '/manuals/demo-kitchen');
  assert.equal(opened.status, 200);
  const applied = (opened.json.patches as any[]).filter((p) => p.status === 'applied');
  const order = ['- X1', '- X2', '- X3', '- X1（ランチだけ）'].map((text) => applied.find((p) => p.text === text).appliedAt);
  assert.deepEqual([...order].sort(), order);
  assert.equal(new Set(order).size, 4);
  const texts = opened.json.lines.map((l: any) => l.text);
  const at = texts.indexOf('- 炊けたら10分蒸らす');
  assert.deepEqual(texts.slice(at, at + 4), ['- 炊けたら10分蒸らす', '- X1（ランチだけ）', '- X2', '- X3']);
});
