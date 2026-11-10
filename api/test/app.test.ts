import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { PDFDocument } from 'pdf-lib';

import { createApp, type Deps } from '../src/app.ts';
import { assessWithGemini, type Assess, type AssessInput } from '../src/assess.ts';
import { hashPassword, sessionIdOf } from '../src/auth.ts';
import type { CheckInput } from '../src/conflict/check.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { toGeminiSchema, type InlineFile } from '../src/gemini.ts';
import type { ReadMaterial } from '../src/material.ts';
import { seed, seedWithHistory } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

let app: ReturnType<typeof createApp>;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai });
});

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

/** demo としてログインした状態にする。ログインそのものは別のテストで確かめる */
const auth = { Authorization: 'Bearer test-token' };
const signIn = (store: MemoryStore) => store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...auth },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
}

async function record(text: string) {
  const { status, json } = await call('POST', '/manuals/demo-kitchen/utterances', { text, today: '2026-11-03' });
  assert.equal(status, 201);
  const patches = json.state.patches.filter((p: any) => p.utteranceId === json.utteranceId);
  const checks = json.state.checks.filter((c: any) => c.utteranceId === json.utteranceId);
  return { state: json.state, utterance: json.state.utterances.at(-1), patch: patches[0], check: checks[0] };
}

test('矛盾は確認待ちになり、確認した人と日付付きで確定できる', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  assert.equal(r.utterance.speaker, '田中さん');
  assert.equal(r.utterance.saidAt, '2026-11-03');
  assert.equal(r.check.kind, 'contradiction');
  assert.equal(r.check.conflictLine, '- 塩 小さじ1');
  assert.ok(r.check.ask.candidates.some((x: any) => x.who === '店長'));
  assert.ok(r.check.ask.question.length > 0);

  const { status, json } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
  });
  assert.equal(status, 200);
  const line = json.lines.find((l: any) => l.text === '- 塩 小さじ1/2');
  const resolved = json.checks.find((c: any) => c.id === r.check.id).resolution;
  assert.equal(line.patchId, resolved.patchId);
  assert.equal(resolved.decidedBy, '店長');
  assert.equal(json.patches.find((p: any) => p.id === r.patch.id).status, 'discarded');
  // 確認の答えも発言として残る
  assert.ok(json.utterances.some((u: any) => u.speaker === '店長' && u.saidAt === '2026-11-07' && u.text === '1/2で統一'));
});

test('マニュアルのままと確定したら本文は変えずに記録だけ残す', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const { json } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1',
  });
  assert.ok(json.lines.some((l: any) => l.text === '- 塩 小さじ1' && l.patchId === null));
  assert.equal(json.checks[0].resolution.patchId, null);
  assert.equal(json.checks[0].resolution.note, '- 塩 小さじ1');
});

test('追記は承認するとそのまま反映され、誰の発言かが行に残る', async () => {
  const r = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  assert.equal(r.check.kind, 'addition');
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  const texts = json.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 炊けたら10分蒸らす') + 1], '- ご飯はおかわり1回まで無料');
  assert.equal(json.lines.find((l: any) => l.text === '- ご飯はおかわり1回まで無料').patchId, r.patch.id);
});

test('本文を空にすると白紙のマニュアルになり、言われたことから書き足せる', async () => {
  const created = await call('POST', '/manuals', { title: '自分用メモ', body: '  ' });
  assert.equal(created.status, 201);
  assert.deepEqual(created.json.lines, []);
  const id = created.json.manual.id;

  const { json } = await call('POST', `/manuals/${id}/utterances`, { text: '佐藤さんから、ご飯はおかわり1回まで無料と教わった' });
  const [p] = json.state.patches;
  assert.equal(json.state.checks[0].kind, 'addition');
  const applied = await call('POST', `/manuals/${id}/patches/${p.id}/apply`, {});
  assert.deepEqual(applied.json.lines, [{ text: '- ご飯はおかわり1回まで無料', patchId: p.id }]);
});

async function edit(body: object) {
  const { status, json } = await call('POST', '/manuals/demo-kitchen/edits', { today: '2026-11-08', ...body });
  assert.equal(status, 201);
  return { state: json, patch: json.patches.at(-1), texts: json.lines.map((l: any) => l.text) as string[] };
}

test('直接編集：行を足す・書き換える・消すと、自分が書いた記録としてすぐ反映される', async () => {
  const added = await edit({ op: 'insert', line: '- 塩 小さじ1', text: '- だしは煮干し' });
  assert.equal(added.texts[added.texts.indexOf('- 塩 小さじ1') + 1], '- だしは煮干し');
  const u = added.state.utterances.find((x: any) => x.id === added.patch.utteranceId);
  assert.deepEqual([u.speaker, u.saidAt, u.fromEdit, u.editedBy], ['自分', '2026-11-08', true, undefined]);
  assert.equal(added.state.lines.find((l: any) => l.text === '- だしは煮干し').patchId, added.patch.id);

  const replaced = await edit({ op: 'replace', line: '- だしは煮干し', text: '- だしは昆布' });
  assert.ok(replaced.texts.includes('- だしは昆布') && !replaced.texts.includes('- だしは煮干し'));

  const deleted = await edit({ op: 'delete', line: '- だしは昆布' });
  assert.ok(!deleted.texts.includes('- だしは昆布'));
  // 編集しただけでは衝突検知の記録は作らない（確かめるのは別の呼び出し）
  assert.equal(deleted.state.checks.length, 0);
});

test('直接編集：行頭の空白（マークダウンの入れ子）は残し、行末の空白だけを落とす', async () => {
  const { texts } = await edit({ op: 'insert', line: '- 塩 小さじ1', text: '  - 粗塩でもよい  ' });
  assert.equal(texts[texts.indexOf('- 塩 小さじ1') + 1], '  - 粗塩でもよい');
});

test('直接編集：無い行は編集できず、中身が空の行は書けない', async () => {
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'delete', line: '- 無い行' })).status, 409);
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: ' ' })).status, 400);
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: null, text: 'x' })).status, 400);
});

test('直接編集：書いた行がほかの行と食い違えば、あとで確認に入る', async () => {
  const { patch } = await edit({ op: 'insert', line: null, text: '- 塩 小さじ2' });
  const { status, json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(status, 200);
  const chk = json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1']);
  // 同じ編集は二度確かめない
  assert.equal((await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`)).status, 409);
});

test('直接編集：書き換える前の行とは食い違いにしない', async () => {
  const { patch } = await edit({ op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ2' });
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(json.checks.find((c: any) => c.patchId === patch.id).kind, 'addition');
});

test('直接編集：食い違いを確定すると、2行が確定した内容の1行にまとまる', async () => {
  const { patch } = await edit({ op: 'insert', line: null, text: '- 塩 小さじ2' });
  const checked = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  const chk = checked.json.checks.find((c: any) => c.patchId === patch.id);
  const { json } = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-09',
    text: '- 塩 小さじ2',
  });
  const salt = json.lines.filter((l: any) => l.text.startsWith('- 塩'));
  assert.deepEqual(salt.map((l: any) => l.text), ['- 塩 小さじ2']);
  assert.equal(json.checks.find((c: any) => c.id === chk.id).resolution.decidedBy, '店長');
});

/** 田中さんの「小さじ1/2」を店長に確認して確定し、塩の行を `- 塩 小さじ1/2` にする */
async function confirmHalf() {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const { status } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
  });
  assert.equal(status, 200);
}

test('直接編集：確定済みの行を書き換えると、確定した行と食い違うとして確認に入る', async () => {
  const inputs: CheckInput[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai, check: (i) => (inputs.push(i), fakeCheckPatch(i)) });
  await confirmHalf();

  const { patch } = await edit({ op: 'replace', line: '- 塩 小さじ1/2', text: '- 塩 小さじ1' });
  const { status, json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(status, 200);
  const chk = json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1/2']);
  // 書き換える前の行は、元の位置に確定の出どころ付きで渡る
  assert.deepEqual(inputs[0].lines.slice(0, 3), [
    { text: '## 味噌汁', note: null },
    { text: '- 塩 小さじ1/2', note: '店長（2026-11-07）に確認して確定' },
    { text: '- 味噌は火を止めてから溶く', note: null },
  ]);
  assert.ok(!inputs[0].lines.some((l) => l.text === '- 塩 小さじ1'));
});

test('直接編集：確定していない行の書き換えは、確定がほかにあっても書き換える前の行と食い違いにしない', async () => {
  await confirmHalf();
  const { patch } = await edit({ op: 'replace', line: '- 大盛りは250gまで', text: '- 大盛りは300gまで' });
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(json.checks.find((c: any) => c.patchId === patch.id).kind, 'addition');
});

test('食い違っていた行を確定の前に直していても、行は変えずに確定の記録だけ残せる', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const { state } = await edit({ op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1（味見して調整）' });
  const { status, json } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
  });
  assert.equal(status, 200);
  assert.deepEqual(json.lines, state.lines);
  const resolved = json.checks.find((c: any) => c.id === r.check.id).resolution;
  assert.deepEqual([resolved.decidedBy, resolved.decidedAt, resolved.text, resolved.patchId], ['店長', '2026-11-07', '- 塩 小さじ1/2', null]);
  assert.equal(json.patches.find((p: any) => p.id === r.patch.id).status, 'discarded');
});

test('題名がなければマニュアルを作らない', async () => {
  assert.equal((await call('POST', '/manuals', { title: ' ', body: '' })).status, 400);
});

test('条件付きの補足は元の記述と併記される', async () => {
  const r = await record('田中さんに、忙しい日は塩は小さじ1/2でいいと言われた');
  assert.equal(r.check.kind, 'qualification');
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.ok(json.lines.some((l: any) => l.text === '- 塩 小さじ1（忙しい日は小さじ1/2）'));

  const r2 = await record('田中さんに、忙しい日は大盛りは200gまでと言われた');
  assert.equal(r2.check.kind, 'qualification');
  assert.equal(r2.patch.text, '- 大盛りは250gまで（忙しい日は200gまで）');
});

test('マニュアルと同じ内容は same になり、次の判定でその行の裏付けとして渡る', async () => {
  const r = await record('佐藤さんから塩は小さじ1と言われた');
  assert.equal(r.check.kind, 'same');
  assert.equal(r.check.sameLine, '- 塩 小さじ1');
  assert.equal(r.check.ask, null);

  const inputs: AssessInput[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai, assess: (i) => (inputs.push(i), fakeAssess(i)) });
  await record('佐藤さんから塩は小さじ1と言われた');
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  const salt = inputs[1].manuals[0].lines.find((l) => l.text === '- 塩 小さじ1');
  assert.equal(salt?.note, '佐藤さん（2026-11-03）も同じ');
});

test('発言者が分からないうちは反映できない', async () => {
  const r = await record('ご飯はおかわり1回まで無料');
  assert.equal(r.utterance.speaker, null);
  const blocked = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.equal(blocked.status, 400);
  await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, { speaker: '鈴木さん' });
  const ok = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.equal(ok.status, 200);
});

test('書き起こしを直すと、その文面で差分と分類を作り直し、入れた発言者は残す', async () => {
  // 「小さじ1/2」を「小さじ1」と聞き間違えた
  const r = await record('塩は小さじ1でいい');
  assert.equal(r.check.kind, 'same');
  const { status, json } = await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, {
    text: '塩は小さじ1/2でいい',
    speaker: '田中さん',
  });
  assert.equal(status, 200);
  const u = json.utterances.find((x: any) => x.id === r.utterance.id);
  assert.equal(u.text, '塩は小さじ1/2でいい');
  assert.equal(u.speaker, '田中さん');
  const patches = json.patches.filter((p: any) => p.utteranceId === u.id);
  const checks = json.checks.filter((x: any) => x.utteranceId === u.id);
  assert.equal(patches.length, 1);
  assert.notEqual(patches[0].id, r.patch.id);
  assert.equal(checks.length, 1);
  assert.equal(checks[0].kind, 'contradiction');
  assert.equal(checks[0].patchId, patches[0].id);
});

test('反映した差分のある記録は、書き起こしを直せない', async () => {
  const r = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  const { status } = await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, { text: 'ご飯はおかわり2回まで無料' });
  assert.equal(status, 409);
});

test('記録した人：記録・直接の編集・確定の答えに、記録した人の ID と名前を残し、応答に読んでいる人を返す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const recorded = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた' });
  const u = recorded.json.state.utterances.find((x: any) => x.id === recorded.json.utteranceId);
  assert.deepEqual(u.recordedBy, { id: 'sato', name: '佐藤店長' });
  assert.equal(u.speaker, '田中さん');
  assert.equal(recorded.json.state.me, 'sato');

  const edited = await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' });
  assert.deepEqual(edited.json.utterances.at(-1).recordedBy, { id: 'demo', name: 'demo' });
  assert.equal(edited.json.me, 'demo');

  const chk = recorded.json.state.checks.find((x: any) => x.utteranceId === u.id);
  const resolved = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1' });
  const answer = resolved.json.utterances.find((x: any) => x.id === resolved.json.checks.find((x: any) => x.id === chk.id).resolution.utteranceId);
  assert.deepEqual([answer.speaker, answer.recordedBy], ['店長', { id: 'demo', name: 'demo' }]);
});

test('記録した人：記録を直す・書き込む・書き込まないは記録した本人だけで、前からある記録は持ち主の記録とみなす', async () => {
  const store = await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await store.put('demo', 'demo-kitchen', 'utterances', { id: 'old', text: '塩は控えめ', speaker: '田中さん', saidAt: '2026-11-01', createdAt: '2026-11-01T00:00:00Z' });
  const mine = await record('ご飯はおかわり1回まで無料');
  const theirs = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: 'ご飯は硬めに炊く' });
  const theirPatch = theirs.json.state.patches.find((p: any) => p.utteranceId === theirs.json.utteranceId);

  const denied: [string, string, string, unknown][] = [
    ['sato', 'PATCH', `/manuals/demo-kitchen/utterances/${mine.utterance.id}`, { speaker: '鈴木さん' }],
    ['sato', 'POST', `/manuals/demo-kitchen/patches/${mine.patch.id}/apply`, {}],
    ['sato', 'POST', `/manuals/demo-kitchen/patches/${mine.patch.id}/discard`, {}],
    ['test', 'PATCH', `/manuals/demo-kitchen/utterances/${theirs.json.utteranceId}`, { text: 'ご飯は柔らかめに炊く' }],
    ['test', 'POST', `/manuals/demo-kitchen/patches/${theirPatch.id}/discard`, {}],
  ];
  for (const [who, method, path, body] of denied) {
    const r = await callAs(who, method, path, body);
    assert.equal(r.status, 403, `${who} ${method} ${path}`);
    assert.match(r.json.error, /記録した (佐藤店長|demo) だけです/);
  }
  // 前からある記録（記録した人が無い）は持ち主の記録
  assert.equal((await callAs('sato', 'PATCH', '/manuals/demo-kitchen/utterances/old', { speaker: 'x' })).status, 403);

  assert.equal((await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${theirPatch.id}/discard`, {})).status, 200);
  assert.equal((await call('PATCH', `/manuals/demo-kitchen/utterances/${mine.utterance.id}`, { speaker: '鈴木さん' })).status, 200);
});

