import { z } from 'zod';

import { checkRules, type CheckResult, type ManualContext } from './conflict/check.ts';
import type { PatchDraft } from './foundation/manual.ts';
import { patchifySystem } from './foundation/patchify.ts';
import { generateJson, hasText, isItem, isoDate, numbered, type GenerateJson } from './gemini.ts';

/*
 * 関係するマニュアルの振り分け・差分化（土台）・分類（衝突検知）を Gemini 1回で行う（ADR 0006）。
 * 呼び出し回数と待ちの段数を減らすため。指示文はそれぞれのモジュールが持ち、
 * 保存の形（patches / checks）も分けたままにする。
 */

export interface AssessInput {
  /** 対象のマニュアル。入力ページからは登録済みの全マニュアル、マニュアル画面からはその1冊 */
  manuals: (ManualContext & { title: string })[];
  text: string;
  /** 「昨日」などを解釈する基準日（YYYY-MM-DD） */
  today: string;
  /** これまでに記録した発言者。表記ゆれを揃えるのに使う */
  speakers: string[];
}

export interface AssessResult {
  /** 文中に発言者が書かれていなければ null。推測では埋めない */
  speaker: string | null;
  saidAt: string | null;
  /** パッチと、その分類。manual はマニュアルの添字（0始まり）。指示がなければ空 */
  items: { manual: number; patch: PatchDraft; check: CheckResult }[];
}

/** 口頭で言われたことを、マニュアルごとのパッチ候補とその分類にする */
export type Assess = (input: AssessInput) => Promise<AssessResult>;

const system = `${patchifySystem}

マニュアルは複数あり、番号付きで渡します（「# マニュアル1: 題名」）。行番号はマニュアルごとに1から数えます。
- パッチごとに、どのマニュアルへのパッチかを manualNo に入れる。lineNo・conflictLineNo・sameLineNo はそのマニュアルの行番号
- 1つの指示が複数のマニュアルに関わるなら、マニュアルごとに別のパッチにする
- どのマニュアルの見出し・項目にも当てはまらない雑談や感想だけなら、patches は空にする

さらに、作ったパッチごとに、そのマニュアルの全文と確定済みの記録に照らして次の項目を判定し、patches の各要素に入れてください。
マニュアルの行の後ろの〔〕はその行の出どころ（誰がいつ言ったか、確認して確定したか）です。

${checkRules}`;

function schema(manuals: string[][]) {
  const at = (m: number, n: number | null) => (n === null ? undefined : manuals[m - 1]?.[n - 1]);
  const lineNo = z.number().int().min(1);
  return z.object({
    speaker: z.string().min(1).nullable(),
    saidAt: isoDate.nullable(),
    patches: z.array(
      z
        .object({
          manualNo: z.number().int().min(1).max(manuals.length),
          op: z.enum(['replace', 'insert']),
          lineNo: lineNo.nullable(),
          text: z.string().min(1),
          summary: z.string().min(1),
          kind: z.enum(['same', 'addition', 'qualification', 'contradiction']),
          conflictLineNo: lineNo.nullable(),
          sameLineNo: lineNo.nullable(),
          reason: z.string().min(1),
          ask: z
            .object({
              candidates: z.array(z.object({ who: z.string().min(1), why: z.string().min(1) })).min(1).max(3),
              question: z.string().min(1),
            })
            .nullable(),
        })
        .refine(
          (p) =>
            p.op === 'replace'
              ? isItem(at(p.manualNo, p.lineNo))
              : p.lineNo === null || hasText(at(p.manualNo, p.lineNo)),
          'replace はそのマニュアルの項目の行を、insert は空でない行か null を指してください',
        )
        .refine(
          (p) => p.kind !== 'contradiction' || (isItem(at(p.manualNo, p.conflictLineNo)) && p.ask !== null),
          'contradiction のときは、衝突相手の項目の行番号と ask を入れてください',
        )
        .refine(
          (p) => p.kind !== 'same' || isItem(at(p.manualNo, p.sameLineNo)),
          'same のときは、同じ内容の項目の行番号を入れてください',
        ),
    ),
  });
}

export async function assessWithGemini(input: AssessInput, generate: GenerateJson = generateJson): Promise<AssessResult> {
  const manuals = input.manuals.map((m) => m.lines.map((l) => l.text));
  // 変わらない部分（指示・マニュアル・確定済みの記録）を前に置き、暗黙のコンテキストキャッシュに乗せる
  const prompt = `${input.manuals
    .map(
      (m, i) => `# マニュアル${i + 1}: ${m.title}
${numbered(manuals[i], (n) => m.lines[n].note)}

## 確定済みの記録（マニュアル${i + 1}）
${m.confirmations.map((c) => `- ${c}`).join('\n') || '（なし）'}`,
    )
    .join('\n\n')}

# これまでの発言者
${input.speakers.join('、') || '（なし）'}

# 基準日
${input.today}

# 新人のメモ
${input.text}`;
  const out = await generate({ system, prompt, schema: schema(manuals) });
  return {
    speaker: out.speaker,
    saidAt: out.saidAt,
    items: out.patches.map((p) => {
      const lines = manuals[p.manualNo - 1];
      const line = (n: number | null) => (n === null ? null : lines[n - 1]);
      return {
        manual: p.manualNo - 1,
        patch: { op: p.op, line: line(p.lineNo), text: p.text, summary: p.summary },
        check: {
          kind: p.kind,
          conflictLine: p.kind === 'contradiction' ? line(p.conflictLineNo) : null,
          sameLine: p.kind === 'same' ? line(p.sameLineNo) : null,
          reason: p.reason,
          ask: p.kind === 'contradiction' ? p.ask : null,
        },
      };
    }),
  };
}
