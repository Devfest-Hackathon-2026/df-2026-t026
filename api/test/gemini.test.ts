import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assessWithGemini } from '../src/assess.ts';
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

const ask = { candidates: [{ who: '店長', why: '決める立場' }], question: 'どちらに合わせればよいですか？' };

/** まとめた呼び出しの応答のパッチ1件。指定しない項目は「追記」 */
const item = (o: Record<string, unknown>) => ({
  op: 'insert', lineNo: null, text: '- x', summary: 'x',
  kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null, ...o,
});

function assessWith(patches: unknown[]) {
  const s = stub({ speaker: '田中さん', saidAt: '2026-11-03', patches });
  const run = () =>
    assessWithGemini(
      { lines: lines.map((text) => ({ text, note: null })), confirmations: [], text: '田中さんから…', today: '2026-11-03', speakers: [] },
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