test('記録した人：書き込んだ・確定した記録も、本人なら発言者と日付は直せる。書き起こしは直せない', async () => {
  const applied = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  await call('POST', `/manuals/demo-kitchen/patches/${applied.patch.id}/apply`, {});
  const resolved = await record('田中さんから塩は小さじ1/2でいいと言われた');
  await call('POST', `/manuals/demo-kitchen/checks/${resolved.check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1' });

  for (const r of [applied, resolved]) {
    const path = `/manuals/demo-kitchen/utterances/${r.utterance.id}`;
    const fixed = await call('PATCH', path, { speaker: '鈴木さん', saidAt: '2026-11-01' });
    assert.equal(fixed.status, 200);
    const u = fixed.json.utterances.find((x: any) => x.id === r.utterance.id);
    assert.deepEqual([u.speaker, u.saidAt], ['鈴木さん', '2026-11-01']);
    assert.equal((await call('PATCH', path, { text: '別の話' })).status, 409);
  }
});

test('名前とアイコン：決めるまでは ID を名前にし、決めたら残す', async () => {
  assert.deepEqual((await call('GET', '/me')).json, { id: 'demo', name: 'demo', icon: null });

  const icon = { mimeType: 'image/jpeg', data: Buffer.from('jpeg').toString('base64') };
  const saved = await call('PUT', '/me', { name: ' かなで ', icon });
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.json, { id: 'demo', name: 'かなで', icon });
  assert.deepEqual((await call('GET', '/me')).json, { id: 'demo', name: 'かなで', icon });
  assert.deepEqual((await call('PUT', '/me', { name: 'かなで', icon: null })).json, { id: 'demo', name: 'かなで', icon: null });

  assert.equal((await call('PUT', '/me', { name: ' ', icon: null })).status, 400);
  assert.equal((await call('PUT', '/me', { name: 'かなで', icon: { mimeType: 'image/gif', data: icon.data } })).status, 400);
  const huge = { mimeType: 'image/jpeg', data: Buffer.alloc(400_000).toString('base64') };
  assert.equal((await call('PUT', '/me', { name: 'かなで', icon: huge })).status, 400);

});

test('名前とアイコン：ほかの人が決めた名前は、自分には出ない', async () => {
  const store = new MemoryStore();
  await signIn(store);
  await store.putSession({ id: sessionIdOf('sato-token'), userId: 'sato', createdAt: '' });
  app = createApp({ store, ...ai });
  await call('PUT', '/me', { name: 'かなで', icon: null });
  const res = await app.request('/me', { headers: { Authorization: 'Bearer sato-token' } });
  assert.deepEqual(await res.json(), { id: 'sato', name: 'sato', icon: null });
});

test('CORS は指定したオリジンだけを許可する', async () => {
  const store = new MemoryStore();
  const restricted = createApp({ store, ...ai, allowOrigin: 'https://a.web.app,https://a.firebaseapp.com' });
  const origin = async (o: string) =>
    (await restricted.request('/health', { headers: { Origin: o } })).headers.get('Access-Control-Allow-Origin');
  assert.equal(await origin('https://a.firebaseapp.com'), 'https://a.firebaseapp.com');
  assert.equal(await origin('https://evil.example.com'), null);
});

test('配った ID とパスワードでログインすると、その人のノートだけを読み書きできる', async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await store.putAccount({ id: 'demo', ...(await hashPassword('pass-demo')), createdAt: '' });
  await store.putAccount({ id: 'sato', ...(await hashPassword('pass-sato')), createdAt: '' });
  const origin = 'https://a.web.app';
  const locked = createApp({ store, ...ai, allowOrigin: origin });
  const login = async (id: string, password: string) => {
    const res = await locked.request('/login', {
      method: 'POST',
      headers: { Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ id, password }),
    });
    return { status: res.status, json: (await res.json()) as any };
  };
  const get = (path: string, token?: string) =>
    locked.request(path, { headers: { Origin: origin, ...(token && { Authorization: `Bearer ${token}` }) } });

  const preflight = await locked.request('/manuals', {
    method: 'OPTIONS',
    headers: { Origin: origin, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'authorization' },
  });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers') ?? '', /authorization/i);

  const missing = await get('/manuals');
  assert.equal(missing.status, 401);
  assert.equal(((await missing.json()) as any).error, 'ログインしてください');
  // CORS のヘッダーがないと、ブラウザからは 401 ではなく通信エラーに見えてしまう
  assert.equal(missing.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal((await get('/manuals', 'made-up-token')).status, 401);

  for (const [id, password] of [['demo', 'pass-sato'], ['nobody', 'pass-demo'], ['../demo', 'pass-demo']]) {
    const wrong = await login(id, password);
    assert.equal(wrong.status, 401);
    assert.equal(wrong.json.error, 'ID かパスワードが違います');
  }

  const demo = await login('demo', 'pass-demo');
  assert.equal(demo.status, 200);
  const mine = await get('/manuals', demo.json.token);
  assert.equal(mine.status, 200);
  assert.equal(((await mine.json()) as any).length, 2);
  // トークンそのものは保存しない
  assert.equal(await store.getSession(demo.json.token), null);

  // ほかの人のノートは見えない
  const sato = (await login('sato', 'pass-sato')).json.token;
  assert.deepEqual(await (await get('/manuals', sato)).json(), []);
  assert.equal((await get('/manuals/demo-kitchen', sato)).status, 404);

  assert.equal((await get('/health')).status, 200);
});

/** 持ち主 demo・共有する相手 sato・無関係の kim。共有の相手はアカウントがあるかを確かめるので、アカウントも作る */
async function withAccounts() {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  for (const id of ['sato', 'kim']) {
    await store.putAccount({ id, salt: '', hash: '', createdAt: '' });
    await store.putSession({ id: sessionIdOf(`${id}-token`), userId: id, createdAt: '' });
  }
  await store.putProfile('sato', { name: '佐藤店長', icon: null });
  app = createApp({ store, ...ai });
  return store;
}

async function callAs(who: string, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${who}-token` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
}

test('共有：持ち主が ID で足すと、相手のサイドバーに出て、相手は見て行を直せる', async () => {
  await withAccounts();
  const added = await call('POST', '/manuals/demo-kitchen/shares', { userId: ' sato ' });
  assert.equal(added.status, 201);
  assert.deepEqual(added.json, [{ id: 'sato', name: '佐藤店長' }]);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json, [{ id: 'sato', name: '佐藤店長' }]);

  const shared = await callAs('sato', 'GET', '/shared');
  assert.deepEqual(
    shared.json.map((m: any) => [m.id, m.title, m.sharedBy]),
    [['demo-kitchen', 'キッチンマニュアル（定食屋 みのり）', { id: 'demo', name: 'demo' }]],
  );
  // 自分のノートの一覧には混ぜない
  assert.deepEqual((await callAs('sato', 'GET', '/manuals')).json, []);

  const seen = await callAs('sato', 'GET', '/manuals/demo-kitchen');
  assert.equal(seen.status, 200);
  assert.deepEqual(seen.json.sharedBy, { id: 'demo', name: 'demo' });
  assert.ok(seen.json.lines.some((l: any) => l.text === '- 塩 小さじ1'));
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.sharedBy, null);

  // 直した行は、共有された人が書いたとして持ち主のノートに積まれる
  const edited = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: '- 塩 小さじ1', text: '- だしは煮干し', today: '2026-11-09' });
  assert.equal(edited.status, 201);
  const mine = (await call('GET', '/manuals/demo-kitchen')).json;
  const texts = mine.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 塩 小さじ1') + 1], '- だしは煮干し');
  const u = mine.utterances.at(-1);
  assert.deepEqual([u.speaker, u.saidAt, u.fromEdit, u.editedBy], ['佐藤店長', '2026-11-09', true, 'sato']);

  // ほかの行と食い違えば、持ち主の確認リストに入り、持ち主が確定する
  const conflicting = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- 塩 小さじ2' });
  const patch = conflicting.json.patches.at(-1);
  const checked = await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(checked.status, 200);
  const chk = checked.json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1']);
  assert.equal((await call('GET', '/manuals')).json.find((m: any) => m.id === 'demo-kitchen').openCount, 1);
  const resolved = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-09', text: '- 塩 小さじ2' });
  assert.equal(resolved.status, 200);
});

