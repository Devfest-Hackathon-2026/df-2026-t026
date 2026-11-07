import { z } from 'zod';

import type { ManualLine, Patch, PatchDraft, Utterance } from '../foundation/manual.ts';
import { generateJson, isItem, lineNo, numbered, type GenerateJson } from '../gemini.ts';

export type Kind = 'addition' | 'qualification' | 'contradiction';

export interface Ask {
  /** 確認する相手の候補。決めるのは本人なので、アプリは候補までを返す */
  candidates: { who: string; why: string }[];
  /** そのまま口頭で聞ける・送れる文面 */
  question: string;
}

export interface CheckResult {
  kind: Kind;
  /** 衝突相手のマニュアルの行。contradiction のときだけ入る */
  conflictLine: string | null;
  reason: string;
  /** contradiction のときだけ入る */
  ask: Ask | null;
}

/** 確認して確定させた記録。後で別の人に聞かれたときの証拠になる */
export interface Resolution {
  /** 確認の答えを土台の発言として記録したもの */
  utteranceId: string;
  /** 確定した内容でマニュアルを変えたパッチ。マニュアルのままなら null */
  patchId: string | null;
  decidedBy: string;
  decidedAt: string;
  /** 確定した行の内容 */
  text: string;
  note: string;
}

export interface Check extends CheckResult {
  id: string;
  patchId: string;
  utteranceId: string;
  resolution: Resolution | null;
  createdAt: string;
}

export interface CheckInput {
  /** 現行マニュアルの全行。note はその行の出どころ（誰がいつ言ったか、確認済みか） */
  lines: { text: string; note: string | null }[];
  /** 確定済みの記録。マニュアルを変えなかった確認もここに入る */
  confirmations: string[];
  utterance: { text: string; speaker: string | null; saidAt: string };
  patch: PatchDraft;
}

/**
 * パッチを3分類し、矛盾なら衝突相手と確認先を返す。
 *
 * 衝突相手はパッチが触る行とは限らない（別の段落にいることが多い）ので、
 * マニュアル全文と確定済みの記録を毎回すべて渡す。
 */
export type CheckPatch = (input: CheckInput) => Promise<CheckResult>;

export function checkInput(
  lines: ManualLine[],
  patches: Patch[],
  utterances: Utterance[],
  checks: Check[],
  utterance: Utterance,
  patch: PatchDraft,
): CheckInput {
  const confirmedPatch = new Set(checks.map((c) => c.resolution?.patchId).filter(Boolean));
  const note = (patchId: string | null) => {
    const p = patches.find((x) => x.id === patchId);
    const u = utterances.find((x) => x.id === p?.utteranceId);
    if (!p || !u) return null;
    return `${u.speaker ?? '不明'}（${u.saidAt}）${confirmedPatch.has(p.id) ? 'に確認して確定' : 'から'}`;
  };
  return {
    lines: lines.map((l) => ({ text: l.text, note: note(l.patchId) })),
    confirmations: checks.flatMap((c) =>
      c.resolution
        ? [`${c.resolution.decidedAt} ${c.resolution.decidedBy}に確認：${c.resolution.note}（「${c.conflictLine}」→「${c.resolution.text}」）`]
        : [],
    ),
    utterance: { text: utterance.text, speaker: utterance.speaker, saidAt: utterance.saidAt },
    patch,
  };
}

const system = `あなたは、飲食店などで働く新人が、矛盾した指示の板挟みにならないよう手助けするアシスタントです。
新人が口頭で言われたことと、そこから作ったマニュアルへの変更案（パッチ）を、マニュアル全文と確定済みの記録に照らして判定します。
マニュアルは行番号付きで、行の後ろの〔〕はその行の出どころ（誰がいつ言ったか、確認して確定したか）です。

kind は次のどれか1つ:
- addition: 既存のどの記述とも両立する追記。言い方が違うだけで同じ内容のときもこれ
- qualification: 既存の記述を残したまま、条件付きの補足を足すもの（例: 「忙しい日は」「ランチだけ」）。両立する
- contradiction: 同じ状況について、マニュアルのどこかの行または確定済みの記録と両立しない

判定の注意:
- 衝突の相手はパッチが触る行とは限らない。マニュアル全文と確定済みの記録をすべて見る
- 条件が書かれていない記述は「いつも」と読む。条件付きの話がそれと両立するなら qualification
- 聞かれすぎると新人はこの道具を使わなくなる。両立する読み方が自然にできるなら contradiction にしない
- ただし、同じ状況で数値・手順・担当・場所が食い違うなら contradiction。「〜から変わった」と言われても、マニュアルと両立しなければ contradiction（どちらが正しいかはアプリが決めない）
- 確認して確定した行や確定済みの記録と食い違うときは contradiction。reason にその確認（誰がいつ）を書く

conflictLineNo: contradiction のときだけ、衝突相手の行番号。それ以外は null
reason: 判定の理由を1〜2文で
ask: contradiction のときだけ入れる。それ以外は null
- candidates: 確認する相手の候補を1〜3人。その判断に責任を持つ立場（店長・社員など）を優先する。言った本人も候補になる。マニュアルや記録に出てくる人・役職から選び、いなければ「店長」のような一般的な役職にする。who は呼び方、why はその人に聞く理由を短く
- question: 新人がそのまま口頭で聞ける、丁寧で短い話し言葉。誰かが間違っていると責めない。「〜と教わったのですが、〜とも聞いて、どちらに合わせればよいですか」のように両方を並べて判断を仰ぐ。告げ口に聞こえないよう、もう一方の指示を出した人の名前は必要がなければ出さない`;

function schema(lines: string[]) {
  return z
    .object({
      kind: z.enum(['addition', 'qualification', 'contradiction']),
      conflictLineNo: lineNo(lines).nullable(),
      reason: z.string().min(1),
      ask: z
        .object({
          candidates: z.array(z.object({ who: z.string().min(1), why: z.string().min(1) })).min(1).max(3),
          question: z.string().min(1),
        })
        .nullable(),
    })
    .refine(
      (o) => o.kind !== 'contradiction' || (o.conflictLineNo !== null && isItem(lines[o.conflictLineNo - 1]) && o.ask !== null),
      'contradiction のときは、衝突相手の項目の行番号と ask を入れてください',
    );
}

export async function checkWithGemini(input: CheckInput, generate: GenerateJson = generateJson): Promise<CheckResult> {
  const lines = input.lines.map((l) => l.text);
  const { utterance: u, patch: p } = input;
  // 変わらない部分（指示・マニュアル・確定済みの記録）を前に置き、暗黙のコンテキストキャッシュに乗せる
  const prompt = `# 現行マニュアル
${numbered(lines, (i) => input.lines[i].note)}

# 確定済みの記録
${input.confirmations.map((c) => `- ${c}`).join('\n') || '（なし）'}

# 新しく言われたこと
${u.speaker ?? '発言者不明'}（${u.saidAt}）: ${u.text}

# そこから作ったパッチ
${p.op === 'replace' ? `「${p.line}」を「${p.text}」に置き換える` : `「${p.text}」を${p.line ? `「${p.line}」の後ろに` : '末尾に'}追記する`}`;
  const out = await generate({ system, prompt, schema: schema(lines) });
  if (out.kind !== 'contradiction') return { kind: out.kind, conflictLine: null, reason: out.reason, ask: null };
  return { kind: out.kind, conflictLine: lines[out.conflictLineNo! - 1], reason: out.reason, ask: out.ask };
}
