import assert from 'node:assert/strict';
import { mock, test } from 'node:test';

import { assessWithGemini } from '../src/assess.ts';
import { checkWithGemini, manualContext, materialContext, type Check } from '../src/conflict/check.ts';
import { formatWithGemini, readNoteWithGemini } from '../src/format.ts';
import { transcribeWithGemini } from '../src/intake.ts';
import type { Material } from '../src/material.ts';
import { GoogleGenAI } from '@google/genai';
import { z } from 'zod';

import { httpOptions, isItem, requestJson, requestWithCache, toGeminiSchema, type GenerateJson, type JsonRequest, type Usage } from '../src/gemini.ts';

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
      { manuals: [{ title: 'キッチン', lines: lines.map((text) => ({ text, note: null })), confirmations: [], materials: [], materialConfirmations: [] }], text: '田中さんから…', today: '2026-11-03', speakers: [] },
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
  assert.equal(calls[0].hedgeMs, 12_000);
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
    { title: 'キッチン', lines: lines.map((text) => ({ text, note: null })), confirmations: [], materials: [], materialConfirmations: [] },
    { title: 'ホール', lines: hall.map((text) => ({ text, note: null })), confirmations: [], materials: [], materialConfirmations: [] },
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
  const blank = { title: '自分用メモ', lines: [], confirmations: [], materials: [], materialConfirmations: [] };
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
      materials: [],
      materialConfirmations: [],
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
  const { generate, calls } = stub({ kind: 'contradiction', conflictLineNo: 2, sameLineNo: null, reason: '量が違う', ask });
  const r = await checkWithGemini(
    {
      lines: lines.map((text) => ({ text, note: null })),
      confirmations: [],
      materials: [],
      materialConfirmations: [],
      utterance: { text: '- 塩 小さじ2', speaker: '自分', saidAt: '2026-11-08' },
      patch: { op: 'insert', line: null, text: '- 塩 小さじ2', summary: '追記' },
    },
    generate,
  );
  assert.deepEqual([r.kind, r.conflictLine], ['contradiction', '- 塩 小さじ1']);
  assert.equal(calls[0].hedgeMs, 8_000);
});

/** 資料（ADR 0019）。M1 は2ページ、M2 はページの無い貼り付けた文 */
const store = {
  id: 'mat-store',
  title: '店舗マニュアル',
  lines: [
    { page: 1, text: '## 開店前' },
    { page: 1, text: '- 冷蔵庫の温度を記録する' },
    { page: 2, text: '- 味噌汁の塩は小さじ1' },
  ],
};
const hygiene = { id: 'mat-hygiene', title: '衛生の手引き', lines: [{ page: null, text: '- 手洗いは30秒' }] };
const saltConfirmed = {
  materialId: 'mat-store',
  lineNo: 3,
  page: 2,
  text: '2026-11-07 店長に確認：1/2で統一（資料「- 味噌汁の塩は小さじ1」→「- 味噌汁の塩は小さじ1/2」）',
};
const withMaterials = {
  title: 'キッチン',
  lines: lines.map((text) => ({ text, note: null })),
  confirmations: ['2026-11-05 店長に確認：250gのまま（「- 大盛りは250gまで」→「- 大盛りは250gまで」）'],
  materials: [store, hygiene],
  materialConfirmations: [saltConfirmed],
};
const hall = { title: 'ホール', lines: [{ text: '- レジは現金のみ', note: null }], confirmations: [], materials: [hygiene], materialConfirmations: [] };

function assessWithMaterials(patches: unknown[]) {
  const s = stub({ speaker: null, saidAt: null, patches });
  const run = () => assessWithGemini({ manuals: [withMaterials, hall], text: 'x', today: '2026-11-10', speakers: [] }, s.generate);
  return { run, calls: s.calls };
}