/** 共有された佐藤さんが、確定済みの `- 塩 小さじ1/2` を `- 塩 小さじ1` に書き換えて確かめる */
async function rewriteConfirmedAsShared() {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await confirmHalf();
  const edited = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: '- 塩 小さじ1/2', text: '- 塩 小さじ1', today: '2026-11-10' });
  const patch = edited.json.patches.at(-1);
  const checked = await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(checked.status, 200);
  return { patch, chk: checked.json.checks.find((c: any) => c.patchId === patch.id) };
}

test('共有：共有された人が確定済みの行を書き換えると、持ち主の確認リストに入る', async () => {
  const { chk } = await rewriteConfirmedAsShared();
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1/2']);
  assert.equal((await call('GET', '/manuals')).json.find((m: any) => m.id === 'demo-kitchen').openCount, 1);
});

test('共有：確定済みの行を書き換えた食い違いを確定すると、塩の行は1本のまま選んだ内容になる', async () => {
  const cases = [
    { label: 'ノートのまま（前の確定に戻す）', text: '- 塩 小さじ1/2' },
    { label: '書き換えた方', text: '- 塩 小さじ1' },
    { label: '別の内容', text: '- 塩 小さじ2/3' },
  ];
  for (const { label, text } of cases) {
    const { patch, chk } = await rewriteConfirmedAsShared();
    const { status, json } = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, {
      decidedBy: '店長',
      decidedAt: '2026-11-10',
      text,
      note: label,
    });
    assert.equal(status, 200, label);
    const texts = json.lines.map((l: any) => l.text);
    assert.deepEqual(texts.filter((t: string) => t.startsWith('- 塩')), [text], label);
    const salt = json.lines[texts.indexOf('## 味噌汁') + 1];
    assert.equal(salt.text, text, label);
    const resolved = json.checks.find((c: any) => c.id === chk.id).resolution;
    assert.deepEqual([resolved.decidedBy, resolved.decidedAt, resolved.text, resolved.note], ['店長', '2026-11-10', text, label], label);
    // 書き換えた方を採るなら行は変えず、それ以外は確定した内容の行に置き換わる
    if (text === patch.text) assert.deepEqual([resolved.patchId, salt.patchId], [null, patch.id], label);
    else assert.ok(resolved.patchId && salt.patchId === resolved.patchId, label);
    assert.ok(json.utterances.some((u: any) => u.id === resolved.utteranceId && u.speaker === '店長'), label);
    assert.equal((await call('GET', '/manuals')).json.find((m: any) => m.id === 'demo-kitchen').openCount, 0, label);
  }
});

