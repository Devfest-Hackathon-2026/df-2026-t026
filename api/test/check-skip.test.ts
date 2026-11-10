import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import { sessionIdOf } from '../src/auth.ts';
import type { CheckInput, CheckPatch } from '../src/conflict/check.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

// 直接書いた行の確かめで、Gemini を呼ばなくても結果が決まる編集では呼ばない（設計書 0021 §4.4、ADR 0007）

let app: ReturnType<typeof createApp>;
/** 確かめ（Gemini）に渡した入力。呼んだ回数を数える */
let inputs: CheckInput[];
/** 確かめの答え。既定は fakeCheckPatch */
let respond: CheckPatch;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });
  inputs = [];
  respond = fakeCheckPatch;
  app = createApp({
    store,
    assess: fakeAssess,
    check: (i) => (inputs.push(i), respond(i)),
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

/** 本文を持つノートを作り、その ID を返す。本文を省けば白紙 */
async function newNote(body = '') {
  const { status, json } = await call('POST', '/manuals', { title: 'メモ', body });
  assert.equal(status, 201);
  return json.manual.id as string;
}

/** 行を直接書いて、その差分を返す */
async function edit(manualId: string, body: object) {
  const edited = await call('POST', `/manuals/${manualId}/edits`, { today: '2026-11-10', ...body });
  assert.equal(edited.status, 201);
  return edited.json.patches.at(-1);
}

/** 確かめる。確かめの応答と、その差分の確認（無ければ undefined）を返す */
async function checkOf(manualId: string, patch: any) {
  const checked = await call('POST', `/manuals/${manualId}/patches/${patch.id}/check`);
  return { patch, status: checked.status, state: checked.json, check: checked.json.checks?.find((c: any) => c.patchId === patch.id) };
}

/** 行を直接書いて、すぐ確かめる */
const write = async (manualId: string, body: object) => checkOf(manualId, await edit(manualId, body));

test('白紙のノートの最初の行は確かめず、確認を残さずに今の状態を返す。2行目からは確かめる', async () => {
  const id = await newNote();
  const first = await write(id, { op: 'insert', line: null, text: '- 塩 小さじ1' });
  assert.equal(inputs.length, 0);
  assert.equal(first.status, 200);
  assert.equal(first.check, undefined);
  assert.deepEqual({ ...(await call('GET', `/manuals/${id}`)).json, asOf: first.state.asOf }, first.state);

  // 同じ差分にもう一度呼んでも、確かめずに今の状態を返す
  const again = await call('POST', `/manuals/${id}/patches/${first.patch.id}/check`);
  assert.equal(again.status, 200);
  assert.equal(inputs.length, 0);
  assert.ok(!again.json.checks.some((c: any) => c.patchId === first.patch.id));

  const second = await write(id, { op: 'insert', line: null, text: '- 塩 小さじ2' });
  assert.equal(inputs.length, 1);
  assert.deepEqual([second.check.kind, second.check.conflictLine], ['contradiction', '- 塩 小さじ1']);
});

test('見出し・区切り線・空行だけのノートへの行は確かめない', async () => {
  const id = await newNote('## 味噌汁\n\n---');
  const { status, check } = await write(id, { op: 'insert', line: '## 味噌汁', text: '- 塩 小さじ1' });
  assert.equal(status, 200);
  assert.equal(check, undefined);
  assert.equal(inputs.length, 0);
});

test('資料が1冊でもあれば、白紙のノートでも確かめる', async () => {
  const id = await newNote();
  const added = await call('POST', `/manuals/${id}/materials`, { title: '店舗マニュアル', text: '- 休憩は30分' });
  assert.equal(added.status, 201);
  const { check } = await write(id, { op: 'insert', line: null, text: '- 休憩は15分' });
  assert.equal(inputs.length, 1);
  assert.deepEqual([check.kind, check.conflictLine], ['contradiction', '- 休憩は30分']);
});

test('確定済みの記録があれば、項目の行が無いノートでも確かめる', async () => {
  const id = await newNote();
  await write(id, { op: 'insert', line: null, text: '- 塩 小さじ1' });
  const { check } = await write(id, { op: 'insert', line: null, text: '- 塩 小さじ2' });
  const resolved = await call('POST', `/manuals/${id}/checks/${check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ2' });
  assert.equal(resolved.status, 200);
  const deleted = await call('POST', `/manuals/${id}/edits`, { op: 'delete', line: '- 塩 小さじ2' });
  assert.deepEqual(deleted.json.lines, []);

  await write(id, { op: 'insert', line: null, text: '- 塩は入れない' });
  assert.equal(inputs.length, 2);
  assert.deepEqual(inputs[1].lines, []);
  assert.equal(inputs[1].confirmations.length, 1);
});

test('確かめた直接編集の行は、印や前後の空白だけを変えた書き換えなら確かめず、文が変わる書き換えは確かめる', async () => {
  for (const text of ['- 粗塩でもよい', '- 鍋は弱火にかける', '  - 器は温めておく']) {
    await write('demo-kitchen', { op: 'insert', line: null, text });
  }
  assert.equal(inputs.length, 3);
  const marked = await write('demo-kitchen', { op: 'replace', line: '- 粗塩でもよい', text: '* 粗塩でもよい' });
  assert.equal(marked.status, 200);
  assert.equal(marked.check, undefined);
  await write('demo-kitchen', { op: 'replace', line: '- 鍋は弱火にかける', text: '1. 鍋は弱火にかける' });
  // 行頭の空白を減らす
  await write('demo-kitchen', { op: 'replace', line: '  - 器は温めておく', text: '- 器は温めておく' });
  assert.equal(inputs.length, 3);

  await write('demo-kitchen', { op: 'insert', line: null, text: '- 醤油は薄口' });
  const changed = await write('demo-kitchen', { op: 'replace', line: '- 醤油は薄口', text: '- 醤油は濃口' });
  assert.equal(inputs.length, 5);
  assert.ok(changed.check);
});

test('作ったときの本文の行や、口頭の記録で入った行は、まだ直接編集として確かめていないので、印だけ変えても確かめる', async () => {
  await write('demo-kitchen', { op: 'replace', line: '- 塩 小さじ1', text: '* 塩 小さじ1' });
  assert.equal(inputs.length, 1);

  const recorded = await call('POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから、だしは煮干しと言われた', today: '2026-11-10' });
  assert.equal(recorded.status, 201);
  const p = recorded.json.state.patches.find((x: any) => x.utteranceId === recorded.json.utteranceId);
  assert.ok(recorded.json.state.checks.some((x: any) => x.patchId === p.id));
  assert.equal((await call('POST', `/manuals/demo-kitchen/patches/${p.id}/apply`, {})).status, 200);
  assert.equal(p.text, '- だしは煮干し');
  await write('demo-kitchen', { op: 'replace', line: '- だしは煮干し', text: '* だしは煮干し' });
  assert.equal(inputs.length, 2);
});

test('確かめる前に閉じた編集や、確かめが失敗した編集の行は、印だけ変えても確かめる', async () => {
  // 確かめを呼ばなかった（確かめる前にタブを閉じた）
  await edit('demo-kitchen', { op: 'insert', line: null, text: '- 粗塩でもよい' });
  await write('demo-kitchen', { op: 'replace', line: '- 粗塩でもよい', text: '* 粗塩でもよい' });
  assert.equal(inputs.length, 1);

  // 確かめが失敗した
  respond = async () => {
    throw new Error('混んでいます');
  };
  const failed = await write('demo-kitchen', { op: 'insert', line: null, text: '- 鍋は弱火にかける' });
  assert.equal(failed.status, 500);
  respond = fakeCheckPatch;
  const { check } = await write('demo-kitchen', { op: 'replace', line: '- 鍋は弱火にかける', text: '* 鍋は弱火にかける' });
  assert.equal(inputs.length, 3);
  assert.ok(check);
});

test('見出しを同じ文の項目にした書き換えは、新しい主張なので、前の見出しを確かめてあっても確かめる', async () => {
  await write('demo-kitchen', { op: 'insert', line: null, text: '## 汁物' });
  assert.equal(inputs.length, 1);
  const { check } = await write('demo-kitchen', { op: 'replace', line: '## 汁物', text: '- 汁物' });
  assert.equal(inputs.length, 2);
  assert.ok(check);
});

test('まだ確認していない食い違いが付いた行は、印だけ変えても確かめる', async () => {
  // 書いた行のほうに食い違いが付いている
  const { check } = await write('demo-kitchen', { op: 'insert', line: null, text: '- 塩 小さじ2' });
  assert.equal(check.kind, 'contradiction');
  await write('demo-kitchen', { op: 'replace', line: '- 塩 小さじ2', text: '* 塩 小さじ2' });
  assert.equal(inputs.length, 2);

  // 食い違いの相手になっている行（確かめた直接編集の行）
  await write('demo-kitchen', { op: 'insert', line: null, text: '- 醤油 大さじ1' });
  const rival = await write('demo-kitchen', { op: 'insert', line: null, text: '- 醤油 大さじ2' });
  assert.deepEqual([rival.check.kind, rival.check.conflictLine], ['contradiction', '- 醤油 大さじ1']);
  await write('demo-kitchen', { op: 'replace', line: '- 醤油 大さじ1', text: '* 醤油 大さじ1' });
  assert.equal(inputs.length, 5);
});

test('前の行の確かめが書き換えの後に走って同じ内容になったときは、印だけ変えても確かめる', async () => {
  // 続けて書くと、前の編集の確かめが、印を変えた後のノートで走ることがある。そのときは書き換えた後の行を同じ内容と指す
  const first = await edit('demo-kitchen', { op: 'insert', line: null, text: '- だしは煮干し' });
  const remarked = await edit('demo-kitchen', { op: 'replace', line: '- だしは煮干し', text: '* だしは煮干し' });
  respond = async () => ({ kind: 'same', conflictLine: null, sameLine: '* だしは煮干し', reason: '同じ内容です', ask: null, materialRef: null });
  assert.equal((await checkOf('demo-kitchen', first)).check.kind, 'same');
  respond = fakeCheckPatch;
  const { check } = await checkOf('demo-kitchen', remarked);
  assert.equal(inputs.length, 2);
  assert.ok(check);
});

test('確定済みの行を書き換えたときは、書き換える前の行が相手になるので確かめる', async () => {
  const id = await newNote();
  const material = await call('POST', `/manuals/${id}/materials`, { title: '店舗マニュアル', text: '- 休憩は30分' });
  const { check } = await write(id, { op: 'insert', line: null, text: '- 休憩は15分' });
  assert.equal(check.materialRef.materialId, material.json.id);
  const resolved = await call('POST', `/manuals/${id}/checks/${check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 休憩は15分' });
  assert.equal(resolved.status, 200);
  // 資料を消すと、資料と資料に結び付いた確定は判定に載らない。残る相手は書き換える前の行だけ（#86）
  assert.equal((await call('DELETE', `/manuals/${id}/materials/${material.json.id}`)).status, 204);

  await write(id, { op: 'replace', line: '- 休憩は15分', text: '- 休憩は20分' });
  assert.equal(inputs.length, 2);
  assert.deepEqual(inputs[1].lines.map((l) => l.text), ['- 休憩は15分']);
  assert.deepEqual([inputs[1].confirmations, inputs[1].materials, inputs[1].materialConfirmations], [[], [], []]);
});