test('資料：プロンプトは「# 資料」から始まり、ページの印と L 付きの行をノートより前に置く。資料に結び付いた確定は確定済みの記録の最後に出る', async () => {
  const { run, calls } = assessWithMaterials([]);
  await run();
  const [{ system, prefix, prompt: rest, schema }] = calls;
  // 資料のブロックだけを明示のキャッシュに入れる
  assert.ok(prefix?.endsWith('L1: - 手洗いは30秒\n\n') && rest.startsWith('# マニュアル1: キッチン\n'), prefix ?? '');
  const prompt = prefix + rest;
  // M の番号は、ノートの順・取り込んだ順に通しで振り、どのノートの資料かを添える
  assert.ok(
    prompt.startsWith(`# 資料
## 資料M1: 店舗マニュアル（マニュアル1の資料）
〔p.1〕
L1: ## 開店前
L2: - 冷蔵庫の温度を記録する
〔p.2〕
L3: - 味噌汁の塩は小さじ1

## 資料M2: 衛生の手引き（マニュアル1の資料）
L1: - 手洗いは30秒

## 資料M3: 衛生の手引き（マニュアル2の資料）
L1: - 手洗いは30秒

# マニュアル1: キッチン
L1: ## 味噌汁
`),
    prompt,
  );
  assert.ok(
    prompt.includes(`## 確定済みの記録（マニュアル1）
- 2026-11-05 店長に確認：250gのまま（「- 大盛りは250gまで」→「- 大盛りは250gまで」）
- 資料M1 L3（p.2）について 2026-11-07 店長に確認：1/2で統一（資料「- 味噌汁の塩は小さじ1」→「- 味噌汁の塩は小さじ1/2」）

# マニュアル2: ホール`),
    prompt,
  );
  assert.match(system, /資料は、職場や学校で配られた/);
  assert.match(system, /資料について:\n/);
  assert.match(JSON.stringify(toGeminiSchema(schema)), /"materialLine"/);
});