test('共同編集：共有された人も、記録・書き込み・確定を持ち主のノートにできる', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });

  // 記録先を選ばなくても、共有されたノートに振り分ける
  const routed = await callAs('sato', 'POST', '/utterances', { text: '田中さんからガスは二重に確かめると言われた', today: '2026-11-10' });
  assert.equal(routed.status, 201);
  assert.deepEqual(routed.json.results.map((r: any) => r.manualId), ['demo-kitchen']);

  const picked = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', today: '2026-11-10' });
  assert.equal(picked.status, 201);
  const u = picked.json.state.utterances.find((x: any) => x.id === picked.json.utteranceId);
  const chk = picked.json.state.checks.find((x: any) => x.utteranceId === u.id);
  assert.equal(chk.kind, 'contradiction');
  const open = picked.json.state.checks.filter((x: any) => x.kind === 'contradiction' && !x.resolution).length;
  assert.equal((await callAs('sato', 'GET', '/shared')).json[0].openCount, open);

  const renamed = await callAs('sato', 'PATCH', `/manuals/demo-kitchen/utterances/${u.id}`, { speaker: '田中さん（ホール）' });
  assert.equal(renamed.status, 200);
  const resolved = await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' });
  assert.equal(resolved.status, 200);

  // 書き込みは持ち主の下に入り、持ち主から見ても同じ
  const mine = (await call('GET', '/manuals/demo-kitchen')).json;
  assert.ok(mine.lines.some((l: any) => l.text === '- 塩 小さじ1/2'));
  assert.equal(mine.utterances.find((x: any) => x.id === u.id).speaker, '田中さん（ホール）');
  assert.equal((await callAs('sato', 'GET', '/shared')).json[0].openCount, open - 1);
  assert.deepEqual((await callAs('sato', 'GET', '/manuals')).json, []);

  // 書き込む前の確認（書き込む・書き込まない）も同じ
  const added = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんからご飯は硬めにすると言われた' });
  const p = added.json.state.patches.find((x: any) => x.utteranceId === added.json.utteranceId);
  assert.equal((await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${p.id}/discard`, {})).status, 200);
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.patches.find((x: any) => x.id === p.id).status, 'discarded');
});

test('教える人の答え：共有された人の確定は、送った名前でなく本人の名前で、本人が答えた記録として残る', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');

  const answered = await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '田中さん',
    decidedAt: '2026-11-10',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一する',
  });
  assert.equal(answered.status, 200);
  const res = answered.json.checks.find((c: any) => c.id === r.check.id).resolution;
  // 日付は送った日でなく、答えた日（日本時間の今日）
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
  assert.deepEqual([res.decidedBy, res.answeredBy, res.decidedAt], ['佐藤店長', 'sato', today]);
  assert.equal(answered.json.utterances.find((u: any) => u.id === res.utteranceId).speaker, '佐藤店長');
  assert.ok(answered.json.lines.some((l: any) => l.text === '- 塩 小さじ1/2'));
});

test('教える人の答え：持ち主が聞いた結果を記録するときは、確認した相手が要り、本人の答えにはしない', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const path = `/manuals/demo-kitchen/checks/${r.check.id}/resolve`;
  assert.equal((await call('POST', path, { decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' })).status, 400);
  const ok = await call('POST', path, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' });
  const res = ok.json.checks.find((c: any) => c.id === r.check.id).resolution;
  assert.deepEqual([res.decidedBy, 'answeredBy' in res], ['店長', false]);
});

test('共同編集：共有された人も共有の相手を足し・外せるが、持ち主には足せず、ノートは消せない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  assert.deepEqual((await callAs('sato', 'GET', '/manuals/demo-kitchen/shares')).json, [{ id: 'sato', name: '佐藤店長' }]);
  assert.equal((await callAs('sato', 'POST', '/manuals/demo-kitchen/shares', { userId: 'demo' })).status, 400);

  const added = await callAs('sato', 'POST', '/manuals/demo-kitchen/shares', { userId: 'kim' });
  assert.equal(added.status, 201);
  // 足した人ではなく、持ち主のノートとして共有される
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json.map((m: any) => m.sharedBy), [{ id: 'demo', name: 'demo' }]);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 200);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json.map((x: any) => x.id), ['sato', 'kim']);

  assert.equal((await callAs('sato', 'DELETE', '/manuals/demo-kitchen')).status, 404);

  // 自分を外すと、自分も読めなくなる
  assert.equal((await callAs('kim', 'DELETE', '/manuals/demo-kitchen/shares/kim')).status, 200);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen/shares')).status, 404);
});

test('共有：共有されていない人は、見ることも直すこともできない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const before = (await call('GET', '/manuals/demo-kitchen')).json;

  const denied: [string, string, string, unknown?][] = [
    ['kim', 'GET', '/manuals/demo-kitchen'],
    ['kim', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' }],
    ['kim', 'POST', '/manuals/demo-kitchen/utterances', { text: '塩は小さじ2' }],
    ['kim', 'POST', '/utterances', { text: '塩は小さじ2', manualIds: ['demo-kitchen'] }],
    ['kim', 'POST', `/manuals/demo-kitchen/patches/${r.patch.id}/discard`, {}],
    ['kim', 'POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-09', text: '- 塩 小さじ1' }],
    ['kim', 'GET', '/manuals/demo-kitchen/shares'],
    ['kim', 'POST', '/manuals/demo-kitchen/shares', { userId: 'kim' }],
    ['kim', 'DELETE', '/manuals/demo-kitchen/shares/sato'],
    // 共有された人も、共有されていないほかのノートは読めない
    ['sato', 'GET', '/manuals/demo-hall'],
    ['sato', 'POST', '/manuals/demo-hall/edits', { op: 'insert', line: null, text: '- x' }],
  ];
  for (const [who, method, path, body] of denied) {
    assert.equal((await callAs(who, method, path, body)).status, 404, `${who} ${method} ${path}`);
  }
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json, []);
  // 記録先を選ばなくても、共有されていないノートには振り分けない
  assert.deepEqual((await callAs('kim', 'POST', '/utterances', { text: '田中さんから塩は小さじ2と言われた' })).json.results, []);
  // 読んだ時刻（asOf）のほかは変わらない
  assert.deepEqual({ ...(await call('GET', '/manuals/demo-kitchen')).json, asOf: before.asOf }, before);
});

test('共同編集：同じ行をほかの人が先に書き換えていたら、書き換え・削除は 409 でだれがどう直したかを返す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const edit = (who: string, body: object) => callAs(who, 'POST', '/manuals/demo-kitchen/edits', { today: '2026-11-10', ...body });

  // 佐藤さんが先に直す。持ち主は古い画面のまま同じ行を直す
  assert.equal((await edit('sato', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2' })).status, 201);
  const replaced = await edit('test', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ2' });
  assert.equal(replaced.status, 409);
  assert.deepEqual(replaced.json.conflict, { line: '- 塩 小さじ1', theirs: '- 塩 小さじ1/2', after: '## 味噌汁', by: '佐藤店長', at: '2026-11-10' });
  const deleted = await edit('test', { op: 'delete', line: '- 塩 小さじ1' });
  assert.equal(deleted.status, 409);
  assert.equal(deleted.json.conflict.theirs, '- 塩 小さじ1/2');

  // 持ち主が先に消した行を佐藤さんが直すと、持ち主の名前で返し、消した行の上の行を返す
  assert.equal((await edit('test', { op: 'delete', line: '- 炊けたら10分蒸らす' })).status, 201);
  const gone = await edit('sato', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす' });
  assert.equal(gone.status, 409);
  assert.deepEqual(gone.json.conflict, { line: '- 炊けたら10分蒸らす', theirs: null, after: '- 大盛りは250gまで', by: 'demo', at: '2026-11-10' });

  // 自分が直した行でも、ほかの画面から古いまま直せば同じく返す
  const own = await edit('test', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- x' });
  assert.equal(own.json.conflict.by, '自分');

  // ノートは先に保存した直しのまま
  const texts = (await call('GET', '/manuals/demo-kitchen')).json.lines.map((l: any) => l.text);
  assert.ok(texts.includes('- 塩 小さじ1/2'));
  assert.ok(!texts.includes('- 塩 小さじ2'));
  assert.ok(!texts.includes('- 炊けたら15分蒸らす'));
});

test('共同編集：足す位置の行が直されていたら、直した行の下（消されていればその上の行の下）に足す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const edit = (who: string, body: object) => callAs(who, 'POST', '/manuals/demo-kitchen/edits', { today: '2026-11-10', ...body });
  await edit('sato', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2' });
  await edit('sato', { op: 'delete', line: '- 炊けたら10分蒸らす' });

  assert.equal((await edit('test', { op: 'insert', line: '- 塩 小さじ1', text: '- 味噌は合わせ味噌' })).status, 201);
  const r = await edit('test', { op: 'insert', line: '- 炊けたら10分蒸らす', text: '- 茶碗は温めておく' });
  assert.equal(r.status, 201);
  const texts = r.json.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 塩 小さじ1/2') + 1], '- 味噌は合わせ味噌');
  assert.equal(texts[texts.indexOf('- 大盛りは250gまで') + 1], '- 茶碗は温めておく');
  // 一度も無かった行は、今までどおり見つからないとする
  assert.equal((await edit('test', { op: 'replace', line: '- 無い行', text: '- x' })).status, 409);
  assert.equal((await edit('test', { op: 'replace', line: '- 無い行', text: '- x' })).json.conflict, undefined);
});

test('共有：外すとすぐ読めなくなり、無い ID と自分の ID には共有できない', async () => {
  await withAccounts();
  assert.equal((await call('POST', '/manuals/demo-kitchen/shares', { userId: 'demo' })).status, 400);
  assert.equal((await call('POST', '/manuals/demo-kitchen/shares', { userId: ' ' })).status, 400);
  for (const id of ['nobody', '../sato']) {
    const missing = await call('POST', '/manuals/demo-kitchen/shares', { userId: id });
    assert.equal(missing.status, 404);
    assert.match(missing.json.error, /アカウントはありません/);
  }
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json, []);

  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'kim' });
  const removed = await call('DELETE', '/manuals/demo-kitchen/shares/sato');
  assert.equal(removed.status, 200);
  assert.deepEqual(removed.json, [{ id: 'kim', name: 'kim' }]);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' })).status, 404);
  assert.deepEqual((await callAs('sato', 'GET', '/shared')).json, []);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 200);
  assert.equal((await call('DELETE', '/manuals/demo-kitchen/shares/sato')).status, 404);
});

test('共有：相手の側の索引だけがあっても、持ち主の側に共有の記録が無ければ読めない', async () => {
  const store = await withAccounts();
  await store.putShared('kim', { id: 'demo-kitchen', ownerId: 'demo', createdAt: '' });
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json, []);
});

test('ノートを消す：本文と記録・確認・共有・資料がまとめて消え、共有していた相手からも見えなくなる', async () => {
  const store = await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  assert.equal((await call('POST', '/manuals/demo-kitchen/materials', { title: '衛生の手引き', text: '- 手洗いは30秒' })).status, 201);
  const hall = (await call('GET', '/manuals/demo-hall')).json;

  const { status } = await call('DELETE', '/manuals/demo-kitchen');
  assert.equal(status, 204);
  assert.equal((await call('GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual((await call('GET', '/manuals')).json.map((m: any) => m.id), ['demo-hall']);
  for (const name of ['utterances', 'patches', 'checks', 'shares', 'materials']) {
    assert.deepEqual(await store.list('demo', 'demo-kitchen', name), [], name);
  }
  assert.deepEqual(await store.listShared('sato'), []);
  assert.deepEqual((await callAs('sato', 'GET', '/shared')).json, []);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual({ ...(await call('GET', '/manuals/demo-hall')).json, asOf: hall.asOf }, hall);
  assert.equal((await call('DELETE', '/manuals/demo-kitchen')).status, 404);
});

test('ノートを消す：持ち主でなければ、共有されていても消せない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const before = (await call('GET', '/manuals/demo-kitchen')).json;
  assert.equal((await callAs('sato', 'DELETE', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('kim', 'DELETE', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await call('DELETE', '/manuals/nothing')).status, 404);
  // 読んだ時刻（asOf）のほかは変わらない
  assert.deepEqual({ ...(await call('GET', '/manuals/demo-kitchen')).json, asOf: before.asOf }, before);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 200);
});

test('入力の形が違えば 400 を返す', async () => {
  const { status } = await call('POST', '/manuals/demo-kitchen/utterances', { text: '' });
  assert.equal(status, 400);
});

test('入力ページから：関係するマニュアルを選んで記録する', async () => {
  const { status, json } = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', today: '2026-11-03' });
  assert.equal(status, 201);
  assert.deepEqual(json.results.map((r: any) => r.manualId), ['demo-kitchen']);
  const [r] = json.results;
  assert.equal(r.state.utterances.find((u: any) => u.id === r.utteranceId).speaker, '田中さん');
  assert.equal(r.state.checks[0].kind, 'contradiction');
});

test('入力ページから：複数のマニュアルにまたがる指示は、それぞれに記録する', async () => {
  const { json } = await call('POST', '/utterances', { text: '田中さんから、レジ締めは店長がやると言われた' });
  assert.deepEqual(json.results.map((r: any) => r.manualId).sort(), ['demo-hall', 'demo-kitchen']);
  for (const r of json.results) assert.equal(r.state.utterances.length, 1);
});

test('入力ページから：関係するマニュアルが無ければ保存せず、選んだマニュアルに記録できる', async () => {
  const none = await call('POST', '/utterances', { text: '傘は入口の傘立てに置く' });
  assert.equal(none.status, 200);
  assert.deepEqual(none.json.results, []);
  assert.equal(none.json.text, '傘は入口の傘立てに置く');
  const manuals = await call('GET', '/manuals');
  assert.ok(manuals.json.every((m: any) => m.utteranceCount === 0));

  const picked = await call('POST', '/utterances', { text: none.json.text, manualIds: ['demo-hall'] });
  assert.equal(picked.status, 201);
  assert.deepEqual(picked.json.results.map((r: any) => r.manualId), ['demo-hall']);
});

test('入力ページから：ファイルや録音はテキストにしてから差分化する', async () => {
  const data = Buffer.from('RIFF').toString('base64');
  const { status, json } = await call('POST', '/utterances', { files: [{ mimeType: 'application/pdf', data }] });
  assert.equal(status, 201);
  assert.equal(json.text, '田中さんから塩は小さじ1/2でいいと言われた');
  assert.equal(json.results[0].state.utterances[0].text, json.text);
});

test('入力ページから：録音は Speech-to-Text、PDF・画像は Gemini で書き起こす', async () => {
  const heard: { mimeType: string; phrases: string[] }[] = [];
  const read: string[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  const split = createApp({
    store,
    ...ai,
    listen: async (f, phrases) => (heard.push({ mimeType: f.mimeType, phrases }), '録音の文'),
    transcribe: async (files) => (read.push(...files.map((f) => f.mimeType)), 'メモの文'),
  });
  const data = Buffer.from('x').toString('base64');
  const res = await split.request('/utterances', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({
      files: [
        { mimeType: 'audio/wav', data },
        { mimeType: 'image/png', data },
      ],
      manualIds: ['demo-kitchen'],
    }),
  });
  assert.equal(((await res.json()) as any).text, '録音の文\nメモの文');
  assert.deepEqual(read, ['image/png']);
  assert.equal(heard.length, 1);
  // 録音のフレーズヒントには、登録した全マニュアルの見出しと項目の頭の語を渡す
  assert.ok(heard[0].phrases.includes('味噌汁'));
  assert.ok(heard[0].phrases.includes('塩'));
  assert.ok(heard[0].phrases.includes('領収書'));
});

test('入力ページから：中身が無い、受け付けない形式のファイルなら 400 を返す', async () => {
  assert.equal((await call('POST', '/utterances', { text: ' ' })).status, 400);
  const data = Buffer.from('x').toString('base64');
  assert.equal((await call('POST', '/utterances', { files: [{ mimeType: 'video/mp4', data }] })).status, 400);
});

test('リワインド：切り出した録音を書き起こして未整理メモにためるだけで、ノートには記録しない', async () => {
  const heard: string[][] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  const rewind = createApp({ store, ...ai, listen: async (_, phrases) => (heard.push(phrases), '塩は小さじ1/2') });
  const res = await rewind.request('/listen', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ data: Buffer.from('RIFF').toString('base64'), at: '2026-11-03T05:05:00.000Z' }),
  });
  assert.equal(res.status, 201);
  const memo = (await res.json()) as any;
  assert.deepEqual(memo, { id: memo.id, at: '2026-11-03T05:05:00.000Z', text: '塩は小さじ1/2' });
  assert.deepEqual(await store.listMemos('demo'), [memo]);
  assert.ok(heard[0].includes('塩'));
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, 0);
});

test('リワインド：聞き取れなければ 422、録音が無ければ 400 を返す', async () => {
  const store = new MemoryStore();
  await signIn(store);
  const silent = createApp({ store, ...ai, listen: async () => '' });
  const post = (body: unknown) =>
    silent.request('/listen', { method: 'POST', headers: { 'Content-Type': 'application/json', ...auth }, body: JSON.stringify(body) });
  const at = '2026-11-03T05:05:00.000Z';
  assert.equal((await post({ data: Buffer.from('x').toString('base64'), at })).status, 422);
  assert.equal((await post({ data: '', at })).status, 400);
  // 時刻は端末をまたいで並べるので、UTC でなければ受けない
  assert.equal((await post({ data: Buffer.from('x').toString('base64'), at: '2026-11-03T14:05:00.000' })).status, 400);
  assert.deepEqual(await store.listMemos('demo'), []);
});

test('未整理メモ：切り出した順に返し、直す・消すができ、ほかの人のメモは見えない', async () => {
  const late = (await call('POST', '/memos', { at: '2026-11-04T00:30:00.000Z', text: 'お冷やはすぐ出す' })).json;
  const early = (await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '塩は小さじいち' })).json;
  assert.deepEqual((await call('GET', '/memos')).json.map((m: any) => m.text), ['塩は小さじいち', 'お冷やはすぐ出す']);

  const edited = await call('PATCH', `/memos/${early.id}`, { text: '塩は小さじ1' });
  assert.deepEqual(edited.json, { ...early, text: '塩は小さじ1' });
  assert.equal((await call('PATCH', `/memos/${early.id}`, { text: ' ' })).status, 400);
  assert.equal((await call('PATCH', '/memos/none', { text: '塩' })).status, 404);

  const removed = await app.request(`/memos/${late.id}`, { method: 'DELETE', headers: auth });
  assert.equal(removed.status, 204);
  // ほかの端末で先に消していても失敗にしない
  assert.equal((await app.request(`/memos/${late.id}`, { method: 'DELETE', headers: auth })).status, 204);
  assert.deepEqual((await call('GET', '/memos')).json, [{ ...early, text: '塩は小さじ1' }]);
  assert.equal((await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '' })).status, 400);

  const other = new MemoryStore();
  await other.putSession({ id: sessionIdOf('sato-token'), userId: 'sato', createdAt: '' });
  await other.putMemo('demo', early);
  const asSato = await createApp({ store: other, ...ai }).request('/memos', { headers: { Authorization: 'Bearer sato-token' } });
  assert.deepEqual(await asSato.json(), []);
});

test('未整理メモ：入力欄に入れたメモは、記録できたら消し、記録先を選び直すときは残す', async () => {
  const memo = (await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '塩は小さじ1/2' })).json;
  const unrelated = await call('POST', '/utterances', { text: '今日はいい天気', memoIds: [memo.id] });
  assert.deepEqual(unrelated.json.results, []);
  assert.equal((await call('GET', '/memos')).json.length, 1);

  const recorded = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', memoIds: [memo.id] });
  assert.equal(recorded.status, 201);
  assert.deepEqual((await call('GET', '/memos')).json, []);
});

test('整形：整えた案を返すだけで、ノートは作らない', async () => {
  const before = (await call('GET', '/manuals')).json.length;
  const { status, json } = await call('POST', '/format', { text: '## 仕込み\n朝は野菜を切る。塩は小さじ1' });
  assert.equal(status, 200);
  assert.deepEqual(json, { text: '## 仕込み\n- 朝は野菜を切る\n- 塩は小さじ1' });
  assert.equal((await call('GET', '/manuals')).json.length, before);
  assert.equal((await call('POST', '/format', { text: ' ' })).status, 400);
});

test('読み取り：PDF・画像から本文と題名の案を返すだけで、ノートは作らない', async () => {
  const before = (await call('GET', '/manuals')).json.length;
  const { status, json } = await call('POST', '/read', { files: [{ mimeType: 'application/pdf', data: 'JVBERg==' }] });
  assert.equal(status, 200);
  assert.deepEqual(json, { title: 'キッチンマニュアル', text: '仕込み\n野菜を切る 塩は小さじ1' });
  assert.equal((await call('GET', '/manuals')).json.length, before);
  assert.equal((await call('POST', '/read', { files: [] })).status, 400);
  // 録音はノートの本文にしない
  assert.equal((await call('POST', '/read', { files: [{ mimeType: 'audio/wav', data: 'AAAA' }] })).status, 400);
});

test('読み取り：文字が読み取れなければ 422 を返す', async () => {
  const store = new MemoryStore();
  await signIn(store);
  app = createApp({ store, ...ai, readNote: async () => ({ title: '', text: '' }) });
  const { status } = await call('POST', '/read', { files: [{ mimeType: 'image/png', data: 'iVBORw==' }] });
  assert.equal(status, 422);
});

test('起動時のデモの履歴は、反映済みのパッチが順に当たり、食い違いの確認が1件だけ残る', async () => {
  const store = new MemoryStore();
  await seedWithHistory(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai });

  const { status, json } = await call('GET', '/manuals/demo-kitchen');
  assert.equal(status, 200);
  const texts = json.lines.map((l: any) => l.text);
  assert.ok(texts.includes('- まな板は使うたびに熱湯をかける（週1回は漂白する）'));
  assert.ok(texts.includes('- 保温は2時間まで（過ぎたらまかないに回す）'));
  assert.ok(texts.includes('- 洗った皿は左の棚に戻す'));
  assert.ok(texts.includes('- 冷蔵庫の温度を開店前と閉店後に記録する'));
  // ノートのままと確定した行と、まだ確認していない行は変わらない。デモで使う塩の行にも触れない
  assert.ok(texts.includes('- 大盛りは250gまで'));
  assert.ok(texts.includes('- ガスの元栓を閉めて写真を撮る'));
  assert.ok(texts.includes('- 塩 小さじ1'));

  const manuals = (await call('GET', '/manuals')).json;
  assert.deepEqual(manuals.map((m: any) => [m.id, m.openCount]).sort(), [['demo-hall', 0], ['demo-kitchen', 1]]);

  // 2回目の起動では積み直さない
  await seedWithHistory(store, 'demo');
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, json.utterances.length);
});

/** 資料の読み取りなどを差し替えて、アプリを作り直す */
async function withDeps(deps: Partial<Deps>) {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai, ...deps });
  return store;
}

/** n ページの白紙の PDF */
async function pdfOf(n: number) {
  const doc = await PDFDocument.create();
  for (let i = 0; i < n; i++) doc.addPage();
  return { mimeType: 'application/pdf', data: await doc.saveAsBase64() };
}

const png = { mimeType: 'image/png', data: 'iVBORw==' };

/** 読み取りの呼び出しを記録し、何回目のどのページかが分かる本文を返す。題名は1回目と2回目で変える */
function readings() {
  const calls: { files: InlineFile[]; pages: number }[] = [];
  const readMaterial: ReadMaterial = async (files, pages) => {
    calls.push({ files, pages });
    const n = calls.length;
    return { title: n === 1 ? '店舗マニュアル' : '別の題名', pages: Array.from({ length: pages }, (_, i) => `- ${n}回目の${i + 1}ページ目`) };
  };
  return { calls, readMaterial };
}

const withoutId = ({ id: _, createdAt: __, ...rest }: any) => rest;

test('資料：貼り付けた文を足すと、空行を除いた行・ページ無し・トークン数が返り、一覧と中身に出る', async () => {
  const added = await call('POST', '/manuals/demo-kitchen/materials', {
    title: ' 衛生の手引き ',
    text: '## 手洗い\n\n- 手洗いは30秒  \n  - 指の間も洗う\n   \n- 爪は短く',
  });
  assert.equal(added.status, 201);
  // 偽のトークン数は、プロンプトに載せる形（L 付きの行）の文字数
  const prompt = 'L1: ## 手洗い\nL2: - 手洗いは30秒\nL3:   - 指の間も洗う\nL4: - 爪は短く';
  // 足した人は、名前を決めていなければ ID を名前にする（ADR 0010）
  assert.deepEqual(withoutId(added.json), {
    title: '衛生の手引き',
    pageCount: null,
    lineCount: 4,
    tokens: prompt.length,
    addedBy: { id: 'demo', name: 'demo' },
  });
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, [added.json]);

  const { status, json } = await call('GET', `/manuals/demo-kitchen/materials/${added.json.id}`);
  assert.equal(status, 200);
  // lines の位置 + 1 が行番号。行頭の空白（入れ子）は残す
  assert.deepEqual(json, {
    ...added.json,
    lines: [
      { page: null, text: '## 手洗い' },
      { page: null, text: '- 手洗いは30秒' },
      { page: null, text: '  - 指の間も洗う' },
      { page: null, text: '- 爪は短く' },
    ],
  });
  // ノートの応答には資料を載せない
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.materials, undefined);
});

test('資料：PDF・画像は5ページずつに分けて同時に読み、ページ番号は分けた順から通しで付ける', async () => {
  let r = readings();
  await withDeps({ readMaterial: r.readMaterial });
  const three = await call('POST', '/manuals/demo-kitchen/materials', { files: [await pdfOf(3)] });
  assert.equal(three.status, 201);
  assert.deepEqual(r.calls.map((x) => x.pages), [3]);
  assert.deepEqual([three.json.title, three.json.pageCount, three.json.lineCount], ['店舗マニュアル', 3, 3]);
  const body = (await call('GET', `/manuals/demo-kitchen/materials/${three.json.id}`)).json;
  assert.deepEqual(body.lines.map((l: any) => l.page), [1, 2, 3]);

  r = readings();
  await withDeps({ readMaterial: r.readMaterial });
  const six = await call('POST', '/manuals/demo-kitchen/materials', { title: 'うちの手引き', files: [await pdfOf(6)] });
  assert.equal(six.status, 201);
  assert.deepEqual(r.calls.map((x) => x.pages), [5, 1]);
  // 分けた PDF は、それぞれそのページの数だけを持つ
  const counts = await Promise.all(r.calls.map(async (x) => (await PDFDocument.load(Buffer.from(x.files[0].data, 'base64'))).getPageCount()));
  assert.deepEqual(counts, [5, 1]);
  // 入れた題名は読み取った題名より優先する
  assert.deepEqual([six.json.title, six.json.pageCount], ['うちの手引き', 6]);
  const lines = (await call('GET', `/manuals/demo-kitchen/materials/${six.json.id}`)).json.lines;
  assert.deepEqual(lines.slice(-2), [
    { page: 5, text: '- 1回目の5ページ目' },
    { page: 6, text: '- 2回目の1ページ目' },
  ]);

  r = readings();
  await withDeps({ readMaterial: r.readMaterial });
  const photos = await call('POST', '/manuals/demo-kitchen/materials', { files: Array(7).fill(png) });
  assert.equal(photos.status, 201);
  assert.deepEqual(r.calls.map((x) => x.files.length), [5, 2]);
  assert.equal(photos.json.pageCount, 7);
});

test('資料：形の違うファイル・31ページの PDF・題名の無い貼り付けは 400 で、読み取らず保存もしない', async () => {
  const r = readings();
  await withDeps({ readMaterial: r.readMaterial });
  const pdf = await pdfOf(1);
  const kinds = 'PDF は1つずつ、画像は10枚まで足せます。PDF と画像はまぜられません';
  const either = '文を貼り付けるか、ファイルを選んでください';
  const bodies = [
    [{ files: [pdf, pdf] }, kinds],
    [{ files: [pdf, png] }, kinds],
    [{ files: Array(11).fill(png) }, kinds],
    [{ files: [{ mimeType: 'image/png', data: 'A'.repeat(15_000_004) }] }, 'ファイルは合わせて10MBまでにしてください'],
    [{ files: [{ mimeType: 'audio/wav', data: 'AAAA' }] }, 'files[0].mimeType'],
    [{ title: '手引き', text: '- 手洗いは30秒', files: [png] }, either],
    [{ title: '手引き', text: '  ' }, either],
    [{ text: '- 手洗いは30秒' }, '貼り付けた文には題名を付けてください'],
  ] as const;
  for (const [body, message] of bodies) {
    const { status, json } = await call('POST', '/manuals/demo-kitchen/materials', body);
    assert.equal(status, 400);
    assert.ok(json.error.includes(message), json.error);
  }
  const long = await call('POST', '/manuals/demo-kitchen/materials', { files: [await pdfOf(31)] });
  assert.deepEqual([long.status, long.json.error], [400, 'PDF は30ページまでにしてください。分けて足してください']);
  assert.equal(r.calls.length, 0);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, []);
});

test('資料：文字が読み取れない・開けない PDF は 422、読み取りが失敗したら 502 で、どれも保存しない', async () => {
  await withDeps({ readMaterial: async (_, n) => ({ title: '', pages: Array(n).fill('') }) });
  const empty = await call('POST', '/manuals/demo-kitchen/materials', { files: [png] });
  assert.deepEqual([empty.status, empty.json.error], [422, '資料から文字を読み取れませんでした']);
  const broken = await call('POST', '/manuals/demo-kitchen/materials', { files: [{ mimeType: 'application/pdf', data: 'JVBERg==' }] });
  assert.deepEqual([broken.status, broken.json.error], [422, 'PDF を開けませんでした。パスワードの付いた PDF は読めません']);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, []);

  await withDeps({
    readMaterial: async () => {
      throw new Error('Gemini が混んでいる');
    },
  });
  const failed = await call('POST', '/manuals/demo-kitchen/materials', { files: [png] });
  assert.deepEqual([failed.status, failed.json.error], [502, '資料を読み取れませんでした。少し待ってからもう一度足してください']);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, []);
});

test('資料：1冊・1つのノートの上限を超えると 400 で保存しない。ノートの上限はほかのノートの資料を数えない', async () => {
  // 本文の「N tok」をトークン数にする
  await withDeps({ countTokens: async (text) => Number(/(\d+) tok/.exec(text)![1]) });
  const add = (manualId: string, tokens: number) =>
    call('POST', `/manuals/${manualId}/materials`, { title: `${tokens}`, text: `- ${tokens} tok` });

  const big = await add('demo-kitchen', 30_001);
  assert.deepEqual([big.status, big.json.error], [400, '資料が大きすぎます（約30001トークン。1冊30000トークンまで）。ページを分けて足してください']);

  for (const tokens of [30_000, 30_000, 30_000, 10_000]) assert.equal((await add('demo-kitchen', tokens)).status, 201);
  const over = await add('demo-kitchen', 1);
  assert.deepEqual(
    [over.status, over.json.error],
    [400, 'このノートの資料は合わせて100000トークンまでです（いま約100000トークン）。使わない資料を消してから足してください'],
  );
  assert.equal((await call('GET', '/manuals/demo-kitchen/materials')).json.length, 4);
  assert.equal((await add('demo-hall', 30_000)).status, 201);

  // 消せば、また足せる
  const [first] = (await call('GET', '/manuals/demo-kitchen/materials')).json;
  assert.equal((await call('DELETE', `/manuals/demo-kitchen/materials/${first.id}`)).status, 204);
  assert.equal((await add('demo-kitchen', 1)).status, 201);
});

test('資料：共有された人も、見る・足す・消すができ、足した人として残る。共有されていない人は何もできない', async () => {
  const store = await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const mine = (await call('POST', '/manuals/demo-kitchen/materials', { title: '衛生の手引き', text: '- 手洗いは30秒' })).json;
  assert.deepEqual((await callAs('sato', 'GET', '/manuals/demo-kitchen/materials')).json, [mine]);
  assert.deepEqual((await callAs('sato', 'GET', `/manuals/demo-kitchen/materials/${mine.id}`)).json.lines, [{ page: null, text: '- 手洗いは30秒' }]);

  // 共有された人が足した資料も、持ち主のノートの下に置く
  const theirs = await callAs('sato', 'POST', '/manuals/demo-kitchen/materials', { title: '店長メモ', text: '- 爪は短く' });
  assert.equal(theirs.status, 201);
  assert.deepEqual(theirs.json.addedBy, { id: 'sato', name: '佐藤店長' });
  assert.deepEqual((await store.list<any>('demo', 'demo-kitchen', 'materials')).map((m) => m.id), [mine.id, theirs.json.id]);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, [mine, theirs.json]);
  // 持ち主が足したものも消せる
  assert.equal((await callAs('sato', 'DELETE', `/manuals/demo-kitchen/materials/${mine.id}`)).status, 204);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, [theirs.json]);

  const path = `/manuals/demo-kitchen/materials/${theirs.json.id}`;
  const notFound = { status: 404, json: { error: 'ノートが見つかりません' } };
  assert.deepEqual(await callAs('kim', 'GET', '/manuals/demo-kitchen/materials'), notFound);
  assert.deepEqual(await callAs('kim', 'GET', path), notFound);
  assert.deepEqual(await callAs('kim', 'POST', '/manuals/demo-kitchen/materials', { title: '手引き', text: '- 爪は短く' }), notFound);
  assert.deepEqual(await callAs('kim', 'DELETE', path), notFound);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, [theirs.json]);
  // ノートそのものを消せるのは、今までどおり持ち主だけ
  assert.equal((await callAs('sato', 'DELETE', '/manuals/demo-kitchen')).status, 404);
});

test('資料：消すと一覧から消え、無い資料は 404。ノートの記録と確認は変えない', async () => {
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  const a = (await call('POST', '/manuals/demo-kitchen/materials', { title: '衛生の手引き', text: '- 手洗いは30秒' })).json;
  const b = (await call('POST', '/manuals/demo-kitchen/materials', { files: [png] })).json;
  const before = (await call('GET', '/manuals/demo-kitchen')).json;

  assert.equal((await call('DELETE', `/manuals/demo-kitchen/materials/${a.id}`)).status, 204);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/materials')).json, [b]);
  const gone = { status: 404, json: { error: '資料が見つかりません' } };
  assert.deepEqual(await call('GET', `/manuals/demo-kitchen/materials/${a.id}`), gone);
  assert.deepEqual(await call('DELETE', `/manuals/demo-kitchen/materials/${a.id}`), gone);
  assert.equal((await call('GET', '/manuals/nothing/materials')).status, 404);
  // 読んだ時刻（asOf）のほかは変わらない
  assert.deepEqual({ ...(await call('GET', '/manuals/demo-kitchen')).json, asOf: before.asOf }, before);
});

/** 休憩・ご飯の保温・片付けの決まりを、貼り付けた文の資料として demo-kitchen に足す。ノートにはどの行も無い */
async function addRules() {
  const { status, json } = await call('POST', '/manuals/demo-kitchen/materials', {
    title: '店舗マニュアル',
    text: '## 休憩\n- 休憩は30分\n## ご飯\n- ご飯は保温2時間まで\n## 片付け\n- 片付けは閉店前に終える',
  });
  assert.equal(status, 201);
  return json;
}

const texts = (state: any) => state.lines.map((l: any) => l.text) as string[];
const resolve = (checkId: string, text: string, note = '') =>
  call('POST', `/manuals/demo-kitchen/checks/${checkId}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-07', text, note });

/** 直接書いた行を確かめ、その確認を返す */
async function editAndCheck(body: object) {
  const { patch } = await edit(body);
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  return { patch, check: json.checks.find((c: any) => c.patchId === patch.id), state: json };
}

test('資料：記録・書き起こしの読み直しの判定に、そのノートの資料と、今ある資料に結び付いた確定が載る', async () => {
  const inputs: AssessInput[] = [];
  await withDeps({ assess: (i) => (inputs.push(i), fakeAssess(i)) });
  const rules = await addRules();
  // 記録先を選ばない振り分けには、どのノートの資料も、ノートごとに載る
  await call('POST', '/utterances', { text: 'お疲れさまと言われた', today: '2026-11-03' });
  assert.deepEqual(
    inputs[0].manuals.map((m) => m.materials),
    [
      [
        {
          id: rules.id,
          title: '店舗マニュアル',
          lines: [
            { page: null, text: '## 休憩' },
            { page: null, text: '- 休憩は30分' },
            { page: null, text: '## ご飯' },
            { page: null, text: '- ご飯は保温2時間まで' },
            { page: null, text: '## 片付け' },
            { page: null, text: '- 片付けは閉店前に終える' },
          ],
        },
      ],
      [],
    ],
  );

  // 資料と食い違った記録を資料のままに確定すると、以後の判定に資料の行を添えて載る。ノートの確定済みの記録には出さない
  const r = await record('田中さんから休憩は45分と言われた');
  await resolve(r.check.id, '- 休憩は30分', '30分のまま');
  const u = await record('田中さんからご飯は保温3時間までと言われた');
  const reread = await call('PATCH', `/manuals/demo-kitchen/utterances/${u.utterance.id}`, { text: '田中さんからご飯は保温4時間までと言われた' });
  assert.equal(reread.status, 200);
  const last = inputs.at(-1)!.manuals[0];
  assert.equal(inputs.at(-1)!.text, '田中さんからご飯は保温4時間までと言われた');
  assert.deepEqual(last.materials.map((m) => m.id), [rules.id]);
  assert.deepEqual(last.materialConfirmations, [
    { materialId: rules.id, lineNo: 2, page: null, text: '2026-11-07 店長に確認：30分のまま（資料のとおり「- 休憩は30分」）' },
  ]);
  assert.deepEqual(last.confirmations, []);

  // 資料を消すと、その資料も、その資料に結び付いた確定も載らない
  assert.equal((await call('DELETE', `/manuals/demo-kitchen/materials/${rules.id}`)).status, 204);
  await record('田中さんから休憩は45分と言われた');
  assert.deepEqual([inputs.at(-1)!.manuals[0].materials, inputs.at(-1)!.manuals[0].materialConfirmations], [[], []]);
});

test('資料：偽の Gemini でも、資料の行と頭の言葉が同じで中身の違う記録は資料と矛盾になり、同じ文なら資料と同じ内容になる', async () => {
  // 偽の読み取りは「## 味噌汁」「- 味噌汁の塩は小さじ1」「- だしは昆布でとる」を返す
  const m = (await call('POST', '/manuals/demo-kitchen/materials', { files: [png] })).json;
  const r = await record('田中さんから味噌汁の塩は小さじ1/2でいいと言われた');
  assert.deepEqual(
    [r.check.kind, r.check.conflictLine, r.check.materialRef],
    ['contradiction', '- 味噌汁の塩は小さじ1', { materialId: m.id, title: '店舗マニュアル', page: 1, lineNo: 2 }],
  );
  const same = await record('田中さんからだしは昆布でとると言われた');
  assert.deepEqual(
    [same.check.kind, same.check.sameLine, same.check.materialRef],
    ['same', '- だしは昆布でとる', { materialId: m.id, title: '店舗マニュアル', page: 1, lineNo: 3 }],
  );
  // ノートの行と食い違うものは、今まで通りノートの行が相手
  const note = await record('田中さんから塩は小さじ1/2でいいと言われた');
  assert.deepEqual([note.check.conflictLine, note.check.materialRef], ['- 塩 小さじ1', null]);
});

test('資料と食い違った口頭の記録の確定：資料のままならノートを変えず、別の内容なら元のパッチの位置に書く。位置の行が無ければ末尾', async () => {
  await addRules();
  const before = texts((await call('GET', '/manuals/demo-kitchen')).json);

  const keep = await record('田中さんから休憩は45分と言われた');
  assert.equal(keep.check.materialRef.lineNo, 2);
  const kept = (await resolve(keep.check.id, '- 休憩は30分')).json;
  assert.deepEqual(texts(kept), before);
  assert.equal(kept.patches.find((p: any) => p.id === keep.patch.id).status, 'discarded');
  assert.deepEqual(kept.checks.find((c: any) => c.id === keep.check.id).resolution.patchId, null);

  const rice = await record('田中さんからご飯は保温3時間までと言われた');
  assert.deepEqual([rice.patch.op, rice.patch.line, rice.check.conflictLine], ['insert', '- 炊けたら10分蒸らす', '- ご飯は保温2時間まで']);
  const other = (await resolve(rice.check.id, '- ご飯は保温2時間半まで')).json;
  const t = texts(other);
  assert.equal(t[t.indexOf('- 炊けたら10分蒸らす') + 1], '- ご飯は保温2時間半まで');
  const resolution = other.checks.find((c: any) => c.id === rice.check.id).resolution;
  const fix = other.patches.find((p: any) => p.id === resolution.patchId);
  assert.deepEqual([fix.status, fix.utteranceId], ['applied', resolution.utteranceId]);
  assert.equal(other.patches.find((p: any) => p.id === rice.patch.id).status, 'discarded');

  // 新しい方に決まり、元のパッチの位置の行がもう無いときは末尾に書く
  const tidy = await record('田中さんから片付けは閉店後でいいと言われた');
  assert.deepEqual([tidy.patch.line, tidy.check.conflictLine], ['- まな板は使うたびに熱湯をかける', '- 片付けは閉店前に終える']);
  await edit({ op: 'delete', line: '- まな板は使うたびに熱湯をかける' });
  const newer = (await resolve(tidy.check.id, tidy.patch.text)).json;
  assert.equal(texts(newer).at(-1), tidy.patch.text);
});

test('資料と食い違った直接書いた行の確定：資料のままなら書いた行を消し、別の内容なら置き換え、新しい方なら残す。消された行は変えない', async () => {
  await addRules();
  const before = texts((await call('GET', '/manuals/demo-kitchen')).json);

  const keep = await editAndCheck({ op: 'insert', line: '- 炊けたら10分蒸らす', text: '- 休憩は45分' });
  assert.deepEqual([keep.check.kind, keep.check.conflictLine, keep.check.materialRef.lineNo], ['contradiction', '- 休憩は30分', 2]);
  const kept = (await resolve(keep.check.id, '- 休憩は30分')).json;
  assert.deepEqual(texts(kept), before);
  assert.equal(kept.checks.find((c: any) => c.id === keep.check.id).resolution.patchId, null);

  // 確定の前に書いた行を消していたら、確定の記録だけ残す
  const gone = await editAndCheck({ op: 'insert', line: null, text: '- 休憩は60分' });
  await edit({ op: 'delete', line: '- 休憩は60分' });
  const untouched = (await resolve(gone.check.id, '- 休憩は40分')).json;
  assert.deepEqual(texts(untouched), before);
  assert.deepEqual(untouched.checks.find((c: any) => c.id === gone.check.id).resolution.patchId, null);

  const other = await editAndCheck({ op: 'insert', line: null, text: '- 休憩は50分' });
  const replaced = (await resolve(other.check.id, '- 休憩は40分')).json;
  assert.deepEqual(texts(replaced), [...before, '- 休憩は40分']);
  assert.equal(replaced.lines.at(-1).patchId, replaced.checks.find((c: any) => c.id === other.check.id).resolution.patchId);

  const newer = await editAndCheck({ op: 'insert', line: null, text: '- ご飯は保温3時間まで' });
  assert.equal(newer.check.conflictLine, '- ご飯は保温2時間まで');
  const stayed = (await resolve(newer.check.id, '- ご飯は保温3時間まで')).json;
  assert.deepEqual(texts(stayed), [...before, '- 休憩は40分', '- ご飯は保温3時間まで']);
  assert.equal(stayed.checks.find((c: any) => c.id === newer.check.id).resolution.patchId, null);
});

test('資料と食い違った確定：同じ資料から作ったノートに同じ文の行があっても、それを相手と取り違えない', async () => {
  // ノートの「- 塩 小さじ1」と同じ文の資料の行を相手にした、資料との食い違い
  const assess: Assess = async ({ manuals }) => {
    const m = manuals[0].materials[0];
    return {
      speaker: '田中さん',
      saidAt: null,
      items: [
        {
          manual: 0,
          patch: { op: 'insert', line: null, text: '- 塩 小さじ2', summary: '塩' },
          check: {
            kind: 'contradiction',
            conflictLine: m.lines[0].text,
            sameLine: null,
            reason: '資料と違う',
            ask: { candidates: [{ who: '店長', why: '決める立場' }], question: 'どちらですか？' },
            materialRef: { materialId: m.id, title: m.title, page: null, lineNo: 1 },
          },
        },
      ],
    };
  };
  await withDeps({ assess });
  await call('POST', '/manuals/demo-kitchen/materials', { title: '店舗マニュアル', text: '- 塩 小さじ1' });
  const before = (await call('GET', '/manuals/demo-kitchen')).json.lines;

  const keep = await record('田中さんから塩は小さじ2と言われた');
  assert.deepEqual((await resolve(keep.check.id, '- 塩 小さじ1')).json.lines, before);
  // 別の内容に決まっても、ノートの同じ文の行は書き換えず、元のパッチの位置（末尾）に書く
  const other = await record('田中さんから塩は小さじ2と言われた');
  const t = texts((await resolve(other.check.id, '- 塩 小さじ1/2')).json);
  assert.ok(t.includes('- 塩 小さじ1'));
  assert.equal(t.at(-1), '- 塩 小さじ1/2');
});

test('資料：共有された人の直接編集の確かめにも、持ち主のノートの資料が載る', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const rules = await addRules();
  const { json } = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- 休憩は45分', today: '2026-11-08' });
  const patch = json.patches.at(-1);
  const checked = await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  const chk = checked.json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine, chk.materialRef?.materialId], ['contradiction', '- 休憩は30分', rules.id]);
});

