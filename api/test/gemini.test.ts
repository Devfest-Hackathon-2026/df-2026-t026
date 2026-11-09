import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assessWithGemini } from '../src/assess.ts';
import { checkWithGemini } from '../src/conflict/check.ts';
import { formatWithGemini, readNoteWithGemini } from '../src/format.ts';
import { transcribeWithGemini } from '../src/intake.ts';
import { GoogleGenAI } from '@google/genai';

import { httpOptions, isItem, toGeminiSchema, type GenerateJson, type JsonRequest } from '../src/gemini.ts';

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

const ask = { candidates: [{ who: '店長', why: '決める立場' }], question: 'どちらに合わせればよいですか？' };

/** まとめた呼び出しの応答のパッチ1件。指定しない項目は「追記」 */
const item = (o: Record<string, unknown>) => ({
  manualNo: 1, op: 'insert', lineNo: null, text: '- x', summary: 'x',
  kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null, ...o,
});

function assessWith(patches: unknown[]) {
  const s = stub({ speaker: '田中さん', saidAt: '2026-11-03', patches });
  const run = () =>
    assessWithGemini(
      { manuals: [{ title: 'キッチン', lines: lines.map((text) => ({ text, note: null })), confirmations: [] }], text: '田中さんから…', today: '2026-11-03', speakers: [] },
      s.generate,
    );
  return { run, calls: s.calls };
}

test('差分化と分類を1回で受け取り、行番号を行の文字列に直す', async () => {
  const { run, calls } = assessWith([
    item({ op: 'replace', lineNo: 2, text: '- 塩 小さじ1/2', kind: 'contradiction', conflictLineNo: 2, ask }),
    item({ op: 'insert', lineNo: 5, text: '- おかわりは1回まで' }),
    item({ op: 'insert', lineNo: null, text: '- 閉店後に床を掃く' }),
  ]);
  const r = await run();
  assert.equal(calls.length, 1);
  assert.deepEqual(
    r.items.map((x) => [x.patch.op, x.patch.line, x.check.kind, x.check.conflictLine]),
    [
      ['replace', '- 塩 小さじ1', 'contradiction', '- 塩 小さじ1'],
      ['insert', '- 大盛りは250gまで', 'addition', null],
      ['insert', null, 'addition', null],
    ],
  );
  assert.deepEqual(r.items[0].check.ask, ask);
  // マニュアル全文を行番号付きで渡している
  assert.match(calls[0].prompt, /L2: - 塩 小さじ1\n/);
});

test('差分化：見出しや範囲外の行を置き換えようとしたら受け付けない', async () => {
  for (const lineNo of [1, 3, 6]) {
    await assert.rejects(assessWith([item({ op: 'replace', lineNo })]).run());
  }
});

test('マークダウンの見出し（# 〜 ######）と区切り線は、書き換えや衝突の相手にしない', () => {
  for (const l of ['# 店', '## 味噌汁', '### 仕込み', '---', '* * *']) assert.equal(isItem(l), false, l);
  for (const l of ['- 塩 小さじ1', '#3番テーブルは予約席', '1. 手を洗う', '**塩** 小さじ1']) assert.equal(isItem(l), true, l);
});

test('分類：矛盾でなければ衝突相手と確認先は返さない', async () => {
  const r = await assessWith([item({ kind: 'qualification', conflictLineNo: 2, ask })]).run();
  assert.equal(r.items[0].check.conflictLine, null);
  assert.equal(r.items[0].check.ask, null);
});

test('分類：矛盾なのに確認先や衝突相手がなければ受け付けない', async () => {
  for (const bad of [
    { kind: 'contradiction', conflictLineNo: 2, ask: null },
    { kind: 'contradiction', conflictLineNo: null, ask },
    { kind: 'contradiction', conflictLineNo: 4, ask },
  ]) {
    await assert.rejects(assessWith([item(bad)]).run());
  }
});

test('分類：同じ内容なら、その行を文字列で返す', async () => {
  const r = await assessWith([item({ kind: 'same', sameLineNo: 2 })]).run();
  assert.equal(r.items[0].check.sameLine, '- 塩 小さじ1');
  assert.equal(r.items[0].check.conflictLine, null);
});

test('分類：同じ内容なのに、項目の行番号がなければ受け付けない', async () => {
  for (const sameLineNo of [null, 1, 3]) {
    await assert.rejects(assessWith([item({ kind: 'same', sameLineNo })]).run());
  }
});

test('Gemini に渡すスキーマに、使えないキーワードを含めない', async () => {
  const { run, calls } = assessWith([]);
  await run();
  const json = JSON.stringify(toGeminiSchema(calls[0].schema));
  assert.doesNotMatch(json, /"\$schema"|"pattern"/);
});

