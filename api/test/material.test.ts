import assert from 'node:assert/strict';
import { test } from 'node:test';

import { noteRules } from '../src/format.ts';
import type { GenerateJson, JsonRequest } from '../src/gemini.ts';
import { materialLines, materialText, readMaterialWithGemini } from '../src/material.ts';

const pages = [
  { page: 1, text: '## 開店前\n- 冷蔵庫の温度を記録する' },
  { page: 2, text: '' },
  { page: 3, text: '- 味噌汁の塩は小さじ1' },
];

test('資料の行は、ページをまたいで通しで数える。文字の無いページは行を持たない', () => {
  assert.deepEqual(materialLines({ pages }), [
    { page: 1, text: '## 開店前' },
    { page: 1, text: '- 冷蔵庫の温度を記録する' },
    { page: 3, text: '- 味噌汁の塩は小さじ1' },
  ]);
});

test('プロンプトに載せる資料は、ページの印と通しの L 付きの行にする。ページの無い資料は印を出さない', () => {
  assert.equal(materialText({ pages }), '〔p.1〕\nL1: ## 開店前\nL2: - 冷蔵庫の温度を記録する\n〔p.2〕\n〔p.3〕\nL3: - 味噌汁の塩は小さじ1');
  assert.equal(materialText({ pages: [{ page: null, text: '- 手洗いは30秒\n  - 指の間も洗う' }] }), 'L1: - 手洗いは30秒\nL2:   - 指の間も洗う');
});

test('資料の読み取り：渡したページの数をちょうど返させ、ノートと同じ書き方で起こさせる。行末の空白と空行は落とす', async () => {
  const calls: JsonRequest<unknown>[] = [];
  const generate: GenerateJson = async (req) => {
    calls.push(req as JsonRequest<unknown>);
    return req.schema.parse({ title: ' 店舗マニュアル ', pages: ['## 開店前  \n\n  - 冷蔵庫  \n', ''] });
  };
  const files = [{ mimeType: 'application/pdf', data: 'JVBERg==' }];
  assert.deepEqual(await readMaterialWithGemini(files, 2, generate), { title: '店舗マニュアル', pages: ['## 開店前\n  - 冷蔵庫', ''] });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].files, files);
  assert.equal(calls[0].thinkingLevel, 'LOW');
  assert.ok(calls[0].system.includes(noteRules));
  assert.match(calls[0].system, /pages はちょうど 2 個/);
  // ページの数が違う応答は形が合わないので、呼び直しになる
  assert.throws(() => calls[0].schema.parse({ title: 't', pages: ['x'] }));
});