test('資料：いくつものノートをまとめて記録に載せるとき、資料の合計が上限を超えたら、書き起こす前に 400 で記録先を選んでもらう', async () => {
  let transcribed = 0;
  // 本文の「N tok」をトークン数にする
  await withDeps({
    countTokens: async (text) => Number(/(\d+) tok/.exec(text)![1]),
    transcribe: async () => (transcribed++, '田中さんから塩は小さじ1/2でいいと言われた'),
  });
  const add = (manualId: string, tokens: number) => call('POST', `/manuals/${manualId}/materials`, { title: `${tokens}`, text: `- ${tokens} tok` });
  for (const tokens of [30_000, 30_000, 30_000, 10_000]) assert.equal((await add('demo-kitchen', tokens)).status, 201);
  assert.equal((await add('demo-hall', 1)).status, 201);

  const auto = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', files: [png], today: '2026-11-03' });
  assert.deepEqual(
    [auto.status, auto.json.error],
    [
      400,
      '記録先が自動のときは、すべてのノートの資料と照らし合わせます。資料が合わせて約100001トークンあり、1回に照らし合わせられる100000トークンを超えています。記録先のノートを選んでから記録してください',
    ],
  );
  assert.equal(transcribed, 0);
  const both = await call('POST', '/utterances', { text: 'x', manualIds: ['demo-kitchen', 'demo-hall'] });
  assert.deepEqual(
    [both.status, both.json.error],
    [400, '選んだノートの資料が合わせて約100001トークンあり、1回に照らし合わせられる100000トークンを超えています。記録先のノートを減らしてから記録してください'],
  );
  // 1冊なら、そのノートの上限に収まっているので記録できる
  const one = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', manualIds: ['demo-kitchen'], today: '2026-11-03' });
  assert.equal(one.status, 201);
  assert.equal((await call('POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた' })).status, 201);
});