test('資料：直接編集の確かめも、資料をマニュアルより前に置き、資料に結び付いた確定を添える', async () => {
  const { generate, calls } = stub({ kind: 'addition', conflictLineNo: null, sameLineNo: null, materialLine: null, reason: 'x', ask: null });
  await checkWithGemini(
    {
      ...withMaterials,
      utterance: { text: '- 塩 小さじ2', speaker: '自分', saidAt: '2026-11-08' },
      patch: { op: 'insert', line: null, text: '- 塩 小さじ2', summary: '追記' },
    },
    generate,
  );
  const [{ system, prefix, prompt: rest }] = calls;
  assert.ok(prefix?.endsWith('L1: - 手洗いは30秒\n\n') && rest.startsWith('# 現行マニュアル\n'), prefix ?? '');
  const prompt = prefix + rest;
  assert.ok(prompt.startsWith('# 資料\n## 資料M1: 店舗マニュアル\n〔p.1〕\nL1: ## 開店前\n'), prompt);
  assert.match(prompt, /## 資料M2: 衛生の手引き\nL1: - 手洗いは30秒\n\n# 現行マニュアル\n/);
  assert.match(prompt, /# 確定済みの記録\n- 2026-11-05 .+\n- 資料M1 L3（p\.2）について 2026-11-07 店長に確認：/);
  assert.match(system, /資料について:\n/);
  // パッチの作り方は直接編集の確かめには要らない
  assert.doesNotMatch(system, /資料は、職場や学校で配られた/);
  // 資料ぶんだけ1本目が遅いので、並べて送るまで assess と同じだけ待つ
  assert.equal(calls[0].hedgeMs, 12_000);
});

test('資料：資料の行を指すと、相手の行の文と資料の場所を返す。ノートの行も正しく指していればノートを採る', async () => {
  const toMaterial = await assessWithMaterials([
    item({ kind: 'contradiction', materialLine: { materialNo: 1, lineNo: 3 }, ask }),
    item({ kind: 'same', materialLine: { materialNo: 2, lineNo: 1 } }),
    item({ kind: 'contradiction', conflictLineNo: 2, materialLine: { materialNo: 1, lineNo: 3 }, ask }),
    item({ kind: 'addition', materialLine: { materialNo: 1, lineNo: 3 } }),
  ]).run();
  assert.deepEqual(
    toMaterial.items.map(({ check: c }) => [c.kind, c.conflictLine, c.sameLine, c.materialRef]),
    [
      ['contradiction', '- 味噌汁の塩は小さじ1', null, { materialId: 'mat-store', title: '店舗マニュアル', page: 2, lineNo: 3 }],
      ['same', null, '- 手洗いは30秒', { materialId: 'mat-hygiene', title: '衛生の手引き', page: null, lineNo: 1 }],
      ['contradiction', '- 塩 小さじ1', null, null],
      ['addition', null, null, null],
    ],
  );

  const { generate } = stub({ kind: 'contradiction', conflictLineNo: null, sameLineNo: null, materialLine: { materialNo: 1, lineNo: 3 }, reason: 'x', ask });
  const r = await checkWithGemini({ ...withMaterials, utterance: { text: 'x', speaker: null, saidAt: '2026-11-08' }, patch: { op: 'insert', line: null, text: 'x', summary: 'x' } }, generate);
  assert.deepEqual([r.conflictLine, r.materialRef], ['- 味噌汁の塩は小さじ1', { materialId: 'mat-store', title: '店舗マニュアル', page: 2, lineNo: 3 }]);
});

test('資料：別のノートの資料・見出し・無い行を指したら、形が合わない', async () => {
  for (const materialLine of [{ materialNo: 3, lineNo: 1 }, { materialNo: 1, lineNo: 1 }, { materialNo: 1, lineNo: 4 }, { materialNo: 4, lineNo: 1 }, null]) {
    await assert.rejects(assessWithMaterials([item({ kind: 'contradiction', materialLine, ask })]).run());
    await assert.rejects(assessWithMaterials([item({ kind: 'same', materialLine })]).run());
  }
  // 2冊目のノートの資料（M3）は、2冊目へのパッチからなら指せる
  const r = await assessWithMaterials([item({ manualNo: 2, kind: 'same', materialLine: { materialNo: 3, lineNo: 1 } })]).run();
  assert.deepEqual(r.items[0].check.materialRef, { materialId: 'mat-hygiene', title: '衛生の手引き', page: null, lineNo: 1 });
});

test('資料：資料に結び付いた確定は、今ある資料のものだけを、資料のまま・違う内容で書き分ける。ノートの確定済みの記録と裏付けには出さない', () => {
  const material: Material = {
    id: 'mat-store',
    title: '店舗マニュアル',
    pages: [{ page: 1, text: '## 休憩\n- 休憩は30分' }],
    tokens: 10,
    addedBy: { id: 'demo', name: 'demo' },
    createdAt: '',
  };
  const ref = (materialId: string) => ({ materialId, title: '店舗マニュアル', page: 1, lineNo: 2 });
  const base = { patchId: 'p', utteranceId: 'u', createdAt: '', sameLine: null, reason: 'x', ask, conflictLine: '- 休憩は30分' };
  const decided = (text: string) => ({ utteranceId: 'a', patchId: null, decidedBy: '店長', decidedAt: '2026-11-07', text, note: '店長に聞いた' });
  const checks: Check[] = [
    { ...base, id: 'keep', kind: 'contradiction', materialRef: ref('mat-store'), resolution: decided('- 休憩は30分') },
    { ...base, id: 'changed', kind: 'contradiction', materialRef: ref('mat-store'), resolution: decided('- 休憩は45分') },
    // 消した資料の確定は、指せる行が無いので見せない
    { ...base, id: 'gone', kind: 'contradiction', materialRef: ref('mat-deleted'), resolution: decided('- 休憩は45分') },
    { ...base, id: 'open', kind: 'contradiction', materialRef: ref('mat-store'), resolution: null },
    { ...base, id: 'same', kind: 'same', conflictLine: null, sameLine: '- 休憩は30分', ask: null, materialRef: ref('mat-store'), resolution: null },
  ];
  assert.deepEqual(materialContext([material], checks), {
    materials: [{ id: 'mat-store', title: '店舗マニュアル', lines: [{ page: 1, text: '## 休憩' }, { page: 1, text: '- 休憩は30分' }] }],
    materialConfirmations: [
      { materialId: 'mat-store', lineNo: 2, page: 1, text: '2026-11-07 店長に確認：店長に聞いた（資料のとおり「- 休憩は30分」）' },
      { materialId: 'mat-store', lineNo: 2, page: 1, text: '2026-11-07 店長に確認：店長に聞いた（資料「- 休憩は30分」→「- 休憩は45分」）' },
    ],
  });
  // 同じ資料から作ったノートに同じ文の行があっても、資料の確定と「も同じ」を、その行のものとして出さない
  const said = { id: 'u', text: 'x', speaker: '田中さん', saidAt: '2026-11-06', createdAt: '' };
  assert.deepEqual(manualContext([{ text: '- 休憩は30分', patchId: null }], [], [said], checks), {
    lines: [{ text: '- 休憩は30分', note: null }],
    confirmations: [],
  });
});

test('書き起こし：ファイルを添えて呼ぶ', async () => {
  const { generate, calls } = stub({ text: ' 田中さんから塩は小さじ1/2 ' });
  const files = [{ mimeType: 'image/png', data: 'AAAA' }];
  assert.equal(await transcribeWithGemini(files, generate), '田中さんから塩は小さじ1/2');
  assert.deepEqual(calls[0].files, files);
  // 書き写すだけなので考えさせず、遅ければ早めに並べて送る
  assert.deepEqual([calls[0].thinkingLevel, calls[0].hedgeMs], ['LOW', 8_000]);
});

test('整形：本文を渡し、行末の空白だけを落として行頭の入れ子は残す', async () => {
  const { generate, calls } = stub({ text: '## 仕込み  \n- 野菜を切る\n  - 玉ねぎは薄切り \n' });
  assert.equal(await formatWithGemini('仕込み 野菜を切る 玉ねぎは薄切り', generate), '## 仕込み\n- 野菜を切る\n  - 玉ねぎは薄切り');
  assert.equal(calls.length, 1);
  assert.match(calls[0].prompt, /仕込み 野菜を切る 玉ねぎは薄切り/);
  assert.equal(calls[0].thinkingLevel, 'LOW');
});

test('読み取り：ファイルを渡し、本文と題名の前後の空白を落とす', async () => {
  const files = [{ mimeType: 'application/pdf', data: 'JVBERg==' }];
  const { generate, calls } = stub({ title: ' キッチンマニュアル ', text: '仕込み  \n  野菜を切る\n' });
  assert.deepEqual(await readNoteWithGemini(files, generate), { title: 'キッチンマニュアル', text: '仕込み\n  野菜を切る' });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].files, files);
});

