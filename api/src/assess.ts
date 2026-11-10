import { z } from 'zod';

import {
  checkRules,
  counterpart,
  materialConfirmation,
  materialLine,
  materialLineOf,
  materialRules,
  numberedMaterial,
  type CheckResult,
  type ManualContext,
  type MaterialContext,
  type MaterialLine,
} from './conflict/check.ts';
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
  /** 言った人や「〜と言われた」を除いた、言われた言葉。画面の付箋に出す */
  said: string;
  /** パッチと、その分類。manual はマニュアルの添字（0始まり）。指示がなければ空 */
  items: { manual: number; patch: PatchDraft; check: CheckResult }[];
}

/** 口頭で言われたことを、マニュアルごとのパッチ候補とその分類にする */
export type Assess = (input: AssessInput) => Promise<AssessResult>;

/** 資料（ADR 0019）があるときだけ足す、パッチの作り方と振り分け。分類の決め方（materialRules）は衝突検知が持つ */
const materialPatchRules = `資料は、職場や学校で配られたマニュアル・規約・授業の資料を書き起こしたもので、書き換えません。「# 資料」の下に「## 資料M1: 題名（マニュアル1の資料）」の形で、どのマニュアルに付いた資料かを添えて渡します。
- パッチ（op・lineNo）はマニュアルの行だけを指す。資料にしか書かれていない事柄についての指示は、そのマニュアルへの追記（insert）にする
- マニュアルの本文が白紙でも、そのマニュアルの資料が扱う事柄に当たれば、そのマニュアルへのパッチにする`;

// 資料が0冊なら、指示文を資料の前と1文字も変えない（今の eval/ の数字と、資料を使わない人の判定を守る）
const system = (materials: boolean) => `${patchifySystem}

マニュアルは複数あり、番号付きで渡します（「# マニュアル1: 題名」）。行番号はマニュアルごとに1から数えます。
- パッチごとに、どのマニュアルへのパッチかを manualNo に入れる。lineNo・conflictLineNo・sameLineNo はそのマニュアルの行番号
- 1つの指示が複数のマニュアルに関わるなら、マニュアルごとに別のパッチにする
- 本文が白紙のマニュアルは、題名が扱う事柄に当たるかで判断する（白紙なら追記だけで、lineNo は null）
- どのマニュアルの見出し・項目にも当てはまらない雑談や感想だけなら、patches は空にする
${materials ? `\n${materialPatchRules}\n` : ''}
さらに、作ったパッチごとに、そのマニュアルの全文と確定済みの記録に照らして次の項目を判定し、patches の各要素に入れてください。
マニュアルの行の後ろの〔〕はその行の出どころ（誰がいつ言ったか、確認して確定したか）です。

${checkRules}${materials ? `\n\n${materialRules}` : ''}`;

/** プロンプトに載せた資料。M の番号は位置 + 1 で、manual は付いているマニュアルの添字 */
type Mats = { manual: number; ctx: MaterialContext }[];

/** 資料の行。そのパッチのマニュアルに付いた資料でなければ指せない */
function materialAt(mats: Mats, manualNo: number, m: MaterialLine | undefined) {
  const x = m ? mats[m.materialNo - 1] : undefined;
  return x && x.manual === manualNo - 1 ? { ctx: x.ctx, lineNo: m!.lineNo } : undefined;
}

function schema(manuals: string[][], mats: Mats) {
  const at = (m: number, n: number | null) => (n === null ? undefined : manuals[m - 1]?.[n - 1]);
  const atMaterial = (manualNo: number, m: MaterialLine | undefined) => {
    const x = materialAt(mats, manualNo, m);
    return x?.ctx.lines[x.lineNo - 1]?.text;
  };
  const lineNo = z.number().int().min(1);
  return z.object({
    speaker: z.string().min(1).nullable(),
    saidAt: isoDate.nullable(),
    said: z.string().min(1),
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
          // 資料が0冊ならスキーマに入れない（資料の前と変えない）
          ...(mats.length > 0 ? { materialLine: materialLine(mats.length) } : {}),
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
          (p) =>
            p.kind !== 'contradiction' ||
            ((isItem(at(p.manualNo, p.conflictLineNo)) || isItem(atMaterial(p.manualNo, materialLineOf(p)))) && p.ask !== null),
          'contradiction のときは、衝突相手の項目の行（そのマニュアルの行番号か、そのマニュアルの資料の materialLine）と ask を入れてください',
        )
        .refine(
          (p) => p.kind !== 'same' || isItem(at(p.manualNo, p.sameLineNo)) || isItem(atMaterial(p.manualNo, materialLineOf(p))),
          'same のときは、同じ内容の項目の行（そのマニュアルの行番号か、そのマニュアルの資料の materialLine）を入れてください',
        ),
    ),
  });
}

export async function assessWithGemini(input: AssessInput, generate: GenerateJson = generateJson): Promise<AssessResult> {
  const manuals = input.manuals.map((m) => m.lines.map((l) => l.text));
  // 資料の番号はプロンプトの中で通しに振る（マニュアルの順、その中は取り込んだ順）
  const mats: Mats = input.manuals.flatMap((m, manual) => m.materials.map((ctx) => ({ manual, ctx })));
  const no = (manual: number, id: string) => mats.findIndex((x) => x.manual === manual && x.ctx.id === id) + 1;
  // 変わらない部分（指示・資料・マニュアル・確定済みの記録）を前に置き、コンテキストキャッシュに乗せる。
  // 資料は足す・消すまで変わらないので、編集のたびに変わるマニュアルより前に置き、指示文と合わせて明示のキャッシュに入れる
  const head = mats.length
    ? `# 資料\n${mats.map((x, k) => `## 資料M${k + 1}: ${x.ctx.title}（マニュアル${x.manual + 1}の資料）\n${numberedMaterial(x.ctx.lines)}`).join('\n\n')}\n\n`
    : '';
  const prompt = `${input.manuals
    .map(
      (m, i) => `# マニュアル${i + 1}: ${m.title}
${numbered(manuals[i], (n) => m.lines[n].note)}

## 確定済みの記録（マニュアル${i + 1}）
${[...m.confirmations, ...m.materialConfirmations.map((c) => materialConfirmation(no(i, c.materialId), c))].map((c) => `- ${c}`).join('\n') || '（なし）'}`,
    )
    .join('\n\n')}

# これまでの発言者
${input.speakers.join('、') || '（なし）'}

# 基準日
${input.today}

# 新人のメモ
${input.text}`;
  // ふだんは5〜15秒で返り、遅い1本は25秒を過ぎても返らない。12秒で並べると遅い件が約6秒縮む（ADR 0002）
  const out = await generate({ system: system(mats.length > 0), ...(head && { prefix: head }), prompt, schema: schema(manuals, mats), hedgeMs: 12_000, label: 'assess' });
  return {
    speaker: out.speaker,
    saidAt: out.saidAt,
    said: out.said,
    items: out.patches.map((p) => {
      const lines = manuals[p.manualNo - 1];
      const line = (n: number | null) => (n === null ? null : lines[n - 1]);
      const n = p.kind === 'contradiction' ? p.conflictLineNo : p.kind === 'same' ? p.sameLineNo : null;
      return {
        manual: p.manualNo - 1,
        patch: { op: p.op, line: line(p.lineNo), text: p.text, summary: p.summary },
        check: counterpart(p, line(n) ?? undefined, materialAt(mats, p.manualNo, materialLineOf(p))),
      };
    }),
  };
}