test('振り分け：パッチごとのマニュアル番号を添字に直し、行番号はそのマニュアルの行で確かめる', async () => {
  const hall = ['## 会計', '- レジは現金とカードのみ'];
  const manuals = [
    { title: 'キッチン', lines: lines.map((text) => ({ text, note: null })), confirmations: [] },
    { title: 'ホール', lines: hall.map((text) => ({ text, note: null })), confirmations: [] },
  ];
  const run = (patches: unknown[]) => {
    const s = stub({ speaker: null, saidAt: null, patches });
    return { calls: s.calls, done: assessWithGemini({ manuals, text: 'x', today: '2026-11-03', speakers: [] }, s.generate) };
  };
  const ok = run([item({ manualNo: 2, op: 'replace', lineNo: 2, text: '- レジは現金のみ' }), item({ manualNo: 1, op: 'replace', lineNo: 2 })]);
  const r = await ok.done;
  assert.deepEqual(r.items.map((x) => [x.manual, x.patch.line]), [[1, '- レジは現金とカードのみ'], [0, '- 塩 小さじ1']]);
  // 全マニュアルの全文を載せている
  assert.match(ok.calls[0].prompt, /# マニュアル2: ホール\nL1: ## 会計\nL2: - レジは現金とカードのみ/);
  // ホールに5行目はない
  await assert.rejects(run([item({ manualNo: 2, op: 'replace', lineNo: 5 })]).done);
  await assert.rejects(run([item({ manualNo: 3 })]).done);
});

test('白紙のノート：題名だけで振り分けさせ、末尾への追記だけを受け付ける', async () => {
  const blank = { title: '自分用メモ', lines: [], confirmations: [] };
  const ok = stub({ speaker: null, saidAt: null, patches: [item({ text: '- 塩 小さじ1' })] });
  const r = await assessWithGemini({ manuals: [blank], text: '塩は小さじ1', today: '2026-11-03', speakers: [] }, ok.generate);
  assert.deepEqual(r.items.map((x) => [x.manual, x.patch.op, x.patch.line]), [[0, 'insert', null]]);
  assert.match(ok.calls[0].prompt, /# マニュアル1: 自分用メモ\n（白紙。まだ何も書かれていません）/);
  // 最小1・最大0のような、満たせない範囲を Gemini に渡さない
  assert.doesNotMatch(JSON.stringify(toGeminiSchema(ok.calls[0].schema)), /"maximum":0/);
  const bad = stub({ speaker: null, saidAt: null, patches: [item({ lineNo: 1 })] });
  await assert.rejects(assessWithGemini({ manuals: [blank], text: 'x', today: '2026-11-03', speakers: [] }, bad.generate));
});

test('直接編集の分類：白紙のノートでも、満たせない行番号の範囲を渡さずに判定する', async () => {
  const { generate, calls } = stub({ kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null });
  const r = await checkWithGemini(
    {
      lines: [],
      confirmations: [],
      utterance: { text: '- 塩 小さじ1', speaker: '自分', saidAt: '2026-11-08' },
      patch: { op: 'insert', line: null, text: '- 塩 小さじ1', summary: '追記' },
    },
    generate,
  );
  assert.equal(r.kind, 'addition');
  assert.match(calls[0].prompt, /白紙/);
  assert.doesNotMatch(JSON.stringify(toGeminiSchema(calls[0].schema)), /"maximum":0/);
});

test('直接編集の分類：矛盾なら衝突相手の行を文字列で返す', async () => {
  const { generate } = stub({ kind: 'contradiction', conflictLineNo: 2, sameLineNo: null, reason: '量が違う', ask });
  const r = await checkWithGemini(
    {
      lines: lines.map((text) => ({ text, note: null })),
      confirmations: [],
      utterance: { text: '- 塩 小さじ2', speaker: '自分', saidAt: '2026-11-08' },
      patch: { op: 'insert', line: null, text: '- 塩 小さじ2', summary: '追記' },
    },
    generate,
  );
  assert.deepEqual([r.kind, r.conflictLine], ['contradiction', '- 塩 小さじ1']);
});

test('書き起こし：ファイルを添えて呼ぶ', async () => {
  const { generate, calls } = stub({ text: ' 田中さんから塩は小さじ1/2 ' });
  const files = [{ mimeType: 'image/png', data: 'AAAA' }];
  assert.equal(await transcribeWithGemini(files, generate), '田中さんから塩は小さじ1/2');
  assert.deepEqual(calls[0].files, files);
});

test('整形：本文を渡し、行末の空白だけを落として行頭の入れ子は残す', async () => {
  const { generate, calls } = stub({ text: '## 仕込み  \n- 野菜を切る\n  - 玉ねぎは薄切り \n' });
  assert.equal(await formatWithGemini('仕込み 野菜を切る 玉ねぎは薄切り', generate), '## 仕込み\n- 野菜を切る\n  - 玉ねぎは薄切り');
  assert.equal(calls.length, 1);
  assert.match(calls[0].prompt, /仕込み 野菜を切る 玉ねぎは薄切り/);
});

test('読み取り：ファイルを渡し、本文と題名の前後の空白を落とす', async () => {
  const files = [{ mimeType: 'application/pdf', data: 'JVBERg==' }];
  const { generate, calls } = stub({ title: ' キッチンマニュアル ', text: '仕込み  \n  野菜を切る\n' });
  assert.deepEqual(await readNoteWithGemini(files, generate), { title: 'キッチンマニュアル', text: '仕込み\n  野菜を切る' });
  assert.equal(calls.length, 1);
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