// 記録を見せて済ませる（#118）。聞き直さず、前の確定の記録を見せて確定する。決めたのは前の人で、見せたのは押した人

const japanToday = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
const showRecord = (checkId: string, shownFrom: string, as?: string) =>
  as
    ? callAs(as, 'POST', `/manuals/demo-kitchen/checks/${checkId}/resolve`, { shownFrom })
    : call('POST', `/manuals/demo-kitchen/checks/${checkId}/resolve`, { shownFrom });
const resolutionOf = (state: any, checkId: string) => state.checks.find((c: any) => c.id === checkId).resolution;
const utteranceOf = (state: any, id: string) => state.utterances.find((u: any) => u.id === id);

/** 田中さんの「小さじ1/2」を 11/7 に店長に確認して 1/2 に決め、そのあと佐藤さんが「小さじ1」と言った */
async function saltSettled() {
  const first = await record('田中さんから塩は小さじ1/2でいいと言われた');
  await resolve(first.check.id, '- 塩 小さじ1/2', '1/2で統一');
  const again = await record('佐藤さんから塩は小さじ1でいいと言われた');
  assert.deepEqual([again.check.kind, again.check.conflictLine, again.check.materialRef], ['contradiction', '- 塩 小さじ1/2', null]);
  return { first, again };
}

