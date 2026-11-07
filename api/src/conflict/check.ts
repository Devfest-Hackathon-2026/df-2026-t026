import type { ManualLine, Patch, PatchDraft, Utterance } from '../foundation/manual.ts';

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
