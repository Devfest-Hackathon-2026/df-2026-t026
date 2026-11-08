import assert from 'node:assert/strict';
import { test } from 'node:test';

import { checkWithGemini } from '../src/conflict/check.ts';
import { patchifyWithGemini } from '../src/foundation/patchify.ts';
import { toGeminiSchema, type GenerateJson, type JsonRequest } from '../src/gemini.ts';

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