test('記録を見せて済ませる：ノートの行の確定を見せると、中身は前の確定のまま、答えは見せた人の行いとして残り、ノートの行は変わらない', async () => {
  await call('PUT', '/me', { name: 'かなで', icon: null });
  const { first, again } = await saltSettled();
  const before = (await call('GET', '/manuals/demo-kitchen')).json;

  const { status, json } = await showRecord(again.check.id, first.check.id);
  assert.equal(status, 200);
  assert.deepEqual(json.lines, before.lines);
  assert.equal(json.lines.filter((l: any) => l.text === '- 塩 小さじ1/2').length, 1);
  assert.equal(json.patches.length, before.patches.length);
  assert.equal(json.patches.find((p: any) => p.id === again.patch.id).status, 'discarded');

  const r = resolutionOf(json, again.check.id);
  const today = japanToday();
  assert.deepEqual(r, {
    utteranceId: r.utteranceId,
    patchId: null,
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
    shown: { by: { id: 'demo', name: 'かなで' }, at: today },
  });
  // 店長の発言にはしない。発言者は見せた人で、いつ誰の記録を見せたかの文
  const answer = utteranceOf(json, r.utteranceId);
  assert.deepEqual(
    [answer.speaker, answer.saidAt, answer.text, answer.recordedBy],
    ['かなで', today, '11/7 店長に確認した記録（1/2で統一）を見せた', { id: 'demo', name: 'かなで' }],
  );
  assert.deepEqual(
    json.utterances.filter((u: any) => u.speaker === '店長').map((u: any) => u.id),
    [resolutionOf(json, first.check.id).utteranceId],
  );

  // 確定済みの項目は確定できず、確定していない確認や無い確認は見せられない
  assert.equal((await showRecord(again.check.id, first.check.id)).status, 409);
  const third = await record('佐藤さんから塩は小さじ1でいいと言われた');
  const fourth = await record('佐藤さんから塩は小さじ1でいいと言われた');
  assert.equal((await showRecord(fourth.check.id, third.check.id)).status, 409);
  assert.equal((await showRecord(fourth.check.id, 'nothing')).status, 404);
});

