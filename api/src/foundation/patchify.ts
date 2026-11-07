import { z } from 'zod';

import { generateJson, hasText, isItem, isoDate, lineNo, numbered, type GenerateJson } from '../gemini.ts';
import type { PatchDraft } from './manual.ts';

export interface PatchifyInput {
  /** 現行マニュアルの全行 */
  lines: string[];
  text: string;
  /** 「昨日」などを解釈する基準日（YYYY-MM-DD） */
  today: string;
  /** これまでに記録した発言者。表記ゆれを揃えるのに使う */
  speakers: string[];
}

export interface PatchifyResult {
  /** 文中に発言者が書かれていなければ null。推測では埋めない */
  speaker: string | null;
  saidAt: string | null;
  patches: PatchDraft[];
}

/** 口頭で言われたことを、現行マニュアルへのパッチ候補に変換する */
export type Patchify = (input: PatchifyInput) => Promise<PatchifyResult>;

const system = `あなたは、飲食店などで働く新人が「口頭で言われたこと」を、職場のマニュアルへの変更案（パッチ）に変換するアシスタントです。
マニュアルは行番号付きで渡します。「## 」で始まる行は見出し、「- 」で始まる行は項目です。

speaker: メモに書かれた、言った人の呼び方（例: 田中さん、店長）。書かれていなければ null。推測で埋めない。これまでの発言者に同じ人がいれば、その表記に揃える。
saidAt: 言われた日（YYYY-MM-DD）。「昨日」などは基準日から計算する。書かれていなければ null。
patches: マニュアルへの変更案。
- 1つのメモに複数の指示があれば、指示ごとに分ける。指示でない雑談や感想は含めない（指示がなければ空の配列）
- 既存の項目と同じ事柄についての指示なら op=replace。lineNo にその項目の行番号、text に置き換えた後の行を入れる
  - 条件付きの話（「忙しい日は」「ランチは」など）で元の記述も生きているなら、元の記述を残して括弧で併記する（例: "- 塩 小さじ1（忙しい日は小さじ1/2）"）
  - 元の記述と両立しない内容でも、言われた通りの内容で置き換える。どちらが正しいかは判断しない
- 新しい事柄なら op=insert。lineNo には「この行の後ろに入れる」行の番号（合う節の最後の項目、または見出し）。合う節がなければ null（末尾に入る）
- text はマニュアルの書き方（「- 」で始まる短い項目）に合わせる。数値や言い回しは言われた通りにし、勝手に数値化したり言い換えたりしない
- summary は変更の要約を1行で（例: "塩: 小さじ1 → 小さじ1/2"）`;

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
        })
        .refine(
          (p) =>
            p.op === 'replace'
              ? p.lineNo !== null && isItem(lines[p.lineNo - 1])
              : p.lineNo === null || hasText(lines[p.lineNo - 1]),
          'replace は項目の行を、insert は空でない行か null を指してください',
        ),
    ),
  });
}

export async function patchifyWithGemini(
  { lines, text, today, speakers }: PatchifyInput,
  generate: GenerateJson = generateJson,
): Promise<PatchifyResult> {
  // 変わらない部分（指示・マニュアル）を前に置き、暗黙のコンテキストキャッシュに乗せる
  const prompt = `# 現行マニュアル
${numbered(lines)}

# これまでの発言者
${speakers.join('、') || '（なし）'}

# 基準日
${today}

# 新人のメモ
${text}`;
  const out = await generate({ system, prompt, schema: schema(lines) });
  return {
    speaker: out.speaker,
    saidAt: out.saidAt,
    patches: out.patches.map((p) => ({
      op: p.op,
      line: p.lineNo === null ? null : lines[p.lineNo - 1],
      text: p.text,
      summary: p.summary,
    })),
  };
}
