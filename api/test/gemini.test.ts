import assert from 'node:assert/strict';
import { test } from 'node:test';

import { checkWithGemini } from '../src/conflict/check.ts';
import { patchifyWithGemini } from '../src/foundation/patchify.ts';
import { routeWithGemini, transcribeWithGemini } from '../src/intake.ts';
import { GoogleGenAI } from '@google/genai';

import { httpOptions, toGeminiSchema, type GenerateJson, type JsonRequest } from '../src/gemini.ts';

const lines = ['## 味噌汁', '- 塩 小さじ1', '', '## ご飯', '- 大盛りは250gまで'];

/** Gemini の代わりに決まった応答を返し、渡されたリクエストを記録する */
function stub(response: unknown) {
  const calls: JsonRequest<unknown>[] = [];
  const generate: GenerateJson = async (req) => {
    calls.push(req as JsonRequest<unknown>);
    return req.schema.parse(response);
  };
  return { generate, calls };
}

test('差分化：行番号を行の文字列に直す', async () => {
  const { generate, calls } = stub({
    speaker: '田中さん',
    saidAt: '2026-11-03',
    patches: [
      { op: 'replace', lineNo: 2, text: '- 塩 小さじ1/2', summary: '塩: 小さじ1 → 小さじ1/2' },
      { op: 'insert', lineNo: 5, text: '- おかわりは1回まで', summary: 'おかわり' },
      { op: 'insert', lineNo: null, text: '- 閉店後に床を掃く', summary: '掃除' },
    ],
  });
  const r = await patchifyWithGemini({ lines, text: '田中さんから…', today: '2026-11-03', speakers: [] }, generate);
  assert.deepEqual(
    r.patches.map((p) => [p.op, p.line]),
    [['replace', '- 塩 小さじ1'], ['insert', '- 大盛りは250gまで'], ['insert', null]],
  );
  // マニュアル全文を行番号付きで渡している
  assert.match(calls[0].prompt, /L2: - 塩 小さじ1\n/);
});

test('差分化：白紙のマニュアルには行番号を指させず、末尾への追記だけにする', async () => {
  const { generate, calls } = stub({
    speaker: null,
    saidAt: null,
    patches: [{ op: 'insert', lineNo: null, text: '- 塩 小さじ1', summary: '塩' }],
  });
  const r = await patchifyWithGemini({ lines: [], text: '塩は小さじ1', today: '2026-11-03', speakers: [] }, generate);
  assert.deepEqual(r.patches.map((p) => [p.op, p.line]), [['insert', null]]);
  assert.match(calls[0].prompt, /白紙/);
  // 最小1・最大0のような、満たせない範囲を Gemini に渡さない
  assert.doesNotMatch(JSON.stringify(toGeminiSchema(calls[0].schema)), /"maximum":0/);
  const lineNo1 = stub({ speaker: null, saidAt: null, patches: [{ op: 'insert', lineNo: 1, text: 'x', summary: 'x' }] });
  await assert.rejects(patchifyWithGemini({ lines: [], text: 'x', today: '2026-11-03', speakers: [] }, lineNo1.generate));
});

test('差分化：見出しや範囲外の行を置き換えようとしたら受け付けない', async () => {
  for (const lineNo of [1, 3, 6]) {
    const { generate } = stub({ speaker: null, saidAt: null, patches: [{ op: 'replace', lineNo, text: 'x', summary: 'x' }] });
    await assert.rejects(patchifyWithGemini({ lines, text: 'x', today: '2026-11-03', speakers: [] }, generate));
  }
});

const input = {
  lines: lines.map((text) => ({ text, note: null })),
  confirmations: [],
  utterance: { text: '田中さんから塩は小さじ1/2', speaker: '田中さん', saidAt: '2026-11-03' },
  patch: { op: 'replace' as const, line: '- 塩 小さじ1', text: '- 塩 小さじ1/2', summary: '' },
};
const ask = { candidates: [{ who: '店長', why: '決める立場' }], question: 'どちらに合わせればよいですか？' };

test('分類：矛盾なら衝突相手の行を文字列で返す', async () => {
  const { generate } = stub({ kind: 'contradiction', conflictLineNo: 2, sameLineNo: null, reason: '量が違う', ask });
  const r = await checkWithGemini(input, generate);
  assert.equal(r.conflictLine, '- 塩 小さじ1');
  assert.deepEqual(r.ask, ask);
});

test('分類：矛盾でなければ衝突相手と確認先は返さない', async () => {
  const { generate } = stub({ kind: 'qualification', conflictLineNo: 2, sameLineNo: null, reason: '条件付き', ask });
  const r = await checkWithGemini(input, generate);
  assert.equal(r.conflictLine, null);
  assert.equal(r.ask, null);
});

test('分類：矛盾なのに確認先や衝突相手がなければ受け付けない', async () => {
  for (const bad of [
    { kind: 'contradiction', conflictLineNo: 2, sameLineNo: null, reason: 'x', ask: null },
    { kind: 'contradiction', conflictLineNo: null, sameLineNo: null, reason: 'x', ask },
    { kind: 'contradiction', conflictLineNo: 4, sameLineNo: null, reason: 'x', ask },
  ]) {
    await assert.rejects(checkWithGemini(input, stub(bad).generate));
  }
});

test('分類：同じ内容なら、その行を文字列で返す', async () => {
  const { generate } = stub({ kind: 'same', conflictLineNo: null, sameLineNo: 2, reason: '言い方違い', ask: null });
  const r = await checkWithGemini(input, generate);
  assert.equal(r.sameLine, '- 塩 小さじ1');
  assert.equal(r.conflictLine, null);
  assert.equal(r.ask, null);
});

