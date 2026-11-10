import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { assessWithGemini, type AssessInput } from '../src/assess.ts';
import { checkWithGemini, type CheckInput, type ManualContext } from '../src/conflict/check.ts';
import { toGeminiSchema, type GenerateJson, type JsonRequest } from '../src/gemini.ts';

/*
 * 資料が0冊のノートでは、判定の指示文・プロンプト・スキーマに資料のことを入れない（ADR 0019）。資料を使わない人の判定を守るため。
 * fixtures/ は資料を載せる前のコードで書き出し、指示文を意図して変えたときだけ書き出し直す（見せる文の書き方を足したときに system だけ書き直した）
 */

const kitchen: AssessInput['manuals'][number] = {
  title: 'キッチン',
  lines: [
    { text: '## 味噌汁', note: null },
    { text: '- 塩 小さじ1/2', note: '田中さん（2026-11-03）から' },
    { text: '- 味噌は火を止めてから溶く', note: '店長（2026-11-05）に確認して確定／佐藤さん（2026-11-06）も同じ' },
    { text: '', note: null },
    { text: '## ご飯', note: null },
    { text: '- 大盛りは250gまで', note: null },
  ],
  confirmations: ['2026-11-05 店長に確認：250gのまま（「- 大盛りは250gまで」→「- 大盛りは250gまで」）'],
  materials: [],
  materialConfirmations: [],
};
const blank: AssessInput['manuals'][number] = { title: 'ホール', lines: [], confirmations: [], materials: [], materialConfirmations: [] };

const said = { text: '田中さんから塩は小さじ1でいいと言われた', today: '2026-11-10', speakers: ['田中さん', '店長'] };
const edit: Omit<CheckInput, keyof ManualContext> = {
  utterance: { text: '- 大盛りは300gまで', speaker: '自分', saidAt: '2026-11-10' },
  patch: { op: 'insert', line: null, text: '- 大盛りは300gまで', summary: '追記' },
};

/** generate に渡ったリクエストのうち、Gemini に送る中身 */
async function sent(run: (generate: GenerateJson) => Promise<unknown>, response: unknown) {
  const reqs: JsonRequest<unknown>[] = [];
  await run(async (req) => {
    reqs.push(req as JsonRequest<unknown>);
    return req.schema.parse(response);
  });
  const [req] = reqs;
  return { system: req.system, prompt: req.prompt, schema: toGeminiSchema(req.schema), hedgeMs: req.hedgeMs ?? null, thinkingLevel: req.thinkingLevel ?? null };
}

const fixture = (name: string) => JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), 'utf8'));
const noPatches = { speaker: null, saidAt: null, patches: [] };
const addition = { kind: 'addition', conflictLineNo: null, sameLineNo: null, reason: 'x', ask: null };

test('資料が0冊なら、記録（assess）に渡す指示文・プロンプト・スキーマは書き出したものと同じ：ノート1冊', async () => {
  assert.deepEqual(await sent((g) => assessWithGemini({ manuals: [kitchen], ...said }, g), noPatches), fixture('assess-one-note'));
});

test('資料が0冊なら、記録（assess）に渡す指示文・プロンプト・スキーマは書き出したものと同じ：白紙をまぜた2冊', async () => {
  assert.deepEqual(await sent((g) => assessWithGemini({ manuals: [kitchen, blank], ...said }, g), noPatches), fixture('assess-two-notes'));
});

test('資料が0冊なら、直接編集の確かめに渡す指示文・プロンプト・スキーマは書き出したものと同じ', async () => {
  assert.deepEqual(await sent((g) => checkWithGemini({ ...kitchen, ...edit }, g), addition), fixture('check'));
});

test('資料が0冊なら、白紙のノートの直接編集の確かめも書き出したものと同じ', async () => {
  assert.deepEqual(await sent((g) => checkWithGemini({ ...blank, ...edit }, g), addition), fixture('check-blank'));
});
