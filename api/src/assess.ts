import { z } from 'zod';

import { checkRules, type CheckResult, type ManualContext } from './conflict/check.ts';
import type { PatchDraft } from './foundation/manual.ts';
import { patchifySystem } from './foundation/patchify.ts';
import { generateJson, hasText, isItem, isoDate, lineNo, numbered, type GenerateJson } from './gemini.ts';

/*
 * 差分化（土台）と分類（衝突検知）を Gemini 1回で行う（ADR 0006）。
 * 呼び出し回数と待ちの段数を減らすため。指示文はそれぞれのモジュールが持ち、
 * 保存の形（patches / checks）も分けたままにする。
 */

export interface AssessInput extends ManualContext {
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
  /** パッチと、その分類。指示がなければ空 */
  items: { patch: PatchDraft; check: CheckResult }[];
}

/** 口頭で言われたことを、パッチ候補とその分類にする */
export type Assess = (input: AssessInput) => Promise<AssessResult>;

const system = `${patchifySystem}

さらに、作ったパッチごとに、マニュアル全文と確定済みの記録に照らして次の項目を判定し、patches の各要素に入れてください。
マニュアルの行の後ろの〔〕はその行の出どころ（誰がいつ言ったか、確認して確定したか）です。

${checkRules}`;

const ask = z
  .object({
    candidates: z.array(z.object({ who: z.string().min(1), why: z.string().min(1) })).min(1).max(3),
    question: z.string().min(1),
  })
  .nullable();

function schema(lines: string[]) {
  return z.object({
    speaker: z.string().min(1).nullable(),
    saidAt: isoDate.nullable(),
    patches: z.array(
      z
        .object({
          op: z.enum(['replace', 'insert']),
          lineNo: lineNo(lines).nullable(),
          text: z.string().min(1),
          summary: z.string().min(1),
          kind: z.enum(['same', 'addition', 'qualification', 'contradiction']),
          conflictLineNo: lineNo(lines).nullable(),
          sameLineNo: lineNo(lines).nullable(),
          reason: z.string().min(1),
          ask,
        })
        .refine(
          (p) =>
            p.op === 'replace'
              ? p.lineNo !== null && isItem(lines[p.lineNo - 1])
              : p.lineNo === null || hasText(lines[p.lineNo - 1]),
          'replace は項目の行を、insert は空でない行か null を指してください',
        )
        .refine(
          (p) => p.kind !== 'contradiction' || (p.conflictLineNo !== null && isItem(lines[p.conflictLineNo - 1]) && p.ask !== null),
          'contradiction のときは、衝突相手の項目の行番号と ask を入れてください',
        )
        .refine(
          (p) => p.kind !== 'same' || (p.sameLineNo !== null && isItem(lines[p.sameLineNo - 1])),
          'same のときは、同じ内容の項目の行番号を入れてください',
        ),
    ),
  });
}

export async function assessWithGemini(input: AssessInput, generate: GenerateJson = generateJson): Promise<AssessResult> {
  const lines = input.lines.map((l) => l.text);
  // 変わらない部分（指示・マニュアル・確定済みの記録）を前に置き、暗黙のコンテキストキャッシュに乗せる
  const prompt = `# 現行マニュアル
${numbered(lines, (i) => input.lines[i].note)}

# 確定済みの記録
${input.confirmations.map((c) => `- ${c}`).join('\n') || '（なし）'}

# これまでの発言者
${input.speakers.join('、') || '（なし）'}

# 基準日
${input.today}

# 新人のメモ
${input.text}`;
  const out = await generate({ system, prompt, schema: schema(lines) });
  const line = (n: number | null) => (n === null ? null : lines[n - 1]);
  return {
    speaker: out.speaker,
    saidAt: out.saidAt,
    items: out.patches.map((p) => ({
      patch: { op: p.op, line: line(p.lineNo), text: p.text, summary: p.summary },
      check: {
        kind: p.kind,
        conflictLine: p.kind === 'contradiction' ? line(p.conflictLineNo) : null,
        sameLine: p.kind === 'same' ? line(p.sameLineNo) : null,
        reason: p.reason,
        ask: p.kind === 'contradiction' ? p.ask : null,
      },
    })),
  };
}