test('分類：同じ内容なのに、項目の行番号がなければ受け付けない', async () => {
  for (const sameLineNo of [null, 1, 3]) {
    await assert.rejects(checkWithGemini(input, stub({ kind: 'same', conflictLineNo: null, sameLineNo, reason: 'x', ask: null }).generate));
  }
});

test('Gemini に渡すスキーマに、使えないキーワードを含めない', async () => {
  const p = stub({ speaker: null, saidAt: null, patches: [] });
  await patchifyWithGemini({ lines, text: 'x', today: '2026-11-03', speakers: [] }, p.generate);
  const c = stub({ kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null });
  await checkWithGemini(input, c.generate);
  for (const req of [p.calls[0], c.calls[0]]) {
    const json = JSON.stringify(toGeminiSchema(req.schema));
    assert.doesNotMatch(json, /"\$schema"|"pattern"/);
  }
});

test('分類：白紙のマニュアルでも、満たせない行番号の範囲を渡さずに判定する', async () => {
  const { generate, calls } = stub({ kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null });
  const r = await checkWithGemini({ ...input, lines: [], patch: { op: 'insert', line: null, text: '- 塩 小さじ1', summary: '' } }, generate);
  assert.equal(r.kind, 'addition');
  assert.match(calls[0].prompt, /白紙/);
  assert.doesNotMatch(JSON.stringify(toGeminiSchema(calls[0].schema)), /"maximum":0/);
});

test('振り分け：番号をマニュアルの添字に直し、重複を除く', async () => {
  const { generate, calls } = stub({ manualNos: [2, 1, 2] });
  const manuals = [
    { title: 'キッチン', lines },
    { title: 'ホール', lines: ['## 会計', '- レジは現金とカードのみ'] },
  ];
  assert.deepEqual(await routeWithGemini({ manuals, text: 'レジ締めは店長' }, generate), [0, 1]);
  // 全マニュアルの全文を載せている
  assert.match(calls[0].prompt, /# マニュアル2: ホール\n## 会計\n- レジは現金とカードのみ/);
  await assert.rejects(routeWithGemini({ manuals, text: 'x' }, stub({ manualNos: [3] }).generate));
});

test('振り分け：白紙のマニュアルは白紙と書いて題名で選ばせる', async () => {
  const { generate, calls } = stub({ manualNos: [1] });
  assert.deepEqual(await routeWithGemini({ manuals: [{ title: '自分用メモ', lines: [] }], text: '塩は小さじ1' }, generate), [0]);
  assert.match(calls[0].prompt, /# マニュアル1: 自分用メモ\n（白紙）/);
});

test('書き起こし：ファイルを添えて呼ぶ', async () => {
  const { generate, calls } = stub({ text: ' 田中さんから塩は小さじ1/2 ' });
  const files = [{ mimeType: 'image/png', data: 'AAAA' }];
  assert.equal(await transcribeWithGemini(files, generate), '田中さんから塩は小さじ1/2');
  assert.deepEqual(calls[0].files, files);
});

/** 決まった順にステータスを返す fetch。呼ばれた回数を数える */
function fakeFetch(statuses: number[]) {
  let calls = 0;
  const fetch = async () => {
    const status = statuses[Math.min(calls++, statuses.length - 1)];
    const body = status === 200 ? { candidates: [{ content: { parts: [{ text: 'ok' }] } }] } : { error: { code: status, message: 'x' } };
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  };
  return { fetch, calls: () => calls };
}

async function callWith(statuses: number[]) {
  const f = fakeFetch(statuses);
  // 待ち時間だけ短くして、やり直す回数と対象のステータスは本番と同じ設定で確かめる
  const ai = new GoogleGenAI({
    vertexai: true,
    apiKey: 'test',
    httpOptions: { ...httpOptions, retryOptions: { ...httpOptions.retryOptions, initialDelay: 0.01, maxDelay: 0.01 }, fetch: f.fetch },
  });
  const res = await ai.models.generateContent({ model: 'm', contents: 'x' }).then((r) => r.text, (e) => e);
  return { res, calls: f.calls() };
}

test('呼び出し：混雑（503）やレート制限（429）は待ってやり直す', async () => {
  assert.deepEqual(await callWith([503, 200]), { res: 'ok', calls: 2 });
  assert.deepEqual(await callWith([429, 429, 200]), { res: 'ok', calls: 3 });
});

test('呼び出し：やり直しは決めた回数まで。リクエストの誤り（400）はやり直さない', async () => {
  const busy = await callWith([503]);
  assert.equal(busy.calls, 3);
  assert.equal(busy.res.status, 503);
  const bad = await callWith([400, 200]);
  assert.equal(bad.calls, 1);
  assert.equal(bad.res.status, 400);
});

test('呼び出し：応答が上限時間を過ぎたら打ち切り、やり直す', async () => {
  let calls = 0;
  const fetch = (_url: unknown, init?: RequestInit) => {
    calls++;
    if (calls > 1) return Promise.resolve(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'ok' }] } }] })));
    // 1回目は返事をせず、打ち切られるのを待つ
    return new Promise<Response>((_, reject) => init?.signal?.addEventListener('abort', () => reject(init.signal!.reason)));
  };
  const ai = new GoogleGenAI({
    vertexai: true,
    apiKey: 'test',
    httpOptions: { ...httpOptions, timeout: 20, retryOptions: { ...httpOptions.retryOptions, initialDelay: 0.01, maxDelay: 0.01 }, fetch },
  });
  const r = await ai.models.generateContent({ model: 'm', contents: 'x' });
  assert.equal(r.text, 'ok');
  assert.equal(calls, 2);
});