test('読み取り：1回の呼び出しで、整形と同じ書き方のマークダウンに整えさせる', async () => {
  const read = stub({ title: 't', text: 'x' });
  await readNoteWithGemini([{ mimeType: 'application/pdf', data: 'JVBERg==' }], read.generate);
  const format = stub({ text: 'x' });
  await formatWithGemini('x', format.generate);
  // 整形の決まり（見出しから空行まで）を、読み取りの指示にもそのまま含める
  const rules = format.calls[0].system.slice(format.calls[0].system.indexOf('ノートは1行を1まとまり'));
  assert.ok(read.calls[0].system.includes(rules));
  assert.equal(read.calls.length, 1);
  assert.equal(read.calls[0].thinkingLevel, 'LOW');
});

/**
 * 決まった順に応答する fetch。数字はそのステータスの失敗、'hang' は打ち切られるまで返事をしない、
 * 文字列はその文面で成功。送られたプロンプトを記録する
 */
function fakeFetch(replies: (number | 'hang' | string)[]) {
  const prompts: string[] = [];
  let aborted = 0;
  const fetch = (_url: unknown, init?: RequestInit) => {
    const reply = replies[Math.min(prompts.length, replies.length - 1)];
    prompts.push(JSON.parse(String(init?.body)).contents[0].parts[0].text);
    if (reply === 'hang') {
      return new Promise<Response>((_, reject) =>
        init?.signal?.addEventListener('abort', () => {
          aborted++;
          reject(init.signal!.reason);
        }),
      );
    }
    const body = typeof reply === 'string' ? { candidates: [{ content: { parts: [{ text: reply }] } }] } : { error: { code: reply, message: 'x' } };
    return Promise.resolve(new Response(JSON.stringify(body), { status: typeof reply === 'string' ? 200 : reply, headers: { 'Content-Type': 'application/json' } }));
  };
  return { fetch, prompts, aborted: () => aborted };
}

const ok = JSON.stringify({ text: 'ok' });

async function requestWith(replies: (number | 'hang' | string)[], { timeout = httpOptions.timeout, hedgeMs = 60_000 } = {}) {
  const f = fakeFetch(replies);
  const ai = new GoogleGenAI({ vertexai: true, apiKey: 'test', httpOptions: { ...httpOptions, timeout, fetch: f.fetch } });
  // 待ち時間だけ短くして、送る本数と対象のステータスは本番と同じ設定で確かめる
  const res = await requestJson(ai, { system: 's', prompt: '書き起こして', schema: z.object({ text: z.string() }), hedgeMs }, 1).then(
    (r) => r.text,
    (e) => e,
  );
  return { res, calls: f.prompts.length, prompts: f.prompts, aborted: f.aborted() };
}