test('記録を見せて済ませる：共有された人が押しても、決めた人は前の人のままで、その人の答え（決定）にはしない。前が本人の決定なら決定のまま引き継ぐ', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const { first, again } = await saltSettled();

  const shown = await showRecord(again.check.id, first.check.id, 'sato');
  assert.equal(shown.status, 200);
  const r = resolutionOf(shown.json, again.check.id);
  assert.deepEqual(
    [r.decidedBy, r.decidedAt, 'answeredBy' in r, r.shown],
    ['店長', '2026-11-07', false, { by: { id: 'sato', name: '佐藤店長' }, at: japanToday() }],
  );
  const answer = utteranceOf(shown.json, r.utteranceId);
  assert.deepEqual([answer.speaker, answer.recordedBy.id], ['佐藤店長', 'sato']);
  assert.equal(shown.json.lines.filter((l: any) => l.text === '- 塩 小さじ1/2').length, 1);

  // 佐藤店長が自分で決めた確定を、持ち主が見せたとき
  const said = await record('田中さんから塩は小さじ2でいいと言われた');
  const answered = await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${said.check.id}/resolve`, {
    decidedAt: '2026-11-08',
    text: '- 塩 小さじ1/2',
    note: 'やっぱり1/2',
  });
  assert.equal(resolutionOf(answered.json, said.check.id).answeredBy, 'sato');
  const later = await record('佐藤さんから塩は小さじ1でいいと言われた');
  const own = await showRecord(later.check.id, said.check.id);
  const decided = resolutionOf(own.json, later.check.id);
  assert.deepEqual(
    [decided.decidedBy, decided.answeredBy, decided.decidedAt, decided.shown.by],
    ['佐藤店長', 'sato', japanToday(), { id: 'demo', name: 'demo' }],
  );
  const md = `${Number(japanToday().slice(5, 7))}/${Number(japanToday().slice(8, 10))}`;
  assert.equal(utteranceOf(own.json, decided.utteranceId).text, `${md} 佐藤店長が決定した記録（やっぱり1/2）を見せた`);
});

test('記録を見せて済ませる：確定した行を書き換えていたら、前の確定の内容に戻す。戻した行の出どころは、見せた人でなく元の確定の人と日付', async () => {
  const inputs: AssessInput[] = [];
  await withDeps({ assess: (i) => (inputs.push(i), fakeAssess(i)) });
  const first = await record('田中さんから塩は小さじ1/2でいいと言われた');
  await resolve(first.check.id, '- 塩 小さじ1/2', '1/2で統一');
  const edited = await editAndCheck({ op: 'replace', line: '- 塩 小さじ1/2', text: '- 塩 小さじ1' });
  assert.deepEqual([edited.check.kind, edited.check.conflictLine], ['contradiction', '- 塩 小さじ1/2']);

  const { json } = await showRecord(edited.check.id, first.check.id);
  const t = texts(json);
  assert.equal(t.filter((x) => x === '- 塩 小さじ1/2').length, 1);
  assert.ok(!t.includes('- 塩 小さじ1'));
  const r = resolutionOf(json, edited.check.id);
  assert.equal(json.lines.find((l: any) => l.text === '- 塩 小さじ1/2').patchId, r.patchId);

  await record('田中さんからご飯は硬めにすると言われた');
  const ctx = inputs.at(-1)!.manuals[0];
  assert.equal(ctx.lines.find((l) => l.text === '- 塩 小さじ1/2')!.note, '店長（2026-11-07）に確認して確定');
  assert.deepEqual(ctx.confirmations, ['2026-11-07 店長に確認：1/2で統一（「- 塩 小さじ1」→「- 塩 小さじ1/2」）']);
});

test('記録を見せて済ませる：見せた確定は判定に重ねて載せず、資料が0冊なら記録の判定に渡す指示文・プロンプト・スキーマは見せる前と1文字も変わらない', async () => {
  const inputs: AssessInput[] = [];
  await withDeps({ assess: (i) => (inputs.push(i), fakeAssess(i)) });
  const { first, again } = await saltSettled();
  await record('田中さんからご飯は硬めにすると言われた');
  const before = inputs.at(-1)!;
  assert.equal((await showRecord(again.check.id, first.check.id)).status, 200);
  await record('田中さんからご飯は硬めにすると言われた');
  const after = inputs.at(-1)!;

  assert.deepEqual(after.manuals[0].confirmations, ['2026-11-07 店長に確認：1/2で統一（「- 塩 小さじ1」→「- 塩 小さじ1/2」）']);
  // 見せた人（demo）は、言われたことの発言者に数えない
  assert.ok(!after.speakers.includes('demo'));
  const sent = async (input: AssessInput) => {
    let req: unknown;
    await assessWithGemini(input, async (r) => {
      req = { system: r.system, prompt: r.prompt, schema: toGeminiSchema(r.schema) };
      return r.schema.parse({ speaker: null, saidAt: null, patches: [] });
    });
    return req;
  };
  assert.deepEqual(await sent(after), await sent(before));
});

/** 休憩の決まりの資料を足し、田中さんの「45分」を 11/7 に店長に確認して「資料のまま」に決めた */
async function breakKept() {
  const rules = await addRules();
  const first = await record('田中さんから休憩は45分と言われた');
  await resolve(first.check.id, '- 休憩は30分', '30分のまま');
  return { rules, first };
}

test('記録を見せて済ませる：資料のままに決まった確定を見せると、ノートは変えず、書いた行があれば消す。判定には前の確定だけが載る', async () => {
  const inputs: AssessInput[] = [];
  await withDeps({ assess: (i) => (inputs.push(i), fakeAssess(i)) });
  const { rules, first } = await breakKept();
  const before = texts((await call('GET', '/manuals/demo-kitchen')).json);

  const said = await record('佐藤さんから休憩は60分と言われた');
  assert.equal(said.check.materialRef.lineNo, 2);
  const shown = (await showRecord(said.check.id, first.check.id)).json;
  assert.deepEqual(texts(shown), before);
  const r = resolutionOf(shown, said.check.id);
  assert.deepEqual([r.decidedBy, r.decidedAt, r.text, r.note, r.patchId], ['店長', '2026-11-07', '- 休憩は30分', '30分のまま', null]);
  assert.equal(utteranceOf(shown, r.utteranceId).text, '11/7 店長に確認した記録（30分のまま）を見せた');

  const written = await editAndCheck({ op: 'insert', line: null, text: '- 休憩は50分' });
  assert.equal(written.check.materialRef.lineNo, 2);
  assert.deepEqual(texts((await showRecord(written.check.id, first.check.id)).json), before);

  await record('田中さんからご飯は硬めにすると言われた');
  assert.deepEqual(inputs.at(-1)!.manuals[0].materialConfirmations, [
    { materialId: rules.id, lineNo: 2, page: null, text: '2026-11-07 店長に確認：30分のまま（資料のとおり「- 休憩は30分」）' },
  ]);
});

test('記録を見せて済ませる：資料と違う内容に決まった確定を見せても、その行がもうノートにあれば足さず、行は2つにならない。無ければ元の位置に書く', async () => {
  // 「4時間」の記録と直接書いた行を、資料の「- ご飯は保温2時間まで」（4行目）と食い違ったことにする
  const toMaterial = (m: { id: string; title: string }) => ({
    kind: 'contradiction' as const,
    conflictLine: '- ご飯は保温2時間まで',
    sameLine: null,
    reason: '資料と違う',
    ask: { candidates: [{ who: '店長', why: '決める立場' }], question: 'どちらですか？' },
    materialRef: { materialId: m.id, title: m.title, page: null, lineNo: 4 },
  });
  const four = { op: 'insert' as const, line: '- 炊けたら10分蒸らす', text: '- ご飯は保温4時間まで', summary: 'ご飯' };
  await withDeps({
    assess: async (i) =>
      i.text.includes('4時間')
        ? { speaker: '佐藤さん', saidAt: null, items: [{ manual: 0, patch: four, check: toMaterial(i.manuals[0].materials[0]) }] }
        : fakeAssess(i),
    check: async (i) => (i.patch.text.includes('4時間') ? toMaterial(i.materials[0]) : fakeCheckPatch(i)),
  });
  await addRules();
  const rice = await record('田中さんからご飯は保温3時間までと言われた');
  assert.equal(rice.check.materialRef.lineNo, 4);
  await resolve(rice.check.id, '- ご飯は保温2時間半まで', '2時間半にする');
  const settled = texts((await call('GET', '/manuals/demo-kitchen')).json);
  assert.equal(settled.filter((t) => t === '- ご飯は保温2時間半まで').length, 1);

  // 書き込んでいない記録
  const said = await record('佐藤さんからご飯は保温4時間までと言われた');
  const shown = (await showRecord(said.check.id, rice.check.id)).json;
  assert.deepEqual(texts(shown), settled);
  const r = resolutionOf(shown, said.check.id);
  assert.deepEqual([r.text, r.note, r.patchId], ['- ご飯は保温2時間半まで', '2時間半にする', null]);
  assert.equal(shown.patches.find((p: any) => p.id === said.patch.id).status, 'discarded');

  // 直接書いた行は消す
  const written = await editAndCheck({ op: 'insert', line: null, text: '- ご飯は保温4時間まで' });
  assert.equal(written.check.materialRef.lineNo, 4);
  assert.deepEqual(texts((await showRecord(written.check.id, rice.check.id)).json), settled);

  // 決まった行を消したあとなら、確定した内容を元のパッチの位置に1行だけ書く
  await edit({ op: 'delete', line: '- ご飯は保温2時間半まで' });
  const again = await record('佐藤さんからご飯は保温4時間までと言われた');
  assert.deepEqual(texts((await showRecord(again.check.id, rice.check.id)).json), settled);
});

test('通知：自分のノートで、共有した相手が答えた・行を直したことを新しい順に返し、見た時刻より後を新しいとする', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  assert.deepEqual((await call('GET', '/notices')).json, { seenAt: null, items: [] });

  await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, { decidedAt: '2026-11-10', text: '- 塩 小さじ1/2', note: '1/2で統一' });
  await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす', today: '2026-11-10' });
  // 持ち主が自分で直した行は知らせない
  await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- 自分で足した行', today: '2026-11-10' });

  const { json } = await call('GET', '/notices');
  assert.equal(json.seenAt, null);
  assert.deepEqual(
    json.items.map(({ id, at, ...x }: any) => x),
    [
      { kind: 'edit', manualId: 'demo-kitchen', title: 'キッチンマニュアル（定食屋 みのり）', by: { id: 'sato', name: '佐藤店長' }, op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす' },
      { kind: 'answer', manualId: 'demo-kitchen', title: 'キッチンマニュアル（定食屋 みのり）', by: { id: 'sato', name: '佐藤店長' }, line: '- 塩 小さじ1', text: '- 塩 小さじ1/2', note: '1/2で統一' },
    ],
  );
  assert.ok(json.items[0].at >= json.items[1].at);

  // 共有された人には、共有されたノートでの出来事を知らせない（持ち主だけ）
  assert.deepEqual((await callAs('sato', 'GET', '/notices')).json.items, []);

  // 見たら、見た時刻を覚える。通知は残り、それより後のものだけが新しい
  assert.equal((await call('POST', '/notices/seen')).status, 204);
  const seen = (await call('GET', '/notices')).json;
  assert.equal(seen.items.length, 2);
  assert.ok(seen.items.every((x: any) => x.at <= seen.seenAt));
  // 時刻はミリ秒までなので、見た時刻と同じ時刻にならないよう少し待つ
  await new Promise((r) => setTimeout(r, 5));
  await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'delete', line: '- 炊けたら15分蒸らす', today: '2026-11-10' });
  const after = (await call('GET', '/notices')).json;
  assert.deepEqual([after.items[0].op, after.items[0].line, after.items[0].at > after.seenAt], ['delete', '- 炊けたら15分蒸らす', true]);
  // 見た時刻は人ごと
  assert.equal((await callAs('sato', 'GET', '/notices')).json.seenAt, null);
});