test('呼び出し：混雑（503）やレート制限（429）は待ってやり直す', async () => {
  assert.deepEqual((await requestWith([503, ok])).res, 'ok');
  const twice = await requestWith([429, 429, ok]);
  assert.deepEqual([twice.res, twice.calls], ['ok', 3]);
});

test('呼び出し：やり直しは決めた回数まで。リクエストの誤り（400）はやり直さない', async () => {
  const busy = await requestWith([503]);
  assert.equal(busy.calls, 3);
  assert.equal(busy.res.status, 503);
  const bad = await requestWith([400, ok]);
  assert.equal(bad.calls, 1);
  assert.equal(bad.res.status, 400);
});

test('呼び出し：応答が上限時間を過ぎたら打ち切り、やり直す', async () => {
  const r = await requestWith(['hang', ok], { timeout: 20 });
  assert.deepEqual([r.res, r.calls], ['ok', 2]);
});

test('呼び出し：返事が遅ければ、打ち切らずに中身を変えた依頼を並べて送り、先に返ったほうを使う', async () => {
  const r = await requestWith(['hang', ok], { hedgeMs: 10 });
  assert.deepEqual([r.res, r.prompts], ['ok', ['書き起こして', '書き起こして\n']]);
  // 使わなかった1本目は止める
  assert.equal(r.aborted, 1);
});

test('呼び出し：すぐ返れば並べて送らない', async () => {
  const r = await requestWith([ok], { hedgeMs: 10 });
  await new Promise((resolve) => setTimeout(resolve, 30));
  // prompts は送るたびに増えるので、待ったあとも1本のままかを見る
  assert.deepEqual([r.res, r.prompts.length], ['ok', 1]);
});

test('呼び出し：やり直すときは、同じ中身にならないよう末尾に改行を足す（1回目はそのまま）', async () => {
  const r = await requestWith([504, 504, ok]);
  assert.deepEqual(r.prompts, ['書き起こして', '書き起こして\n', '書き起こして\n\n']);
});

test('呼び出し：応答の形が崩れたら1回だけ呼び直す', async () => {
  assert.deepEqual(await requestWith(['{}', ok]).then((r) => [r.res, r.calls]), ['ok', 2]);
  const broken = await requestWith(['{}']);
  assert.equal(broken.calls, 2);
  assert.match(broken.res.message, /想定の形になりませんでした/);
});

test('呼び出し：使った応答のトークンと、何本目を使ったか・何本送ったかを返す（暗黙のキャッシュが効いているかを見る）', async () => {
  let sent = 0;
  const usageMetadata = { promptTokenCount: 7000, cachedContentTokenCount: 6144, candidatesTokenCount: 20, thoughtsTokenCount: 30 };
  // 1本目は返事をせず、並べた2本目が返る
  const fetch = (_url: unknown, init?: RequestInit) =>
    ++sent === 1
      ? new Promise<Response>((_, reject) => init?.signal?.addEventListener('abort', () => reject(init.signal!.reason)))
      : Promise.resolve(
          new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: ok }] } }], usageMetadata }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          }),
        );
  const ai = new GoogleGenAI({ vertexai: true, apiKey: 'test', httpOptions: { ...httpOptions, fetch } });
  const usages: Usage[] = [];
  const schema = z.object({ text: z.string() });
  await requestJson(ai, { system: 's', prompt: 'p', schema, hedgeMs: 10, label: 'assess', onUsage: (u) => usages.push(u) }, 1);
  assert.deepEqual(
    usages.map(({ seconds: _, ...u }) => u),
    [{ label: 'assess', attempt: 2, sent: 2, explicitCache: false, ...usageMetadata }],
  );
});

/**
 * 明示のキャッシュを作る・生成するの両方に応える fetch。create はキャッシュを作る呼び出しへの応答（'ok' か失敗のステータス）、
 * generate は生成への応答（文面か失敗のステータス）を順に返す。送られた生成の本文を記録する
 */
function cacheFetch({ create = ['ok'], generate = [ok] }: { create?: ('ok' | number)[]; generate?: (string | number)[] }) {
  const creates: Record<string, unknown>[] = [];
  const gens: Record<string, any>[] = [];
  const json = (body: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));
  const fetch = (url: unknown, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    if (String(url).includes('cachedContents')) {
      const r = create[Math.min(creates.length, create.length - 1)];
      creates.push(body);
      return r === 'ok' ? json({ name: `projects/p/locations/global/cachedContents/c${creates.length}` }) : json({ error: { code: r, message: 'x' } }, r);
    }
    const r = generate[Math.min(gens.length, generate.length - 1)];
    gens.push(body);
    return typeof r === 'string' ? json({ candidates: [{ content: { parts: [{ text: r }] } }] }) : json({ error: { code: r, message: 'x' } }, r);
  };
  const ai = new GoogleGenAI({ vertexai: true, apiKey: 'test', httpOptions: { ...httpOptions, fetch } });
  // キャッシュはモジュールの Map に持つので、テストごとに prefix を変えてキーを分ける
  const req = { system: 's', prefix: `資料${Math.random()}\n`, prompt: 'p', schema: z.object({ text: z.string() }) };
  // キャッシュは裏で作るので、送ったあとに作り終わるのを待つ
  const send = async () => {
    const r = await requestWithCache(ai, req, 1).then((r) => r.text, (e) => e);
    await new Promise((done) => setTimeout(done, 5));
    return r;
  };
  /** キャッシュ無しで送ったときの [cachedContent, 指示文, 本文] */
  const plain = [undefined, 's', `${req.prefix}p`];
  return { send, req, creates, gens, plain };
}

const c1 = 'projects/p/locations/global/cachedContents/c1';

test('明示のキャッシュ：1回目は作り始めてキャッシュ無しで送り、2回目から指示文を付けずに prompt だけを送る。作り直さない', async () => {
  const f = cacheFetch({});
  assert.equal(await f.send(), 'ok');
  assert.equal(await f.send(), 'ok');
  assert.equal(await f.send(), 'ok');
  assert.equal(f.creates.length, 1);
  const created = f.creates[0] as { systemInstruction: { parts: { text: string }[] }; contents: { parts: { text: string }[] }[] };
  assert.deepEqual([created.systemInstruction.parts[0].text, created.contents[0].parts[0].text], ['s', f.req.prefix]);
  assert.deepEqual(
    f.gens.map((g) => [g.cachedContent, g.systemInstruction?.parts[0].text, g.contents[0].parts[0].text]),
    [f.plain, [c1, undefined, 'p'], [c1, undefined, 'p']],
  );
});

test('明示のキャッシュ：作れなければ、今まで通り指示文を付けて prefix + prompt を送る。小さすぎて断られた（400）ものは作り直さない', async () => {
  const f = cacheFetch({ create: [400] });
  assert.equal(await f.send(), 'ok');
  assert.equal(await f.send(), 'ok');
  assert.equal(f.creates.length, 1);
  assert.deepEqual(
    f.gens.map((g) => [g.cachedContent, g.systemInstruction?.parts[0].text, g.contents[0].parts[0].text]),
    [f.plain, f.plain],
  );
});

test('明示のキャッシュ：キャッシュが無い（404）と断られたら、今回はキャッシュ無しで送り、次の回に作り直す', async () => {
  const f = cacheFetch({ generate: [ok, 404, ok] });
  await f.send();
  assert.equal(await f.send(), 'ok');
  assert.deepEqual(
    f.gens.map((g) => g.cachedContent ?? null),
    [null, c1, null],
  );
  await f.send();
  assert.equal(f.creates.length, 2);
});

test('明示のキャッシュ：期限の5分前を過ぎたら、前のキャッシュを使いながら作り直す。期限を過ぎた名前は送らない', async () => {
  const f = cacheFetch({});
  const now = Date.now();
  const at = (ms: number) => mock.method(Date, 'now', () => now + ms);
  at(0);
  await f.send();
  await f.send();
  at(56 * 60_000);
  await f.send();
  assert.equal(f.creates.length, 2);
  // 作り直しが断られたまま期限を過ぎた
  const g = cacheFetch({ create: ['ok', 503] });
  at(0);
  await g.send();
  at(61 * 60_000);
  await g.send();
  mock.restoreAll();
  assert.deepEqual(
    [...f.gens, ...g.gens].map((x) => x.cachedContent ?? null),
    [null, c1, c1, null, null],
  );
});
